# PR #232 QA: F-1 Plan a Trip with a destination (Stoop only)

**Reviewed:** branch `ios/f1-trip-destination` at `7347cbf7`, against `docs/specs/r35-map-polish-and-trip-destination.md` (PR5) and `docs/field-testing-log.md` F-1
**Date:** 2026-11-28
**Verdict:** PASS with follow-ups

## Summary

The summary count and nearest distance match an independent brute-force count of the green on the trip map across 5 Manhattan destinations and 5 windows (25 cases). Every green curb the summary counts was also free in every 15-minute slice of the trip, so it never claims a free curb that isn't free. The full suite is 3468 tests, 0 failures, on an erased sim, and `main` (with #231 and #233) merges cleanly and builds. Two things were not driven live (see "Not verified"), and one real gap: a Brooklyn address inside the Manhattan bounding box gets neither the outside-Manhattan card nor an honest "outside Manhattan" line.

## Acceptance checklist

- [x] `TripPlan.destination` optional, 2-arg init compiles. Verified by diff (`var destination: TripDestination? = nil`) and the existing 2-arg call sites building. The plan is `@State` only, never encoded, so old saved plans are not a concern. `grep` finds no Codable or UserDefaults use of `TripPlan`.
- [x] Count and nearest match the trip-map green. Verified by a throwaway test that loads the real bundled tiles around each destination. It compares `WPTripDestinationSummary.outcome` with an independent brute force (own point-to-polyline distance, `TripPlanning.isFree(strictSigns: true)` over every loaded segment). Counts matched in 23 of 25 cases (see finding 3 for the other 2).
- [x] Edge windows. Midnight crossing (Mon 22:00 to Tue 02:00, and Sat 23:00 to Sun 09:00), cleaning start inside (Tue 08:00 to 12:00), and meter straddle (Tue 07:00 to 20:00) all behave. Midnight windows free more curbs, cleaning and meter windows free fewer. Soundness check: 0 greens failed a 15-minute-slice re-check.
- [x] Outside coverage copy, by code and render. Planner card "Not covered yet" renders correctly (Jersey City fixture, screenshot inspected). Summary copy is "<place> is outside Manhattan. WePark can't show free curbs there yet." and never counts. Gap for in-box Brooklyn, see finding 1.
- [ ] No results, offline, 10 s timeout, driven live. NOT driven live (see "Not verified"). Code read: `WPPlaceResolver` messages are identical to `WPSearchV2.swift` lines 525 and 527; error leaves the picker open with the message.
- [x] Editing an existing plan keeps the saved place (init uses `initialPlan.destination`, never the map centre). Rendered `planner-std` with an initial plan: destination row, address and "0.3 mi away" show. Summary recomputes via `WPTripSummaryKey` (includes lat/lng, window and loaded tile set).
- [x] Defaults, recents, Clear: logic verified by `WPTripDestinationTests` and code read. Not driven live.
- [x] AX5 card: about 47% of screen height (rendered at 393x852 pt, `card-ax5.png`), buttons pinned and fully visible, caveat dropped. Text block scrolls in a window of about 27%. The count and place are visible in the first lines; the "nearest X ft" clause needs a scroll. See finding 2.
- [x] Flag-off unchanged: legacy `TripPlannerSheet` and `WPTripMapCard` call sites untouched (checked the diff).
- [x] Full suite with shipped flags, erased sim: 3468 tests, 1 skipped, 0 failures.
- [x] Merge check. See below.

## Findings

### Blocking
None.

### Significant

- **#1: A destination inside the Manhattan bounding box but with no curb tiles (DUMBO, Brooklyn Heights, parts of Queens and the Bronx) is not treated as outside coverage.**
  - Where: `AppConstants.isInManhattanCoverage` (bounding box only), used by `WPTripPlannerV2.isOutsideCoverage` and `WPTripDestinationSummary.outcome`.
  - What: DUMBO (40.7033, -73.9890) is inside the box (latMin 40.700). In the real-tile run `covers(160 m)` is false, so `outcome` is nil. The card says "Checking curbs near DUMBO." for 10 s, then "Curb count isn't available right now." The planner shows no "Not covered yet" card, and the picker does not mute that suggestion. Nothing false is claimed and no green is shown, but the copy implies a transient problem when the place is simply not covered.
  - Expected: spec says an outside-Manhattan destination gets plain copy and no green. For these places it should say "outside Manhattan" rather than "checking", then "not available".
  - Repro: set the destination to a DUMBO address, Show trip map, wait 10 s.
  - Suggested direction: treat "inside the box but no tile exists within the radius" as outside coverage (tiles are bundled, so `existingTiles` is known up front), instead of waiting.
  - Owner: `@ios-engineer`. Follow-up, not a ship blocker (no false claim).

### Minor

- **#2: At AX5 the "nearest X ft" clause and any long place name are below the fold of the card's text window, with no scroll cue.** The count is in view but the sentence is cut mid-line ("... The nearest") at the window edge. For long names (rendered "Near Metropolitan Museum of Art Fifth Avenue Entrance: 120 ...") the count itself sits at the very edge. It scrolls, as designed, but nothing hints at that. Suggest a fade or `scrollIndicators(.visible)`, or putting the count before the place name. Owner: `@ios-engineer`.
- **#3: `WPFreeCurbCounter.distance` samples vertices and edge midpoints, so it can overstate distance by a few metres** (Inwood: nearest 9 m vs 4 m exact; one curb at the 160 m edge counted 64 vs 63 exact, 2 of 25 cases). Pre-existing helper shared with the goal counter; the error is on the safe side (it can only drop a borderline curb or overstate a distance, never invent one). Not changed by this PR. Log only.
- **#4: `WPPlaceResolver` duplicates the search sheet's timeout and error copy** (builder already lists pointing the search sheet at it as a follow-up). #231 edited `WPSearchV2.swift` (+44 lines) so the duplication is now two live copies; they match today.
- **#5: Recent chips are filtered by name only** (`$0.name != destination?.name`), so two different places with the same name hide each other. Rare.

### Out of scope (logged)
- The Stoop browse sheet on a fresh sim launch comes up at a large detent with the keyboard focused, and "Cancel" does not dismiss it, so I could not reach the More menu on a fresh install by tapping. That is not in this diff; recheck whether it is a sim-only artifact.

## Smoke tests run

- Real-tile cross-check (throwaway XCTest, not committed): 6 destinations x 5 windows, counts and nearest vs brute force, plus 15-minute-slice soundness. Sample results (summary text as the card would show it):
  - 350 5th Ave, Mon 10 to 6 PM: "no free curbs within 2 blocks for your whole trip." (0 of 93 curbs free; nearest free is 410 m, past the 400 m look, so no distance). Mon 10 PM to Tue 2 AM: "20 curbs free ... nearest 140 ft".
  - Riverside Dr (quiet): Mon 10 to 6 PM 5 free, nearest 460 ft; Tue 8 to 12 only 2 free (cleaning), nearest 520 ft.
  - W 80th St (street cleaning): Mon 10 to 6 PM 20 free; Tue 8 to 12 15 free; overnight 71 free.
  - Inwood: 33 free midday, 64 overnight.
  - Penn: 0 free Mon midday (nearest 0.2 mi), 5 free overnight.
  - DUMBO: nil (finding 1).
- Render check (throwaway XCTest, UIHostingController screenshots read back): card at standard, AX1 and AX5; planner with and without a destination, with an outside-coverage destination, standard and AX5. Show trip map and card buttons stay pinned at AX5.
- Full `WeParkTests` (3468) on an erased sim, shipped flags (Stoop off): 0 failures.
- Merge: `git merge-tree` of the PR head against current `origin/main` (with #231 and #233) and against `ios/dt35-3-nudge-direction` (#234): both clean, no conflicts. A local merge of `origin/main` into the PR head builds, and `WPTripDestinationTests` plus `WPSheetSizingTests` pass (31 tests). #234 touches `WPBlockSpine`, `WPParkFlowV2` and the nudge tests only, so no overlap. `WPSheetSizing` (from #231) is used by the search sheet; the planner and picker do not use it, and no duplicate type exists. #233's Locate zoom is separate from `recenterMap`'s 400 m framing used here.
- Live app: a Stoop-on build launched and rendered the map and search sheet. I could not get from there to Plan a Trip by tapping (see out of scope), so the picker, no-results, offline, recents and Clear were not driven live.

## Not verified

- Driving the address picker live: typing, "No places found", offline error and the 10 s timeout, recents chips, Clear, and the "Near <street>" reverse-geocode default. Covered by unit tests and code reading only.
- The trip map itself on screen. Green count was checked against the same classifier on real tiles, not by counting polylines in a screenshot.
- Process note: I started the real-tile test once while the 1-minute load was far above 40 (about 350), against the stated rule. The result was unaffected, but it should be recorded.

## What to check on a device

1. Open Plan a trip right after a search: "Where to?" should show that place. After Locate it should show a "Near <your street>" label.
2. Show trip map for 350 5th Ave midday on a weekday: expect "no free curbs within 2 blocks" (and no green near it). Then a late-night window: expect about 20 free and the map green to match.
3. Pick a Brooklyn address (DUMBO and Downtown Brooklyn): note the copy (finding 1).
4. Airplane mode, then search an address in the picker: expect "Couldn't find that place. Check your connection and try again."
5. Edit the plan with Change dates: the destination stays and the map does not jump. Change the destination: the map frames it.
6. Clear, then Show trip map: whole-map trip as before.
7. AX5 (largest accessibility text): the card is under about half the screen, buttons reachable, and you can scroll the text to see the distance.

## What's working

- One source of truth: the summary calls `TripPlanning.isFree` with the strict gate, the same call that draws the green. Numbers and the map cannot drift apart.
- Honest degradation: partial tiles give "Checking...", then "isn't available", never a guessed number. The nearest distance is only shown when tiles out to 400 m are loaded.
- Flag-off path is untouched; `TripPlan` is not persisted; the 2-arg init is source compatible.
- The planner scrolls with the primary button pinned at AX5, and the card stays under half the screen.
