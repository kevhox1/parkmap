# PR #136 Minimal Ambient Layout QA Pass 1 — 2026-10-23

**Reviewed:** branch `feat/minimal-ambient-layout` at `73681d48`, against `docs/design/goal-first-ambient-design.md` Addendum 3 (A3.1-A3.5; A3.6 explicitly out of scope), Addendum 2 where not superseded, and `docs/drive-mode-default-spec.md`.
**Verdict:** 🟡 MERGE (ship with caveats). Zero blocking findings. Conditional on Kevin's Mac build + test run + live smoke (nothing here was compiled; no Swift toolchain on this host). The flag is still `false`, so everything flag-on ships dark.

## Summary

Flag-off is byte-identical by construction: the flag-off rail is the pre-DM-2 rail verbatim, the floating Report/"?" layer reduces to the same boolean as main, the browse sheet and dock are untouched, and BlockDetailView's new parameter is `nil` flag-off. The feared More-sheet swap trap does not exist: the generic `onDismiss` catch-all is guarded by `activeSheet == nil`, and the exact same swap shape is used by a documented precedent. The remaining risks are layout-only and cannot be verified from a Linux VPS: accessibility-size dock height versus the rail, and possible ragged tile heights. Both are for Kevin's smoke, and both are flag-on only.

## Acceptance criteria checklist (Addendum 3 A3.1-A3.5 + flags)

- [x] A3.1 six always-visible controls — verified by reading: rail = Search + More (+ conditional Recenter), dock = Start Driving + 3 tiles. Count at launch is 6. Live count not verified (no sim).
- [x] A3.2 rail: 56pt `.regularMaterial` circles, `VStack(spacing: 12)`, 16pt trailing, order Search / More / Recenter, `.primary`, `.title3.weight(.semibold)`, `.dynamicTypeSize(...xxxLarge)` on the rail only, labels "Search" / "More" / "Show my location", `.transition(.opacity)`, no haptic — verified in `ambientRail` / `railCircleButton`.
- [x] A3.2 Recenter off-center test is a pure function with unit tests (flag #5) — verified; see Trace 4.
- [x] A3.3 dock = guard -> Start Driving -> tiles; Report/toggle row deleted — verified in `GoalSelectorView.body`.
- [x] A3.3 tiles: minHeight 128, `.title` icon, `.headline` bold 2 lines, `.footnote` 3 lines, AX vertical reflow, `.sensoryFeedback(.selection, trigger: selectedGoal)` — verified in code (deployment target is 17.0, so `.sensoryFeedback` is available). Visual result NOT verified.
- [x] A3.3 full-palette "Pick a parking goal" row: `rectangle.split.3x1.fill`, `.borderedProminent`, `.tint(.blue)`, 56pt, `.headline`, label/hint verbatim — verified. It calls `toggleFullPaletteMode()`, whose turn-OFF branch re-applies `selectedGoal` (`selectedGoal` is never reset).
- [x] A3.4 More sheet: `.moreMenu` case, `NavigationStack` + `List(.insetGrouped)`, inline "More", Done, `.medium` detent, drag indicator, 64pt rows, 44pt blue icon tile, all-blue palette, per-row a11y label "<Title>, <subtitle>", `Toggle` row for palette — verified in `MoreMenuSheet.swift`.
- [x] A3.4 row gating and copy match the table verbatim (`moreMenuVisibleRows` + `MoreMenuRow`) — verified, and a test pins the copy.
- [x] A3.4 rows swap, never stack — verified in `handleMoreMenuSelection`; see Trace 2.
- [x] A3.4 verify-item (block-detail Report): builder confirmed BlockDetailView had none and added one; gating verified (flag-on AND community-on) — see Trace 1.
- [x] A3.5 every displaced control has a home — verified, including reachability from every state (Trace 6).
- [x] Flag-off byte-identical — verified by reading (Trace 1).
- [x] Flag `false` — `Constants.swift:262` still `false`.
- [ ] A3.8 AC 1/4/7/8/9 (live counts, AX5 reflow, tap sizes, flag-off screenshot diff) — NOT verified; require a Mac. See findings #1 and #2 and the smoke checklist at the end.
- [ ] A3.6 / A3.8 AC 2-3 (driving look, coarse GPS) — correctly NOT in this PR.

## Trace 1 — Flag-off byte-identical (priority 1)

Every `driveModeDefaultEnabled` read added in the diff:

1. `ambientRail` vs `legacyRecenterButtonStack` fork in `recenterButtonStack`. I diffed the legacy body against main's `recenterButtonStack` line by line. Find-me (`location.fill`, 44pt rounded square, accent), Find-my-car, and the clock (`parkUntilClockButtonVisible`, green when `parkUntilMode`) are identical, including `VStack(spacing: 8)` and the accessibility strings. The only deletions are the two blocks that were already gated `if AppConstants.driveModeDefaultEnabled` (Search, "?"), so flag-off never rendered them. The wrapper is an `if/else` inside `@ViewBuilder`, which only adds a `_ConditionalContent`, and nothing carries state across it.
2. `.padding(.trailing, flag ? 16 : 12)`. Flag-off is 12, as on main. `.padding(.top, 100)` is unchanged.
3. `communityMapFloatingChromeVisible(chromeVisible:driveModeDefaultEnabled:)` is `chromeVisible && !flag`. On main, flag-off was `chromeVisible && !goalSelectorDockVisible(flag: false, ...)`, and `goalSelectorDockVisible` ANDs the flag first, so it is `false` and the whole expression reduces to `chromeVisible`. Equal. The new test enumerates all 32 input combos against the old formula (a real assertion, not a tautology: it re-states the old formula inline).
4. `blockDetailReportAction(for:)` returns `nil` unless `driveModeDefaultEnabled && communityEnabled`. Flag-off passes `nil`, so `reportBlockButton` never renders and the BlockDetailView body is unchanged.
5. `GoalSelectorView` is flag-on only (mounted only when `goalDockVisible`, which is false flag-off). Its changes cannot affect flag-off.

BlockDetailView init: `onReportBlock` is `var … = nil`, declared LAST (after `goalGoodThroughLabel`); the ContentView call site passes it last, matching declaration order. The other call site (the `#Preview` at `BlockDetailView.swift:1091`) uses defaults. The memberwise-init-order scar is respected.

`GoalSelectorView` de-genericization: the only construction site is `ContentView:3346`, the only other mention is its own `#Preview` (updated). Grep of `WeParkTests` finds no use of `GoalSelectorView(`, `onToggleFullPalette` (outside MoreMenuSheet, which defines its own), `reportPill`, or "Back to goal picker". No stale callers.

Merge cleanliness: `git merge-tree origin/main HEAD` is clean.

## Trace 2 — The sheet-swap trap (priority 2): NOT a defect

The `.sheet(item: $activeSheet, onDismiss:)` catch-all at `ContentView.swift:1211` restores the rest state ONLY under `if Self.ft20BrowseSheetEnabled, activeSheet == nil, !driveModeActive, !blockSelectModeActive, !spotPlacementActive`. When a More row sets `activeSheet = .reportPin(...)` / `.mapKeyLegend` / `.parkUntil`, then by the time SwiftUI fires `onDismiss` for the outgoing `.moreMenu` item, `activeSheet` is already the non-nil new case, so the `== nil` guard skips the restore. The guard's own comment (lines 1178-1183) documents exactly this: "when a case's own dismiss handler has already reassigned `activeSheet` to a NEW non-nil case … this closure must NOT clobber that transition."

Precedent for a direct sheet-to-sheet swap in the same host: `.signCheckConfirm` `onConfirm` -> `.parkConfirm` (`:1706`), `.blockDetail` -> `.pinDetail` via `onOpenRestriction`, `.arrivalPrompt` -> `.parkUntil`. `blockDetailSheetContent`'s comment (`:2130-2133`) states the dismiss-then-present is handled by `.sheet(item:)`. The More rows add no new mechanism.

`onDismiss` side effects on the swap (clearing `selectedSegmentID`, `selectedBlockKeys`, resyncing `reminderOffsets`) are benign for every destination. `.reportPin`'s id embeds the coordinate, so it is always distinct from `"moreMenu"`.

Not verified live (no sim). Standard residual: live-confirm Report, What-the-colors-mean, and Park-until all STAY presented after tapping from More (smoke item below). I expect them to, on the strength of the guard plus precedent; I am not claiming a live pass.

In-place rows: Find my car sets `activeSheet = dismissTargetOutsideBrowseNav` (nil flag-on) then `recenterOnCar()`, the same camera call the old rail circle made. The palette toggle sets `activeSheet = nil` then `toggleFullPaletteMode()` -> `clearParkUntilFilter()` on turn-ON (the AC-27 twin, same path), `rebuildOverlays` on turn-OFF. Done and swipe-dismiss resolve to nil via `dismissTargetOutsideBrowseNav` / the catch-all.

## Trace 3 — Drive / escalation invariants (priority 3)

- `driveModeActive` is not written anywhere in the diff.
- Start Driving: `onStartDriving: { enterCruiseMode() }` unchanged. `enterCruiseMode()` itself is untouched, so the DM-3 `cruiseEntryAuthAction` routing, `isRequestingCruiseEntryAuth`, and the PR #133 one-shot auto-continue are intact. `noBlockingSheetPresented` (nil or `.browseNav` only) is untouched; `.moreMenu` correctly counts as blocking, and Start Driving is not visible while any sheet is up anyway.
- Rail hidden in drive: the mount site is `if driveModeActive { endDriveControl } else if recenterButtonStackVisible(...) { recenterButtonStack }`, unchanged, so the ambient rail (and therefore More) is unreachable mid-drive and during block-select, same as the old rail.
- Dock exclusivity (`goalSelectorDockVisible`) unchanged.
- Full-palette round trip: ON via More dismisses and clears the filter; "Pick a parking goal" calls the turn-OFF branch, which re-applies the preserved `selectedGoal`. `fullPaletteMode` is read by `moreMenuVisibleRows`, so the Park-until row appears and disappears correctly, and the More toggle reflects state because it reads ContentView's `fullPaletteMode`.

## Trace 4 — Recenter conditional (priority 4)

`ambientRecenterVisible` feeds the live `locationService.authorizationStatus` (@Observable), `locationService.userLocation`, and `region` (ContentView `@State`) into `ambientRecenterButtonVisible`. `region` is updated by `handleRegionChanged` on every `regionDidChangeAnimated` (settled gesture) and by `recenterMap(on:)` itself, so the circle re-evaluates on pan and hides again after a recenter. Cost is O(1): two abs/compares per body evaluation, and `region` already invalidates `body`.

Rule: central 50% = offset <= span*0.25 each axis. Test arithmetic checked (0.0024 < 0.0025 inside, 0.0026 outside, lng 0.0019/0.0021 likewise).

Deviation #6 judged acceptable: `.notDetermined` shows (permission route, as spec'd); authorized + no fix hides (no dot to return to; a fix arriving re-renders); denied/restricted hides (the button could do nothing useful; Start Driving routes denied users to the Settings alert).

Edge notes (non-blocking):
- Authorized user in coverage whose cold-launch `region` (Manhattan center, 400m) is not yet centered on them will see Recenter until auto-center runs. Correct behavior.
- Out-of-coverage fix: circle shows and tap produces the existing "Limited parking data outside Manhattan" toast (`recenterOnUser` guard). The circle then stays because the camera did not move. Fine.
- `.notDetermined` tap goes straight to the system prompt and bypasses the one-shot `LocationPrimingCard`. Spec A3.2(b) explicitly makes it "the route to the permission prompt," so this is as designed, but Kevin should see it once in smoke.
- Rotation/tilt: `mapView.region` is the enclosing region under rotation/tilt, so the lat/lng "central 50%" math is approximate. It is harmless today (north-up browse, no tilt). See Out of scope: A3.6 introduces a tilted launch camera, where this test needs re-evaluation.

## Trace 5 — Layout / mount chain (priority 5)

- The rail stays an overlay sibling of `mapRepresentable` in the same `ZStack` (not a new `.safeAreaInset`), with the same `.padding(.top, 100)`. No new mount-chain layer; the flag-off tree is structurally the old tree. `MapViewRepresentable.swift` is untouched, so the #31 camera-mutation invariant is not at risk.
- Deviation #3 (keep `.padding(.top, 100)`): acceptable. The ASP banner is a `.safeAreaInset` on the map only, and the rail already cleared it with this offset on main. Cost is cosmetic: on non-suspension days there is a ~100pt gap above the rail instead of spec'd safe-area + 8. Residual risk is a banner taller than 100pt at large Dynamic Type; that risk is pre-existing for the old rail.
- Rail height with Recenter showing: 3 x 56 + 24 = 192pt, starting ~159pt from the screen top on Dynamic Island devices (bottom ~351pt). No bottom-edge collision at default type.
- Deviation #2 (Start Driving 56pt, `.headline`, `.tint(.blue)`, pulled forward from A3.6.2): fine. Behavior is unchanged and the 56pt is the spec'd no-caption height. The `.regularMaterial` backdrop fix is kept.
- `.sensoryFeedback` requires iOS 17: deployment target is 17.0 across all configs.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: Accessibility-size dock height is unbounded and likely overlaps the rail / covers most of the map (A3.8 AC 8 at risk)**
  - Where: `GoalSelectorView.goalTileRow` (AX branch) + `GoalTile.tileContent(horizontalLayout: true)`; dock mounted via `bottomSafeAreaContent` in a `.safeAreaInset(edge: .bottom)`; rail is a separate overlay.
  - What: at `isAccessibilitySize` the three tiles stack vertically, each `minHeight: 128` and content-sized (headline bold + footnote with no line limits, plus 16pt vertical padding), under a Start Driving bar. The dock is not in a `ScrollView` and has no height cap. My rough estimate at AX3-AX5: ~180-260pt per tile, so a dock of ~640-900pt on a 852pt screen. That reaches the rail zone (rail bottom ~283-351pt with Recenter) and at AX5 can exceed the screen. This is an estimate from font metrics, NOT observed.
  - Expected: A3.8 AC 8, "tiles reflow to a vertical stack, no clipped text, nothing overlaps the rail."
  - Repro: Mac sim, flag on, Settings > Accessibility > Larger Text AX3 then AX5, cold launch, screenshot; also with Recenter showing.
  - Owner: `@ios-engineer`. Not a merge blocker: the reflow is exactly what the spec asked for, flag-on is dark, and Kevin's smoke checklist already has the AX5 line. If it fails, the fix is likely a height cap + `ScrollView` for the AX branch, or fewer lines at AX. Treat the smoke result as the gate for flipping the flag.

- **#2: Nothing in this PR has been compiled or run (mount-chain PR class)**
  - Where: whole PR; the PR body is honestly marked `[COMPILE-UNVERIFIED]`.
  - What: this host has no `xcodebuild`/`swiftc`. I read all six compile-failure classes and found nothing (below), but "I read it" is not a build. HANDOFF's rule for `ContentView`/overlay PRs is a live screenshot of the real app, which I could not do here.
  - Expected: Mac `xcodebuild test` green plus the live smoke below, before the flag flips.
  - Owner: Kevin (Mac).

### 🟢 Minor / nit

- **#3: Possible ragged tile heights.** Three tiles in an `HStack` with `minHeight: 128` and content-driven growth. "A Few Hours" / "Park & Forget" can wrap their headline to 2 lines at ~97pt text width (393pt device), while "Overnight" stays on 1, so one or two tiles can be taller than the others (my estimate ~140 vs 128). The structure is inherited from main (112pt) so it may already be visible there. Unverified; look at it in the smoke. If ragged, give the row a uniform height. Owner: `@ios-engineer`.
- **#4: The new block-detail "Report a problem on this block" button is the 6th element in a scroll view at a `.medium` detent**, below "Park here". It may sit below the fold until the user scrolls or drags to `.large`. It is a backstop path, not the primary one, so acceptable; confirm in smoke that it is findable.
- **#5: Stale comments.** `GoalSelectorView.swift:54` header text still describes the removed `reportPill` slot, and `ContentView.swift:~1085` mentions "`GoalSelectorView`'s new `reportPill` slot". Cosmetic. Owner: `@ios-engineer`.
- **#6: Gating of the block-detail button is untested.** `blockDetailReportAction(for:)` is private and impure, so the flag-AND-community gate has no unit test. Optional hardening: extract a one-line `nonisolated` pure function (`blockDetailReportEnabled(driveModeDefaultEnabled:communityEnabled:)`) and test the four combos. The gate is correct by reading.
- **#7: More-sheet `List` uses the default opaque grouped background**, so the `.presentationBackground(.regularMaterial)` will mostly not show through. Purely cosmetic; matches how other sheets here are configured.

### 💡 Out of scope (logged, not fixed)

- **A3.6 forward note:** the launch camera becomes tilted under Option A. `mapView.region` for a tilted camera is the enclosing rectangle of the visible trapezoid, so the lat/lng "central 50%" Recenter test will misjudge "off-center". Re-evaluate `ambientRecenterButtonVisible` (e.g. compare against the camera center / `centerCoordinate` distance) when A3.6 lands.
- **Settings and Parking 101 flag-on:** they live in the browse sheet's action list, reachable on the flag-on screen only via Search -> `.browseNav`. A3.5 doesn't list them; two taps and pre-existing since Addendum 2. Consider adding to More later.
- **Report-from-block-detail posts at the block midpoint** (`coordinateSource: "block detail"`), not the user's GPS, so a user can report a block they are not at. Identical to the existing Path-B pin-drop semantics; product call whether that needs a proximity check.
- The `Toast` "Park Until filter cleared" appears when switching ON "Show all parking rules" because the AC-27 path is reused deliberately. Not a regression.

## Deviation verdicts (the builder's six)

1. Floating chrome suppressed for the whole flag-on session: **accepted, and a real improvement.** Addendum 2's gate let Report and "?" reappear over every sheet. Reachability was checked state by state: ambient home -> More (Report, key); block detail -> its own Report button; escalated drive -> `driveActionRow` Report (the floating layer was already hidden in drive on main via `communityMapChromeVisible`); block-select / spot-placement -> already hidden on main. No flag-on state loses its only Report path. Community-off: Report row absent and floating layer absent, as before.
2. Start Driving styling pulled forward: accepted.
3. Rail `.padding(.top, 100)` kept: accepted (cosmetic gap, no collision; see Trace 5).
4. Recenter icon always `location`: accepted (the follow state cannot occur on this button).
5. `GoalSelectorView` de-genericized, explicit init, `onReturnToGoals` rename: accepted. Explicit-init parameter order equals property declaration order; the sole caller matches; no test references it.
6. Denied/restricted/no-fix hide Recenter: accepted (Trace 4).

## Compile-failure-class scan (priority 8): no hits

- Literal-receiver contextual types: tests use `XCTAssertEqual(moreMenuVisibleRows(...), [.report, ...])` (the first argument pins T) and `rows.first, MoreMenuRow.report` (explicit). Clean.
- Labeled-arg order vs declaration: `ambientRecenterButtonVisible(authorizationStatus:userLocation:visibleRegion:)`, `moreMenuVisibleRows(communityEnabled:hasParkedCar:fullPaletteMode:)`, `MoreMenuSheet(rows:fullPaletteMode:onSelect:onToggleFullPalette:onDone:)`, `railCircleButton(systemImage:accessibilityLabel:accessibilityHint:action:)`, `.reportPin(coord:streetName:segment:confirmCandidates:coordinateSource:)` all match their declarations.
- Memberwise-init order: BlockDetailView (`onReportBlock` last) and MoreMenuSheet (no private members) clean; GoalSelectorView uses an explicit init in declaration order.
- XCTest helper shadowing: the test class declares `regionCenter`, `region`, `user(...)`; none shadows an `XCTestCase` member.
- `nonisolated` on pure statics/functions used by sync XCTests: `ambientRecenterButtonVisible`, `moreMenuVisibleRows`, `MoreMenuRow` properties, `communityMapFloatingChromeVisible` are all `nonisolated`, matching the existing pattern. (The `MoreMenuRow: Equatable` enum is main-actor-by-default like `ParkingGoal`; the Swift 5 mode used by this project has the same behavior for existing enums.)
- Bare `Category`: not referenced in the new tests.
- No `Calendar.current`; no SwiftUI in Services (the new pure functions live in `ContentView.swift` / `Views/MoreMenuSheet.swift`, not Services); flag `false`; no PWA/supabase/SW/tiles/pbxproj changes. Diff footprint is 7 files, all iOS, proportionate.
- `MoreMenuSheet.swift` registration claim: **holds.** `project.pbxproj` has `PBXFileSystemSynchronizedRootGroup` sections for the app and test targets, and neither `GoalSelectorView.swift` nor any other individual Swift file appears by name in the pbxproj.

## Tests (priority 7)

Real assertions throughout: the 9 `testRecenter_*` (cover boundary-adjacent in/out on both axes, panned away, re-hide after a recenter, no fix, `.notDetermined` with and without a fix, denied/restricted at a far offset), the 7 `testMoreRows_*` plus the copy-table test, the floating-chrome pair, the 32-combo flag-off guard, the rest-state guard, and the id-collision test. Honest limits: the swap behavior, the rail/dock layout, the haptic, and the AX reflow are not unit-testable and rest on code structure plus the smoke; the PR body says so. One gap: no test for the block-detail gate (#6 above). The "default parameter binding" gap-closing test for the real flag is a good habit.

## Smoke tests run

- Static trace of every `driveModeDefaultEnabled` read in the diff (4 sites): all consistent with flag-off identity.
- Line-by-line diff of `legacyRecenterButtonStack` against main's `recenterButtonStack`: identical modulo the two flag-gated blocks.
- Traced `.sheet(item:onDismiss:)` catch-all, `dismissTargetOutsideBrowseNav`, `noBlockingSheetPresented`, `enterCruiseMode`, `toggleFullPaletteMode`/`clearParkUntilFilter`, `handleRegionChanged`/`recenterMap`, `handleReportPillTap`, `initiatePathBPinDrop` (precedent), `handleSelectionChanged` (does not touch `activeSheet`).
- `git merge-tree origin/main HEAD`: clean. Flag constant: `false`. Deployment target: 17.0.
- NOT run: `xcodebuild` build/test, sim install, screenshot (no Swift toolchain / simulator on this Linux host). Per the repo's mount-chain rule, "tests pass" would not have been sufficient evidence even if I could have run them; Kevin's live smoke is required.

## What's working

- The best structural decision in the PR: one pure `communityMapFloatingChromeVisible` plus an exhaustive flag-off equivalence test, instead of re-deriving the old boolean.
- The flag-off rail was preserved by moving it intact into `legacyRecenterButtonStack` rather than adding conditions to it, which makes the byte-identical claim easy to audit.
- Rows swap through the existing, already-guarded dismiss funnel, with a documented precedent, and no new sheet-state machinery.
- Single pure source of truth (`moreMenuVisibleRows`) for row gating, with copy pinned verbatim by a test.
- Honest PR description: deviations disclosed, unit-test limits admitted, compile status flagged.
- The builder noticed Addendum 2's gate leaked Report/"?" over sheets and fixed it rather than inheriting the bug.

## Mac smoke checklist (Kevin's re-smoke script; the PR's list plus additions marked +)

Flag-on build:
1. Cold launch: exactly Search + More on the rail and Start Driving + 3 tiles in the dock. No Report pill, "?", palette toggle, or Find-my-car circle. Count taps. Note: the gap above the rail (~100pt from the safe area) is the deliberate deviation.
2. Tiles: 128pt+, readable sub-labels; tap gives a light tick and flips the blue selection. + Check that all three tiles are the same height (finding #3).
3. Pan away from your dot: Recenter fades in below More without moving Search/More; tap recenters and it fades out. + Fresh install / location `.notDetermined`: Recenter visible; tap raises the system prompt (note it skips the priming card). + Denied: Recenter absent; Start Driving shows the Settings alert.
4. More: lists Report, What the colors mean, Show all parking rules (toggle); Find my car only with a parked car.
5. + THE SWAP CHECK: from More tap Report, then separately What the colors mean, and (full-palette) Park until a set time. Each destination must STAY presented (not bounce back to the ambient screen). Repeat the Report tap twice in a row from a fresh More open.
6. Report row opens the report sheet at your location (+ also with no GPS fix: map-center fallback). Cancel/submit lands on the ambient screen with the dock back.
7. Find my car recenters on the car and closes More. + The Recenter circle then appears (expected, the dot is off-center).
8. Show all parking rules ON: sheet closes, five colors, tiles replaced by "Pick a parking goal"; More now shows "Park until a set time". "Pick a parking goal" restores the tiles with the previous goal still selected. + Select a non-default goal first and confirm it comes back.
9. Block tap: block-detail sheet has "Report a problem on this block" (+ findable at `.medium` without hunting?); tapping it swaps to the report sheet for that block; + cancel returns to the ambient screen with no lingering block highlight.
10. Done and swipe-down on More both land on the sheet-free ambient screen with the dock.
11. Start Driving enters Cruise; End returns here. + On a fresh install, Start Driving at `.notDetermined` raises the prompt and then auto-continues into the drive (PR #133 behavior). + While driving, no rail/More/dock is visible.
12. + ASP suspension-banner day (or force the banner state): rail clears the banner on a small iPhone (SE-class) and a Dynamic Island iPhone.
13. Largest Dynamic Type AX5, and AX3: tiles reflow vertically; + check clipping, whether the dock overlaps the rail (with Recenter visible), and how much map remains (finding #1).
14. + Dark Mode and VoiceOver: More rows read "<Title>, <subtitle>"; the toggle reads as a switch; rail buttons read "Search", "More", "Show my location".
15. + Palette: confirm no green/orange/red in any new chrome (A3.8 AC 10).

Flag-off build:
16. Screenshots identical to the pre-PR build: legacy rail (Find me, Find-my-car, clock), floating Report pill + "?", browse sheet, block detail with NO new Report button.
