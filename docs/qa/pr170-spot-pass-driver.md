# PR #170 QA: Spot Pass C2 full-app driver flow (2026-11-24)

**Reviewed:** `feat/spot-pass-c2-driver` at `79f72479`, merged locally with `origin/main` at `e40c7018` (App Clip PRs #169/#171/#172; one test-only conflict in `ClipC3Tests.swift` `ClipCopyLintTests.allCopy`, resolved locally by union, not pushed; **the PR itself needs that merge before it can land**).
**Verdict:** **MERGE-WITH-FOLLOWUPS** (no blockers; flag stays `false`; 1 real logic bug and 1 layout bug to fix before the flag flips)
**CI:** `Build and XCTest (Xcode 26)` pass (16m, includes the 98 new `SpotPassDriverC2Tests`). I ran no tests (build only), per rules.
**Env:** iPhone 17 sim iOS 26.5, Debug build for `generic/platform=iOS Simulator`; temp iPhone SE (3rd gen) for small-screen layout (deleted).

## Summary

Flag-off is inert: the app renders exactly the main chrome and the intents are non-discoverable. With the flag on and the fake API, the whole driver loop works live on the simulator, including things I expected to be device-only: the **Live Activity renders on the lock screen and in the Dynamic Island, and a one-tap "Leaving now" from the locked sim ran the intent and flipped the activity to "You passed a spot."** Findings: a new Spot Pass link is silently dropped while an unthanked "passed" record is on disk (up to 30 min), and the pinned CTA footer on the card screen overlaps the scrolling text at large Dynamic Type.

## Merge-blocking checks

### 1. Flag OFF: PASS
- [x] Launch, Main defaults (`spotHandoffEnabled=false`): ASP banner, locate + clock toolbar, persistent browse sheet ("Search for a destination"), Report/? buttons, location dot all render (`assets/pr170/off1.png`). No Spot Pass UI. (The curb polylines appear in the drive-mode screens; flag-off default zoom shows none, same as main's default presentation. The ContentView diff flag-off is one modifier returning `content` untouched plus an `await` skipped by `if AppConstants.spotHandoffEnabled`, so I judge no regression; I did not A/B against a main build.)
- [x] Intents non-discoverable: built app's `Metadata.appintents/extract.actionsdata` lists `LeavingNowIntent`, `NotLeavingIntent`, `FiveMoreMinutesIntent` all `isDiscoverable: false`, `autoShortcuts: []` (same in the `WeParkLiveActivities.appex`). Provider compiled out behind `SPOT_PASS_SHORTCUTS`. I did **not** open Shortcuts -> add action -> search in the sim; the metadata is the stronger evidence, but a one-minute eyeball on a device is cheap.

### 2. Flag ON, fake API: PASS (two findings below)
- [x] **Universal link -> driver cover over the browse sheet** (`-spotPassClipURL`): cover presents full-screen over the map/sheet (card "Bodega Cat is waiting for your spot", indigo, chips Now/10/30/1hr/Pick, 10 preselected, "Not leaving soon" always there).
- [x] Chip "Now": CTA becomes "Tell Bodega Cat I'm on my way", tapping it arms and opens the "Leaving in" pulling-out screen; it did not send. (Fake leave-seconds override masked the real "Time to go?" copy; see Not verified.)
- [x] CTA -> notification permission prompt appears **only here** (never at launch) -> armed screen "You're on, neighbor. Reminder at 2:40 AM", countdown, "I'm pulling out", "Set up car auto-ping", "Not leaving after all" (`on4.png`).
- [x] **Reminder notification at leave time** ("Time to go? Bodega Cat is waiting for your spot.") delivered while backgrounded; Dynamic Island showed cat glyph + `0:00`.
- [x] **Live Activity on the lock screen** (countdown, Leaving now, Not leaving) and **one-tap Leaving now while the sim was locked**: activity changed to "You passed a spot. +5 karma lands when they say thanks" and the reminder notification was cleared (`rem3.png`, `la1.png`). Opening the app showed the celebration "You just passed a spot." with dashed **pending** karma chip "+5 karma lands when they say thanks" (`cel1.png`).
- [x] **Thanks**: `-spotPassFakeThanksAfter 20` after a depart settled and purged the pass (next link started a fresh card). I did not catch the dashed->solid frame itself.
- [x] **Cancel**: "Not leaving" -> "Cancel my pass? Bodega Cat won't be told." / "Keep it" -> "Pass cancelled." Done.
- [x] **Report**: flag -> Harassment/Spam/Unsafe/Something else -> toast "Thanks. We'll take a look." and an armed pass ends with "This pass has ended. Thanks for being ready, neighbor." (`report-ended.png`).
- [x] **Start Driving with armed pass** departs: after tapping Start Driving the lock-screen activity read "You passed a spot." (a faint "Told your neighbor you're leaving." toast was visible in one frame). **Without a pass** Start Driving just starts drive mode, no toast, nothing sent.
- [x] **Failed secret save**: I hit this by accident (ad-hoc-unsigned build, `CODE_SIGNING_ALLOWED=NO`, has no keychain access). Footnote "We couldn't save this on your phone, so nothing was set up. Try scanning the pass again." shows under the card, nothing armed, **no "Get WePark"** (`save-failed.png`). Rebuilding with `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` made the keychain work, which is how the rest was run. Note for future QA: unlike the clip (#171), the driver fake mode has no DEBUG in-memory secret store, so an unsigned build can never arm (finding #4).
- [x] **Categories registered together** (code): `launchCategories` appends address + seeker + `DriverReminderCategory` (`includeDriverReminders: AppConstants.spotHandoffEnabled`) and all go through the merge-safe `NotificationCategoryRegistry.register`; the driver scheduler also uses it. The only lone `setNotificationCategories` left is `Shared/.../HandoffReminders.swift:122`, used by the clip target only (no reference from `WePark/`). Reminder actions are `options: []` (background, non-destructive, no auth).
- [x] **`AppDelegate.didReceive`** (code): reminder actions return before the `defer` and hold `completionHandler()` until the send/extend/cancel finishes; the body tap falls through to the existing `defer { completionHandler() }` path and calls `presentPullingOut()`; address/community/seeker/`show_car_detail` paths unchanged (the diff only hoists `let userInfo`).
- [x] Seeker-cover-open case (code only): `onChange(of: runtime.coverPresented)` dismisses the seeker cover, then re-presents after 600 ms; the intermediate `coverPresented=false` hits the `guard presented` and exits. **Not exercised live.**

### 3. Carry-over + Welcome: PASS
Fresh install each time (`simctl keychain reset` is required, see note), `onboardingStoryEnabled` on:
- [x] `-spotPassSeedCarryOver YES -spotPassSeedHelped 0 -spotPassSeedPending 1`: "Welcome, neighbor. You've already helped 1 person park." + dashed "+5 karma lands when they say thanks" chip, "Show me around", Skip, no progress bar (`welcome-pending.png`).
- [x] `Helped 2 Pending 0`: "...helped 2 people park." + solid "10 karma" chip (`welcome-helped2.png`). `0/0`: "You were ready to pass a spot. That's what this is all about." no chip.
- [x] "Show me around" -> the unchanged location priming card ("See real parking conditions around you"); **no notification prompt** at launch, at the Welcome, or after it.
- [x] No seed -> standard 3-card deck ("Parking here is a game you play twice a week").
- Note (by design, Decision 4): the sim keychain survives uninstall, so a re-seeded launch with a leftover session shows the deck. Anyone repeating this must `xcrun simctl keychain <udid> reset`.

### 4. Layouts
- [x] iPhone 17 default: all screens clean (cards above).
- [x] SE default: card screen fits fully, nothing clipped.
- [ ] **AX5 (iPhone 17) and XXXL (SE): card screen FAILS visually, see finding #2.** Armed screen at AX5/XXXL scrolls fine and "I'm pulling out" is reachable (it is in the scroll, not pinned); celebration/other screens were not captured at AX5.

### 5. Live Activity / intents
The sim **can** show it (lock screen + Dynamic Island compact). Verified: counting state, 56 pt Leaving now, "Not leaving" link, the one-tap path while locked, and the passed state. The system "Allow Live Activities from WePark?" prompt appears on the lock screen on first use (expected). Not seen: Time-to-go state with "5 more min" (the activity cannot self-update when the app is backgrounded; it sat at `0:00` with the Leaving now button, which is the documented stale state), Not leaving tap, StandBy. Intent `perform` logic: code review of `SharedFullApp/SpotPassDriverIntents.swift` (stale pass-id no-op, source mapping) plus the CI unit tests.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
- **#1: A new Spot Pass link is swallowed while an un-thanked "passed" record is on disk**
  - Where: `DriverFlowController.handle(link:)` (`if pass != nil { return true }`), `restore()` (`.departed` kept for `departedLinger = 30 min` unless `thanksReceived`), `dismissCelebration()` (only clears when thanked).
  - What: after "I'm pulling out", the pass stays `departed` until the neighbor thanks (the normal wait) or 30 min. If the driver scans a *different* Spot Pass in that window, the app presents the old "You just passed a spot." celebration and drops the new token. Tapping Done doesn't help (record stays), and relaunching with the new link shows the celebration again. Repro: arm, depart (Leaving now), `-spotPassFakeThanksAfter 3000`, relaunch with `-spotPassClipURL ...#t=<new token>` -> celebration instead of the new card, twice.
  - Expected: a new token should start its own flow (a finished pass should not shadow a new claim; keep the old record only for the late-thanks purge).
  - Owner: `@ios-engineer`
- **#2: Card screen at large Dynamic Type: pinned footer has no backing and overlaps scrolling text**
  - Where: `Views/SpotPass/Driver/DriverFlowView.swift` / `DriverPassViews.swift` (card/choosing screen).
  - What: at AX5 (iPhone 17) and XXXL (SE) the CTA + "Not leaving soon" are pinned but transparent: body text and chips scroll underneath and show through ("A neighbor will be told..." overlaps the CTA; the 10 min chip slides under it); the pinned block eats ~45% of an AX5 screen, and the header scrolls under the status bar. Everything is reachable by scrolling. Design calls for "text ScrollView above a fixed button" (see `assets/pr170/ax5-card.png`, `se-xxxl-card.png`).
  - Expected: scroll area ends above the footer (or footer gets an opaque/gradient backing), safe-area top inset respected.
  - Owner: `@ios-engineer`
- **#3: PR needs `origin/main` merged before landing**
  - Where: `ios/WePark/WeParkTests/ClipC3Tests.swift` `ClipCopyLintTests.allCopy` (conflicts with #172's `finishedTitle/finishedBody/activitiesOff*` additions); trivial union fixes it, but I only did it locally.
  - Owner: `@ios-engineer`

### 🟢 Minor / nit
- **#4: No DEBUG in-memory secret store for the driver fake mode** (the clip got one in #171). Unsigned `CODE_SIGNING_ALLOWED=NO` builds always hit "couldn't save" and can never arm; QA needs `CODE_SIGN_IDENTITY=-` signing. Owner: `@ios-engineer` (optional).
- **#5: "Set up car auto-ping" guide is reachable (flag on) while `LeavingNowIntent` is non-discoverable and the provider is compiled out**, so the 4-step guide would send people to a Shortcuts action they can't find. Builder already documents the flip-time coupling; add it to the flag-flip checklist.
- **#6: Armed pass has no in-app way back once the cover is closed** (only Live Activity, reminder tap, or re-opening the link). Probably intended; noting since Start Driving is the only in-app trigger.
- **#7: Toasts** ("Thanks. We'll take a look.", Start Driving toast) sit over the top header / near the ASP banner; low-contrast in one captured frame. Cosmetic.
- **#8: AX5 armed screen** hyphenates "auto-ping"/"automati-cally" in the guide row.
- Pre-existing, not this PR: with flag on, the first-run "New to NYC parking?" card overlaps the Report button (seen in the flag-off screenshot too).

### 💡 Out of scope
- Live Activity lingers stale (`0:00`, Leaving now button) when the app never runs after expiry; documented limitation, tap runs the intent which cleans up.

## Device-only / not verified
Live Activity one-tap from a **truly locked, passcode** phone (sim lock has no passcode, so forced-unlock behavior unknown); reminder **notification actions** (long-press expand did not work via AXe; code-reviewed only); "Time to go?" copy with real leave-time-now and "5 more min"; seeker cover open -> driver cover swap live; keychain session adoption from a real clip; real universal link cold launch (AASA); CarPlay/Bluetooth automation; real APNs thanks / `handoff_ended`; Dynamic Island expanded, StandBy; opening Shortcuts in the sim to eyeball non-discoverability.

## What's working
Flag-off really is inert; card -> arm -> reminder -> Live Activity one-tap -> celebration -> thanks -> cancel/report/Start Driving all behave and read in the Spot Pass voice with the indigo look; permission prompt only at the CTA; Welcome matrix matches design 8.2 in all three cases and hands off to the unchanged location priming; notification delegate and category registry changes are careful and merge-safe; CI green with a large new test suite.

## Cleanup
`Constants.swift` reverted (never committed), `Config.xcconfig` removed, app/clip uninstalled, sims shut down, temp SE deleted, derived data deleted, QA branch reset to `origin/main` so the local merge is not pushed.

## Re-verification after follow-ups (2026-11-24)

**Reviewed:** `feat/spot-pass-c2-driver` at `3bb9c135` (merged with main), live on iPhone 17 sim (iOS 26.5) + temp iPhone SE (3rd gen); unsigned Debug build (`CODE_SIGNING_ALLOWED=NO`). `driveModeDefaultEnabled` and `spotHandoffEnabled` flipped locally only (reverted, never committed). Build only, no tests run.
**Verdict:** **MERGE.** Both 🟡 findings are fixed live; no blockers. One new 🟢 nit (AX5 hyphen split) below.

| # | Check | Result |
|---|---|---|
| 1 | Flag-off chrome / More rows | PASS (see caveat) |
| 2 | 🟡#1 new-token repro | PASS (fixed) |
| 3 | 🟡#2 AX5 + XXXL card layout | PASS (fixed) |
| 4 | "Your Spot Pass" More row | PASS |
| 5 | "Auto heads-up" copy, no "ping" | PASS, one 🟢 at AX5 |
| 6 | Driver-cover toast | PASS |
| 7 | Release `strings` | PASS (0 hits) |

### 1. Flag off (ContentView change)
Built with `driveModeDefaultEnabled=true`, `spotHandoffEnabled=false` (the only way to reach More). The ASP banner, locate/search + More toolbar buttons, Start Driving, the Overnight / A Few Hours / Park & Forget tiles and curb polylines all render. The More sheet shows exactly **Report, What the colors mean, Parking 101, Show all parking rules, Settings** (no Spot Pass, no Your Spot Pass). I compared it with `origin/main`'s `moreMenuVisibleRows`: the only difference is the new `driverPassArmed: Bool = false` argument and one `if spotPassEnabled && driverPassArmed` append, so the flag-off rows are identical.
Caveat: I did not build a pure both-off binary or an A/B main build. The browse sheet is hidden behind drive mode in this flag combination, so I did not eyeball it. The code diff is the only evidence for the pure flag-off browse sheet.

### 2. 🟡#1 new link vs finished pass: FIXED
Flag on, `-spotPassUseFakeAPI YES -spotPassFakeThanksAfter 3000`.
- Token A: card -> "Now" -> CTA -> notification prompt (only here) -> Allow -> "Time to go?" (armed). **The unsigned build armed**, so the DEBUG in-memory secret store works (QA #4 closed).
- **Armed + relaunch with token B:** armed screen with the note "You can only help one neighbor at a time. Finish or cancel this pass first." and the pass is kept (`assets/pr170b/c4.png`).
- "I'm pulling out" -> celebration "You just passed a spot." with the dashed pending +5 karma chip. I did NOT tap Done. **Relaunch with token C:** the fresh card "Bodega Cat is waiting for your spot." appears, not the old celebration (`c9.png`). This is the exact repro from the prior report, now passing.
- Done clears: I armed, departed and tapped Done, then relaunched with no URL. The map shows with no cover, and the More sheet has no "Your Spot Pass" row.

### 3. 🟡#2 card layout at large type: FIXED
- AX5 (iPhone 17): the footer has an opaque ink backing and a fade, takes about 13% of the screen and holds the primary CTA only ("Tell Bodega Cat when I leave"). The header row (WePark / flag / X) is pinned, opaque and below the status bar. Scrolled text does not show through the footer or header (`ax5-card.png`). The armed screen at AX5 also scrolls cleanly (`ax5-armed2.png`).
- XXXL (temp SE): the footer is capped, the secondary "Not leaving soon" moves into the scroll area and is reachable (scrolled and confirmed), the header is opaque, and nothing shows through (`se-xxxl.png`). The footer sits flush to the bottom edge on the SE, which has no home-indicator inset (cosmetic, fine).

### 4. "Your Spot Pass" More row: PASS
Absent with flag on and no pass (second pass through More, after Done). Present between Spot Pass and What the colors mean while a driver pass is armed (`c5.png`). Tapping it reopens the armed cover ("You're on, neighbor.").
Observation (not a defect): the one-neighbor note is still shown on that reopen. It is session state that was not cleared, harmless.

### 5. Copy
Armed screen and celebration say "Auto heads-up when you start your car" with the subtitle "Tell your neighbor the moment your phone connects to your car." No "ping" appears anywhere I visited. The Shortcuts guide sheet itself was not opened this pass, so its reworded title and intro are covered only by `ClipCopyLintTests` (the banned-word lint) from the diff.

### 6. Toast
Report -> Spam shows "Thanks. We'll take a look." below the pinned header, clear of the logo and buttons (`toast.png`; the pass is also shown ended). The map-level Start Driving toast remains on the shared `ToastHostView` as documented (not exercised).

### 7. Release binary
A Release simulator build's `WePark.app/WePark` has **0** hits for `DebugInMemoryHandoffSecretStore` or `spotPassDebugFakeSecret`. A control grep of the Debug `WePark.debug.dylib` gives 6, so the grep is meaningful.

### New findings
- 🟢 **#9: AX5 hyphen split in the guide row.** The row title "Auto heads-up when you start your car" breaks mid-word at AX5 ("heads-u / p when"; `ax5-armed2.png`). The non-breaking hyphen stops the break at the hyphen but the word then splits by character. The car icon also touches the text. The row is reachable and legible. Fix options: allow a normal hyphen at AX sizes or reduce the row's horizontal padding. Owner: `@ios-engineer`, optional polish; this was the same area as QA #8, so it is only a partial win.

### Prior findings status
- #1 (new link swallowed): FIXED. #2 (card layout): FIXED. #3 (main merge): FIXED, merged and CI green. #4 (no debug secret store): FIXED. #5/#8 (copy and AX5): copy fixed, AX5 residual = #9 above. #6 (no in-app way back): FIXED via the "Your Spot Pass" row. #7 (toast): driver cover FIXED, map toast intentionally left.

### Not verified
Live Activity and lock-screen behavior after the follow-ups (unchanged and not retested; the sim showed "Lock-screen countdown is off" because Live Activities were not enabled for the unsigned build, which also exercised the new off-copy). Pure both-flags-off build and browse sheet (see caveat 1). Map Start Driving toast. Opening the Shortcuts guide sheet.

### Cleanup
`Constants.swift` reverted, `Config.xcconfig` removed, app uninstalled from the iPhone 17 smoke sim, all sims shut down, temp SE deleted, derived data deleted.
