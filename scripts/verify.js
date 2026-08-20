#!/usr/bin/env node
'use strict';

/*
 * Verifies the generated JSON tree against the source .mmdb by resolving many
 * addresses both ways and comparing. Implements the exact consumer lookup
 * documented in the README, so it doubles as a reference implementation.
 */

const fs = require('fs');
const path = require('path');
const maxmind = require('maxmind');

const DB_PATH = process.env.MMDB_PATH || 'GeoLite2-City.mmdb';
const OUT_DIR = process.env.OUT_DIR || 'data';
const N = parseInt(process.env.SAMPLES || '2000000', 10);

// Same minimal-record projection the generator uses.
function minimalRecord(d) {
  if (!d) return null;
  const out = {};
  const country =
    (d.country && d.country.iso_code) ||
    (d.registered_country && d.registered_country.iso_code);
  if (country) out.c = country;
  if (d.subdivisions && d.subdivisions.length) {
    const region = d.subdivisions[0].iso_code;
    if (region) out.r = region;
  }
  if (d.city && d.city.names && d.city.names.en) out.t = d.city.names.en;
  if (d.location) {
    if (typeof d.location.latitude === 'number') out.y = d.location.latitude;
    if (typeof d.location.longitude === 'number') out.x = d.location.longitude;
    if (typeof d.location.accuracy_radius === 'number') out.a = d.location.accuracy_radius;
  }
  return Object.keys(out).length ? out : null;
}

// --- The documented consumer lookup -----------------------------------------
const fileCache = new Map();
function loadFile(A, B) {
  const key = A * 256 + B;
  if (fileCache.has(key)) return fileCache.get(key);
  const fp = path.join(OUT_DIR, String(A), String(B) + '.json');
  let val = null;
  if (fs.existsSync(fp)) val = JSON.parse(fs.readFileSync(fp, 'utf8'));
  fileCache.set(key, val);
  return val;
}

function lookup(A, B, C, D) {
  const file = loadFile(A, B);
  if (!file) return null;
  const cd = file.c[C];
  if (cd === undefined || cd === null) return null;
  if (typeof cd === 'number') return file.r[cd];
  // run-list: greatest startOctet <= D
  let lo = 0, hi = cd.length - 1, ans = 0;
  while (lo <= hi) {
    const m = (lo + hi) >> 1;
    if (cd[m][0] <= D) { ans = m; lo = m + 1; } else hi = m - 1;
  }
  const ri = cd[ans][1];
  return ri < 0 ? null : file.r[ri];
}
// ----------------------------------------------------------------------------

function ipStr(a, b, c, d) { return `${a}.${b}.${c}.${d}`; }

async function main() {
  const reader = await maxmind.open(DB_PATH);

  let checked = 0, mism = 0;
  const examples = [];

  function check(a, b, c, d) {
    const expected = minimalRecord(reader.get(ipStr(a, b, c, d)));
    const got = lookup(a, b, c, d);
    checked++;
    const e = expected ? JSON.stringify(expected) : null;
    const g = got ? JSON.stringify(got) : null;
    if (e !== g) {
      mism++;
      if (examples.length < 20) examples.push({ ip: ipStr(a, b, c, d), expected: e, got: g });
    }
  }

  // 1) Deterministic edge cases.
  const edge = [
    [0,0,0,0],[8,8,8,8],[1,1,1,1],[1,2,3,4],[9,9,9,9],
    [77,236,25,0],[77,236,25,1],[77,236,25,255],[78,31,0,1],
    [255,255,255,255],[100,64,0,1],[169,254,0,1],[192,168,0,1],
    [10,0,0,0],[172,16,0,0],[224,0,0,1],[203,0,113,7],
  ];
  for (const [a,b,c,d] of edge) check(a,b,c,d);

  // 2) A full /24 sweep (all 256 octets) on a known-good block.
  for (let d = 0; d < 256; d++) check(77, 236, 25, d);

  // 3) Random sample across the whole IPv4 space.
  //    Deterministic LCG so the run is reproducible.
  let seed = 0x12345678 >>> 0;
  const rnd = () => (seed = (seed * 1103515245 + 12345) >>> 0);
  for (let i = 0; i < N; i++) {
    const r = rnd();
    const a = (r >>> 24) & 255, b = (r >>> 16) & 255, c = (r >>> 8) & 255;
    const d = rnd() & 255;
    check(a, b, c, d);
  }

  console.log(`Checked ${checked.toLocaleString()} addresses — ${mism} mismatches.`);
  if (mism) {
    console.log('\nFirst mismatches:');
    for (const e of examples) console.log(`  ${e.ip}\n    expected: ${e.expected}\n    got:      ${e.got}`);
    process.exit(1);
  }
  console.log('OK: file tree matches the mmdb for every sampled address.');
}

main().catch((e) => { console.error(e); process.exit(1); });
