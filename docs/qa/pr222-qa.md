# PR #222 (DT35-5 direction of travel) QA — 2026-11-27

**Reviewed:** branch `ios/dt35-5-drive-direction` at `722c11d4`, against `docs/specs/dt35-park-flow-and-drive-fixes.md` (PR5) and field log DT35-5
**Verdict:** PASS with follow-ups (no blockers; the direction was never wrong in any test)

## Summary
The label logic is sound: axis from the tile side letters, direction from the street's local bearing picked to agree with raw GPS course, nil on every ambiguous case. Over every vertex pair of every real tile segment (both travel directions, 127,370 labelled cases) there was zero contradiction with the Manhattan grid frame. Live on the sim, driving Stanton St eastbound shows "Stanton St · Eastbound", and crossing Chrystie (heading 90 deg off that street) shows no suffix. Follow-ups are minor.

## Acceptance criteria
- [x] Stanton (N/S sides) 100 deg Eastbound / 280 deg Westbound — unit test + my tile sweep + live sim
- [x] 2nd Ave style (E/W sides, 29 deg) 5/25/55 deg Northbound, 205 deg Southbound — unit test + sweep
- [x] Speed gate: opens at 2.0, closes after 3 s below 1.0, holds between; held heading gives nil — code read of `WPDriveDirectionGate`, tests
- [x] Mid-turn (>60 deg off street) nil — sweep + live (Chrystie crossing)
- [x] Raw GPS course only (`locationService.driveHeading`, never `effectiveDriveHeading`/snapped) — code read
- [x] Flag off unchanged (`refreshDriveDirection` guards on `v2DriveActive`, `direction` defaults nil) — code read, full suite with shipped flags
- [~] AX5 wrap — not screenshot-verified (needs moving GPS at AX5); text is one `Text` with existing `fixedSize(vertical)`, same pattern as the street pill. Kevin to glance.

## Independent verification (not the builder's tests)
1. **Real-tile sweep** (`docs/qa/pr222-assets/tile_sweep.py`, a Python port of `label()` run over all 1078 tiles, every vertex pair, both travel directions, heading = exact travel bearing). Ground truth = Manhattan frame (grid north = 29 deg) inside Manhattan, true north elsewhere.
   - 127,370 labelled, **0 wrong**; 12,420 nil (8.9%).
   - Broadway: 3,656 labelled, 512 nil (diagonal band). 5th Ave 1,910 ok / 42 nil. 2nd Ave 2,160 / 54. Stanton 168 / 2. Bowery 392 / 6. E and W Houston 448+244 ok, 10 nil. 14th St ok.
   - Avenues labelled Northbound/Southbound even at 29 deg. A port can mirror a bug in the original, so this is evidence for the sign/axis rules, not a proof of the Swift file; the Swift tests and the live drive cover that side.
2. **Flipping side letters mid-street**: the axis comes from the matched segment's own letter, so a street that flips N/S to E/W mid-way flips axis at the segment boundary. The `offAxis > 60` check returns nil when letter and geometry disagree; in the sweep no segment produced a contradictory label.
3. **One-way**: Stanton tiles are one-way "to" with line digitised eastward; live eastbound drive labelled Eastbound. Label reports actual motion (spec: wrong-way logic owns warnings).
4. **Live (sim, iOS 26.5, flags on locally, not committed)**: stationary on Bowery shows "Bowery" only; moving at 8 m/s on Stanton shows "Stanton St · Eastbound" (`docs/qa/pr222-assets/stanton-eastbound.png`); at the Chrystie crossing the pill shows "Chrystie St" with no suffix (`chrystie-crossing-no-label.png`). The pill is a single wrapping Text; renders cleanly.
5. **VoiceOver**: `accessibilityText` gives "Street: Stanton St, eastbound" (lowercased), and no suffix gives "Street: Stanton St". Read in code and tests; not run with VoiceOver.

## Hysteresis review
- `update(speed:now:)`: >=2.0 opens and clears the slow timer; 1.0..2.0 holds state and clears the timer (so the 3 s must be continuous below 1.0, as spec'd); <1.0 starts the timer and closes after 3 s. nil speed counts as stopped.
- A quiet GPS stream at a stop is handled by a one-shot Task (3.1 s) that rechecks the gate; it is cancelled and re-armed on each fix and cancelled by `resetDriveDirection()` on drive entry/exit. Correct.
- Stale `driveSpeed` after the stream stops: task re-reads it and closes if it was < 1.0. If the last speed was between 1 and 2 m/s and fixes stop, the label stays (documented hold behaviour; edge case, see follow-up 2).

## Findings
### 🟢 Minor
- **#1: Gate clock is wall-clock `Date.timeIntervalSinceReferenceDate`.** A system clock jump could stretch or cut the 3 s grace. Uptime clock would be sturdier. Owner `@ios-engineer`.
- **#2: Stale-fix hold.** If GPS goes silent while the last speed was 1 to 2 m/s, the label stays until a new fix. Rare (needs creeping speed plus signal loss). Owner `@ios-engineer`.
- **#3: Labelled-but-oblique streets.** 512 segments (e.g. W 125th/126th at 33 to 35 deg off the N/S line, Macombs Place) are labelled although the street is nearer to the opposite axis than expected (offAxis 45 to 57). Result is still the correct direction word for the geometry (sweep: no contradiction). Informational.
- **#4: Deviation notes accepted.** `moving:` from a separate gate (needed for hysteresis); diagonal band +/-10 (a +/-20 band would blank Manhattan's own 29 deg avenues: 35 to 55 from axis only blanks true diagonals, Broadway keeps 88% labelled); no short forms (pill wraps). All reasonable. The spec text should be updated to match.

### 💡 Out of scope
- Voice callout of direction; legacy card untouched by design.

## Smoke tests run
- `xcodebuild test -only-testing:WeParkTests`, `-parallel-testing-enabled NO -jobs 4`, shipped flags (all off), head `722c11d4`: **3277 tests, 1 skipped, 0 failures** (no flakes hit).
- Live sim drive on Stanton (above).
- Dry-run `git merge-tree`: #222 vs #223, #222 vs #221: clean, no conflicts. #222 touches only `ContentView.swift`, `WPDriveDirection.swift`, `WPDriveV2.swift`, tests. None of the #221 park-flow files (`ParkSideResolver`, park side card, `ParkPinService`, `LocationService`).
- Flag-off: `WPDriveTopChromeV2.direction` defaults to nil; `refreshDriveDirection` returns early when `!v2DriveActive`; legacy card never reads it.

## What's working
Clean pure function, good separation of gate from label, no new timers in the view tree, raw heading respected, and conservative nil on every uncertainty.

## What Kevin should check on a drive
- Stanton or any crosstown street: suffix appears above about 5 mph, vanishes about 3 s after stopping, stays through a short slow-down at a light.
- An avenue (2nd, 5th): "Northbound"/"Southbound" matches your actual direction.
- Broadway and Bowery diagonal stretches: no suffix is expected.
- Mid-turn at a corner: suffix drops, then returns on the new street.
- Large text: pill wraps by words and End stays reachable.
