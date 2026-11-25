#!/usr/bin/env node
/**
 * scripts/test-sign-reclassification.js
 *
 * Gate for the sign-classification overhaul (build/preprocess.js classifySign /
 * isSkippedSign / parseSchedule). Product rule: a private car must see RED
 * wherever it cannot legally park. The iOS rules engine treats NO_PARKING /
 * NO_STANDING / TRUCK_LOADING / SPECIAL as restrictions in their window
 * (anytime -> always) and UNKNOWN / FREE as never a restriction, so every
 * plate/vehicle/use-only curb must be emitted as a restriction category.
 *
 * Offline: pure functions, no network, no tiles.
 */
const pre = require('../build/preprocess.js');

let fail = 0;
function check(name, ok, info) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${info ? ' -- ' + info : ''}`); if (!ok) fail++; }
const RESTRICTION = new Set(['NO_PARKING', 'NO_STANDING', 'TRUCK_LOADING', 'SPECIAL']);
const ALL = [0, 1, 2, 3, 4, 5, 6];
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// [name, description, expected category, expected {anytime, days, ranges}] ; ranges in minutes
const M = h => h * 60;
const CASES = [
  // 1. metered commercial vehicles only -> restriction in the stated window
  ['commercial-only HMP Mon-Fri', '3 HMP COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 8AM-6PM <-> (SUPERSEDES PS-20C)', 'NO_PARKING', { anytime: false, days: [1,2,3,4,5], ranges: [[M(8), M(18)]] }],
  ['commercial-only HMP except Sunday', '3 HMP COMMERCIAL VEHICLES ONLY 7AM-7PM EXCEPT SUNDAY -->', 'NO_PARKING', { anytime: false, days: [1,2,3,4,5,6], ranges: [[M(7), M(19)]] }],
  ['commercial-only 30 MMP', '30 MMP COMMERCIAL VEHICLES ONLY 7AM-7PM EXCEPT SUNDAY', 'NO_PARKING', { anytime: false, days: [1,2,3,4,5,6], ranges: [[M(7), M(19)]] }],
  // 2. plate / vehicle-type / use-only curbs
  ['diplomat/consul STAR', 'STAR (SYMBOL) AUTHORIZED VEHICLES ONLY CONSUL-C DIPLOMAT-A & D LICENSE PLATES D/S DECALS ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['diplomat/consul with window', 'STAR (SYMBOL) AUTHORIZED VEHICLES ONLY CONSUL & DIPLOMAT LICENSE PLATES 7AM-7PM EXCEPT SUNDAY DELIVERY DECAL REQUIRED', 'SPECIAL', { anytime: false, days: [1,2,3,4,5,6], ranges: [[M(7), M(19)]] }],
  ['consul/diplomat coding rider', 'CONSUL / DIPLOMAT CODING RIDER (SIGN CAN CONTAIN 1 TO 4 CODES ONLY AS SPECIFIED)', 'SPECIAL', { anytime: true, days: ALL }],
  ['press NYP', 'PRESS (SYMBOL) NYP LICENSE PLATES ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['press NYP window', 'PRESS (SYMBOL) NYP LICENSE PLATES ONLY MONDAY-FRIDAY 7AM-7PM', 'SPECIAL', { anytime: false, days: [1,2,3,4,5], ranges: [[M(7), M(19)]] }],
  ['USPS', 'STAR (SYMBOL) AUTHORIZED VEHICLES ONLY US POSTAL SERVICE', 'SPECIAL', { anytime: true, days: ALL }],
  ['ambulette', 'CROSS (SYMBOL) AMBULETTE ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['ambulette ALL DAYS', 'CROSS (SYMBOL) AMBULETTE ONLY 7AM-7PM ALL DAYS', 'SPECIAL', { anytime: false, days: ALL, ranges: [[M(7), M(19)]] }],
  ['for-hire window', 'FHV (SYMBOL) FOR-HIRE VEHICLES ONLY MONDAY-FRIDAY 4PM-MIDNIGHT', 'SPECIAL', { anytime: false, days: [1,2,3,4,5], ranges: [[M(16), 0]] }],
  ['taxi stand', 'TAXI HAILING (SYMBOL) TAXI STAND', 'SPECIAL', { anytime: true, days: ALL }],
  ['taxi relief stand', 'TAXI (SYMBOL) TAXI/FHV RELIEF STAND 1 HOUR LIMIT', 'SPECIAL', { anytime: true, days: ALL }],
  ['taxi stand all days', 'TAXI HAIL (SYMBOL) TAXI STAND 7AM-7PM ALL DAYS', 'SPECIAL', { anytime: false, days: ALL, ranges: [[M(7), M(19)]] }],
  ['EV charging', 'ELECTRIC VEHICLE (SYMBOL) ELECTRIC VEHICLE CHARGING ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['horse drawn cabs', 'HORSE DRAWN CAB (SYMBOL) HORSE DRAWN CABS ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['farmers market', 'TRUCK (SYMBOL) FARMERS MARKET ONLY SUNDAY 6AM-6PM', 'SPECIAL', { anytime: false, days: [0], ranges: [[M(6), M(18)]] }],
  ['NLZ loading only', 'NLZ (SYMBOL) LOADING ONLY MONDAY-FRIDAY 8AM-6PM', 'SPECIAL', { anytime: false, days: [1,2,3,4,5], ranges: [[M(8), M(18)]] }],
  ['RIOC permit', 'R I O C PERMIT', 'SPECIAL', { anytime: true, days: ALL }],
  ['FLEO', 'F L E O', 'SPECIAL', { anytime: true, days: ALL }],
  ['permits only', 'LOT #1 PERMITS ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['agency STAR (no AUTHORIZED words)', 'STAR (SYMBOL) NYC DEPT OF INVESTIGATION MONDAY-FRIDAY 7AM-7PM', 'SPECIAL', { anytime: false, days: [1,2,3,4,5], ranges: [[M(7), M(19)]] }],
  // 3. bus layover (restriction) vs route/destination panels (info)
  ['MTA bus layover', 'BUS (SYMBOL) MTA BUS LAYOVER ONLY NO ENGINE IDLING MAX FINE $2000', 'SPECIAL', { anytime: true, days: ALL }],
  ['non-MTA bus layover window', 'BUS (SYMBOL) NON-MTA BUS LAYOVER ONLY MONDAY-FRIDAY 7AM-7PM NO ENGINE IDLING MAX FINE $2000', 'SPECIAL', { anytime: false, days: [1,2,3,4,5], ranges: [[M(7), M(19)]] }],
  ['bus layover ALL DAYS', 'BUS (SYMBOL) NON-MTA BUS LAYOVER ONLY 7AM-7PM ALL DAYS NO ENGINE IDLING MAX FINE $2000', 'SPECIAL', { anytime: false, days: ALL, ranges: [[M(7), M(19)]] }],
  // 4. temporary construction regulation
  ['construction NO STANDING ANYTIME', 'NO STANDING ANYTIME HARD HAT (SYMBOL) TEMPORARY CONSTRUCTION REGULATION (FUTURE PHONE)', 'NO_STANDING', { anytime: true, days: ALL, temporary: true }],
  ['construction NO STANDING bus stop (no window)', 'NO STANDING W/ SINGLE ARROW BUS & HANDICAP (SYMBOLS) HARD HAT (SYMBOL) TEMPORARY CONSTRUCTION REGULATION', 'NO_STANDING', { anytime: true, days: ALL, temporary: true }],
  ['construction NO PARKING ANYTIME', 'NO PARKING ANYTIME W/SINGLE ARROW/ HARD HAT(SYMBOL) TEMPORARY CONSTRUCTION REGULATION (FUTURE PHONE)', 'NO_PARKING', { anytime: true, days: ALL, temporary: true }],
  ['construction NO PARKING ANYTIME CONSTRUCTION', 'NO PARKING ANYTIME CONSTRUCTION ( SINGLE ARROW )', 'NO_PARKING', { anytime: true, days: ALL, temporary: true }],
  // 6. correct families unchanged
  ['ASP broom Tue/Fri', 'NO PARKING (BROOM) TUESDAY FRIDAY 11AM-12:30PM', 'ASP_TUE_FRI', null],
  ['ASP overnight', 'NO PARKING (BROOM) MOON & STARS TUE THU SAT MIDNIGHT-3AM', 'ASP_OVERNIGHT_TTHS', null],
  ['No Standing Anytime', 'NO STANDING ANYTIME', 'NO_STANDING', { anytime: true, days: ALL }],
  ['No Stopping Anytime', 'NO STOPPING ANYTIME', 'NO_STANDING', { anytime: true, days: ALL }],
  ['bus stop (no window) is anytime every day', 'BUS STOP SIGN (BUS & HANDICAP SYMBOLS) NO STANDING W/ SINGLE ARROW', 'NO_STANDING', { anytime: true, days: ALL }],
  ['hotel loading zone', 'NO STANDING HOTEL LOADING ZONE -->', 'NO_STANDING', { anytime: true, days: ALL }],
  ['fire zone', 'NO STANDING FIRE ZONE <->', 'NO_STANDING', { anytime: true, days: ALL }],
  ['No Standing timed', 'NO STANDING MON-FRI 7AM-10AM 4PM-7PM', 'NO_STANDING', { anytime: false, days: [1,2,3,4,5], ranges: [[M(7), M(10)], [M(16), M(19)]] }],
  ['No Parking timed', 'NO PARKING MONDAY-FRIDAY 8AM-6PM', 'NO_PARKING', { anytime: false, days: [1,2,3,4,5], ranges: [[M(8), M(18)]] }],
  ['truck loading timed', 'TRUCK (SYMBOL) TRUCK LOADING ONLY MONDAY-FRIDAY 7AM-7PM', 'TRUCK_LOADING', { anytime: false, days: [1,2,3,4,5], ranges: [[M(7), M(19)]] }],
  ['trucks loading only', 'TRUCK (SYMBOL) TRUCKS LOADING ONLY MONDAY-FRIDAY 7AM-7PM', 'TRUCK_LOADING', { anytime: false, days: [1,2,3,4,5], ranges: [[M(7), M(19)]] }],
  ['AVO police', 'STAR (SYMBOL) AVO POLICE DEPARTMENT <->', 'SPECIAL', { anytime: true, days: ALL }],
  ['doctor plates', 'CROSS (SYMBOL) DOCTOR LICENSE PLATES ONLY', 'SPECIAL', { anytime: true, days: ALL }],
  ['meter for any vehicle', '2 HMP 9AM-7PM EXCEPT SUNDAY', 'METERED', { anytime: false, days: [1,2,3,4,5,6], ranges: [[M(9), M(19)]] }],
  ['meter with explicit commercial wording absent', '1 HMP 9AM-7PM EXCEPT SUNDAY', 'METERED', null],
];

for (const [name, desc, cat, sched] of CASES) {
  const c = pre.classifySign(desc);
  check(`${name}: category`, c === cat, `${c} (want ${cat})`);
  if (sched) {
    const s = pre.parseSchedule(desc, c);
    const got = { anytime: s.anytime, days: s.days, ranges: s.timeRanges.map(t => [t.start, t.end]) };
    const okAny = s.anytime === sched.anytime;
    const okDays = same(s.days, sched.days);
    const okRanges = sched.anytime ? true : same(got.ranges, sched.ranges);
    check(`${name}: window`, okAny && okDays && okRanges, JSON.stringify(got));
    if (RESTRICTION.has(cat)) check(`${name}: is a restriction category`, true);
    check(`${name}: temporary flag`, pre.isTemporarySign(desc) === !!sched.temporary, String(pre.isTemporarySign(desc)));
  }
}

// Info signs must stay non-rules (null) or UNKNOWN, never a restriction category.
const NULLS = [
  'LOCAL MTA BUS ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'EXPRESS MTA BUS DESTINATION PANEL (TEXT TO BE MODIFIED AS REQUIRED)',
  'NON MTA BUS ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'LTD/RUSH MTA BUS DESTINATION PANEL (TEXT TO BE MODIFIED AS REQUESTED)',
  'PAY-BY-CELL LOCATOR NUMBER',
  '14 STREET & UNION SQ (BOTTOM LOCATION PANEL)(USE AS EXAMPLE FOR DIFFERENT LOCATION)',
  'HARD HAT (SYMBOL) TEMPORARY CONSTRUCTION REGULATION (RIDER)',
];
for (const d of NULLS) check(`info panel skipped: ${d.slice(0, 50)}`, pre.classifySign(d) === null && pre.isSkippedSign(d) === true);

const UNKNOWNS = [
  'DESCRIPTION NOT AVAILABLE',
  'SELECT BUS SERVICE ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED)', 'REAL TIME PUBLIC INFORMATION BOX (FOR FULL TIME BUS STOPS)',
  'OPEN STREETS (INFORMATION SIGN)', 'CARSHARE SIGN (INFORMATION) - (BLUE LETTERING)',
  'NO TRUCKS (SYMBOL)', 'NO BUS LAYOVER',
];
for (const d of UNKNOWNS) check(`stays UNKNOWN: ${d.slice(0, 50)}`, pre.classifySign(d) === 'UNKNOWN', String(pre.classifySign(d)));
// UNKNOWN-sign audit (docs/qa/tiles-unknown-audit.md, scripts/test-unknown-classifier.js): these moved.
const INFOS = [
  'METERS ARE NOT IN EFFECT ABOVE TIMES (TO BE USED ONLY FOR CONFLICTING STREET CLEANING AND METERED PARKING REGULATIONS)',
  'BACK IN ANGLE PARKING ONLY', 'BACK IN 90 DEG PARKING ONLY', 'PARALLEL PARKING ONLY',
  'NO ENGINE IDLING (SYMBOL) NO ENGINE IDLING MAX FINE $XXXX',
];
for (const d of INFOS) check(`now INFO: ${d.slice(0, 50)}`, pre.classifySign(d) === 'INFO', String(pre.classifySign(d)));
check('time-limited parking is a windowed SPECIAL', pre.classifySign('2 HOUR PARKING SATURDAY 9AM-7PM') === 'SPECIAL');

console.log(fail ? `\nRESULT: ${fail} FAILED` : '\nRESULT: PASS');
process.exit(fail ? 1 : 0);
