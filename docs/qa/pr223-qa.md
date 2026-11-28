# PR #223 (DT35-6 Apple Maps legal link) QA — 2026-11-27

**Reviewed:** branch `ios/dt35-6-legal-label` at `f43b0457`, against `docs/specs/dt35-park-flow-and-drive-fixes.md` (PR6) and field log DT35-6
**Verdict:** PASS with follow-ups (default size is fixed; AX5 and a puck-position change need a decision)

## Summary
At default text size the Maps logo and Legal link now sit clear above the whole bottom stack (the Park Until pill included) in Stoop drive mode, and margins are driven from a measured, run-loop-hopped value that is never written in `updateUIView`. Two things Kevin should know: (1) at AX5 the existing compressed Park Until pill (a bug on `main` too, tracked as DT35-8) still covers the Legal text, so "attribution never covered" is not met there; (2) lifting the map margin moves where the follow camera puts the puck while driving. The `WPInfoPill` AX5 fix works and does not change default size.

## Acceptance criteria
- [x] Default size: logo and Legal fully visible, clear of Report / Park here / Voice. Screenshots `docs/qa/pr223-assets/before-main-default.png` (Legal under the Report button, overlapped by it) vs `after-default.png` (Legal above the Park Until pill, about 8 pt gap).
- [ ] AX5: **not met.** `after-ax5.png`: the Park Until pill renders as an oversize blob over the street pill and End, and covers the Maps logo and Legal (only an Apple glyph visible). `before-main-ax5.png` shows the same blob on main, and on main the logo was under the buttons. Pre-existing cause (DT35-8), but this PR claims AX5 and the attribution is hidden. See finding #1.
- [~] AX3, no-home-indicator phone, final-approach strip: **not verified** (only the 17 Pro sim, default and AX5).
- [x] Attribution unmodified: no hide/restyle code in the diff; `testApplyNeverHidesTheMap`; screenshots show it rendered.
- [x] Margins restored exactly on exit: `MapBottomInsetController` keeps its own raw+effective snapshot; unit test round trip; End on the sim returns to the normal browse layout. Placement keeps a separate snapshot (`CurbPlacementController` untouched).
- [x] No margin write in `updateUIView`: apply goes through `DispatchQueue.main.async` from `onGeometryChange`; source-guard test scans `updateUIView`; I read the diff and found no other call site.
- [~] No camera jump: see finding #2. Not a hard jump, but the puck sits higher while following.
- [x] Flag-off unchanged: `applyDriveBottomInset` guards `v2DriveActive && driveModeActive`; clear path is a no-op when no snapshot. Full suite with shipped flags passes.
- [x] `WPInfoPill` `fixedSize(vertical:)`: default size unchanged (`after-default.png`, browse launch), AX5 browse pill wraps in its box (`after-ax5-browse-street-cleaning-pill.png`).

## Findings
### 🟡 Significant
- **#1: At AX5 the attribution is still covered in drive mode.**
  - Where: Stoop drive stack at AX5 (`WPDriveBottomV2` plus the Park Until / goal pill).
  - What: pill text overflows its tiny layout frame; `.onGeometryChange` measures the layout frame, so the Legal link is placed just above the compressed frame, under the visually oversized pill.
  - Expected: spec criterion "attribution never covered" at AX5.
  - Repro: Stoop flags on, Start driving, set text size to AX5 (`xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large`).
  - Cause is the pre-existing pill compression (`main` identical; the builder disclosed it). Fixing the pill (DT35-8) fixes this; until then the margin math cannot help. Owner `@ios-engineer`. Not blocking default-size ship; AX5 drivers are rare but Apple requires the attribution, so schedule with DT35-8.
- **#2: Follow camera places the puck higher while driving.**
  - Where: drive mode on a car at speed; sim route on Stanton St.
  - What: with the 400+ pt bottom margin MapKit centres the camera in the inset area, so the puck rides at about 31% of screen height (moving sim, `after-moving.png`; a tap landed on a curb sheet there, ignore the sheet) versus about 52% on `main` (`before-main-default.png`). On drive entry with a single static fix I saw the puck at the top right, behind the End pill, for several seconds (`after-default.png`, puck partly hidden behind End), versus screen-centre on main. With continuous fixes it recentred horizontally; with no further fixes it stays off.
  - Expected: spec says "no camera jump". The builder said no visible jump, but the puck position changed.
  - Possibly desirable (puck is no longer pressed against the card), but it is a behaviour change nobody asked for. Needs a Kevin decision after a real drive. Owner `@ios-engineer`.

### 🟢 Minor
- **#3:** `applied` margins keep the snapshot's top/left/right effective values with `insetsLayoutMarginsFromSafeArea = false`, so a safe-area change during drive (rotation, Dynamic Island state) would not update the top margin until exit. Portrait-only app, so low risk.
- **#4:** `UIScreen.main.bounds` used for the measurement and 60% clamp; fine on iPhone, would be wrong in split view or on iPad. Informational.
- **#5:** A sheet presented over the drive card (Park here, Report) leaves the inset in place. That is correct because the card stays; spec's "clear on sheet" is intentionally not done.

### 💡 Out of scope
- Browse goal sheet and Stoop park card still sit over the Legal link (spec: recommended only).

## Smoke tests run
- `xcodebuild test -only-testing:WeParkTests`, `-parallel-testing-enabled NO -jobs 4`, shipped flags, head `f43b0457`: **3270 tests, 1 skipped, 0 failures** (no flakes).
- Own sim (iPhone 17 Pro, iOS 26.5, deleted afterwards). Flags flipped **locally only** to true (uncommitted): built `main` and PR head, screenshots at default and AX5 for both, drive exit and AX5 browse pill. Screenshots in `docs/qa/pr223-assets/`. Mount-chain rule satisfied (live app inspected, not just tests).
- Dry-run `git merge-tree`: #223 vs #222 and #223 vs #221 both clean. #223 touches `ContentView.swift`, `MapViewRepresentable.swift`, `WPMapScreenV2.swift`, new `MapBottomInsetController.swift` and tests; none of the #221 park-flow files.
- Placement margin handling: `CurbPlacementController` not in the diff. Placement is excluded while `driveModeActive` (guards at `ContentView.swift` ~3459/3478/7593), so the two snapshot owners do not overlap in practice.

## What's working
Pure policy plus separate snapshot object is clean and well tested; the run-loop hop respects the #31 rule; default-size result is exactly what DT35-6 asked for; the `WPInfoPill` fix is a one-liner with no default-size regression.

## What Kevin should check on a drive
- Stoop on, Start driving at normal text size: Maps logo and Legal sit above the Park Until pill, not under Report / Voice.
- Where the blue puck sits on screen while moving (higher than before?) and whether it ever hides behind End at the start. Tell us whether the higher puck is fine.
- Tap End: map and Legal behave normally in browse; then Start driving again to confirm no leftover margin.
- If you use large text: the Legal link is likely still hidden behind the Park Until pill (known, DT35-8).

---

# Re-verification (head `178ccf27`) — 2026-11-27

**Verdict: FAIL** (puck and DT35-8 fixed; the equal top margin now makes MapKit drop the Apple "Maps" logo in the common moving case and at every AX size)

Diff since last QA (`7a31fe09..178ccf27`): 5 files only (ContentView, MapBottomInsetController, MapViewRepresentable, WPDriveV2, MapBottomInsetTests). The merge of `main` (#221/#222) is clean and adds nothing else. Spec deviation (60% to 75% clamp) confirmed in code.

## Results
1. **Puck position: fixed.** Static drive entry: puck centre at 51.6% of screen height (y 1328/2576), identical to the browse map and to `main`. Moving (simulated 12 m/s route): PR about 51% (`reverify/pr-moving.png`), `main` about 51.5% (`reverify/main-moving.png`). Puck is no longer behind End on entry (`reverify/pr-entry-default.png`).
2. **Top-anchored items:** compass is constrained to `safeAreaLayoutGuide` (not layout margins), street pill, End and ASP banner did not move versus `main` in any screenshot. `CurbPlacementController` untouched; placement is excluded during drive. Placement margins not exercised live.
3. **Margin reset: pass.** After End the browse map is pixel-identical to the pre-drive browse map (puck y 1328). Start again: Maps logo and Legal back at the default position, puck at 51.6% (`reverify/pr-restart-default.png`), no accumulated margin.
4. **Attribution: FAIL.** See finding #1.
5. **DT35-8: pass.** Park Until pill wraps to two lines at AX, sits clear of street pill, End and Legal (`pr-ax3.png`, `pr-ax5.png`). Flag-off path is a no-op by code (`...accessibility5` is the max, `fixedSize(vertical:false)`); not run live with the flag off in drive.
6. **Full suite, shipped flags, head `178ccf27`:** 3354 tests, 1 skipped, 0 failures, no flakes.
7. Note on AX: the sim applied `accessibility-large` (AX2) and the layout changed, but AX2, AX3 (`accessibility-extra-large`) and AX5 render the same drive layout (the drive stack is capped), so they are one result.

## Findings
### 🔴 #1: Apple "Maps" logo disappears; only Legal remains (moving at default size, and AX2/AX3/AX5)
- Where: `MapBottomInsetController.apply` (bottom inset plus mirrored top margin).
- What: with the mirrored top margin, top plus bottom margins approach or exceed the map height once the card stack is tall. MapKit then renders only the "Legal" link and omits the "Maps" logo. Static default entry (shorter card) shows "Maps Legal" correctly (`pr-entry-default.png`, `pr-restart-default.png`). While moving at default size the cards grow to three lines and the logo is gone (`pr-moving.png`, two frames about 3 s apart, Legal at y 1285/2576 with no logo). At AX2/AX3/AX5 only Legal shows, at y 815 (`pr-ax3.png`, `pr-ax5.png`). On `main` the logo is present while moving (`main-moving.png`). The cause (margin sum exceeding the map height) is my inference from the pattern; I did not rebuild to prove it.
- Expected: "Maps logo and Legal visible and not covered" (DT35-6, Apple requirement). Legal alone is not enough.
- Repro: Stoop flags on, Start driving, simulate movement (`simctl location start --speed=12 ...`), or set AX2+ text and look bottom-left.
- Owner: `@ios-engineer`. Suggested direction (not a fix by me): keep top margin smaller than needed to centre exactly, or cap the sum of top and bottom margins below the map height, or recentre the camera with `edgePadding` instead of mirrored margins.

### 🟢 Minor
- #2: At AX5 the ASP banner grows to two lines and "Today" runs under the street pill. Not part of this PR (the banner is pre-existing); logging only.
- #3: At AX the Park Until pill and the two side cards cover the puck (puck stays at about 52%). Same on `main` by construction; the road strip visible between the street pill and the Park Until pill is about 11% of screen height at AX, which is the card stack's size, not the 75% clamp.

## Smoke tests run
- Own sim `wepark-qa223b-sim` (iPhone 17 Pro, iOS 26.5), flags flipped locally only (StoopFlag, driveModeDefault; reverted, nothing committed). Built and screenshot-inspected `main` (`4783d03b`) and PR head: static entry, moving, End, restart, AX2/AX3/AX5. Sim and derived data deleted.
- Mount-chain rule satisfied (live app inspected, not tests alone).

## What's working
Puck framing fix is exact, margins reset cleanly, the DT35-8 pill layout is clean, and the window-coordinate measurement removed the `UIScreen.main` dependence. One more rework round (attribution logo) should close it.
