# Community 2.0 Phase 4a — leaving-soon handoff + My Car redesign — QA Pass 1 — 2026-09-01

**Reviewed:** PR #98, branch `ios/community-phase4a` at `a819309d`, against `docs/community-2.0-reconciliation-spec.md`
§3 Phase 4 (4a slice), roadmap row S10, `docs/design/community-2.0-hero-gap-inventory.md` WP4,
`design/prototype.html:281-335`, `design/screenshots/15-my-car.png`.
**Verdict:** 🟡 MERGE-AFTER-MAC-GATE

## Summary

This is a clean, well-scoped PR: exactly the three files it claims to touch
(`Views/ParkedCarDetailView.swift`, the new test file, `docs/community-1.0-direction.md`), zero
`ContentView.swift`/mount-chain changes, flag-off parity holds structurally for every new element,
and the identity-gate reuse is genuinely the QA-cleared "sheet nested in an already-presented
sheet" shape from PR #96, not the at-risk pattern. Test count checks out exactly (1111 → 1137).
Copy is verbatim, the direction-doc supersede marker is accurate and appropriately restrained, and
all three self-flagged deviations turn out to be handled correctly (see below). Two real, narrow
bugs surfaced on a deeper trace that the PR's own risk framing undersells — both are dark-shipped
behind `communityEnabled = false` today, so neither blocks this merge, but both need to close before
the flag ever flips.

## Acceptance criteria checklist

- [x] AC-P4.1 (payload: exact car position, `leaving_minutes` present, server-derives `expires_at`)
      — verified by code read (`leavingSoonInsertParams` uses `parkedCar.latitude/longitude`,
      `insertCrowdPin` call passes `leavingMinutes`) + cross-referenced against HANDOFF's
      2026-08-27 "Gate 1" entry (server-derived expiry live in prod, verified against tampered
      client payloads with delta 0s). See Finding #3 for a wording nit on how this is described.
- [x] Flag-off byte-identical — verified structurally: every new render branch
      (`sweptStatusPin`/`offsetChipsRow`/`leavingSoonCard`/the nested identity `.sheet`) is gated
      on `AppConstants.communityEnabled` (currently `false`), traced individually. Not
      screenshot-verified (no Xcode in this environment) — Mac gate should confirm visually.
- [x] Identity gate shows once, shared gate — `ParkedCarDetailLogic.shouldGateLeavingSoonPost`
      delegates to the exact same `CommunityIdentityInterception.shouldShowIdentitySheet` /
      `CommunityIdentityGate` every other contribution path uses; 5 tests cover all combinations.
- [x] Swept badge presence logic — `ParkedCarDetailLogic.liveSweeperPin` correctly excludes wrong
      type, wrong segment, nil segment, expired, resolved, and flag-off; 7 tests, all real
      behavioral assertions (not tautological).
- [ ] Offset chips reflect/correctly toggle the same `ReminderOffsets` Settings controls —
      **directionally correct, but a same-session cross-sheet race can silently drop an edit.**
      See Finding #2.
- [x] "I left — clear pin" unchanged — diff shows only a trailing doc comment added to this
      button; the view/behavior itself is byte-identical.
- [x] `docs/community-1.0-direction.md` §4 superseded-marker present, dated correctly, points to
      the reconciliation spec, and explicitly preserves the original paragraph "for the historical
      record" rather than deleting it — matches spec §5's requirement and this repo's
      link-don't-delete convention.

## The three flagged deviations — ruled

**(a) "Claim button not built."** Verified correct, non-issue. `claim_pin` consumption already
shipped in PR #97 (S9, `c581d65f`): `CrewFeedSection.leavingSoonAction` and
`PinDetailSheet.claimSection` both call `CommunityPinService.claimPin(pinId:)`, the real RPC, with
`false` handled as the expected "someone beat you to it" outcome (not an error state), matching spec
§2.10/§3 Phase 4 exactly. The roadmap's S10 row wording ("Leaving-soon picker + claim button") is
simply stale — it predates S9 pulling claim-consumption forward. Nothing is missing for the
leaving-soon consumer side. The PR's own caution here (flag rather than silently drop or silently
rebuild) was the right call and turned out to be correct.

**(b) Nested `.sheet(isPresented:)` local to `ParkedCarDetailView`.** Verified: this is genuinely
the safe shape PR #96 pass 1 Finding #2 cleared ("nesting one sheet inside an already-presented
sheet's own content is the standard, safe shape"), not the at-risk ContentView-level pattern that
finding was actually about. Confirmed by tracing the presentation chain: `ParkedCarDetailView` is
itself presented via `ActiveSheet.parkedCarDetail` inside ContentView's single
`.sheet(item: $activeSheet)` (same presenter `ReportSheet` uses via `ActiveSheet.reportPin`), and
the new `IdentitySheet` nests inside `ParkedCarDetailView`'s own already-presented content — an
exact structural match to `ReportSheet.swift:547`'s cleared pattern, using the identical
`Binding(get: { pendingIdentityAction != nil }, set: { if !$0 { pendingIdentityAction = nil } })`
shape (no `onDismiss:` needed — the binding's own setter handles swipe-to-dismiss).
Dismiss/cancel/swipe traced: swiping away `IdentitySheet` without tapping Save/Skip drives the
binding's setter to `false`, which clears `pendingIdentityAction` without ever invoking the deferred
`performPostLeavingSoon()` closure — no post occurs, no half-committed state, `leavingMinutes`
selection is preserved and the CTA card returns to its normal (not-yet-posted) state for a retry.
This matches `ReportSheet`'s own already-cleared behavior exactly. No new risk introduced.

**(c) Offset-chips-not-threaded (stale Settings display in same session).** Real, but the PR's own
description of it ("display-only... not a functional bug") is not fully accurate. See Finding #2 —
it can become a genuine lost-update, not merely a stale read.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: Leaving-soon "posted" confirmation state doesn't survive a sheet dismiss/reopen, so a user
  can re-post a duplicate `leaving_soon` pin while the first one is still live.**
  - Where: `Views/ParkedCarDetailView.swift` — `@State private var leavingSoonPosted` /
    `leavingSoonCard`.
  - What: `leavingSoonPosted` is plain view-local `@State`, reinitialized to `false` every time
    `ParkedCarDetailView` is reconstructed (any dismiss-then-reopen of My Car). Nothing checks
    `pinService?.visiblePins` (the exact source `sweptStatusPin` already reads) for an existing,
    still-live `leaving_soon` pin authored by this device for this car before deciding whether to
    show the chips/CTA or the "crew's been told" confirmation. There's also no server-side
    constraint preventing a second insert — spec §2.8's "naturally self-limiting, one active pin
    per parked car" is a stated assumption, not an enforced unique index
    (`03-community-2.0-schema.sql` has no such constraint).
  - Expected: reopening My Car mid-countdown should re-derive the confirmation state from live pin
    data, the same way the swept badge does, or otherwise durably remember "already posted for this
    car" so the user can't accidentally double-post.
  - Repro: flip `AppConstants.communityEnabled = true` locally, park, open My Car, tap a leaving
    chip and post (confirmation renders), dismiss the sheet, reopen My Car — chips/CTA are back as
    if nothing was posted; tapping again posts a second, independent `leaving_soon` pin for the same
    spot with a different countdown and a separate `claimed_by` race.
  - Owner: `@ios-engineer`.

- **#2: An offset-chip edit in My Car can be silently reverted by a later, unrelated Settings edit
  in the same foreground session — this is a lost-update bug, not just a stale-display cosmetic
  issue as the PR describes it.**
  - Where: `Views/ParkedCarDetailView.swift` `offsetChipsRow`'s `.onChange(of: offsets)` (new) +
    `Views/SettingsView.swift:125-128` (pre-existing, unchanged) `.onChange(of: offsets)`.
  - What: `ParkedCarDetailView` loads/saves the same global `ReminderOffsets` `UserDefaults` blob
    directly, bypassing `ContentView`'s cached `@State reminderOffsets` (the PR discloses this
    choice explicitly). `ContentView`'s cache is only refreshed on `scenePhase == .active`, not on
    My Car's sheet dismiss. `SettingsView.onChange(of: offsets)` unconditionally
    `ReminderOffsets.save(newOffsets, to: .standard)`s the *entire* bound struct on every toggle.
    Sequence: (1) edit a chip in My Car → saved correctly to `UserDefaults`; (2) dismiss My Car;
    (3) open Settings (still same session, no backgrounding) → Settings renders `ContentView`'s
    stale pre-step-1 copy; (4) toggle any *different* Settings switch → Settings writes back its
    stale full struct, silently erasing the change made in step 1. Actual notification *scheduling*
    stays correct at any instant (`NotificationScheduler.schedule` re-reads `UserDefaults` fresh
    every call — confirmed by reading its guards), but the user's chosen preference itself can be
    silently discarded, which is worse than what "display-only" implies.
  - Expected (per the PR's own suggested fix, which is the right shape): a one-line resync of
    `ContentView`'s cached `reminderOffsets` in the My-Car sheet's dismiss handler, closing the
    window entirely.
  - Repro: flag on, My Car → toggle "30 min" on → dismiss → Settings → toggle "Night before" on →
    dismiss → reopen My Car: "30 min" chip is off again.
  - Owner: `@ios-engineer`.

Both #1 and #2 are fully inert in production today (`AppConstants.communityEnabled = false`), so
neither blocks this merge — but both should be closed before the flag is ever flipped to `true`
(S11+), not discovered live during the eventual drive-test/TestFlight flip.

### 🟢 Minor / nit

- **#3: PR description and one test's docstring overclaim what's actually proven about
  `expires_at`.** `CommunityPinService.insertCrowdPin` (pre-existing Phase 2 code, untouched by this
  PR) still computes and sends a client-side `expires_at` in the POST payload for every ephemeral
  type including `leaving_soon` (`CommunityPinService.swift:1552-1572`,
  `Self.ephemeralTTLSeconds(for:leavingMinutes:)`). The PR body states "this client never sends
  one," and `ParkedCarDetailLeavingSoonInsertParamsTests.testPayloadShape_hasNoClientSuppliedExpiryField`
  only Mirror-inspects the *new* `LeavingSoonInsertParams` struct (which was designed without an
  expiry field to begin with) — it does not, and structurally cannot, prove anything about the real
  network payload built one layer up in `insertCrowdPin`. Functionally this is fine: HANDOFF's
  2026-08-27 "Gate 1" entry confirms the server-side `derive_pin_expiry` trigger is live in
  production and was verified to override tampered client `expires_at` values with delta 0s — the
  server is genuinely authoritative. But the claim and the test's real coverage should be described
  accurately (client sends a value; server overrides it), not as "never sends one."
  - Where: PR #98 body (Claim-button section preamble), `Services/CommunityPinService.swift:1552-1572`
    (pre-existing), `ParkedCarDetailPhase4aTests.swift` `testPayloadShape_hasNoClientSuppliedExpiryField`.
  - Owner: `@ios-engineer`, wording/docstring only — no functional change needed.

### 💡 Out of scope (logged, not fixed)

- Nothing new beyond what spec §5 already tracks. WP5 (proactive confirm-prompt card) and the
  APNs pipeline (Phase 4b) remain correctly untouched by this PR, as scoped.

## Smoke tests run

No `xcodebuild`/`xcrun simctl` available in this environment (Linux VPS) — this is a cold, adversarial
code read against the diff, cross-referenced against `origin/main`, the applied production schema
(`supabase/03-community-2.0-schema.sql`), HANDOFF's Gate-1/Gate-2 entries, the prototype source, and
the design screenshot. Specifically verified by direct comparison (not trusted from the PR body):

- `git diff origin/main..a819309d --stat` — file list matches the PR's claimed 3-file touch list
  exactly; no `ContentView.swift`/`MapViewRepresentable.swift`/`BrowseNavigationSheet.swift`/
  `ReportSheet.swift` changes.
- Test count: `git grep -c "func test"` sums to 1111 on `origin/main`, 1137 on
  `origin/ios/community-phase4a` — exactly +26 as claimed.
- Flag-off render paths individually traced: `sweptStatusPin` (via `liveSweeperPin`'s own
  `communityEnabled` guard), `offsetChipsRow` (`if AppConstants.communityEnabled, remindMe`),
  `leavingSoonCard` (`if AppConstants.communityEnabled`), and the nested identity `.sheet` (can only
  present via `pendingIdentityAction`, which can only be set from `submitLeavingSoon()`, which is
  only reachable from the flag-gated CTA) — all four confirmed structurally unreachable with the
  flag off.
- `ParkedCarDetailView` presentation chain confirmed: `ContentView.swift:1145-1146`
  (`case .parkedCarDetail(let car): ParkedCarDetailView(...)`) inside the single
  `.sheet(item: $activeSheet, ...)` at `ContentView.swift:881` — same presenter `ReportSheet` uses
  (`case .reportPin` at `ContentView.swift:1280`). The new nested `.sheet(isPresented:)` matches
  `ReportSheet.swift:547`'s already-cleared pattern token-for-token.
  `NotificationScheduler.schedule`/`cancelAllThenSchedule` guards read directly
  (`Services/NotificationScheduler.swift:95,98,156,159`) to confirm mute-flag and
  `notifyOnRestriction` checks happen inside the scheduler regardless of caller — the new
  `offsetChipsRow.onChange` reschedule call is semantically equivalent to
  `ContentView.handleReminderOffsetsChange()`'s.
- Direction-doc edit diffed in full: dates, pointer target, and "kept for the historical record, not
  the current answer" framing all verified accurate against spec §1/§5.
- `design/screenshots/15-my-car.png` visually inspected — implementation's layout order (status →
  parked-ago → swept badge → remind toggle+chips → rules → leaving-soon card → clear pin) matches.
- Copy diffed verbatim against `design/prototype.html:323-331`: card title, subcopy (including the
  em dash and "first come, first served"), and CTA label ("Leaving in {N} min — tell the crew",
  U+2014 em dash) all match exactly. No forbidden words ("avoid"/"ticket"/"fine"/"evasion"/"dodge")
  present anywhere in the new copy.
- Swept-badge color literal (`Color(red: 48/255, green: 209/255, blue: 88/255)`) confirmed against
  the canonical `#30D158` `sweeper_passed` palette entry, spec §6 appendix.

**Not verified (requires Xcode/simulator — Kevin's gate):** actual compile, actual live rendering
(screenshot comparison of My Car both flag-on and flag-off), actual tap-through of the leaving-soon
post + identity-sheet flow, actual pin appearing on the map via realtime.

## What's working

- Scope discipline is excellent: exactly the claimed 3 files touched, zero incidental drift into
  `ContentView.swift` or any other Views file, and the identity-gate reuse is a textbook application
  of a pattern this project's own QA history already vetted rather than a fresh risk.
- All three self-disclosed deviations were handled honestly — flagged rather than silently resolved
  either way — and two of the three (claim button, nested sheet) turn out to be genuine non-issues
  on independent verification, which is the ideal outcome of that discipline.
- Copy, palette, and layout ordering are verbatim/faithful to the prototype and screenshot 15.
- Test suite is real behavioral coverage (segment/type/expiry/resolved/flag-off matrix for the swept
  badge; all 4 identity-gate combinations; payload-shape structural guard), not tautological
  scaffolding, and the count is exact.
- The privacy-rule comment at the insert site is accurate and correctly reasoned against both
  HANDOFF's standing rule and spec §2.1 — this is exactly the kind of write-path-adjacent commentary
  this repo expects and often gets skipped.
- Direction-doc supersede marker is a model example of the "link, don't delete" convention — dated,
  pointed, and honest that the reversal only worked because it kept the original deferral's own
  free/non-reservation reasoning intact.

## Kevin's gate (right-sized)

This PR touches only `ParkedCarDetailView.swift` among Views — no mount-chain files
(`MapViewRepresentable.swift`, `ContentView.swift`, `Views/DriveMode*.swift`, no
`.safeAreaInset`/overlay-attachment code). It does **not** need the full #31-class toolbar/ASP-banner
regression check. But it is a visible sheet redesign shipping dark behind a flag that will flip
later, so:

1. **Build + test.** `xcodebuild ... build test` on a real iPhone 17 sim UDID — confirm compile and
   **1137/0**.
2. **Flag-off screenshot.** With `communityEnabled` at its shipped `false`, open My Car on a parked
   test pin — confirm it is visually identical to the pre-S10 sheet (plain toggle, no chips, no
   badge, no leaving-soon card).
3. **Flag-on live smoke.** Flip `communityEnabled = true` locally only, park, open My Car — confirm
   layout order matches `design/screenshots/15-my-car.png`, tap through the leaving-minute chips,
   post (first time should show the identity sheet), confirm "The crew's been told" renders, and
   confirm the pin appears on the map via the normal realtime pipeline.
4. **The two Significant findings, live:** (a) dismiss and reopen My Car right after posting — does
   the app let you post a second leaving-soon pin for the same still-active countdown? (b) edit an
   offset chip in My Car, dismiss, open Settings, toggle something else, reopen My Car — does the
   first chip's state survive? Use these to decide whether Findings #1/#2 get fixed now or ticketed
   for S11 before the flag actually flips for real users — either is acceptable, but it shouldn't be
   discovered for the first time during the eventual drive-test flip.
5. Flip back to `false` before merge/TestFlight, per the flag-off screenshot in step 2.
