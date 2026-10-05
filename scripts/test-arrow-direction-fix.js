#!/usr/bin/env node
/**
 * scripts/test-arrow-direction-fix.js
 *
 * #26 acceptance test: use DOT arrow_direction as span authority.
 *
 * Runs the REAL pipeline functions from build/preprocess.js (classifySign,
 * parseSchedule, getBlockPolyline, getBlockBearingVector,
 * resolveSignSpanDirection, createSubSegments, mostRestrictiveCategory,
 * filterSignsToManhattanBounds, dedupeSigns, groupSignsIntoBlocks --
 * shared via module.exports, no logic duplicated here) against real,
 * live-fetched NYC sign data for three hand-verified blockfaces, and asserts
 * the exact post-fix rule composition.
 *
 * Fixtures under scripts/fixtures/arrow-direction-*.json are real Socrata
 * rows -- not synthetic. Two flavors:
 *   - `arrow-direction-{e4th,e59th,pike}-*.json`: hand-slimmed (only the
 *     fields the composition layer reads), fetched 2026-09-25. Exercise
 *     createSubSegments()/resolveSignSpanDirection() directly -- proves the
 *     RESOLUTION mechanism given the data it's fed, but NOT sufficient
 *     end-to-end acceptance proof on their own (see #26 QA finding #1,
 *     docs/qa/pr117-arrow-direction.md).
 *   - `arrow-direction-e4th-RAW-unfiltered-n-bowery-2ave.json`: genuinely
 *     raw, unfiltered live pull (fetched 2026-09-27, coordinate fields
 *     preserved exactly as NYC's live data has them -- some present, some
 *     missing). Run through the REAL filterSignsToManhattanBounds() ->
 *     dedupeSigns() -> groupSignsIntoBlocks() chain in the "REAL END-TO-END"
 *     block below -- this is the test that actually proves the flagship E4th
 *     claim holds against the real production pipeline, not just a fixture.
 *
 * Usage: node scripts/test-arrow-direction-fix.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

const pp = require(path.join(ROOT, 'build/preprocess.js'));

const osmData = JSON.parse(fs.readFileSync(path.join(ROOT, 'osm_data.json'), 'utf8'));
pp._setOsmStreets(osmData);

let pass = 0, fail = 0;

function loadFixture(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8'));
}

function buildBlock(rows, street, from, to, side) {
  return {
    street: pp.normalizeNYCName(street),
    from: pp.normalizeNYCName(from),
    to: pp.normalizeNYCName(to),
    side,
    signs: rows,
    blockKey: `${pp.normalizeNYCName(street)} (${pp.normalizeNYCName(from)} to ${pp.normalizeNYCName(to)})`,
  };
}

// Runs a block through the real pipeline (blockGeo -> bearing -> createSubSegments)
// and returns the raw composed zones: [{ distStart, distEnd, dominantCategory }].
// This is the composition layer the fix targets -- deliberately NOT going all
// the way through extractSubSegment()/offsetPolyline() (intersection-setback
// trimming/geometry), which is orthogonal to and unaffected by this fix.
function composeZones(block) {
  const blockGeo = pp.getBlockPolyline(block);
  if (!blockGeo) throw new Error(`No OSM geometry resolved for ${block.blockKey} [${block.side}]`);
  const bearingVector = pp.getBlockBearingVector(blockGeo);
  const zones = pp.createSubSegments(block, bearingVector);
  return zones.map(z => ({
    distStart: z.distStart,
    distEnd: z.distEnd,
    dominantCategory: pp.mostRestrictiveCategory(z.rules),
    ruleCategories: z.rules.map(r => r.category),
  }));
}

function assertZoneCovers(zones, distance, expectedCategory, label) {
  const zone = zones.find(z => distance >= z.distStart && distance < z.distEnd);
  if (!zone) {
    fail++;
    console.log(`FAIL: ${label} -- no zone covers distance ${distance}ft. Zones: ${JSON.stringify(zones)}`);
    return;
  }
  if (zone.dominantCategory !== expectedCategory) {
    fail++;
    console.log(`FAIL: ${label} -- distance ${distance}ft resolved to zone [${zone.distStart},${zone.distEnd}) dominant=${zone.dominantCategory}, expected ${expectedCategory}`);
    return;
  }
  pass++;
  console.log(`PASS: ${label} -- [${zone.distStart},${zone.distEnd}) = ${expectedCategory}`);
}

function assertNoZoneCovers(zones, distance, label) {
  const zone = zones.find(z => distance >= z.distStart && distance < z.distEnd);
  if (zone) {
    fail++;
    console.log(`FAIL: ${label} -- expected NO zone at distance ${distance}ft (coverage gap), found [${zone.distStart},${zone.distEnd}) = ${zone.dominantCategory}`);
    return;
  }
  pass++;
  console.log(`PASS: ${label} -- no zone at distance ${distance}ft, as expected`);
}

// ============================================================================
// Block 1: E 4th St, N side, Bowery -> 2nd Ave -- COMPOSITION-LAYER test only.
//
// #26 QA finding #1 (docs/qa/pr117-arrow-direction.md): this block exercises
// createSubSegments()/resolveSignSpanDirection() directly against a fixture
// built from real field values -- but that fixture (like a `block` object
// built directly) sits BELOW filterSignsToManhattanBounds(), the real
// pipeline's Manhattan-bounds filter. QA found that filter used to silently
// drop the three signs (191/315/399ft) load-bearing for this exact block's
// claimed result, because NYC's live data omits their sign_x_coord/
// sign_y_coord -- a real, live, unrelated-to-this-fixture data gap. This
// block's assertions below are still valid (they prove the RESOLUTION
// mechanism is correct given the data it's fed) but are NOT sufficient
// end-to-end acceptance proof by themselves -- see the REAL END-TO-END
// section immediately after, which runs the actual filter/dedup/group chain
// (filterSignsToManhattanBounds/dedupeSigns/groupSignsIntoBlocks) against an
// unfiltered raw live pull that still has the coordinate-missing rows in it,
// exactly as main() would receive them.
// ============================================================================
console.log('\n=== Block 1: E 4th St, N side, Bowery -> 2nd Ave (composition-layer only -- see real end-to-end test below) ===');
{
  const rows = loadFixture('arrow-direction-e4th-bowery-2ave-n.json');
  const block = buildBlock(rows, 'EAST 4 STREET', 'BOWERY', '2 AVENUE', 'N');
  const zones = composeZones(block);
  console.log('Composed zones:', JSON.stringify(zones, null, 2));

  assertZoneCovers(zones, 20, 'NO_STANDING', 'E4th: 0-49ft (Bowery corner) is NO_STANDING');
  assertZoneCovers(zones, 100, 'ASP_MON_THU', 'E4th: 63 E 4th St (~100-191ft) is ASP_MON_THU, not swallowed by the 49ft sign');
  assertZoneCovers(zones, 250, 'ASP_MON_THU', 'E4th: 191-315ft stays ASP_MON_THU');
  assertZoneCovers(zones, 360, 'ASP_MON_THU', 'E4th: 315-399ft stays ASP_MON_THU (399ft closing sign now reads backward, not forward)');
  assertZoneCovers(zones, 410, 'NO_PARKING', 'E4th: 399-421ft is NO_PARKING (driveway marker, TF2-13 cap never invoked -- arrow_direction alone resolves it backward)');
  assertZoneCovers(zones, 450, 'NO_STANDING', 'E4th: 421-485ft is NO_STANDING (485ft sign now reads backward)');
  // NOTE: this zone is ALSO a real flip, not an agree case -- the 485ft NO
  // STANDING ANYTIME sign's glyph ("-->") reads forward under the old logic
  // and used to dominate this zone by priority (NO_STANDING beats METERED);
  // its arrow_direction (West) resolves it backward instead, so METERED
  // (the two 485ft signs that genuinely agree: HMP meter + ASP broom, both
  // arrow_direction East) is left as the sole dominant category here.
  assertZoneCovers(zones, 500, 'METERED', 'E4th: 485-545ft is METERED (was wrongly NO_STANDING pre-fix -- a THIRD flip on this one block)');

  // The full logical ASP stretch this fix restores, contiguous:
  const aspZone = zones.filter(z => z.dominantCategory === 'ASP_MON_THU');
  const aspStart = Math.min(...aspZone.map(z => z.distStart));
  const aspEnd = Math.max(...aspZone.map(z => z.distEnd));
  if (aspStart === 49 && aspEnd === 399) {
    pass++;
    console.log(`PASS: E4th: contiguous ASP_MON_THU stretch is exactly [49,399) -- 350ft, matching docs/open-items.md #26's "~350ft ASP stretch" description`);
  } else {
    fail++;
    console.log(`FAIL: E4th: expected contiguous ASP_MON_THU [49,399), got [${aspStart},${aspEnd})`);
  }
}

// ============================================================================
// REAL END-TO-END TEST: E 4th St, N side, Bowery -> 2nd Ave.
//
// #26 QA finding #1 fix proof. scripts/fixtures/arrow-direction-e4th-RAW-
// unfiltered-n-bowery-2ave.json is a genuinely RAW, unfiltered live pull
// (re-fetched fresh for this fix, both Socrata datasets, deduplicated only
// for identical-object API duplication -- not hand-slimmed of coordinate
// fields) for this exact block. 8 of its 17 rows are missing sign_x_coord/
// sign_y_coord in NYC's live data TODAY, including all three ASP_MON_THU
// signs (191/315/399ft) this block's claimed result depends on -- confirmed
// present in this fixture exactly as QA found them.
//
// This runs the REAL production functions in the REAL order main() calls
// them: filterSignsToManhattanBounds() -> dedupeSigns() -> groupSignsIntoBlocks()
// -> getBlockPolyline() -> getBlockBearingVector() -> createSubSegments().
// If the coordinate-filter fix regresses, this test fails the same way QA's
// live full-pipeline regen did.
// ============================================================================
console.log('\n=== REAL END-TO-END: E 4th St, N side, Bowery -> 2nd Ave (full ingestion pipeline, not a fixture bypass) ===');
{
  const rawRows = loadFixture('arrow-direction-e4th-RAW-unfiltered-n-bowery-2ave.json');
  const missingCoords = rawRows.filter(r => !r.sign_x_coord || !r.sign_y_coord).length;
  console.log(`Raw fixture: ${rawRows.length} rows, ${missingCoords} missing sign_x_coord/sign_y_coord (must be > 0 -- this test is meaningless otherwise)`);
  if (missingCoords === 0) {
    fail++;
    console.log('FAIL: fixture has no coordinate-missing rows -- this test no longer exercises finding #1, fixture needs refreshing from a live pull');
  } else {
    pass++;
    console.log(`PASS: fixture genuinely exercises the coordinate-missing path (${missingCoords}/${rawRows.length} rows)`);
  }

  const { filtered, coordMissingCount } = pp.filterSignsToManhattanBounds(rawRows);
  console.log(`filterSignsToManhattanBounds: ${filtered.length}/${rawRows.length} kept, ${coordMissingCount} coordinate-missing (all must be recovered, not dropped)`);
  if (filtered.length !== rawRows.length) {
    fail++;
    console.log(`FAIL: expected ALL ${rawRows.length} rows to survive the real Manhattan-bounds filter (every row is genuinely borough=Manhattan) -- only ${filtered.length} did`);
  } else {
    pass++;
    console.log('PASS: no rows dropped by filterSignsToManhattanBounds -- coordinate-missing rows recovered via borough membership');
  }

  const { deduped } = pp.dedupeSigns(filtered);
  const { blocks } = pp.groupSignsIntoBlocks(deduped);
  const fullKey = 'EAST 4TH STREET (BOWERY to 2ND AVENUE) [N]';
  const block = blocks[fullKey];
  if (!block) {
    fail++;
    console.log(`FAIL: block "${fullKey}" not found after real grouping. Keys present: ${Object.keys(blocks).join(', ')}`);
  } else {
    pass++;
    console.log(`PASS: block found with ${block.signs.length} signs after real filter/dedup/group`);

    const blockGeo = pp.getBlockPolyline(block);
    const bearingVector = pp.getBlockBearingVector(blockGeo);
    const zones = pp.createSubSegments(block, bearingVector).map(z => ({
      distStart: z.distStart, distEnd: z.distEnd,
      dominantCategory: pp.mostRestrictiveCategory(z.rules),
    }));
    console.log('Real end-to-end composed zones:', JSON.stringify(zones));

    assertZoneCovers(zones, 20, 'NO_STANDING', 'E4th REAL PIPELINE: 0-49ft is NO_STANDING');
    assertZoneCovers(zones, 100, 'ASP_MON_THU', 'E4th REAL PIPELINE: 63 E 4th St (~100-191ft) is ASP_MON_THU end-to-end -- the coordinate-missing 191/315/399ft signs were recovered, not dropped, and this is the actual claim this PR/#26 exists to fix');
    assertZoneCovers(zones, 360, 'ASP_MON_THU', 'E4th REAL PIPELINE: 315-399ft is ASP_MON_THU');
    assertZoneCovers(zones, 410, 'NO_PARKING', 'E4th REAL PIPELINE: 399-421ft is NO_PARKING');
    assertZoneCovers(zones, 500, 'METERED', 'E4th REAL PIPELINE: 485-545ft is METERED (both 485ft agreeing signs were also coordinate-missing and recovered)');
  }
}

// ============================================================================
// Block 2: E 59th St, N side, 5th Ave -> Madison Ave.
// Hand-verified: bracket-style METERED/NO_STANDING(timed) signs at 100/302ft
// (glyph <->, no arrow_direction -- unaffected) bracket a NO_STANDING ANYTIME
// corner sign at 80ft whose arrow_direction (West) disagrees with its glyph
// ("-->") -- same flip pattern as E4th's 49ft sign, plus a second flip on the
// three signs at 374ft. Coverage-gap finding: under the pre-fix glyph-only
// logic, the 80ft sign's glyph ('towards') never covered [0,80) backward, so
// that corner produced ZERO surviving zones (dropped entirely) -- the fix
// both corrects the flip AND fills that gap.
// ============================================================================
console.log('\n=== Block 2: E 59th St, N side, 5th Ave -> Madison Ave ===');
{
  const rows = loadFixture('arrow-direction-e59th-5ave-madison-n.json');
  const block = buildBlock(rows, 'EAST 59 STREET', '5 AVENUE', 'MADISON AVENUE', 'N');
  const zones = composeZones(block);
  console.log('Composed zones:', JSON.stringify(zones, null, 2));

  assertZoneCovers(zones, 40, 'NO_STANDING', 'E59th: 0-80ft is NO_STANDING (was a coverage GAP pre-fix -- the 80ft sign\'s glyph never covered it backward)');
  assertZoneCovers(zones, 90, 'NO_STANDING', 'E59th: 80-100ft still NO_STANDING (the bracket\'s timed NO_STANDING sign), but no longer carries the fabricated ANYTIME rule from the 80ft sign');
  assertZoneCovers(zones, 200, 'NO_STANDING', 'E59th: 100-302ft dominant is still the timed NO_STANDING bracket sign (priority 1 beats METERED\'s priority 5) -- unaffected by the fix, both signs here are glyph "<->"/no arrow_direction');
  assertZoneCovers(zones, 340, 'NO_STANDING', 'E59th: 302-374ft same bracket, same reasoning -- unaffected');
  assertZoneCovers(zones, 400, 'NO_STANDING', 'E59th: 374-420ft is NO_STANDING (the 420ft <-> sign, unaffected by the fix)');
}

// ============================================================================
// Block 3: Pike St, E side, Henry St -> East Broadway.
// Hand-verified: two REAL dominant-category flips (not just gap-filling).
// The 90ft NO_PARKING sign's arrow_direction (North) AGREES with its glyph
// (forward) -- an agree case, unaffected. But the paired signs at 90ft/186ft
// (METERED, ASP_DAILY -- glyph "-->", arrow_direction South) all flip to
// backward, which changes the DOMINANT PAINTED CATEGORY of the [69,90) and
// [130,186) zones from NO_PARKING (pre-fix) to METERED (post-fix).
// ============================================================================
console.log('\n=== Block 3: Pike St, E side, Henry St -> East Broadway ===');
{
  const rows = loadFixture('arrow-direction-pike-henry-eastbway-e.json');
  const block = buildBlock(rows, 'PIKE STREET', 'HENRY STREET', 'EAST BROADWAY', 'E');
  const zones = composeZones(block);
  console.log('Composed zones:', JSON.stringify(zones, null, 2));

  assertZoneCovers(zones, 50, 'NO_PARKING', 'Pike St: 0-69ft is NO_PARKING (was a coverage GAP pre-fix)');
  assertZoneCovers(zones, 80, 'METERED', 'Pike St: 69-90ft is METERED (was NO_PARKING pre-fix -- a real dominant-category flip)');
  assertZoneCovers(zones, 110, 'NO_PARKING', 'Pike St: 90-130ft is NO_PARKING (the 90ft sign\'s North arrow agrees with glyph -- unaffected agree case, bracketed by the 130ft sign\'s corrected backward read)');
  assertZoneCovers(zones, 160, 'METERED', 'Pike St: 130-186ft is METERED (was NO_PARKING pre-fix -- second dominant-category flip)');
  assertNoZoneCovers(zones, 220, 'Pike St: nothing past 186ft (was wrongly painted METERED pre-fix, extending past the real block into the East Broadway intersection buffer)');
}

// ============================================================================
console.log(`\n${'='.repeat(60)}`);
console.log(`RESULT: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
