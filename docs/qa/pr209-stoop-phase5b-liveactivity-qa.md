# PR #209 QA: Stoop Phase 5b Live Activity / Dynamic Island (B12) + notification copy (B13)

**Reviewed:** branch `feat/stoop-phase5b-liveactivity` at `863e5c54` (base `ddcc0f10`, behind main `3fb6130c`; reviewed with three-dot diffs), against DECISIONS, `docs/design-kit/BRIEF.md`, mocks b12-*/b13-*. Also tested merged with #208 on a throwaway local branch (clean merge).
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
Locked-phone "Leaving now" is still a real `Button(intent: LeavingNowIntent)` in the full-app extension, and the clip extension keeps its deep-link path. "Not leaving" is back as a quiet 44 pt link on counting-down surfaces. Attributes/ContentState are untouched, backend push copy is untouched, flag-off is the shipping code. All 4 schemes build and the full suite is green on the merge (3121 tests, 0 failures, 1 skipped). Follow-ups: Walk there is dropped when address-anchored parking is on, and expanded-island height is unverified.

## Checklist
- [x] Foundation: same as #208 (byte-identical blobs, flag false, `Constants.swift:385` forwards, no literal). See `pr208-...-qa.md`.
- [x] "Leaving now" locked phone: `WeParkLiveActivitiesBundle.swift` `WPIntentWrapper` uses `Button(intent: LeavingNowIntent(passID:))` (also FiveMore/NotLeaving intents), for lock screen and island. Clip ext: `WPClipLinkWrapper` maps leavingNow to `.openPullingOut` (counting) or `.leavingNow(.liveActivity)` (time to go), fiveMore to `.extend`, notLeaving to `.confirmCancel`: same destinations as the shipping clip buttons.
- [x] "Not leaving" restored: `WPActivityQuietLink` 14 pt text, `minHeight: 44, minWidth: 96`, wired in counting lock screen and expanded island; time-to-go keeps a full pill (44 in island).
- [x] Content state / attributes unchanged: no diff under `Shared/SpotPass`; push `content-state {phase}` contract unaffected. New views read only existing fields.
- [x] Notification category `wepark_park_reminder_v2` registered only when `designSystemV2Enabled` (`NotificationCategoryRegistry.launchCategories`, merge-safe `register`); launch gate in `WeParkApp.swift:105` adds the flag with `||`, flag off unchanged. Scheduling times/presets unchanged (only title/body/category/userInfo set).
- [x] "Walk there": `WeParkApp.swift` handler opens `https://maps.apple.com/?daddr=<lat>,<lon>&dirflg=w` with the car's `latitude/longitude` from `userInfo`, range-checked; tested.
- [x] `supabase/functions/_shared/handoff_push.ts` not in the diff.
- [x] DEBUG showcase `-wp5bActivity`: file wrapped in `#if DEBUG` (lines 16-117), ContentView call inside the existing `#if DEBUG` Group. Not confirmed in a Release app binary (see smoke).
- [x] Flag-off: every Stoop branch is `if StoopFlag/AppConstants.designSystemV2Enabled`; else-branches are the original views verbatim.

## Findings

### Significant
- **#1: "Walk there" lost when address-anchored parking is on**
  - Where: `NotificationScheduler.swift` `buildContent`: Stoop sets `categoryIdentifier = wepark_park_reminder_v2`, then the `addressAnchoredParkingEnabled` block overwrites it with `addressCategoryID`.
  - What: with both flags on and a verified address, the reminder shows Stoop copy but no Walk there action.
  - Expected: B13 action present. Both flags can be on in a tester build (`addressAnchoredParkingEnabled` is false in code today).
  - Owner: `@ios-engineer` (give the address variant the walk action, or build one category set).
- **#2: Expanded island height unverified**
  - Where: `wpDynamicIsland` bottom region, counting: 52 pt pill + 44 pt link stacked.
  - What: `activity-island-*.png` predates the "Not leaving" link, so the final layout was never captured; expanded island has a tight height budget and the new stack may clip or push the pill. Not verified; recommend a device/sim look before the Stoop-on build.
  - Owner: `@ios-engineer`.

### Minor
- **#3:** `activity-counting-*` and `activity-island-*` screenshots are stale (pre-link), as noted; refresh when #2 is checked.
- **#4:** `.dark` pills use the same Capsule for 5 more/Not leaving at 56 pt; fine, just heavy next to the quiet link elsewhere. Design call.
- **#5:** Backend thanks push still says "Thanks, neighbor!" (exclamation, retired in round 2) while the activity says "Thanks, neighbor." Out of scope here; pairs with #208 #1.

## Smoke tests run
- 4 schemes built (Debug sim) on the merged tree: all BUILD SUCCEEDED (ClipLiveActivities and WeParkLiveActivities compile `Shared/Stoop`).
- Full WePark suite on merged tree, `-parallel-testing-enabled NO -jobs 4`: 3121 executed, 1 skipped, 0 failures. Not run on #209 alone (load); subset of merged tree.
- Release clip build compiled the shared Stoop files and embedded ClipLiveActivities appex.
- Read screenshots `activity-timetogo-dark.png` (Still leaving?, taxi Leaving now, two dark secondaries, black surface) and `activity-island-dark.png` (compact, minimal, expanded; no Not leaving link, as flagged).
- Not verified: tapping the intent from a real locked device, Live Activity push updates on device, Release build of the full app (no `wp5bActivity` string check), live "Walk there" tap.

## What's working
Buttons injected via a wrapper, so the same Stoop views serve intents in the app extension and links in the clip; the `layout(phase:isStale:)` mapping is pure and tested; copy is notification-voice compliant; flag-off path untouched.

## Flag to flip for a Stoop-on build
`ios/WePark/Shared/Stoop/StoopFlag.swift:19`: `static let designSystemV2Enabled = false` to `true`. `AppConstants.designSystemV2Enabled` (`Constants.swift:385`) forwards; no literal remains there.

**MERGE-WITH-FOLLOWUPS**
