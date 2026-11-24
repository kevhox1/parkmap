# PR #171 QA: clip DEBUG in-memory secret store, plus the first full live walk of the App Clip

**Reviewed:** `chore/clip-debug-secret-store` (PR #171, CI green). Debug `WePark` scheme build for the simulator (`CODE_SIGNING_ALLOWED=NO`), iPhone 17 sim iOS 26.5, temp iPhone SE 3rd gen. Release `WeParkClip` build for `strings` and size. No `xcodebuild test`.
**Date:** 2026-11-24
**Verdict on PR #171: MERGE.** It does exactly what it says: the unsigned sim can now walk every clip screen, and Release is clean.
**Verdict on the clip flow itself: not ready for a real sign yet.** The walk found one real bug (a finished pass is never cleared, so the next scan is swallowed, finding #1) and one design-doc safety miss ("Not leaving after all" is not always visible, finding #2). Neither comes from #171.

## Summary

With the in-memory store, every screen the PR #168 and #169 reports could not reach is now reachable and was walked live: armed, "Time to go?" foreground flip, reminder banner, "5 more min", "Not leaving" confirm, depart, celebration with the pending karma chip, thanks, install card, `departFails`, cancel, and the second-scan note. All behave as designed except two deviations below. The Release clip is 5.2 MB with zero DEBUG symbols. Not reachable even now: the new `.saveFailed` screen (needs a failing keychain, which fake mode deliberately no longer has), the Live Activity lock-screen rendering (activities report "off" in this sim), and the SKOverlay (the in-clip install card renders instead).

## PR #171 checklist

- [x] In-memory store only with the fake flag. Code: `makeSecretStore()` returns `DebugInMemoryHandoffSecretStore` only when `useFakeAPI`, else `KeychainHandoffSecretStore`. It lives in `ClipDebugSupport.swift` (`#if DEBUG`) and its only caller is inside the `#if DEBUG` fake branch of `ClipComposition.make()`. The non-DEBUG path (line 60) names `KeychainHandoffSecretStore()` directly. PR tests cover the flag gating (`-spotPassUseFakeAPI NO` and `-spotPassFakeScenario offline` alone both give the keychain store) and the store semantics (save, load, scoped to pass id, clear). CI green; not re-run by me.
- [x] Fake secret is the constant `FAKEFAKEFAKEFAKEFAKE12` value (never a real secret); nothing logged.
- [x] Release clip hygiene (built `WeParkClip` Release for the sim). `strings` on the clip binary and the bundle: 0 hits for `DebugInMemoryHandoffSecretStore`, `spotPassUseFakeAPI`, `FakeHandoffDriverAPI`, `spotPassClipURL`, `FAKEFAKE`, `spotPassFakeLeaveSeconds`, `makeSecretStore`, `DebugAuthorizing`. Size 5.2 MB (binary 3.97 MB), budget 10 MB. The new saveFailed copy is present in the Release binary (2 string hits).
- [x] New `.saveFailed` copy: title "We couldn't save this on your phone." body "Nothing was set up. Get WePark and scan again." with "What's WePark?". Calm, no banned words, no reminder mention, distinct from `.openApp`. Reworded `.openApp` body: "We couldn't finish setting this up here. Get WePark and scan again." (no longer says "reminder"). Both in the copy lint list. Not seen live (see out of scope).
- [x] Behavior on a failed save: `finishArming` ends the Live Activity, clears the store, best-effort cancels the server claim, then `phase = .saveFailed`; the test asserts no pass, no stored pass, no reminders, `cancel` called, no `depart`.

## Screen-by-screen table (iPhone 17 unless noted; launch flags `-spotPassUseFakeAPI YES -spotPassClipURL ...#t=AAAA...`)

| # | Screen / behavior | Result | Evidence |
|---|---|---|---|
| 1 | Choosing card: "Bodega Cat is waiting for your spot.", chips (10 min preselected), pinned CTA, "Not leaving soon" | PASS | `assets/pr171/01-choose.png` |
| 2 | Notification permission prompt on CTA (DEBUG-only), then claim | PASS | `02-after-tap.png` |
| 3 | Armed "You're on, neighbor." with real reminder time, lock-screen card, "I'm pulling out" (secondary), "Show me" card, "Not leaving after all" | PASS | `03-armed.png` |
| 4 | Foreground flip to "Time to go?" at `leave_at` (`-spotPassFakeLeaveSeconds 30`); "I'm pulling out" becomes the hero button | PASS (live, at 1:52:33, no relaunch) | `05-leaveat-b.png` |
| 5 | "I'm pulling out" opens the "Time to go?" screen: 120 pt button, driving safety line, "5 more min", "Not leaving", Back | PASS | `06-pullout.png` |
| 6 | "5 more min": countdown "Leaving in 4:58", toast "Done. +5 minutes." | PASS | `07-five-more.png` |
| 7 | "Not leaving" confirm dialog (dismisses on outside tap, no state change) | PASS, copy differs slightly from design (finding #4) | `08-cancel-confirm.png` |
| 8 | Cancel confirmed in one process: "Pass cancelled." with "What's WePark?" | PASS | `14-cancelled.png` |
| 9 | Depart then celebration: SPOT PASSED stamp, "You just passed a spot.", "A neighbor is pulling in because of you.", dashed **pending** "+5 karma / lands when they say thanks", Done | PASS | `09-celebration.png` |
| 10 | Thanks after `-spotPassFakeThanksAfter 10`: "Thanks, neighbor! Bodega Cat got your spot.", solid +5 karma chip | PASS | `10-thanks.png` |
| 11 | Install card (in-clip): "Keep your karma." headline, body, "Next time, leave from your lock screen in one tap.", Get WePark / Not now. SKOverlay itself did not appear in the sim | PASS for the in-clip card; SKOverlay NOT REACHABLE in sim | `10-thanks.png` |
| 12 | Done on thanks: "No worries. Thanks for looking." | PASS mechanically, copy mismatch (finding #5) | `11b-after-done.png` |
| 13 | `departFails`: tap through to "Time to go?", tap depart: "Couldn't send. Try again." inline, countdown and options stay, no state loss | PASS | `15-departFails.png` |
| 14 | Second scan of a different token while armed (cold relaunch with token C, armed pass was A): note "You can only help one neighbor at a time. Finish or cancel this pass first.", armed pass kept, not replaced | PASS (note appears; AX tree + screenshot) | `12-second-scan.png` |
| 15 | Reminder banner at `leave_at` with the app backgrounded: "Time to go? Bodega Cat is waiting for your spot." at ~30 s, also on the lock screen | PASS | `16-reminder-banner.png`, `17-lockscreen.png` |
| 16 | Live Activity on lock screen / Dynamic Island | NOT REACHABLE: the armed card says "Lock-screen countdown is off. We'll remind you with a notification instead." on every run, so ActivityKit is unavailable in this sim for the clip; no activity on the lock screen. Needs a device. | `17-lockscreen.png` |
| 17 | AX pinning on the **choosing** screen | Not re-run (verified in PR #169) | n/a |
| 18 | AX pinning on the **armed** screen | FAIL against design intent: no pinned CTA, and "Not leaving after all" is not visible (finding #2) | `18-armed-ax5.png`, `19-armed-xxxl.png`, `20-se-armed-default.png`, `22-se-armed-ax5.png` |
| 19 | `.saveFailed` screen | NOT REACHABLE live (fake mode never fails a save now; flag off needs the real prod API). Code, copy and unit test only | n/a |
| 20 | Stale pass after Done (relaunch) | FAIL (finding #1) | `11b-after-done.png`; relaunch observed (see finding) |

## Findings

### 🔴 Blocking (for the clip going live on real signs; not for PR #171)

- **#1: A finished pass (departed or thanked) is never cleared, so every later scan is swallowed by a stale "Thanks, neighbor!" screen.**
  - Where: `ClipFlowController.dismissCelebration()` only sets `phase = .dismissed`; `passStore.clear()` is reached only through `cleanupLocal` in `endPass`, which the celebration path does not call. `restore()` on the next launch loads the saved `.departed` pass straight back into `.celebration` with no expiry check, and `handle(url:)` then returns early because `pass != nil` ("an active pass wins").
  - Observed live: complete the flow, tap Done ("No worries. Thanks for looking."), relaunch the clip with the same token or a different one. It opens on "Thanks, neighbor! Bodega Cat got your spot." and the new scan never starts. Reproduced three times; only a clip uninstall cleared it.
  - Expected: Done (and the thanks/celebration end of life) clears the stored pass, secret and fingerprint, so the next scan starts a fresh pass. A `.departed` pass should also expire.
  - Repro: fake claim, "I'm pulling out", depart, Done, relaunch with any `-spotPassClipURL`.
  - Impact: a driver who ever completes one pass sees a dead screen on the next sign until iOS purges the clip data (up to about 30 days). This is a one-use clip. Not caused by #171 (the dead end was simply unreachable before the store existed).
  - Owner: `@ios-engineer`

### 🟡 Significant

- **#2: On the armed screen, "Not leaving after all" and "I'm pulling out" are not pinned and fall below the fold at large text and on the SE.** Design 3.4 says "Not leaving after all ... ALWAYS visible (safety item 3/12)" and 3.9 says the CTA stays pinned at AX5.
  - Where: `ClipArmedView` is a plain `ScrollView` with no `safeAreaInset` (only `ClipChoosingView` pins). The PR #169 report said the armed screen "uses the same pinning rule per the diff"; that was wrong and is corrected here.
  - Observed: iPhone 17 default shows everything above the fold (the quiet cancel link is at the very bottom, visible). SE default: "Not leaving after all" is below the fold. iPhone 17 XXXL: "I'm pulling out" visible but cancel cut off. iPhone 17 AX5 and SE AX5: only the title and subline show; neither action is visible without several scrolls.
  - Expected: cancel always reachable; at AX the primary action pinned.
  - Owner: `@ios-engineer`
- **#3: Lock-screen card when Live Activities are off has no Settings link** (design 3.4: "with a `Settings` link"). Card shows the right sentence only. Not verifiable whether the link exists elsewhere; none visible. Owner: `@ios-engineer`. (Lowered to this tier because it affects the only user-visible recovery path for the "off" state.)

### 🟢 Minor

- **#4: Cancel confirm differs from the design.** Live: a small dialog with "Not leaving after all" as a header-style row and "Cancel my pass"; no "Keep it" button (dismiss is tap-outside). Design 3.4 lists "Cancel my pass / Keep it", 56 pt buttons. Works, but the dismiss affordance is hidden and the buttons are not 56 pt. Owner: `@ios-engineer`.
- **#5: Done after a completed pass shows the "I wasn't leaving" screen.** "No worries. Thanks for looking." is the `.dismissed` copy meant for "Not leaving soon". After a successful hand-off it is off-tone (the driver just did a good thing). Consider a thank-you or the install card as the resting state. Owner: `@ios-engineer` / `@designer`.
- **#6: In fake mode, a relaunched armed pass cannot be cancelled or departed.** The pass snapshot lives in the app-group defaults across launches but the in-memory secret does not, so after a relaunch "Not leaving after all > Cancel my pass" gives "Couldn't cancel. Try again." and depart gives "Couldn't send. Try again." That is a tooling limit of #171 (and in production the real keychain survives). Worth one line in the PR #168 launch instructions: do the whole walk in one process; reinstall to reset. Owner: `@ios-engineer` (docs only).
- **#7: SKOverlay and Live Activity cannot be judged in the sim.** Not defects; carried to the device pass.
- **#8: Copy said "Look at your lock screen" while the countdown is off.** The card title is still shown with the "off" body ("Look at your lock screen / Lock-screen countdown is off. ..."), which reads slightly contradictory. Also the install card promises "leave from your lock screen in one tap" to a user whose Live Activities are off. Cosmetic.

### 💡 Out of scope

- Real-device confirmation of ActivityKit and the SKOverlay remains the last gate before a QR goes on a sign.
- The ASP calendar is 2026 only (carried from #169).

## Smoke tests run

- `df -h /`: 12 GB before the first build, 9.4 GB before the Release build (above the 8 GB floor); 13 GB after cleanup.
- Debug `WePark` build and Release `WeParkClip` build (derived data under `~/Library/Caches/wepark-qa171-dd`, deleted after): both succeeded.
- Live walk on iPhone 17 (UDID resolved dynamically, `iPhone 17 smoke`): choosing, permission, armed, foreground flip, pulling out, 5 more min, cancel confirm, cancel, depart, celebration, thanks, install card, Done, `departFails`, second scan, reminder banner, lock screen, AX5 and XXXL armed. Screenshots read, AX tree checked for the second-scan note.
- Temp SE (iPhone SE 3rd gen): armed at default and AX5 (screenshots read).
- Release binary `strings`, bundle size.
- Code review of `makeSecretStore`, `ClipComposition`, `restore`, `dismissCelebration`, `handle(url:)`, `ClipArmedView`, `ClipChoosingView` pinning.
- Not run: `xcodebuild test`, `.saveFailed` live, Live Activity rendering, SKOverlay.

## What's working

The in-memory store is a tidy, correctly fenced fix: one DEBUG file, one gated call site, constant fake secret, and tests for both gating and semantics. With it the whole driver journey is walkable unsigned, and almost all of it is lovely: the celebration stamp with the dashed pending karma chip becoming a solid one on thanks, the 120 pt depart button, the calm inline "Couldn't send. Try again." that keeps the countdown, the foreground flip to "Time to go?" and a notification that lands on time, and a second scan that is politely refused without disturbing the armed pass.
