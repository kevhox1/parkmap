#!/usr/bin/env node
// Coverage report: % of street-miles with sign data, by Manhattan neighborhood.
// Denominator: CSCL centerlines (street_widths.json), highways/bridges/tunnels excluded.
// Numerator: tile curb-face miles with >=1 rule, /2 to approximate centerline miles.
// Run from repo root after any tile regen: node scripts/coverage-report.js
// Caveats: neighborhood bounds are approximate boxes; 10m intersection setbacks and
// one-sided streets make percentages UNDERCOUNT by ~10-15 points. Ranking is the signal.
const fs = require("fs");

const R = 6371000;
function dist(a, b) {
  const dLat = (b[0]-a[0])*Math.PI/180, dLng = (b[1]-a[1])*Math.PI/180;
  const la1 = a[0]*Math.PI/180, la2 = b[0]*Math.PI/180;
  const h = Math.sin(dLat/2)**2 + Math.cos(la1)*Math.cos(la2)*Math.sin(dLng/2)**2;
  return 2*R*Math.asin(Math.sqrt(h));
}
function plLen(pl) { let m=0; for (let i=1;i<pl.length;i++) m+=dist(pl[i-1],pl[i]); return m; }

// Ordered boxes — first match wins. [name, latMin, latMax, lngMin, lngMax]
const HOODS = [
  ["Financial District", 40.700, 40.7135, -74.020, -73.999],
  ["Tribeca", 40.7135, 40.7238, -74.015, -74.0022],
  ["Chinatown", 40.7115, 40.7195, -74.0022, -73.991],
  ["Lower East Side", 40.710, 40.7225, -73.991, -73.970],
  ["SoHo", 40.7195, 40.7288, -74.0055, -73.9975],
  ["Nolita/Noho", 40.7195, 40.730, -73.9975, -73.991],
  ["East Village", 40.7225, 40.7345, -73.992, -73.970],
  ["Greenwich Village", 40.7265, 40.738, -74.0055, -73.992],
  ["West Village", 40.7238, 40.742, -74.015, -74.0035],
  ["Flatiron/Gramercy/Union Sq", 40.734, 40.7495, -73.9995, -73.970],
  ["Chelsea/Meatpacking", 40.738, 40.755, -74.012, -73.9905],
  ["Murray Hill/Kips Bay", 40.7415, 40.752, -73.9855, -73.968],
  ["Midtown East", 40.7495, 40.766, -73.985, -73.958],
  ["Midtown West/Hells Kitchen", 40.749, 40.7715, -74.005, -73.978],
  ["Upper East Side/Yorkville", 40.7615, 40.789, -73.974, -73.930],
  ["Upper West Side", 40.7685, 40.802, -73.995, -73.9575],
  ["East Harlem", 40.785, 40.809, -73.955, -73.920],
  ["Harlem", 40.799, 40.834, -73.965, -73.920],
  ["Hamilton Hts/Morningside", 40.802, 40.834, -73.9695, -73.945],
  ["Washington Hts/Inwood", 40.834, 40.882, -73.945, -73.907],
];
function hoodOf(pt) {
  for (const [n, la1, la2, lo1, lo2] of HOODS)
    if (pt[0]>=la1 && pt[0]<la2 && pt[1]>=lo1 && pt[1]<lo2) return n;
  return "Other/edges";
}
const EXCLUDE = /FDR|WEST SIDE HIGHWAY|HENRY HUDSON|HARLEM RIVER DR|BRIDGE|TUNNEL|EXPRESSWAY|EXPWY|APPROACH|RAMP|TRANS-?MANHATTAN|PARKWAY/i;

const cscl = JSON.parse(fs.readFileSync("street_widths.json"));
const den = {};
for (const [name, segs] of Object.entries(cscl)) {
  if (EXCLUDE.test(name)) continue;
  for (const seg of segs) {
    const pl = seg.polyline; if (!pl || pl.length < 2) continue;
    for (let i=1;i<pl.length;i++) {
      const m = [(pl[i-1][0]+pl[i][0])/2, (pl[i-1][1]+pl[i][1])/2];
      den[hoodOf(m)] = (den[hoodOf(m)]||0) + dist(pl[i-1], pl[i]);
    }
  }
}

const num = {}, faces = {};
for (const f of fs.readdirSync("tiles").filter(f => f.startsWith("tile_"))) {
  const j = JSON.parse(fs.readFileSync("tiles/"+f));
  const arr = Array.isArray(j) ? j : (j.segments || j.blocks || []);
  for (const s of arr) {
    if (!s.line || s.line.length < 2 || !s.rules || !s.rules.length) continue;
    if (EXCLUDE.test(s.street||"")) continue;
    const h = hoodOf(s.line[Math.floor(s.line.length/2)]);
    num[h] = (num[h]||0) + plLen(s.line);
    faces[h] = (faces[h]||0) + 1;
  }
}

const M = 1609.34;
const rows = [];
for (const [n] of HOODS.concat([["Other/edges"]])) {
  const d = den[n]||0; if (d < 500) continue;
  const cov = (num[n]||0)/2;
  rows.push([n, (d/M).toFixed(1), (Math.min(cov,d)/M).toFixed(1), Math.min(100, Math.round(100*cov/d)), faces[n]||0]);
}
rows.sort((a,b) => a[3]-b[3]);
console.log(["Neighborhood","CSCL mi","covered mi","pct","faces"].join(" | "));
rows.forEach(r => console.log(r.join(" | ")));
const tD = Object.values(den).reduce((a,b)=>a+b,0), tN = Object.values(num).reduce((a,b)=>a+b,0)/2;
console.log("TOTAL:", (tD/M).toFixed(0), "mi |", (tN/M).toFixed(0), "mi covered |", Math.round(100*tN/tD)+"%");
