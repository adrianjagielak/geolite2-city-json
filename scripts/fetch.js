#!/usr/bin/env node
'use strict';

/*
 * Downloads and decompresses the GeoLite2-City database used by the generator.
 * Mirrors what the GitHub Action does, for convenient local testing.
 *
 *   node scripts/fetch.js   ->   ./GeoLite2-City.mmdb
 */

const fs = require('fs');
const zlib = require('zlib');
const { pipeline } = require('stream/promises');

const URL = process.env.MMDB_URL ||
  'https://cdn.jsdelivr.net/npm/geolite2-city/GeoLite2-City.mmdb.gz';
const OUT = process.env.MMDB_PATH || 'GeoLite2-City.mmdb';

async function main() {
  console.log(`Downloading ${URL} …`);
  const res = await fetch(URL);
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
  await pipeline(
    // Node's fetch body is a web ReadableStream; Readable.fromWeb bridges it.
    require('stream').Readable.fromWeb(res.body),
    zlib.createGunzip(),
    fs.createWriteStream(OUT)
  );
  const { size } = fs.statSync(OUT);
  console.log(`Wrote ${OUT} (${(size / 1048576).toFixed(1)} MiB).`);
}

main().catch((e) => { console.error(e); process.exit(1); });
