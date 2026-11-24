# PR #168 QA: Spot Pass App Clip (stream C3)

**Reviewed:** branch `feat/spot-pass-c3-clip` at `4f1ee4a5`, against `docs/specs/qr-spot-handoff.md` Rev 2 and `docs/design/spot-pass-design.md`
**Date:** 2026-11-24 (iPhone 17 sim iOS 26.5, temporary iPhone SE 3rd gen; Debug + Release sim builds; no `xcodebuild test`)
**Verdict:** MERGE-WITH-FOLLOWUPS (conditional: see "Not verified live" below. The depart, celebration, thanks and install-card screens could NOT be walked in the simulator, so the device pass is the real gate.)

## Summary

The clip's first impression is strong. The card, chips, "Now never auto-sends", the armed screen, every error scenario, the real "Show me this block" reveal, and the SE and AX5 layouts all render and behave as designed. Release hygiene is clean: DEBUG fakes are absent from the Release binary, there is no `requestAlwaysAuthorization`, nothing is logged, the secret redacts itself, and the clip is 5.0 MB against a 10 MB budget. The seeker flow still works after the shared-code move.

Three things hold back a clean MERGE. (1) A failed keychain write is ignored, which leaves a dead "I'm pulling out" button. (2) At accessibility sizes the pinned CTA stack covers most of the screen and collides with scrolled text. (3) The block card shows a false "Next" cleaning date on holidays. I found no blockers in the code I could exercise.

## Not verified live (environment limit, be explicit)

Walking from claim through depart, celebration (karma pending), thanks and the install card needs the claimer secret in the keychain. A simulator build with `CODE_SIGNING_ALLOWED=NO` has no entitlements, so `SecItemAdd` fails with -34018. I got through claim, armed and the "Time to go?" screen, but the final "I'm pulling out" tap did nothing (see finding 1).

I tried re-signing the clip, with and without the parent app and with the project's xcent and a real identity. Every signed variant was refused by SpringBoard (`FBSOpenApplicationServiceErrorDomain` code 1, "denied by service delegate"). So these screens are unverified live:
- depart, celebration with the dashed karma chip, thanks, and the install card
- `departFails`
- the cancel confirm
- the "Five more minutes" action
- the reminder banner at `leave_at`

Code was reviewed for them, and the PR's ~110 unit tests cover the state machine (CI green, not re-run by me). **Recommend one device pass of this segment before the QR goes on a real sign.**

## Acceptance checklist

- [x] Card "Bodega Cat is waiting for your spot." with glyph; peek crossfade. Verified live. `slowPeek` at t=1 s shows "A neighbor is waiting for your spot." with chips and CTA already usable; the alias appears by t=7 s.
- [x] Chips: Now / 10 min (preselected, checkmark) / 30 min / 1 hr / Pick a time, with VoiceOver labels "Leaving in 10 minutes" and so on. Verified in the accessibility tree and screenshot.
- [x] Now never auto-sends. Armed screen "I'm pulling out" opens "Time to go?" with a 120 pt button, "Tap right before you go. Please don't use your phone while driving.", Five more minutes, Not leaving. Nothing was sent.
- [x] Claim goes to the armed screen "You're on, neighbor." with the reminder time. Real keychain was off, but the fake claim returned an `id` and the UI armed.
- [x] Live Activity. On a later launch the armed card showed "Look at your lock screen... Your countdown is there", so ActivityKit started. On the first fresh install it showed "Lock-screen countdown is off. We'll remind you with a notification instead." The cause is unclear: possibly a sim quirk, or authorization not settled while the DEBUG notification prompt was up. The copy and fallback work. Not verified: the lock-screen rendering itself.
- [x] Scenarios, all verified live with calm copy:
  - `unavailable`: "This Spot Pass isn't active anymore." plus "What's WePark?"
  - `offline`: "Can't reach WePark right now." plus Try again
  - `disabled`: "Spot Pass isn't live yet."
  - `claimOffline`: stays on the chooser with an inline "Check your connection and try again."
  - `noID`: "Open the WePark app to finish."
  - `slowPeek`: see above
- [ ] `departFails`, depart, celebration, thanks, install card, cancel: not verified live (see above).
- [x] "Show me this block". Fake tile, "Wrong side? Switch" flipped Tue 10:00-11:30 to Thu 9:00-10:30. Footer "Always check the posted signs." and "Next time you park here, WePark tells you this before you walk away." No legality claim. Location is requested on tap only, with the explainer "Uses your location once...". The reveal is not visible on the first screen, only on the armed screen, which is correct.
- [x] iPhone 17 default, SE default: clean (screenshots attached).
- [ ] AX5 / XXXL layouts: chips stack correctly and the CTA is pinned, but see finding 2.
- [x] Colors: indigo and lavender chrome only. No green, orange or red appears in anything I saw. The red "cleaning now" pill was not triggered because the fake windows were not in effect.
- [x] Banned words: copy lint grep found none ("hurry", "free spot", "legal" and so on appear only in comments). The copy uses "heads-up" and "neighbor".
- [x] Security and privacy, see below.
- [x] Main app, flag off, launches normally (map, ASP banner, toolbar, search sheet).
- [x] Seeker flow (flag on, fake API): More, Spot Pass, "Pass the spot.", Create, armed, "Spot opening up." and Got it, thanks!, "Thanks, neighbor. +3 karma". Passes after the move of glyph, theme and karma chip into Shared.
- [x] Size: Release clip is 5.0 MB (binary 3.6 MB, Live Activity appex 1.0 MB). The budget is 10 MB.

## Security and privacy (code review and binary)

- `strings` on the Release clip binary finds 0 hits for `spotPassUseFakeAPI`, `spotPassFakeScenario`, `spotPassClipURL`, `_XCAppClipURL`, `FAKEFAKE`, fake class names and `requestAlwaysAuthorization`. `ClipDebugSupport.swift` is wrapped in `#if DEBUG`. The only `requestAuthorization` call is inside that DEBUG file, so Release never prompts and relies on `.ephemeral`.
- The claimer secret is stored only via `SecItemAdd` (label `wepark-appclip`, account = pass id). `ClaimerSecret` redacts itself (`description` is "ClaimerSecret(redacted)"). There are no `print`, `NSLog`, `os_log` or `Logger` calls in `Clip`, `Shared/SpotPass` or `ClipLiveActivities`. The App Group holds only the non-secret pass snapshot.
- Anonymous session: plain GoTrue `POST /auth/v1/signup` with a 6 s timeout, run concurrently with Live Activity start. If anonymous sign-ins are disabled the call returns nil, the claim goes out without a JWT, and arming still works. Karma and the carry-over context are then skipped, because no uid is written (as the PR says). Not tested against the real backend.
- The tile fetch goes to the GitHub Pages host. That is a dependency to note (finding 6), not a leak: only a tile index is requested.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: Keychain write failure is silent and leaves a dead "I'm pulling out" button.**
  - Where: `HandoffStorage.swift` `KeychainHandoffSecretStore.save` (return of `SecItemAdd` ignored); `ClipFlowController.finishArming` then `pullOut` (`guard ... let secret = deps.secrets.secret(for:) else { return }`).
  - What: when the secret cannot be stored, the clip still arms and shows "You're on". Tapping "I'm pulling out" then silently does nothing, with no error and no state change. I hit this in the unsigned sim build (-34018), and `extend` and `cancel` presumably share the problem. On a device with a correctly signed clip this should be rare, but the failure mode is the worst one in a feature whose whole value is that the depart ping lands.
  - Expected: a failed save should fail arming ("Open the WePark app to finish", like `noID`), or `pullOut` should surface "Couldn't send. Try again." (design 7.1). The pass should never look armed if it cannot depart.
  - Owner: `@ios-engineer`

- **#2: At AX5 and XXXL the pinned CTA stack covers most of the screen and overlaps scrolled text.**
  - Where: `ClipChoosingView` pinned `safeAreaInset`. Attached `ax5-choose.png` (iPhone 17, XXXL) and `se-xxxl-choose.png` (SE, XXXL).
  - What: the primary CTA is 195 pt tall, and with "Not leaving soon" the pinned area is roughly 40% of an iPhone 17 and 60% of an SE. The inset has no opaque backdrop, so the subline text scrolls underneath and renders on top of or behind "Not leaving soon". On the SE the overlap is illegible. The chips stack correctly below (63 pt each, all reachable by scrolling), but a user has to scroll past the pinned CTA to pick a time.
  - Expected: design AX5 says the CTA is pinned and readable. The inset needs a solid or gradient scrim, and its height should be capped at larger sizes (smaller label font, or unpin below some height).
  - Owner: `@ios-engineer`

- **#3: ASP suspension gap gives a wrong "Next" date, and a possible false red pill on holidays.**
  - Where: `ClipBlockInsight.swift`; the builder flagged it.
  - What: today (Tue Nov 24) the "Wrong side" card showed "Next: Thu, Nov 26, 9:00-10:30 AM". Nov 26 2026 is Thanksgiving, when ASP is suspended, so the card states a cleaning date that will not happen. The same logic would show the red "cleaning now" pill on a suspension day. The bundled full app already ships `asp-2026.json`, but the clip does not. The footer "Always check the posted signs." is adequate against any legality reading, but it does not soften a wrong red "now" pill. The card never says "you can park", so this is wrong-date severity, not a liability one.
  - Expected: before the pill ships to real signs, either bundle the small suspension list in the clip (about 1 KB of the 5 MB) or hide the red pill and "Next" date on dates in the list. Short of that, soften the pill copy so it does not read as authoritative on holidays.
  - Owner: `@ios-engineer`

### 🟢 Minor

- **#4: A saved armed pass wins over a newly scanned invocation.** After arming once, relaunching with a new `-spotPassClipURL` restored the old armed screen instead of the new pass. This is probably intended, since only one pass is active at a time, but a second scan while armed gives no feedback. Worth a product decision.
- **#5: Armed screen stays on "You're on" past `leave_at` when foregrounded.** The foreground does not flip to "Time to go?" on its own (a banner is expected via `willPresent`, which I could not observe). It is consistent with "Now never auto-sends", but the armed headline could say "Time to go?" once the time passes. The `TimelineView` on the pulling-out screen already does this.
- **#6: Tiles come from GitHub Pages (`kevhox1.github.io/parkmap`).** The block card breaks if the Pages deploy moves. A tile path on getwepark.com is a follow-up.
- **#7: First-run "countdown is off" on a fresh install.** See the checklist: unclear cause, worth a look on a device.
- **#8: "I'm pulling out" renders as a low-contrast dark button on the armed screen.** It reads as disabled next to "Show me". Per design 7.1 it is secondary when the Live Activity is on, so this is by design, but a driver may miss it. Judge on a device.
- **#9: DEBUG-only notification prompt before the claim result.** Expected and DEBUG-only, noted so nobody files it.

### 💡 Out of scope

- Clip never polls the server after the 8 h ephemeral window (PR watch-list item 1).
- Test-harness recommendation: add a DEBUG in-memory secret store to the fake mode, so QA can walk depart through celebration on an unsigned sim build.

## Device-only list (not failures)

Live Activity `Link` opening the clip, and the lock-screen LA rendering and flip at `leave_at` (`isStale`); notification actions and the reminder banner; ephemeral APNs token and the thanks push; `#t=` fragment surviving into `webpageURL` (the `?t=` fallback parses); SKOverlay; push capability and signing on the clip App ID (`aps-environment`); keychain secret write on a signed build (finding 1); depart, celebration, thanks and the install card (see "Not verified live").

## Smoke tests run

- `df -h /`: 12 GB free, above the 8 GB floor, before each build.
- Debug build (`WePark` scheme, embeds the clip), Release build (`WeParkClip` scheme): both succeeded.
- Live walk on the iPhone 17 smoke sim with the PR's example command: card, chips, claim, armed, Show me, Wrong side, "Time to go?".
- 6 of 8 scenarios live (all but `departFails`), plus the default `open` scenario.
- iPhone 17 default and XXXL, SE default and XXXL screenshots, each read.
- Seeker flow with the flag on locally (temporary one-line edits to `Constants.swift`, reverted; `git status` clean): armed, departed, "+3 karma".
- Flag-off launch: map, toolbar, ASP banner, search sheet render (screenshot read).
- Release binary `strings`, grep for logging, auth and prompts.

## What's working

The copy and tone are very good, with no urgency language and "neighbor" throughout. The "Now" chip is handled safely: it opens "Time to go?" and never sends. Failure screens are calm and each has a next step. The "Show me this block" card never claims legality. The Release binary is small and clean. The shared-code move did not break the seeker flow. The code is careful about secrets, with a 6 s cap on anonymous signup so it can never stall arming.
