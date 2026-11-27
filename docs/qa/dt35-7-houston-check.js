#!/usr/bin/env node
// DT35-7 read-only curb-line checker (investigation helper; NOT part of the build).
// Usage: node docs/qa/dt35-7-houston-check.js [--street HOUSTON] [--write-geojson]
// Reads tiles/*.json + street_widths.json + osm_data.json, no network, no writes except
// docs/qa/dt35-7-houston-current-vs-proposed.geojson when --write-geojson is given.
// For every tile sub-segment on the street it finds the outermost CSCL carriageway row on the
// segment's compass side (within 40 m) and reports err = (line - curb) in metres, where
// curb = row half-width. err > +3 => outside the curb; err < -3 => inside the roadway ("mid-road").
// "Proposed" = vertex re-seated at 0.88 * row half-width outward of that row (what an
// outer-carriageway rule would draw).
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..', '..');
const argv = process.argv.slice(2);
const street = (argv.includes('--street') ? argv[argv.indexOf('--street') + 1] : 'HOUSTON').toUpperCase();
const widths = JSON.parse(fs.readFileSync(path.join(ROOT, 'street_widths.json')));
const osm = JSON.parse(fs.readFileSync(path.join(ROOT, 'osm_data.json')));
const cosL = Math.cos(40.726 * Math.PI / 180);
const XY = p => [p[1] * cosL * 111320, p[0] * 111320];
const LL = q => [q[1] / 111320, q[0] / (cosL * 111320)];
const SV = { N: [0, 1], S: [0, -1], E: [1, 0], W: [-1, 0] };
const FRAC = 0.88;
function nearest(poly, q, v) {
  let best = null;
  for (let i = 0; i < poly.length - 1; i++) {
    const a = XY(poly[i]), b = XY(poly[i + 1]);
    const ab = [b[0] - a[0], b[1] - a[1]], l2 = ab[0] ** 2 + ab[1] ** 2;
    if (l2 < 1) continue;
    let t = ((q[0] - a[0]) * ab[0] + (q[1] - a[1]) * ab[1]) / l2; t = Math.max(0, Math.min(1, t));
    const c = [a[0] + t * ab[0], a[1] + t * ab[1]], d = Math.hypot(q[0] - c[0], q[1] - c[1]);
    if (!best || d < best.d) {
      const L = Math.sqrt(l2); let nx = -ab[1] / L, ny = ab[0] / L;
      if (nx * v[0] + ny * v[1] < 0) { nx = -nx; ny = -ny; }
      best = { d, c, n: [nx, ny], off: (c[0] - q[0]) * nx + (c[1] - q[1]) * ny };
    }
  }
  return best;
}
const canon = s => s.replace(/\bEAST\b/, 'E').replace(/\bWEST\b/, 'W').replace(/\bSTREET\b/, 'ST');
const segs = [];
for (const f of fs.readdirSync(path.join(ROOT, 'tiles'))) {
  if (!f.startsWith('tile_')) continue;
  for (const s of JSON.parse(fs.readFileSync(path.join(ROOT, 'tiles', f)))) if (s.street.includes(street)) segs.push(s);
}
const rowsFor = {};
function rows(s) {
  const ck = canon(s.street);
  return rowsFor[ck] || (rowsFor[ck] = (widths[ck] || []).filter(r => r.polyline && r.polyline.length > 1 && r.stWidthFt && (r.segLengthFt || 0) >= 100));
}
const feats = [], faceErr = {};
const line = (c, p) => feats.push({ type: 'Feature', properties: p, geometry: { type: 'LineString', coordinates: c.map(x => [x[1], x[0]]) } });
for (const s of segs) {
  const v = SV[s.side]; if (!v) continue;
  const R = rows(s);
  const pick = pt => { let b = null; for (const r of R) { const n = nearest(r.polyline, XY(pt), v); if (!n || n.d > 40) continue; const c = { ...n, hw: r.stWidthFt * 0.3048 / 2 }; if (!b || c.off > b.off) b = c; } return b; };
  const m = pick(s.line[Math.floor(s.line.length / 2)]);
  const err = m ? (-m.off) - m.hw : null;
  const key = `${s.street}|${s.from}>${s.to}|${s.side}`;
  (faceErr[key] = faceErr[key] || []).push(err);
  line(s.line, { layer: 'current-tile-line', name: s.id, side: s.side, category: s.dominantCategory, errM: err && +err.toFixed(1), stroke: s.side === 'N' || s.side === 'E' ? '#e53935' : '#1e88e5', 'stroke-width': 3 });
  const np = s.line.map(pick);
  if (np.every(Boolean)) line(np.map(p => LL([p.c[0] + p.n[0] * FRAC * p.hw, p.c[1] + p.n[1] * FRAC * p.hw])), { layer: 'proposed-line', name: s.id, side: s.side, category: s.dominantCategory, stroke: '#2e7d32', 'stroke-width': 4 });
}
for (const [k, e] of Object.entries(faceErr).sort()) console.log(k.padEnd(70), e.map(x => x == null ? '?' : x.toFixed(1)).join(' '));
if (argv.includes('--write-geojson')) {
  for (const ck of Object.keys(rowsFor)) for (const r of widths[ck]) if (r.polyline && r.polyline.length > 1) line(r.polyline, { layer: 'ref-cscl-carriageway-row', name: `${ck} ${r.trafdir} ${r.stWidthFt}ft`, stroke: '#9e9e9e', 'stroke-width': 2 });
  const out = path.join(__dirname, 'dt35-7-houston-current-vs-proposed.geojson');
  fs.writeFileSync(out, JSON.stringify({ type: 'FeatureCollection', features: feats }));
  console.log('wrote', out);
}
