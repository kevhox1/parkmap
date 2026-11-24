# PR #169 QA: Spot Pass clip follow-ups (from PR #168 QA)

**Reviewed:** branch `fix/spot-pass-clip-followups`, Debug + Release sim builds (`CODE_SIGNING_ALLOWED=NO`), iPhone 17 sim iOS 26.5 and a temp iPhone SE 3rd gen. No `xcodebuild test`.
**Date:** 2026-11-24
**Verdict:** MERGE (no findings above minor). Armed-screen items (#2 armed, #4, #5) could not be walked live in the unsigned sim and rest on code and unit tests; the device pass from the PR #168 report remains the real gate for those.

## Summary
Every follow-up I could reach live behaves as claimed. A failed keychain write now lands on the calm "Open the WePark app to finish." screen. The AX5 and XXXL choosing screens pin only the primary CTA on an opaque scrim with no text collision, including on the SE. The shared `asp-2026.json` move did not regress the main app (it is in the app bundle, the clip bundle and the embedded clip, and the ASP banner loads). The Release clip is 5.2 MB with no DEBUG fake strings.

## Checklist
- [x] #1 keychain failure: fake claim, tap "Tell Bodega Cat when I leave", allow notifications. Result: "Open the WePark app to finish." with "We couldn't set up your reminder here. Get WePark and scan again." and "What's WePark?". No armed screen, no dead button (`assets/pr169/keychain-fail-openapp.png`).
  - Code: `finishArming` guards on `save` returning false, then best-effort `api.cancel(id:secret:)` (the fake API records `calls.append("cancel")`), `endActivityIfStarted(.ended)`, `secrets.clear()`, `phase = .openApp`. `pass` is never set and reminders are scheduled only after this guard, so nothing is stored or scheduled. Server cancel and Live Activity end are CODE-verified, not observed (no log surface for the fake call list in the running clip; no lock screen on the sim).
  - `pullOut` with no secret sets `sendFailed` and moves to `.pullingOut` ("Couldn't send. Try again."); `confirmCancel` toasts `cancelFailed`. Code-verified only: the armed screen cannot be reached in the unsigned sim (the failed save now correctly prevents arming), so these paths are unit-test territory (CI green).
- [x] #2 AX pinned CTA, live:
  - iPhone 17 AX5 (`iphone17-accessibility-...png`): only the primary CTA is pinned (about 13% of height), opaque ink scrim with a fade above; scrolled subline is cut cleanly at the scrim, no overlap.
  - iPhone 17 XXXL: primary, reassurance and "Not leaving soon" pinned (about 23%, under the 30% rule), opaque, no collision.
  - SE XXXL and SE AX5 (`se-*.png`): primary only pinned (the rule unpins the secondary because SE overflows); scroll text fades under an opaque scrim, no collision. (A "Ready for Apple Intelligence" system banner in the SE XXXL shot is sim noise.)
  - Default size iPhone 17 (`default-choose.png`): scrim seam is a soft fade into the darker pinned area; visible as a slight tone step, not a hard line. Acceptable.
  - Not verified live: the armed screen at AX (unreachable unsigned). It uses the same pinning rule per the diff.
- [x] #3 ASP holidays:
  - `asp-2026.json` contains `2026-11-26 Thanksgiving Day`. `nextWindow` skips `isSuspended` ET days, so Thanksgiving can never be "Next" nor "cleaning now". Unit tests cover it (CI green). Sim clock not set; the fake tile flow was not exercised for the rendered "Next" date. Code-verified.
  - REGRESSION check passed: `asp-2026.json` is present in `WePark.app`, `WeParkClip.app`, and `WePark.app/AppClips/WeParkClip.app`. Main app launched with flag off and onboarding skipped: map renders, yellow "ASP in Effect Today" banner (Tuesday Nov 24, not a holiday), toolbar, search sheet, process alive, no crash (`main-app.png`).
- [x] #4 second scan of a different pass: not live (needs armed). Code: `showsOtherPassNote` set only when active pass is `.armed` and the stored `tokenFingerprint` differs; nil fingerprint (older saves) shows no note; never cancels or replaces; reset on end. Fingerprint is 8 bytes of SHA-256, not the token.
- [x] #5 leave_at flip: not live (needs armed). Code-verified only. Recommend one device check.
- [x] #6 Release clip: 5.2 MB (du), `strings` 0 hits for `spotPassUseFakeAPI`, `spotPassClipURL`, `FAKEFAKE`, `spotPassFakeLeaveSeconds`. `asp-2026.json` present in the Release clip.

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1 (green): the keychain-failure screen says "We couldn't set up your reminder here."** That copy is shared with `noID` and is slightly off when the real cause is a secret-store failure, but the instruction (open the app / scan again) is right. Optional.
- **#2 (green): tiny gray artifacts at the top edge of the AX5 scrim on iPhone 17** (two small dark squares at the fade, likely chip or scrollbar tops peeking through the 14 pt fade). Cosmetic; one pixel-level look on a device.
- **#3 (green): a failed save also calls server `cancel`.** The PR flagged this as beyond "like noID". It is sensible (a neighbor is not left waiting). Note that `cancel` result is ignored with `try?`; if it also fails the pass expires server-side by TTL. Fine.

### Out of scope
- The sim still cannot walk armed, depart, celebration or thanks (keychain -34018). The previous recommendation stands: add a DEBUG in-memory secret store to fake mode so QA can reach armed screens unsigned.
- 2026-only calendar: after year end the ASP data needs a refresh (the footer "Always check the posted signs." stays).

## Smoke tests run
- `df -h /`: 12 GB then 9.5 GB free before builds (above the 8 GB floor).
- Debug `WePark` scheme build and Release `WeParkClip` build: both succeeded.
- Clip claim to calm "Open the WePark app" (live, screenshot read).
- Choosing screen at default, XXXL, AX5 on iPhone 17; XXXL and AX5 on temp SE (screenshots read).
- Main app launch flag-off, ASP banner read; `find` of `asp-2026.json` in all three bundles.
- Release binary `strings` and bundle size.
- Cleanup: Config.xcconfig removed, apps uninstalled, sims shut down, SE device deleted, derived data deleted.

## What's working
The failed-save path is exactly the calm failure the first report asked for, and the AX layout is far better: the primary action is always reachable and nothing renders behind it. Moving the ASP data to Shared gives one source of truth without touching the app's service.
