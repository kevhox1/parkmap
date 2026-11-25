#!/usr/bin/env node
/**
 * scripts/diff-tiles-days.js
 *
 * Rule-days drift + verdict diff between two tile directories built from IDENTICAL
 * sign data (SIGNS_CACHE_PATH + TILES_OUTPUT_DIR, see build/preprocess.js).
 *
 *   node scripts/diff-tiles-days.js <beforeDir> <afterDir> [--json out.json]
 *
 * Part 1: per-rule `days` changes grouped by sign family, with example segment ids.
 * Part 2: green/red verdict moves per goal x time, using a MINIMAL Node port of the iOS
 *   engine (ParkingRulesEngine.isFree + ParkingGoals.match, midnight-aware ranges from
 *   PR #189). The repo had no Node evaluator, so this is the port. Port notes:
 *   - ET wall clock as a linear minute axis (no DST: the probe dates are DST-free).
 *   - ASP suspensions are not applied (none fall inside the probe dates).
 *   - Goals per ParkingGoals.swift: A Few Hours = now -> min(+3h, overnightEnd);
 *     Overnight = now -> next 7AM; Park & Forget = first of offsets 8,4,2 days that is free.
 *   - Running meters are not free (ignoringMeteredPayment = false).
 */
const fs = require('fs');
const path = require('path');

function load(dir) {
  const m = new Map();
  for (const f of fs.readdirSync(dir)) {
    if (!f.startsWith('tile_') || !f.endsWith('.json')) continue;
    for (const seg of JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'))) m.set(seg.id, seg);
  }
  return m;
}

// ---- engine port ------------------------------------------------------------------
const ASP_DAYS = {
  ASP_MON_THU: d => d === 1 || d === 4,
  ASP_TUE_FRI: d => d === 2 || d === 5,
  ASP_OVERNIGHT_MWF: d => d === 1 || d === 3 || d === 5,
  ASP_OVERNIGHT_TTHS: d => d === 2 || d === 4 || d === 6,
  ASP_DAILY: d => d >= 1 && d <= 6,
};
const endMinute = tr => (tr.end === 0 ? 1440 : tr.end);
const wraps = tr => tr.start >= endMinute(tr);
function overlaps(tr, dayMid, from, until) {
  const rStart = dayMid + tr.start;
  const rEnd = endMinute(tr) === 1440 ? dayMid + 1440 : dayMid + (wraps(tr) ? 1440 : 0) + tr.end;
  return rStart < until && rEnd > from;
}
// UNKNOWN-is-restriction switch (the engine change Kevin is making: an UNKNOWN rule restricts during its
// stated days/times, or all the time when it states none). Off = today's engine (UNKNOWN is a no-op).
// Enable with env UNKNOWN_RESTRICTS=1 or setUnknownRestricts(true).
let UNKNOWN_RESTRICTS = process.env.UNKNOWN_RESTRICTS === '1';
function setUnknownRestricts(v) { UNKNOWN_RESTRICTS = !!v; }
// t = minutes on a linear ET axis; day 0 = a Sunday.
function isFree(seg, from, until) {
  const rules = seg.rules || [];
  if (!rules.length) return true;
  const fromDay = Math.floor(from / 1440), untilDay = Math.floor(until / 1440);
  const dayCount = Math.max(0, untilDay - fromDay);
  for (const r of rules) {
    if (r.anytime) return false;
    for (let off = -1; off <= dayCount; off++) {
      const dayMid = (fromDay + off) * 1440;
      const wStart = off === 0 ? from : dayMid;
      const wEnd = off === dayCount ? until : dayMid + 1440;
      const dow = (((fromDay + off) % 7) + 7) % 7;
      const cat = r.category;
      const hit = tr => (off >= 0 || wraps(tr)) && overlaps(tr, dayMid, from, until);
      if (ASP_DAYS[cat]) {
        if (!ASP_DAYS[cat](dow)) continue;
        if (r.days.length && !r.days.includes(dow)) continue;
        if (!r.timeRanges.length) { if (off < 0) continue; if (wEnd > wStart) return false; continue; }
        for (const tr of r.timeRanges) if (hit(tr)) return false;
      } else if (['NO_PARKING', 'TRUCK_LOADING', 'NO_STANDING', 'SPECIAL'].includes(cat) || (UNKNOWN_RESTRICTS && cat === 'UNKNOWN')) {
        if (r.days.length && !r.days.includes(dow)) continue;
        if (!r.timeRanges.length) {
          if (off < 0) continue;
          if (cat === 'UNKNOWN' && !r.days.length) { if (wEnd > wStart) return false; continue; } // states nothing: all the time
          if (r.days.length && wEnd > wStart) return false;
          continue;
        }
        for (const tr of r.timeRanges) if (hit(tr)) return false;
      } else if (cat === 'METERED') {
        if (r.days.length && !r.days.includes(dow)) continue;
        if (!r.timeRanges.length) continue;
        for (const tr of r.timeRanges) if (hit(tr)) return false;
      }
    }
  }
  return true;
}
function overnightEnd(from) {
  const day = Math.floor(from / 1440);
  const today7 = day * 1440 + 420;
  return today7 > from ? today7 : (day + 1) * 1440 + 420;
}
const GOALS = {
  'A Few Hours': (s, from) => isFree(s, from, Math.min(from + 180, overnightEnd(from))),
  'Overnight': (s, from) => isFree(s, from, overnightEnd(from)),
  'Park & Forget': (s, from) => [8, 4, 2].some(o => isFree(s, from, (Math.floor(from / 1440) + o) * 1440)),
};
// Day 0 = Sun 2026-12-06 (no DST change inside the 8-day horizon).
const TIMES = {
  'Tue 10 AM': 2 * 1440 + 600,
  'Tue 8 PM': 2 * 1440 + 1200,
  'Sat 2 PM': 6 * 1440 + 840,
  'Sun 10 AM': 7 * 1440 + 600,
};

// ---- families ---------------------------------------------------------------------
const DAYTOK = '(MON(?:DAY)?|TUE(?:S(?:DAY)?)?|WED(?:NESDAY)?|THU(?:RS?(?:DAY)?)?|FRI(?:DAY)?|SAT(?:URDAY)?|SUN(?:DAY)?)';
function family(desc) {
  const d = (desc || '').toUpperCase();
  const hasAll = /\bALL DAYS\b|\bDAILY\b/.test(d);
  const noAll = d.replace(/\bALL DAYS\b/g, '');
  const hasExplicit = new RegExp('\\b' + DAYTOK + '\\b').test(noAll.replace(/EXCEPT\s+\w+/g, ''));
  if (hasAll && hasExplicit) return 'ALL DAYS next to an explicit day clause (e.g. "7PM-7AM ALL DAYS SUNDAY 7AM-7PM")';
  if (/\bALL DAY\b(?!S)/.test(d) && /SATURDAY|SUNDAY|SAT\b|SUN\b/.test(d)) return 'weekday window + "SAT & SUN ALL DAY" clause (taxi/bus stand)';
  if (new RegExp('\\b(MON|MONDAY)\\s*(THRU|THROUGH|-)\\s*(FRI|FRIDAY)\\b').test(d) && new RegExp('\\b(SAT|SATURDAY|SUN|SUNDAY)\\b').test(d.replace(/EXCEPT\s+\w+/g, ''))) return 'MON-FRI clause + weekend clause (weekend part was dropped)';
  if (/EXCEPT\s+(SUNDAY|SATURDAY|MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY|SAT|SUN|MON|TUE|WED|THU|FRI)/.test(d) && !new RegExp('\\b' + DAYTOK + '\\b').test(d.replace(/EXCEPT\s+\w+/g, ''))) return 'EXCEPT <day> only (previously defaulted to Mon-Sat)';
  if (new RegExp('\\b' + DAYTOK + '\\s*(THRU|THROUGH|TO|-)\\s*' + DAYTOK + '\\b').test(d)) return 'day range other than MON-SAT / MON-FRI (e.g. FRI-SUN, WEDNESDAY-SUNDAY)';
  if (/\b(SAT|SUN|MON|TUES?|WED|THURS?|FRI)\b/.test(d)) return 'abbreviated day names (SAT & SUN, MON THRU FRI ...)';
  if (!new RegExp('\\b' + DAYTOK + '\\b').test(d) && /EXCEPT/.test(d)) return 'no day named, EXCEPT <non-day> (previously defaulted to Mon-Sat)';
  return 'other';
}

// --green-table <mainDir> <newDir>: green counts per goal x probe time for the four states
//   (i) main data / today's engine   (ii) new data / today's engine
//   (iii) main data / UNKNOWN restricts   (iv) new data / UNKNOWN restricts (what ships)
// plus red->green / green->red between states and the UNKNOWN-only census of each tile set.
function greenTable(mainDir, newDir) {
  const M = [...load(mainDir).values()], N = [...load(newDir).values()];
  const states = [['(i) main data, current engine', M, false], ['(ii) new data, current engine', N, false],
    ['(iii) main data, UNKNOWN=restriction', M, true], ['(iv) new data, UNKNOWN=restriction', N, true]];
  const out = { states: {}, census: {} };
  for (const [name, segs, unk] of states) {
    setUnknownRestricts(unk);
    out.states[name] = { segments: segs.length };
    for (const [goal, fn] of Object.entries(GOALS)) for (const [tn, t] of Object.entries(TIMES)) {
      let g = 0; for (const s of segs) if (fn(s, t)) g++;
      out.states[name][`${goal} @ ${tn}`] = g;
    }
  }
  const census = (segs) => {
    let anyU = 0, onlyU = 0, mixed = 0;
    for (const s of segs) { const u = (s.rules || []).filter(r => r.category === 'UNKNOWN').length; if (!u) continue; anyU++; if (u === s.rules.length) onlyU++; else mixed++; }
    return { segmentsWithUnknown: anyU, unknownOnly: onlyU, mixed };
  };
  out.census.main = census(M); out.census.new = census(N);
  // red->green of new data vs main under the SAME engine (matched by id; ids of untouched segments are stable)
  const mainById = new Map(M.map(s => [s.id, s]));
  for (const unk of [false, true]) {
    setUnknownRestricts(unk);
    let r2g = 0, g2r = 0; const ex = [];
    for (const s of N) { const b = mainById.get(s.id); if (!b) continue;
      for (const fn of Object.values(GOALS)) for (const t of Object.values(TIMES)) {
        const bv = fn(b, t), av = fn(s, t);
        if (!bv && av) { r2g++; if (ex.length < 10) ex.push(s.id); } else if (bv && !av) g2r++;
      } }
    out.census[unk ? 'vsMainUnknownRestricts' : 'vsMainCurrentEngine'] = { redToGreenCells: r2g, greenToRedCells: g2r, r2gExamples: ex };
  }
  setUnknownRestricts(false);
  return out;
}

function main() {
  if (process.argv[2] === '--green-table') { console.log(JSON.stringify(greenTable(process.argv[3], process.argv[4]), null, 1)); return; }
  const [bDir, aDir] = process.argv.slice(2);
  const jsonOut = process.argv.includes('--json') ? process.argv[process.argv.indexOf('--json') + 1] : null;
  const B = load(bDir), A = load(aDir);
  const out = { segmentsBefore: B.size, segmentsAfter: A.size, sameIds: B.size === A.size && [...B.keys()].every(k => A.has(k)) };

  // Part 1: rule-level days changes
  const fam = new Map(); let ruleChanges = 0, rulesTotal = 0, segsChanged = new Set(), otherDrift = 0;
  const distinctChanged = new Map();
  // Rules are bucketed by (category, description) per segment: a multi-clause sign now emits one
  // rule per clause, so positional comparison no longer works. A bucket "changed" when its
  // (days, timeRanges, anytime) multiset differs. Counted per bucket = per sign-rule.
  const bucket = rules => {
    const m = new Map();
    for (const r of rules) { const k = r.category + '\u0000' + r.description; if (!m.has(k)) m.set(k, []); m.get(k).push(r); }
    return m;
  };
  const sig = rs => JSON.stringify(rs.map(r => [[...r.days].sort((x, y) => x - y), r.timeRanges, r.anytime]));
  for (const [id, b] of B) {
    const a = A.get(id); if (!a) continue;
    const ba = bucket(a.rules), bb = bucket(b.rules);
    if (ba.size !== bb.size) { otherDrift++; continue; }
    for (const [k, brs] of bb) {
      rulesTotal++;
      const ars = ba.get(k);
      if (!ars) { otherDrift++; continue; }
      if (sig(ars) === sig(brs)) continue;
      const ar = ars[0], br = brs[0];
      const dayChanged = true;
      ruleChanges++; segsChanged.add(id);
      const f = family(ar.description);
      if (!fam.has(f)) fam.set(f, { n: 0, ex: [] });
      const e = fam.get(f); e.n++;
      if (e.ex.length < 12) e.ex.push({ id, cat: ar.category, desc: ar.description, before: brs, after: ars });
      const key = `${ar.category} | ${ar.description.replace(/\(SUPERSEDES[^)]*\)|\(SUPERSEDED[^)]*\)/g, '').replace(/\s+/g, ' ').trim()}`;
      const j = rs => rs.map(r => r.days.join('') + '/' + (r.anytime ? 'anytime' : r.timeRanges.map(t => t.start + '-' + t.end).join(','))).join(' ; ');
      const dd = distinctChanged.get(key) || { n: 0, b: j(brs), a: j(ars) };
      dd.n++; distinctChanged.set(key, dd);
    }
  }
  out.rulesTotal = rulesTotal; out.ruleChanges = ruleChanges; out.segmentsWithChangedRules = segsChanged.size; out.otherDrift = otherDrift;
  out.families = [...fam].map(([f, v]) => ({ family: f, n: v.n, examples: v.ex })).sort((x, y) => y.n - x.n);
  out.distinctChanged = [...distinctChanged].map(([k, v]) => ({ k, ...v })).sort((x, y) => y.n - x.n);

  // Part 2: verdicts
  const verdicts = {}; const r2g = [];
  for (const [goal, fn] of Object.entries(GOALS)) for (const [tname, t] of Object.entries(TIMES)) {
    let g2r = 0, r2gN = 0, same = 0;
    for (const id of segsChanged) {
      const b = fn(B.get(id), t), a = fn(A.get(id), t);
      if (b && !a) g2r++;
      else if (!b && a) { r2gN++; r2g.push({ goal, time: tname, id }); }
      else same++;
    }
    verdicts[`${goal} @ ${tname}`] = { g2r, r2g: r2gN };
  }
  out.verdicts = verdicts; out.redToGreen = r2g;
  // sanity: segments whose rules did not change must not move
  let unchangedMoves = 0;
  for (const [id, b] of B) { if (segsChanged.has(id)) continue; const a = A.get(id); if (a && JSON.stringify(a.rules) !== JSON.stringify(b.rules)) unchangedMoves++; }
  out.unchangedSegmentRuleDrift = unchangedMoves;
  if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(out, null, 1));
  console.log(JSON.stringify({ ...out, families: out.families.map(f => ({ family: f.family, n: f.n })), distinctChanged: undefined, redToGreen: out.redToGreen.length }, null, 1));
}
if (require.main === module) main();
module.exports = { isFree, GOALS, TIMES, family, setUnknownRestricts, greenTable, load };
