#!/usr/bin/env node
/**
 * scripts/test-day-parsing.js
 *
 * Gate for build/preprocess.js parseSchedule day parsing (parseDayPhrases / splitDayClauses).
 * Regression class: "ALL DAYS" next to another day word came out as days:[0] (Sunday only),
 * abbreviated day names / day ranges / multi-clause signs lost days. Product rule: never
 * show a spot that isn't a spot -> an unparsed or ambiguous day phrase applies EVERY day.
 *
 * Offline: pure functions, no network, no tiles.   node scripts/test-day-parsing.js
 */
const pre = require('../build/preprocess.js');

let fail = 0;
function check(name, ok, info) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${info ? ' -- ' + info : ''}`); if (!ok) fail++; }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const ALL = [0, 1, 2, 3, 4, 5, 6];

// [name, description, category, expected days]
const DAYS = [
  ['ALL DAYS', 'NO STANDING 7AM-7PM ALL DAYS <->', 'NO_STANDING', ALL],
  ['ANYTIME', 'NO STANDING ANYTIME', 'NO_STANDING', ALL],
  ['DAILY', 'NO PARKING 8AM-6PM DAILY', 'NO_PARKING', ALL],
  ['EVERY DAY', 'NO PARKING 8AM-6PM EVERY DAY', 'NO_PARKING', ALL],
  ['7 DAYS A WEEK', 'NO PARKING 8AM-6PM 7 DAYS A WEEK', 'NO_PARKING', ALL],
  // THE DEFECT: ALL DAYS + an explicit SUNDAY clause used to be [0]
  ['ALL DAYS + SUNDAY clause (3rd Ave truck loading)', 'TRUCK (SYMBOL) TRUCK LOADING ONLY 7PM-7AM ALL DAYS SUNDAY 7AM-7PM <->', 'TRUCK_LOADING', ALL],
  ['ALL DAYS + SUNDAY clause, midnight form', 'TRUCK (SYMBOL) TRUCK LOADING ONLY MIDNIGHT-7AM ALL DAYS SUNDAY 7PM-MIDNIGHT -->', 'TRUCK_LOADING', ALL],
  ['SAT & SUN list + ALL DAYS (was [0,6])', 'TRUCK (SYMBOL) TRUCK LOADING ONLY SATURDAY & SUNDAY 7AM-7PM 7PM-7AM ALL DAYS <->', 'TRUCK_LOADING', ALL],
  ['ALL DAYS EXCEPT SUNDAY', 'NO PARKING 7AM-7PM ALL DAYS EXCEPT SUNDAY', 'NO_PARKING', [1, 2, 3, 4, 5, 6]],
  ['MONDAY-FRIDAY', 'NO STANDING MONDAY-FRIDAY 8AM-6PM', 'NO_STANDING', [1, 2, 3, 4, 5]],
  ['MON THRU FRI', 'NO STANDING 8AM-6PM MON THRU FRI', 'NO_STANDING', [1, 2, 3, 4, 5]],
  ['MON-SAT', 'NO PARKING MON-SAT 8AM-6PM', 'NO_PARKING', [1, 2, 3, 4, 5, 6]],
  ['EXCEPT SUNDAY', 'NO PARKING 7AM-7PM EXCEPT SUNDAY', 'NO_PARKING', [1, 2, 3, 4, 5, 6]],
  ['EXCEPT SATURDAY only (was Mon-Sat)', 'NO PARKING 7AM-7PM EXCEPT SATURDAY', 'NO_PARKING', [0, 1, 2, 3, 4, 5]],
  ['EXCEPT SAT & SUN list', 'NO PARKING 7AM-7PM EXCEPT SAT & SUN', 'NO_PARKING', [1, 2, 3, 4, 5]],
  ['SAT & SUN abbreviated (was Mon-Sat)', 'NO STANDING SAT & SUN 1AM-6AM', 'NO_STANDING', [0, 6]],
  ['FRI-SUN wraps through Saturday (was Mon-Sat)', 'NO STANDING FRI-SUN MIDNIGHT-6AM', 'NO_STANDING', [0, 5, 6]],
  ['WEDNESDAY-SUNDAY range (was [0,3])', 'NO STANDING MAY-OCTOBER WEDNESDAY-SUNDAY 6PM-8:30PM', 'NO_STANDING', [0, 3, 4, 5, 6]],
  ['FRIDAY-MONDAY wraparound', 'NO STANDING FRIDAY-MONDAY 8AM-6PM', 'NO_STANDING', [0, 1, 5, 6]],
  ['abbreviated list MON WED FRI', 'NO STANDING MON WED FRI 8AM-6PM', 'NO_STANDING', [1, 3, 5]],
  ['WEEKDAYS', 'NO STANDING WEEKDAYS 8AM-6PM', 'NO_STANDING', [1, 2, 3, 4, 5]],
  ['WEEKENDS', 'NO STANDING WEEKENDS 8AM-6PM', 'NO_STANDING', [0, 6]],
  ['restriction, no day at all -> every day', 'NO STANDING EXCEPT AUTHORIZED VEHICLES', 'NO_STANDING', ALL],
  ['bus stop, no day -> every day', 'NO STANDING BUS STOP', 'NO_STANDING', ALL],
  ['MON-FRI + SAT clause union', 'MONDAY-FRIDAY 7PM-MIDNIGHT SATURDAY 9AM-MIDNIGHT', 'METERED', [1, 2, 3, 4, 5, 6]],
  ['ASP single weekday abbreviation + TO time', 'NO PARKING (SANITATION BROOM SYMBOL) 11AM TO 12:30PM WED <--->', 'ASP_DAILY', [3]],
  // Truncated day words (>= 3-letter prefixes). "MONDAY THURSDA" used to drop Thursday.
  ['truncated THURSDA keeps Thursday', 'NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDA 8AM-9AM', 'ASP_MON_THU', [1, 4]],
  ['truncated THURSDA alone', 'NO PARKING (SANITATION BROOM SYMBOL) 8AM-9AM THURSDA', 'ASP_DAILY', [4]],
  ['truncated WEDNESD', 'NO PARKING 8AM-9AM WEDNESD', 'NO_PARKING', [3]],
  ['truncated SATURD in a range', 'NO PARKING MON-SATURD 8AM-9AM', 'NO_PARKING', [1, 2, 3, 4, 5, 6]],
  ['THUR / THURS / TUES / WEDS prefixes', 'NO PARKING 8AM-9AM THUR TUES WEDS', 'NO_PARKING', [2, 3, 4]],
  ['3-letter minimum: MON TUE WED THU FRI SAT SUN', 'NO PARKING 8AM-9AM MON TUE WED THU FRI SAT SUN', 'NO_PARKING', ALL],
  ['SUNDA truncated', 'NO PARKING 8AM-9AM SUNDA', 'NO_PARKING', [0]],
  // Misspelling that is not a prefix -> every day (fail safe), never a partial day set.
  ['misspelled THRUSDAY -> every day', 'NO PARKING (SANITATION BROOM SYMBOL) MONDAY THRUSDAY 8AM-9AM', 'ASP_MON_THU', ALL],
  ['misspelled TUESDY -> every day', 'NO PARKING 8AM-9AM TUESDY FRIDAY', 'NO_PARKING', ALL],
  // Benign look-alike must not trigger the fail-safe.
  ['MONEY is not a day', 'NO PARKING 8AM-9AM MONDAY MONEY', 'NO_PARKING', [1]],
];
for (const [name, desc, cat, want] of DAYS) {
  const got = pre.parseSchedule(desc, cat).days;
  check(`days: ${name}`, same(got, want), same(got, want) ? '' : `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
}

// A rule must NEVER come out as Sunday-only / empty when the sign text says ALL DAYS.
for (const desc of [
  'TRUCK (SYMBOL) TRUCK LOADING ONLY MIDNIGHT-7AM ALL DAYS SUNDAY 7PM-MIDNIGHT <->',
  'TRUCK (SYMBOL) TRUCK LOADING ONLY 10PM-6AM ALL DAYS SUNDAY 6AM-10PM <->',
  'NO STANDING 7AM-7PM ALL DAYS SUNDAY ALL DAY',
]) {
  const s = pre.parseSchedule(desc, 'TRUCK_LOADING');
  check('ALL DAYS never Sunday-only: ' + desc.slice(0, 60), same(s.days, ALL) && !s.clauses, JSON.stringify(s.days));
}

// Multi-clause signs split into per-clause rules (no clause's window on another clause's days).
const mc = pre.parseSchedule('2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 9AM-10PM <->', 'METERED');
check('clauses: MON-FRI + SAT split', mc.clauses && mc.clauses.length === 2 &&
  same(mc.clauses[0], { days: [1, 2, 3, 4, 5], timeRanges: [{ start: 1140, end: 1320 }], anytime: false }) &&
  same(mc.clauses[1], { days: [6], timeRanges: [{ start: 540, end: 1320 }], anytime: false }), JSON.stringify(mc.clauses));
const tx = pre.parseSchedule('TAXI (SYMBOL) TAXI RELIEF STAND 1 HOUR LIMIT MONDAY-FRIDAY 6PM-2AM SATURDAY & SUNDAY ALL DAY -->', 'SPECIAL');
check('clauses: taxi weekday window + SAT&SUN ALL DAY keeps the weekend', tx.clauses && tx.clauses.length === 2 &&
  same(tx.clauses[0].days, [1, 2, 3, 4, 5]) && same(tx.clauses[1].days, [0, 6]) && same(tx.clauses[1].timeRanges, []), JSON.stringify(tx.clauses));
check('clauses: single-clause sign has none', !pre.parseSchedule('NO STANDING MONDAY-FRIDAY 8AM-6PM', 'NO_STANDING').clauses);

// Fail-safe: day words present but unparseable -> all days, counted.
const before = pre.DAY_PARSE_STATS.unparsedFallbackAllDays;
const odd = pre.parseSchedule('2 HMP 8AM-6PM HOLIDAYS', 'METERED');
check('fail-safe: unparsed day word -> all days', same(odd.days, ALL), JSON.stringify(odd.days));
check('fail-safe: fallback counted', pre.DAY_PARSE_STATS.unparsedFallbackAllDays === before + 1);

// Category must agree with the day parse for truncated broom signs (engine ANDs category days with rule days).
check('classify: MONDAY THURSDA broom sign is ASP_MON_THU',
  pre.classifySign('NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDA 8AM-9AM <->') === 'ASP_MON_THU');
check('classify: TUES & FRI broom sign is ASP_TUE_FRI',
  pre.classifySign('NO PARKING (SANITATION BROOM SYMBOL) TUES & FRI 8AM-9AM <->') === 'ASP_TUE_FRI');

// Arrow glyphs: any double-headed shaft length is "both" (was: only the exact "<->").
for (const [g, want] of [['<->', 'both'], ['<-->', 'both'], ['<--->', 'both'], ['<----->', 'both'], ['<------->', 'both'],
  ['-->', 'towards'], ['<--', 'away'], ['<-------', 'away']]) {
  const got = pre.parseSchedule(`TRUCK LOADING ONLY MONDAY-FRIDAY 8AM-1PM ${g}`, 'TRUCK_LOADING').arrow;
  check(`arrow glyph ${g} -> ${want}`, got === want, `got ${got}`);
}

// Time fail-safe: a stray unparsed time next to a parsed range drops the ranges (all-day), never a partial list.
const tp = pre.parseSchedule('NO PARKING 7AM-10A M 4PM-7PM MONDAY-FRIDAY', 'NO_PARKING');
check('time fail-safe: unparsed window next to a parsed one -> all-day', same(tp.timeRanges, []), JSON.stringify(tp.timeRanges));
const tg = pre.parseSchedule('NO PARKING 8AM-9AM MONDAY-FRIDAY', 'NO_PARKING');
check('time fail-safe: clean sign keeps its range', same(tg.timeRanges, [{ start: 480, end: 540 }]));
const mh = pre.parseSchedule('(PARKNYC LOGO) PARKNYC APP PAYMENT ONLY ZONE # 123456 (FOR METERLESS CURB PILOT)', 'METERED');
check('metered with no readable hours -> all-day window', same(mh.timeRanges, [{ start: 0, end: 0 }]), JSON.stringify(mh.timeRanges));
const mt = pre.parseSchedule('2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 9AM-10PM <->', 'METERED');
check('metered with hours keeps them', same(mt.clauses[0].timeRanges, [{ start: 1140, end: 1320 }]));

process.exit(fail ? 1 : 0);
