# PR #207 QA: Stoop Phase 5a Spot Pass in-app restyle (B9 seeker, B10 driver)

**Reviewed:** PR #207 `feat/stoop-phase5a-spotpass` at `be2222b5` (main `ddcc0f10` is already an ancestor; the throwaway `qa207-merge` branch was identical to the PR head), against DECISIONS.md, `docs/design-kit/BRIEF.md`, mocks b9-*/b10-*.
**Verdict:** MERGE-WITH-FOLLOWUPS (no blocking findings)

## Summary
This is a genuine restyle. `git diff origin/main...HEAD` touches only 9 non-asset files, all under `ios/WePark/WePark/` plus one test file; `ios/WePark/Shared/`, `WeParkClip`, `ClipLiveActivities` and `WeParkLiveActivities` have zero changes. All Spot Pass networking, `DriverFlowController`, `SpotPassStore`, QR payloads and Live Activity code are reached through the same calls as before; flag-off takes the untouched legacy branches. The leave-time picker is correct and sends exactly what it shows. The follow-ups are all AX5 layout: on a short phone the huge-type pinned action bar eats about 45% of the screen, and the time chips break "4:15 A / M".

## Acceptance checklist
- [x] No networking / Supabase / QR / Live Activity / `Shared/` / `Clip/` changes: verified by `git diff --stat` on those paths (empty) and by reading the full diff. The Stoop wrappers (`WPDriverChoosingStoop` etc.) call only existing controller methods: `select`, `arm`, `notLeavingSoon`, `report`, `showPullingOut`, `requestCancel`, `backToArmed`, `pullOut`, `extendFiveMinutes`, `turnOffAutoDetect`, `dismissCelebration`, `tick`. The 20 s tick `.task` is replicated in the armed wrapper.
- [x] Legacy branches moved verbatim: `legacyContent` in `DriverFlowView` / `SpotPassFlowView` and `legacyBody` in `SpotPassBadgeView` show as unchanged diff context. In the badge, the lifecycle modifiers (`onAppear`, `onChange`, `onDisappear`, `.task`) were hoisted onto a wrapping `Group`, so both looks share them (verified by reading; behavior-neutral). `.spotPassBackdrop()` stays on the legacy body only.
- [x] Flag-off identical: every new branch is gated on `AppConstants.designSystemV2Enabled`. No live Spot Pass flag-off run was possible (the flow needs a live session), see finding 6 and "Out of scope".
- [x] Leave-time picker. Chips: "Now / About 10 min / About 30 min / About 1 hour / Pick a time" (`WPPassCopy.chipTitle`, tilde-free, VoiceOver labels "Leaving in about 10 minutes"). Slots: first quarter hour strictly after now, every 15 min, `min(now+240 min, LeaveChoice.latest(from:))`, max 16 (`WPPassLogic.leaveSlots`). Displayed == sent: payload is `choice.leaveAt(from: startedAt)` in `DriverFlowController.arm()` (unchanged, `DriverFlowController.swift:323`); a slot is a multiple of 900 s so `roundToFiveMinutes` is the identity and the ceiling is never hit (4 h slot <= `latest`). Test `testLeaveSlots_timeShownIsTimeSent` asserts this. Edge, see finding 5b.
- [x] Auto heads-up: off by default (`.canEnable/.needsSavedCar/.locationDenied` map to off); ON maps to `.openPurpose` (the Binding getter never flips, the purpose sheet `AutoDetectPurposeView` is the same one the legacy row used, and it handles saveCarFirst / openSettings itself); OFF calls `turnOffAutoDetect()`. Opted-in carry-over note preserved. Tests cover all.
- [x] Privacy copy intact: "They won't see who you are or where you are." / "They see a nickname and a code. Nothing else." on the seeker intro; "They won't see who you are." on the driver choose screen; first name stays opt-in OFF by default and disabled with helper text when none is on file. Nothing new reads or displays identity or location; the badge shows alias + glyph only.
- [x] `-wp5aShowcase` is `#if DEBUG` in `WPPhase5aShowcase.swift` (whole file, lines 17-141) and its one `ContentView.swift` hook sits inside the existing `#if DEBUG` block (3239-3255). Release build result below.
- [x] Builds: WeParkClip, ClipLiveActivities, WeParkLiveActivities BUILD SUCCEEDED. WePark suite: 3101 tests, 1 skipped, 0 failures (`-parallel-testing-enabled NO -jobs 4`; 3089 baseline + 12 new in `StoopPhase5aSpotPassTests`). No known flake tripped.

## Judging the builder's deviations
- Kept the existing first-name toggle (mock b9-intro has none): **agree.** It is existing behavior and a privacy control; removing it would be a behavior change in a restyle PR.
- "Leaving around/now" cards ink-outlined, not green (mock b9-headsup is green): **agree, and good call.** Green means "you can park"; this card only says a neighbor is leaving, and the sibling note says "Check the signs before you park". Matches the "never show a spot that isn't a spot" rule.
- Kept existing driver CTA wording ("Tell Bodega Cat when I leave" vs the mock's "Tell Bodega Cat"; "Got it, thanks!" vs "Say thanks"): **agree.** Clearer than the mock, and the semantics (outcome confirm calls) are unchanged. The auto switch is green when ON as in mock b10-auto, so that is not a deviation.

## AX5 on short phones: pinned large action bar, rated
I re-shot on my own iPhone SE (3rd gen) sim at AX5 (`-wp5aShowcase intro|qr|driver-armed|pull|pick`, light). Rating: **functional but cramped; follow-up, not a blocker.** Nothing is unreachable and the primary actions are never clipped, which is the right trade. But on SE the bar (primary wraps to 2 lines + secondary 2 lines) takes about 40-45% of the height and:
- Seeker intro: only the title and subtitle are visible; the privacy promise and the 3 steps are below the fold, so "Make a pass" can be tapped without ever seeing "They won't see who you are". For the key onboarding funnel that matters.
- Driver armed: the lock-screen note and the auto switch are below the fold.
- Pull: "5 more min" is cut in half by the bar and the "don't use your phone while driving" line is hidden.
- QR screen is fine: the whole QR is visible above "Stop waiting".

## Findings

### Blocking
None.

### Significant
- **#1: Pick-a-time chips break "4:15 A / M" at AX5, and the sheet shows barely 1.5 rows on SE**
  - Where: `WPSpotPassDriverV2.swift` `WPLeaveTimeSheetV2` (2-column grid at accessibility sizes, `WPChoiceChip` height 56) ; evidence `docs/qa/assets/stoop-phase5a/pick-light-ax5.png` (the builder's own frame shows it) and my SE shot.
  - What: the time text wraps between "A" and "M", which reads as broken; at AX5 on SE the grid is cut under a huge "Use 4:45 AM" button.
  - Expected: one slot per row (single column) at accessibility sizes, or `lineLimit(1)` + `minimumScaleFactor`.
  - Owner: `@ios-engineer`
- **#2: Seeker intro: privacy promise is below the fold at AX5 on short phones**
  - Where: `WPSeekerIntroV2` via `WPScreenScaffold` pinned bar; see rating above.
  - Expected: BRIEF says the privacy line is the funnel. At AX5/short, move the privacy note above the steps or stop pinning the bar when it would take more than about 35% of the height (cap pinned button type at AX2 as the drive screens do).
  - Owner: `@ios-engineer`

### Minor
- **#3: Dark mode: navigation-kind primary button disappears.** `docs/qa/assets/stoop-phase5a/done-dark.png` and `pick-dark.png`: "Done" / "Use 4:15 AM" are ink pills on an ink-dark ground, so only the text shows (still legible, target still 48 pt). Design-system level (`WPPrimaryKind.navigation` in dark), not specific to this PR.
- **#4: Departed card repeats itself.** `departed-light.png`: "Your neighbor is / Leaving now / Your neighbor is pulling out now." (`WPPassCopy.departedOver` + `SpotPassCopy.departedSubtitle`). Trim one.
- **#5: Pull screen header says "Leaving now" over a "Leaving in 4:07" countdown** (`pull-light.png`). The title is true only after the tap; mildly contradictory. Legacy had the same pre-tap framing, so low priority.
- **#5b: Stale slot.** Slots are computed when the sheet opens. If the driver dawdles past a chosen slot, `leaveAt(from:)` clamps to now, so the chip can show "4:15" while 4:17 is sent. Same server-safe clamp as legacy; inherent to the picker, only visible after a long delay.
- **#6: Evidence gaps in `docs/qa/assets/stoop-phase5a/`.** I viewed all 37 PNGs (36 + `flag-off-smoke.png`). `flag-off-smoke.png` is the wrong state: it shows the map with the iOS location-permission alert, not a Spot Pass screen, so it proves nothing about flag-off Spot Pass. `choose-custom-light.png` shows a chip of "4:17 AM", which is not a 15-minute slot (showcase fixture date; not reachable in the real picker). No frames on SE and no VoiceOver evidence.
- No other wrong-state or broken frames. Frames matching their names: intro (light/dark/AX5/name), choose (light/dark/AX5/custom), pick, armed and driver-armed (light/dark/AX5/auto), pull, sent, qr, departed, done, done-pending, settled, nolack, ended, paused, failed, offline.

### Out of scope (logged)
- Armed plate is a fixed 328 pt (`WPSeekerBadgeV2.plate`, same as legacy `SpotPassBadgeView.swift:252`); inside the new card padding and margins this is wider than an SE column. On my SE QR shot the open (QR) state fits; the armed glyph plate was not shot on SE.
- Real Spot Pass flow with the flag on (create, scan, arm, pull out) was not driven live; only the DEBUG showcase and unit tests.

## Smoke tests run
- Diffs on `Shared/`, `WeParkClip`, `ClipLiveActivities`, `WeParkLiveActivities`: empty.
- 4 schemes built; WePark suite 3101 / 1 skipped / 0 failures.
- All 37 builder screenshots viewed (contact sheets) against mocks b9-intro, b9-headsup, b9-qr, b10-armed, b10-auto, b10-scanned.
- Own SE (3rd gen) sim, AX5, light: intro, qr, driver-armed, pull, pick via `-wp5aShowcase`.
- Release build of the WePark scheme (generic iOS Simulator) and `strings` for `wp5aShowcase`: see below.

Release build (generic iOS Simulator) succeeded. `strings` on the Release `WePark` binary: `wp5aShowcase` count 0, while `WPSeekerIntroV2` (this PR's code) count 2, so the binary is from this PR and the showcase is compiled out. The Debug dylib contains `wp5aShowcase` (count 2).

## What's working
- Clean separation: leaf `WPSeeker*V2` / `WPDriver*V2` views take plain values and closures; wrappers add no behavior. This is what made the "restyle only" claim easy to verify.
- Pure `WPPassLogic` with 12 tests; picker bound to the server's own `LeaveChoice.latest`.
- Privacy copy kept word for word; green withheld from "leaving" cards.
- Showcase correctly DEBUG-only.

**MERGE-WITH-FOLLOWUPS**
