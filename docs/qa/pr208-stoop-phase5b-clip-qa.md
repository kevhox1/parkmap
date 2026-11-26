# PR #208 QA: Stoop Phase 5b App Clip screens (B11) + one reminder

**Reviewed:** branch `feat/stoop-phase5b-clip` at `43bae6d1` (base `ddcc0f10`, so it is behind main `3fb6130c`; reviewed with three-dot diffs), against DECISIONS #7, `docs/design-kit/BRIEF.md`, mocks b11-*. Also tested merged with #209 on a throwaway local branch (clean merge, no conflicts).
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
Foundation move is byte-identical, flag is false everywhere, all 4 schemes build and the full WePark suite is green on the #208+#209 merge (3121 tests, 0 failures, 1 skipped). The clip never prompts, plans exactly one reminder under Stoop and the shipping two with the flag off. One 🟡: the copy "That's the only notification you'll get." is not true in every path (backend thanks alert, and "5 more min" after the reminder has fired).

## Checklist
- [x] Moved files byte-identical: blob SHAs equal (WPTokens 64ef88d4, WPTypography 370f3049, WPButtons a6538ff2), `git diff -M` shows 100% renames. pbxproj untouched (synchronized folders), all 4 targets compile `Shared/`.
- [x] Flag defaults false: `StoopFlag.designSystemV2Enabled = false`; `AppConstants.designSystemV2Enabled = StoopFlag.designSystemV2Enabled` has no literal of its own (`Constants.swift:385`).
- [x] No `requestAuthorization` reachable in the clip: only hit is `ClipDebugSupport.swift:204`, inside `#if DEBUG` (lines 21-212), unchanged from main. Release clip binary: 0 occurrences of the string.
- [x] `NSAppClipRequestEphemeralUserNotification` = true in `Support/Clip-Info.plist:14`.
- [x] B11.3 informational; shown only when `shouldOfferReminder()` (availability == .on) and choice is not Now (`ClipRootViewV2.swift` `tell()`). Skip calls `chooseReminder(false)` then `arm()`; `scheduleReminders` guards `!reminderSkipped` (`ClipFlowController.swift:348`). Nothing is scheduled.
- [x] `HandoffReminderPlan.plan(stoop:)`: true gives `makeSingle` (1 reminder, 2 min before leave_at, none for Now / past expiry), false gives untouched `make` (2). Tests pin both.
- [x] `HandoffReminders.swift` diff vs main is additions only (+31, no deletions).
- [x] Clip networking, QR, deep links: no diff in those files. `ClipRootView` only adds a flag branch; flag-off renders the old body.
- [x] Clip size: Release iphoneos unsigned (merged tree), `WeParkClip.app` zipped = 1,083,575 bytes (about 1,058 KB), matches builder's ~1,054 KB; limit is 15 MB. Includes the embedded ClipLiveActivities appex.
- [ ] "Only notification" claim true in every path: see #1.

## Findings

### Significant
- **#1: "That's the only notification you'll get." is false in two paths**
  - Where: `WPClipCopy.swift` `reminderOnly`; `ClipFlowController.swift:439` (`extendFiveMinutes` calls `scheduleReminders`); `supabase/functions/_shared/handoff_push.ts:75-85` (`driverThanksAlertBody`, "Thanks, neighbor!" visible alert with `target-content-id` for clips).
  - What: (a) when the seeker thanks the driver, the backend sends the clip driver a visible alert. (b) If the reminder already fired and the driver taps "5 more min", `extendFiveMinutes` schedules a fresh single reminder at about now+3 min, and again per extension (max extensions).
  - Expected: the copy the user reads on B11.3 is a promise; either every path honours it or the copy changes.
  - Repro (b): arm for 10 min, wait for "Still leaving around ...?", tap "5 more min" in the notification; a second reminder is scheduled. Reasoned from code, not run live.
  - Owner: `@ios-engineer` (skip re-scheduling after the reminder has fired, or soften copy), `@backend-data` (thanks alert for clip drivers; also retire the "!" to match round 2).

### Minor
- **#2:** Primary button reads "Allow one reminder" but nothing is requested (it is an info step). Fine functionally, mildly misleading; consider "Remind me" / "Got it". `WPClipCopy.allowReminder`.
- **#3:** B11.6 block rules intentionally not matched (DECISIONS: needs backend); existing block card restyled only.

### Out of scope
- Backend pushes were not changed (not expected for this PR).

## Smoke tests run
- Built all 4 schemes (Debug, simulator) on the merged tree: all BUILD SUCCEEDED.
- Full `WePark` suite on merged tree, `-parallel-testing-enabled NO -jobs 4`: 3121 executed, 1 skipped, 0 failures, no flakes hit. Not run on #208 alone (load); it is a strict subset of the merged tree.
- Release iphoneos unsigned build of WeParkClip: succeeded; strings check for `wp5bClip` and `requestAuthorization` in the clip binary: 0 / 0.
- Read screenshots `flag-on-clip-1-intro.png`, `-3-next.png`, `flag-off-clip-smoke.png`: Stoop screens render with Fredoka, privacy line "They won't see who you are or where you are" present; flag-off shows the shipping dark clip.
- Not verified: live clip run on device (ephemeral notification status only exists via a real App Clip card launch); Release build of the full app (DEBUG showcase file and ContentView call are `#if DEBUG`-wrapped by inspection).

## What's working
Clean separation: one flag branch at the root, same `ClipFlowController` phases, "Now" path skips the reminder step, Skip arms without scheduling, plan logic is pure and well tested, and the size cost is only about 170 KB.

## Flag to flip for a Stoop-on build
`ios/WePark/Shared/Stoop/StoopFlag.swift:19`: `static let designSystemV2Enabled = false` to `true`. `Constants.swift:385` forwards and needs no edit; no script or doc references the old literal.

**MERGE-WITH-FOLLOWUPS**
