# PR #236 QA (R35 polish batch: R35-6, 8, 9, 10, 11, 12, 13)

**Reviewed:** branch `ios/polish-r35` at `0f7fde5f`, against the R35 items in `docs/field-testing-log.md`
**Verdict:** PASS with follow-ups

## Summary
Full `WeParkTests` pass on a fresh sim with shipped flags (Stoop off): 3507 tests, 1 skipped, 0 failures. Merge dry-run is clean against `main` (74685b75) and against #235 (`merge-tree`, no conflicts; not compiled together). Static review found no blocking defects. Two limits: live Stoop-on interaction was not independently driven (see "Not verified"), and one R35-12 copy issue (Central Park) is worth a follow-up.

## Checklist
- [x] R35-6: `goalCopyClock` returns the live clock under Stoop, the window instant when the live clock is behind, and the live clock when the flag is off. Tests cover all three, and the end label stays on the grid because it is built from the instant. Dock label, pill and compact drive pill all use `goalClockNow`. Not driven over a real 5-minute boundary.
- [x] R35-8 (code): the pick never leaks. `WPGoalEnd.end` honors the pick only for `.parkAndForget`. The headline, tiles and guard banner in `WPMapScreenV2` are also gated on `selectedGoal == .parkAndForget`. `refreshDrivingContextForGoalChange` runs after the synchronous `rebuildOverlays`, so it sees the new `parkUntilTarget`. It is a no-op outside drive mode. New unit tests cover every pick/goal order.
- [~] R35-8 (live): switching goals in drive mode was not driven (see below).
- [x] R35-9: `ViewThatFits` goes full name, then short form, then scaled middle-truncation, with `accessibilityLabel(street)` holding the full name. The table is tested. Live AX5 pill not driven.
- [x] R35-10: `WPMoreSheetV2` and the My Car sub-sheets use `wpContentSizedSheet` (measured height, clamp 260 to 85%, `.large` only at AX, threshold 2 pt). PR screenshot of the More sheet reviewed: tight, with only the home-indicator inset below the card. First-open jitter and AX5 scrolling not verified live.
- [x] R35-11: wide span is 0.011 and strictly inside `fullMaxDelta`. A test asserts it is in the `.full` band, and `altitude(for:cruiseSpan:stoop:)` is tested. Cold-launch red+green not driven live.
- [x] R35-12: tile coverage was checked against the real 1077-tile index (see below). Tests cover DUMBO, Downtown Brooklyn and Brooklyn Bridge Park (all `.outsideCoverage`) and Midtown (still counted).
- [x] R35-13: `WPScrollCue` is correct and tested. The PR's AX5 screenshot shows the fade and chevron over clipped text. Dedupe is by name and coordinate (about 11 m) and is tested.
- [x] Flag-off unchanged: the full suite passes, the flag-off app launches and renders the legacy UI (screenshot read: ASP banner, toolbar buttons, search dock, location prompt). Every changed call site is either Stoop-guarded or exercised through the flag.

## Findings

### Blocking
None.

### Significant
- **#1: Central Park (and other tile-less parks) gets contradictory copy.** I computed R35-12 coverage over the real tile index, 160 m radius, for 38 points.
  - Covered, as expected: Battery Park City (3 points), Roosevelt Island Main St and Cornell, Inwood (5 points), Hudson piers 40/45/57, Chelsea Piers, Little Island, Hudson Yards, Tribeca West St, Stuy Town, Battery, Wall St, Fort Tryon, UN, Riverside 80th and 100th, the Harlem and Washington Heights waterfront.
  - Correctly not covered (honest): DUMBO, Brooklyn Heights, Governors Island (already outside the box), Roosevelt Island south tip (Southpoint Park), Randall's Island, open Hudson water.
  - The misfire: the Central Park center (40.7829, -73.9654) has no tile within 160 m, so a "Central Park" destination now shows "Not covered yet. WePark covers Manhattan today. Curbs here aren't mapped." That is false for a Manhattan park. Previously it was "Checking...", then "unavailable".
  - Also, a destination in a tile-less pocket with curbs about 200 m away is told "Not covered".
  - Expected: wording that does not claim the place is outside Manhattan, or a larger fallback radius, for in-box points. Not a lie about counts, since no green is shown, so I rate it follow-up rather than blocking.
  - Owner: `@ios-engineer`
  - Note: the picker's "Not covered yet" row copy was reused verbatim. The picker row itself is bounding-box only, so the two surfaces can disagree on DUMBO (known, disclosed in the field log).

### Minor
- **#2: R35-8's `WPGoalEnd.end` is behaviorally a no-op for Overnight and A few hours.** The old code already called `ParkingGoals.target` for those goals, so the pick never leaked there. The real fix is the immediate drive-card refresh. The unit tests pass trivially for the overnight and few-hours cases. This is harmless, but the log's "done" wording overstates it.
- **#3: `presentationBackgroundInteraction(.enabled(upThrough:))` now applies to the More sheet and My Car sub-sheets.** The map behind them stays interactive at the content detent. It is consistent with the other content-sized sheets, but is a new behavior for Settings-type sheets. Confirm it is intended.
- **#4: the More sheet at the content detent still shows about 40 pt of card below the list (home-indicator inset).** That is expected and fine.

### Out of scope
- `RecentDestinationsStore.add` still dedupes by name only (disclosed).
- The curb sheet and the park-flow priming sheet were not converted (disclosed).

## Not verified (recommend a device or sim look)
Stoop is behind `designSystemV2Enabled`, which is off in shipped config. I did not flip it, so these were not independently driven:
- Goal switching in every order, in drive mode, for R35-8.
- AX5 street pill short forms.
- First-open sheet jitter.
- Cold-launch Locate span.
- Scroll cue disappearing at the bottom (logic unit-tested, the screenshot shows the "present" state only).
- The minute and 5-minute tick cadence.

## Smoke tests run
- Full `WeParkTests`: 3507 run, 0 failures, 1 skipped, parallel testing off, `-jobs 4`. The sim was fresh with a private derivedData path.
- Flag-off live launch on the sim (iPhone 17 Pro, iOS 26.5). The screenshot was read: map, ASP banner, toolbar buttons, Report and Help buttons, search dock, and the permission prompt all render.
- Tile-coverage geometry replay in Python against `Resources/tiles/index.json` (the same row/col math as `TileLoader.tileKeys` with `buffer: 0`).
- `git merge-tree` against `origin/main` and `origin/ios/dt35-3-spine-categories`: both clean.
- Read the PR screenshots for R35-10 and R35-13.

## What's working
- Careful gating: every Stoop change is flag-guarded, and the pure logic is split out and tested.
- The scroll-cue threshold is rounding-safe and rejects NaN.
- Sheet sizing reuses the existing clamped helper, with a measured height reset per sub-sheet.
- The sim was shut down and deleted (0 `wepark-qa236` devices remain), and derivedData was removed.
