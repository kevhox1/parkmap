#!/usr/bin/env node
/**
 * scripts/diff-tiles-residual.js
 *
 * Attribution + verdict diff for the "residual fake spots" tile fixes. All builds must come from
 * the SAME cached sign pull (SIGNS_CACHE_PATH) so every difference is the code change alone.
 *
 *   node scripts/diff-tiles-residual.js <baseDir> <fullDir> \
 *        [--off glyph=<dir> --off companion=<dir> --off superseded=<dir> --off meteredhours=<dir>] \
 *        [--json out.json]
 *
 * <fullDir> is built with every fix; each `--off X=<dir>` is built with RESIDUAL_FIXES_OFF=X (see
 * build/preprocess.js). A segment is attributed to fix X when its rules differ between <fullDir> and
 * the X-off build. Segments changed vs <baseDir> but attributed to no switchable fix are the parser
 * fixes (truncated day words, ...).
 *
 * Verdicts use the Node port of ParkingRulesEngine.isFree + ParkingGoals from diff-tiles-days.js
 * (an audit tool, not a product engine). Reports the 4 PR #190 probe times, plus a full-week scan
 * (3 goals x 168 hours) so a red->green cannot hide between probe times.
 */
const fs = require('fs');
const path = require('path');
const { GOALS, TIMES } = require('./diff-tiles-days.js');

// Segments are matched by GEOMETRY (street, from, to, side, first and last point), not by id: the id
// ends in the zone index, which shifts when a fix makes a previously rule-less zone appear.
const segKey = seg => `${seg.street}|${seg.from}|${seg.to}|${seg.side}|${seg.line[0]}|${seg.line[seg.line.length - 1]}`;
function load(dir) {
  const m = new Map();
  for (const f of fs.readdirSync(dir)) {
    if (!f.startsWith('tile_') || !f.endsWith('.json')) continue;
    for (const seg of JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'))) m.set(segKey(seg), seg);
  }
  return m;
}
const rulesKey = s => JSON.stringify(s.rules);

function summarize(seg) {
  return seg.rules.map(r => `${r.category} "${r.description.replace(/\s+/g, ' ').slice(0, 110)}" days=${r.days.join('')} ` +
    (r.anytime ? 'anytime' : r.timeRanges.length ? r.timeRanges.map(t => `${t.start}-${t.end}`).join(',') : 'all-day')).join('\n      ');
}

function verdictTable(ids, B, F) {
  const t = {};
  for (const [goal, fn] of Object.entries(GOALS)) for (const [tn, tm] of Object.entries(TIMES)) {
    let g2r = 0, r2g = 0;
    for (const id of ids) {
      const b = fn(B.get(id), tm), a = fn(F.get(id), tm);
      if (b && !a) g2r++; else if (!b && a) r2g++;
    }
    t[`${goal} @ ${tn}`] = { g2r, r2g };
  }
  return t;
}

// Segments that exist only in the new build (a zone that had no rule before and now does): there is no
// "before" verdict (nothing was drawn), so report how many are green at each probe instead.
function newSegmentGreen(keys, F) {
  const t = {};
  for (const [goal, fn] of Object.entries(GOALS)) for (const [tn, tm] of Object.entries(TIMES)) {
    t[`${goal} @ ${tn}`] = keys.filter(k => fn(F.get(k), tm)).length;
  }
  return t;
}

function weekScan(ids, B, F) {
  // Day 0 = Sunday 2026-12-06; every hour of the following week.
  const cells = [], segs = new Set();
  let g2rCells = 0;
  for (const [goal, fn] of Object.entries(GOALS)) for (let h = 0; h < 168; h++) {
    const tm = 1440 + h * 60;
    for (const id of ids) {
      const b = fn(B.get(id), tm), a = fn(F.get(id), tm);
      if (b && !a) g2rCells++;
      else if (!b && a) { cells.push({ goal, hour: h, id }); segs.add(id); }
    }
  }
  return { g2rCells, r2gCells: cells.length, r2gSegments: [...segs] };
}

function main() {
  const args = process.argv.slice(2);
  const [bDir, fDir] = args;
  const offs = {};
  let jsonOut = null;
  for (let i = 2; i < args.length; i++) {
    if (args[i] === '--off') { const [k, v] = args[++i].split('='); offs[k] = v; }
    else if (args[i] === '--json') jsonOut = args[++i];
  }
  const B = load(bDir), F = load(fDir);
  const changed = [...B.keys()].filter(k => F.has(k) && rulesKey(B.get(k)) !== rulesKey(F.get(k)));
  const added = [...F.keys()].filter(k => !B.has(k));
  const removed = [...B.keys()].filter(k => !F.has(k));
  const out = { segmentsBase: B.size, segmentsFull: F.size, changedSegments: changed.length, newSegments: added.length, removedSegments: removed.length };

  const attributed = {}, attributedNew = {};
  const covered = new Set();
  for (const [fix, dir] of Object.entries(offs)) {
    const X = load(dir);
    attributed[fix] = changed.filter(k => X.has(k) && rulesKey(F.get(k)) !== rulesKey(X.get(k)));
    attributedNew[fix] = added.filter(k => !X.has(k));
    attributed[fix].forEach(k => covered.add(k));
  }
  attributed.parser = changed.filter(k => !covered.has(k));
  out.byFix = {};
  for (const [fix, ids] of Object.entries(attributed)) {
    const nw = attributedNew[fix] || [];
    const w = weekScan(ids, B, F);
    out.byFix[fix] = {
      segments: ids.length,
      newSegments: nw.length,
      verdicts: verdictTable(ids, B, F),
      newSegmentsGreen: nw.length ? newSegmentGreen(nw, F) : undefined,
      week: { g2rCells: w.g2rCells, r2gCells: w.r2gCells, r2gSegments: w.r2gSegments.length },
      examples: ids.slice(0, 6).map(k => ({ id: F.get(k).id, before: summarize(B.get(k)), after: summarize(F.get(k)) })),
      newExamples: nw.slice(0, 6).map(k => ({ id: F.get(k).id, after: summarize(F.get(k)) })),
    };
  }
  out.verdicts = verdictTable(changed, B, F);
  out.newSegmentsGreen = newSegmentGreen(added, F);
  const w = weekScan(changed, B, F);
  out.week = { g2rCells: w.g2rCells, r2gCells: w.r2gCells, r2gSegments: w.r2gSegments.length };
  out.r2gDetail = w.r2gSegments.map(k => ({ id: F.get(k).id, before: summarize(B.get(k)), after: summarize(F.get(k)) }));
  const nwWeek = (() => { let green = 0; const segs = new Set(); for (const [, fn] of Object.entries(GOALS)) for (let h = 0; h < 168; h++) for (const k of added) if (fn(F.get(k), 1440 + h * 60)) { green++; segs.add(k); } return { greenCells: green, greenSegments: segs.size }; })();
  out.newSegmentsWeek = nwWeek;
  out.removedExamples = removed.slice(0, 5).map(k => ({ id: B.get(k).id, before: summarize(B.get(k)) }));
  if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(out, null, 1));
  const brief = JSON.parse(JSON.stringify(out));
  for (const v of Object.values(brief.byFix)) { delete v.examples; delete v.newExamples; }
  delete brief.r2gDetail;
  console.log(JSON.stringify(brief, null, 1));
}
if (require.main === module) main();
