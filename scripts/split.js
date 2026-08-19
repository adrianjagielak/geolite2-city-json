#!/usr/bin/env node
'use strict';

/*
 * geolite2-city-json — generator
 * -------------------------------
 * Reads a MaxMind GeoLite2-City .mmdb file and emits one compact, lossless
 * JSON file per IPv4 /16 into <out>/<A>/<B>.json.
 *
 * Why /16 and not /24?
 *   A per-/24 (data/A/B/C.json) layout as one file per /24 would create ~14.4M
 *   files (most of them byte-identical, because the DB stores a single record
 *   for whole /20s, /16s, etc.). That is fatal for git checkout, the git index,
 *   GitHub repo health and jsDelivr. Grouping by /16 yields ~56k files (~110 MiB)
 *   while still resolving every individual IPv4 address exactly.
 *
 * File format (see README.md for the consumer contract):
 *   {
 *     "r": [ <record>, ... ],        // distinct records used in this /16
 *     "c": [ slot_for_C0, ..., slot_for_C255 ]   // index = 3rd octet (C)
 *   }
 *   where each slot is one of:
 *     null                       -> that /24 has no data
 *     <int>                      -> whole /24 resolves to r[<int>]
 *     [[startD, ri], ...]        -> /24 is split; run i covers octets
 *                                   [startD_i, startD_{i+1}); ri = -1 means the
 *                                   octet range has no data, otherwise r[ri].
 *
 * A <record> is minimal and omits null fields:
 *   { country, region?, city?, lat?, lon? }
 *
 * The output is fully deterministic for a given input .mmdb (stable ordering,
 * no timestamps) so that unchanged /16s produce byte-identical files and git
 * records no change for them.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const maxmind = require('maxmind');

// ----------------------------------------------------------------------------
// Config (CLI flags or env vars)
// ----------------------------------------------------------------------------
function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--db') out.db = argv[++i];
    else if (a === '--out') out.out = argv[++i];
    else if (a === '--write-concurrency') out.concurrency = parseInt(argv[++i], 10);
    else if (a === '--help' || a === '-h') out.help = true;
  }
  return out;
}

const args = parseArgs(process.argv);
if (args.help) {
  console.log('Usage: node scripts/split.js [--db GeoLite2-City.mmdb] [--out data]');
  process.exit(0);
}

const DB_PATH = args.db || process.env.MMDB_PATH || 'GeoLite2-City.mmdb';
const OUT_DIR = args.out || process.env.OUT_DIR || 'data';
const WRITE_CONCURRENCY = args.concurrency || parseInt(process.env.WRITE_CONCURRENCY || '64', 10);
const FORMAT_VERSION = 1;

// ----------------------------------------------------------------------------
// Record extraction: turn a full GeoLite2 record into our minimal shape.
// Keys are inserted in a fixed order so JSON.stringify output is deterministic.
// ----------------------------------------------------------------------------
function minimalRecord(d) {
  if (!d) return null;
  const out = {};
  // country: prefer the location country, fall back to the registered country
  // so IPs that only carry a registration (e.g. 1.1.1.1) still resolve.
  const country =
    (d.country && d.country.iso_code) ||
    (d.registered_country && d.registered_country.iso_code);
  if (country) out.country = country;
  // region: top-level (first) subdivision, i.e. state / province / oblast.
  if (d.subdivisions && d.subdivisions.length) {
    const region = d.subdivisions[0].iso_code;
    if (region) out.region = region;
  }
  if (d.city && d.city.names && d.city.names.en) out.city = d.city.names.en;
  if (d.location) {
    if (typeof d.location.latitude === 'number') out.lat = d.location.latitude;
    if (typeof d.location.longitude === 'number') out.lon = d.location.longitude;
  }
  return Object.keys(out).length ? out : null;
}

// ----------------------------------------------------------------------------
// Walk the MaxMind binary search tree and collect every IPv4 network.
//
// mmdb-lib doesn't expose a network iterator, but the Reader gives us the
// building blocks: metadata, the `walker` (left/right record readers) and the
// `decoder` (to resolve a data pointer). We DFS the IPv4 sub-tree.
// ----------------------------------------------------------------------------
function collectNetworks(reader) {
  const md = reader.metadata;
  const nodeCount = md.nodeCount;
  const nodeByteSize = md.nodeByteSize;
  const searchTreeSize = md.searchTreeSize;
  const walker = reader.walker;
  const decoder = reader.decoder;
  const startNode = reader.ipv4StartNodeNumber;

  if (walker === undefined || decoder === undefined || startNode === undefined) {
    throw new Error(
      'Incompatible maxmind/mmdb-lib internals (walker/decoder/ipv4StartNodeNumber missing). ' +
      'Pin maxmind to the tested version.'
    );
  }

  // POW[k] = 2^(32-k); used for both bit values and network sizes.
  const POW = new Array(33);
  for (let k = 0; k <= 32; k++) POW[k] = 2 ** (32 - k);

  const resolve = (ptr) => decoder.decodeFast(ptr - nodeCount + searchTreeSize).value;

  // Intern minimal records to integer ids (dedup across the whole DB).
  const pool = new Map();          // json string -> id
  const recJson = [];              // id -> json string

  // Parallel arrays describing each network.
  const startIp = [];              // uint32 base address
  const prefixLen = [];            // 1..32
  const recId = [];                // index into recJson

  // Iterative DFS stack.
  const stNode = [startNode];
  const stDepth = [0];
  const stIp = [0];

  let visited = 0;
  while (stNode.length) {
    const node = stNode.pop();
    const depth = stDepth.pop();
    const ip = stIp.pop();
    const offset = node * nodeByteSize;

    // Two records per node: left (bit 0) and right (bit 1).
    const children = [
      [walker.left(offset), ip],
      [walker.right(offset), ip + POW[depth + 1]],
    ];
    for (let s = 0; s < 2; s++) {
      const rec = children[s][0];
      const baseIp = children[s][1];
      const nd = depth + 1;
      if (rec === nodeCount) {
        // empty record: no data in this branch
      } else if (rec > nodeCount) {
        // data record: this is a network baseIp/nd
        const mr = minimalRecord(resolve(rec));
        if (!mr) continue; // registration-only / no useful geo -> skip
        const js = JSON.stringify(mr);
        let id = pool.get(js);
        if (id === undefined) {
          id = recJson.length;
          recJson.push(js);
          pool.set(js, id);
        }
        startIp.push(baseIp >>> 0);
        prefixLen.push(nd);
        recId.push(id);
      } else {
        // internal node pointer
        stNode.push(rec);
        stDepth.push(nd);
        stIp.push(baseIp);
      }
    }

    if ((++visited & 0x3fffff) === 0) {
      process.stdout.write(
        `  walking tree… ${visited.toLocaleString()} nodes, ` +
        `${startIp.length.toLocaleString()} networks\n`
      );
    }
  }

  return { startIp, prefixLen, recId, recJson, POW };
}

// ----------------------------------------------------------------------------
// Build the JSON body for a single /16 given its networks (already clipped &
// grouped by third octet C). Returns the serialized string.
// ----------------------------------------------------------------------------
function buildSixteen(perC, recJson) {
  // Local record pool: only the records actually used in this /16, in
  // first-seen order (deterministic, since C ascends and segments are sorted).
  const localPool = new Map(); // globalId -> localId
  const rArr = [];
  const localId = (gid) => {
    let li = localPool.get(gid);
    if (li === undefined) {
      li = rArr.length;
      rArr.push(recJson[gid]);
      localPool.set(gid, li);
    }
    return li;
  };

  let maxC = -1;
  for (const c of perC.keys()) if (c > maxC) maxC = c;
  const cArr = new Array(maxC + 1).fill(null);

  const cs = [...perC.keys()].sort((a, b) => a - b);
  for (const c of cs) {
    const segs = perC.get(c).sort((x, y) => x[0] - y[0]); // by startD
    // Build runs covering octets 0..255, inserting -1 gaps where no data.
    const runs = [];
    let cur = 0;
    for (const seg of segs) {
      const d0 = seg[0], d1 = seg[1], gid = seg[2];
      if (d0 > cur) runs.push([cur, -1]);
      runs.push([d0, localId(gid)]);
      cur = d1 + 1;
    }
    if (cur <= 255) runs.push([cur, -1]);
    // Coalesce consecutive runs with the same record id.
    const merged = [];
    for (const r of runs) {
      if (merged.length && merged[merged.length - 1][1] === r[1]) continue;
      merged.push(r);
    }
    // Uniform /24 -> single int; otherwise the run-list.
    cArr[c] = merged.length === 1 && merged[0][1] >= 0 ? merged[0][1] : merged;
  }

  return '{"r":[' + rArr.join(',') + '],"c":' + JSON.stringify(cArr) + '}';
}

// ----------------------------------------------------------------------------
// Simple bounded-concurrency async file writer.
// ----------------------------------------------------------------------------
async function writeAll(files) {
  let i = 0;
  let written = 0;
  const total = files.length;
  async function worker() {
    while (i < total) {
      const idx = i++;
      const f = files[idx];
      await fsp.writeFile(f.path, f.body);
      written++;
      if ((written % 5000) === 0) {
        process.stdout.write(`  wrote ${written.toLocaleString()}/${total.toLocaleString()} files\n`);
      }
    }
  }
  const workers = [];
  for (let w = 0; w < Math.min(WRITE_CONCURRENCY, total); w++) workers.push(worker());
  await Promise.all(workers);
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------
async function main() {
  const t0 = Date.now();

  if (!fs.existsSync(DB_PATH)) {
    console.error(`ERROR: mmdb not found at "${DB_PATH}".`);
    console.error('Fetch it first, e.g.:  npm run fetch   (or set MMDB_PATH)');
    process.exit(1);
  }

  console.log(`Opening ${DB_PATH} …`);
  const reader = await maxmind.open(DB_PATH);
  const md = reader.metadata;
  console.log(
    `  ${md.databaseType}  build=${md.buildEpoch.toISOString()}  ` +
    `nodes=${md.nodeCount.toLocaleString()}  recordSize=${md.recordSize}`
  );

  console.log('Walking the IPv4 tree…');
  const { startIp, prefixLen, recId, recJson, POW } = collectNetworks(reader);
  const n = startIp.length;
  console.log(
    `  ${n.toLocaleString()} networks, ${recJson.length.toLocaleString()} distinct records ` +
    `(${((Date.now() - t0) / 1000).toFixed(1)}s)`
  );

  // Sort network indices by start address (networks are disjoint).
  const order = new Uint32Array(n);
  for (let k = 0; k < n; k++) order[k] = k;
  // Array.prototype.sort on a typed array sorts numerically.
  const orderArr = Array.from(order);
  orderArr.sort((a, b) => startIp[a] - startIp[b]);

  // Reset the output directory so removed networks don't leave stale files.
  console.log(`Resetting ${OUT_DIR}/ …`);
  await fsp.rm(OUT_DIR, { recursive: true, force: true });
  await fsp.mkdir(OUT_DIR, { recursive: true });

  // Sweep /16 groups in ascending order.
  console.log('Building /16 files…');
  const files = [];              // {path, body}
  const dirsNeeded = new Set();  // A octets that need a directory
  const G = 1 << 16;
  let p = 0;                     // pointer into orderArr
  let built = 0;

  for (let g = 0; g < G; g++) {
    const gStart = g * 65536;
    const gEnd = gStart + 65535;

    // Advance past networks that end before this /16.
    while (p < n && (startIp[orderArr[p]] + POW[prefixLen[orderArr[p]]] - 1) < gStart) p++;
    if (p >= n) break;
    if (startIp[orderArr[p]] > gEnd) continue; // gap: no /16 coverage

    // Collect segments per third octet C.
    const perC = new Map();
    let j = p;
    while (j < n) {
      const k = orderArr[j];
      const s = startIp[k];
      if (s > gEnd) break;
      const e = s + POW[prefixLen[k]] - 1;
      if (e >= gStart) {
        const a = Math.max(s, gStart) - gStart; // offset 0..65535 in this /16
        const b = Math.min(e, gEnd) - gStart;
        const cA = a >> 8, cB = b >> 8;
        for (let c = cA; c <= cB; c++) {
          const d0 = Math.max(a, c * 256) - c * 256;
          const d1 = Math.min(b, c * 256 + 255) - c * 256;
          let arr = perC.get(c);
          if (!arr) { arr = []; perC.set(c, arr); }
          arr.push([d0, d1, recId[k]]);
        }
      }
      j++;
    }
    if (perC.size === 0) continue;

    const A = g >> 8;
    const B = g & 255;
    dirsNeeded.add(A);
    files.push({
      path: path.join(OUT_DIR, String(A), String(B) + '.json'),
      body: buildSixteen(perC, recJson),
    });

    if ((++built % 5000) === 0) {
      process.stdout.write(`  built ${built.toLocaleString()} /16 files\n`);
    }
  }

  // Create the (up to 256) first-octet directories, then write everything.
  console.log(`Creating ${dirsNeeded.size} directories and writing ${files.length.toLocaleString()} files…`);
  for (const A of [...dirsNeeded].sort((a, b) => a - b)) {
    await fsp.mkdir(path.join(OUT_DIR, String(A)), { recursive: true });
  }
  await writeAll(files);

  // Deterministic metadata (no wall-clock time -> stable when the DB is unchanged).
  const meta = {
    format: FORMAT_VERSION,
    source: md.databaseType,
    build_epoch: md.buildEpoch.toISOString(),
    networks: n,
    distinct_records: recJson.length,
    files: files.length,
    schema: {
      file: 'data/<A>/<B>.json is the /16 A.B.0.0/16',
      r: 'array of distinct records used in this /16',
      c: 'array indexed by 3rd octet C; slot = null | int (=> r[int]) | [[startOctet, ri], ...] runs (ri=-1 means no data)',
      record: { country: 'ISO country', region: 'ISO-3166-2 subdivision', city: 'English city name', lat: 'latitude', lon: 'longitude' },
    },
  };
  await fsp.writeFile(path.join(OUT_DIR, 'meta.json'), JSON.stringify(meta, null, 2) + '\n');

  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`Done: ${files.length.toLocaleString()} files in ${OUT_DIR}/ (${secs}s).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
