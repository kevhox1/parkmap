# Community 2.0 Phase 2b (PR #96) QA Pass 1 — 2026-08-28

**Reviewed:** branch `ios/community-phase2b` at `7369d265`, against
`docs/community-2.0-reconciliation-spec.md` §3 Phase 2 (AC-P2.1, AC-P2.2, AC-P2.4, AC-P2.5),
`docs/community-2.0-roadmap.md` S7 row (+ locked decision #6, prototype-exact fidelity),
`design/prototype.html:85-102,358-382,415-429,806-830`,
`design/screenshots/08-report-grid.png, 10-spot-placement.png, 11-spot-confirm.png,
12-identity-sheet.png`. Historical context cross-referenced: `docs/qa/pr95-community-phase2a.md`
(the shift-under-finger bug class and the `destination(forTapping:)` routing model).

**Verdict: MERGE-AFTER-MAC-GATE.** No blockers found in a cold code read. Two Significant
findings, both plausible-but-unverifiable-from-a-code-read-alone and both masked/non-fatal in
the shipped code paths — one needs a live check against the *real* Supabase schema (can't be
proven or disproven from static analysis), the other needs a live-sim smoke of a specific
interaction this codebase has a documented history with. Neither blocks starting the Mac gate;
both must be resolved (or explicitly waved off by Kevin) before the flag ever flips externally.

## Summary

This PR does what it claims, and — unlike PR #95's first pass — actually closes the exact gap
PR #95's QA pass 2 flagged as unresolved: `ReportSheet.destination(forTapping:)` was a
disconnected, test-only routing model after #95 (QA called it "a pure, disconnected model...
not wired into the live tap path"). In this PR, the new grid's `handleGridTileTap` genuinely
calls through `destination(forTapping:)` and switches on its result — verified by reading the
`Button` closure, not by trusting the PR body's claim. The S6 shift-under-finger invariant
("nothing may shift beneath a tap") is preserved by construction in the new grid: tile
selection only changes a stroke's width/opacity (no layout mutation), and every per-type detail
section renders below the entire grid, never between cells — confirmed line-by-line against the
diff, not just the doc comment's assertion. The flag-off list was diffed (comments stripped)
against PR #95's shipped code and is byte-identical.

The fraction-snap math (`CandidateSegmentSearch.nearestSegmentSnap`) is careful: per-sub-segment
`t` is clamped `[0,1]` before being folded into a cumulative-length interpolation across the
whole polyline, the final fraction is clamped again, and the "too far, reject" path returns
`nil` cleanly. AC-P2.4 (pin lands on the curb, not the tap point) is satisfied by construction —
`insertCrowdPin` is fed `draft.coordinate`, the polyline-projected point, never the raw tap.

Two real findings, both Significant not Blocking: (1) `upsertProfile`'s nil-username omission
will hit a genuine Postgres `NOT NULL` violation against the live schema on every call where the
handle is cleared (not just "first-ever" as the PR body frames it) — masked by `try?` so it
fails silently rather than blocking the underlying report/spot post, but the disclosed-gap
framing undersells the mechanism; and (2) a second, independent `.sheet(isPresented:)` is now
chained directly onto `ContentView`'s own top-level view (for the spot-placement identity gate),
stacked under the existing `.sheet(item: $activeSheet)` — the same *class* of pattern this
codebase specifically moved away from in W5.1, even though my state-machine trace shows the two
sheets' active windows don't overlap in the intended flow. Both need the Mac gate to actually
settle, not further code reading.

## Acceptance criteria checklist

- [x] AC-P2.3 "Street closure" opens the existing `BlockRestrictionReportSheet` unchanged —
      confirmed `git diff origin/main..7369d265 -- .../BlockRestrictionReportSheet.swift` is
      empty (file not in the PR's touch list at all).
- [x] AC-P2.5 no "avoid"/"ticket"/"fine"/"evasion"/"dodge" in user-facing copy — grepped the
      full diff; only two hits, both in code comments (one is the substring "avoids" in a doc
      comment, one is the copy-compliance doc comment itself listing the banned words).
- [x] Grid restyle resolves S6's disclosed closure-tile-order deviation by construction — every
      tile has a fixed grid slot; per-type detail renders below the WHOLE grid, never between
      cells; verified against the actual `LazyVGrid`/`reportGridCard` code, not the PR's prose.
- [x] Flag-off list is byte-identical to PR #95's shipped code — verified via an automated diff
      of the two files' flag-off branch bodies with comments stripped (`diff` exit 0), not an
      eyeball comparison.
- [x] `destination(forTapping:)` is genuinely wired into the live grid-tap path this time
      (`handleGridTileTap` → `switch ReportSheet.destination(forTapping:...)`) — this closes PR
      #95 pass-2's Finding #3 ("not wired into the live tap path") for the new 4-tile grid.
      The pre-existing `reportTypeRow`/`streetClosureRow` (flag-off list only) still have their
      own separate inline switches that don't call through the model — unchanged from #95,
      correctly out of scope for this PR to touch (flag-off parity requirement).
- [x] Draft-spot-pin annotation lifecycle: added/replaced/removed mechanically in
      `MapViewRepresentable.updateUIView` via `syncDraftSpotPin`, mirroring
      `syncDestinationPin`'s exact shape — no camera mutation, kept in its own
      `draftSpotPinAnnotation` property, never merged into `communityPinAnnotations` (no leak
      into the real pin set).
- [x] Zone stamping (S6) still applies unconditionally on the new write path — `resolveZoneId`
      is called inside `insertCrowdPin` itself, not per-call-site, so the spot-placement path
      (which passes `zoneId: nil`) gets it automatically.
- [x] `insertCrowdPin`'s new `positionFraction`/`leavingMinutes` params: correct `snake_case`
      keys (`position_fraction`, `leaving_minutes`) verified against
      `supabase/03-community-2.0-schema.sql`, nil-omitted (not nil-included), every
      pre-existing call site unaffected (default `nil` params, own tests confirm payload
      omission).
- [x] AC-P2.4 — pin's `lat`/`lng` is the snapped coordinate, not the tap point — `draft.coordinate`
      (from `nearestPointOnPolyline`'s projection) is what's threaded into `insertCrowdPin`,
      never the raw `coordinate` parameter from `handleMapTap`.
- [x] `CommunityIdentityGate` sets shown-state on SHOW (`IdentitySheet.onAppear`), not on either
      button's action — verified in the view body, matches spec §3's explicit fix for the
      prototype's own non-latching `needIdentity()` bug.
- [x] Flag-off contribution paths never touch the identity sheet or its `UserDefaults` key —
      `CommunityIdentityInterception.shouldShowIdentitySheet` requires `communityEnabled` as a
      hard AND-gate; tested for both flag states including the "gate would say show, flag says
      no" combination specifically (`testShouldShowIdentitySheet_flagOff_gateShouldShow_stillFalse`).
- [x] `upsertProfile` never writes `reputation`/`helped_count`/`accurate_report_count`/
      `total_report_count` — payload only ever contains `id`/`username`/`avatar`; tested
      (`XCTAssertNil(capturedBody?["reputation"])`).
- [ ] The NOT-NULL-safe prefill claim ("guaranteeing a non-nil username on the common path") is
      true for the common path but the disclosed edge case (explicitly-cleared handle) fails
      harder against the real schema than the PR body's framing suggests — not a common-path
      failure, but see Finding #1. Not a checklist fail for AC-P2.2 itself (identity sheet
      show-once gate is correct); flagging under its own finding.
- [ ] Two-device AC-P2.1 and the live overlay-render / toolbar-intact mount-chain check — **not
      verified in this environment** (Linux sandbox, no Xcode/simulator). Required at Kevin's
      Mac gate; see below.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: `upsertProfile(username: nil, ...)` will hit a real Postgres `NOT NULL` violation on
  the live schema, not just on a user's very-first profile write — the PR's own disclosure
  undersells the mechanism, and the test suite can't catch it because the mock always returns
  200.**
  - Where: `Services/CommunityPinService.swift`, `upsertProfile(username:avatar:)` — `if let
    username { payload["username"] = username }` (username omitted from the JSON body when
    `nil`, not sent as literal `null`); `supabase/01-mvp-schema.sql:10` —
    `username text unique not null` (no `DEFAULT`); test —
    `WeParkTests/CommunityPhase2bWritePathTests.swift`,
    `testUpsertProfile_usernameNil_omittedFromPayload`, whose `WriteMockURLProtocol` handler
    unconditionally returns `(HTTPURLResponse(..., statusCode: 200, ...), Data())` regardless
    of the payload contents.
  - What: PostgREST's upsert (`Prefer: resolution=merge-duplicates`) compiles to
    `INSERT ... ON CONFLICT (id) DO UPDATE`. Postgres validates `NOT NULL` on the row
    constructed for the `INSERT` clause *before* conflict resolution is applied — a column
    omitted from the payload with no table `DEFAULT` gets `NULL`, and the `NOT NULL`
    constraint fails immediately, regardless of whether the conflicting row already exists.
    This means every `upsertProfile` call with `username: nil` — not only a user's first-ever
    write, as the PR body's "Deviations" section frames it ("A blank handle field would
    violate that on a user's first-ever profile write") — will 400 against the real database.
    The disclosure also states the client "still sends `username: nil`"; it actually *omits*
    the key entirely, which is a materially different payload shape than a literal JSON
    `null` but produces the identical Postgres failure either way (both construct a `NULL`
    value for the column).
  - Practical impact (not severe, which is why this is Significant not Blocking): both call
    sites (`ReportSheet.swift`'s `.sheet` `onSave`, `ContentView.swift`'s `.sheet` `onSave`)
    call `Task { try? await pinService.upsertProfile(...) }` — the error is silently
    swallowed, and `action?()` (the actual report/spot-open submit) fires regardless, on its
    own, independent network call. That underlying pin insert's `award_report_reputation`
    trigger lazily creates a `profiles` row with a generated `neighbor-<uuid8>` username if
    one doesn't exist yet, so the contribution itself still succeeds. The user-visible effect
    is narrower than "profile write fails": a user who deliberately clears the pre-filled
    handle but keeps an avatar selection silently loses that avatar pick, with zero error
    shown. Requires deliberately deleting the pre-fill text, so it's a rare path — but it's a
    real, verifiable 400, not a hypothetical.
  - Expected: either (a) the client sends a non-empty fallback string (e.g. the same
    `generateDefaultHandle()`-shaped value) instead of omitting the key when the trimmed
    handle is empty, so `upsertProfile` never constructs an invalid row; or (b)
    `@backend-data` adds a schema-level `DEFAULT` to `profiles.username` (the spec's own §2.5
    already treats the handle as "decorative, not a login identifier" when it dropped the
    UNIQUE constraint — a `DEFAULT 'neighbor-' || substr(id::text, 1, 8)`-shaped default,
    mirroring the trigger's own generated-handle convention, would close this at the source
    rather than needing every client call site to remember the workaround).
  - Repro (needs the real Supabase project, not the mock): with an authenticated anon session
    that has never written a `profiles` row, `curl -X POST .../rest/v1/profiles -H "Prefer:
    resolution=merge-duplicates" -d '{"id": "<uuid>", "avatar": "🐿️"}'` (no `username` key) —
    expect a `23502 not_null_violation`, not a 200/201.
  - Owner: `@ios-engineer` (client-side fallback) or `@backend-data` (schema default) — either
    is a legitimate fix; recommend Kevin pick one rather than leaving both undone.

- **#2: A second, independent `.sheet(isPresented:)` is now chained directly onto
  `ContentView`'s own top-level view for the spot-placement identity gate — the same *class*
  of pattern this codebase specifically collapsed away from in W5.1, even though the state
  machine traces clean.**
  - Where: `ContentView.swift` — `body` is `mapLayerWithEvents.onReceive(...).onReceive(...)
    .onChange(...).sheet(item: $activeSheet, onDismiss: {...}) {...}`; `mapLayerWithEvents`
    (a separate computed `private var`) itself internally chains
    `.sheet(isPresented: Binding(get: { pendingIdentityAction != nil }, ...)) { IdentitySheet(...) }`
    onto its own returned content, *before* the caller in `body` chains the `.sheet(item:)`
    on top of it.
  - What: HANDOFF's own W5.1 entry documents "Currently, only presenting a single sheet is
    supported" as a real runtime warning this codebase hit and fixed by collapsing three
    independent `.sheet()` modifiers into one enum-driven `.sheet(item:)`. This PR explicitly
    declined to route the spot-placement identity gate through the existing `ActiveSheet` enum
    ("keeps that already-fragile enum's dismiss-target machinery untouched" — the PR's own
    words), instead adding a second, structurally separate `.sheet` modifier chained on the
    exact same view node. I traced the state machine by hand: `enterSpotPlacementMode()`
    always sets `activeSheet = nil` on entry and it stays `nil` throughout placement mode
    (the confirm card is a map overlay, not an `ActiveSheet` case), so `pendingIdentityAction`
    only ever becomes non-nil while `activeSheet` is already `nil` — no code path sets both to
    a "showing" value in the same synchronous transaction. This is *not* the same shape as the
    `ReportSheet`-local identity sheet (which nests inside `ReportSheet`'s own already-
    presented content — the standard, safe "sheet-from-a-sheet" pattern, not at risk here).
  - Why this is still worth flagging as Significant rather than closed by the trace: a hand
    trace proves the *intended* flows don't overlap, but it can't rule out a SwiftUI-internal
    timing edge case (e.g., a deep-link notification tap or `routePendingDeepLink` racing
    `activeSheet` non-nil during the brief async window between `pendingIdentityAction`
    resolving and `activeSheet` being reassigned in `submitSpotPlacement`'s success closure) —
    exactly the kind of interaction that only ever surfaced in this codebase via live smoke,
    never via code review (W5.1's own bug, and PR #95's Mac-gate blocker, were both missed by
    a code-only QA pass).
  - Expected: a targeted live-sim check of this exact interaction before merge (see Smoke
    tests run / Mac gate below). If it's clean, ship as-is — no code change requested
    speculatively. If Kevin's gate finds a "sheet dismissed unexpectedly" / warning-console
    hit, the fix is almost certainly routing `pendingIdentityAction` through a new
    `ActiveSheet` case rather than a parallel `.sheet` modifier.
  - Owner: `@ios-engineer` (only if the Mac gate reproduces an issue).

### 🟢 Minor / nit

- **#3: `IdentitySheetTests.swift`'s header comment says "(9 tests)" but the file both lists
  and contains 10.** Same class of doc-drift as PR #95's Finding #5 (a stale/miscounted test
  inventory comment). Cosmetic; the actual count (verified via `grep -c "func test"` = 10,
  matching the numbered list 1–10 in the same comment block) is correct and consistent with
  the PR's own 41-test total claim. Owner: `@ios-engineer`, comment fix only.

- **#4: Identity sheet's pre-filled handle is a generic `"Neighbor" + 4 random digits"` rather
  than the prototype's context-aware, street-derived suggestion ("MottStRegular",
  `design/screenshots/12-identity-sheet.png`).** Functionally equivalent (both guarantee a
  non-empty default, closing the NOT NULL gap on the common path) and not spec-mandated to be
  street-derived — the reconciliation spec never specifies the exact generation algorithm.
  Disclosed nowhere in the PR body as a deviation, though; worth a one-line note next time
  there's a visible gap between a screenshot's literal content and the shipped default-value
  algorithm, even when (as here) the gap is cosmetic and doesn't affect any acceptance
  criterion. Owner: `@ios-engineer`, only if Kevin wants literal prototype-handle-generation
  parity — not required.

### 💡 Out of scope (logged, not fixed)

- MapKit-POI storefront naming deferral for spot placement — matches the spec's own explicit
  scope cut (§3 Phase 2, §5). Correctly not attempted here.
- Open-items #12 finding ④ (scroll the confirm-street section into view) — disclosed, deferred
  to S13, consistent with the roadmap.
- `leavingMinutes` threaded into `insertCrowdPin`/`ephemeralTTLSeconds` ahead of its actual
  Phase 4a (S10) UI call site — reasonable early plumbing per the PR's own stated reasoning
  (avoids a second future touch to the most multi-phase-touched write path); no functional
  risk today since no call site in this PR passes a `leavingMinutes` value, and the
  5/10/15/20 `CHECK` constraint isn't exercised by anything yet.

## Smoke tests run

No `xcodebuild`/`xcrun simctl` available in this environment (Linux VPS, confirmed —
`which xcodebuild xcrun` returns nothing). All verification below is a cold, adversarial code
read against the diff, cross-referenced against `origin/main`, the applied production schema
(`supabase/03-community-2.0-schema.sql`), the prototype source, and the design screenshots —
**not** a build or a live-UI smoke. This PR's own body correctly discloses this and flags the
Mac gate as mandatory; I'm confirming that disclosure is accurate, not overriding it.

Specifically verified by direct comparison (not trusted from the PR body):
- `git diff origin/main..7369d265 --stat` — file list matches the PR's claimed touch list.
- Flag-off `ReportSheet` body diffed against PR #95's shipped commit (`1fbee567`) with comments
  stripped — `diff` exit code 0, byte-identical.
- `handleGridTileTap`'s `Button` action genuinely calls `ReportSheet.destination(forTapping:...)`
  — read the closure directly, confirming this closes PR #95 pass-2's disconnected-model
  finding for the new grid path (the pre-existing list rows' own inline switches remain
  disconnected, unchanged from #95, correctly untouched here).
- Test count: `git grep -c "func test" origin/main -- ios/WePark/WeParkTests` sums to 1023;
  same against `origin/ios/community-phase2b` sums to 1064 — exactly +41 as claimed.
- `CandidateSegmentSearch.pointToSegmentDistanceDetailed`'s `t` is clamped `[0, 1]` per
  sub-segment before folding into `nearestPointOnPolyline`'s cumulative-length interpolation;
  final fraction clamped again (`min(1, max(0, bestFraction))`). Read the full function body,
  not just the doc comment.
- `insertCrowdPin`'s new params: grepped `supabase/03-community-2.0-schema.sql` to confirm
  `position_fraction`/`leaving_minutes` column names match the payload keys exactly; confirmed
  `resolveZoneId` fires unconditionally inside `insertCrowdPin` (not per-call-site), so the new
  spot-placement path inherits S6's zone stamping automatically.
- Copy grep for the five AC-P2.5 banned words across the full diff — two hits, both in code
  comments (one is "avoids" inside an unrelated sentence, one is the copy-compliance doc
  comment itself).
- Visually inspected `design/screenshots/08-report-grid.png`, `10-spot-placement.png`,
  `11-spot-confirm.png`, `12-identity-sheet.png` (Read tool) against the shipped copy strings
  — hint banner, confirm-card title/subtitle/footer, and grid-tile copy are verbatim matches;
  identity sheet layout (4×2 avatar grid, pre-filled handle field, green CTA, "Post
  anonymously" link) matches structurally, modulo Finding #4's cosmetic handle-generation gap.
- `#30D158`/`#04290F` (identity sheet's green CTA) initially read as a possible legality-
  palette leak — traced to `design/prototype.html:426` (`saveIdentity` button) and `:1016`
  (`av.bd`, avatar-selected border) and confirmed both are prototype-exact values, not an
  invented color, consistent with Kevin's locked decision #6.
- `DraftSpotPinAnnotation` traced end-to-end: registered as its own `MKAnnotationView` reuse
  identifier, synced via its own `syncDraftSpotPin`/`draftSpotPinAnnotation` state, never
  merged into `communityPinAnnotations` (the real pin set) — no leak, confirmed by reading
  both sync functions side by side.

## What Kevin's Mac gate must cover

1. **`xcodebuild build` + `xcodebuild test`, full suite, confirm 1064/1064.** First real
   compile of this diff — nothing here looks type-unsound, but this is genuinely
   COMPILE-UNVERIFIED and hasn't touched a real toolchain.
2. **Full mount-chain live-UI smoke (mandatory per the QA charter — this PR touches
   `MapViewRepresentable.swift` + `ContentView.swift` overlay-attachment code):**
   - Launch on sim (UDID `F0820726-15F4-4FA3-8602-A5D7B479A277`), screenshot at rest —
     confirm toolbar (gear/find-me/find-car/clock/Drive buttons), ASP banner, and Park Until
     pill all still render (the #31-class regression check). Flag can be off for this step.
   - Flip `communityEnabled = true` locally, open the report grid, confirm all 4 tiles render
     in a fixed 2×2 layout matching `08-report-grid.png` and that tapping "Enforcement
     active"/"Sweeper passed" doesn't shift "Spot open"/"Street closure" out from under a
     following tap (re-run of PR #95's exact reported repro class, now against the grid).
3. **Targeted smoke for Finding #2**: flag on, first-ever-install state (identity gate not yet
   shown), open report grid → "Spot open" → tap a curb → "Post it" → confirm the identity sheet
   presents cleanly (no console warning about multiple sheets, no visible flash/overlap), Save
   or Skip resolves it, and the spot-open pin posts + placement mode exits back to
   `.browseNav`. Then repeat via the *report-submit* path (Enforcement active → Report →
   identity sheet) to confirm both call sites behave identically. Try a swipe-to-dismiss on the
   identity sheet mid-flow too — confirm the underlying report is correctly NOT posted (no
   silent double-behavior), matching the code's intended "swipe = cancel" semantics.
4. **AC-P2.1 two-device check (Mac simulator + Kevin's phone, no NYC/second-phone needed):**
   post each of the 4 report types from one device, confirm all 4 (including `open_spot` with
   its snapped, non-midpoint position) appear correctly positioned on the other within ~2s via
   Realtime.
5. **Placement-accuracy check (roadmap S5's carried-over note):** with real, non-synthetic tile
   data loaded, tap a curb at a few different points along a blockface (near each end + near
   the middle) and visually confirm the draft pin (and the eventually-posted pin) lands on the
   actual tapped curb position — not a segment midpoint, and not visibly off the polyline. S5's
   note flagged that a prior hand-inserted test pin rendered mid-block using raw un-snapped
   lat/lng; this is the first real exercise of the curb-snap flow this note was waiting on.
6. **Finding #1 (schema NOT NULL) — verify directly against the live Supabase project**, not
   just accept the code-level analysis: from the identity sheet, clear the pre-filled handle
   entirely, pick an avatar, tap "Join the board & post." Expect either (a) the avatar visibly
   fails to save (confirming the finding, fix needed) or (b) Kevin/`@backend-data` already
   added a schema default and it succeeds silently (finding closed, no code change needed). If
   (a), decide client-fallback vs. schema-default per Finding #1's recommendation before this
   ships externally.
7. **Flag-off manual pass**: with `communityEnabled = false` (shipped default), confirm the
   report list still shows exactly the pre-Community-2.0 2-type list (no grid, no "Spot open"/
   "Street closure" tiles) and the enforcement/sweeper submit flow is pixel-identical to
   pre-this-PR `main`.

No physical NYC drive-test needed for any of the above — everything is Simulator- or
phone-in-hand testable, consistent with the roadmap's S8 row.

## What's working

- The single biggest thing this PR gets right that PR #95 didn't: `destination(forTapping:)`
  is now a live routing authority for the grid, not just documentation-as-tests. That was PR
  #95 pass 2's one open, non-blocking item, and this PR closes it for the new surface without
  being asked to.
- The S6 shift-under-finger fix's invariant ("nothing may move under a tap") survives the grid
  restyle *by construction*, not by luck — grid cells are fixed slots in a `LazyVGrid`, and
  every conditional detail section is deliberately placed after the entire grid, never
  interleaved. This is exactly the right structural answer to the problem #95's blocker
  exposed.
- Flag-off byte-identical parity is not just claimed but independently, automatically verified
  (diffed against #95's actual shipped commit, not against this PR's own prose).
- The fraction-snap math is genuinely careful geometry work: correct per-sub-segment clamping,
  correct cumulative-length folding across multi-vertex polylines, and the test suite actually
  exercises the boundary cases (endpoint, midpoint, perpendicular offset, multi-vertex,
  radius-boundary, empty-input) rather than just the happy path.
- The draft-pin annotation is a clean, minimal, correctly-isolated addition that mirrors an
  already-proven pattern (`DestinationPinAnnotation`) rather than inventing a new mechanism —
  exactly the kind of "match the existing architecture" discipline this codebase's history
  rewards.
- Copy and palette fidelity to the prototype is genuinely high — verified against the actual
  screenshots, not just the prototype's HTML source, and the one thing that looked like a
  palette violation on first read (green CTA in the identity sheet) turned out to be
  prototype-exact, not an invented color.
- The PR body's own disclosures (POI-naming deferral, finding-④ deferral, the NOT NULL
  discovery, the sheet-vs-ActiveSheet tradeoff) are honest about the actual tradeoffs made —
  even where I disagree with the framing of the NOT NULL fix's severity (Finding #1), the
  underlying fact pattern was surfaced, not hidden.
