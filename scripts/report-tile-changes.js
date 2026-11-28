#!/usr/bin/env node
/**
 * scripts/report-tile-changes.js  (DT35-7)
 *
 * Diff two tile directories at the segment level and report every segment whose
 * GEOMETRY changed (plus added / removed ids), grouped by street. Exits 1 if any
 * street outside the allow-listed divided streets changed, so a curb-geometry PR can
 * prove its blast radius is limited to the streets it claims to touch.
 *
 * Usage:
 *   node scripts/report-tile-changes.js <baseTilesDir> <newTilesDir> [--rules] [--json out.json] [--quiet]
 *
 *   --rules   also treat a change in rules/dominantCategory as a change (default: geometry only,
 *             plus added/removed ids). Use this to prove the committed tiles are the only thing
 *             that moved when tiles/ is compared with the PR's tiles/.
 *   --json    write the full per-face change list as JSON.
 *
 * "Allowed" streets = every street whose canonical CSCL key is in build/preprocess.js's
 * DIVIDED_STREET_ALLOW_LIST (E HOUSTON ST, W HOUSTON ST, BOWERY, ALLEN ST, DELANCEY ST).
 */
'use strict';
const fs = require('fs');
const path = require('path');
const pp = require('../build/preprocess.js');

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const positional = args.filter((a, i) => !a.startsWith('--') && args[i - 1] !== '--json');
if (positional.length < 2) {
  console.error('usage: report-tile-changes.js <baseTilesDir> <newTilesDir> [--rules] [--json out.json] [--quiet]');
  process.exit(2);
}
const [baseDir, newDir] = positional.map(p => path.resolve(p));
const jsonOut = flag('--json') ? args[args.indexOf('--json') + 1] : null;
const allowed = pp._DIVIDED_STREET_ALLOW_LIST;
const isAllowed = (street) => allowed.has(pp.canonicalNameForOneway(street));

function load(dir) {
  const m = new Map();
  for (const f of fs.readdirSync(dir)) {
    if (!f.startsWith('tile_')) continue;
    for (const s of JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'))) m.set(s.id, s);
  }
  return m;
}
const faceOf = (id) => id.replace(/_\d+$/, '');
const base = load(baseDir), next = load(newDir);
const sameLine = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const sameRules = (a, b) => JSON.stringify([a.rules, a.dominantCategory]) === JSON.stringify([b.rules, b.dominantCategory]);

const changes = []; // {street, face, id, kind}
for (const [id, s] of next) {
  const o = base.get(id);
  if (!o) { changes.push({ street: s.street, face: faceOf(id), id, kind: 'added' }); continue; }
  if (!sameLine(o.line, s.line)) changes.push({ street: s.street, face: faceOf(id), id, kind: 'geometry' });
  else if (flag('--rules') && !sameRules(o, s)) changes.push({ street: s.street, face: faceOf(id), id, kind: 'rules' });
}
for (const [id, o] of base) if (!next.has(id)) changes.push({ street: o.street, face: faceOf(id), id, kind: 'removed' });

const byStreet = {};
for (const c of changes) {
  const st = (byStreet[c.street] = byStreet[c.street] || { faces: new Set(), n: { geometry: 0, added: 0, removed: 0, rules: 0 } });
  st.faces.add(c.face); st.n[c.kind]++;
}
let bad = 0;
console.log(`base ${baseDir} (${base.size} segments)\nnew  ${newDir} (${next.size} segments)\n`);
for (const street of Object.keys(byStreet).sort()) {
  const st = byStreet[street];
  const ok = isAllowed(street);
  if (!ok) bad += st.faces.size;
  console.log(`${ok ? 'ok  ' : 'BAD '} ${street}: ${st.faces.size} faces changed (geometry ${st.n.geometry}, added ${st.n.added}, removed ${st.n.removed}${flag('--rules') ? ', rules ' + st.n.rules : ''})`);
  if (!flag('--quiet') || !ok) for (const f of [...st.faces].sort()) console.log(`       ${f}`);
}
console.log(`\nTOTAL: ${changes.length} segment changes across ${new Set(changes.map(c => c.face)).size} faces on ${Object.keys(byStreet).length} streets`);
if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(changes, null, 1));
if (bad) {
  console.error(`FAIL: ${bad} face(s) changed on streets outside the allow-listed divided streets`);
  process.exit(1);
}
console.log('PASS: every changed face is on an allow-listed street');
