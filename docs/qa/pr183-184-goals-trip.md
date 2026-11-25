# PR #183 (goals rework) + PR #184 (Plan a Trip) QA, 2026-11-24

Reviewed: `feat/goals-rework` @ a735a90a (#183) and `feat/plan-a-trip` (#184, stacked, includes #183) against `docs/specs/goals-rework.md` and the owner decisions in `docs/sign-types-review.md`.
Built the #184 head with the six flags flipped locally (never committed), ran it on a dedicated simulator (iPhone 17, iOS 26.5, fixed location Bleecker and Lafayette, sim clock Tue 19:27 ET).

**Verdict #183: MERGE-WITH-FOLLOWUPS**
**Verdict #184: MERGE-WITH-FOLLOWUPS** (dark-shipped behind `planTripEnabled = false`)

CI: `gh pr checks 183` and `184` both green (Build and XCTest, Xcode 26). I did not run `xcodebuild test`.

## Summary
The single free rule is genuinely single: every `isFree` caller on the goal path, the Park & Forget viewport resolver, `nextMoveForcingDate`, the drive card plumbing (`parkUntilIgnoresMeteredPayment` is forced `false` on the goal path and every reset path) and the trip evaluator pass `ignoringMeteredPayment: false`. Window math is DST-safe and the Overnight/A Few Hours/Park & Forget superset holds on screen and in code. Live: banner copy, goal switching, lever (shrinks green, persists across relaunch), "Show all sign details" (default off, restores rich palette), drive chip matching the map, trip planner, purple "not live" banner, curb verdicts, exit restoring the live goal map all work. No blockers. Follow-ups are accessibility at AX5 (both PRs) and a couple of trip-mode "unmistakably not live" gaps.

## Acceptance checklist
- [x] No metered tolerance anywhere. Grep of `ignoringMeteredPayment: true`/`ignoresMeteredPayment`: no live callers left (only stale comments, finding G1). Map overlay, `goalAwareChip` (fed `false`), P&F viewport (hardcoded `false`), `goalGoodThroughLabel` via `match`, trip `isFree` all strict.
- [x] Window math in ET: `startOfDayET(offsetDays:)` uses `Calendar.date(byAdding: .day)` (not 86400*n), `bySettingHour` on an ET start-of-day, so spring-forward/fall-back days land on 7:00 AM wall clock. Midnight to 7 AM: anchor = today 7 AM, exactly 7:00:00 rolls to tomorrow. A Few Hours = `min(now+3h, overnightEnd)` uses absolute interval (correct across DST). Reasoned, not executed on a DST night.
- [x] Lever monotonic: lever hour applied to the day chosen by the default 7 AM rule; past 6 AM falls back to the default end; invariant test iterates 6..10 over real tiles and 9 times. Persisted via `@AppStorage`, sanitized (verified 9 AM survives terminate/relaunch, screenshot 06).
- [x] Invariant tests exercise real bundled tiles (`index.json` + `tile_r_c.json`, every 40th tile, cap 6000, asserts >500 segments and >0 green so non-vacuous). They call `match` with the production target math, so a regression to per-goal metered tolerance would flip `testInvariant_noGoalIsGreenForARunningMeter` (asserts `checked > 0`). One gap: the meter test only runs Tue 1 PM (G3).
- [x] Visual superset: A Few Hours >= Overnight >= Park & Forget on the same view (screens 01-03): P&F strictly less green, A Few Hours == Overnight here (7:30 PM).
- [x] Lever 7 -> 9 AM: Bleecker south-side and Mulberry green segments disappear, nothing new turns green (04-06).
- [x] "Show all sign details": default off (07/08), on gives rich palette and "Pick a parking goal" (09), off restores goal map (verified by AX value and screenshot).
- [x] Drive mode with goal: left chip "No parking" (red) on Bleecker N side matches red map; pill shows "Overnight · Now -> 9:00 AM tomorrow" (17).
- [x] Trip never leaks into drive card/voice: `tripPlan` is only read by the trip overlay branch, banner and `tripVerdict`; `parkUntilTarget`/`parkUntilMode` not written by trip code; goal dock (and Start Driving) hidden while `tripPlan != nil`; `handleDriveModeChange(true)` calls `exitTripPlan` first. Start Driving absent in trip screenshots (12, 15).
- [x] Exit restores live state: screenshot 16 identical to pre-trip goal map (Overnight, 9 AM lever, Start Driving back).
- [x] ASP coverage: `calendarCovers` is year-based (2026 only); uncovered dates produce no suspensions so ASP stays in effect (red); copy "Treating street cleaning as in effect." Code-verified. 2027 date not exercised in the UI (see "Not verified").
- [x] Plan a Trip entry only in More, row only when flag on.

## Findings

### Blocking
None.

### Significant
- **S1 (#183): Goal banner row breaks mid-word at AX5**
  - Where: `GoalWindowRow` (`Views/GoalSelectorView.swift`), screenshot `18-ax5-dock.png`
  - What: at accessibility-extra-extra-extra-large the row does not reflow: "Overnig/ht ·/Now ->/9:00/AM/tomor-/row" over 7 lines with the "Until 9 AM" lever pill squeezed beside it. Nothing is truncated (all text present, lever reachable) but mid-word breaks defeat "obvious which window you're looking at". At default size the window also wraps to two lines ("Now -> 9:00 / AM tomorrow"), nit.
  - Expected: stack vertically (ViewThatFits / dynamicTypeSize >= .accessibility1) so lever sits below the text.
  - Owner: `@ios-engineer`
- **S2 (#184): Trip banner at AX5 truncates "Exit trip plan" and collides with floating buttons**
  - Where: `TripPlanBanner`, screenshot `19-ax5-trip-banner.png`
  - What: banner grows to ~80% of the screen height, the Search and More buttons overlay its top-right and cover the "TRIP PLAN" title/time text, "Exit trip plan" renders as "Exi...", and the ASP top banner truncates to "ASP in Effect To...". Exit is still tappable (verified), but its label is cut.
  - Expected: no truncation of window text or controls; cap banner height or stack buttons at AX sizes.
  - Owner: `@ios-engineer`
- **S3 (#184): Live-only actions and a live banner remain visible during a "not live" trip**
  - Where: curb-tap sheet (`13-trip-curb-free.png`, `14-trip-curb-red.png`) and top ASP banner (`12`, `15`)
  - What: the block sheet still offers "Park here" (a live action) beside "Free for your whole trip", and the yellow "ASP in Effect Today" banner stays on top of a Sat/Sun or Wed plan. Both undercut "unmistakably not live". I did not tap Park here in trip mode (I did not verify what it records).
  - Expected: hide or relabel Park here while planning; suppress or relabel the live ASP banner in trip mode.
  - Owner: `@ios-engineer`

### Minor
- **G1: stale comments**: `DrivingContextService.swift` (~lines 297-299, 704-707) and `ParkingGoals.swift` (~240-243) still reference the deleted `ParkingGoals.ignoresMeteredPayment(for:)` / "overnight family's ignoringMeteredPayment: true". Misleading for the next reader; code is correct.
- **G2: trip branch placement**: the goal recompute block above still runs `resolveParkAndForgetViewport` and writes `parkUntilMode = true` while a trip is active (state is not read by trip UI, but it is wasted work and relies on the trip branch winning later in `rebuildOverlays`). Safe today; fragile if someone reorders.
- **G3: invariant coverage**: meter test is Tue 1 PM only; add a Sat and an evening-after-meter-hours case, and a DST-boundary time (Mar 7 23:00 and Nov 1 00:30 ET) to `sampleTimes`.
- **G4: A Few Hours capped at Overnight end** (builder decision 1) is correct for the invariant, but at 5 AM the dock shows "A Few Hours · Now -> 7:00 AM" (about 2h). Fine; flag for owner awareness.

### Out of scope (logged)
- Default custom plan opens as today 8 PM to midnight; harmless.
- Simulator host time zone equals ET, so a device-in-another-timezone check of the pickers (`.environment(\.timeZone, .easternTime)`) was not possible.

## Smoke tests run (live, ContentView touched)
Launch to map with overlays, toolbar (Search, More), ASP banner, Start Driving, goal dock all rendering (01). Goal switching x3 (01-03). Lever menu + 9 AM + relaunch persistence (04-06). More sheet rows, sign-details toggle on/off (07-09). Plan a trip: planner sheet, quick pick "This weekend" fills fields (10-11), confirm, purple TRIP PLAN banner with "not live", caveat, Edit and Exit (12), curb tap free verdict "Free for your whole trip" (13) and red verdict "Not free: no standing the whole trip" (14), Edit to "Tomorrow" recolors (Lafayette/Broadway-side red, Mott St green) (15), Exit returns to live goal map (16). Start Drive: drive card, End, "Keep WePark in Front" modal, goal pill and chips (17). Curb-pin placement mode opened (Cancel/Next, pin rendered). AX5 (accessibility-XXXL) on dock and trip banner (18-19).

## Not verified (no silent passes)
- Meter-red during paid hours live in each goal: the sim clock was 7:30 PM (meters off). Covered by code review and the unit invariant; the Wed 9-6 trip plan showed Lafayette red but cannot separate meter from ASP. Recommend a daytime smoke.
- Trip validation messages (past arrival, departure before arrival, over 7 days) and the 2027 calendar caveat in the UI: the pickers constrain past/before-arrival ranges, so those messages are only reachable via the >7 day path; validated by reading `TripPlanning.validate` and the unit tests only.
- Drive-mode entry while a trip is active (needs a destination Go path): code-reviewed only.
- Car icon after "Park here"; full placement flow.
- DST nights executed.

## What's working
- One rule really is one rule; deleting the per-goal API (and making metered tolerance not a parameter) is exactly the right way to stop drift.
- Lever anchoring fix (apply hour to default-rule day) is subtle and correct, and test-found.
- The trip plan cannot reach the drive card/voice by construction (separate state, dock replaced, exit on drive entry), and Exit visibly restores the exact prior state.
- The purple TRIP PLAN banner plus "not live" plus caveat plus per-curb "TRIP PLAN · not live" tag is clear at normal text size.
- Flag-off behavior untouched; all new surfaces dark-shipped.

Screenshots: `docs/qa/assets/pr183-184/` (downscaled to 700 px).
