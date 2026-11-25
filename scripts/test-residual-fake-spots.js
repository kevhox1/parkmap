#!/usr/bin/env node
/**
 * scripts/test-residual-fake-spots.js
 *
 * Gate for the residual fake-spot fixes in build/preprocess.js (product rule: never show a spot
 * that isn't a spot; when unsure the curb reads as not parkable).
 *   1. Segmentation gap: long-shaft double arrows ("<--->") are 'both'; a timed commercial /
 *      truck-loading sign on the same pole as a meter follows the meter into every zone it covers.
 *   2. Superseded signs: detected; a zone resting ONLY on unresolved superseded signs (none anytime)
 *      is flagged no-data; a replacement on the same face resolves it.
 *   (Truncated day words, time and meter fail-safes live in test-day-parsing.js.)
 *
 * Offline: synthetic blocks through the REAL createSubSegments.   node scripts/test-residual-fake-spots.js
 */
const pre = require('../build/preprocess.js');

let fail = 0;
function check(name, ok, info) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${info ? ' -- ' + info : ''}`); if (!ok) fail++; }

const sign = (code, desc, dist, arrowDirection) => ({
  sign_code: code, sign_description: desc, distance_from_intersection: String(dist),
  ...(arrowDirection && { arrow_direction: arrowDirection }),
});
const block = signs => ({ street: 'TEST AVENUE', from: 'A STREET', to: 'B STREET', side: 'E', signs, blockKey: 'TEST AVENUE (A STREET to B STREET)' });
const NORTH = { x: 0, y: 1 }; // from->to runs north: increasing distance = north
const cats = z => z.rules.map(r => r.category).sort().join(',');

// ---- 1a. 8th Avenue shape: the pole-mate commercial sign points back (arrow_direction South) ----
{
  const C = 'PS 3 HMP COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM';
  const M = '2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 7AM-10PM <->';
  const zones = pre.createSubSegments(block([
    sign('PS-289C', C + ' <->', 109), sign('PS-554C', M, 109),
    sign('PS-554C', M, 203), sign('PS-289CA', C + ' -->', 203, 'South'),
  ]), NORTH);
  const tail = zones[zones.length - 1];
  check('companion: tail zone keeps the weekday commercial sign next to the evening meter',
    tail.rules.some(sd => sd.category === 'NO_PARKING') && tail.rules.some(sd => sd.category === 'METERED'), cats(tail));
  check('companion: nothing is dropped from other zones', zones.every(z => z.rules.length >= 2));
}

// ---- 1b. St Nicholas shape: truck loading printed "<--->" (was read as one direction) ----
{
  const T = 'TRUCK (SYMBOL) TRUCK LOADING ONLY MONDAY-FRIDAY 8:30AM-1PM';
  const zones = pre.createSubSegments(block([
    sign('PS-1GA', 'NO STANDING ANYTIME --> (SUPERSEDES SP-1044BA)', 43),
    sign('PS-569E', T + ' <--->', 91), sign('PS-504C', '2 HMP MONDAY-FRIDAY 1PM-10PM SATURDAY 8:30AM-10PM <->', 91),
    sign('PS-569EA', T + ' -->', 232), sign('PS-504CA', '2 HMP MONDAY-FRIDAY 1PM-10PM SATURDAY 8:30AM-10PM -->', 232),
  ]), null);
  const z91 = zones.find(z => z.distStart === 43 && z.distEnd === 91);
  check('glyph <---> covers the zone before its pole', z91 && z91.rules.some(sd => sd.category === 'TRUCK_LOADING'), z91 && cats(z91));
}

// ---- 2. Superseded signs ----
{
  check('superseded: "SUPERSEDED BY" is a marker', pre.parseSupersededBy('NO PARKING (SANITATION BROOM SYMBOL) 11AM TO 12:30PM WED <---> (SUPERSEDED BY PS-84B)').superseded);
  check('superseded: replacement code extracted', pre.parseSupersededBy('X (SUPERSEDED BY PS-84B)').codes[0] === 'PS-84B');
  check('superseded: "REPLACED BY" is a marker', pre.parseSupersededBy('NO STANDING ANYTIME (REPLACED BY SP-1)').superseded);
  check('superseded: "SUPERSEDES" is NOT a marker (normal current sign)', !pre.parseSupersededBy('NO STANDING ANYTIME <-> (SUPERSEDES SP-1044B)').superseded);
  check('superseded: typo "SUPERSED ES" is NOT a marker', !pre.parseSupersededBy('NO STOPPING ANYTIME <------> SUPERSED ES R7-1R DATED 8-18 -86').superseded);

  const ASP = 'NO PARKING (SANITATION BROOM SYMBOL) 11AM TO 12:30PM WED <---> (SUPERSEDED BY PS-84B)';
  const alone = pre.createSubSegments(block([sign('SP-1', ASP, 100)]), null);
  check('superseded alone, replacement missing -> no-data zone', alone.length === 1 && alone[0].noData === true);

  const withReplacement = pre.createSubSegments(block([sign('SP-1', ASP, 100), sign('PS-84B', 'NO PARKING (SANITATION BROOM SYMBOL) 11AM-12:30PM WED <->', 100)]), null);
  check('superseded with its replacement on the face -> not no-data', withReplacement.every(z => !z.noData));

  const withOther = pre.createSubSegments(block([sign('SP-1', ASP, 100), sign('PS-9', '2 HMP 8AM-7PM EXCEPT SUNDAY <->', 100)]), null);
  check('superseded next to a live sign -> not no-data (superseded rule still applies)',
    withOther.every(z => !z.noData) && withOther[0].rules.length === 2);

  const withInfo = pre.createSubSegments(block([sign('SP-1', ASP, 100), sign('R7-101', 'ANGLE PARKING ONLY <---->', 100)]), null);
  check('superseded + an UNKNOWN-category info sign (never restricts) -> still no-data', withInfo.length === 1 && withInfo[0].noData === true);

  const anytime =pre.createSubSegments(block([sign('SP-2', 'NO STANDING ANYTIME <-----> (SUPERSEDED BY R7-20R)', 100)]), null);
  check('superseded NO STANDING ANYTIME alone stays an ordinary (red) rule, not no-data', anytime.every(z => !z.noData));
}

process.exit(fail ? 1 : 0);
