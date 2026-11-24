#!/usr/bin/env node
/**
 * scripts/test-bowery-detour.js
 *
 * Open item #35 regression gate (Bowery / E Houston hairpin-detour fix in
 * build/preprocess.js getBlockPolyline()). Offline: drives getBlockPolyline()
 * against the committed osm_data.json, no network.
 *
 * Pinned: Bowery Bleecker->E Houston (W) used to extract a 1,727ft chain slice
 * (around the OSM hairpin) for a ~330ft block, painting its commercial-only meter
 * rules north over Bond / Great Jones / E 2nd. It must now be < 400ft and lie
 * SOUTH of Bleecker (lat < 40.7253). Also asserts the citywide gate: no block
 * in the pinned list is a >2x detour any more, and a known-good control block
 * (Bowery Great Jones->Bond) is unchanged.
 */
const fs = require('fs');
const path = require('path');
const pre = require('../build/preprocess.js');
pre.initStreets(JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'osm_data.json'), 'utf8')));

let fail = 0;
function check(name, ok, info) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${info ? ' -- ' + info : ''}`); if (!ok) fail++; }

const b = pre.getBlockPolyline({ street: 'BOWERY', from: 'BLEECKER STREET', to: 'EAST HOUSTON STREET', side: 'W' });
check('Bowery Bleecker->E Houston length', b && b.blockLenFt < 400 && b.blockLenFt > 250, b && b.blockLenFt.toFixed(0) + 'ft');
check('Bowery Bleecker->E Houston lies south of Bleecker', b && b.line.every(p => p[0] < 40.7253), b && JSON.stringify(b.line[0]));

const ctl = pre.getBlockPolyline({ street: 'BOWERY', from: 'GREAT JONES STREET', to: 'BOND STREET', side: 'W' });
check('control Bowery Great Jones->Bond unchanged (~222ft)', ctl && Math.abs(ctl.blockLenFt - 222.0) < 1, ctl && ctl.blockLenFt.toFixed(1));

for (const [s, f, t] of [['BOWERY', 'EAST 2ND STREET', 'EAST 3RD STREET'], ['BOWERY', 'PRINCE STREET', 'SPRING STREET'],
                         ['EAST HOUSTON STREET', 'ELIZABETH STREET', 'BOWERY'], ['EAST HOUSTON STREET', 'AVENUE B', 'AVENUE A']]) {
  const g = pre.getBlockPolyline({ street: s, from: f, to: t, side: 'N' });
  const straight = g ? Math.hypot((g.ptTo[1] - g.ptFrom[1]) * 84400, (g.ptTo[0] - g.ptFrom[0]) * 110540) : 0;
  check(`${s} ${f}->${t} not a >2x detour`, g && g.blockLenM <= 2 * straight + 30, g && `${g.blockLenM.toFixed(0)}m vs straight ${straight.toFixed(0)}m`);
}
console.log(fail ? `\nRESULT: ${fail} FAILED` : '\nRESULT: PASS');
process.exit(fail ? 1 : 0);
