# PR #172 QA: App Clip finished-pass lifecycle, armed pinning, LA-off copy, cancel sheet

**Reviewed:** `fix/spot-pass-clip-lifecycle` (CI green), Debug `WePark` build (unsigned, `CODE_SIGNING_ALLOWED=NO`), iPhone 17 sim iOS 26.5 + temp iPhone SE 3rd gen. Release `WeParkClip` built for size/`strings`. No `xcodebuild test`.
**Date:** 2026-11-24
**Verdict: MERGE-WITH-FOLLOWUPS.** The red finding (#1 in the PR #171 report) is fixed and live-verified in every variant asked for. Armed pinning, cancel sheet and Done copy work. One premise in the PR is wrong for this sim (it does not report Live Activities "off"), so the Settings link and the install-card line-omission could not be exercised live; a small copy inconsistency follows from it.

## Checklist

| # | Check | Result |
|---|---|---|
| 1a | Complete pass, Done, relaunch with DIFFERENT token (`B...`) | PASS: choosing screen "Bodega Cat is waiting for your spot." (no stuck "Thanks, neighbor!"). |
| 1b | Complete pass, Done, relaunch with SAME token | PASS: fresh choosing screen. |
| 1c | Depart, relaunch mid-celebration | PASS: no-URL relaunch #1 restores "You just passed a spot."; relaunch #2 lands on the "Pass the spot" landing, not the celebration. A relaunch with a different token mid-celebration starts a fresh flow (terminal pass), per PR text. |
| 1d | Cancel, relaunch with new token | PASS: "Pass cancelled." then token B shows the choosing screen. |
| 1e | Armed, relaunch with new token | PASS: armed screen shows "You can only help one neighbor at a time. Finish or cancel this pass first." (AX tree). |
| 2 | Armed pinning | PASS, table below. |
| 3a | Title "Lock-screen countdown is off" | PASS (`01`, `02`, `12`, `13`). |
| 3b | Settings link present | NOT VERIFIED: link absent in this sim, by design (finding #1). Tap behavior unverifiable. |
| 3c | Install card omits lock-screen promise when LA off | NOT VERIFIED: card still shows "Next time, leave from your lock screen in one tap." in this sim (`09`), finding #1. |
| 4a | Cancel sheet: "Keep it" primary, "Cancel my pass" | PASS (`05`): white primary "Keep it", dark "Cancel my pass", full width and roomy (about 56 pt at 3x by eye, not ruler-measured). Keep it dismisses with no state change (still "Time to go?"). |
| 4b | Done copy | PASS: "Thanks for passing it on." / "That helped a neighbor find a spot." (AX tree). Fits the design voice: calm, plain, no gamification. |
| 4c | Fake-mode relaunch of an armed pass can cancel | PASS: kill + relaunch while armed (restored as "Time to go?"), "Not leaving after all" then "Cancel my pass" gave "Pass cancelled." |
| 5 | Release clip | PASS: `WeParkClip.app` 5.3 MB (budget 10). `strings` on the binary and `grep -rl` on the bundle: 0 hits for `DebugInMemoryHandoffSecretStore`, `spotPassUseFakeAPI`, `spotPassDebugFakeSecret`, `FakeHandoffDriverAPI`, `spotPassClipURL`, `FAKEFAKE`. New copy "Lock-screen countdown is off" is present (2 hits). |

### Armed screen pinning (screenshots in `assets/pr172/`)

| Device / size | "I'm pulling out" | "Not leaving after all" | Collisions | Shot |
|---|---|---|---|---|
| iPhone 17 default | pinned | pinned, visible | none | `01` |
| iPhone 17 XXXL | pinned | pinned, visible | none (content fades under the pinned bar) | `02` |
| iPhone 17 AX5 | pinned | under the lock-screen card, about two swipes down; not in first viewport | none | `03`, `04` |
| SE default | pinned | pinned, visible | none | `12` |
| SE XXXL | pinned | visible without scrolling (inline above the pinned primary) | none | `13` |
| SE AX5 | pinned | not in first viewport (scroll) | none | `14` |

## Findings

### 🟡 Significant

- **#1: The Live Activities "off" path is not what the PR assumes, so the Settings link and install-card line-omission are unverifiable live, and two copy surfaces can disagree.**
  - Where: `ClipArmedView.lockScreenCard` (Settings link gated on `!controller.activitiesEnabled`, title gated on `!controller.activityStarted`), `ClipCelebrationView` (`showsLockScreenLine: controller.activitiesEnabled`), `ActivityKitHandoffActivityController.start`.
  - Observed: in this sim `areActivitiesEnabled` is TRUE but `Activity.request` fails, so `activityStarted == false` and `activitiesEnabled == true`. The card title reads "Lock-screen countdown is off", no Settings link shows (correct: Settings would not help), and the install card still promises "leave from your lock screen in one tap" (`09`). The PR note "the sim reports off" is wrong; it reports "enabled, start failed".
  - Impact: the real target branch (user disabled Live Activities, `areActivitiesEnabled == false`) is covered by unit tests only. The start-fails-while-enabled branch (rare on device, for example a system budget limit) shows "off" copy yet the install card still promises a lock-screen countdown.
  - Suggest: key the install-card line on `activityStarted`, or on both flags; confirm the Settings link and `openURL` from a real App Clip on a device with Live Activities toggled off.
  - Owner: `@ios-engineer`. Not merge-blocking.

### 🟢 Minor

- **#2: At AX5 the armed screen's "Not leaving after all" is about two swipes down.** Pinned primary plus cancel under the card is the stated design, but design 3.4 says cancel is always visible. Judgment call for `@designer` whether to pin a compact cancel at AX or shorten the AX subline.
- **#3: Primary button turns white at "Time to go?"** (compare `01` and `04`). Intended hero emphasis; noted so nobody reads it as a regression.

### 💡 Out of scope / carried

- Live Activity lock-screen rendering, SKOverlay and the Settings link from a real App Clip remain device-only checks.
- Known limit from the PR: a late seeker "thanks" after Done cannot settle the pending karma. Documented, acceptable.
- On a fresh sim the DEBUG notification prompt blocks the first screenshot; not a defect.

## Smoke tests run

- `df -h /`: 14 GB free before the first build, 11 GB before the Release build. Derived data under `~/Library/Caches/wepark-qa172-dd`, deleted after.
- Debug `WePark` build (includes `WeParkClip`) and Release `WeParkClip` build: both succeeded.
- Live on iPhone 17 via AXe taps and AX-tree dumps, screenshots read: armed default/XXXL/AX5, cancel sheet (Keep it, then Cancel), cancel then new token, armed then new-token note, full pass to celebration, restore-once via no-URL relaunches, thanks + install card, Done copy, relaunch after Done with different and same tokens.
- Live on a temp SE: armed default/XXXL/AX5 after allowing notifications.
- Release `strings`/`grep` hygiene and size.
- Not run: `xcodebuild test`, `.saveFailed`, Live Activity rendering, SKOverlay, Settings link tap. The same-token-while-celebrating no-op relied on the PR's unit test (the live restore-once check used no-URL relaunches).

## What's working

The dead-end fix is clean: Done now ends the pass, a departed pass restores exactly once, and every relaunch variant (new token, same token, after cancel, while armed) behaves. The armed screen keeps the primary action under the thumb at every size, the cancel sheet makes "Keep it" the obvious safe choice, and "Thanks for passing it on." closes the flow in the right voice. Release stays at 5.3 MB with zero DEBUG symbols.
