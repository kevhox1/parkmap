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
const TILES_DIR = path.join(ROOT, 'tiles');

const SOCRATA_BASE = 'https://data.cityofnewyork.us/resource/nfid-uabd.json';
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
};

const osmNameCache = {};
// Normalize NYC's weird street names: "EAST    4 STREET" → "EAST 4TH STREET", "2 AVENUE" → "2ND AVENUE"
function normalizeNYCName(name) {
  if (!name) return name;
  // Collapse multiple spaces
  let n = name.replace(/\s+/g, ' ').trim();
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
  ];
  for (const v of variations) {
    if (OSM_STREETS[v]) { osmNameCache[upper] = v; return v; }
  }

  osmNameCache[upper] = null;
  return null;
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

  return { line, totalLen, blockLenM, blockLenFt };
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

function offsetPolyline(points, side) {
  const offset = 0.00004;
  if (!points || points.length < 2) return points || [];
  const valid = points.filter(p => Array.isArray(p) && p.length >= 2 && isFinite(p[0]) && isFinite(p[1]));
  if (valid.length < 2) return valid;

  const result = [];
  for (let i = 0; i < valid.length; i++) {
    let nx, ny;
    if (i === 0) {
      const dx = valid[1][1] - valid[0][1], dy = valid[1][0] - valid[0][0];
      const len = Math.sqrt(dx*dx + dy*dy);
      if (len === 0) { result.push(valid[i]); continue; }
      nx = -dy / len; ny = dx / len;
    } else if (i === valid.length - 1) {
      const dx = valid[i][1] - valid[i-1][1], dy = valid[i][0] - valid[i-1][0];
      const len = Math.sqrt(dx*dx + dy*dy);
      if (len === 0) { result.push(valid[i]); continue; }
      nx = -dy / len; ny = dx / len;
    } else {
      const dx1 = valid[i][1] - valid[i-1][1], dy1 = valid[i][0] - valid[i-1][0];
      const dx2 = valid[i+1][1] - valid[i][1], dy2 = valid[i+1][0] - valid[i][0];
      const len1 = Math.sqrt(dx1*dx1 + dy1*dy1);
      const len2 = Math.sqrt(dx2*dx2 + dy2*dy2);
      if (len1 === 0 || len2 === 0) { result.push(valid[i]); continue; }
      nx = (-dy1/len1 + -dy2/len2) / 2;
      ny = (dx1/len1 + dx2/len2) / 2;
      const nLen = Math.sqrt(nx*nx + ny*ny);
      if (nLen > 0) { nx /= nLen; ny /= nLen; }
    }

    let mult = 0;
    if (side === 'E' || side === 'N') mult = -1;
    else if (side === 'W' || side === 'S') mult = 1;

    result.push([
      Math.round((valid[i][0] + nx * offset * mult) * 1e6) / 1e6,
      Math.round((valid[i][1] + ny * offset * mult) * 1e6) / 1e6
    ]);
  }
  return result;
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

  if (uniqueDists.length <= 1) {
    return [{ rules: signData, distStart: Math.max(0, uniqueDists[0] - 30), distEnd: uniqueDists[0] + 30 }];
  }

  const signsByDist = {};
  signData.forEach(s => { (signsByDist[s.distance] = signsByDist[s.distance] || []).push(s); });

  const boundaries = [];
  if (uniqueDists[0] > 15) boundaries.push(0);
  boundaries.push(...uniqueDists);
  boundaries.push(uniqueDists[uniqueDists.length - 1] + 40);

  const zones = [];
  for (let i = 0; i < boundaries.length - 1; i++) {
    zones.push({ distStart: boundaries[i], distEnd: boundaries[i + 1], rules: [] });
  }

  uniqueDists.forEach(d => {
    const signsAtD = signsByDist[d];
    const zoneAfterIdx = zones.findIndex(z => z.distStart === d);
    const zoneBeforeIdx = zones.findIndex(z => z.distEnd === d);

    signsAtD.forEach(sd => {
      const arrow = sd.arrow;
      let coversBefore = arrow === 'both' || arrow === null || arrow === 'away';
      let coversAfter = arrow === 'both' || arrow === null || arrow === 'towards';

      if (coversBefore && zoneBeforeIdx >= 0) zones[zoneBeforeIdx].rules.push(sd);
      if (coversAfter && zoneAfterIdx >= 0) zones[zoneAfterIdx].rules.push(sd);
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
  console.log(`   Loaded ${streetCount} streets from OSM data\n`);

  // 2. Fetch signs from Socrata API
  console.log('🔄 Fetching parking signs from NYC Socrata API...');
  let allSigns = [];
  let offset = 0;
  let keepFetching = true;
  let pageNum = 0;

  while (keepFetching) {
    pageNum++;
    const url = `${SOCRATA_BASE}?$limit=${PAGE_SIZE}&$offset=${offset}&borough=Manhattan`;
    process.stdout.write(`   Page ${pageNum}: fetching offset ${offset}...`);

    try {
      const resp = await fetch(url);
      if (!resp.ok) {
        console.log(` HTTP ${resp.status} - stopping`);
        break;
      }
      const data = await resp.json();
      if (!Array.isArray(data) || data.length === 0) {
        console.log(' no more data');
        keepFetching = false;
        break;
      }
      allSigns.push(...data);
      console.log(` got ${data.length} signs (total: ${allSigns.length})`);
      if (data.length < PAGE_SIZE) keepFetching = false;
      else offset += PAGE_SIZE;
    } catch (e) {
      console.log(` ERROR: ${e.message}`);
      break;
    }
  }
  console.log(`   Total signs fetched: ${allSigns.length}\n`);

  // 3. Filter to Manhattan area using State Plane bounds
  console.log('🔍 Filtering signs to Manhattan area...');
  const filtered = allSigns.filter(s => {
    if (!s.sign_x_coord || !s.sign_y_coord) return false;
    const x = +s.sign_x_coord, y = +s.sign_y_coord;
    return x >= SP_BOUNDS.xMin && x <= SP_BOUNDS.xMax && y >= SP_BOUNDS.yMin && y <= SP_BOUNDS.yMax;
  });
  console.log(`   ${filtered.length} signs in Manhattan area (from ${allSigns.length} total)\n`);

  // 4. Group signs into blocks
  console.log('📦 Grouping signs into blocks...');
  const blocks = {};
  let skippedInfo = 0;
  filtered.forEach(sign => {
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

      if (subSegments.length === 0) {
        // Whole block as unknown
        const offsetLine = offsetPolyline(blockGeo.line, block.side);
        if (!offsetLine || offsetLine.length < 2) continue;

        const segId = `${block.street}_${block.from}_${block.to}_${block.side}`.replace(/\s+/g, '_');
        allSegments.push({
          id: segId,
          street: block.street,
          from: block.from,
          to: block.to,
          side: block.side,
          line: offsetLine,
          rules: [],
          dominantCategory: 'UNKNOWN'
        });
        continue;
      }

      subSegments.forEach((zone, idx) => {
        let line;
        try {
          line = extractSubSegment(blockGeo, zone.distStart, zone.distEnd);
        } catch(e) { return; }
        if (!line || line.length < 2) return;

        const offsetLine = offsetPolyline(line, block.side);
        if (!offsetLine || offsetLine.length < 2) return;
        if (!offsetLine.every(p => isFinite(p[0]) && isFinite(p[1]))) return;

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
          dominantCategory: mostRestrictiveCategory(zone.rules)
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

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
