#!/usr/bin/env node
// Build street width lookup artifact from NYC CSCL (inkn-q76z).
// Same data source as build-oneway-data.js — fetches the same rows but
// extracts the streetwidth field and builds a per-way polyline lookup.
//
// Output: street_widths.json at repo root.
// Format: { "<CANONICAL_NAME>": [{ polyline: [[lat,lng],...], stWidthFt: <number> }, ...] }
//
// Run BEFORE node build/preprocess.js:
//   node scripts/build-street-widths.js && node build/preprocess.js
//
// Update cadence: same as osm_oneway.json (quarterly, or whenever CSCL is refreshed).
//
// Field evidence (confirmed from NYC DCP CSCL metadata, Metadata_StreetCenterline.md):
//   ST_WIDTH — "The width, in feet, of the paved area of the street"
//   Socrata JSON API returns this field in lowercase: streetwidth
//   No streetwidth_min / streetwidth_max fields exist in this dataset;
//   those names appear only in the LION file geodatabase (a separate DCP product).
//   CSCL (inkn-q76z) has a single width field: streetwidth.
//
// Divided / dual-carriageway streets (e.g. East Houston Street east of 6th Ave,
// Bowery south of Canal with median):
//   CSCL stores each carriageway as a SEPARATE record with its own centerline
//   polyline and its own streetwidth.  "streetwidth" for each carriageway is the paved
//   width of THAT carriageway only (from median/separation edge to outer curb).
//   preprocess.js handles the dual-carriageway case via getCurbOffsetFromWidth():
//   it finds ALL CSCL ways within 30m of the block midpoint, detects a dual pair
//   when two ways are separated by > 12m but < 60m, and uses the farther way's
//   geometry to estimate the full half-width to the outer curb.

const fs = require('fs');
const path = require('path');

const ENDPOINT = 'https://data.cityofnewyork.us/resource/inkn-q76z.json';
// Same WHERE as build-oneway-data.js — Manhattan driveable roadways
const WHERE = "boroughcode='1' AND rw_type IN ('1','2','3','9','10','11','13','14')";
const PAGE_SIZE = 10000;

// Canonical street name normalization — mirrors canonicalStreetName() in
// build-oneway-data.js exactly so the lookup keys match osm_oneway.json.
const SUFFIX_NORMALIZE = [
  [/\bSTREETS\b/g, 'ST'], [/\bSTREET\b/g, 'ST'],
  [/\bAVENUES\b/g, 'AVE'], [/\bAVENUE\b/g, 'AVE'],
  [/\bBOULEVARD\b/g, 'BLVD'],
  [/\bPLACE\b/g, 'PL'],
  [/\bPLAZA\b/g, 'PLZ'],
  [/\bDRIVE\b/g, 'DR'],
  [/\bROAD\b/g, 'RD'],
  [/\bPARKWAY\b/g, 'PKWY'],
  [/\bEXPRESSWAY\b/g, 'EXPY'],
  [/\bTERRACE\b/g, 'TER'],
  [/\bCOURT\b/g, 'CT'],
  [/\bSQUARE\b/g, 'SQ'],
  [/\bHIGHWAY\b/g, 'HWY'],
  [/\bBRIDGE\b/g, 'BR'],
  [/\bTUNNEL\b/g, 'TUN'],
  [/\bEAST\b/g, 'E'], [/\bWEST\b/g, 'W'], [/\bNORTH\b/g, 'N'], [/\bSOUTH\b/g, 'S'],
  [/\bFIRST\b/g, '1'], [/\bSECOND\b/g, '2'], [/\bTHIRD\b/g, '3'],
  [/\bFOURTH\b/g, '4'], [/\bFIFTH\b/g, '5'], [/\bSIXTH\b/g, '6'],
  [/\bSEVENTH\b/g, '7'], [/\bEIGHTH\b/g, '8'], [/\bNINTH\b/g, '9'],
  [/\bTENTH\b/g, '10'], [/\bELEVENTH\b/g, '11'], [/\bTWELFTH\b/g, '12'],
];

function canonicalStreetName(raw) {
  if (!raw) return '';
  let s = String(raw).toUpperCase().trim();
  s = s.replace(/(\d+)(ST|ND|RD|TH)\b/g, '$1');
  for (const [re, rep] of SUFFIX_NORMALIZE) s = s.replace(re, rep);
  s = s.replace(/\s+/g, ' ').trim();
  if (s === 'AVE OF THE AMERICAS') return '6 AVE';
  if (s === 'AVE OF AMERICAS') return '6 AVE';
  return s;
}

// Convert MultiLineString coords (lng,lat) to our [[lat,lng],...] polylines.
function multiLineToPolylines(geom) {
  if (!geom || geom.type !== 'MultiLineString') return [];
  const out = [];
  for (const part of geom.coordinates || []) {
    if (!part || part.length < 2) continue;
    out.push(part.map(([lng, lat]) => [Number(lat.toFixed(6)), Number(lng.toFixed(6))]));
  }
  return out;
}

async function fetchPage(offset) {
  // Request streetwidth along with the fields needed for polyline + name
  const select = '$select=full_street_name,stname_label,street_name,streetwidth,trafdir,rw_type,the_geom';
  const url = `${ENDPOINT}?$where=${encodeURIComponent(WHERE)}&$limit=${PAGE_SIZE}&$offset=${offset}&${select}`;
  const resp = await fetch(url, {
    headers: {
      'User-Agent': 'WePark/1.0 (https://kevhox1.github.io/parkmap)',
      'Accept': 'application/json',
    },
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status} at offset ${offset}`);
  return resp.json();
}

(async () => {
  console.log('Building street width data from NYC CSCL (Manhattan)...');
  console.log('Field used: streetwidth (paved roadway width in feet, per CSCL metadata)');
  console.log('');

  const allRows = [];
  let offset = 0;
  for (;;) {
    console.log(`  fetching page offset=${offset}...`);
    const rows = await fetchPage(offset);
    if (!rows.length) break;
    allRows.push(...rows);
    if (rows.length < PAGE_SIZE) break;
    offset += PAGE_SIZE;
  }
  console.log(`total rows: ${allRows.length}`);

  const byStreet = {};
  let noNameCount = 0;
  let noWidthCount = 0;
  let withWidthCount = 0;

  for (const row of allRows) {
    const name = canonicalStreetName(row.full_street_name || row.stname_label || row.street_name);
    if (!name) { noNameCount++; continue; }

    const rawWidth = row.streetwidth;
    const stWidthFt = rawWidth !== undefined && rawWidth !== null && rawWidth !== ''
      ? parseFloat(rawWidth)
      : null;

    if (stWidthFt === null || isNaN(stWidthFt) || stWidthFt <= 0) {
      noWidthCount++;
      // Still include the way in the output (with null width) so preprocess.js
      // can find the polyline for proximity purposes even when width is absent.
    } else {
      withWidthCount++;
    }

    const polylines = multiLineToPolylines(row.the_geom);
    if (!polylines.length) continue;

    if (!byStreet[name]) byStreet[name] = [];
    for (const pl of polylines) {
      byStreet[name].push({
        polyline: pl,
        stWidthFt: stWidthFt !== null && !isNaN(stWidthFt) && stWidthFt > 0 ? stWidthFt : null,
      });
    }
  }

  const streetCount = Object.keys(byStreet).length;
  const waysTotal = Object.values(byStreet).reduce((n, arr) => n + arr.length, 0);
  console.log(`unique streets: ${streetCount}`);
  console.log(`total way-segments: ${waysTotal}`);
  console.log(`ways with width: ${withWidthCount}, ways without width: ${noWidthCount}, no-name rows: ${noNameCount}`);

  const outPath = path.join(__dirname, '..', 'street_widths.json');
  fs.writeFileSync(outPath, JSON.stringify(byStreet));
  const stat = fs.statSync(outPath);
  console.log(`\nwrote ${outPath} (${(stat.size / 1024).toFixed(1)} KB)`);

  // Sanity check: print sample width values for the four verification streets
  const verifyStreets = [
    { key: 'E HOUSTON ST',  label: 'East Houston St' },
    { key: 'W HOUSTON ST',  label: 'West Houston St' },
    { key: 'BOWERY',        label: 'Bowery' },
    { key: 'E 2 ST',        label: 'E 2 St' },
    { key: '2 AVE',         label: '2nd Avenue' },
  ];
  console.log('\nSanity check — streetwidth values for verification streets:');
  for (const { key, label } of verifyStreets) {
    const ways = byStreet[key];
    if (!ways) { console.log(`  ${label} (${key}): NOT FOUND`); continue; }
    const widths = ways.map(w => w.stWidthFt).filter(Boolean);
    const min = widths.length ? Math.min(...widths) : null;
    const max = widths.length ? Math.max(...widths) : null;
    const avg = widths.length ? (widths.reduce((a, b) => a + b, 0) / widths.length).toFixed(1) : null;
    console.log(`  ${label} (${key}): ${ways.length} ways, width range ${min}–${max} ft (avg ${avg} ft)`);

    // For Houston: print first few way centroids to show carriageway separation
    if (key === 'E HOUSTON ST' && ways.length > 0) {
      const sample = ways.slice(0, Math.min(4, ways.length));
      for (const w of sample) {
        const mid = Math.floor(w.polyline.length / 2);
        const [lat, lng] = w.polyline[mid];
        console.log(`    way centroid: lat=${lat.toFixed(6)} lng=${lng.toFixed(6)} width=${w.stWidthFt} ft`);
      }
    }
  }

  // Divided-street evidence: for E HOUSTON ST, show if multiple ways have
  // centerlines far apart (> 12m), confirming dual-carriageway representation
  const houstonWays = byStreet['E HOUSTON ST'];
  if (houstonWays && houstonWays.length >= 2) {
    console.log('\nE HOUSTON ST dual-carriageway check:');
    // Look at ways near the Houston-Bowery intersection (lat~40.726, lng~-73.993)
    const refLat = 40.726, refLng = -73.993;
    const nearby = houstonWays.filter(w => {
      const mid = Math.floor(w.polyline.length / 2);
      const [lat, lng] = w.polyline[mid];
      const dLat = (lat - refLat) * 111320;
      const dLng = (lng - refLng) * 111320 * Math.cos(refLat * Math.PI / 180);
      return Math.sqrt(dLat * dLat + dLng * dLng) < 200;
    });
    console.log(`  ways within 200m of Bowery-Houston intersection: ${nearby.length}`);
    if (nearby.length >= 2) {
      const lats = nearby.map(w => { const mid = Math.floor(w.polyline.length / 2); return w.polyline[mid][0]; });
      const spreadLat = (Math.max(...lats) - Math.min(...lats)) * 111320;
      console.log(`  N-S spread of way centroids: ${spreadLat.toFixed(1)} m (expected ~14-20m for divided street)`);
    }
  }
})().catch(err => {
  console.error('FATAL:', err.message);
  process.exit(1);
});
