#!/usr/bin/env node
// DT35-7 independent ground-truth check (NOT part of the build). Compares drawn Houston curb lines with the
// NYC Planimetric Database "Pavement Edge" linework (Socrata vs44-rznx, surveyed from aerial imagery), which
// does not depend on CSCL widths. Needs network (one Socrata query, cached next to this file's --cache path).
// Usage: node docs/qa/dt35-7-pavement-edge-check.js [--tiles <dir>] [--baseline <dir>] [--cache <file>] [--write-geojson]
// Prints, per street and tile set, the median distance of each sub-segment midpoint to the nearest pavement edge and the
// share within 2 m / 3 m. A line drawn at 0.88 x half-width should sit about 0.12 x half-width (0.6 to 0.8 m) inside the edge.
// --write-geojson appends the nearby pavement-edge lines (layer ref-nyc-pavement-edge) to
// docs/qa/dt35-7-houston-current-vs-proposed.geojson so geojson.io shows them next to the tile lines.
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..', '..');
const argv = process.argv.slice(2);
const opt = (n, d) => (argv.includes(n) ? path.resolve(argv[argv.indexOf(n) + 1]) : d);
const TILES = opt('--tiles', path.join(ROOT, 'tiles'));
const BASE = opt('--baseline', null);
const CACHE = opt('--cache', path.join(require('os').tmpdir(), 'dt35-7-pavement-edges.json'));
const cosL = Math.cos(40.722 * Math.PI / 180);
const XY = ([lat, lng]) => [lng * cosL * 111320, lat * 111320];
async function loadEdges() {
  if (fs.existsSync(CACHE)) return JSON.parse(fs.readFileSync(CACHE));
  const where = encodeURIComponent('within_box(the_geom,40.7185,-74.0125,40.7300,-73.9715)');
  const j = await (await fetch(`https://data.cityofnewyork.us/resource/vs44-rznx.json?$limit=50000&$where=${where}`)).json();
  fs.writeFileSync(CACHE, JSON.stringify(j)); return j;
}
function tileSegs(dir, street) {
  const out = [];
  for (const f of fs.readdirSync(dir)) if (f.startsWith('tile_'))
    for (const s of JSON.parse(fs.readFileSync(path.join(dir, f)))) if (s.street.includes(street)) out.push(s);
  return out;
}
(async () => {
  const edges = await loadEdges(), segs = [];
  for (const e of edges) for (const ls of e.the_geom.coordinates) for (let i = 0; i < ls.length - 1; i++)
    segs.push([XY([ls[i][1], ls[i][0]]), XY([ls[i + 1][1], ls[i + 1][0]])]);
  const dist = p => { let best = 1e9; for (const [a, b] of segs) {
    const dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy;
    let t = l2 ? ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2 : 0; t = Math.max(0, Math.min(1, t));
    best = Math.min(best, Math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)); } return best; };
  console.log(`pavement edge features ${edges.length}, segments ${segs.length}`);
  const sets = BASE ? [['before', BASE], ['after', TILES]] : [['tiles', TILES]];
  for (const street of ['WEST HOUSTON', 'EAST HOUSTON']) for (const [label, dir] of sets) {
    const ds = tileSegs(dir, street).map(s => dist(XY(s.line[Math.floor(s.line.length / 2)]))).sort((a, b) => a - b);
    const q = p => ds[Math.floor(p * (ds.length - 1))].toFixed(1), w = m => ds.filter(d => d <= m).length;
    console.log(`${street} ${label}: n=${ds.length} median ${q(0.5)} m (p25 ${q(0.25)}, p75 ${q(0.75)}); within 2 m ${w(2)} (${(100 * w(2) / ds.length).toFixed(0)}%), within 3 m ${w(3)} (${(100 * w(3) / ds.length).toFixed(0)}%)`);
  }
  if (argv.includes('--write-geojson')) {
    const gj = path.join(__dirname, 'dt35-7-houston-current-vs-proposed.geojson');
    const doc = JSON.parse(fs.readFileSync(gj));
    doc.features = doc.features.filter(f => f.properties.layer !== 'ref-nyc-pavement-edge');
    const pts = [];
    for (const f of doc.features) if (/tile-line$/.test(f.properties.layer)) for (const c of f.geometry.coordinates) pts.push(XY([c[1], c[0]]));
    for (const e of edges) {
      const near = e.the_geom.coordinates.some(ls => ls.some(c => { const q = XY([c[1], c[0]]); return pts.some(p => Math.hypot(p[0] - q[0], p[1] - q[1]) < 40); }));
      if (near) for (const ls of e.the_geom.coordinates) doc.features.push({ type: 'Feature', properties: { layer: 'ref-nyc-pavement-edge', name: 'NYC planimetric pavement edge', stroke: '#6a1b9a', 'stroke-width': 2 }, geometry: { type: 'LineString', coordinates: ls } });
    }
    fs.writeFileSync(gj, JSON.stringify(doc)); console.log('updated', gj);
  }
})();
