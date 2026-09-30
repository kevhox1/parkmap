#!/usr/bin/env node
/**
 * scripts/test-pipeline-determinism.js
 *
 * Open item #27 regression gate — see docs/open-items.md #27,
 * docs/qa/pr117-arrow-direction.md (Finding #4, where this was first surfaced), and
 * docs/ft21-width-offset-investigation.md §4 (why it gates the width-offset work).
 *
 * THE BUG (fixed in build/preprocess.js's findIntersection(), see its own header
 * comment for the full mechanism): findIntersection(street1, street2) memoized its
 * result under a CANONICAL, order-independent cache key
 * (`[street1, street2].sort().join('|')`), but the search itself walked street1/
 * street2 in whatever raw argument order the CALLER used, not the sorted order the
 * cache key implies. For the overwhelming majority of street pairs — which have
 * exactly one real geometric crossing — that mismatch is invisible. It is NOT
 * invisible for a street pair with more than one exact (dist === 0) crossing
 * candidate, which happens when a street's OSM way is fragmented into several chains
 * that pass close to one another near an intersection (Delancey St is the confirmed
 * case: its OSM geometry crosses Essex St's single chain at two distinct exact points
 * ~17m apart). The search breaks that tie by "first exact match wins," and which
 * candidate is found first depends on which street drives the outer vs inner loop —
 * i.e. on which BLOCK happened to call findIntersection() for that street pair first
 * in a given run. Confirmed repro: processing an "Essex Street (Rivington Street to
 * Delancey Street)"-shaped block before "Delancey Street (Ludlow Street to Essex
 * Street) [S]" corrupts the latter from a correct ~175ft/53m block face to a
 * ~3,154ft/961m one, by walking ~70 extra vertices along Delancey's own fragmented
 * chain that have nothing to do with this block.
 *
 * This script is deliberately independent of live NYC sign data (none of it is
 * available outside a real regen) — it drives build/preprocess.js's own exported
 * getBlockPolyline()/findIntersection() surface directly against the committed
 * osm_data.json, so it can run cheaply and offline as a standing regression gate.
 *
 * WHAT IT PROVES:
 *   1. The exact historical Delancey/Essex repro no longer reproduces (pinned case).
 *   2. A broad, real (not synthetic) pool of Manhattan block candidates — built from
 *      osm_data.json's own intersections, validated via the real findIntersection() —
 *      returns byte-identical getBlockPolyline() output for every block, across many
 *      independently-shuffled processing orders. Any mismatch is a NEW instance of the
 *      #27 class of bug and must block a regen.
 *
 * Usage:   node scripts/test-pipeline-determinism.js
 * Exit 0 = deterministic (safe to trust compare-tilesets.js diffs against a regen
 *          that touches getBlockPolyline()'s helper chain).
 * Exit 1 = FAIL — do not trust regen diffs until this passes again.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OSM_DATA_PATH = path.join(ROOT, 'osm_data.json');

const pp = require(path.join(ROOT, 'build', 'preprocess.js'));
const { initStreets, clearGeometryCaches, getBlockPolyline, findIntersection } = pp;

if (!fs.existsSync(OSM_DATA_PATH)) {
  console.error(`ERROR: ${OSM_DATA_PATH} not found — cannot run the determinism harness.`);
  process.exit(1);
}
const osmData = JSON.parse(fs.readFileSync(OSM_DATA_PATH, 'utf8'));

// ---------------------------------------------------------------------------
// Deterministic PRNG (mulberry32) so the harness's own "randomness" is
// reproducible across CI runs — only the PROCESSING ORDER should exercise
// randomness, never the test harness's own control flow.
// ---------------------------------------------------------------------------
function makeRng(seed) {
  let a = seed >>> 0;
  return function rng() {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function shuffle(arr, rng) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    const tmp = a[i]; a[i] = a[j]; a[j] = tmp;
  }
  return a;
}

function makeBlock(street, from, to) {
  return { street: street.toUpperCase(), from: from.toUpperCase(), to: to.toUpperCase() };
}
function blockKey(b) { return `${b.street} (${b.from} to ${b.to})`; }

// Serialize a getBlockPolyline() result to a form suitable for byte-identical
// comparison (JSON.stringify is sufficient here — the fix doesn't touch anything
// that would produce equivalent-but-differently-ordered output).
function serializeGeo(geo) {
  if (!geo) return 'null';
  return JSON.stringify({ line: geo.line, blockLenFt: geo.blockLenM !== undefined ? geo.blockLenFt : null });
}

// ---------------------------------------------------------------------------
// 1. Pinned historical regression: the exact Delancey/Essex repro.
// ---------------------------------------------------------------------------
const PINNED_TARGET = makeBlock('Delancey Street', 'Ludlow Street', 'Essex Street');
const PINNED_POISONER = makeBlock('Essex Street', 'Rivington Street', 'Delancey Street');
// Ground truth: this Delancey block is one Manhattan block face (Ludlow -> Essex are
// adjacent LES cross streets), so it must be well under 300ft. The corrupted value
// this bug historically produced was ~3,154ft (~961m) — walking ~70 unrelated
// vertices along Delancey's own fragmented OSM chain.
const PINNED_MAX_PLAUSIBLE_FT = 300;

function runPinnedRegression() {
  console.log('=== 1. Pinned regression: Delancey St (Ludlow to Essex) [S] ===');

  initStreets(osmData);
  const isolatedGeo = getBlockPolyline(PINNED_TARGET);
  if (!isolatedGeo) {
    console.error('FAIL: isolated call to getBlockPolyline() for the pinned target returned null.');
    return false;
  }
  console.log(`  isolated (fresh cache):      ${isolatedGeo.blockLenFt.toFixed(2)}ft, ${isolatedGeo.line.length} pts`);

  initStreets(osmData); // fresh cache
  getBlockPolyline(PINNED_POISONER); // process the historically-poisoning block FIRST
  const afterGeo = getBlockPolyline(PINNED_TARGET);
  if (!afterGeo) {
    console.error('FAIL: getBlockPolyline() for the pinned target returned null after the poisoner block.');
    return false;
  }
  console.log(`  after poisoner block first:  ${afterGeo.blockLenFt.toFixed(2)}ft, ${afterGeo.line.length} pts`);

  const identical = serializeGeo(isolatedGeo) === serializeGeo(afterGeo);
  const plausible = afterGeo.blockLenFt < PINNED_MAX_PLAUSIBLE_FT;

  if (!identical) {
    console.error(`FAIL: pinned regression reproduced — isolated (${isolatedGeo.blockLenFt.toFixed(2)}ft) != after-poisoner (${afterGeo.blockLenFt.toFixed(2)}ft).`);
    return false;
  }
  if (!plausible) {
    console.error(`FAIL: pinned target's length (${afterGeo.blockLenFt.toFixed(2)}ft) exceeds the plausibility ceiling (${PINNED_MAX_PLAUSIBLE_FT}ft) for a single LES block face.`);
    return false;
  }
  console.log('  PASS — identical, and within the plausible single-block-face range.\n');
  return true;
}

// ---------------------------------------------------------------------------
// 2. Broad fuzz pool: real block candidates derived from osm_data.json's own
//    intersections (validated via the real, exported findIntersection()).
// ---------------------------------------------------------------------------
function bbox(chains) {
  let minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
  for (const c of chains) for (const [lat, lng] of c) {
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lng < minLng) minLng = lng;
    if (lng > maxLng) maxLng = lng;
  }
  return { minLat, maxLat, minLng, maxLng };
}

// Spatial grid bucketing so we don't pay O(streets^2) to find candidate cross
// streets. Cell size ~0.003deg (~300m at Manhattan's latitude) is coarse enough
// that any two streets that actually cross will share at least one cell.
const CELL = 0.003;
function cellsForBbox(bb) {
  const cells = [];
  for (let x = Math.floor(bb.minLng / CELL); x <= Math.floor(bb.maxLng / CELL); x++) {
    for (let y = Math.floor(bb.minLat / CELL); y <= Math.floor(bb.maxLat / CELL); y++) {
      cells.push(`${x},${y}`);
    }
  }
  return cells;
}

function buildFuzzPool(maxPoolSize, rng) {
  const streetNames = Object.keys(osmData);
  const bboxes = {};
  const grid = new Map();
  for (const s of streetNames) {
    const bb = bbox(osmData[s]);
    bboxes[s] = bb;
    for (const c of cellsForBbox(bb)) {
      if (!grid.has(c)) grid.set(c, []);
      grid.get(c).push(s);
    }
  }

  const candidateSetFor = (s) => {
    const bb = bboxes[s];
    const out = new Set();
    for (const c of cellsForBbox(bb)) {
      for (const t of grid.get(c) || []) if (t !== s) out.add(t);
    }
    return [...out];
  };

  initStreets(osmData);
  const pool = [];
  const shuffledStreets = shuffle(streetNames, rng);
  let scanned = 0;
  for (const s of shuffledStreets) {
    if (pool.length >= maxPoolSize) break;
    scanned++;
    // Skip streets whose bounding box is huge (avenues, highways spanning miles) —
    // they blow up candidateSetFor()'s grid-cell fan-out without adding meaningfully
    // different determinism coverage over the many smaller streets in the pool.
    const bb0 = bboxes[s];
    if ((bb0.maxLat - bb0.minLat) > 0.02 || (bb0.maxLng - bb0.minLng) > 0.02) continue;
    // Cap the candidate set BEFORE validating — validation calls the real
    // findIntersection(), which is O(segs1 * segs2) on a cache miss.
    const cands = shuffle(candidateSetFor(s), rng).slice(0, 25);
    if (cands.length < 2) continue;
    // Try a handful of candidate cross-street pairs per street; keep the first
    // 1-2 that resolve to a REAL intersection on both ends (validated, not assumed).
    let addedForThisStreet = 0;
    for (let i = 0; i < cands.length - 1 && addedForThisStreet < 2 && pool.length < maxPoolSize; i++) {
      const from = cands[i], to = cands[i + 1];
      if (findIntersection(s, from) && findIntersection(s, to)) {
        pool.push(makeBlock(s, from, to));
        addedForThisStreet++;
      }
    }
    if (scanned % 200 === 0) {
      process.stderr.write(`  ...scanned ${scanned} streets, pool at ${pool.length}/${maxPoolSize}\r`);
    }
  }
  process.stderr.write('\n');
  return pool;
}

function runFuzzTrials(pool, trialCount, rng) {
  console.log(`=== 2. Fuzz pool: ${pool.length} real block candidates, ${trialCount} shuffled trials ===`);

  // Always include the two pinned blocks in the fuzz pool too, so the general
  // fuzz path also covers the historical case under many MORE orderings than the
  // single hand-picked one above.
  const fullPool = [PINNED_TARGET, PINNED_POISONER, ...pool];

  const baseline = new Map(); // blockKey -> serialized geometry (from trial 0)
  let mismatches = [];

  for (let trial = 0; trial < trialCount; trial++) {
    initStreets(osmData); // fresh caches — no leakage between trials
    const order = shuffle(fullPool, rng);
    const results = new Map();
    for (const b of order) {
      const geo = getBlockPolyline(b);
      results.set(blockKey(b), serializeGeo(geo));
    }

    if (trial === 0) {
      for (const [k, v] of results) baseline.set(k, v);
    } else {
      for (const [k, v] of results) {
        const base = baseline.get(k);
        if (base !== undefined && base !== v) {
          mismatches.push({ trial, key: k, expected: base, got: v });
        }
      }
    }
  }

  if (mismatches.length > 0) {
    console.error(`FAIL: ${mismatches.length} block(s) produced non-deterministic geometry across trials:`);
    const shown = mismatches.slice(0, 10);
    for (const m of shown) {
      console.error(`  trial ${m.trial}: "${m.key}"`);
      console.error(`    expected: ${m.expected.slice(0, 200)}`);
      console.error(`    got:      ${m.got.slice(0, 200)}`);
    }
    if (mismatches.length > shown.length) console.error(`  ... and ${mismatches.length - shown.length} more.`);
    return false;
  }

  console.log(`  PASS — ${fullPool.length} blocks x ${trialCount} independently-shuffled trials, all byte-identical.\n`);
  return true;
}

function main() {
  const seedArg = process.argv.find(a => a.startsWith('--seed='));
  const poolArg = process.argv.find(a => a.startsWith('--pool='));
  const trialsArg = process.argv.find(a => a.startsWith('--trials='));
  // Defaults chosen to comfortably finish in well under a minute (verified
  // ~15-20s locally) so this is cheap enough to run on every regen and every QA
  // pass, not just once. Pass --pool=/--trials= for a more thorough run (e.g.
  // --pool=300 --trials=15 takes ~90-120s and was used to validate this harness).
  const seed = seedArg ? parseInt(seedArg.split('=')[1], 10) : 42;
  const poolSize = poolArg ? parseInt(poolArg.split('=')[1], 10) : 200;
  const trials = trialsArg ? parseInt(trialsArg.split('=')[1], 10) : 10;

  console.log('Pipeline determinism harness (#27 regression gate)');
  console.log(`osm_data.json: ${OSM_DATA_PATH}`);
  console.log(`seed=${seed} poolSize=${poolSize} trials=${trials}\n`);

  const pinnedOk = runPinnedRegression();

  const rng = makeRng(seed);
  const pool = buildFuzzPool(poolSize, rng);
  const fuzzOk = runFuzzTrials(pool, trials, rng);

  if (pinnedOk && fuzzOk) {
    console.log('RESULT: PASS — getBlockPolyline() is deterministic under permuted processing order.');
    process.exit(0);
  } else {
    console.error('RESULT: FAIL — do not trust compare-tilesets.js output until this passes.');
    process.exit(1);
  }
}

main();
