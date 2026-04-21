#!/usr/bin/env node
// One-time build: pull Manhattan one-way data from NYC DOT Centerline (CSCL), save as osm_oneway.json.
// Data source: https://data.cityofnewyork.us/resource/inkn-q76z.json (NYC Open Data, CC0)
// Run: node scripts/build-oneway-data.js
// Output: ../osm_oneway.json, shape { "<street_name_upper>": [{ polyline: [[lat,lng],...], oneway: "yes"|"reverse"|"no" }] }

const fs = require('fs');
const path = require('path');

const ENDPOINT = 'https://data.cityofnewyork.us/resource/inkn-q76z.json';
// boroughcode: 1=Manhattan, 2=Bronx, 3=Brooklyn, 4=Queens, 5=Staten Island
const WHERE = "boroughcode='1' AND rw_type IN ('1','2','3','9','10','11','13','14')";
// rw_type: 1=Street, 2=Hwy, 3=Bridge, 9=Tunnel, 10=Boardwalk, 11=Path, 13=Exit, 14=Ramp (driveable-ish)
// Skip 6=Cul-de-sac? no, keep. Actually keep everything drivable.

const PAGE_SIZE = 10000;

function classifyOneway(trafdir) {
  const t = String(trafdir || '').toUpperCase().trim();
  // TF = against digitized direction, FT = with digitized direction, TW = two-way, NV = non-vehicular, blank = unknown
  if (t === 'FT') return 'yes';      // forward = in polyline order
  if (t === 'TF') return 'reverse';  // reverse = opposite polyline order
  if (t === 'TW') return 'no';       // bidirectional
  if (t === 'NV') return 'skip';     // non-vehicular (pedestrian, etc.) — exclude
  return 'no';                       // unknown -> assume two-way (conservative)
}

// Canonical street name: matches both NYC Centerline ("1 AVE", "CHRYSTIE ST")
// and tile/OSM ("1ST AVENUE", "CHRYSTIE STREET") to a single form.
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
  // Word-form ordinals to digits (FIRST → 1, etc.)
  [/\bFIRST\b/g, '1'], [/\bSECOND\b/g, '2'], [/\bTHIRD\b/g, '3'],
  [/\bFOURTH\b/g, '4'], [/\bFIFTH\b/g, '5'], [/\bSIXTH\b/g, '6'],
  [/\bSEVENTH\b/g, '7'], [/\bEIGHTH\b/g, '8'], [/\bNINTH\b/g, '9'],
  [/\bTENTH\b/g, '10'], [/\bELEVENTH\b/g, '11'], [/\bTWELFTH\b/g, '12']
];

function canonicalStreetName(raw) {
  if (!raw) return '';
  let s = String(raw).toUpperCase().trim();
  // Drop ordinal suffixes on digits (1ST → 1, 2ND → 2, 23RD → 23)
  s = s.replace(/(\d+)(ST|ND|RD|TH)\b/g, '$1');
  for (const [re, rep] of SUFFIX_NORMALIZE) s = s.replace(re, rep);
  s = s.replace(/\s+/g, ' ').trim();
  // Famous aliases (6 AVE is officially "AVENUE OF THE AMERICAS" below 59th)
  if (s === 'AVE OF THE AMERICAS') return '6 AVE';
  if (s === 'AVE OF AMERICAS') return '6 AVE';
  return s;
}

function normalizeStreetName(raw) { return canonicalStreetName(raw); }

// Convert MultiLineString coords (lng,lat) to our [[lat,lng],...] polylines.
// A MultiLineString may have multiple parts; treat each as a separate way.
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
  const url = `${ENDPOINT}?$where=${encodeURIComponent(WHERE)}&$limit=${PAGE_SIZE}&$offset=${offset}`;
  const resp = await fetch(url, {
    headers: {
      'User-Agent': 'WePark/1.0 (https://kevhox1.github.io/parkmap)',
      'Accept': 'application/json'
    }
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status} at offset ${offset}`);
  return resp.json();
}

(async () => {
  console.log('building oneway data from NYC DOT Centerline (Manhattan only)');
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
  const onewayCounts = { yes: 0, reverse: 0, no: 0, skip: 0 };
  let noNameCount = 0;

  for (const row of allRows) {
    const name = normalizeStreetName(row.full_street_name || row.stname_label || row.street_name);
    if (!name) { noNameCount++; continue; }
    const oneway = classifyOneway(row.trafdir);
    onewayCounts[oneway]++;
    if (oneway === 'skip') continue;
    const polylines = multiLineToPolylines(row.the_geom);
    if (!polylines.length) continue;
    if (!byStreet[name]) byStreet[name] = [];
    for (const pl of polylines) {
      byStreet[name].push({ polyline: pl, oneway });
    }
  }

  const streetCount = Object.keys(byStreet).length;
  const waysTotal = Object.values(byStreet).reduce((n, arr) => n + arr.length, 0);
  console.log(`unique streets: ${streetCount}`);
  console.log(`total way-segments: ${waysTotal}`);
  console.log(`trafdir breakdown: FT/yes=${onewayCounts.yes} TF/reverse=${onewayCounts.reverse} TW/no=${onewayCounts.no} NV/skipped=${onewayCounts.skip} no-name=${noNameCount}`);

  const outPath = path.join(__dirname, '..', 'osm_oneway.json');
  fs.writeFileSync(outPath, JSON.stringify(byStreet));
  const stat = fs.statSync(outPath);
  console.log(`wrote ${outPath} (${(stat.size / 1024).toFixed(1)} KB)`);

  // sanity samples
  const famousOneWays = [
    'FIRST AVENUE', '1 AVE', 'AVENUE A',
    'SECOND AVENUE', '2 AVE',
    'THIRD AVENUE', '3 AVE',
    'LEXINGTON AVENUE', 'LEXINGTON AVE',
    'MADISON AVENUE', 'MADISON AVE',
    'FIFTH AVENUE', '5 AVE',
    'SIXTH AVENUE', '6 AVE', 'AVENUE OF THE AMERICAS',
    'BROADWAY',
    'PARK AVENUE', 'PARK AVE'
  ];
  console.log('\nsanity check (famous Manhattan arteries):');
  for (const name of famousOneWays) {
    const entry = byStreet[name];
    if (!entry) { console.log(`  ${name}: NOT FOUND`); continue; }
    const tally = entry.reduce((acc, w) => (acc[w.oneway]++, acc), { yes: 0, reverse: 0, no: 0 });
    console.log(`  ${name}: ${entry.length} ways, yes=${tally.yes} reverse=${tally.reverse} two-way=${tally.no}`);
  }
})().catch(err => {
  console.error('FATAL:', err.message);
  process.exit(1);
});
