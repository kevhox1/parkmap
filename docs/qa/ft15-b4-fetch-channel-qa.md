# FT-15 / TF2-15 Stream B4 (third fetch channel + consumption) QA Pass 1 — 2026-08-13

**Reviewed:** branch `ios/ft15-b4-fetch-channel-consumption` at `ace2695a` (pinned to local ref
`refs/qa/ft15-b4`, diffed against merge-base `8a79eb5d` = `main`'s Stream B1 commit), against
`docs/ft15-tf215-temporary-block-restrictions-spec.md` §3.4, §9.1, §9.2, §9.3, §12 (AC-C1–C5,
AC-T1's render half, AC-I8).
**Verdict:** 🟡 ship with caveats — code reads as compile-safe and logically sound by careful
manual review (see below), the 22 new + 6 updated tests exercise real behavior against realistic
fixtures, and the two author-flagged decisions both hold up under independent verification. But
there is **no Swift toolchain on this machine** — a Mac `xcodebuild build` + `test` pass remains a
required gate, not a formality this replaces. Two 🟡 findings should be read before this ships to
any build that could reach production, and one live-UI smoke is outstanding.

This is a **static/manual review only**. I did not compile or run anything Swift-related. Every
claim below is "what a compiler and a careful adversarial human would catch reading this cold,"
not a substitute for either.

---

## Summary

Stream B4 adds the third `CommunityPinService` fetch channel that the spec's §3.4 identifies as
the concrete gap making the whole FT-15/TF2-15 feature invisible end-to-end (neither existing
channel's hardcoded `source`/`lifespan` filter would ever return a `source=crowd,
lifespan=session|durable` block-scoped row). I independently re-derived Channel 1's and Channel
2's filters from the unmodified surrounding code and confirmed the gap is real and that Channel
3's predicate — `source=eq.crowd`, `pin_type=in.(filming,construction)`, `resolved_at=is.null`,
`or=(expires_at.is.null,expires_at.gt.<now>)`, deliberately no `lifespan=` and no `starts_at=`
filter — closes it exactly as specified, with no possibility of overlap/duplication against
Channel 1 (mutually exclusive on `source`) or Channel 2 (mutually exclusive on `pin_type`). The
consumption surfaces (`BlockDetailView`/`ParkedCarDetailView` banner, widened `PinDetailSheet`
reactions gate, block-scoped detail view, construction glyph) are correctly wired and covered by
targeted tests. `MapViewRepresentable.swift` is untouched — the PR keeps its promise of doing this
work with **zero** new map-overlay surface, exactly per Kevin's closed OQ-1 ruling.

The two things the author flagged both check out: the `isStillHereDisabled` TTL-cap scoping fix to
`lifespan == .ephemeral` is provably behavior-preserving for every existing ephemeral pin (I
re-derived the before/after logic by hand), and I independently confirmed
`extend_pin_expiry`'s `and lifespan = 'ephemeral'` guard at `supabase/02-pins-schema.sql:262`. The
construction marker glyph/color addition to `PinMarkerAnnotation.markerStyle` is not scope creep —
§9.1 of the spec explicitly names this exact addition ("construction needs a new glyph/color —
suggest hammer.fill / a construction-orange, a one-line addition to the same switch"); the
author's cited line numbers are off but the textual authorization is unambiguous.

What concerns me isn't a bug in this diff — it's what happens when this diff meets the rest of the
system. `fetchPins` has no per-channel failure isolation: if any one of the three concurrent
requests returns a non-2xx status, the whole fetch aborts and `visiblePins` is never updated that
cycle — not just for the failing channel, but for the two that succeeded too. That's pre-existing
architecture (true for 2 channels already), but Channel 3 is, right now, virtually guaranteed to
hit it: its `select` list requires `starts_at`/`report_group_id` columns that exist only after
Stream A's migration is applied to production, Stream A is not yet merged to `main`, and its
latest independent QA verdict is **🔴 DO NOT APPLY** (`docs/qa/ft15-a-block-scoped-schema-qa-pass3.md`
— two fresh abuse-control bypasses found in round 3). If a build carrying this code reaches
TestFlight before Stream A is both fixed and applied, every community pin on the map — the
pre-existing filming/ASP-suspension/special-event/enforcement/sweeper markers, not just the new
feature — stops refreshing app-wide. See Findings #1 and #2.

---

## Acceptance criteria checklist (§12)

- [x] **AC-C1** — Channel 3 returns `source=crowd, pin_type in (filming, construction)` and merges
      into `visiblePins`, genuinely new coverage. Verified by reading `buildCrowdBlockScopedRequest`
      + re-deriving Channel 1/2's filters independently (confirmed neither could ever match) + 8
      tests in `FT15Channel3RequestTests` (source, pin_type, resolved_at, expiry-or-clause, select
      shape, no-lifespan-filter, apikey header).
- [x] **AC-C2** — upcoming pins (`starts_at` in the future) still fetched; UI distinguishes
      Upcoming/Active. Verified: no `starts_at=` filter in the request (test +
      code read), `clientSideFilter` (unmodified — confirmed by diff) never inspects `startsAt`,
      `CommunityPin.isUpcoming(now:)` correctly implements the distinction and is wired into 3
      display sites (`TemporaryRestrictionBanner`, `BlockDetailView.statusBadge`,
      `PinDetailSheet.statusBadge`).
- [x] **AC-C3 (logic)** — `blockScopedRestriction(forBlockfaceKey:)` correctly requires
      `reportGroupId != nil` + `pinType in (filming, construction)` + exact string match; 5
      targeted tests including a deliberate "colliding segmentId but no reportGroupId" negative
      case that proves open-data filming pins can never spoof a match. **Not independently
      verified in a live UI** — the `if let restriction = blockScopedRestriction { ... }` wiring
      in both consumer views is code-read-verified only. See Finding #3.
- [x] **AC-C4** — `showsReactionsRow` widens to `lifespan in (session, durable)` block-scoped
      reports without becoming lifespan-blind. Verified by 5 tests, including the boundary case
      (`testShowsReactionsRow_sessionCrowd_noReportGroupId_false`) that proves the widen is scoped
      to `reportGroupId != nil`, not to every session/durable crowd pin.
- [x] **AC-C5** — tapping a marker shows at minimum the covered block + shared window (always);
      multi-blockface extent only when `> 1` sibling shares `reportGroupId` — meets the spec's
      explicit "nice-to-have, not required" bar.
- [~] **AC-T1 (render/consumption half only)** — construction glyph (`hammer.fill`, distinct
      "safety orange") present in both the map marker and `PinDetailSheet`'s icon/color switches,
      zero files touched beyond what B2/B4 were already budgeted. **The write-path half (Stream
      B3) is not in this diff** — full end-to-end "submit a construction report and see it render"
      cannot be verified until B3 lands. Not a defect in B4; flagging the AC as partially-scoped
      to this PR.
- [x] **AC-I8 / §3.4's "concrete gap"** — independently re-verified: `buildOpenDataRequest`
      hardcodes `source=eq.open_data` (unmodified), `buildCrowdEphemeralRequest` hardcodes
      `lifespan=eq.ephemeral` (unmodified) — neither channel could ever have returned a
      `source=crowd, lifespan=session` row before this PR. Confirmed real, confirmed closed.

---

## Findings

### 🔴 Blocking
None found in this diff on its own terms.

### 🟡 Significant

- **#1: `fetchPins` has no per-channel failure isolation — one channel's error silently drops the
  other two channels' fresh results.**
  - Where: `ios/WePark/WePark/Services/CommunityPinService.swift`, `fetchPins(for:)` (the
    sequential `if let httpResponse = ...Response as? HTTPURLResponse, !(200..<300).contains(...)`
    checks for each of the three channels, each followed by `return` before `visiblePins` is ever
    reassigned).
  - What: if Channel 3 (or any channel) returns a non-2xx, the function returns immediately after
    setting `fetchError`, without applying Channel 1's or Channel 2's already-successfully-fetched
    and decoded data to `visiblePins`. The existing (pre-B4) 2-channel version had the same
    all-or-nothing shape; B4 adds a third failure point without adding isolation, and — per
    Finding #2 — gives that third point a near-certain, currently-live trigger.
  - Expected: a single channel's failure should not block the other channels' fresh data from
    reaching `visiblePins`. The task brief for this review named this exact risk ("Check error
    handling when one of three fails, that a partial failure can't silently drop the other
    channels' results") — the answer is that it currently can, and does.
  - Repro (by reading, not by running): mock Channel 3's `URLSession` handler to return HTTP 400
    while Channel 1 and Channel 2 return 200 with valid `[]`/pin JSON — `visiblePins` will not be
    updated with Channel 1/2's results this fetch cycle (stale data persists instead, per the
    existing "on failure, don't clear visiblePins" behavior, so it fails soft rather than blank —
    but new pins from all three channels are still withheld).
  - Owner: `@ios-engineer`. Suggested fix: `try` each channel's data/decode independently (e.g.
    per-channel `do`/`catch` or `Result`), merge whichever channels succeeded, and only set
    `fetchError` to reflect the channel(s) that actually failed.

- **#2: Deploy-sequencing landmine — Channel 3's `select` list depends on columns that don't exist
  in production yet, and the schema PR that adds them is currently failing its own QA.**
  - Where: `buildCrowdBlockScopedRequest`'s `select` query item
    (`...,starts_at,expires_at,...,report_group_id`); depends on
    `supabase/02f-block-scoped-restrictions.sql` (Stream A).
  - What: as of this review, Stream A's migration is **not merged to `main`** (only present in a
    separate agent worktree) and its most recent independent QA verdict is **🔴 DO NOT APPLY**
    (`docs/qa/ft15-a-block-scoped-schema-qa-pass3.md` — two new complete abuse-control bypasses
    found in round 3, on top of two earlier rounds of findings). Production's `pins_with_author`
    view does not have `starts_at`/`report_group_id` columns today. A request selecting unknown
    columns gets a PostgREST 400.
  - Expected / consequence: combined with Finding #1, if this B4 code ships in a TestFlight build
    before Stream A is fixed and applied, **every** community pin fetch fails closed — not just
    block-scoped filming/construction markers, but the existing Tier 1 (`filming`,
    `asp_suspended_today`, `special_event`) and Tier 3 (`enforcement_active`, `sweeper_passed`)
    markers stop refreshing app-wide, silently (stale data stays on screen, `fetchError` is set but
    I did not find any UI surface that renders it to the user in this diff or the surrounding
    code).
  - This is not a defect in B4's code — it's a real operational gate this PR creates that has no
    code-level safeguard today. HANDOFF.md already documents the intended sequencing ("Kevin
    applies `02f`/`02g` by hand → FT-15 B2/B3/B4"), so the risk is understood at the process level,
    but nothing stops someone from merging B4 to `main` and later archiving a build from `main`
    without re-checking that Stream A is live.
  - Owner: `@ios-engineer` (Finding #1's fix reduces blast radius) + process: whoever owns the next
    TestFlight archive must confirm Stream A is applied to production first. Worth a HANDOFF.md
    note at merge time, not just tribal knowledge.

- **#3: Live-UI smoke not performed — `ContentView.swift` is touched, no simulator available here.**
  - Where: `ios/WePark/WePark/ContentView.swift` (`blockDetailSheetContent(_:)` extraction, new
    `pinService`/`onOpenRestriction` wiring at both the `.blockDetail` and `.parkedCarDetail` sheet
    call sites).
  - What: per this repo's standing live-UI-smoke norm for any `ContentView.swift` touch (the #31
    regression class), a build+install+launch+screenshot pass is the correct verification step
    before merge, not a code read alone. This VPS has no Xcode/simulator — I could not obtain that
    screenshot, and per my own operating instructions I will not claim a result I didn't obtain.
  - My code-read assessment: this specific touch is low-risk relative to past #31 incidents — it's
    a pure `@ViewBuilder` extraction (matching the file's own established pattern for staying under
    the type-checker complexity limit) plus two new optional constructor arguments passed through
    at existing call sites. No `region`/camera/`updateUIView` mutation, no `MapViewRepresentable`
    touch at all. But "low risk by reading" is exactly the category of claim this repo's own
    history (W8.5c-polish: 210/0 tests passed with the entire toolbar layer missing live) says not
    to trust without the screenshot.
  - Owner: whoever has Mac access next — build, install on `F0820726-15F4-4FA3-8602-A5D7B479A277`,
    screenshot with a fixture block-scoped pin injected (`inject(fixtures:)` is already exposed for
    exactly this), confirm the `TemporaryRestrictionBanner` renders with sane text wrapping in both
    `BlockDetailView` and `ParkedCarDetailView`, and confirm the toolbar/ASP-banner/Park-Until pill
    mount chain is unaffected.

### 🟢 Minor / nit

- **#4: Construction "safety orange" RGB literal `(0.91, 0.45, 0.05)` duplicated 3× with no shared
  constant** — `PinMarkerAnnotation.swift` (`markerStyle`), `PinDetailSheet.swift`
  (`constructionOrange`), `BlockDetailView.swift` (`TemporaryRestrictionBanner.iconColor`). Kept in
  sync today only by comments cross-referencing each other. A future palette tweak needs someone to
  remember all three sites. Suggest a single named constant (e.g. on `Constants.swift` or a shared
  `Color` extension) in a follow-up.
- **#5: Two different mechanisms for the same "optional service, default nil" pattern across
  sibling views.** `BlockDetailView.pinService`/`onOpenRestriction` rely on Swift's synthesized
  memberwise-init default (inline `= nil` on the stored property, no custom `init`); the
  near-identical pair on `ParkedCarDetailView` uses an explicit custom `init` with parameter
  defaults. Both compile and behave correctly (verified by tracing both call sites), but it's an
  avoidable stylistic inconsistency between two views doing the same thing.
- **#6: `CommunityPin.isUpcoming(now:)` call sites in the view layer default to `Date()`**
  (`pin.isUpcoming()` with no argument in `BlockDetailView`, `PinDetailSheet`,
  `TemporaryRestrictionBanner`), not the service's injectable `nowProvider()`. Functionally fine —
  there's no correctness requirement for the "Upcoming" badge to use deterministic time in
  production — but it's an asymmetry worth noting since every other time comparison in this feature
  is injectable. Matches this file's own stated convention that view-layer formatting isn't unit
  tested, so not counted against the PR.
- **#7: `windowText` (`TemporaryRestrictionBanner`) and `windowSummary` (`PinDetailSheet`)** are
  near-identical duplicated date-range formatting logic. Consistent with this codebase's explicit,
  already-documented convention of view-file-local duplication over shared helpers (cited in both
  doc comments) — flagged for awareness only, not a defect.

### 💡 Out of scope (logged, not fixed)
- AC-T1's write-path half (Stream B3, the actual "submit a construction report" flow) is a
  different stream and not part of this diff.
- Stream A schema readiness (Finding #2) is a different stream's deliverable; only the
  cross-stream operational risk is this PR's concern.

---

## Adversarial checks performed (no defect found)

- **Non-exhaustive switches over `PinType`**: both new `switch pin.pinType` blocks touched by this
  PR (`PinDetailSheet.iconSymbol`/`iconColor`) already carry a `default:` case — adding
  `.construction` cannot break exhaustiveness either way. `PinMarkerAnnotation.markerStyle` is the
  same shape (`default:` fallback present both before and after).
- **`Codable`/`CodingKeys` mismatches**: `Models/CommunityPin.swift` is untouched by this PR (all
  new B4 logic reads already-decoded fields via extensions in other files) — zero risk of a
  decode/encode key drift introduced here.
- **Optionality**: `PinDetailSheet.pinService` is a required (non-optional) `var`, and its sole
  construction call site (`ContentView.swift:927`, unmodified by this PR) already passes it —
  `blockScopedDetails`' `pinService.visiblePins` access is safe. `BlockDetailView.pinService` /
  `ParkedCarDetailView.pinService` are correctly optional with nil-coalescing lookups
  (`pinService?.blockScopedRestriction(...)`), matching the existing `onParkHere` optional-closure
  convention in the same files.
- **Access levels**: `TemporaryRestrictionBanner` is declared with no access modifier (`internal`
  by default), correctly visible from both `BlockDetailView.swift` (its home file) and
  `ParkedCarDetailView.swift` (its only other user) in the same target.
- **Closure signature mismatches**: `onOpenRestriction: ((CommunityPin) -> Void)?` is typed
  identically at all three sites — `BlockDetailView`'s stored property, `ParkedCarDetailView`'s
  init parameter, and both `ContentView.swift` call sites (`{ pin in activeSheet = .pinDetail(pin) }`).
- **Ambiguous overloads / call-site compile check for every touched call site**: both
  `BlockDetailView(...)` call sites (`ContentView.swift:951`, the file's own `#Preview` at line
  556) and both `ParkedCarDetailView(...)` call sites (`ContentView.swift:684`, the file's own
  `#Preview`) traced by hand against the (respectively synthesized / explicit) initializer
  signatures — all compile-consistent, including the ones that omit the two new parameters.
- **`activeSheet = .pinDetail(pin)` reassignment from within an already-presented sheet** — this is
  not a novel pattern this PR introduces; it's the same established, already-working precedent as
  `.signCheckConfirm`'s `onConfirm: { confirmedIntent in activeSheet = .parkConfirm(confirmedIntent) }`
  (`ContentView.swift:829`, unmodified).
- **Merge/dedup risk across the 3 channels**: confirmed by reading the filter predicates directly
  (not just trusting the comment) — Channel 1 (`source=eq.open_data`) and Channel 3
  (`source=eq.crowd`) are mutually exclusive on `source`; Channel 2's `pin_type` filter
  (`enforcement_active,sweeper_passed`) never overlaps Channel 3's (`filming,construction`). No
  pin row can satisfy two channels' predicates simultaneously — no duplication risk under the
  current schema.
- **Cancellation**: the three `async let` bindings are unchanged in kind from the pre-existing
  2-channel pattern (Swift structured concurrency auto-cancels un-awaited `async let` children when
  the parent task is cancelled or throws) — B4 doesn't change this behavior, just adds a third
  child task with identical semantics.
- **`mergeableTypes` widening**: confirmed additive-only (`.construction` appended to the existing
  `Set<PinType>` literal); did not find any pre-existing `CommunityPinServiceRealtimeMergeTests`
  or `CommunityPinServiceCrowdMergeTests` case whose expectations would be affected by the
  addition (those tests assert specific pin types are/aren't merged; none test `.construction`'s
  prior absence as a positive assertion).
- **`isStillHereDisabled` regression check for existing ephemeral pins**: traced both branches by
  hand — for `pin.lifespan == .ephemeral`, the new `guard pin.lifespan == .ephemeral else { return
  false }` is a no-op (falls through to the unchanged TTL-cap check), so behavior is byte-for-byte
  identical to before this PR for every pin type this button already served.
- **No `Calendar.current`**: grepped the full diff — zero occurrences outside of comments
  referencing the invariant by name. All new date math is `Date`/`TimeInterval` comparison or a
  `DateFormatter` with `.easternTime`.
- **`project.pbxproj`**: not present in the diff; `FT15B4Tests.swift` lands under the existing
  `PBXFileSystemSynchronizedRootGroup` for `WeParkTests` (same mechanism verified in the B1 QA
  pass), so no manual project-file wiring was needed or missed.

---

## Test quality review

- **The 6 modified pre-existing tests** in `CommunityPinServiceTests.swift`
  (`testFetchRequest_includesOpenDataSourceFilter`,
  `testFetchRequest_includesCrowdEphemeralChannel`,
  `testFetchRequest_crowdChannel_includesResolvedAtIsNull`,
  `testBuildRequest_noAuthorizationHeader`, `testBuildRequest_apiKeyHeader_present`,
  `testDebounce_twoRapidCalls_firesOneFetch`) — genuinely updated, not weakened. Each moved its
  `expectedFulfillmentCount`/`fetchCount` assertion from 2 → 3 with an accurate rationale in the
  updated comment; none of the underlying assertions (URL content, header presence, debounce
  collapse behavior) were loosened or removed. Confirmed these are the only 6 count-based
  assertions in the file by grepping for every `expectedFulfillmentCount`/`fetchCount ==` /
  `XCTAssertEqual(fetchCount` occurrence.
- **`FT15B4Tests.swift` (22 new tests, confirmed by count)** — tests real behavior, not
  tautologies. Request-shape tests assert on the actual percent-decoded URL string (with an
  explicit, well-reasoned comment on why percent-decoding first, rather than assuming
  `URLComponents`'s encoding choices for `(`, `)`, `,`). The shared `b4PinFixture` builder produces
  full `pins_with_author`-shaped JSON matching `CommunityPin.CodingKeys` exactly (including the
  ISO8601 date formatting quirks already established elsewhere in this test suite) and is decoded
  through the real `CommunityPin(from:)` initializer, not hand-constructed — so these tests
  exercise the actual decode path, not a mock of it. The lookup tests include a genuinely
  adversarial negative case (`testBlockScopedRestriction_reportGroupIdNil_excluded`: a colliding
  `segmentId` with `reportGroupId == nil` must not match) rather than only positive-path coverage.
  Uses a dedicated `FT15B4MockURLProtocol` (not the shared `PinMockURLProtocol`) specifically to
  avoid static-state races under parallel test execution — matches an existing project convention
  cited by name (`AuthMockURLProtocol`/`WriteMockURLProtocol`).
- No test in either file asserts the per-channel-failure-isolation behavior in Finding #1 — that
  gap in test coverage exists both before and after this PR.

---

## Smoke tests run

None — no Xcode, Swift toolchain, or simulator available in this environment (Linux VPS). All
verification above is static/manual code review plus independent re-derivation of the claims made
in code comments and the PR's own framing (Channel 1/2 filter hardcoding, `extend_pin_expiry`'s SQL
guard, Stream A's current merge/QA status). A Mac `xcodebuild build` + `xcodebuild test` pass and a
live-UI-smoke screenshot (Finding #3) are both required gates before merge, not formalities this
review replaces.

## What's working

- The core design goal — close the "third fetch channel" gap without adding any new
  `MapViewRepresentable` overlay surface — is fully honored. `MapViewRepresentable.swift` does not
  appear in this diff at all, matching Kevin's closed OQ-1 ruling exactly.
- Channel 3's predicate is a precise, independently-re-derivable match for spec §3.4, including the
  two easy-to-get-wrong details (no `lifespan=` filter so both `session` and `durable` reports are
  fetched; no `starts_at=` filter so upcoming reports aren't invisible until they start).
- The two author-flagged decisions (the `isStillHereDisabled` pre-existing-code fix, and the
  construction marker glyph placement) both hold up under independent scrutiny — the first is a
  provably safe, byte-for-byte-behavior-preserving scoping fix backed by a real SQL guard I
  re-verified myself; the second is directly authorized by the spec's own text, not scope creep.
  Both are exactly the kind of "flag it, don't just do it" discipline this project's process is
  supposed to produce.
- Test discipline is strong: the 6 updated pre-existing tests were genuinely updated (not
  weakened), and the 22 new tests hit real adversarial cases (negative lookups, boundary
  lifespan/reportGroupId combinations) rather than just the happy path, and decode through the real
  `Codable` path rather than a hand-rolled mock of it.
- No new PII surface, no new `Calendar.current`, no `project.pbxproj` changes needed or missed, no
  hardcoded secrets found in the diff.
