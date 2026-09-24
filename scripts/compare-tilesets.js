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

// Curb-line displacement between two versions of the same segment.
//
// FIX (QA pass 1, docs/qa/pr116-ft21-option-a.md finding #1): the original
// implementation compared points at matching array INDICES, falling back to
// comparing the single point at Math.floor(length/2) on each line whenever
// vertex counts differed. That fallback fired on 158/355 (44.5%) of moved
// segments in the PR's own regen (the #9 dedup fix routinely drops a
// near-duplicate point on only one side of a before/after pair) and produced
// numbers with no real geometric meaning — index-midpoint is not
// arc-length-midpoint, and neither is a true point-to-polyline distance.
// QA's repro: BROADWAY_LA_SALLE_STREET_WEST_122ND_STREET_W_0 reported 62.14m
// under the old metric; true displacement is 5.77-5.84m.
//
// FIX: mean point-to-polyline nearest-distance, one-directional — for every
// vertex of the AFTER line, find its nearest point anywhere on the BEFORE
// polyline (point-to-segment, minimized over all of its segments), then
// average those distances. This directly answers "how far did Option A move
// this curb from where it used to sit," is robust to differing vertex counts
// on either side (no index correspondence needed), and matches QA's own
// independently-derived methodology exactly ("each after-vertex's
// perpendicular distance to the before-polyline") — verified against their
// reported mean (7.37m) on this PR's own controlled A/B, reproduced exactly.
// (A symmetric before<->after average was tried first and rejected: it
// dilutes the answer to "how far apart are these two lines" rather than "how
// far did the new line move from the old one," and doesn't match QA's number.)
const R = 6371000;
function haversine(a, b) {
  const dLat = (b[0] - a[0]) * Math.PI / 180, dLng = (b[1] - a[1]) * Math.PI / 180;
  const la1 = a[0] * Math.PI / 180, la2 = b[0] * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(la1) * Math.cos(la2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
function pointToSegmentDist(p, segA, segB) {
  const abLat = segB[0] - segA[0], abLng = segB[1] - segA[1];
  const apLat = p[0] - segA[0], apLng = p[1] - segA[1];
  const ab2 = abLat * abLat + abLng * abLng;
  let t = ab2 > 0 ? (apLat * abLat + apLng * abLng) / ab2 : 0;
  t = Math.max(0, Math.min(1, t));
  const projLat = segA[0] + t * abLat, projLng = segA[1] + t * abLng;
  return haversine(p, [projLat, projLng]);
}
function pointToPolylineDist(p, poly) {
  if (poly.length === 1) return haversine(p, poly[0]);
  let best = Infinity;
  for (let i = 0; i < poly.length - 1; i++) {
    const d = pointToSegmentDist(p, poly[i], poly[i + 1]);
    if (d < best) best = d;
  }
  return best;
}
function displacementMeters(a, b) {
  const distsAfterToBefore = b.line.map(p => pointToPolylineDist(p, a.line));
  return distsAfterToBefore.reduce((sum, d) => sum + d, 0) / distsAfterToBefore.length;
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
  let maxDisplacementM = 0;
  let maxDisplacementSample = null;
  // Outliers computed across ALL moved segments, not just the first-60 sample
  // list below — a rare large mover could otherwise hide past the sample cap.
  const OUTLIER_THRESHOLD_M = 30;
  const outliers = [];

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
      if (d > maxDisplacementM) {
        maxDisplacementM = d;
        maxDisplacementSample = { id, street: a.street, from: a.from, to: a.to, side: a.side };
      }
      if (d > OUTLIER_THRESHOLD_M) {
        outliers.push({ id, street: a.street, from: a.from, to: a.to, side: a.side, displacementM: Math.round(d * 100) / 100 });
      }
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
  console.log(`Mean displacement across moved segments (after-vertex -> before-polyline distance): ${geometryMoved ? (totalDisplacementM / geometryMoved).toFixed(2) : 0} m`);
  console.log(`Max displacement across ALL moved segments (not just the sample below): ${maxDisplacementM.toFixed(2)} m` +
    (maxDisplacementSample ? ` — ${maxDisplacementSample.street} (${maxDisplacementSample.from} to ${maxDisplacementSample.to}) [${maxDisplacementSample.side}]` : ''));
  console.log(`Outliers over ${OUTLIER_THRESHOLD_M}m (checked across ALL moved segments): ${outliers.length}`);
  for (const o of outliers) {
    console.log(`  OUTLIER: ${o.street} (${o.from} to ${o.to}) [${o.side}] — ${o.displacementM} m`);
  }
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
