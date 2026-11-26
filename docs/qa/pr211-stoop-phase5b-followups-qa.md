# PR #211 Stoop Phase 5b follow-ups QA, 2026-11-26

**Reviewed:** `fix/stoop-phase5b-followups` at `e4fe4061`, against `docs/qa/pr208-stoop-phase5b-clip-qa.md` and `docs/qa/pr209-stoop-phase5b-liveactivity-qa.md`
**Verdict:** MERGE-WITH-FOLLOWUPS (no blockers)

## Summary
The four fixes are correct and contained: clip copy now matches the reminder plan, "Walk there" wins over the address category under Stoop, the counting island lays out side by side, and the DEBUG-only real-activity launcher is compiled out of Release. Backend untouched (no `supabase/` in the diff). On a throwaway merge of origin/main + #210 + #211: all 4 schemes build, full WePark suite 3135 tests, 1 skipped, 0 failures (`-parallel-testing-enabled NO -jobs 4`). I did not run the suite on #211 alone (load). One likely related defect remains in the time-to-go island layout (finding 1).

## Checklist
- [x] Clip copy true on every path: `WPClipCopy.reminderOnly` discloses one reminder, the user-requested "5 more min" reminder, and the neighbor thank-you. Cross-checked with code: `HandoffReminderPlan.makeSingle` yields exactly one reminder; `ClipFlowController.extendFiveMinutes` calls `scheduleReminders`, which goes through `plan(stoop:)` and `UNHandoffReminderScheduler.schedule`, which first calls `cancelAll(passID:)` and re-adds under the same `leaveIdentifier`, so no duplicate pending reminders (also pinned by a test). The thank-you alert is backend behavior, left untouched, and is only sent when a push token exists (reminders on), so the copy shown on the reminders-on screen is accurate. Button now "Remind me once" (no system prompt exists in the clip). VoiceOver hint on "5 more min" discloses the re-remind.
- [x] Backend untouched: confirmed by diff.
- [x] "Walk there" precedence: new pure `NotificationScheduler.categoryIdentifier(stoop:hasVerifiedAddress:)`; Stoop returns `wepark_park_reminder_v2` (has `figure.walk` action, `hiddenPreviewsBodyPlaceholder = "Parking reminder"`), so the verified address (appended to the body) is still hidden when previews are hidden. Category is registered when the flag is on (`NotificationCategoryRegistry` `stoopParkReminders`), and coordinates ride in `userInfo` under Stoop. Flag off: address category still set exactly as before (tests cover both).
- [x] Island / lock screen height: builder's real-system island screenshot (reviewed, `docs/qa/assets/stoop-phase5b/activity-island-dark.png`) shows header, "Leaving now" pill and "Not leaving" together. Claimed ~152 pt island and ~128 pt lock screen, inside 84-160. I could not reproduce live: on my fresh simulator `-wp5bActivity real` did not surface an activity (the app launched slowly under load 100-200 and no island appeared), so the height numbers are the builder's, not independently measured.
- [x] Wiring: "Leaving now" (`wrap(.leavingNow, ...)`) and "Not leaving" (`wrap(.notLeaving, ...)`) still go through the same wrappers (unchanged); pill 52 pt, link `minHeight: 44, minWidth: 96`, both at least 44 pt.
- [x] `-wp5bActivity real`: `WPPhase5bActivityShowcase.swift` is wrapped in `#if DEBUG ... #endif` (including the `ActivityKit` import and `startRealActivity`), and its only call site in `ContentView` is inside `#if DEBUG`. Absent from Release by construction (no Release binary inspected).
- [x] Flag-off identical to main: all changes are Stoop copy, flag-gated views, or `categoryIdentifier(stoop:false)` which returns the previous values. Clip copy lives in `Shared/Stoop` and is Stoop-only. Suite passes flag-off.

## Findings

### Blocking
None.

### Significant
- **#1 (significant) `ios/WePark/Shared/Stoop/WPActivityViews.swift` (`wpDynamicIsland`, `.bottom` region, `layout == .timeToGo` branch):** this branch still stacks a 52 pt "Leaving now" pill over a row of two 44 pt pills (6 pt gap, about 102 pt) inside the expanded island. The PR's own measurement says the counting stack of 52 + 44 (96 pt) was already clipped and dropped "Not leaving"; the time-to-go stack is taller. Likely "5 more min" / "Not leaving" clip in the time-to-go expanded island (the phase where the driver most needs them). Not verified live (no island on my sim), so confirm with `-wp5bActivity real` plus a time-to-go state before ship. Owner `@ios-engineer`.

### Minor
- **#2 (minor) copy length:** `reminderOnly` is now three sentences in 15 pt muted on the clip reminder screen; confirm it still sits above the pinned buttons at AX sizes (not checked; clip showcase not run by me).
- **#3 (minor, backend, logged):** the backend's "Thanks, neighbor!" keeps the exclamation mark the client retired (builder already noted this for `@backend-data`).
- **#4 (minor) not verified:** island height measurements; Release binary string absence.

## Smoke tests run
- Build: WePark (build-for-testing), WeParkClip, ClipLiveActivities, WeParkLiveActivities all succeeded on the combined merge.
- Full suite on combined merge: 3135 executed, 1 skipped, 0 failures.
- Code review of clip flow controller, reminder scheduler, notification category registry, scheduler category selection.
- Flag-on app launched on iPhone 17 Pro Max sim with `-wp5bActivity real`: no activity rendered (see above); inconclusive.

## What's working
Copy and plan are now in agreement and test-pinned; the snooze reuses the same identifier; the category fix keeps the address off the lock screen; the DEBUG launcher is properly fenced.

**MERGE-WITH-FOLLOWUPS** (finding 1 should be checked live; it only affects the flag-on time-to-go island).
