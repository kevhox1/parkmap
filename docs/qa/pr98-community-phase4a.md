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

---

# Pass 2 — 2026-09-01

**Reviewed:** fix commit `d7de770a` (on top of `a819309d`), against Pass 1's Findings #1/#2/#3.
Verified cold via `git show`/`git diff a819309d..d7de770a`, not the worktree's disk state.
**Verdict:** ✅ MERGE-AFTER-MAC-GATE (upgraded gate — see below)

## Summary

All three Pass 1 findings are genuinely fixed, not papered over. Finding #1 is now derived from
truth (`pinService.visiblePins`) instead of transient `@State`, with a sensible own-author +
segment-or-tight-radius predicate and 13 real boundary-case tests. Finding #2's fix is a single,
correctly-placed line in `ContentView`'s existing dismiss closure, with a red-if-regressed test that
faithfully reproduces the original bug's mechanism. Finding #3's wording is corrected everywhere it
appeared, plus a new test now inspects the actual wire payload instead of a same-file proxy struct.
Test count is exact (1154). One new, narrow, non-blocking observation on Fix #1's latch (below). The
one process-relevant fact: this fix commit touches `ContentView.swift` for the first time in this
PR's life, which — per this role's own mount-chain rule — upgrades Kevin's gate regardless of how
small the touch is.

## Fix 1 — `ownLiveLeavingSoonPin` derivation

- **Own-author-only:** `pin.authorId == authorId` where `authorId` is
  `pinService?.authService?.currentUserId` — confirmed `authService: SupabaseAuthService?` is
  non-private on `CommunityPinService` and `currentUserId: UUID?` has a public getter, so this
  compiles and reads the real signed-in user. `testOtherAuthorPin_evenIfMatchingSegmentAndLive_returnsNil`
  proves a same-segment, live, correctly-typed pin from a *different* author never suppresses the
  CTA — the right direction (never over-suppress on someone else's post).
- **Live = unexpired AND unresolved:** `pin.resolvedAt == nil && (pin.expiresAt.map { $0 > now } ?? true)`
  — identical shape to `liveSweeperPin`'s existing (already-cleared) pattern. Confirmed via
  `testExpiredOwnPin_returnsNil` / `testResolvedOwnPin_returnsNil`.
- **Segment match OR 30m geo fallback:** correctly ordered (segment match short-circuits before the
  distance calc). 30m is tight enough in practice because the own-author filter already runs first —
  a *different* nearby car scenario can't reach the radius check as a false-positive suppressor
  unless it's the *same* signed-in user's pin, and this app carries exactly one active `ParkedCar`
  per account, so "two of my own cars near each other" isn't a real scenario today. It's loose enough
  for fraction drift: the pin's lat/lng is written from the same raw `parkedCar.latitude/longitude`
  this check re-reads, so real-world distance is ~0m in the common case — the radius exists mainly to
  survive a segment-ID mismatch (car's `detectedSegmentID` resolved differently at read time than at
  post time), for which 30m (tighter than the file's own 35m `positionFractionSearchRadiusMeters`
  precedent) is a reasonable, consistent choice.
- **`isLeavingSoonPosted = derived OR transient`:** confirmed exactly
  `justPosted || ownLivePin != nil`, covered by all 4 combinations in
  `ParkedCarDetailIsLeavingSoonPostedTests`.
- **13 new tests, boundary cases:** confirmed 9 (`ParkedCarDetailOwnLiveLeavingSoonPinTests`) + 4
  (`ParkedCarDetailIsLeavingSoonPostedTests`) = 13, covering: live match via segment, live match via
  geo-fallback-only, far-away/no-segment, other author, expired, resolved, wrong pin type, nil
  authorId (no session), flag-off. All are real behavioral assertions against the actual JSON-decode
  fixture path (`makePin`), not tautological.

**🟢 New minor observation (not in Pass 1, not blocking):** `leavingSoonJustPosted` never resets to
`false` within a live view instance — it's a one-way latch, by design, per its own doc comment
("resets to `false` on every sheet reconstruct, which is fine"). That's true for the dismiss/reopen
case (Finding #1's actual bug), but if a user keeps My Car open continuously past the posted pin's
own TTL (e.g. picks 5 min and leaves the sheet open through the full ~8-minute expiry window), the
confirmation state will keep showing "The crew's been told" indefinitely — `ownLiveLeavingSoonPin`
correctly flips back to `nil` once the pin expires, but `isLeavingSoonPosted`'s `OR` means the stale
`justPosted` latch still forces the confirmation state, denying the user a legitimate second post
without closing and reopening the sheet. Narrow (requires holding the sheet open the entire TTL),
safe-direction (a UX annoyance, not a duplicate-post or data-integrity risk — the opposite failure
mode from Finding #1), and easy to close later (e.g. reset `leavingSoonJustPosted = false` once
`ownLiveLeavingSoonPin` is observed non-nil, or drop the transient once `visiblePins` has had one
chance to merge). Not required before merge or before the flag flip. Owner: `@ios-engineer`,
whenever convenient.

**🟢 Also minor:** the coordinator's ask for "radius edge" coverage isn't literally present — the
two geo tests use a comfortably-inside distance (~10m) and a comfortably-outside one (~220m), not a
value straddling the 30.0m `<=` boundary itself. The logic is simple enough (`distance <= 30.0`)
that this is low-risk, but a `29.9m` / `30.1m` pair would close the gap precisely. Owner:
`@ios-engineer`, optional.

## Fix 2 — `ContentView` onDismiss resync

- **Location confirmed:** the new line is the *first* statement inside the **existing**
  `.sheet(item: $activeSheet, onDismiss: { ... })` closure (`ContentView.swift:881` unchanged as the
  attachment point) — this is the single shared dismiss handler for every `ActiveSheet` case, not a
  new modifier or a new sheet. Fires on dismissal of *any* sheet (My Car, Settings, Report, Block
  Detail, etc.), not just the two involved in the bug.
- **Perf:** a `ReminderOffsets.load(from:)` call is a 5-bool JSON decode from `UserDefaults` — trivial
  cost, only on sheet-dismiss events (not per-frame/per-render). Confirmed acceptable.
- **No surprising ordering:** read the rest of the closure — `selectedSegmentID`/`selectedBlockKeys`
  resets, the `pendingIdentityAction`/`cancelSpotPlacementMode()` guard, and the final
  `activeSheet == nil → .browseNav` backstop. None of them reference `reminderOffsets`; the new line
  is purely additive with no downstream dependency introduced.
- **Both edit orders traced end-to-end, post-fix:**
  - *Chips → Settings:* chip edit saves directly to `UserDefaults` → My Car dismiss → resync loads
    the fresh value into `ContentView`'s cache → Settings opens already showing the chip edit →
    Settings toggle writes back the full (now-correct) struct → both edits present. No stale
    overwrite path remains.
  - *Settings → chips:* Settings edit saves → dismiss → resync (no-op, already current) → My Car
    opens and — unchanged by this fix — always loads fresh at init (`_offsets = State(initialValue:
    ReminderOffsets.load(from: .standard))`), so it already reflected the Settings edit even before
    this fix. Chip edit then saves the full struct including both. Confirmed correct both directions
    (matches the fix's own `testChipsEditThenSettingsEdit_bothSurvive_withResync` /
    `testSettingsEditThenChipsEdit_bothSurvive`).
- **Red-if-regressed test genuinely reproduces the pre-fix bug shape:**
  `testChipsEditThenSettingsEdit_withoutResync_dropsTheChipEdit` models `ContentView`'s cache as
  staying at `.default` (i.e., never resynced) while `UserDefaults` itself already holds the chip
  edit, then has "Settings" write back a full struct built from that stale base — asserting the chip
  edit is lost. This is exactly the mechanism this Pass 1 QA traced by hand in the original code (a
  binding fed by a cache that's stale relative to a concurrent writer), not a different or weaker
  scenario standing in for it.
- **Scheduling semantics byte-identical vs. `main`:** `NotificationScheduler.swift` is not in this
  fix's diff at all (`git diff a819309d..d7de770a --stat` — only `ContentView.swift`,
  `ParkedCarDetailView.swift`, and 2 test files changed), and `offsetChipsRow`'s own
  `cancelAllThenSchedule` call (the only new scheduling call site in this whole PR) is untouched by
  this commit. Provably no scheduling-path change.
- **Flag-off = pure no-op re-read confirmed:** the resync line runs unconditionally on every dismiss,
  but with `communityEnabled == false` nothing ever writes this `UserDefaults` key from My Car (the
  chip row never mounts) — the reload just reconfirms whatever `SettingsView` (the only writer) last
  wrote. No behavior change.

## Fix 3 (nit) — `expires_at` wording

- Doc comments corrected at both the original overclaim site (`performPostLeavingSoon()`'s privacy
  note) and the Mirror-based test's docstring (renamed
  `testPayloadShape_hasNoClientSuppliedExpiryField` → `testLeavingSoonInsertParamsStruct_hasNoExpiryShapedField`,
  now explicitly scoped to "this view-layer struct," not the network payload).
- **New wire-payload test confirmed real:**
  `InsertCrowdPinPhase2bPayloadTests.testInsertCrowdPin_leavingSoonType_expiresAtIsClientComputed_notOmitted`
  intercepts the actual `URLRequest` body via `WriteMockURLProtocol`, calls the real
  `insertCrowdPin(type: .leavingSoon, ...)`, and asserts `capturedBody["expires_at"]` is present and
  non-empty — i.e. it proves the client *does* send a value, framed correctly as "server overrides
  it," not "client omits it." This is the accurate claim and it's now tested against the real wire
  format, closing the gap Pass 1 flagged.

## Count

`git grep -c "func test" d7de770a -- ios/WePark/WeParkTests` sums to **1154** — matches exactly
(1137 + 13 Fix-1 tests + 3 `ReminderOffsetsCrossSheetRaceTests` + 1 wire-payload test = 1154).

## Item 5 — any new issues? Does the `ContentView.swift` touch upgrade the gate?

No new functional issues beyond the two minor/optional observations under Fix 1 above. But **yes,
the gate is upgraded**, and this is worth being explicit about rather than waiving on inspection:
Pass 1's "no mount-chain files touched" reasoning is what let it skip the mandatory #31-class
live-UI smoke. That's no longer true — `d7de770a` adds a line inside `ContentView.swift`'s
`.sheet(item:)` `onDismiss` closure, which is exactly the file this role's own operating rules name
as mount-chain-adjacent. The change itself is genuinely low-risk by inspection (one additive state
mutation, no new modifiers, no reordering of overlay-attachment code, no touch to
`MapViewRepresentable.swift`/`DriveMode*`/`.safeAreaInset`), and I don't have a specific reason to
suspect a regression — but this project's own history (`W8.5c-polish`: 210/0 tests passed with the
entire toolbar layer missing live) is precisely the lesson that "the diff looks safe" is not a
substitute for the live screenshot when `ContentView.swift` is touched at all. Treat this as a
process requirement, not a specific suspicion.

## Findings (Pass 2)

### 🔴 Blocking
None.

### 🟡 Significant
None — both Pass 1 Significant findings are closed.

### 🟢 Minor / nit
- **#4 (new):** `leavingSoonJustPosted` latch never clears within a single view session, so holding
  My Car open past the posted pin's own TTL keeps showing the confirmation state after the pin has
  actually expired (safe-direction, narrow, optional fix — see Fix 1 section above).
- **#5 (new):** the 30m geo-fallback radius tests don't cover the literal `<=30.0` boundary, only
  comfortably-inside/outside values (optional test-coverage gap, see Fix 1 section above).

### 💡 Out of scope (logged, not fixed)
None new.

## Smoke tests run (Pass 2)

Same environment constraint as Pass 1 (Linux VPS, no Xcode). Verified by direct comparison:

- `git show d7de770a --stat` / `git diff a819309d..d7de770a` for all 4 changed files, read in full.
- `pin.authorId`/`pin.lat`/`pin.lng` fields confirmed present on `CommunityPin`
  (`Models/CommunityPin.swift:117-118,123`) so the new fixture parameters and predicate compile
  conceptually.
- `authService`/`currentUserId` accessibility confirmed non-private
  (`Services/CommunityPinService.swift:335`, `Services/SupabaseAuthService.swift:96`).
- Test count: 1154, exact match, computed independently via `git grep -c "func test"` against
  `d7de770a`, not trusted from the commit message.
- `NotificationScheduler.swift` confirmed absent from this commit's diff — scheduling semantics
  provably untouched.

**Not verified (requires Xcode/simulator — Kevin's gate):** actual compile/test run, live rendering,
and the two live-repro checks below.

## Kevin's gate (right-sized, restated for Pass 2)

The `ContentView.swift` touch means this now gets the **full mount-chain live-UI smoke**, not just
the narrower My-Car-only checks from Pass 1:

1. **Build + test.** `xcodebuild ... build test` on a real iPhone 17 sim UDID — confirm compile and
   **1154/0**.
2. **#31-class regression screenshot (new requirement this pass).** With the app freshly launched
   (flag off, default state), screenshot the main map view — confirm the full toolbar (gear /
   find-me / find-car / clock / Drive), ASP banner, Park Until pill, and block polylines all still
   render. This is the standard check for any `ContentView.swift` touch, however small the diff.
3. **Flag-off screenshot.** My Car sheet on a parked test pin — confirm byte-identical to the
   pre-S10 sheet.
4. **Flag-on live smoke.** Flip `communityEnabled = true` locally, park, open My Car — layout matches
   screenshot 15, chips/CTA work, identity sheet shows once, confirmation renders, pin appears on map.
5. **Live-repro the two fixed bugs (should now both hold):**
   (a) Post a leaving-soon pin, dismiss My Car, reopen it — confirm the confirmation state
   ("The crew's been told") shows immediately, with **no** chips/CTA available to double-post.
   (b) Edit an offset chip in My Car, dismiss, open Settings, toggle a *different* preset, dismiss,
   reopen My Car — confirm the first chip's state survived.
6. Flip back to `false` before merge/TestFlight.

Pending step 1-6 confirmation on a Mac, this PR is clear to merge.
