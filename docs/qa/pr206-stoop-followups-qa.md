# PR #206 QA: Stoop My Car + drive follow-ups

**Reviewed:** PR #206 `fix/stoop-mycar-followups` at `b9abc299` (main `ddcc0f10` is already an ancestor, so the "merge" test tree is the PR head itself), against `docs/qa/pr205-stoop-phase4-mycar-qa.md`, `docs/qa/pr203-stoop-drive-ax5-qa.md`, DECISIONS.md and the round-2 mocks (b7, b5).
**Verdict:** MERGE-WITH-FOLLOWUPS (no blocking findings)

## Summary
Small, well-scoped diff (6 source/test files, all flag-on paths). The suspension note can no longer contradict the verdict, the "Leaving soon?" card is back for `.dont`, muted/denied notification copy no longer promises reminders, and the arrival buttons are pinned. Full suite and all 4 schemes pass. Remaining issues are polish: the notification state is read once and goes stale, the SE AX5 arrival prompt still hides the verdict above the fold, and "Park · no meter" drops the window qualifier.

## Acceptance checklist
- [x] Suspension note "You don't have to move the car" only for `.park` / `.meter`. Verified in `WPMyCarLogic.suspensionNote` (`backsNoMove = variant == .park || variant == .meter`). All other variants (dont, soon, nodata, unclear, planpark, plandont) fall to the neutral sentence, so the default is safe for any future variant. Both `todaySuspended` and `tomorrowSuspended` branches are covered. `testSuspensionNote_neverContradictsTheVerdict` loops dont/soon/nodata/unclear for both states and asserts no "have to move". planpark/plandont are not tested but are not reachable from My Car and take the neutral path.
- [x] "Leaving soon?" restored for `.dont`: `showsLeavingSoonCard` now returns `leaveOpensSheet` for every variant; view uses it (line ~390). Test covers all variants. Note the `variant` parameter is unused, so the test cannot catch a future re-introduction inside the view; wiring verified by reading.
- [x] Muted/denied copy: `NotificationAvailability.resolve(muted:status:)` reads `AppConstants.notificationsMutedKey` and the real `UNUserNotificationCenter` authorization status (`.task`). Summary and row sub-line never say "You'll get" when muted or denied; tests assert it. The reminder section's "Reminders are off for this car." path is unchanged.
- [x] Arrival buttons pinned (`WPArrivalPromptV2`: ScrollView + fixed VStack of the two buttons). Screenshots read: Pro Max AX5 and SE AX5 both show "Park here" and "Keep looking" fully visible.
- [~] "Park · no meter": accurate for the selected window (see finding 3), but terse.
- [x] Flag-off unchanged: every edited view is a V2 view (`WPDriveV2.swift`, `WPMyCarV2View.swift`, design-system logic); `WPDriveVerdict.compactLine` is only called from `WPDriveV2.swift:170`. No legacy file touched.
- [x] Builds: WeParkClip, ClipLiveActivities, WeParkLiveActivities BUILD SUCCEEDED. WePark suite: 3093 tests, 1 skipped, 0 failures (`-parallel-testing-enabled NO -jobs 4`, iPhone 17 Pro Max sim, iOS 26.5). No known flake tripped.

## Findings

### Blocking
None.

### Significant
- **#1: SE AX5 arrival prompt hides the verdict behind the pinned bar**
  - Where: `ios/WePark/WePark/Views/WPDriveV2.swift` `WPArrivalPromptV2` (~line 450-495); evidence `docs/qa/assets/stoop-mycar-followups/arrive-ax5-se.png`.
  - What: On SE at AX5 the only thing visible above "Park here" is a clipped "LEFT SIDE" label sliver. The word "Park" / "No parking" text for either side is a scroll away. A driver can tap the yellow "Park here" without having read which side or why. On Pro Max the "Right side: no parking" line is sliced in half under the button, which reads like a rendering glitch.
  - Expected: Pinned buttons must not make the verdict harder to see than the button; "never a contradictory parking statement" is satisfied textually, but the screen no longer shows the statement the button commits to.
  - Repro: DEBUG `-wp3Showcase arrive`, AX5, SE. (I reviewed the builder's screenshots; I did not re-shoot.)
  - Suggestion: at AX5 on short screens shrink the map region (builder already flagged) or let the pinned primary carry the side name ("Park on left"). Follow-up, not a merge blocker, because the buttons are fully visible and the prompt only opens on arrival with a green side offered.
  - Owner: `@ios-engineer`

### Minor
- **#2: Notification state read once, never refreshed**
  - Where: `WPMyCarV2View.swift` `.task { notificationStatus = ... }` and `notificationAvailability`.
  - What: Permission is read only when the view first appears and the in-app mute is read from `UserDefaults` during body evaluation (not observed). If the driver flips notifications on in Settings and comes back, the screen keeps saying "Notifications are off for WePark in Settings" until it is reopened. Until the first read returns, `nil` is treated as "on", so "You'll get N reminders" can flash for one frame on a denied device.
  - Expected: re-read on `scenePhase == .active`; consider treating nil as neutral rather than on.
  - Owner: `@ios-engineer`
- **#3: "Park · no meter" drops the window**
  - Where: `WPDriveLogic.swift:177`.
  - What: A green metered side is green only when `override == .free`, which exists only when a goal window is set, so the line is true for the window. But the text no longer says so; "no meter" can read as "this street has no meter". Old text was accurate and longer; the new one is one line at Pro Max AX5.
  - Suggestion: "Park · meter off" or keep a "in your window" qualifier somewhere visible.
  - Owner: `@ios-engineer`
- **#4: `.dont` + "Leaving soon?" is not in the b7-dont mock**
  - What: The mock shows only the verdict and "Tell me when it's free again" for "Move your car now". Restoring the card follows PR #205 QA finding #5, so this is intentional, but a driver told to move now is also asked "Leaving soon?". Design call for Kevin.
- **#5: AX3 cap still in place** (QA #205 finding #2): comment only, Kevin's decision pending. Logged, no action.

### Out of scope (logged)
- `UIScreen.main.bounds` still used in `WPArrivalPromptV2` for the type-size cap (builder noted).
- My Car with the flag on was not verified live by the builder or by me; muted/denied wording is covered by unit tests only.

## Smoke tests run
- Read full diff of the 6 source/test files plus 3 builder screenshots (Pro Max arrive, SE arrive, Pro Max meter). Pro Max meter shows "Park · no meter" on one line, side cards, and Park here / Report / Voice on all visible.
- Compared against mock b7-dont.
- 4 schemes built, full WePark suite run (3093 / 1 skipped / 0 failed).
- Not run: live My Car with flag on; SE re-shoot.

## What's working
- Neutral-by-default design of `suspensionNote`: new variants cannot reintroduce the contradiction.
- Notification copy states the truth in both off cases and the scheduler was left alone.
- Pinned bar is a small, contained layout change with unchanged button actions and hints.

**MERGE-WITH-FOLLOWUPS**
