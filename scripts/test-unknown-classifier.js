#!/usr/bin/env node
/**
 * scripts/test-unknown-classifier.js
 *
 * Gate for the UNKNOWN-sign audit (docs/qa/tiles-unknown-audit.md). The iOS engine reads UNKNOWN as
 * free (and will soon read it as a restriction), so the classifier must
 *   (a) turn real restrictions it used to miss (time limits) into SPECIAL with the right days/times,
 *   (b) turn purely informational signs into INFO (never a rule), and
 *   (c) leave anything that could restrict a private car UNKNOWN.
 * Offline: pure functions.   node scripts/test-unknown-classifier.js
 */
const pre = require('../build/preprocess.js');
const eng = require('./diff-tiles-days.js');
let fail = 0;
function check(name, ok, info) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${info ? ' -- ' + info : ''}`); if (!ok) fail++; }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const cls = d => pre.classifySign(d);

// ---- (a) time limits -> SPECIAL, windowed -------------------------------------------------------
const A = [
  ['2 HOUR PARKING 9AM-7PM EXCEPT SUNDAY (SUPERSEDES R7-182R)', [1, 2, 3, 4, 5, 6], [{ start: 540, end: 1140 }], false],
  ['1 HOUR PARKING 9AM-7PM EXCEPT SUNDAY (SUPERSEDES R7-162R)', [1, 2, 3, 4, 5, 6], [{ start: 540, end: 1140 }], false],
  ['1 HOUR PARKING 8:30AM-7PM EXCEPT SUNDAY (SUPERSEDES SP-145E)', [1, 2, 3, 4, 5, 6], [{ start: 510, end: 1140 }], false],
  ['2 HOUR PARKING SATURDAY 9AM-7PM', [6], [{ start: 540, end: 1140 }], false],
  ['1 HOUR PARKING SATURDAY 9AM-10PM (SUPERSEDES SP-424EA)', [6], [{ start: 540, end: 1320 }], false],
];
for (const [d, days, tr, any] of A) {
  const c = cls(d); const s = pre.parseSchedule(d, c);
  check('(a) SPECIAL: ' + d, c === 'SPECIAL', c);
  check('(a) schedule: ' + d, same(s.days, days) && same(s.timeRanges, tr) && s.anytime === any, JSON.stringify([s.days, s.timeRanges, s.anytime]));
}
for (const d of ['30 MINUTE LIMIT', '15 MINUTE PARKING (THIS SMO REQUIRES D/C APPROVAL)']) {
  const c = cls(d); const s = pre.parseSchedule(d, c);
  check('(a) no window = always: ' + d, c === 'SPECIAL' && s.anytime === true, JSON.stringify([c, s.anytime]));
}

// ---- (b) informational -> INFO ----------------------------------------------------------------------
const B = [
  'METERS ARE NOT IN EFFECT ABOVE TIMES (TO BE USED ONLY FOR CONFLICTING STREET CLEANING AND METERED PARKING REGULATIONS) (SUPERSEDES SW-473)',
  'LIMITED PARKING IS NOT IN EFFECT ABOVE TIMES (TO BE USED ONLY FOR CONFLICTING STREET CLEANING AND FREE LIMITED TIME PARKING REGULATIONS)',
  'SELECT BUS SERVICE DESTINATION PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'SELECT BUS SERVICE ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'NIGHT SERVICE ONLY ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'NAVILENS BUS STOP DESTINATION PANEL',
  'REAL TIME PUBLIC INFORMATION BOX (FOR FULL TIME BUS STOPS)',
  'ACCESS A RIDE BUS STOP ROUTE PANEL',
  'Q4/ Q4 LTD (COMBINATION ROUTE PANEL)',
  'LOCAL 2 ROUTE BUS RIDER',
  'BACK IN ANGLE PARKING ONLY (SUPERSEDES SP-7D)',
  'BACK IN 90 DEG PARKING ONLY (SUPERSEDES SP-6D)',
  'HEAD IN ANGLE PARKING ONLY (REQUIRES TC&E A/C APPROVAL)',
  'PARALLEL PARKING ONLY (SUPERSEDES SP-174DA)',
  'NO ENGINE IDLING (SYMBOL) NO ENGINE IDLING MAX FINE $XXXX (XXXX = AMT TO BE DETERMINED)',
  'ATTENTION DRIVERS 1 MINUTE IDLING LAW ENFORCED MAX FINE $XXXX ("XXXX" = AMT TO BE SPECIFIED)',
  '3 MINUTE IDLING LAW YOU IDLE YOU PAY $2000 (REVISED 1-11-2005)',
  'DIAMOND DELINEATOR (BLANK) MAY BE USED AS SUBSTITUTE OR REPLACMENT FOR W14-2A & W14-2B (REVISED 4/24/2013)',
  '6TH AVE PAY-BY-APP INFORMATION SIGN',
  'WARNING THERE ARE NO TAXI DISPATCHERS AT THIS LOCATION DON\'T ALLOW ANYONE TO CARRY YOUR BAGS DON\'T GIVE MONEY',
  'WILLIS AV W/ 3 O\'CLOCK ARROW',
];
for (const d of B) check('(b) INFO: ' + d.slice(0, 60), cls(d) === 'INFO', cls(d));

// ---- (c) must NOT become INFO or SPECIAL: could restrict a private car --------------------------------
const C = [
  'OPEN STREETS (INFORMATION SIGN)',
  'CARSHARE SIGN (INFORMATION) - (BLUE LETTERING) (SUPERSEDES SI-2011G)',
  'MICROHUB SIGN (STREET FACING)',
  'DESCRIPTION NOT AVAILABLE',
  'BUS STOP SIGN (BUS & HANDICAP SYMBOLS) (GENERIC PANEL)',
  'DAY - DAY XYY-XYY (FOR BUS STOP ONLY)',
  'EXCEPT BUSES',
  'NO BUS LAYOVER',
  'NO BUSES',
  '7AM-6PM EXCEPT SUNDAY',
  'OTHER TIMES (RIDER FOR PARKING RESTRICTED SIGNS - RED/WHITE)',
  'GROUP RIDING TO AIRPORTS(SUPERSEDES SP-54G & SP-55G)',
  'PEDESTRIAN PLAZA RULES SIGN (PLAZA NAME TO BE DETERMINED)',
  'TAXI (SYMBOL) PICK UPS & DROP OFFS ACROSS AVE 7AM-1PM MON THRU FRI',
  'MTA SCHOOL BUS SERVICE ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
];
for (const d of C) check('(c) stays UNKNOWN: ' + d.slice(0, 60), cls(d) === 'UNKNOWN', cls(d));

// ---- never-INFO guard: restriction words win even next to an info phrase -----------------------------
const G = [
  ['NO PARKING ANGLE PARKING ONLY', 'NO_PARKING'],
  ['NO STANDING 7AM-7PM ROUTE PANEL', 'NO_STANDING'],
  ['PERMITS ONLY ANGLE PARKING ONLY', 'SPECIAL'],
  ['COMMERCIAL VEHICLES ONLY 7AM-7PM', 'NO_PARKING'],
  ['2 HOUR METERED PARKING 9AM-7PM', 'METERED'],
];
for (const [d, want] of G) check('guard: ' + d, cls(d) === want, cls(d));
check('guard: tow notice with angle phrase is not INFO', cls('TOW-AWAY ZONE ANGLE PARKING ONLY') !== 'INFO', cls('TOW-AWAY ZONE ANGLE PARKING ONLY'));
check('guard: TOWARD does not trip the tow blocker', cls('ANGLE PARKING ONLY TOWARD AVENUE') === 'INFO', cls('ANGLE PARKING ONLY TOWARD AVENUE'));
check('guard: pure time-limit with tow word stays restrictive, not INFO', cls('2 HOUR PARKING 9AM-7PM TOW-AWAY') !== 'INFO');

// ---- engine switch (scripts/diff-tiles-days.js port): UNKNOWN = restriction -----------------------------
const seg = rules => ({ rules });
const unk = (days, tr) => ({ category: 'UNKNOWN', description: 'X', days, timeRanges: tr, anytime: false });
const TUE10 = eng.TIMES['Tue 10 AM'], SUN10 = eng.TIMES['Sun 10 AM'];
eng.setUnknownRestricts(false);
check('engine off: UNKNOWN is free', eng.isFree(seg([unk([], [])]), TUE10, TUE10 + 60) === true);
eng.setUnknownRestricts(true);
check('engine on: UNKNOWN with no days/times restricts always', eng.isFree(seg([unk([], [])]), TUE10, TUE10 + 60) === false);
check('engine on: UNKNOWN restricts only in its window', eng.isFree(seg([unk([2], [{ start: 540, end: 660 }])]), TUE10, TUE10 + 60) === false
  && eng.isFree(seg([unk([2], [{ start: 540, end: 660 }])]), SUN10, SUN10 + 60) === true);
eng.setUnknownRestricts(false);

// ---- emitted tiles: info-only curbs are no-data, never free, never rule-less ---------------------------
const fs = require('fs'), path = require('path');
const tdir = path.join(__dirname, '..', 'tiles');
if (fs.existsSync(tdir)) {
  let noInfo = 0, bad = 0, infoRule = 0;
  for (const f of fs.readdirSync(tdir)) {
    if (!f.startsWith('tile_')) continue;
    for (const sg of JSON.parse(fs.readFileSync(path.join(tdir, f), 'utf8'))) {
      if (sg.rules.some(r => r.category === 'INFO')) infoRule++;
      if (sg.rules.some(r => r.description.startsWith('NO DATA - ONLY INFORMATION PLATES'))) {
        noInfo++;
        if (!(sg.rules[0].anytime && sg.rules[0].category === 'NO_PARKING' && sg.dominantCategory === 'UNKNOWN' && Array.isArray(sg.info) && sg.info.length)) bad++;
      }
    }
  }
  check('tiles: no INFO category leaks into rules', infoRule === 0);
  check('tiles: info-only curbs are always-on no-data with plate text in info', noInfo > 0 && bad === 0, `${noInfo} segments, ${bad} bad`);
}

console.log(fail ? `\n${fail} FAILED` : '\nall passed');
process.exit(fail ? 1 : 0);
