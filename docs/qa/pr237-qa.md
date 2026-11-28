# PR #237 QA (Plan a Trip coverage classification from the real tile index)

**Reviewed:** branch `ios/polish-r35-followup` at `94efba61`, against the PR description and `docs/qa/pr236-qa.md`
**Verdict:** PASS with follow-ups

## Summary
The full `WeParkTests` suite passes on an erased sim with shipped flags: 3519 tests, 1 skipped, 0 failures. The merge dry-run is clean against `main` (689fe72f) and #235. The nearest-free-curb result matches an independent brute-force search on real segments. Live Stoop-on smoke worked for Central Park, DUMBO and Bryant Park at default and AX5 text size, and the row and card agreed. No blocking defects. The Central Park fix is narrower than the PR implies: most of the park still gets the "Near X: no free curbs" copy.

## Checklist
- [x] No Manhattan place gets "Not covered yet". Every Manhattan place I tried was counted or "No street parking right at".
- [~] Outside Manhattan never gets a count or a nearest curb. Governors Island, DUMBO, Brooklyn Bridge Park, LIC and Jersey City are all "Not covered". The Harlem River Bronx bank is the exception (finding #2).
- [x] The nearest free curb is correct and nearest on real segments (below).
- [x] No claim is made before tiles load, and the "checking" state ends in "unavailable" after 10 s. A unit test covers this.
- [x] Row and card agree on all three live destinations.
- [x] Full suite 3519 / 0 failures. `git merge-tree` against `origin/main` and `origin/ios/dt35-3-spine-categories` is clean (no overlapping files).

## Findings

### Blocking
None.

### Significant
- **#1: only some of Central Park gets the new copy.**
  - Where: `WPTripDestinationSummary.coverageClass`.
  - What: "Within 160 m" means "an existing tile lies under the 160 m bounding square". Tiles are about 250 m by 190 m, so this is loose. I took the real nearest curb vertex and ran the real `outcome(...)` with all tiles loaded:

    | Point | True nearest curb | Result |
    |---|---|---|
    | Builder's Central Park centre (40.7829, -73.9654) | beyond 400 m | "No street parking right at... No curbs free within a quarter mile" |
    | Great Lawn | 421 m | "Near Great Lawn: no free curbs within 2 blocks" |
    | Reservoir | 346 m | "Near Reservoir: no free curbs within 2 blocks... 0.2 mi" |
    | Sheep Meadow | 185 m | "Near Sheep Meadow: no free curbs within 2 blocks... 700 ft" |
    | North Meadow | 250 m | counted, 0 |
    | Ramble | 281 m | counted, 0 |
    | Harlem Meer | 242 m | counted, 0 |

    - These are honest, with no fake spot and no "Not covered". But the same park gets two different phrasings depending on the pin.
    - The PR's "tile within 160 m" claim is really "tile bounding square".
  - Expected: classify on real nearest-curb distance, or accept and note it. The Great Lawn case, with no curb in 400 m, says nothing about "no street parking".
  - Owner: `@ios-engineer`

### Minor
- **#2: the Harlem River Bronx bank is classified as Manhattan-covered.**
  - Points near (40.805, -73.929) are 240 m from Manhattan curbs. They are "covered" and counted 0, with "nearest is 890 ft away" across the river.
  - A point at (40.816, -73.930) has a tile within 400 m but no curb, so it gets "No street parking right at X" rather than "Not covered". That is not dishonest, but it is not "outside Manhattan" either.
  - The bounding box plus tile test cannot separate these. A polygon or a distance-to-curb test would fix it. Pre-existing for the "covered" case; new for the 160-400 m band.
- **#3: the planner row and the card say different things for no-curbs places.**
  - The row says "The trip map shows the free curbs nearby." For the Central Park centre the card then says "No curbs free for your whole trip within a quarter mile." The row promises something the card contradicts.
  - The classification agrees; the copy does not.
  - Suggest dropping "shows the free curbs nearby" or making the row neutral.
- **#4: the card headline still reads "Green curbs are free for your whole trip, until Sat 12 PM" above a "Not covered" or "no street parking" sentence.** This is pre-existing, but it is more visible now.
- **#5: the AX5 card clips the longer sentence behind the scroll cue.** The cue is present and works (R35-13); the sentence is longer, so the user has to scroll.

### Out of scope
- The destination picker suggestion rows are still bounding-box only (disclosed in the PR).

## Hand-check of the nearest free curb (real segments, brute force vs implementation)
I ranked every segment by haversine distance to the nearest vertex and took the first one that `WPCurbVerdict.isParkable` accepts for the window. Strict gate. Each window was run at four points, and the street and distance matched every time. The first line below is one example point; the others agreed.

| Point | Window | Implementation | Brute force | Verdict |
|---|---|---|---|---|
| CP SE (40.778, -73.968) | Wed 12/2 10:00-12:00 | E 78th St, 0.2 mi | E 78th N side, 379 m | agree |
| CP SE | Thu 12/3 09:00-11:00 (crosses street cleaning) | E 78th St, 0.2 mi | E 78th **S** side, 392 m | agree. The nearer N side has Mon/Thu 9-10:30 cleaning, so it was correctly skipped. |
| CP SE | Fri 21:00 to Sat 07:00 | 5th Ave, 0.2 mi | 5th Ave W side, 359 m | agree. The curb there has "No standing 7AM-7PM"; the window ends exactly at 7:00, which the engine treats as free, so this is an edge case. |
| East Village (40.728, -73.97) | all four windows | E 13th St | E 13th N side, 350 m | agree |
| Riverside Dr (40.84, -73.95) | all four windows | Riverside Dr | Riverside Dr E side, 361 m | agree |
| Riverside Dr (40.816, -73.966) | all four windows | Riverside Dr | Riverside Dr W side, 356 m | agree |

- The Central Park centre returned "none within 400 m" in all four windows. Brute force's first free curb was W 85th St at 430 m, so that is correct.
- A bad test point of mine (Riverside at 40.832, -73.958) and a point in the East River both returned "none within 450 m" from brute force and from the implementation.
- Distance text: 359 m shows as "0.2 mi" and sub-1000 ft shows as feet. Fine.

## Classification replay on real tiles
- **Manhattan (all counted or "no street parking right at"):** Bryant, Washington Square, Madison Square, Battery, Riverside 96th, Union Square, Times Square plaza, Little Island, Hudson piers 26 and 54, Roosevelt Island south and middle.
- **Outside (all "Not covered"):** DUMBO, Brooklyn Bridge Park, Randall's Island, Governors Island (outside the box), LIC, Jersey City.
- **Central Park points:** see finding #1.

## Smoke tests run
- Full `WeParkTests` on an erased sim (iPhone 17 Pro, iOS 26.5), shipped flags: 3519, 1 skipped, 0 failures. `-parallel-testing-enabled NO -jobs 4`.
- Flags flipped locally only (`StoopFlag`, `planTripEnabled`, `driveModeDefaultEnabled`, `myCarSheetV2Enabled`). Reverted with `git checkout`, so nothing was committed.
- **Live, default text size** (screenshots read):
  - Central Park, row: "No street parking right here. This spot has no curbs of its own. The trip map shows the free curbs nearby." Card: "No street parking right at Central Park. No curbs free for your whole trip within a quarter mile." It resolved immediately, with no stuck "Checking".
  - DUMBO, row: "Not covered yet". Card: "Not covered yet. WePark covers Manhattan today...". Agree.
  - Bryant Park: no row card. Card: "Near Bryant Park: 3 curbs free for your whole trip. The nearest is 410 ft away." Green curbs were visible on the map.
- **Live, AX5:** Bryant card, Central Park card and Central Park row all rendered and scrolled. The scroll cue and chevron were shown. The row card needs a scroll to reach.
- **Not driven:** DUMBO at AX5 (same layout as the others), tiles still loading (the sim loaded within the first screenshot), and the pre-parse bounding-box fallback (the index parses in `init`, so it is effectively instant).

## Loading
- `.noCurbsHere` returns nil unless `coverage.covers(point, 400)`, meaning every existing tile under the 400 m bounding box is loaded. Without that it stays on "Checking curbs near X".
- The card gives up after 10 s with "unavailable". It cannot be stuck. A test covers the nil case.
- The map loads the viewport plus a 2-tile buffer. A framed destination in Central Park resolved without delay.
- The planner row does not depend on loading (it uses existence only). Before the index parses it falls back to the bounding box, which only draws the outside card.

## What's working
- Strict-gate nearest curb matches brute force, including skipping a curb that is cleaned during the window.
- "Not covered yet" is correct for every non-Manhattan place I tried.
- The Central Park centre no longer says "Not covered", which was the PR #236 finding.
- Row and card share one classification function, so they agree.
- The sim `wepark-qa237-sim` was shut down and deleted (0 remaining), and derivedData was removed.
