#!/usr/bin/env node
// FT-21 Option A rule-drift proof (docs/ft21-carriageway-investigation.md item 5 /
// docs/brooklyn-expansion-spec.md Stream B0b). Compares two tile-set directories
// built from IDENTICAL input sign data (one with OPTION_A_DISABLED=1, one without —
// see build/preprocess.js's SIGNS_CACHE_PATH / TILES_OUTPUT_DIR / OPTION_A_DISABLED
// env vars) and proves the ONLY difference between them is segment geometry
// (`line`), never rule content (`rules`, `dominantCategory`, `oneway`,
// `oneway_toward`) or which segments exist.
//
// Usage:
//   node scripts/compare-tilesets.js <beforeDir> <afterDir>
//
// Exit code 0 = clean (geometry-only diff, or no diff at all).
// Exit code 1 = a real rule-content drift or segment-count drift was found —
// this is the merge-blocking signal.

const fs = require('fs');
const path = require('path');

function loadTileset(dir) {
  const byId = new Map();
  const files = fs.readdirSync(dir).filter(f => f.startsWith('tile_') && f.endsWith('.json'));
  for (const f of files) {
    const arr = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    for (const seg of arr) {
      if (byId.has(seg.id)) {
        throw new Error(`Duplicate segment id across tiles in ${dir}: ${seg.id}`);
      }
      byId.set(seg.id, seg);
    }
  }
  return byId;
}

function ruleContentEqual(a, b) {
  // Deliberately excludes `line` — geometry is expected to (possibly) differ.
  const aRest = { rules: a.rules, dominantCategory: a.dominantCategory, oneway: a.oneway, oneway_toward: a.oneway_toward, street: a.street, from: a.from, to: a.to, side: a.side };
  const bRest = { rules: b.rules, dominantCategory: b.dominantCategory, oneway: b.oneway, oneway_toward: b.oneway_toward, street: b.street, from: b.from, to: b.to, side: b.side };
  return JSON.stringify(aRest) === JSON.stringify(bRest);
}

function lineEqual(a, b) {
  return JSON.stringify(a.line) === JSON.stringify(b.line);
}

// Rough curb-line displacement between two versions of the same segment:
// mean point-to-point distance at matching indices when lengths match, else
// midpoint-to-midpoint distance (still informative when vertex count changed,
// e.g. via the #9 dedup fix on one side only).
const R = 6371000;
function haversine(a, b) {
  const dLat = (b[0] - a[0]) * Math.PI / 180, dLng = (b[1] - a[1]) * Math.PI / 180;
  const la1 = a[0] * Math.PI / 180, la2 = b[0] * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(la1) * Math.cos(la2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
function displacementMeters(a, b) {
  if (a.line.length === b.line.length) {
    let sum = 0;
    for (let i = 0; i < a.line.length; i++) sum += haversine(a.line[i], b.line[i]);
    return sum / a.line.length;
  }
  const am = a.line[Math.floor(a.line.length / 2)];
  const bm = b.line[Math.floor(b.line.length / 2)];
  return haversine(am, bm);
}

function dupVertexStats(byId) {
  let totalPoints = 0, dupPoints = 0, segsWithDup = 0;
  for (const seg of byId.values()) {
    const line = seg.line;
    if (!line || line.length < 2) continue;
    let hadDup = false;
    for (let i = 1; i < line.length; i++) {
      totalPoints++;
      if (line[i][0] === line[i - 1][0] && line[i][1] === line[i - 1][1]) {
        dupPoints++;
        hadDup = true;
      }
    }
    if (hadDup) segsWithDup++;
  }
  return { totalPoints, dupPoints, segsWithDup, totalSegs: byId.size, pct: totalPoints ? (100 * dupPoints / totalPoints) : 0 };
}

function main() {
  const [, , beforeDir, afterDir] = process.argv;
  if (!beforeDir || !afterDir) {
    console.error('Usage: node scripts/compare-tilesets.js <beforeDir> <afterDir>');
    process.exit(2);
  }

  const before = loadTileset(beforeDir);
  const after = loadTileset(afterDir);

  console.log(`Before (${beforeDir}): ${before.size} segments`);
  console.log(`After  (${afterDir}): ${after.size} segments`);
  console.log('');

  const onlyBefore = [...before.keys()].filter(id => !after.has(id));
  const onlyAfter = [...after.keys()].filter(id => !before.has(id));

  let ruleDrift = 0;
  let geometryMoved = 0;
  let identical = 0;
  const ruleDriftSamples = [];
  const geometrySamples = [];
  let totalDisplacementM = 0;

  for (const [id, a] of before) {
    const b = after.get(id);
    if (!b) continue;
    if (!ruleContentEqual(a, b)) {
      ruleDrift++;
      if (ruleDriftSamples.length < 20) ruleDriftSamples.push({ id, before: a, after: b });
      continue; // don't double-count geometry for a rule-drifted segment
    }
    if (!lineEqual(a, b)) {
      geometryMoved++;
      const d = displacementMeters(a, b);
      totalDisplacementM += d;
      if (geometrySamples.length < 60) {
        geometrySamples.push({ id, street: a.street, from: a.from, to: a.to, side: a.side, displacementM: Math.round(d * 100) / 100 });
      }
    } else {
      identical++;
    }
  }

  console.log('=== Segment identity ===');
  console.log(`Segments only in BEFORE (lost): ${onlyBefore.length}`);
  console.log(`Segments only in AFTER (gained): ${onlyAfter.length}`);
  if (onlyBefore.length) console.log('  sample lost:', onlyBefore.slice(0, 10));
  if (onlyAfter.length) console.log('  sample gained:', onlyAfter.slice(0, 10));
  console.log('');

  console.log('=== Rule-content drift (MUST be zero for a geometry-only PR) ===');
  console.log(`Segments with rule-content drift: ${ruleDrift}`);
  if (ruleDrift) {
    console.log('SAMPLES (first 20):');
    for (const s of ruleDriftSamples) {
      console.log(`  ${s.id}`);
      console.log(`    before: ${JSON.stringify({ rules: s.before.rules, dominantCategory: s.before.dominantCategory })}`);
      console.log(`    after:  ${JSON.stringify({ rules: s.after.rules, dominantCategory: s.after.dominantCategory })}`);
    }
  }
  console.log('');

  console.log('=== Geometry-only changes (expected — this is Option A working) ===');
  console.log(`Segments with identical geometry: ${identical}`);
  console.log(`Segments with MOVED geometry (line differs, rules identical): ${geometryMoved}`);
  console.log(`Mean displacement across moved segments: ${geometryMoved ? (totalDisplacementM / geometryMoved).toFixed(2) : 0} m`);
  const movedStreets = [...new Set(geometrySamples.map(s => s.street))].sort();
  console.log(`Distinct streets with moved geometry (sampled, first 60 segments): ${movedStreets.join(', ')}`);
  console.log('Sample moved segments:');
  for (const s of geometrySamples.slice(0, 20)) {
    console.log(`  ${s.street} (${s.from} to ${s.to}) [${s.side}] — moved ${s.displacementM} m`);
  }
  console.log('');

  console.log('=== Duplicate-adjacent-vertex rate (open-items #9) ===');
  const dupBefore = dupVertexStats(before);
  const dupAfter = dupVertexStats(after);
  console.log(`Before: ${dupBefore.dupPoints}/${dupBefore.totalPoints} duplicate-adjacent points (${dupBefore.pct.toFixed(1)}%), ${dupBefore.segsWithDup}/${dupBefore.totalSegs} segments affected`);
  console.log(`After:  ${dupAfter.dupPoints}/${dupAfter.totalPoints} duplicate-adjacent points (${dupAfter.pct.toFixed(1)}%), ${dupAfter.segsWithDup}/${dupAfter.totalSegs} segments affected`);
  console.log('');

  const clean = ruleDrift === 0 && onlyBefore.length === 0 && onlyAfter.length === 0;
  console.log(clean
    ? '✅ RULE-DRIFT PROOF: PASS — zero rule-content drift, zero segment-identity drift. All differences are geometry-only.'
    : '❌ RULE-DRIFT PROOF: FAIL — rule content and/or segment identity changed. This is NOT a geometry-only diff. Do not merge.');

  process.exit(clean ? 0 : 1);
}

main();
