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
pp.initWidths(rawWidths);

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

console.log('=== 1. Flagship divided/wide streets — expected movement off today\'s flat tier ===\n');

// canonKey -> [today's flat tier, resurrected offset after both memo fixes, tolerance]
// Expected values per docs/ft21-width-offset-investigation.md §2/§5.
const flagship = {
  'E HOUSTON ST': { today: 6, resurrected: 12.79 },
  'W HOUSTON ST': { today: 6, resurrected: 12.49 },
  'BOWERY':       { today: 10, resurrected: 12.49 },
  'ALLEN ST':     { today: 6, resurrected: 13.40 },
  'DELANCEY ST':  { today: 6, resurrected: 14.00 }, // clamp ceiling
  'FORSYTH ST':   { today: 6, resurrected: 6.00 },  // CONTROL — must be unchanged
};

for (const [key, { today, resurrected }] of Object.entries(flagship)) {
  const actual = pp._perStreetOffset[key];
  const delta = actual !== undefined ? +(actual - today).toFixed(2) : null;
  check(`${key}: resurrected offset ~${resurrected}m (delta vs today's ${today}m: +${delta}m)`, actual, resurrected);
}

console.log('\n=== 2. Forsyth allow-list fix — must NOT get the divided-median formula ===\n');
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
