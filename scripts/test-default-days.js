#!/usr/bin/env node
/**
 * scripts/test-default-days.js
 *
 * Gate for docs/qa/tiles-default-days.md: a sign that names no day must never silently get a Sunday
 * exemption. UNKNOWN -> all 7 days. METERED / ASP_* -> Mon-Sat (NYC: no meter payment, no ASP on Sunday).
 * "SCHOOL DAYS" (a stated phrase) keeps Mon-Sat. Everything else -> 7 days.
 * Offline: pure functions.   node scripts/test-default-days.js
 */
const pre = require('../build/preprocess.js');
let fail = 0;
function check(name, ok, info) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${info ? ' -- ' + info : ''}`); if (!ok) fail++; }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const ALL = [0, 1, 2, 3, 4, 5, 6], MON_SAT = [1, 2, 3, 4, 5, 6];
const days = (d, cat) => pre.parseSchedule(d, cat).days;

// UNKNOWN with no days: every day, whatever the text.
for (const d of [
  'SELECT BUS SERVICE ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'CARSHARE SIGN (INFORMATION) - (BLUE LETTERING) (SUPERSEDES SI-2011G)',
  'OPEN STREETS (INFORMATION SIGN)',
  'REAL TIME PUBLIC INFORMATION BOX (FOR FULL TIME BUS STOPS)',
]) check('UNKNOWN no days -> 7 days: ' + d, same(days(d, 'UNKNOWN'), ALL), JSON.stringify(days(d, 'UNKNOWN')));
// Even a SCHOOL DAYS phrase on an UNKNOWN sign: we do not know the sign, so all 7.
check('UNKNOWN + SCHOOL DAYS -> 7 days', same(days('SOME NEW PLATE SCHOOL DAYS', 'UNKNOWN'), ALL));
// UNKNOWN with stated days keeps them.
check('UNKNOWN with stated days keeps them', same(days('SOME PLATE MON-FRI', 'UNKNOWN'), [1, 2, 3, 4, 5]));

// METERED with no day: Mon-Sat (meters need no payment on Sunday).
for (const d of ['(PARKNYC LOGO) PARKNYC APP PAYMENT ONLY ZONE # 999999 (FOR METERLESS CURB PILOT)', 'HOUR METERED PARKING <-> (FOR BUS STOP ONLY)'])
  check('METERED no days -> Mon-Sat: ' + d, same(days(d, 'METERED'), MON_SAT));
// ASP with no day: Mon-Sat (ASP never runs Sunday).
check('ASP_DAILY no days -> Mon-Sat', same(days('NO PARKING (SANITATION BROOM SYMBOL) <->', 'ASP_DAILY'), MON_SAT));

// SCHOOL DAYS keeps Mon-Sat; its time window is untouched.
for (const [d, cat] of [['NO STANDING SCHOOL DAYS 7AM-4PM -->', 'NO_STANDING'], ['STAR (SYMBOL) AVO DEPT OF EDUCATION SCHOOL DAYS 7AM-4PM <->', 'SPECIAL']]) {
  const s = pre.parseSchedule(d, cat);
  check('SCHOOL DAYS -> Mon-Sat + window: ' + d, same(s.days, MON_SAT) && same(s.timeRanges, [{ start: 420, end: 960 }]));
}

// Hard restrictions with no day are all-days (existing behaviour, pinned).
check('NO_STANDING no day -> 7 days + anytime', (s => same(s.days, ALL) && s.anytime)(pre.parseSchedule('NO STANDING BUS STOP', 'NO_STANDING')));
// Any other category reaching the default is all 7 (no verified convention).
check('unlisted category with no days -> 7 days', same(days('SOMETHING', 'SOME_NEW_CATEGORY'), ALL));
// Stated days are never touched.
check('stated days untouched (EXCEPT SUNDAY)', same(days('2 HOUR PARKING 9AM-7PM EXCEPT SUNDAY', 'SPECIAL'), MON_SAT));
check('stated days untouched (SUNDAY only)', same(days('NO PARKING SUNDAY 9AM-7PM', 'NO_PARKING'), [0]));

if (fail) { console.log(`\n${fail} FAILED`); process.exit(1); }
console.log('\nall passed');
