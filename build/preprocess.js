#!/usr/bin/env node
/**
 * ParkMap Preprocessor
 * Converts raw NYC parking sign data + OSM geometry into pre-computed geographic tiles.
 * 
 * Usage: node build/preprocess.js
 * Output: tiles/index.json + tiles/tile_{row}_{col}.json
 */

const fs = require('fs');
const path = require('path');

// ==== Configuration ====
const ROOT = path.resolve(__dirname, '..');
const OSM_DATA_PATH = path.join(ROOT, 'osm_data.json');
const OSM_ONEWAY_PATH = path.join(ROOT, 'osm_oneway.json');
// TF2-14: CSCL real-street-width artifact (built by scripts/build-street-widths.js).
// Optional — if absent, falls back to name-tier offsets (getStreetCurbOffset).
const STREET_WIDTHS_PATH = path.join(ROOT, 'street_widths.json');
const TILES_DIR = path.join(ROOT, 'tiles');
// iOS app bundle reads tiles from this Resources path (see HANDOFF.md
// "iOS app: Resources land flat at app bundle root at build time").
// Build must keep this in sync with TILES_DIR or the iOS app will run
// against stale tiles. Discovered 2026-05-14 when PRs #21 and #22
// shipped tile updates that never reached the iOS bundle because only
// TILES_DIR was being written.
const IOS_TILES_DIR = path.join(ROOT, 'ios', 'WePark', 'WePark', 'Resources', 'tiles');

// Two data sources: main signs + ASP-specific signs
const SOCRATA_MAIN = 'https://data.cityofnewyork.us/resource/nfid-uabd.json';
const SOCRATA_ASP = 'https://data.cityofnewyork.us/resource/2x64-6f34.json';
const PAGE_SIZE = 5000;

// State Plane coordinate filter for Manhattan
const SP_BOUNDS = { xMin: 979000, xMax: 1010000, yMin: 194000, yMax: 259000 };

// Tile grid — smaller tiles (~250m x 250m) for tighter radius loading
const GRID = {
  latMin: 40.700, latMax: 40.882,
  lngMin: -74.020, lngMax: -73.907,
  rows: 80, cols: 50
};
GRID.rowSize = (GRID.latMax - GRID.latMin) / GRID.rows;
GRID.colSize = (GRID.lngMax - GRID.lngMin) / GRID.cols;

// ==== Categories ====
const CATEGORIES = {
  ASP_MON_THU:        { label: 'ASP Mon/Thu',     priority: 7 },
  ASP_TUE_FRI:        { label: 'ASP Tue/Fri',     priority: 8 },
  ASP_OVERNIGHT_MWF:  { label: 'ASP Night MWF',   priority: 9 },
  ASP_OVERNIGHT_TTHS: { label: 'ASP Night TThS',  priority: 10 },
  ASP_DAILY:          { label: 'ASP Daily',        priority: 6 },
  METERED:            { label: 'Metered',          priority: 5 },
  TRUCK_LOADING:      { label: 'Truck Loading',    priority: 4 },
  NO_PARKING:         { label: 'No Parking',       priority: 2 },
  NO_STANDING:        { label: 'No Standing/Stop', priority: 1 },
  SPECIAL:            { label: 'Special',          priority: 3 },
  UNKNOWN:            { label: 'Unknown',          priority: 11 },
};

const SKIP_PATTERNS = ['LOCATOR NUMBER', 'LOCATION PANEL', 'MTA BUS', 'STREET NAME', 'ONE WAY', 'SPEED LIMIT', 'DEAD END', 'CONSTRUCTION'];

// ==== Sign Classification ====
function classifySign(desc) {
  if (!desc) return null;
  const d = desc.toUpperCase();
  for (const p of SKIP_PATTERNS) { if (d.includes(p)) return null; }

  const hasBroom = d.includes('BROOM');
  const hasMidnight = d.includes('MIDNIGHT');

  if (hasBroom) {
    const dayFlags = {
      mon: /MONDAY|MON\b/.test(d), tue: /TUESDAY|TUE\b/.test(d),
      wed: /WEDNESDAY|WED\b/.test(d), thu: /THURSDAY|THU\b/.test(d),
      fri: /FRIDAY|FRI\b/.test(d), sat: /SATURDAY|SAT\b/.test(d),
      sun: /SUNDAY|SUN\b/.test(d)
    };
    const hasMonFri = /MON(DAY)?\s*(THRU|THROUGH|-|&)\s*FRI(DAY)?/i.test(d);
    const hasMonSat = /MON(DAY)?\s*(THRU|THROUGH|-|&)\s*SAT(URDAY)?/i.test(d);

    if (hasMidnight) {
      if (dayFlags.mon || dayFlags.wed || dayFlags.fri) return 'ASP_OVERNIGHT_MWF';
      if (dayFlags.tue || dayFlags.thu || dayFlags.sat) return 'ASP_OVERNIGHT_TTHS';
      return 'ASP_DAILY';
    }
    if ((dayFlags.mon && dayFlags.thu) || (dayFlags.mon || dayFlags.thu)) {
      if (!dayFlags.tue && !dayFlags.fri && !hasMonFri && !hasMonSat) return 'ASP_MON_THU';
    }
    if ((dayFlags.tue && dayFlags.fri) || (dayFlags.tue || dayFlags.fri)) {
      if (!dayFlags.mon && !dayFlags.thu && !hasMonFri && !hasMonSat) return 'ASP_TUE_FRI';
    }
    if (hasMonFri || hasMonSat) return 'ASP_DAILY';
    return 'ASP_DAILY';
  }

  if (d.includes('NO STOPPING') || d.includes('NO STANDING')) return 'NO_STANDING';
  if (d.includes('NO PARKING')) return 'NO_PARKING';
  if (d.includes('TRUCK LOADING')) return 'TRUCK_LOADING';
  if (d.includes('AMBULANCE') || d.includes('FIRE DEPT') || d.includes('DOCTOR LICENSE') || d.includes('AVO')) return 'SPECIAL';
  if ((d.includes('HMP') || d.includes('MUNI METER') || d.includes('METER')) && !d.includes('METERS ARE NOT IN EFFECT')) return 'METERED';

  return 'UNKNOWN';
}

// ==== Schedule Parsing ====
function parseTimeStr(s) {
  if (!s) return null;
  const t = s.toUpperCase().trim();
  if (t === 'MIDNIGHT') return 0;
  if (t === 'NOON') return 720;
  const m = t.match(/(\d{1,2})(?::(\d{2}))?\s*(AM|PM)/);
  if (!m) return null;
  let h = parseInt(m[1]);
  const min = m[2] ? parseInt(m[2]) : 0;
  if (m[3] === 'PM' && h !== 12) h += 12;
  if (m[3] === 'AM' && h === 12) h = 0;
  return h * 60 + min;
}

function parseSchedule(desc) {
  if (!desc) return { days: [], timeRanges: [], anytime: false, arrow: null };
  const d = desc.toUpperCase();
  const result = { days: [], timeRanges: [], anytime: false, arrow: null };

  // Arrow
  if (d.includes('<->') || d.includes('<- ->')) result.arrow = 'both';
  else if (d.includes('-->')) result.arrow = 'towards';
  else if (d.includes('<--')) result.arrow = 'away';

  // Anytime
  if (d.includes('ANYTIME') || d.includes('AT ALL TIMES')) {
    result.anytime = true;
    result.days = [0,1,2,3,4,5,6];
    return result;
  }

  // Day ranges
  const hasMonFri = /MON(DAY)?\s*(THRU|THROUGH|-)\s*FRI(DAY)?/i.test(d);
  const hasMonSat = /MON(DAY)?\s*(THRU|THROUGH|-)\s*SAT(URDAY)?/i.test(d);

  if (hasMonSat) result.days = [1,2,3,4,5,6];
  else if (hasMonFri) result.days = [1,2,3,4,5];
  else {
    const dClean = d.replace(/EXCEPT\s+(SUNDAY|SATURDAY|MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY)/gi, '');
    const dayMap = { MONDAY:1, TUESDAY:2, WEDNESDAY:3, THURSDAY:4, FRIDAY:5, SATURDAY:6, SUNDAY:0 };
    for (const [name, num] of Object.entries(dayMap)) {
      if (dClean.includes(name)) result.days.push(num);
    }
  }

  // Exceptions
  const exceptMatch = d.match(/EXCEPT\s+(SUNDAY|SATURDAY|MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY)/gi);
  if (exceptMatch) {
    const dayMap = { MONDAY:1, TUESDAY:2, WEDNESDAY:3, THURSDAY:4, FRIDAY:5, SATURDAY:6, SUNDAY:0 };
    exceptMatch.forEach(m => {
      const day = m.replace(/EXCEPT\s+/i, '').trim().toUpperCase();
      if (dayMap[day] !== undefined) result.days = result.days.filter(x => x !== dayMap[day]);
    });
  }

  if (result.days.length === 0) result.days = [1,2,3,4,5,6];

  // Parse times
  const timeRe = /(\d{1,2}(?::\d{2})?\s*(?:AM|PM)|MIDNIGHT|NOON)[\s-]+(\d{1,2}(?::\d{2})?\s*(?:AM|PM)|MIDNIGHT|NOON)/gi;
  let tm;
  while ((tm = timeRe.exec(d)) !== null) {
    const start = parseTimeStr(tm[1]);
    const end = parseTimeStr(tm[2]);
    if (start !== null && end !== null) result.timeRanges.push({ start, end });
  }

  return result;
}

// ==== Geometry Functions ====
let OSM_STREETS = {};
// Keyed by canonical uppercase abbreviated street name (e.g. "2 AVE", "SPRING ST")
// as produced by build-oneway-data.js canonicalStreetName().
let OSM_ONEWAY = {};
// TF2-14: CSCL street-width lookup.  Same key format as OSM_ONEWAY.
// Built by scripts/build-street-widths.js → street_widths.json.
// Each entry: [{ polyline: [[lat,lng],...], stWidthFt: <number|null> }, ...]
let OSM_WIDTHS = {};

// Name mapping: NYC uppercase -> OSM title case
const NYC_TO_OSM = {
  'BOWERY': 'Bowery', 'CHRYSTIE STREET': 'Chrystie Street',
  'ELIZABETH STREET': 'Elizabeth Street', 'MOTT STREET': 'Mott Street',
  'MULBERRY STREET': 'Mulberry Street', 'EAST HOUSTON STREET': 'East Houston Street',
  'PRINCE STREET': 'Prince Street', 'SPRING STREET': 'Spring Street',
  'KENMARE STREET': 'Kenmare Street', 'JERSEY STREET': 'Jersey Street',
  'LAFAYETTE STREET': 'Lafayette Street', 'BLEECKER STREET': 'Bleecker Street',
  'GREAT JONES STREET': 'Great Jones Street', 'BOND STREET': 'Bond Street',
  'BROOME STREET': 'Broome Street', 'BROADWAY': 'Broadway',
  'CENTRE STREET': 'Centre Street', '2ND AVENUE': '2nd Avenue',
  '3RD AVENUE': '3rd Avenue', 'COOPER SQUARE': 'Cooper Square',
  'CROSBY STREET': 'Crosby Street', 'DELANCEY STREET': 'Delancey Street',
  'CLEVELAND PLACE': 'Cleveland Place', 'CENTRE MARKET PLACE': 'Centre Market Place',
  'ALLEN STREET': 'Allen Street', 'ELDRIDGE STREET': 'Eldridge Street',
  'FORSYTH STREET': 'Forsyth Street', 'MERCER STREET': 'Mercer Street',
  'RIVINGTON STREET': 'Rivington Street', 'STANTON STREET': 'Stanton Street',
  'WEST HOUSTON STREET': 'West Houston Street', 'EAST 1ST STREET': 'East 1st Street',
  'EAST 2ND STREET': 'East 2nd Street', 'EAST 3RD STREET': 'East 3rd Street',
  'EAST 4TH STREET': 'East 4th Street', 'EAST 5TH STREET': 'East 5th Street',
  'GRAND STREET': 'Grand Street', 'GREENE STREET': 'Greene Street',
  'WEST BROADWAY': 'West Broadway', 'WOOSTER STREET': 'Wooster Street',
  'THOMPSON STREET': 'Thompson Street', 'HOWARD STREET': 'Howard Street',
  // FT-14 join-drop fix (docs/qa/ft14-join-drop-investigation.md): 8 hand-verified
  // alias/co-name entries. Each confirmed 1:1 against the real osm_data.json key list.
  'LENOX AVENUE': 'Malcolm X Boulevard',
  'ADAM C POWELL BOULEVARD': 'Adam Clayton Powell Jr. Boulevard',
  'ADAM CLAYTON POWELL JR BOULEVARD': 'Adam Clayton Powell Jr. Boulevard',
  'ADAM CLAYTON POWELL BOULEVARD': 'Adam Clayton Powell Jr. Boulevard',
  'FRED DOUGLASS BOULEVARD': 'Frederick Douglass Boulevard',
  'AVENUE OF THE AMERICAS': '6th Avenue',
  'AVENUE OF AMERICAS': '6th Avenue',
  'N D PERLMAN PLACE': 'Nathan D. Perlman Place',
  'CATHEDRAL PARKWAY': 'West 110th Street',
};

const osmNameCache = {};
// FT-14 join-drop fix: lazily-built compact-form (spaces stripped, lowercased) index of
// OSM_STREETS keys, used by osmName()'s collision-checked spacing-variant fallback.
// Built lazily because OSM_STREETS is populated after this module's functions are
// defined (see loadData()).
let compactStreetIndex = null;
function buildCompactStreetIndex() {
  const idx = {};
  for (const k of Object.keys(OSM_STREETS)) {
    const compact = k.replace(/\s+/g, '').toLowerCase();
    if (!idx[compact]) idx[compact] = [];
    idx[compact].push(k);
  }
  return idx;
}
// Normalize NYC's weird street names: "EAST    4 STREET" → "EAST 4TH STREET", "2 AVENUE" → "2ND AVENUE"
function normalizeNYCName(name) {
  if (!name) return name;
  // Collapse multiple spaces
  let n = name.replace(/\s+/g, ' ').trim();

  // Convert spelled-out ordinals to numeric: "FIRST AVENUE" → "1ST AVENUE", "SECOND STREET" → "2ND STREET"
  const SPELLED_ORDINALS = {
    'FIRST': '1ST', 'SECOND': '2ND', 'THIRD': '3RD', 'FOURTH': '4TH', 'FIFTH': '5TH',
    'SIXTH': '6TH', 'SEVENTH': '7TH', 'EIGHTH': '8TH', 'NINTH': '9TH', 'TENTH': '10TH',
    'ELEVENTH': '11TH', 'TWELFTH': '12TH', 'THIRTEENTH': '13TH'
  };
  const spelledPattern = new RegExp(`\\b(${Object.keys(SPELLED_ORDINALS).join('|')})\\s+(STREET|AVENUE|PLACE|ROAD|BOULEVARD|DRIVE)\\b`, 'gi');
  n = n.replace(spelledPattern, (match, word, suffix) => {
    return `${SPELLED_ORDINALS[word.toUpperCase()]} ${suffix}`;
  });

  // Add ordinal suffixes to bare numbers before STREET/AVENUE/etc.
  // "EAST 4 STREET" → "EAST 4TH STREET", "2 AVENUE" → "2ND AVENUE"
  n = n.replace(/\b(\d+)\s+(STREET|AVENUE|PLACE|ROAD|BOULEVARD|DRIVE)\b/gi, (match, num, suffix) => {
    const d = parseInt(num);
    let ord;
    if (d % 100 >= 11 && d % 100 <= 13) ord = 'TH';
    else if (d % 10 === 1) ord = 'ST';
    else if (d % 10 === 2) ord = 'ND';
    else if (d % 10 === 3) ord = 'RD';
    else ord = 'TH';
    return `${d}${ord} ${suffix}`;
  });
  return n;
}

function osmName(nycName) {
  if (!nycName) return null;
  // Normalize first, then uppercase
  const normalized = normalizeNYCName(nycName);
  const upper = normalized.toUpperCase().trim();
  if (osmNameCache[upper] !== undefined) return osmNameCache[upper];

  if (NYC_TO_OSM[upper]) { osmNameCache[upper] = NYC_TO_OSM[upper]; return NYC_TO_OSM[upper]; }

  // Smart title-case with ordinal handling
  const titled = upper.replace(/\b(\d+)(ST|ND|RD|TH)\b/gi, (_, n, suf) => n + suf.toLowerCase())
    .replace(/\b[A-Z]+/g, w => {
      if (/^\d/.test(w)) return w;
      return w.charAt(0) + w.slice(1).toLowerCase();
    })
    .replace(/\bFdr\b/gi, 'FDR');
  if (OSM_STREETS[titled]) { osmNameCache[upper] = titled; return titled; }

  // Case-insensitive match
  for (const k of Object.keys(OSM_STREETS)) {
    if (k.toUpperCase() === upper) { osmNameCache[upper] = k; return k; }
  }

  // Suffix variations
  const variations = [
    titled,
    titled.replace(/ Street$/, ' St'),
    titled.replace(/ Avenue$/, ' Ave'),
    titled.replace(/ St$/, ' Street'),
    titled.replace(/ Ave$/, ' Avenue'),
    titled.replace(/ Place$/, ' Pl'),
    titled.replace(/ Pl$/, ' Place'),
    // FT-14 join-drop fix: SAINT <-> ST bidirectional swap (e.g. NYC "St Nicholas
    // Avenue" <-> OSM "Saint Nicholas Avenue"). Candidates still must exact-match a
    // real OSM key below, and OSM has exactly 3 "Saint"-prefixed streets citywide, so
    // there's no room for an accidental wrong-street match.
    titled.replace(/\bSt\b/g, 'Saint'),
    titled.replace(/\bSaint\b/g, 'St'),
  ];
  for (const v of variations) {
    if (OSM_STREETS[v]) { osmNameCache[upper] = v; return v; }
  }

  // FT-14 join-drop fix: collision-checked compact-spacing fallback. Strips all
  // internal spaces from the candidate and compares against a precomputed compact-form
  // index of OSM street names (e.g. NYC "LA GUARDIA PLACE" / OSM "LaGuardia Place" both
  // compact to "laguardiaplace"). Only accepted when the compact form uniquely
  // identifies exactly one OSM street -- citywide there are only 3 compact-form
  // collisions, and all 3 are pre-existing OSM duplicate spellings of the SAME physical
  // street (Vandam St / Van Dam St, two spellings each of the Williamsburg Bridge
  // Bikepath and the Manhattan Bridge lower level), so an unambiguous match can never
  // misroute a sign onto a different street.
  if (!compactStreetIndex) compactStreetIndex = buildCompactStreetIndex();
  const compactCandidate = upper.replace(/\s+/g, '').toLowerCase();
  const compactMatches = compactStreetIndex[compactCandidate];
  if (compactMatches && compactMatches.length === 1) {
    osmNameCache[upper] = compactMatches[0];
    return compactMatches[0];
  }

  osmNameCache[upper] = null;
  return null;
}

// ==== One-way derivation (FT-11) ====
// Translate a NYC-normalized street name (e.g. "2ND AVENUE", "SPRING STREET")
// to the canonical uppercase abbreviated key used as osm_oneway.json keys
// (e.g. "2 AVE", "SPRING ST").  Mirrors canonicalStreetName() in build-oneway-data.js.
const ONEWAY_SUFFIX_NORMALIZE = [
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

const onewayNameCache = {};
function canonicalNameForOneway(nycName) {
  if (!nycName) return null;
  if (onewayNameCache[nycName] !== undefined) return onewayNameCache[nycName];
  let s = nycName.toUpperCase().trim();
  // Drop ordinal suffixes on digits (1ST → 1, 2ND → 2, 3RD → 3, 23RD → 23)
  s = s.replace(/(\d+)(ST|ND|RD|TH)\b/g, '$1');
  for (const [re, rep] of ONEWAY_SUFFIX_NORMALIZE) s = s.replace(re, rep);
  s = s.replace(/\s+/g, ' ').trim();
  // Famous aliases
  if (s === 'AVE OF THE AMERICAS') s = '6 AVE';
  if (s === 'AVE OF AMERICAS') s = '6 AVE';
  onewayNameCache[nycName] = s;
  return s;
}

// Find the OSM-oneway way that best covers the block midpoint.
// Returns the way object {polyline, oneway} or null.
function findBestOnewayWay(ways, midLat, midLng) {
  let best = null;
  let bestDist = Infinity;
  for (const way of ways) {
    const poly = way.polyline;
    if (!poly || poly.length < 2) continue;
    // Find closest point on this polyline to the block midpoint
    for (let i = 0; i < poly.length - 1; i++) {
      const [aLat, aLng] = poly[i];
      const [bLat, bLng] = poly[i + 1];
      const abLat = bLat - aLat, abLng = bLng - aLng;
      const apLat = midLat - aLat, apLng = midLng - aLng;
      const ab2 = abLat * abLat + abLng * abLng;
      let t = ab2 > 0 ? (apLat * abLat + apLng * abLng) / ab2 : 0;
      t = Math.max(0, Math.min(1, t));
      const pLat = aLat + t * abLat;
      const pLng = aLng + t * abLng;
      const dLat = (midLat - pLat) * 111320;
      const dLng = (midLng - pLng) * 111320 * Math.cos(midLat * Math.PI / 180);
      const dist = Math.sqrt(dLat * dLat + dLng * dLng);
      if (dist < bestDist) {
        bestDist = dist;
        best = way;
      }
    }
  }
  // Only accept if the best way is within 100m (noise guard for coverage gaps)
  return bestDist < 100 ? best : null;
}

// Derive oneway fields for a segment given its block and blockGeo.
// Returns { oneway: boolean, oneway_toward: "from"|"to"|undefined }.
// Additive only — existing segment fields are not modified.
function getOnewayFields(block, blockGeo) {
  const canonKey = canonicalNameForOneway(block.street);
  if (!canonKey) return { oneway: false };

  const ways = OSM_ONEWAY[canonKey];
  if (!ways || ways.length === 0) return { oneway: false };

  // Filter to only directional ways
  const directionalWays = ways.filter(w => w.oneway === 'yes' || w.oneway === 'reverse');
  if (directionalWays.length === 0) return { oneway: false };

  // Find the midpoint of the (possibly setback-trimmed) block line
  const line = blockGeo.line;
  const mid = Math.floor(line.length / 2);
  const midLat = line[mid][0];
  const midLng = line[mid][1];

  const bestWay = findBestOnewayWay(directionalWays, midLat, midLng);
  if (!bestWay) return { oneway: false };

  // Compute direction vectors using geographic coordinates.
  // Segment direction: line[0] → line[last]
  const segFirst = line[0];
  const segLast = line[line.length - 1];
  const segDLat = (segLast[0] - segFirst[0]) * 111320;
  const segDLng = (segLast[1] - segFirst[1]) * 111320 * Math.cos(((segFirst[0] + segLast[0]) / 2) * Math.PI / 180);

  // OSM way direction: polyline[0] → polyline[last]
  const poly = bestWay.polyline;
  const wayFirst = poly[0];
  const wayLast = poly[poly.length - 1];
  const wayDLat = (wayLast[0] - wayFirst[0]) * 111320;
  const wayDLng = (wayLast[1] - wayFirst[1]) * 111320 * Math.cos(((wayFirst[0] + wayLast[0]) / 2) * Math.PI / 180);

  // Dot product: positive means segment and way run in the same direction
  const dot = segDLat * wayDLat + segDLng * wayDLng;

  // oneway="yes": legal travel is in polyline order (wayFirst → wayLast)
  // oneway="reverse": legal travel is against polyline order (wayLast → wayFirst)
  let legalTravelMatchesSeg;
  if (bestWay.oneway === 'yes') {
    // Legal travel direction matches way direction; matches segment direction iff dot > 0
    legalTravelMatchesSeg = dot > 0;
  } else {
    // oneway="reverse": legal travel is opposite way direction; matches segment iff dot < 0
    legalTravelMatchesSeg = dot < 0;
  }

  // If legal travel goes in the same direction as seg (line[0]→line[last] = ptFrom→ptTo),
  // then legal travel heads toward "to". Otherwise toward "from".
  const oneway_toward = legalTravelMatchesSeg ? 'to' : 'from';
  return { oneway: true, oneway_toward };
}

function geoDist(lat1, lng1, lat2, lng2) {
  const dLat = (lat2 - lat1) * 111320;
  const dLng = (lng2 - lng1) * 111320 * Math.cos((lat1 + lat2) / 2 * Math.PI / 180);
  return Math.sqrt(dLat * dLat + dLng * dLng);
}

function cumulativeDists(pts) {
  const d = [0];
  for (let i = 1; i < pts.length; i++) {
    d.push(d[i-1] + geoDist(pts[i-1][0], pts[i-1][1], pts[i][0], pts[i][1]));
  }
  return d;
}

function closestPointOnStreet(streetName, lat, lng) {
  const chains = OSM_STREETS[streetName];
  if (!chains) return null;
  let best = null;
  for (let ci = 0; ci < chains.length; ci++) {
    const chain = chains[ci];
    for (let i = 0; i < chain.length - 1; i++) {
      const [aLat, aLng] = chain[i];
      const [bLat, bLng] = chain[i+1];
      const abLat = bLat - aLat, abLng = bLng - aLng;
      const apLat = lat - aLat, apLng = lng - aLng;
      const ab2 = abLat*abLat + abLng*abLng;
      let t = ab2 > 0 ? (apLat*abLat + apLng*abLng) / ab2 : 0;
      t = Math.max(0, Math.min(1, t));
      const pLat = aLat + t * abLat, pLng = aLng + t * abLng;
      const d = geoDist(lat, lng, pLat, pLng);
      if (!best || d < best.dist) {
        best = { chainIdx: ci, segIdx: i, frac: t, pt: [pLat, pLng], dist: d };
      }
    }
  }
  return best;
}

const intersectionCache = {};
function findIntersection(street1, street2) {
  const key = [street1, street2].sort().join('|');
  if (intersectionCache[key] !== undefined) return intersectionCache[key];

  const chains1 = OSM_STREETS[street1];
  const chains2 = OSM_STREETS[street2];
  if (!chains1 || !chains2) { intersectionCache[key] = null; return null; }

  let best = null;
  for (const c1 of chains1) {
    for (let i = 0; i < c1.length - 1; i++) {
      for (const c2 of chains2) {
        for (let j = 0; j < c2.length - 1; j++) {
          const pt = segSegClosest(c1[i], c1[i+1], c2[j], c2[j+1]);
          if (pt && (!best || pt.dist < best.dist)) best = pt;
        }
      }
    }
  }

  const result = (best && best.dist < 30) ? best.pt : null;
  intersectionCache[key] = result;
  return result;
}

function segSegClosest(a1, a2, b1, b2) {
  const ix = lineIntersect(a1, a2, b1, b2);
  if (ix) return { pt: ix, dist: 0 };

  let best = null;
  const pairs = [[a1, b1, b2], [a2, b1, b2], [b1, a1, a2], [b2, a1, a2]];
  for (const [pt, s1, s2] of pairs) {
    const proj = projectPointOnSeg(pt, s1, s2);
    const d = geoDist(pt[0], pt[1], proj[0], proj[1]);
    if (!best || d < best.dist) {
      const mid = [(pt[0]+proj[0])/2, (pt[1]+proj[1])/2];
      best = { pt: mid, dist: d };
    }
  }
  return best;
}

function lineIntersect(a1, a2, b1, b2) {
  const d1Lat = a2[0]-a1[0], d1Lng = a2[1]-a1[1];
  const d2Lat = b2[0]-b1[0], d2Lng = b2[1]-b1[1];
  const cross = d1Lat*d2Lng - d1Lng*d2Lat;
  if (Math.abs(cross) < 1e-12) return null;
  const t = ((b1[0]-a1[0])*d2Lng - (b1[1]-a1[1])*d2Lat) / cross;
  const u = ((b1[0]-a1[0])*d1Lng - (b1[1]-a1[1])*d1Lat) / cross;
  if (t >= 0 && t <= 1 && u >= 0 && u <= 1) {
    return [a1[0] + t*d1Lat, a1[1] + t*d1Lng];
  }
  return null;
}

function projectPointOnSeg(pt, s1, s2) {
  const dLat = s2[0]-s1[0], dLng = s2[1]-s1[1];
  const len2 = dLat*dLat + dLng*dLng;
  if (len2 < 1e-14) return s1;
  let t = ((pt[0]-s1[0])*dLat + (pt[1]-s1[1])*dLng) / len2;
  t = Math.max(0, Math.min(1, t));
  return [s1[0] + t*dLat, s1[1] + t*dLng];
}

function extractPolylineBetween(streetOsmName, ptA, ptB) {
  const chains = OSM_STREETS[streetOsmName];
  if (!chains) return null;
  const locA = closestPointOnStreet(streetOsmName, ptA[0], ptA[1]);
  const locB = closestPointOnStreet(streetOsmName, ptB[0], ptB[1]);
  if (!locA || !locB) return null;
  if (locA.chainIdx !== locB.chainIdx) return [ptA, ptB];

  const chain = chains[locA.chainIdx];
  let startLoc, endLoc;
  if (locA.segIdx < locB.segIdx || (locA.segIdx === locB.segIdx && locA.frac <= locB.frac)) {
    startLoc = locA; endLoc = locB;
  } else {
    startLoc = locB; endLoc = locA;
  }

  const result = [startLoc.pt];
  for (let i = startLoc.segIdx + 1; i <= endLoc.segIdx; i++) {
    result.push(chain[i]);
  }
  result.push(endLoc.pt);
  return result;
}

// Intersection setback: block-face polylines emitted by extractPolylineBetween()
// start/end at the centerline crossing of the intersecting street (~6-7m into the
// intersection box). Trimming each end by INTERSECTION_SETBACK_M moves the visible
// endpoints to approximately the curbline. See docs/tile-geometry-investigation.md.
const INTERSECTION_SETBACK_M = 10;
const INTERSECTION_SETBACK_FT = INTERSECTION_SETBACK_M * 3.28084; // ≈ 32.8ft

function trimIntersectionSetback(blockGeo) {
  if (!blockGeo) return blockGeo;
  const { blockLenFt } = blockGeo;
  // Skip blocks too short to safely trim (need >3× setback to leave a usable middle)
  if (blockLenFt < INTERSECTION_SETBACK_FT * 3) return blockGeo;
  const trimmedLine = extractSubSegment(blockGeo, INTERSECTION_SETBACK_FT, blockLenFt - INTERSECTION_SETBACK_FT);
  if (!trimmedLine || trimmedLine.length < 2) return blockGeo;
  const trimmedTotalLen = cumulativeDists(trimmedLine);
  const trimmedBlockLenM = trimmedTotalLen[trimmedTotalLen.length - 1];
  return {
    line: trimmedLine,
    totalLen: trimmedTotalLen,
    blockLenM: trimmedBlockLenM,
    blockLenFt: trimmedBlockLenM * 3.28084
  };
}

function getBlockPolyline(block) {
  const streetOsm = osmName(block.street);
  const fromOsm = osmName(block.from);
  const toOsm = osmName(block.to);

  if (!streetOsm || !OSM_STREETS[streetOsm]) return null;

  let ptFrom = null, ptTo = null;
  if (fromOsm && OSM_STREETS[fromOsm]) ptFrom = findIntersection(streetOsm, fromOsm);
  if (toOsm && OSM_STREETS[toOsm]) ptTo = findIntersection(streetOsm, toOsm);
  if (!ptFrom || !ptTo) return null;

  const line = extractPolylineBetween(streetOsm, ptFrom, ptTo);
  if (!line || line.length < 2) return null;

  const totalLen = cumulativeDists(line);
  const blockLenM = totalLen[totalLen.length - 1];
  const blockLenFt = blockLenM * 3.28084;

  const rawBlockGeo = { line, totalLen, blockLenM, blockLenFt };
  return trimIntersectionSetback(rawBlockGeo);
}

function interpolateOnBlockLine(blockGeo, distFt) {
  const distM = distFt / 3.28084;
  const { line, totalLen } = blockGeo;
  const targetM = Math.max(0, Math.min(distM, totalLen[totalLen.length - 1]));

  for (let i = 0; i < line.length - 1; i++) {
    if (targetM >= totalLen[i] && targetM <= totalLen[i + 1]) {
      const segLen = totalLen[i + 1] - totalLen[i];
      const frac = segLen > 0 ? (targetM - totalLen[i]) / segLen : 0;
      return [
        line[i][0] + frac * (line[i+1][0] - line[i][0]),
        line[i][1] + frac * (line[i+1][1] - line[i][1])
      ];
    }
  }
  return line[line.length - 1];
}

function extractSubSegment(blockGeo, startFt, endFt) {
  const startM = startFt / 3.28084;
  const endM = endFt / 3.28084;
  const { line, totalLen } = blockGeo;

  const startPt = interpolateOnBlockLine(blockGeo, startFt);
  const endPt = interpolateOnBlockLine(blockGeo, endFt);
  if (!startPt || !endPt) return null;

  const result = [startPt];
  for (let i = 0; i < line.length; i++) {
    if (totalLen[i] > startM && totalLen[i] < endM) {
      result.push(line[i]);
    }
  }
  result.push(endPt);
  if (result.length < 2) return [startPt, endPt];
  return result;
}

// True perpendicular curb offset (TF2-5).
// Replaces the old compass-based offset that only shifted in lat OR lng, which
// produced diagonal artifacts on NYC's rotated grid (numbered streets ~29° off
// north; East Village on its own skew).
//
// Algorithm:
//   1. Project to a locally metric space: x = lng * cos(latRef), y = lat.
//      This makes the projected plane isotropic (equal-scale in both axes),
//      so perpendiculars are geometrically correct.
//   2. At each point, compute the local street direction by averaging the unit
//      vectors of the incoming and outgoing segments.  Endpoints use the single
//      adjacent segment; interior points average both.
//   3. The two candidate normals perpendicular to direction (dx, dy) are
//      n1 = (+dy, -dx) and n2 = (-dy, +dx) in projected (x, y).
//   4. Select the normal whose dot product with the side's compass unit vector
//      is positive: N→(0,+1), S→(0,−1), E→(+1,0), W→(−1,0).
//      This robustly picks the curb-facing perpendicular for any street angle.
//   5. Offset by the width-class-derived distance along the chosen normal, then
//      unproject.  The distance is chosen by getStreetCurbOffset() below (TF2-10).
//
// Intersection setback (INTERSECTION_SETBACK_M) is handled separately by
// trimIntersectionSetback() — this function handles only lateral curb offset.

// ==== Width-aware curb offset (TF2-10) ====
//
// osm_data.json is geometry-only ({name: [[[lat,lng],...],...]}) — no highway class,
// lanes, or width tags are stored.  The fallback is a name-pattern tier.
//
// WIDE class (~20-25 m curb-to-curb): numbered avenues, named avenues, Broadway,
// Bowery, and the major crosstown streets whose curb-to-curb width is ≥ 20 m.
// Offset target = ~10 m from centerline (parking lane sits ~9-11 m out on these).
// Tuning note: raise CURB_OFFSET_WIDE_METERS toward 11 if avenue lines still look
// mid-lane on very wide avenues (e.g. 5th Ave, Park Ave); lower toward 9 if they
// overshoot the curb on narrower avenues (e.g. 1st Ave, Ave A).
//
// DEFAULT class (~12-16 m curb-to-curb): typical Manhattan cross-streets and
// narrow N/S streets.  Offset target = ~6 m (was 5 m pre-TF2-10).
// Tuning note: raise toward 7 if default-class lines still look mid-lane; 6 m
// places the line comfortably inside the parking/parking-regulation strip on a
// typical 40-50 ft (12-15 m) cross-street.

// --- Tunable constants ---
const CURB_OFFSET_WIDE_METERS    = 10; // avenue-class / wide crosstown streets (tunable)
const CURB_OFFSET_DEFAULT_METERS =  6; // typical side streets (tunable)

// Wide-street name patterns (applied to the NORMALIZED NYC name, e.g. "2ND AVENUE").
// Pattern is tested against the uppercased, normalized street name.
//
// Numbered avenues (1ST … 12TH AVENUE) and named avenues:
const WIDE_AVENUE_RE = /\bAVE(NUE)?\b/;  // matches "AVENUE" AND canonical "AVE" (TF2-14: floor must catch "2 AVE" keys)
// Specific named wide N/S corridors that don't carry "AVENUE":
const WIDE_NS_NAMES = new Set([
  'BROADWAY', 'BOWERY', 'WEST BROADWAY', 'LAFAYETTE STREET',
  'ST NICHOLAS AVENUE', 'ADAM CLAYTON POWELL JR BOULEVARD',
  'FREDERICK DOUGLASS BOULEVARD', 'LENOX AVENUE', 'MALCOLM X BOULEVARD',
  'CONVENT AVENUE', 'AMSTERDAM AVENUE', 'RIVERSIDE DRIVE',
  'CENTRAL PARK WEST', 'FORT WASHINGTON AVENUE', 'AUDUBON AVENUE',
  'EDGECOMBE AVENUE',
]);
// Wide crosstown streets (measured curb-to-curb ≥ ~20 m, confirmed via NYC DOT
// street-width records and street-view spot-checks):
const WIDE_CROSSTOWN_NAMES = new Set([
  'EAST HOUSTON STREET', 'WEST HOUSTON STREET',
  'CANAL STREET', 'DELANCEY STREET',
  'EAST 14TH STREET', 'WEST 14TH STREET',
  'EAST 23RD STREET', 'WEST 23RD STREET',
  'EAST 34TH STREET', 'WEST 34TH STREET',
  'EAST 42ND STREET', 'WEST 42ND STREET',
  'EAST 57TH STREET', 'WEST 57TH STREET',
  'EAST 72ND STREET', 'WEST 72ND STREET',
  'EAST 79TH STREET', 'WEST 79TH STREET',
  'EAST 86TH STREET', 'WEST 86TH STREET',
  'EAST 96TH STREET', 'WEST 96TH STREET',
  'EAST 110TH STREET', 'WEST 110TH STREET',
  'EAST 125TH STREET', 'WEST 125TH STREET',
  // Downtown wide crosstown / diagonal corridors
  'FULTON STREET', 'CHAMBERS STREET', 'VESEY STREET',
  'RECTOR STREET', 'LIBERTY STREET',
]);

/**
 * Return the appropriate curb offset in meters for a given street name.
 * streetName is the normalized NYC name (e.g. "2ND AVENUE", "EAST 2ND STREET").
 *
 * Classification logic (TF2-10):
 *   WIDE  → CURB_OFFSET_WIDE_METERS    (10 m)  — avenue-class, wide crosstowns
 *   DEFAULT → CURB_OFFSET_DEFAULT_METERS (6 m)  — typical side streets
 */

// TF2-12 follow-up: zero-length / sub-2m "stub" segments (identical or nearly identical
// endpoints) render as junk dots near the centerline and contaminated the curb-offset
// validation (0.0m side separations). Drop them from tile output entirely.
function isDegenerateLine(line) {
  if (!line || line.length < 2) return true;
  const a = line[0], b = line[line.length - 1];
  const latM = (b[0] - a[0]) * 111320;
  const lngM = (b[1] - a[1]) * 111320 * Math.cos(a[0] * Math.PI / 180);
  return Math.sqrt(latM * latM + lngM * lngM) < 2;
}

function getStreetCurbOffset(streetName) {
  if (!streetName) return CURB_OFFSET_DEFAULT_METERS;
  const upper = streetName.toUpperCase().trim();

  // 1. Any street containing "AVENUE" (numbered or named)
  if (WIDE_AVENUE_RE.test(upper)) return CURB_OFFSET_WIDE_METERS;

  // 2. Named wide N/S corridors (Broadway, Bowery, named boulevards, etc.)
  if (WIDE_NS_NAMES.has(upper)) return CURB_OFFSET_WIDE_METERS;

  // 3. Wide crosstown streets
  if (WIDE_CROSSTOWN_NAMES.has(upper)) return CURB_OFFSET_WIDE_METERS;

  // 4. PARKWAY or BOULEVARD suffix (FDR Drive handled if needed; rare in Manhattan)
  if (/\bPARKWAY\b|\bBOULEVARD\b/.test(upper)) return CURB_OFFSET_WIDE_METERS;

  return CURB_OFFSET_DEFAULT_METERS;
}

// ==== TF2-14 regen-6: CSCL real-street-width offset (REDESIGNED) ====
//
// REDESIGN RATIONALE (replaces the per-segment divided-carriageway detection from regen-5):
//
// PROBLEM: The old code ran divided-street detection on every getCurbOffsetFromWidth() call,
// using the block midpoint to find nearby CSCL ways within a 40m radius.  Different block
// midpoints along the same street found different subsets of CSCL ways, so the divided
// branch fired for some blocks but not others → offsets ranged 10–18m across one street,
// producing a visible zigzag of parking-line positions along the curb.
//
// ROOT FIX: PRE-COMPUTE one offset per canonical street name in initWidths(), applied
// uniformly to every block on that street.  getCurbOffsetFromWidth() is now a simple
// map lookup — coordinates are ignored (kept in signature for backward compat with callers).
//
// PER-STREET OFFSET ALGORITHM (computed in initWidths()):
//   1. Collect all stWidthFt values for the street's CSCL ways.
//   2. Compute the MEDIAN stWidthFt (robust to outlier short segments with atypical widths).
//   3. Is this street on the DIVIDED_STREET_ALLOW_LIST?
//      YES (Houston, Bowery, Allen, Forsyth, Delancey):
//        These streets have OSM centerlines placed at the full-street center (median
//        center), equidistant from both outer curbs.  CSCL st_width for each carriageway
//        is the paved width of that carriageway alone (median edge → outer curb).
//        The median st_width therefore represents ONE carriageway only.
//        Offset = median_carriageway_half_width + DIVIDED_MEDIAN_ALLOWANCE_M
//        where DIVIDED_MEDIAN_ALLOWANCE_M ≈ 7m accounts for the distance from the
//        OSM centerline to the far carriageway's center.
//        Formula: (medianWidthFt × 0.3048 / 2) + DIVIDED_MEDIAN_ALLOWANCE_M
//        Calibration (E Houston, each carriageway ~41–50 ft ≈ 12.5–15.2m, median ≈ 13.8m):
//          half-carriageway = 13.8/2 = 6.9m; + 7m = 13.9m → target 14m ✓
//        Calibration (Bowery, each carriageway ~28–35 ft ≈ 8.5–10.7m, median ≈ 9.6m):
//          half-carriageway = 9.6/2 = 4.8m; + 7m = 11.8m → target 12–13m ✓
//      NO (2nd Ave, E 2nd St, Mott St, Prince St, most streets):
//        Single-carriageway treatment.
//        Offset = (medianWidthFt × 0.3048 / 2) × CSCL_OFFSET_FRACTION
//        then max with the name-tier floor (CURB_OFFSET_WIDE_METERS / _DEFAULT_METERS)
//        so avenues never regress below the validated 10m name-tier floor.
//   4. Clamp to [CSCL_OFFSET_MIN_M, CSCL_OFFSET_MAX_M].
//
// FALLBACK: streets absent from street_widths.json fall back to getStreetCurbOffset()
// (the name-tier logic); this is stored as the pre-computed value so getCurbOffsetFromWidth
// behaves identically to getStreetCurbOffset for unmatched streets.

const CSCL_OFFSET_FRACTION        = 0.88;  // fraction of single-carriageway half-width
const CSCL_OFFSET_MIN_M           =  4.0;  // minimum offset (very narrow/alley)
const CSCL_OFFSET_MAX_M           = 14.0;  // maximum offset — 18m overshot the curb; 14m
                                            // is the outer bound of a realistic half-width
                                            // (e.g. a 92 ft wide undivided street × 0.3048/2
                                            // × 0.88 ≈ 12.3m, well within 14m)
// For divided/median streets: distance from the OSM full-street centerline (median center)
// to the near carriageway's center.  Houston and Bowery have median widths of ~3–5m,
// so the OSM centerline sits ~7m from the centerline of each carriageway.
const DIVIDED_MEDIAN_ALLOWANCE_M  =  7.0;

// Allow-list of canonical CSCL key names for streets that are genuinely divided
// (OSM centerline at median center, CSCL records each carriageway separately).
// Keep this list small and explicit.  Adding a street here means its CSCL
// median st_width is treated as a single-carriageway width, and
// DIVIDED_MEDIAN_ALLOWANCE_M is added to reach the far curb.
const DIVIDED_STREET_ALLOW_LIST = new Set([
  'E HOUSTON ST',   // East Houston Street (divided east of 6th Ave; also OK for single section)
  'W HOUSTON ST',   // West Houston Street (same physical road)
  'BOWERY',         // Bowery south of Canal: median strip
  'ALLEN ST',       // Allen Street: wide median
  'FORSYTH ST',     // Forsyth Street: paired one-way with Allen
  'DELANCEY ST',    // Delancey: divided around bridge approach
]);

// Pre-computed per-street offset map.  Populated by initWidths().
// Key: canonical street name (same as OSM_WIDTHS key, e.g. "E HOUSTON ST").
// Value: offset in metres (number).
let _perStreetOffset = {};

// Compute median of a numeric array (sorted ascending).
function _median(arr) {
  if (!arr.length) return null;
  const sorted = arr.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// Find ALL CSCL width ways within maxDistM of (midLat, midLng).
// Returns array of { way, dist } sorted by ascending distance.
// Kept for diagnostic use / export; not called by getCurbOffsetFromWidth in regen-6.
function findNearbyWidthWays(ways, midLat, midLng, maxDistM) {
  const results = [];
  for (const way of ways) {
    const poly = way.polyline;
    if (!poly || poly.length < 2) continue;
    let minDist = Infinity;
    for (let i = 0; i < poly.length - 1; i++) {
      const [aLat, aLng] = poly[i];
      const [bLat, bLng] = poly[i + 1];
      const abLat = bLat - aLat, abLng = bLng - aLng;
      const apLat = midLat - aLat, apLng = midLng - aLng;
      const ab2 = abLat * abLat + abLng * abLng;
      let t = ab2 > 0 ? (apLat * abLat + apLng * abLng) / ab2 : 0;
      t = Math.max(0, Math.min(1, t));
      const pLat = aLat + t * abLat;
      const pLng = aLng + t * abLng;
      const dLat = (midLat - pLat) * 111320;
      const dLng = (midLng - pLng) * 111320 * Math.cos(midLat * Math.PI / 180);
      const dist = Math.sqrt(dLat * dLat + dLng * dLng);
      if (dist < minDist) minDist = dist;
    }
    if (minDist <= maxDistM) results.push({ way, dist: minDist });
  }
  results.sort((a, b) => a.dist - b.dist);
  return results;
}

// Kept for export / diagnostic use; no longer called by the main offset path.
function polylineCentroidDist(polyline, refLat, refLng) {
  const cosLat = Math.cos(refLat * Math.PI / 180);
  let minDist = Infinity;
  for (let i = 0; i < polyline.length - 1; i++) {
    const [aLat, aLng] = polyline[i];
    const [bLat, bLng] = polyline[i + 1];
    const abLat = bLat - aLat, abLng = bLng - aLng;
    const apLat = refLat - aLat, apLng = refLng - aLng;
    const ab2 = abLat * abLat + abLng * abLng;
    let t = ab2 > 0 ? (apLat * abLat + apLng * abLng) / ab2 : 0;
    t = Math.max(0, Math.min(1, t));
    const pLat = aLat + t * abLat;
    const pLng = aLng + t * abLng;
    const dLat = (refLat - pLat) * 111320;
    const dLng = (refLng - pLng) * 111320 * cosLat;
    const dist = Math.sqrt(dLat * dLat + dLng * dLng);
    if (dist < minDist) minDist = dist;
  }
  return minDist === Infinity ? 0 : minDist;
}

/**
 * getCurbOffsetFromWidth(streetName, midLat, midLng)
 *
 * TF2-14 regen-6: Returns the pre-computed per-street offset in metres.
 * Coordinates (midLat, midLng) are accepted for signature compatibility but
 * are NOT used — the offset is determined solely by the street name, ensuring
 * every block face on a given street gets the SAME offset (no zigzag).
 *
 * Pre-computation happens in initWidths(); the fallback for unmatched streets
 * is getStreetCurbOffset(streetName) (name-tier logic).
 *
 * @param {string} streetName  - NYC-style name ("EAST HOUSTON STREET")
 * @param {number} midLat      - latitude of block midpoint (unused, compat only)
 * @param {number} midLng      - longitude of block midpoint (unused, compat only)
 * @returns {number}           - offset in metres
 */
function getCurbOffsetFromWidth(streetName, midLat, midLng) {
  const canonKey = canonicalNameForOneway(streetName);
  if (!canonKey) return getStreetCurbOffset(streetName);

  // Return pre-computed value if present (covers both CSCL-matched and fallback streets)
  if (_perStreetOffset[canonKey] !== undefined) return _perStreetOffset[canonKey];

  // No entry at all (initWidths not called, or street not in either lookup) → name-tier
  return getStreetCurbOffset(streetName);
}

const DEG_TO_RAD = Math.PI / 180;
const METERS_PER_DEG_LAT = 111320; // 1° lat ≈ 111,320 m (constant)

// Compass unit vectors in projected space (x = lng*cosLat, y = lat)
const SIDE_COMPASS = {
  N: { x: 0, y: 1 },
  S: { x: 0, y: -1 },
  E: { x: 1, y: 0 },
  W: { x: -1, y: 0 },
};

// offsetPolyline(points, side, offsetMeters)
// offsetMeters defaults to CURB_OFFSET_DEFAULT_METERS; callers pass
// getCurbOffsetFromWidth(block.street, midLat, midLng) (TF2-14) which falls back
// to getStreetCurbOffset(block.street) (TF2-10) when no CSCL width data is available.
function offsetPolyline(points, side, offsetMeters) {
  if (offsetMeters === undefined) offsetMeters = CURB_OFFSET_DEFAULT_METERS;
  if (!points || points.length < 2) return points || [];
  const valid = points.filter(p => Array.isArray(p) && p.length >= 2 && isFinite(p[0]) && isFinite(p[1]));
  if (valid.length < 2) return valid;

  // Reference latitude for the projection (mean of all points)
  const meanLat = valid.reduce((sum, p) => sum + p[0], 0) / valid.length;
  const cosLat = Math.cos(meanLat * DEG_TO_RAD);

  // Project to metric-like plane: x = lng * cosLat, y = lat
  const proj = valid.map(([lat, lng]) => [lng * cosLat, lat]);

  // Compute local street direction unit vector at each point
  const dirs = proj.map((pt, i) => {
    let dx = 0, dy = 0;
    if (i > 0) {
      const segDx = proj[i][0] - proj[i - 1][0];
      const segDy = proj[i][1] - proj[i - 1][1];
      const len = Math.sqrt(segDx * segDx + segDy * segDy);
      if (len > 0) { dx += segDx / len; dy += segDy / len; }
    }
    if (i < proj.length - 1) {
      const segDx = proj[i + 1][0] - proj[i][0];
      const segDy = proj[i + 1][1] - proj[i][1];
      const len = Math.sqrt(segDx * segDx + segDy * segDy);
      if (len > 0) { dx += segDx / len; dy += segDy / len; }
    }
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len > 1e-10) return [dx / len, dy / len];
    // Degenerate point: fall back to overall polyline direction
    const fallDx = proj[proj.length - 1][0] - proj[0][0];
    const fallDy = proj[proj.length - 1][1] - proj[0][1];
    const fallLen = Math.sqrt(fallDx * fallDx + fallDy * fallDy);
    return fallLen > 0 ? [fallDx / fallLen, fallDy / fallLen] : [1, 0];
  });

  // Offset distance in degree-lat units (the unit of y in projected space)
  const offsetDist = offsetMeters / METERS_PER_DEG_LAT;

  const sv = SIDE_COMPASS[side] || { x: 0, y: 1 }; // default N if unrecognised

  // TF2-12 P1: Block-level normal hemisphere selection (Option A).
  //
  // The old code picked which perpendicular hemisphere to offset toward by
  // computing a dot product against the side's compass vector at EACH vertex.
  // On streets running NNW (e.g. Bowery, bearing ~330°), both candidate normals
  // have near-equal dot products with the E or W compass vector.  At bend
  // vertices the averaged direction straddles the ambiguity zone and the
  // hemisphere selection flips, causing W-side points to land on the wrong
  // (road-interior) side and the two sides to visually converge to near zero.
  //
  // Fix: determine which hemisphere is "outward" ONCE using the block face's
  // overall line[0]→line[last] direction vector.  This direction is stable and
  // unambiguous even for bent blocks.  Per-vertex tangent directions are still
  // used for curve smoothness; only the left/right side choice is anchored
  // block-level.
  //
  // signChoice = +1 means n1 (90° CW from direction) is the outward normal;
  // signChoice = -1 means n2 (90° CCW from direction) is the outward normal.
  const overallDx = proj[proj.length - 1][0] - proj[0][0];
  const overallDy = proj[proj.length - 1][1] - proj[0][1];
  const overallLen = Math.sqrt(overallDx * overallDx + overallDy * overallDy);
  const odx = overallLen > 1e-10 ? overallDx / overallLen : 1;
  const ody = overallLen > 1e-10 ? overallDy / overallLen : 0;
  // Candidate normals from the overall direction
  const blockN1x = ody, blockN1y = -odx;   // 90° CW
  const blockN2x = -ody, blockN2y = odx;   // 90° CCW
  const blockDot1 = blockN1x * sv.x + blockN1y * sv.y;
  const blockDot2 = blockN2x * sv.x + blockN2y * sv.y;
  const signChoice = blockDot1 >= blockDot2 ? +1 : -1;

  return proj.map(([px, py], i) => {
    const [dx, dy] = dirs[i];

    // Per-vertex n1 normal (90° CW of local tangent).  Apply the block-level
    // sign to select the correct outward hemisphere at every vertex.
    const n1x = dy, n1y = -dx;
    const nx = signChoice * n1x;
    const ny = signChoice * n1y;

    // Offset in projected space, then unproject (lng = x / cosLat, lat = y)
    const newX = px + nx * offsetDist;
    const newY = py + ny * offsetDist;

    return [
      Math.round(newY * 1e6) / 1e6,
      Math.round((newX / cosLat) * 1e6) / 1e6,
    ];
  });
}

// ==== Sub-segment creation ====
function createSubSegments(block) {
  const signData = block.signs
    .map(s => {
      const cat = classifySign(s.sign_description);
      if (!cat) return null;
      const schedule = parseSchedule(s.sign_description);
      return { sign: s, category: cat, schedule, distance: +(s.distance_from_intersection || 0), arrow: schedule.arrow };
    })
    .filter(Boolean);

  if (signData.length === 0) return [];
  signData.sort((a, b) => a.distance - b.distance);

  const uniqueDists = [...new Set(signData.map(s => s.distance))].sort((a, b) => a - b);

  // For single-sign blocks (or all signs at same distance), cover the whole block
  // Real-world: a <-> sign means the rule applies in both directions to the next sign/end
  if (uniqueDists.length <= 1) {
    // Single position: assume rule covers the whole block
    // Use a generous range: 0 to distance + 100ft (or at least 200ft for block coverage)
    const d = uniqueDists[0];
    const blockEnd = Math.max(d + 100, 200);
    return [{ rules: signData, distStart: 0, distEnd: blockEnd }];
  }

  const signsByDist = {};
  signData.forEach(s => { (signsByDist[s.distance] = signsByDist[s.distance] || []).push(s); });

  // Create zones between sign positions, with the first zone starting at 0
  // and the last zone extending past the last sign
  const boundaries = [0]; // Always start from the beginning of the block
  uniqueDists.forEach(d => {
    if (d > 0) boundaries.push(d);
  });
  // Extend last boundary to cover the end of the block
  // Typical Manhattan block is 250-900ft; add generous buffer past last sign
  const lastDist = uniqueDists[uniqueDists.length - 1];
  boundaries.push(lastDist + Math.max(100, lastDist * 0.3));

  // Deduplicate and sort boundaries
  const uniqueBounds = [...new Set(boundaries)].sort((a, b) => a - b);

  const zones = [];
  for (let i = 0; i < uniqueBounds.length - 1; i++) {
    zones.push({ distStart: uniqueBounds[i], distEnd: uniqueBounds[i + 1], rules: [] });
  }

  // Assign signs to zones based on arrow direction
  // --> (towards): sign applies from this position TOWARDS increasing distance
  // <-- (away): sign applies from this position TOWARDS decreasing distance (back to intersection)
  // <-> (both): sign applies in both directions until the next sign
  // null (no arrow): treat like <-> (applies in both directions)
  uniqueDists.forEach(d => {
    const signsAtD = signsByDist[d];

    signsAtD.forEach(sd => {
      const arrow = sd.arrow;
      const coversBefore = arrow === 'both' || arrow === null || arrow === 'away';
      const coversAfter = arrow === 'both' || arrow === null || arrow === 'towards';

      // Find the zone boundaries for this sign position
      const zoneAtIdx = zones.findIndex(z => z.distStart === d || (d >= z.distStart && d < z.distEnd));

      if (coversAfter) {
        // TF2-13: Isolated "NO PARKING ANYTIME -->" towards-arrow cap.
        //
        // A driveway/garage marker (plate SP-854CA or similar) whose description
        // matches /NO PARKING ANYTIME/i and whose arrow is "towards" physically
        // covers only the driveway apron (~10–15m / ~50ft).  Without capping,
        // the coversAfter loop runs to the block end when no closing sign follows,
        // causing NO_PARKING to dominate the dominant category for all remaining
        // zones.  The fix: when the sign is an isolated towards-NO_PARKING sign
        // with no subsequent closing sign within ~50ft, cap the extension at the
        // zone immediately following the sign position (approx ≤ 50ft) rather
        // than continuing to the block end.
        //
        // A "closing sign" is defined as any other sign position that appears
        // after d in uniqueDists AND within CAP_DIST_FT feet — i.e., the normal
        // break condition (uniqueDists.includes(zones[i].distStart)) would trigger
        // within the cap window.
        //
        // Guard conditions (do NOT cap when any of these hold):
        //   1. The sign's category is not NO_PARKING — only cap NO_PARKING.
        //   2. The sign description is NOT /NO PARKING ANYTIME/i — leave timed
        //      NO PARKING signs (e.g. "NO PARKING 8AM-6PM -->") uncapped because
        //      they legitimately cover longer spans (e.g. school zones).
        //   3. A subsequent sign position exists within CAP_DIST_FT feet — that
        //      means a legitimate zone boundary closes the span naturally, and the
        //      ordinary break condition handles it correctly.
        //   4. The sign has arrow "both" or arrow null — both-direction signs
        //      cover the whole face by design (e.g. "NO PARKING ANYTIME <->").
        //
        // The cap distance (~50ft / 15m) matches the physical footprint of a
        // curb-cut driveway.  Zones beyond that distance fall back to whatever
        // other rules (e.g. ASP_MON_THU) cover those positions.
        const CAP_DIST_FT = 50;
        const isIsolatedNPAnytime =
          sd.category === 'NO_PARKING' &&
          sd.arrow === 'towards' &&
          /NO PARKING ANYTIME/i.test(sd.sign ? sd.sign.sign_description : '') &&
          !uniqueDists.some(otherD => otherD > d && otherD <= d + CAP_DIST_FT);

        // Cover from this sign's position forward to the next sign (or end);
        // for isolated NO_PARKING ANYTIME --> signs, stop after one zone (~≤ 50ft).
        for (let i = zoneAtIdx; i < zones.length; i++) {
          // Stop at the next sign position (if there's a sign there with its own rule)
          if (i > zoneAtIdx && uniqueDists.includes(zones[i].distStart)) break;
          // TF2-13 cap: stop after the immediately adjacent zone for isolated
          // driveway NO_PARKING ANYTIME --> signs (no closing sign within 50ft).
          if (isIsolatedNPAnytime && i > zoneAtIdx) break;
          if (i >= 0) zones[i].rules.push(sd);
        }
      }

      if (coversBefore) {
        // Cover from this sign's position backward to the previous sign (or start)
        const beforeIdx = zones.findIndex(z => z.distEnd === d);
        for (let i = beforeIdx; i >= 0; i--) {
          // Stop at the previous sign position
          if (i < beforeIdx && uniqueDists.includes(zones[i].distEnd)) break;
          if (i >= 0) zones[i].rules.push(sd);
        }
      }
    });
  });

  return zones.filter(z => z.rules.length > 0 && (z.distEnd - z.distStart) >= 1);
}

// ==== Most restrictive category ====
function mostRestrictiveCategory(rules) {
  if (!rules || rules.length === 0) return 'UNKNOWN';
  let best = null;
  let bestPriority = 999;
  for (const r of rules) {
    const cat = r.category;
    if (!cat || !CATEGORIES[cat]) continue;
    if (CATEGORIES[cat].priority < bestPriority) {
      bestPriority = CATEGORIES[cat].priority;
      best = cat;
    }
  }
  return best || 'UNKNOWN';
}

// ==== Tile helpers ====
function getTile(lat, lng) {
  const row = Math.floor((lat - GRID.latMin) / GRID.rowSize);
  const col = Math.floor((lng - GRID.lngMin) / GRID.colSize);
  return {
    row: Math.max(0, Math.min(GRID.rows - 1, row)),
    col: Math.max(0, Math.min(GRID.cols - 1, col))
  };
}

function getSegmentCenter(line) {
  if (!line || line.length === 0) return null;
  const mid = Math.floor(line.length / 2);
  return { lat: line[mid][0], lng: line[mid][1] };
}

// ==== Main ====
async function main() {
  const startTime = Date.now();
  console.log('🅿️  ParkMap Preprocessor');
  console.log('========================\n');

  // 1. Load OSM data
  console.log('📍 Loading OSM street geometry...');
  const osmRaw = fs.readFileSync(OSM_DATA_PATH, 'utf8');
  OSM_STREETS = JSON.parse(osmRaw);
  const streetCount = Object.keys(OSM_STREETS).length;
  console.log(`   Loaded ${streetCount} streets from OSM data`);

  // 1b. Load one-way data (FT-11)
  if (fs.existsSync(OSM_ONEWAY_PATH)) {
    OSM_ONEWAY = JSON.parse(fs.readFileSync(OSM_ONEWAY_PATH, 'utf8'));
    console.log(`   Loaded ${Object.keys(OSM_ONEWAY).length} streets from osm_oneway.json\n`);
  } else {
    console.warn('   WARNING: osm_oneway.json not found — oneway fields will be false for all segments\n');
  }

  // 1c. Load CSCL street-width data (TF2-14)
  // Built by: node scripts/build-street-widths.js
  // Optional — falls back to name-tier offsets when absent.
  if (fs.existsSync(STREET_WIDTHS_PATH)) {
    OSM_WIDTHS = JSON.parse(fs.readFileSync(STREET_WIDTHS_PATH, 'utf8'));
    const widthStreetCount = Object.keys(OSM_WIDTHS).length;
    const widthWayCount = Object.values(OSM_WIDTHS).reduce((n, arr) => n + arr.length, 0);
    console.log(`   Loaded ${widthStreetCount} streets (${widthWayCount} ways) from street_widths.json (TF2-14)\n`);
  } else {
    console.warn('   WARNING: street_widths.json not found — curb offsets will use name-tier fallback only\n');
    console.warn('   Run: node scripts/build-street-widths.js\n');
  }

  // 2. Fetch signs from both Socrata datasets
  console.log('🔄 Fetching parking signs from NYC Socrata API...');
  let allSigns = [];

  // TF2-19: Socrata app token (optional). Raises rate limits, reduces the odds of a
  // throttle-induced page failure. Works fine without it.
  const SOCRATA_HEADERS = {};
  if (process.env.SOCRATA_APP_TOKEN) {
    SOCRATA_HEADERS['X-App-Token'] = process.env.SOCRATA_APP_TOKEN;
    console.log('   Using SOCRATA_APP_TOKEN for API requests\n');
  }

  function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  // TF2-19: completeness gate. 0.5% tolerance allows for normal live-dataset churn
  // mid-pull; anything beyond that means the pull was truncated (regen-5's failure
  // mode: ~40-48% of MAIN dataset rules silently dropped) and the build must abort
  // rather than ship partial tile data.
  const COMPLETENESS_TOLERANCE_FRACTION = 0.005;
  // TF2-19: retry-with-backoff. Up to 5 retries (6 attempts total) per page,
  // exponential backoff, before the build fails loudly instead of silently
  // truncating the pull.
  const RETRY_BACKOFF_MS = [2000, 4000, 8000, 16000, 32000];

  // Helper to fetch paginated dataset
  async function fetchSocrataDataset(baseUrl, label) {
    console.log(`   Fetching ${label}...`);

    // Completeness gate — fetch the authoritative row count BEFORE paging so we
    // have something to validate the pull against once paging is done.
    //
    // QA finding #1 (docs/qa/tf2-19-regen6-qa.md): this probe must get the SAME
    // retry-with-backoff treatment as the paged requests, and must FAIL CLOSED
    // (abort the build) if it can't get a count after exhausting retries — a
    // probe that silently disables itself on a transient network blip defeats
    // the entire point of the completeness gate. No path may proceed with
    // expectedCount left null.
    let expectedCount = null;
    {
      const countUrl = `${baseUrl}?$select=count(*)&borough=Manhattan`;
      let lastError = null;
      const totalAttempts = RETRY_BACKOFF_MS.length + 1; // 1 initial try + 5 retries

      for (let attempt = 1; attempt <= totalAttempts; attempt++) {
        if (attempt > 1) {
          const backoffMs = RETRY_BACKOFF_MS[attempt - 2];
          console.log(`   ${label}: count(*) probe retrying in ${backoffMs / 1000}s (attempt ${attempt}/${totalAttempts})...`);
          await sleep(backoffMs);
        }
        try {
          const countResp = await fetch(countUrl, { headers: SOCRATA_HEADERS });
          if (!countResp.ok) {
            lastError = new Error(`HTTP ${countResp.status}`);
            continue;
          }
          const countData = await countResp.json();
          const parsed = parseInt(countData && countData[0] && countData[0].count, 10);
          if (!Number.isFinite(parsed)) {
            lastError = new Error('malformed count(*) response');
            continue;
          }
          expectedCount = parsed;
          break;
        } catch (e) {
          lastError = e;
        }
      }

      if (expectedCount === null) {
        // Fail closed: never proceed to paging without a validated expected
        // count. Aborts the whole build (main().catch() at the bottom of this
        // file exits non-zero before any tile is written).
        throw new Error(
          `FATAL: ${label} count(*) probe failed after ${totalAttempts} attempts. ` +
          `Last error: ${lastError ? lastError.message : 'unknown'}. ` +
          `Aborting build — refusing to run the completeness gate blind.`
        );
      }
      console.log(`   ${label}: expected ${expectedCount} rows (per $select=count(*))`);
    }

    const signs = [];
    let offset = 0;
    let pageNum = 0;
    let keepFetching = true;

    while (keepFetching) {
      pageNum++;
      // $order=:id gives stable, deterministic pagination across sequential page
      // requests even against a live dataset receiving concurrent writes.
      const url = `${baseUrl}?$limit=${PAGE_SIZE}&$offset=${offset}&$order=:id&borough=Manhattan`;

      let pageData = null;
      let lastError = null;
      const totalAttempts = RETRY_BACKOFF_MS.length + 1; // 1 initial try + 5 retries

      for (let attempt = 1; attempt <= totalAttempts; attempt++) {
        if (attempt > 1) {
          const backoffMs = RETRY_BACKOFF_MS[attempt - 2];
          console.log(`     Page ${pageNum}: retrying in ${backoffMs / 1000}s (attempt ${attempt}/${totalAttempts})...`);
          await sleep(backoffMs);
        }
        process.stdout.write(`     Page ${pageNum}: offset ${offset} (attempt ${attempt}/${totalAttempts})...`);
        try {
          const resp = await fetch(url, { headers: SOCRATA_HEADERS });
          if (!resp.ok) {
            lastError = new Error(`HTTP ${resp.status}`);
            console.log(` HTTP ${resp.status}`);
            continue;
          }
          const data = await resp.json();
          if (!Array.isArray(data)) {
            lastError = new Error('malformed response (not an array)');
            console.log(' malformed response');
            continue;
          }
          pageData = data;
          console.log(` +${data.length}`);
          break;
        } catch (e) {
          lastError = e;
          console.log(` ERROR: ${e.message}`);
        }
      }

      if (pageData === null) {
        // Exhausted all retries — never silently ship a partial pull. Abort the
        // whole build (main().catch() at the bottom of this file exits non-zero
        // before any tile is written).
        throw new Error(
          `FATAL: ${label} fetch failed at offset ${offset} (page ${pageNum}) after ${totalAttempts} attempts. ` +
          `Last error: ${lastError ? lastError.message : 'unknown'}. Aborting build — refusing to ship partial tile data.`
        );
      }

      if (pageData.length === 0) {
        keepFetching = false;
      } else {
        signs.push(...pageData);
        if (pageData.length < PAGE_SIZE) keepFetching = false;
        else offset += PAGE_SIZE;
      }
    }

    console.log(`   ${label}: fetched ${signs.length} rows total`);

    // Completeness gate — abort loudly rather than silently shipping a truncated
    // pull (this is exactly the regen-5 / TF2-19 failure mode). expectedCount is
    // guaranteed non-null here — the probe above throws (fail closed) rather
    // than returning if it can't establish a validated count.
    {
      const tolerance = Math.ceil(expectedCount * COMPLETENESS_TOLERANCE_FRACTION);
      const shortfall = expectedCount - signs.length;
      if (shortfall > tolerance) {
        throw new Error(
          `FATAL: ${label} completeness check failed — expected ~${expectedCount} rows (±${tolerance} tolerance), ` +
          `only fetched ${signs.length} (shortfall ${shortfall}). Aborting build — refusing to ship partial tile data.`
        );
      }
      console.log(`   ${label}: completeness OK (expected ${expectedCount}, fetched ${signs.length}, shortfall ${shortfall <= 0 ? 0 : shortfall} within tolerance ${tolerance})`);
    }

    return signs;
  }

  // Fetch main signs dataset
  const mainSigns = await fetchSocrataDataset(SOCRATA_MAIN, 'Main Signs (nfid-uabd)');
  allSigns.push(...mainSigns);
  
  // Fetch ASP-specific dataset
  const aspSigns = await fetchSocrataDataset(SOCRATA_ASP, 'ASP Signs (2x64-6f34)');
  allSigns.push(...aspSigns);
  
  console.log(`   Total signs fetched: ${allSigns.length} (${mainSigns.length} main + ${aspSigns.length} ASP)\n`);

  // 3. Filter to Manhattan area using State Plane bounds
  console.log('🔍 Filtering signs to Manhattan area...');
  const filtered = allSigns.filter(s => {
    if (!s.sign_x_coord || !s.sign_y_coord) return false;
    const x = +s.sign_x_coord, y = +s.sign_y_coord;
    return x >= SP_BOUNDS.xMin && x <= SP_BOUNDS.xMax && y >= SP_BOUNDS.yMin && y <= SP_BOUNDS.yMax;
  });
  console.log(`   ${filtered.length} signs in Manhattan area (from ${allSigns.length} total)\n`);

  // 3b. Deduplicate signs by street/side/description (same sign registered multiple times)
  console.log('🧹 Deduplicating signs...');
  const seen = new Set();
  const deduped = [];
  let dupCount = 0;
  
  filtered.forEach(sign => {
    // Create unique key from street + block + side + distance + description
    // Must include from/to streets AND distance, otherwise signs at different
    // positions on the same block get wrongly deduped (e.g., same ASP sign
    // posted at 89ft, 245ft, 351ft, 424ft along a block)
    const dist = sign.distance_from_intersection || '0';
    const key = `${sign.on_street}|${sign.from_street}|${sign.to_street}|${sign.side_of_street}|${dist}|${sign.sign_description}`;
    if (!seen.has(key)) {
      seen.add(key);
      deduped.push(sign);
    } else {
      dupCount++;
    }
  });
  console.log(`   Removed ${dupCount} duplicates (${deduped.length} unique signs)\n`);

  // 4. Group signs into blocks
  console.log('📦 Grouping signs into blocks...');
  const blocks = {};
  let skippedInfo = 0;
  deduped.forEach(sign => {
    const desc = (sign.sign_description || '').toUpperCase();
    for (const p of SKIP_PATTERNS) {
      if (desc.includes(p)) { skippedInfo++; return; }
    }

    // Normalize NYC's weird street names (e.g., "EAST    4 STREET" → "EAST 4TH STREET")
    const normStreet = normalizeNYCName(sign.on_street);
    const normFrom = normalizeNYCName(sign.from_street);
    const normTo = normalizeNYCName(sign.to_street);
    const key = `${normStreet} (${normFrom} to ${normTo})`;
    const fullKey = `${key} [${sign.side_of_street}]`;
    if (!blocks[fullKey]) {
      blocks[fullKey] = {
        street: normStreet,
        from: normFrom,
        to: normTo,
        side: sign.side_of_street,
        signs: [],
        blockKey: key
      };
    }
    blocks[fullKey].signs.push(sign);
  });
  console.log(`   ${Object.keys(blocks).length} blocks (skipped ${skippedInfo} informational signs)\n`);

  // 5. Process blocks into segments
  console.log('🗺️  Processing blocks with OSM geometry...');
  const allSegments = [];
  let osmHits = 0, osmMisses = 0;
  const blockKeys = Object.keys(blocks);
  let processed = 0;

  for (const fullKey of blockKeys) {
    processed++;
    if (processed % 500 === 0) {
      process.stdout.write(`   Progress: ${processed}/${blockKeys.length} blocks\r`);
    }

    const block = blocks[fullKey];
    const subSegments = createSubSegments(block);
    const blockGeo = getBlockPolyline(block);

    if (blockGeo) {
      osmHits++;

      // TF2-14: compute block midpoint once for width lookup (shared by all sub-segments).
      // Use the raw (un-offset) block centerline midpoint so the CSCL proximity
      // search stays at the road center rather than the parking-lane offset.
      const blockMid = Math.floor(blockGeo.line.length / 2);
      const blockMidLat = blockGeo.line[blockMid][0];
      const blockMidLng = blockGeo.line[blockMid][1];
      const blockCurbOffset = getCurbOffsetFromWidth(block.street, blockMidLat, blockMidLng);

      if (subSegments.length === 0) {
        // Whole block as unknown
        const offsetLine = offsetPolyline(blockGeo.line, block.side, blockCurbOffset);
        if (!offsetLine || offsetLine.length < 2) continue;
        if (isDegenerateLine(offsetLine)) continue;  // TF2-12: drop zero-length stubs

        const segId = `${block.street}_${block.from}_${block.to}_${block.side}`.replace(/\s+/g, '_');
        const onewayFields0 = getOnewayFields(block, blockGeo);
        allSegments.push({
          id: segId,
          street: block.street,
          from: block.from,
          to: block.to,
          side: block.side,
          line: offsetLine,
          rules: [],
          dominantCategory: 'UNKNOWN',
          oneway: onewayFields0.oneway,
          ...(onewayFields0.oneway_toward !== undefined && { oneway_toward: onewayFields0.oneway_toward })
        });
        continue;
      }

      // Compute oneway fields once per block — all sub-segments share the same
      // street/from/to, so direction is constant across the block face (FT-11).
      const onewayFields = getOnewayFields(block, blockGeo);

      subSegments.forEach((zone, idx) => {
        let line;
        try {
          line = extractSubSegment(blockGeo, zone.distStart, zone.distEnd);
        } catch(e) { return; }
        if (!line || line.length < 2) return;

        const offsetLine = offsetPolyline(line, block.side, blockCurbOffset);
        if (!offsetLine || offsetLine.length < 2) return;
        if (!offsetLine.every(p => isFinite(p[0]) && isFinite(p[1]))) return;
        if (isDegenerateLine(offsetLine)) return;  // TF2-12: drop zero-length stubs

        const rules = zone.rules.map(r => ({
          category: r.category,
          description: r.sign.sign_description || '',
          days: r.schedule.days,
          timeRanges: r.schedule.timeRanges,
          anytime: r.schedule.anytime,
          arrow: r.schedule.arrow
        }));

        const segId = `${block.street}_${block.from}_${block.to}_${block.side}_${idx}`.replace(/\s+/g, '_');
        allSegments.push({
          id: segId,
          street: block.street,
          from: block.from,
          to: block.to,
          side: block.side,
          line: offsetLine,
          rules,
          dominantCategory: mostRestrictiveCategory(zone.rules),
          oneway: onewayFields.oneway,
          ...(onewayFields.oneway_toward !== undefined && { oneway_toward: onewayFields.oneway_toward })
        });
      });
    } else {
      osmMisses++;
      // Skip blocks without OSM geometry (no fallback in tile mode)
    }
  }

  console.log(`   \n   OSM geometry: ${osmHits} hits, ${osmMisses} misses`);
  console.log(`   Generated ${allSegments.length} segments\n`);

  // 6. Assign segments to tiles
  console.log('🧩 Assigning segments to tiles...');
  const tileBuckets = {}; // "row_col" -> [segments]

  for (const seg of allSegments) {
    const center = getSegmentCenter(seg.line);
    if (!center) continue;
    const { row, col } = getTile(center.lat, center.lng);
    const key = `${row}_${col}`;
    if (!tileBuckets[key]) tileBuckets[key] = [];
    tileBuckets[key].push(seg);
  }

  const tileCount = Object.keys(tileBuckets).length;
  console.log(`   ${tileCount} tiles with data\n`);

  // 7. Write tile files
  console.log('💾 Writing tile files...');

  // Clean tiles directory
  if (fs.existsSync(TILES_DIR)) {
    const existing = fs.readdirSync(TILES_DIR);
    for (const f of existing) {
      fs.unlinkSync(path.join(TILES_DIR, f));
    }
  } else {
    fs.mkdirSync(TILES_DIR, { recursive: true });
  }

  let totalSize = 0;
  const tileIndex = [];

  for (const [key, segments] of Object.entries(tileBuckets)) {
    const [row, col] = key.split('_').map(Number);
    const filename = `tile_${row}_${col}.json`;
    const filePath = path.join(TILES_DIR, filename);
    const json = JSON.stringify(segments);
    fs.writeFileSync(filePath, json);
    const size = Buffer.byteLength(json);
    totalSize += size;
    tileIndex.push({ row, col, filename, segmentCount: segments.length });
  }

  // Write index
  const indexData = {
    gridSize: { rows: GRID.rows, cols: GRID.cols },
    latMin: GRID.latMin,
    latMax: GRID.latMax,
    lngMin: GRID.lngMin,
    lngMax: GRID.lngMax,
    rowSize: GRID.rowSize,
    colSize: GRID.colSize,
    totalSegments: allSegments.length,
    totalTiles: tileIndex.length,
    generatedAt: new Date().toISOString(),
    tiles: tileIndex.sort((a, b) => a.row - b.row || a.col - b.col)
  };
  const indexJson = JSON.stringify(indexData, null, 2);
  fs.writeFileSync(path.join(TILES_DIR, 'index.json'), indexJson);
  totalSize += Buffer.byteLength(indexJson);

  // 7b. Sync to iOS Resources path. The iOS app bundles tiles from
  // ios/WePark/WePark/Resources/tiles/ at build time. Keep it in lock-step
  // with TILES_DIR so the iOS app sees the same data as the PWA.
  console.log('🔁 Syncing tiles to iOS Resources path...');
  if (fs.existsSync(IOS_TILES_DIR)) {
    for (const f of fs.readdirSync(IOS_TILES_DIR)) {
      fs.unlinkSync(path.join(IOS_TILES_DIR, f));
    }
  } else {
    fs.mkdirSync(IOS_TILES_DIR, { recursive: true });
  }
  for (const f of fs.readdirSync(TILES_DIR)) {
    fs.copyFileSync(path.join(TILES_DIR, f), path.join(IOS_TILES_DIR, f));
  }

  // 8. Summary
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\n✅ Done in ${elapsed}s`);
  console.log('========================');
  console.log(`   Total segments: ${allSegments.length}`);
  console.log(`   Tiles with data: ${tileIndex.length}`);
  console.log(`   Total file size: ${(totalSize / 1024 / 1024).toFixed(2)} MB`);
  console.log(`   Output: ${TILES_DIR}/`);

  // Category breakdown
  const catCounts = {};
  for (const seg of allSegments) {
    catCounts[seg.dominantCategory] = (catCounts[seg.dominantCategory] || 0) + 1;
  }
  console.log('\n   Category breakdown:');
  for (const [cat, count] of Object.entries(catCounts).sort((a, b) => b[1] - a[1])) {
    console.log(`     ${cat}: ${count}`);
  }
}

// ==== Probe / test export surface (TF2-14 validation) ====
// Exposed so scripts/validate-widths.js can share the EXACT same code path
// without duplicating logic.  Not used by the main() pipeline.
//
// initWidths(data): inject the parsed street_widths.json into OSM_WIDTHS and
//   pre-compute the per-street offset map (_perStreetOffset) used by
//   getCurbOffsetFromWidth().  Must be called before getCurbOffsetFromWidth().
//
// Per-street offset algorithm (TF2-14 regen-6):
//   For each canonical street key in data:
//     1. Collect all non-null stWidthFt values from its ways.
//     2. Compute the median stWidthFt.
//     3. If on DIVIDED_STREET_ALLOW_LIST:
//          offset = (medianWidthFt × 0.3048 / 2) + DIVIDED_MEDIAN_ALLOWANCE_M
//        Else (single carriageway):
//          offset = max((medianWidthFt × 0.3048 / 2) × CSCL_OFFSET_FRACTION,
//                       getStreetCurbOffset(nycName))
//     4. Clamp to [CSCL_OFFSET_MIN_M, CSCL_OFFSET_MAX_M].
//   Streets absent from data fall back to getStreetCurbOffset() at query time.
function initWidths(data) {
  OSM_WIDTHS = data;
  _perStreetOffset = {};

  for (const [canonKey, ways] of Object.entries(data)) {
    const widths = ways.map(w => w.stWidthFt).filter(v => v !== null && v > 0);
    if (widths.length === 0) {
      // No usable width data: store name-tier fallback.
      // We need to reverse-map the canonical key to a NYC name for getStreetCurbOffset.
      // The simplest approach: call getStreetCurbOffset with the canonical key itself
      // (it uses .toUpperCase() which matches the WIDE_NS_NAMES / WIDE_CROSSTOWN_NAMES
      // sets that hold full NYC names).  For the common case (avenues, Bowery) both
      // the canonical key and the NYC name contain "AVE" / "BOWERY" / etc., so this
      // is correct.  For streets that don't match any tier (e.g. "E 2 ST") the
      // function returns CURB_OFFSET_DEFAULT_METERS, which is also correct.
      _perStreetOffset[canonKey] = getStreetCurbOffset(canonKey);
      continue;
    }

    const medianWidthFt = _median(widths);
    const medianWidthM  = medianWidthFt * 0.3048;

    let rawOffset;
    if (DIVIDED_STREET_ALLOW_LIST.has(canonKey)) {
      // Divided / dual-carriageway: OSM centerline at median center.
      // medianWidthM is the paved width of ONE carriageway (median edge → outer curb).
      // The carriageway center sits at medianWidthM/2 from the median edge.
      // The OSM centerline sits ~DIVIDED_MEDIAN_ALLOWANCE_M from the carriageway center.
      // Offset to outer curb = DIVIDED_MEDIAN_ALLOWANCE_M + medianWidthM/2.
      rawOffset = DIVIDED_MEDIAN_ALLOWANCE_M + medianWidthM / 2;
    } else {
      // Single carriageway: offset = half-width × fraction, floored by name-tier.
      const csclOffset = (medianWidthM / 2) * CSCL_OFFSET_FRACTION;
      // Name-tier floor: CSCL can raise but never lower below the validated tier offset.
      // Use canonKey as the streetName arg — getStreetCurbOffset checks for AVENUE,
      // BOWERY, BROADWAY etc. patterns which are present in the canonical key.
      const tierOffset = getStreetCurbOffset(canonKey);
      rawOffset = Math.max(csclOffset, tierOffset);
    }

    _perStreetOffset[canonKey] = Math.min(Math.max(rawOffset, CSCL_OFFSET_MIN_M), CSCL_OFFSET_MAX_M);
  }
}

if (require.main !== module) {
  // Required as a module (by validate-widths.js or tests) — export the probe surface.
  module.exports = {
    canonicalNameForOneway,
    getStreetCurbOffset,
    getCurbOffsetFromWidth,
    findNearbyWidthWays,
    polylineCentroidDist,
    initWidths,
    // Constants exposed for diagnostic printing in the probe
    _CSCL_OFFSET_FRACTION:          CSCL_OFFSET_FRACTION,
    _CSCL_OFFSET_MIN_M:             CSCL_OFFSET_MIN_M,
    _CSCL_OFFSET_MAX_M:             CSCL_OFFSET_MAX_M,
    _DIVIDED_MEDIAN_ALLOWANCE_M:    DIVIDED_MEDIAN_ALLOWANCE_M,
    _DIVIDED_STREET_ALLOW_LIST:     DIVIDED_STREET_ALLOW_LIST,
    // Expose pre-computed map for diagnostics (read-only after initWidths())
    get _perStreetOffset() { return _perStreetOffset; },
  };
} else {
  main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
  });
}
