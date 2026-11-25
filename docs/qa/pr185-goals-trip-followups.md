# PR #185 QA: goals/trip follow-ups (S1/S2/S3/Minor), 2026-11-24

**Reviewed:** branch `fix/goals-trip-followups` at `2bac668b`, against `docs/qa/pr183-184-goals-trip.md`
**Verdict:** MERGE-WITH-FOLLOWUPS (no blocking findings; three follow-ups below)

## Summary
S1, S2 and the core of S3 are verified live in the simulator (iPhone 17, iOS 26.5, flags flipped locally only, one sim, CI "Build and XCTest" green). The trip curb sheet no longer shows Park here, Report, chatter or the live ASP banner; the long-press toast and the More Report-row hiding work; exit restores everything. Gaps: Spot Pass is still reachable in trip mode, the floating Report pill is not trip-gated in the driveModeDefault=false flag combo, and the AX trip date line wraps mid-time.

## Acceptance criteria checklist
- [x] S1 AX5 goal banner stacks: name on its own line, window wraps at word boundaries, lever is a 44pt capsule below (`02-ax5-goal.png`; AX3 `03-ax3-goal.png`). Standard size unchanged (`01-launch.png`, lever AX frame 114x44).
- [x] S1 standard-size lever still works: picked 9 AM from the menu, label and goal text updated to "Now -> 9:00 AM tomorrow".
- [x] S2 AX5 trip banner compact: Notes disclosure, pencil Edit, "X Exit" with no truncation, no overlap with Search/More (`13-ax5-trip-banner.png`; AX3 `14-ax3-trip-banner.png`). Standard banner unchanged (`08-trip-std.png`).
- [x] S3 trip curb sheet: no Park here, no Report, no swept badge/restriction banner, no LIVE ON THIS BLOCK, no BLOCK CHATTER compose bar (`09-trip-curb.png`, AX tree dump confirms). Only "TRIP PLAN . not live" verdict + rules.
- [x] S3 long-press on map in trip mode shows toast "Exit your trip plan to park or report." and no placement/dialog (`10-trip-longpress-toast.png`).
- [x] S3 More sheet in trip mode has no Report row (`11-trip-more.png`; live More has it, `06-more-live.png`).
- [x] S3 live yellow ASP banner and goal dock hidden in trip mode (`08-trip-std.png`).
- [x] S3 exit restores: ASP banner, Start Driving, goal pill/tiles back (`15-exit-restored.png`); live curb sheet shows BLOCK CHATTER, Message field, Park here, Report (`16-live-curb.png`).
- [~] LIVE ON THIS BLOCK pins hidden: code-verified only (`showsLive` gate in `BlockDetailView`); no live pins existed on the test block, so not seen on screen either way.
- [x] Minor: no `ignoresMeteredPayment(for:)` references left in comments (grep). Goal recompute guarded by `tripPlan == nil`; `exitTripPlan` calls `rebuildOverlays(at: .nowET)`. DST tests (2026-11-01, 2026-03-08 01:30 ET + lever) and Wed 11 AM invariant present; CI suite green (I did not run xcodebuild test, per instructions).

## Findings

### Blocking
None.

### Significant
- **#1: Spot Pass is still reachable in trip mode**
  - Where: More sheet `.spotPass` row (`moreMenuVisibleRows`, only Report was gated); also `SpotPassPushRouter` / `spotPassPushReceived` path.
  - What: With a trip active, More shows "Spot Pass, Ask a neighbor for their spot" and it opens the full "Pass the spot. ... set it up while parked" flow (`12-trip-spotpass.png`). That is a live-parking action, against the product rule "nothing that suggests live parking".
  - Expected: hidden (or blocked with the same toast) while a trip plan is active, like Report; consider whether a seeker push while in trip mode should exit the trip.
  - Repro: flags on, Plan a trip -> Show where I can park -> More.
  - Owner: `@ios-engineer`

### Significant (flag-combo, code review only, not seen live)
- **#2: Floating Report pill not trip-gated when `driveModeDefaultEnabled` is false**
  - Where: `ContentView.swift` ~3312-3330, `communityMapFloatingChromeVisible(... driveModeDefaultEnabled:)`; inputs do not include `tripPlan`.
  - What: In my test build (driveModeDefault on) the pill is absent, so S3 holds. `planTripEnabled` is an independent flag; with it on and driveModeDefault off, the Report pill (and `handleReportPillTap`) remain available in trip mode.
  - Expected: pass `tripActive` into the chrome-visibility function. Not verified live (needs a different flag build).
  - Owner: `@ios-engineer`

### Minor
- **#3:** AX trip banner date line wraps mid-time ("8:28 / PM -> Tue") at AX5 (`13-ax5-trip-banner.png`); consider a line break between start and end instead.
- **#4:** At AX5 the live yellow ASP banner grows tall and sits over the Search button (`02-ax5-goal.png`). Pre-existing, live (non-trip) path, not part of this PR.
- **#5:** The parked-car deep link (`show_car_detail` notification) opens the parked car detail while in trip mode. It is the user's real car, so arguably correct; flagging for a product decision.

### Out of scope
- Drive Mode entry exits the trip (existing behavior, works: `handleDriveModeChange`). No notification action or deep link creates a new parked car; `confirmLongPressPark`/curb placement are reached only via the gated long-press and the hidden Park here.

## Smoke tests run
- Launch, standard size: goals dock, ASP banner, Start Driving, lever (`01-launch.png`).
- Lever change to 9 AM at standard size.
- AX2/AX3/AX5 goal banner; AX3/AX5 trip banner.
- Plan a trip (quick pick) -> banner, curb sheet, long-press toast, More sheet, Spot Pass.
- Exit trip (at AX3) -> live banner/dock restored; live curb sheet regression.
- Park here -> placement -> confirm -> car icon pin (`18-parked-car.png`).
- Drive start (Cruise, `19-drive.png`) and End -> returns to rest with car pin and Start Driving.
- Not run: `xcodebuild test` (CI green instead), live pins render, Edit flow, Notes expand.

## What's working
Pure `TripModeGating` is a clean single seam, the trip verdict sheet reads as clearly "not live", and exit-restore is immediate. The AX layouts are a big improvement over the pass-1 screenshots.
