# PR #212 Stoop Phase 6a (onboarding + More / Settings) QA, 2026-11-26

**Reviewed:** `feat/stoop-phase6a-onboarding-settings` @ `72efb57c` (base main `d24a997b`), against DECISIONS #8/#9, BRIEF onboarding job, mocks b1-*/b15-*.
**Verdict:** MERGE-WITH-FOLLOWUPS (flag defaults off; no blocking finding)

## Summary
Flag-off paths are the same code as main (every new call site is an `if AppConstants.designSystemV2Enabled` with the legacy branch kept verbatim). Gates, permission timing, reminder storage, mute mapping and dark-shipped delete/suggest gating all hold. Full suite 3149 tests, 0 failures, 1 skip; all 4 schemes build. Flag-on live smoke walked deck, location, 3 coaches, More, Settings, Reminders, Help, About, Colors, and a relaunch (no onboarding repeat). Findings are follow-ups: coach 3 assumes the car token is on screen, mark 2's ring can land on the search row, and one unattributed permission-prompt ordering oddity seen under extreme machine load that needs a re-check at normal load.

## Checklist
- [x] 1 Gating: same `OnboardingStoryGate` / `OnboardingCoachGate` / `LocationPrimingCardGate` call sites (`ContentView.swift` `handleOnboardingStoryCoverDismissed`, `scheduleOnboardingCoach`, `dismissLocationPrimingCard` unchanged). Live: relaunch after the flow showed the map directly, no deck/coach. Mid-coach relaunch matches legacy (story gate written at deck dismissal, coach gate only on finish, coach only scheduled from deck dismissal).
- [x] Permission moments: location only via `dismissLocationPrimingCard(allowed:)` -> `requestAndFetchLocation()` (Allow), Not now/Skip = no side effects; no new notification ask (B1.5 deliberately omitted; Settings Notifications row reads status only, shows "Not asked yet" on fresh install). See finding #3 for the one oddity.
- [x] Coach sequencing/real-control: mark 1 advances on goal-tile tap only (`v2DismissedByGoalTileTap`); mark 2 curb tap -> mark 3; drag start finishes (`onChange(of: v2ParkFlow.phase)`, inert flag-off). Coach 1 copy "Overnight means from now until the morning." matches BRIEF; live ring on tile row confirmed. AX fallback "Tap a green curb, then Park here" present (code + AX title).
- [x] 2 Story honesty: "EXAMPLE" label on the sample time (live shot), no sample time presented as real, "For days / several days" (not "a week"), overnight chip "until morning". Preselected Overnight matches the app default goal (`selectedGoal = .freeOvernight`).
- [x] 3 Settings: Reminders use `ReminderOffsets` (`WPSettingsV2` `.onChange(of: offsets)` saves + `onOffsetsChange` reschedules, identical to legacy `SettingsView`); "Park reminders" = inverse of `notificationsMuted`, `onUnmute` same as legacy; Voice = `DrivingVoice.isMuted`; Notifications row = `UNUserNotificationCenter` status. Delete / Suggest: `sections(...)` fed by `accountDeletionRowVisible()` / `coverageSuggestionVisible()` (both `static let ... = false`), and the Stoop bodies sit inside views only constructed from those rows. "Show all sign details" row still calls the existing toggle (`signDetailsOn.toggle()` + `rebuildOverlays`). Colors legend: 5 line styles + 4 pins only (the 3 undrawn pins dropped).
- [x] 4 `WPGoalSheetV2.onTileRowFrame`: optional, default nil, `onGeometryChange` just forwards; inert when unused.
- [x] 5 Flag-off identical: diff reviewed hunk by hunk. The shared edits (`setOnboardingCoachMark`, geometry `mark != .goalTiles`, `onboardingCoachAnchorPoint`) reduce to the old behavior flag-off (anchor only for `.tapABlock`); the new `onChange` is guarded by `phase != .idle`.
- [x] 6 `-wp6aShowcase`: file wrapped `#if DEBUG ... #endif` (lines 17/104), ContentView call site inside the existing `#if DEBUG` block, `developerRow` DEBUG-only. Release binary check: see Smoke tests.
- [x] 7 Fresh-install flag-on smoke done (below). AX5 settings/more title bars re-shot: Close pill drops under the title, nothing truncated.
- [x] 8 Dark: confirmed low contrast on this branch ("Keep my account" pill vanishes into the card, dark-delete shot). #210 (`origin/fix/stoop-polish-2`) covers both: `InkPillButtonStyle.Palette.resolve(dark:)` (lifted fill + line + cream label; `labelColor` ignored in dark) used by `Keep my account`, and `WPCoachNextStyle` now uses the same palette. Read from the diff; #210 not built by me.

## Findings

### Blocking
None.

### Significant
- **#1: Coach mark 3 says "Drag the car to park" whenever the token is hidden for any reason other than AX size**
  - Where: `WPPhase6aLogic.swift` `OnboardingCoachMark.v2Title/v2Message(accessibilityLayout:)`; `ContentView.swift` `onboardingCoachAnchorPoint` (`guard v2ShowsRestingToken else { return nil }`).
  - What: the anchor correctly goes nil when `v2ShowsRestingToken` is false, but the words switch to the "Tap a green curb, then Park here" fallback only for accessibility sizes. `v2ShowsRestingToken` is also false outside coverage (`v2OutsideCoverage`), with a parked car, trip plan, any sheet, etc. Live: in my flag-on run the car token was not drawn at all (AX tree and screenshots, also after the coach ended, so not caused by the coach), and coach 3 read "Drag the car to park" with no ring and nothing to drag. The builder's own screenshot at Apple Park did show the token, so I could not establish why it was absent for me (location authorized, Times Square fix); unverified root cause.
  - Expected: copy follows what is actually on screen.
  - Repro: fresh install, flags on, allow location, step to coach 3.
  - Owner: `@ios-engineer`. Fix: pass `v2ShowsRestingToken` (not just AX size) into the copy choice.

### Minor
- **#2: Mark 2 ring can sit on the search row.** Live shot: ring centered on the user-dot/nearest-curb projection landed over the "Search an address" field, pointing at nothing tappable (builder also notes card touching the search row). `WPCoachOverlayV2.ring` / `onboardingNearestCurbScreenPoint`. Consider hiding the ring when the anchor falls inside the toolbar/sheet frames.
- **#3: Unattributed permission-prompt ordering (needs re-check at normal load).** On 2 of 3 fresh-install launches (machine load avg 300-500, so timing is suspect) the V2 full-screen location screen was visible with the iOS location prompt already up, before any deck and without tapping Allow; after dismissing it the deck appeared. The third launch showed the deck first with no prompt. Nothing in the PR calls the location request except Allow, and legacy had the same underlying timing but its small floating card was hidden behind the cover. Not verified whether this reproduces flag-off or at normal load; recommend one fresh-install re-run at low load before any build ships. Owner `@ios-engineer` to confirm.
- **#4: Story copy edges toward precision.** "WePark reads the parking signs on every curb" and "Tap any curb to see ... which sign says so" overclaim given no-data curbs (they draw as don't). Suggest "the curbs we have sign data for" style wording or drop "every". `WPPhase6aLogic.swift` `v2Sub`.
- **#5: Notifications status is read once** (`.task` on Settings appear); returning from iOS Settings leaves a stale value until reopening. `WPSettingsV2.refreshNotificationStatus`.
- **#6:** "Night-before time 8:00 PM" row stays visible when "Also the night before" is off (dimmed only when muted). Suggest hiding or dimming with the toggle.
- **#7:** "We cover Manhattan today" is hardcoded in the dark-shipped Suggest sheet (`SuggestNeighborhoodSheet.swift` ~191); will go stale when coverage grows.

### Out of scope (logged)
- Onboarding, the location screen and the More "How WePark works" replay are still gated by dark-shipped `onboardingStoryEnabled` and `driveModeDefaultEnabled`; a Stoop-on build must flip those too (I flipped both locally to smoke; reverted).
- Known flakes did not appear this run.

## Smoke tests run
- `build-for-testing` + full WePark suite `-parallel-testing-enabled NO -jobs 4`: **3149 tests, 1 skipped, 0 failures** (29 `StoopPhase6aTests` lines passed). Machine load was extreme (1-min 90-500, Spotlight indexing / other jobs); I waited below 40 before the first heavy step, then load rose during the run.
- Builds: WePark (test build), WeParkClip, ClipLiveActivities, WeParkLiveActivities: all BUILD SUCCEEDED (Debug, sim 16 Pro iOS 26.5, own derivedData). Release build of WePark and `strings | grep -c wp6aShowcase`: Release build SUCCEEDED, `strings WePark | grep -c wp6aShowcase` = 0 (absent).
- Live flag-on (StoopFlag + onboardingStoryEnabled + driveModeDefaultEnabled flipped locally, reverted; `git status` clean): deck 1/2/3 (read screenshots: "Example" label, Overnight preselected, "several days"), location screen -> Allow -> iOS prompt -> coach 1 (ring on tile row, correct copy), coach 2, coach 3, Got it, relaunch (no repeat), More (B15.1 list, toggle row), Settings (Reminders "1 hour before", Voice toggle, Notifications "Not asked yet", Help, About), Reminders (15 min chip toggles, master switch, night-before toggle), Help list, About + version, What the colors mean. "Don't Allow" path showed the legacy-style "Location is off" card.
- Showcase shots: AX5 Settings and More (title bar OK), dark Delete (Keep my account low contrast).
- Not exercised live: Suggest/Delete flows (flags off, only via showcase), curb-tap advance of mark 2 (no tappable curb under ring), Allow/Not now on flag-off build.

## What's working
- Clean additive structure: legacy bodies kept verbatim behind the flag, pure logic in `WPPhase6aLogic.swift` (`nonisolated`) with 27 targeted tests including gate tests.
- Honest copy decisions: no extra notification ask, "Example" label, "several days", real consequences in the delete confirm, pins list trimmed to what the map draws.
- Reminder set matches DECISIONS #8 and keeps legacy persistence/reschedule semantics; master switch preserves the existing mute.

**MERGE-WITH-FOLLOWUPS** (fix #1 before any flag-on build goes to testers; re-check #3 at normal load).
