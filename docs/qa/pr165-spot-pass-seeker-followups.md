# PR #165 QA: Spot Pass seeker follow-ups (F1/F2/F3/F5)

**Reviewed:** `fix/spot-pass-seeker-followups` (CI green), against `docs/qa/pr162-spot-pass-seeker.md` and `docs/design/spot-pass-design.md`
**Verdict:** MERGE (with two optional follow-ups, no blockers)

## Summary
Built with `spotHandoffEnabled` and `driveModeDefaultEnabled` locally true (never committed) and run live on the iPhone 17 simulator and a temporary iPhone SE (3rd gen), iOS 26.5, using `-spotPassUseFakeAPI YES`. F1, F3 and F5 behave as the PR describes. F2 is correct and inert with the flag off. The one real-world side effect, a transient NULL zone on the community row, is low severity. No findings above yellow.

## Acceptance checklist
- [x] **Flag OFF unchanged (code review).** `registrationWanted = community || spot`. With spot false it equals `communityEnabledProvider()`. `attemptUpsert` guard becomes `zoneId != nil || spotHandoffEnabledProvider()`, which is `zoneId != nil` with spot off, so it matches the old `let zoneId = currentZoneId` guard. The `UploadKey.zoneId` type change to optional and the payload helper only matter when nil. The PR adds tests for both-off, community-only with no zone, spot-only, both-on and the nil-zone payload. All Spot Pass UI is behind the existing flag. I did not run a flag-off launch on the simulator, only the code review. The flag-off build is the main-branch default and CI is green.
- [x] **F1 own rationale.** First "Create my Spot Pass" on a fresh install shows the indigo "Get a heads-up." sheet (`assets/pr165/f1-rationale.png`). No street-cleaning copy, no green/orange/red. Tapping "Not now" creates the pass (QR screen). `notificationRationaleSeen` is persisted as true (checked in the app's plist). After the explainer has been seen, re-entering Spot Pass (same session and after a relaunch) goes straight to a pass with no rationale.
- [x] **F1 at AX5.** The sheet auto-expands, the body wraps to about seven lines, and Allow/Not now are reachable by scrolling. Nothing is truncated (`ax5-rationale.png`, `ax5-rationale-buttons.png`).
- [x] **F5 badge at AX5 (iPhone 17).** At rest the wordmark, alias and countdown are visible and "Stop waiting" is not pinned. It is the last item of the scroll content (`ax5-badge-top.png`, `ax5-bottom.png`). "WePark" is single-line and unbroken.
- [x] **F5 SE at XXXL.** Button is in scroll content, alias and countdown visible at rest, button reached by scrolling (`se-xxxl-top.png`, `se-xxxl-bottom.png`).
- [x] **F5 SE at default (large).** Button is pinned with clear space above it and an opaque bar (`se-default-armed.png`). It does not touch the card edge.
- [x] **Regression, full fake flow.** Created, then armed ("A neighbor's on it", leaving in about 30 min), then departed ("Spot opening up"), then outcome ("Thanks, neighbor"), then "+3 karma". Indigo only. QR screenshot decoded with CoreImage to `https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_-`.
- [x] **F3.** The diff shows "ping" removed from user-facing strings in 5.1 caption, 5.4 (3 spots), 8.3 and 9.2. The remaining "ping" occurrences are in the banned-words rule. The live explainer step 3 reads "You get a heads-up the moment they pull out."

## F2 assessment (zone-less token upsert)
`send-community-push` targets by exact match: `.from("device_push_tokens")...eq("zone_id", pin.zone_id)`, and skips pins with null zone. A row with `zone_id` NULL therefore receives no community push. `send-handoff-push` keys on user_id and environment, so spot alerts work zone-less.

The caller `updatePushZoneFromParkedCarOrLocation()` in `ContentView.swift` is guarded by `AppConstants.communityEnabled`. So:
- Spot on, community off: `updateZone` is never called, and the row stays NULL-zone. That is correct and harmless.
- Both on: `updateZone(nil)` fires only when neither a parked car nor a location resolves (cold launch before the first location fix, or permission denied). Previously that was a no-op that left the old zone in place. Now it upserts NULL, so the device drops out of community fan-out until the next resolve, a few seconds on a normal launch. A user with location permanently denied and no parked car loses community pushes, but only when spot is on. They also previously got zone only from a parked car.
- Only a silent content-available push is affected. No user-visible state is lost.

**Severity: 🟢 minor.** It is gated behind a dark flag and transient. No action needed before merge.

## Findings

### 🟡 Significant
None.

### 🟢 Minor
- **#1: Prefer not to clobber an existing zone with NULL when community is also on.** In `PushRegistrationService.updateZone`, when community is on and spot is also on, skip the NULL upload if a non-nil zone was already uploaded. This is the strict improvement over the PR's accepted tradeoff. Owner: `@ios-engineer`. Optional.
- **#2: Rationale "Not now" is clipped at SE + XXXL.** At the `.medium` detent on iPhone SE at XXXL, "Not now" sits at the clipped bottom edge. The sheet scrolls and can be pulled to `.large`, but a label-based tap on "Not now" missed until I expanded it (`interactiveDismissDisabled(true)` means the user must find the button). Not truncated, only below the fold. Consider starting at `.large` when the dynamic type size is XL or larger. Owner: `@ios-engineer`.
- **#3: SE default pinned bar slightly clips the card's bottom border.** In the armed state on SE (default size) the card is taller than the visible area, so the card's rounded bottom edge is hidden under the opaque button bar at rest. Alias and text stay visible. Cosmetic.
- **#4: Karma chip truncates ("Helped...") at SE + XXXL in the QR state.** Pre-existing chip, not part of this PR. Logged only.

### Out of scope (logged)
- The Report sheet truncates at AX5 ("What's happ...", "Help your neigh..."). This is an existing feature, not part of this PR.
- Real APNs delivery and the `aps.category` push path are device-only. The PR's routing tests cover the `kind`/`handoff_id` parsing. I did not run any tests (build only, per the brief).

## Smoke tests run
- Built the WePark scheme for the simulator with flags flipped locally. Build succeeded.
- Installed on iPhone 17 smoke and a temporary SE, skipped onboarding via defaults, granted location, set location.
- Walked: More, Spot Pass, Create, rationale, Not now, QR, armed, departed, outcome, karma. Relaunch and re-entry.
- AX5 on iPhone 17 (badge top and scrolled bottom, rationale sheet). XXXL and default on SE.
- QR decoded from a screenshot with CoreImage.
- Cleanup: flags reverted, `Config.xcconfig` removed, app uninstalled, simulators shut down, temp SE deleted, derived data deleted. Only the report and `docs/qa/assets/pr165/` are committed.

## What's working
The new rationale is on-brand and scrolls cleanly at AX5. The pin-or-scroll logic for "Stop waiting" is simple and works at both extremes. The F2 change is minimal and keeps the flag-off path identical.
