# PR #194 (Design System Phase 2a, main map) QA

**Reviewed:** `feat/ds-phase2a-map` (a1cd7c44), rebased locally onto `origin/main` (cb720f2d), against `docs/design/wepark-design-system-v0.1/DECISIONS.md` and `docs/design/wepark-round2/`
**Verdict:** MERGE (flag stays off). 0 blocking, 3 significant follow-ups, minor nits.

## Rebase
Clean. 5 commits replayed onto main (#193, #196, #197, #198 included) with zero conflicts. All 4 targets build on the rebased tree: WePark (flag off and flag on), WeParkClip, WeParkLiveActivities, ClipLiveActivities.

## Flag OFF is identical to main
- Every non-DesignSystem hunk was read. All of them are guarded by `AppConstants.designSystemV2Enabled`. The exceptions are the intended ones: the plist change and `.background(WindowAppearanceApplier())`.
  - ContentView: `fullPaletteMode` args, the goal-dock/top-chrome branches, the recenter rail condition, `resolveParkAndForgetViewport(strictGreen: false)` default, the ambient pitch, and `onChange(of: v2OutsideCoverage)`, which is inert because the computed property starts with the flag.
  - MapViewRepresentable: the new `elevationStyle = .flat` is inside the flag-on block.
- Plist key removal: only the **app target** lost `INFOPLIST_KEY_UIUserInterfaceStyle = Dark` (2 build configs). The Clip target keeps its Dark key (lines 508 and 547 untouched). The Live Activity targets never had it. Nothing changed there.
- Live check with the system set to LIGHT, flag off:
  - The launch frame at 1 s is pure black. There is no light flash.
  - The map, status bar and dock render dark.
  - `flagoff-launch-1s-systemlight.png`, `flagoff-map-systemlight.png`.
- The window override is applied in `didMoveToWindow`, i.e. before the first frame. Sheets and alerts inherit it from the window.
- Not live-verified by me: drive mode start and end, the settings sheet, search and My Car, and a keyboard or system alert in dark. They are unchanged by diff review (all behind the flag) and the full suite passes. The one residual risk is the keyboard and share sheet appearance, which previously came from the plist key and now comes from the window override. The builder's flag-off before/after pair is included in the PR.
- Note: `driveModeDefaultEnabled` is also false on main, so the flag-off UI is the old search dock.

## Flag ON: accuracy
Flipped `designSystemV2Enabled` and `driveModeDefaultEnabled` locally and reverted them (never committed).
- **v2 needs both flags.** The v2 dock only appears when `driveModeDefaultEnabled` is true, and the old recenter rail is hidden by `v2 && driveModeDefault`. The flip plan must say this.
- Base-map green comes from a single gate, `WPCurbVerdict.isParkable`. It requires `!hasUnreadableSigns` (no-data, synthetic NO DATA rule, any UNKNOWN rule) and `engine.isFree(..., ignoringMeteredPayment: false)`. The same function drives the map, the ladder (`strictGreen`) and the selected-block colour, so map green equals goal-match by construction.
- I could not do a live count of green segments against the engine. Taps were flaky, and the viewports I reached (Times Square overnight) had zero green. The nesting and gating tests below stand in for it.
- Live: Times Square overnight is all dashed coral. A metered block (W 45th, "paid until 12am") correctly draws coral.
- Nesting: `testGreenNests_overRealSegments_atSeveralTimes` runs over real tiles and passes. It covers a few hours ⊇ overnight ⊇ for days.
- Never-green tests pass: no-data, synthetic NO DATA, UNKNOWN even with other clear rules, running meter, commercial-only and plate-only.
- `.freeButRestrictionSoon` is now "dont" in base and "soon" in detail, which is correct per "green = whole window".
- **No fake green found.**
- Fresh-launch smoke: with flag on, the curb lines drew on first load without a pan (after granting location). I did not reproduce the main-app "no lines until pan" bug on flag-on. Flag-off at the wide default span shows no lines, which is the polyline hide threshold. That is not the same condition, so I can't say whether main's bug still exists at close zoom.

## A1 lever and "For days"
- Overnight shows a "Change" control. Tapping it opens 6/7/8/9/10 AM chips with "A later morning can only remove green curbs." Picking 10 AM changed the Overnight tile to "until 10 AM". The headline and map follow the active goal.
- It uses the existing `ParkingGoals.overnightMorningHourDefaultsKey = "wepark.overnightMorningEndHour"` through `setOvernightMorningHour`, so it is shared with the old UI. I did not verify old-UI persistence on device.
- "For days" uses the real 8/4/2 ladder via `resolveParkAndForgetViewport(strictGreen:)`.
  - On Wed 11/25 it showed "until Sat 11/28" (rung 4, last clear day before Sun 00:00).
  - Selecting it showed "Sat, Nov 28 / Until midnight, 3 days from now / Nothing nearby is clear for a full week. Showing curbs clear for 3 days." The sparse-line copy is correct and the span matches.
  - With no segments loaded (before location) it shows the bottom rung (Thu 11/26).
- Tests pass for the ladder end date and for headlines matching the mocks.

## Fidelity vs mocks (top mismatches)
Compared with a1-closed, b2-detail and b2-ax5 using the builder's screenshots plus my own live shots. Overall close.
1. **AX5 (significant):** the headline eats the sheet and only a clipped "A few hours" row is visible. The other two goals need a scroll. The mock shows all three rows without scrolling and puts "Change" inside the Overnight row. Also the street-cleaning pill grows to two lines and sits tight against the sheet.
2. **More and Locate:** the mock uses text-labelled circles ("More", "Locate"). The build uses icon-only circles. They have a11y labels, but the design shows words.
3. **Karma pill (♥ 12):** present in the mock, absent in the build. Probably out of scope for 2a.
4. **Curb line weight:** the mock's lines are thin. At close zoom the build's dashes and the coral blocks read heavy and wide (visible in my Times Square shot). The detail "Changes soon" is also not shown as the mock's long orange dashes.
5. **Raised vs flat:** the mock tiles are cream with the selected tile raised in yellow, and the build matches. The dock shell has a thinner top radius than the mock.
6. **Copy:** the headline "Green curbs are free from now until" matches the mock (the PR text says "will be" in one pre-location frame only, from the priming overlay state; later shots say "are"). The mock's "For days until Wed 12/2" is replaced by the real ladder date, which is expected.
- Touch targets use `WP.Target.minimum`. Toolbar circles look about 48pt or more.
- Both light and dark builder screenshots are in `docs/qa/assets/ds-phase2a/`.

## Tests
- Full WeParkTests on the rebased tree, flag off: **2992 passed, 4 failed, 1 skipped.**
- The 4 failures:
  - `AmbientDrivingLookLocationPostureTests.testRestingFix_publishesAccuracy_withoutAnyDrivePosture` and `testRestingFix_invalidAccuracy_publishesNil`. This is the known flake that also fails on main. It also failed `testAccuracyGuardEndToEnd_publishedAccuracyDrivesTheStep` in my isolated rerun.
  - `CommunityPinServiceRequestTests.testBuildRequest_noAuthorizationHeader` and `testFetchRequest_includesCrowdEphemeralChannel`. These hit 6 s timing under load and **passed in isolation**.
- Isolated rerun of CommunityPin + Phase2aMapTests + DesignSystemV01Tests: all passed.
- Phase2aMapTests (17 tests) all pass.
  - They cover nesting, never-green, copy and appearance.
  - The recursion regression test `testTagOverload_resolvesWithoutRecursing` passes.
  - `testFlagOffBuildHasNoPlistForcedStyleKey` passes.

## Findings
### 🟡 Significant
- **#1 AX5 layout:** only a clipped first goal row is visible without scrolling. Owner: `@ios-engineer`.
- **#2 Flag-flip prerequisites:** the v2 dock requires `driveModeDefaultEnabled`, and the launch screen is pinned black. Light-mode users would see a black launch when the flag goes live. This is an acknowledged TODO. Owner: `@ios-engineer`.
- **#3 Block detail sheet is not restyled** with the flag on: the tapped-block sheet still uses the old look (yellow and red bars, blue buttons). Presumably a later phase. Owner: `@designer`.

### 🟢 Minor
- More and Locate are icon-only versus the mock's text labels. Line weight reads heavy at close zoom. "Until midnight" next to a "Sat" date is slightly ambiguous (it means the end of Saturday).

### 💡 Out of scope
- Keyboard or share sheet appearance with the flag off was not live-verified.
- The main-app "lines don't draw until first pan" bug is unrelated to this PR and unconfirmed here.

## Smoke tests run
Fresh install, flag off, system light: black launch, dark map. Flag on: priming card, Allow, lines drawn without pan, street-cleaning pill, goal sheet, lever open and 10 AM, For days sparse copy, metered block detail. Screenshots are in `docs/qa/assets/ds-phase2a-qa/`.

## What's working
- Strict green gating is single-sourced.
- The flag-off hunks are cleanly guarded.
- The plist change is surgical, leaving the Clip target alone.
- The recursion crash fix is real and has a test.
- The lever and "For days" are wired to real engine data.
