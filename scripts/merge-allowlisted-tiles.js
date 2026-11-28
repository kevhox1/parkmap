#!/usr/bin/env node
/**
 * scripts/merge-allowlisted-tiles.js  (DT35-7)
 *
 * Limits a tile regen's diff. A full `node build/preprocess.js` re-pulls live Socrata signs, so it
 * also moves faces everywhere that has nothing to do with a geometry fix (live sign churn). This
 * script takes a scratch regen and merges ONLY the segments of the DIVIDED_STREET_ALLOW_LIST streets
 * into an existing tile directory, leaving every other segment (and every tile that has no change on
 * those streets) byte-identical.
 *
 * Usage:
 *   node scripts/merge-allowlisted-tiles.js <targetTilesDir> <scratchRegenDir>
 *
 * Writes into <targetTilesDir> in place: rewrites only tiles whose allow-listed-street content differs,
 * removes tiles that become empty, adds tiles that were empty, refreshes index.json (segmentCount per
 * tile, totalSegments, totalTiles, generatedAt). Afterwards verify with
 *   node scripts/report-tile-changes.js <git baseline copy> <targetTilesDir>
 * and copy the result to ios/WePark/WePark/Resources/tiles/ (they must stay identical).
 *
 * Producing the scratch regen:
 *   TILES_OUTPUT_DIR=/tmp/scratch SIGNS_CACHE_PATH=/tmp/signs.json node build/preprocess.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const pp = require('../build/preprocess.js');

const [target, scratch] = process.argv.slice(2).map(p => p && path.resolve(p));
if (!target || !scratch) { console.error('usage: merge-allowlisted-tiles.js <targetTilesDir> <scratchRegenDir>'); process.exit(2); }
const allowed = pp._DIVIDED_STREET_ALLOW_LIST;
const isAllowed = (street) => allowed.has(pp.canonicalNameForOneway(street));
const tileFiles = (d) => fs.readdirSync(d).filter(f => /^tile_\d+_\d+\.json$/.test(f));
const read = (d, f) => (fs.existsSync(path.join(d, f)) ? JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')) : []);

const names = new Set([...tileFiles(target), ...tileFiles(scratch)]);
const index = JSON.parse(fs.readFileSync(path.join(target, 'index.json'), 'utf8'));
const counts = new Map(index.tiles.map(t => [t.filename, t.segmentCount]));
let rewritten = 0, removed = 0, created = 0;
for (const f of [...names].sort()) {
  const cur = read(target, f), fresh = read(scratch, f);
  const curListed = cur.filter(s => isAllowed(s.street));
  const freshListed = fresh.filter(s => isAllowed(s.street));
  if (JSON.stringify(curListed) === JSON.stringify(freshListed)) continue;
  const merged = cur.filter(s => !isAllowed(s.street)).concat(freshListed);
  const p = path.join(target, f);
  if (merged.length === 0) { fs.unlinkSync(p); counts.delete(f); removed++; continue; }
  if (!fs.existsSync(p)) created++;
  fs.writeFileSync(p, JSON.stringify(merged));
  counts.set(f, merged.length);
  rewritten++;
}
index.tiles = [...counts.entries()].map(([filename, segmentCount]) => {
  const [, row, col] = filename.match(/^tile_(\d+)_(\d+)\.json$/).map(Number);
  return { row, col, filename, segmentCount };
}).sort((a, b) => a.row - b.row || a.col - b.col);
index.totalTiles = index.tiles.length;
index.totalSegments = index.tiles.reduce((n, t) => n + t.segmentCount, 0);
index.generatedAt = new Date().toISOString();
fs.writeFileSync(path.join(target, 'index.json'), JSON.stringify(index, null, 2));
console.log(`merged: ${rewritten} tiles rewritten (${created} new), ${removed} removed; ${index.totalTiles} tiles, ${index.totalSegments} segments`);
