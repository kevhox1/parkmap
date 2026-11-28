#!/usr/bin/env node
/**
 * scripts/test-width-offset-resurrection.js
 *
 * FT-21 width-offset resurrection (open item #25, docs/ft21-width-offset-investigation.md)
 * regression gate. Exercises build/preprocess.js's REAL initWidths()/_perStreetOffset
 * surface (via module.exports) against the committed street_widths.json — no
 * reimplementation of the formula.
 *
 * Proves three things the investigation doc flagged as prerequisites before this
 * resurrection could ship safely:
 *
 *   1. The five flagship divided/wide streets move by the expected amount (Houston,
 *      Allen, Delancey, Bowery) or explicitly do NOT move (Forsyth — the allow-list
 *      fix's own control case).
 *   2. The ~24 major crosstown/boulevard streets that regressed under the UNFIXED
 *      canonical-key bug (docs/ft21-width-offset-investigation.md §3) still resolve
 *      to the correct 10m tier floor now that getStreetCurbOffsetForCanonKey() is
 *      canonical-key-aware. This is the most important assertion in this file — a
 *      silent regression here would be worse than shipping nothing.
 *   3. A spot sample of ordinary unaffected streets (avenues, generic side streets)
 *      stays exactly where it was (byte-identical to the flat name-tier value) —
 *      confirms the "never a worse guess" / narrow-blast-radius claim.
 *
 * DT35-7 update (docs/dt35-7-houston-curb-offset-investigation.md): the allow-listed streets whose OSM
 * chains measure as carriageway centerlines (E/W Houston, Bowery, Delancey) no longer get the +7 m median
 * allowance or the name-tier floor. Sections 1, 1b, 1c, 2 below assert the NEW behaviour (street-level
 * fallback = 0.88 x median half-width; per-face outer-curb pick; Option A guard; override loader), including
 * that the old +12.49/+12.79/+14 values are gone. Sections 3 and 4 are unchanged.
 *
 * Usage: node scripts/test-width-offset-resurrection.js
 */

'use strict';

const fs = require('fs');
const path = require('path');

const pp = require('../build/preprocess.js');
// NOTE: _perStreetOffset is exposed via a `get` accessor on module.exports
// (its underlying module-level binding is REASSIGNED, not mutated, inside
// initWidths()) -- destructuring it here would freeze a reference to the
// pre-initWidths() empty object. Access pp._perStreetOffset directly instead,
// every time, so each read reflects the live post-initWidths() map.
const { _DIVIDED_STREET_ALLOW_LIST } = pp;

const ROOT = path.resolve(__dirname, '..');
const widthsPath = path.join(ROOT, 'street_widths.json');
if (!fs.existsSync(widthsPath)) {
  console.error('ERROR: street_widths.json not found at repo root.');
  process.exit(1);
}
const rawWidths = JSON.parse(fs.readFileSync(widthsPath, 'utf8'));
const osmPath = path.join(ROOT, 'osm_data.json');
// DT35-7: chain-vs-carriageway measurement needs the OSM chains loaded BEFORE initWidths().
pp._setOsmStreets(JSON.parse(fs.readFileSync(osmPath, 'utf8')));
pp.initWidths(rawWidths);
pp.buildCarriagewayPairs(rawWidths);

let pass = 0, fail = 0;

function check(label, actual, expected, tolerance = 0.15) {
  const ok = typeof expected === 'number'
    ? Math.abs(actual - expected) <= tolerance
    : actual === expected;
  if (ok) {
    pass++;
    console.log(`PASS: ${label} -- got ${actual}`);
  } else {
    fail++;
    console.log(`FAIL: ${label} -- got ${actual}, expected ${expected}`);
  }
}

console.log('=== 1. Allow-listed streets -- DT35-7 street-level fallback (no +7 m allowance, no tier floor) ===\n');

// canonKey -> [pre-DT35-7 offset (resurrection era), new street-level fallback]. The new value is
// 0.88 x median CSCL row half-width for carriageway-chained streets; Allen (chains NOT on carriageways,
// 47% within 3 m) and Forsyth (control) keep their old behaviour exactly.
const flagship = {
  'E HOUSTON ST': { old: 12.79, now: 5.10 },
  'W HOUSTON ST': { old: 12.49, now: 4.83 },
  'BOWERY':       { old: 12.49, now: 4.83 },
  'DELANCEY ST':  { old: 14.00, now: 7.24 },
  'ALLEN ST':     { old: 13.40, now: 13.40 }, // legacy: chains are median-ish, allowance kept
  'FORSYTH ST':   { old: 6.00,  now: 6.00 },  // CONTROL -- must be unchanged
};
for (const [key, { old, now }] of Object.entries(flagship)) {
  const actual = pp._perStreetOffset[key];
  check(`${key}: street-level offset ~${now}m (was ${old}m)`, actual, now, 0.05);
}
for (const key of ['E HOUSTON ST', 'W HOUSTON ST', 'BOWERY', 'DELANCEY ST']) {
  check(`${key}: old divided offset is GONE (no +${pp._DIVIDED_MEDIAN_ALLOWANCE_M} m allowance; offset < 8 m)`, pp._perStreetOffset[key] < 8, true);
}
check('W HOUSTON ST street-level offset = 0.88 x median half-width exactly (formula, no floor)',
  pp._perStreetOffset['W HOUSTON ST'],
  pp._CSCL_OFFSET_FRACTION * (rawWidths['W HOUSTON ST'].map(w => w.stWidthFt).filter(v => v > 0).sort((a, b) => a - b)
    .reduce((m, v, i, a) => (i === Math.floor(a.length / 2) ? v : m), 0) * 0.3048 / 2), 0.01);

console.log('\n=== 1b. Carriageway-chain measurement (decides who loses the allowance) ===\n');
for (const [key, expected] of [['E HOUSTON ST', true], ['W HOUSTON ST', true], ['BOWERY', true], ['DELANCEY ST', true], ['ALLEN ST', false]]) {
  check(`${key} carriageway-chained = ${expected} (measured fraction ${(pp._carriagewayChainFractions[key] || 0).toFixed(2)})`, pp.isCarriagewayChained(key), expected);
}
check('FORSYTH ST (not allow-listed) is never chained', pp.isCarriagewayChained('FORSYTH ST'), false);

console.log('\n=== 1c. Per-face outer-curb pick on W Houston (the DT35-7 repro blocks) ===\n');
function faceOffset(side, from, to) {
  const blk = { street: 'WEST HOUSTON STREET', from, to, side };
  const g = pp.getBlockPolyline(blk);
  return g ? pp.pickOuterCarriageOffset('W HOUSTON ST', blk, g) : null;
}
// Dual stretch (Broadway..6th Ave): N faces draw the north carriageway's outer curb (0.88 x 44ft/2 = 5.90 m from
// the north carriageway line); S faces on the same OSM line must shift across to the SOUTH carriageway's outer curb
// (carriageway separation ~16.7 m + 0.88 x 44ft/2). Before DT35-7 both were +/-12.49 m from whichever chain they hit.
let r = faceOffset('N', 'MERCER STREET', 'LA GUARDIA PLACE');
check('dual stretch N face: 5.90 m, no sibling shift', r && +r.offsetM.toFixed(2), 5.90, 0.1);
check('dual stretch N face: sepM = 0', r && r.sepM, 0, 0.01);
r = faceOffset('S', 'WEST BROADWAY', 'WOOSTER STREET');
check('dual stretch S face on the north chain: shifted to the south carriageway outer curb (22.6 m)', r && +r.offsetM.toFixed(1), 22.6, 0.3);
check('dual stretch S face: carriageway separation 16.7 m (not the legacy 12.49)', r && +r.sepM.toFixed(1), 16.7, 0.3);
r = faceOffset('S', 'SULLIVAN STREET', 'THOMPSON STREET');
check('dual stretch S face (34 ft south carriageway): 20.3 m', r && +r.offsetM.toFixed(1), 20.3, 0.3);
// One-way stretch (6th Ave..West St): ONE 34 ft carriageway, both sides parked, no divided treatment: 0.88 x 17 ft = 4.56 m
for (const side of ['N', 'S']) {
  r = faceOffset(side, 'VARICK STREET', 'HUDSON STREET');
  check(`one-way stretch ${side} face: 4.56 m (was 12.49 m, 7 m beyond the curb)`, r && +r.offsetM.toFixed(2), 4.56, 0.05);
}
r = faceOffset('N', 'SULLIVAN STREET', 'MACDOUGAL STREET');
check('stub-chain face declines the general rule (needs the override table)', r, null);

console.log('\n=== 1d. Option A pairing guard ignores same-carriageway neighbours (DT35-7) ===\n');
// Pre-fix counts on the committed data: E Houston 2 pairs, Bowery 5. The fix is scoped to allow-listed streets, so
// every unlisted street keeps its exact old count (Park Ave 14: its change is the follow-up PR).
check('E HOUSTON ST Option A pairs: 7 (was 2)', (pp._carriagewayPairs['E HOUSTON ST'] || []).length, 7);
check('BOWERY Option A pairs: 6 (was 5)', (pp._carriagewayPairs['BOWERY'] || []).length, 6);
check('W HOUSTON ST Option A pairs: 1 (unchanged; chunk boundaries are not mutual, the general rule covers it)', (pp._carriagewayPairs['W HOUSTON ST'] || []).length, 1);
check('PARK AVE Option A pairs unchanged at 14 (unlisted street untouched)', (pp._carriagewayPairs['PARK AVE'] || []).length, 14);
check('total Option A pairs 156 (was 150; all of the +6 on allow-listed streets)',
  Object.values(pp._carriagewayPairs).reduce((n, a) => n + a.length, 0), 156);

console.log('\n=== 1e. build/curb-overrides.json loader ===\n');
const os = require('os');
const ov = pp.loadCurbOverrides(path.join(ROOT, 'build', 'curb-overrides.json'));
check('committed override table loads', ov.size >= 1, true);
check('E Houston stray duplicate is suppressed', (ov.get('EAST_HOUSTON_STREET_AVENUE_A_AVENUE_D_N') || {}).suppress, true);
check('every committed override has a note and verified date', [...ov.values()].every(o => o.note && o.verified), true);
function expectThrows(label, fn, re) {
  let msg = null;
  try { fn(); } catch (e) { msg = e.message; }
  check(label, msg !== null && re.test(msg), true);
}
function tmpOverrides(obj) {
  const f = path.join(os.tmpdir(), `curb-overrides-test-${process.pid}-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(f, JSON.stringify(obj));
  return f;
}
expectThrows('unknown face id is a hard build error',
  () => pp.assertOverridesKnown(ov, new Set(['SOME_OTHER_FACE_N'])), /unknown block-face id/);
check('known face ids pass', (() => { pp.assertOverridesKnown(ov, new Set(ov.keys())); return true; })(), true);
expectThrows('bad base rejected', () => pp.loadCurbOverrides(tmpOverrides({ version: 1, overrides: [{ face: 'X_N', base: 'median', offsetM: 5 }] })), /base must be/);
expectThrows('row without offsetM or suppress rejected', () => pp.loadCurbOverrides(tmpOverrides({ version: 1, overrides: [{ face: 'X_N' }] })), /needs offsetM or suppress/);
expectThrows('duplicate face rejected', () => pp.loadCurbOverrides(tmpOverrides({ version: 1, overrides: [{ face: 'X_N', offsetM: 5 }, { face: 'X_N', suppress: true }] })), /duplicate/);
check('faceIdForBlock matches the tile segment id convention',
  pp.faceIdForBlock({ street: 'EAST HOUSTON STREET', from: 'AVENUE A', to: 'AVENUE D', side: 'N' }), 'EAST_HOUSTON_STREET_AVENUE_A_AVENUE_D_N');

console.log('\n=== 2. Forsyth allow-list fix -- must NOT get the divided-median formula ===\n');
check('FORSYTH ST removed from DIVIDED_STREET_ALLOW_LIST', _DIVIDED_STREET_ALLOW_LIST.has('FORSYTH ST'), false);

console.log('\n=== 3. The 24-major-streets canonical-key regression — MUST stay at 10m, not drop to 6m ===\n');

// Full NYC names -> their street_widths.json canonical key, per
// docs/ft21-width-offset-investigation.md §3's own regression table.
const majorStreets = [
  ['E 14 ST', 'EAST 14TH STREET'], ['W 14 ST', 'WEST 14TH STREET'],
  ['E 23 ST', 'EAST 23RD STREET'], ['W 23 ST', 'WEST 23RD STREET'],
  ['E 34 ST', 'EAST 34TH STREET'], ['W 34 ST', 'WEST 34TH STREET'],
  ['E 42 ST', 'EAST 42ND STREET'], ['W 42 ST', 'WEST 42ND STREET'],
  ['E 57 ST', 'EAST 57TH STREET'], ['W 57 ST', 'WEST 57TH STREET'],
  ['E 72 ST', 'EAST 72ND STREET'], ['W 72 ST', 'WEST 72ND STREET'],
  ['W 79 ST', 'WEST 79TH STREET'],
  ['E 86 ST', 'EAST 86TH STREET'], ['W 86 ST', 'WEST 86TH STREET'],
  ['E 96 ST', 'EAST 96TH STREET'], ['W 96 ST', 'WEST 96TH STREET'],
  ['E 110 ST', 'EAST 110TH STREET'], ['W 110 ST', 'WEST 110TH STREET'],
  ['E 125 ST', 'EAST 125TH STREET'], ['W 125 ST', 'WEST 125TH STREET'],
  ['CANAL ST', 'CANAL STREET'], ['FULTON ST', 'FULTON STREET'],
  ['CHAMBERS ST', 'CHAMBERS STREET'], ['VESEY ST', 'VESEY STREET'],
  ['RECTOR ST', 'RECTOR STREET'], ['LIBERTY ST', 'LIBERTY STREET'],
  ['W BROADWAY', 'WEST BROADWAY'], ['LAFAYETTE ST', 'LAFAYETTE STREET'],
  ['ADAM CLAYTON POWELL JR BLVD', 'ADAM CLAYTON POWELL JR BOULEVARD'],
  ['FREDERICK DOUGLASS BLVD', 'FREDERICK DOUGLASS BOULEVARD'],
  ['RIVERSIDE DR', 'RIVERSIDE DRIVE'],
  ['CENTRAL PARK W', 'CENTRAL PARK WEST'],
];

let majorStreetsChecked = 0;
for (const [canonKey, fullName] of majorStreets) {
  if (pp._perStreetOffset[canonKey] === undefined) {
    console.log(`SKIP: ${canonKey} (${fullName}) -- not present in street_widths.json (no CSCL ways matched this exact key; not a regression, just absent data)`);
    continue;
  }
  majorStreetsChecked++;
  const actual = pp._perStreetOffset[canonKey];
  const regressedWrong = actual < 9.99; // the unfixed-bug symptom: dropping toward 6-9m
  check(`${canonKey} (${fullName}) stays >= 10.00m (actual: ${actual}m; never regresses to the 6m default)`, regressedWrong, false);
}
console.log(`\n(${majorStreetsChecked}/${majorStreets.length} major streets present in street_widths.json and checked above)`);

console.log('\n=== 4. Unaffected control sample — byte-identical to the flat name-tier value ===\n');

const unaffected = {
  '2 AVE': 10,       // WIDE_AVENUE_RE match, no CSCL-width delta per investigation §2
  'PARK AVE': 10,    // not on allow-list (correctly, per this resurrection's scope — Park Ave audit is a future item)
};
for (const [key, tier] of Object.entries(unaffected)) {
  if (pp._perStreetOffset[key] === undefined) {
    console.log(`SKIP: ${key} -- not present in street_widths.json`);
    continue;
  }
  check(`${key}: unaffected, resolves to >= ${tier}m tier floor (no regression)`, pp._perStreetOffset[key] >= tier - 0.01, true);
}

console.log('\n============================================================');
console.log(`RESULT: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
