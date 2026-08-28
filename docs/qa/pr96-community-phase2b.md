# Community 2.0 Phase 2b (PR #96) QA Pass 1 — 2026-08-28

**Reviewed:** branch `ios/community-phase2b` at `7369d265`, against
`docs/community-2.0-reconciliation-spec.md` §3 Phase 2 (AC-P2.1, AC-P2.2, AC-P2.4, AC-P2.5),
`docs/community-2.0-roadmap.md` S7 row (+ locked decision #6, prototype-exact fidelity),
`design/prototype.html:85-102,358-382,415-429,806-830`,
`design/screenshots/08-report-grid.png, 10-spot-placement.png, 11-spot-confirm.png,
12-identity-sheet.png`. Historical context cross-referenced: `docs/qa/pr95-community-phase2a.md`
(the shift-under-finger bug class and the `destination(forTapping:)` routing model).

**Verdict (Pass 1, superseded by Pass 2 below): MERGE-AFTER-MAC-GATE.** No blockers found in a
cold code read. Two Significant findings, both plausible-but-unverifiable-from-a-code-read-alone
and both masked/non-fatal in the shipped code paths — one needs a live check against the *real*
Supabase schema (can't be proven or disproven from static analysis), the other needs a live-sim
smoke of a specific interaction this codebase has a documented history with. Neither blocks
starting the Mac gate; both must be resolved (or explicitly waved off by Kevin) before the flag
ever flips externally. **See Pass 2 below — both findings were fixed at `ea0a4b46` and
independently re-verified; that section carries the operative verdict.**

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
      show-once gate is correct); flagging under its own finding. **Resolved in Pass 2 — see
      below.**
- [ ] Two-device AC-P2.1 and the live overlay-render / toolbar-intact mount-chain check — **not
      verified in this environment** (Linux sandbox, no Xcode/simulator). Required at Kevin's
      Mac gate; see below. **Still outstanding after Pass 2 — unchanged, still needs the Mac
      gate.**

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: `upsertProfile(username: nil, ...)` will hit a real Postgres `NOT NULL` violation on
  the live schema, not just on a user's very-first profile write — the PR's own disclosure
  undersells the mechanism, and the test suite can't catch it because the mock always returns
  200.** — **FIXED at `ea0a4b46`, verified in Pass 2 below.**
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
  machine traces clean.** — **FIXED at `ea0a4b46`, verified in Pass 2 below.**
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
  the PR's own 41-test total claim. Owner: `@ios-engineer`, comment fix only. **Fixed at
  `ea0a4b46` — see Pass 2.**

- **#4: Identity sheet's pre-filled handle is a generic `"Neighbor" + 4 random digits"` rather
  than the prototype's context-aware, street-derived suggestion ("MottStRegular",
  `design/screenshots/12-identity-sheet.png`).** Functionally equivalent (both guarantee a
  non-empty default, closing the NOT NULL gap on the common path) and not spec-mandated to be
  street-derived — the reconciliation spec never specifies the exact generation algorithm.
  Disclosed nowhere in the PR body as a deviation, though; worth a one-line note next time
  there's a visible gap between a screenshot's literal content and the shipped default-value
  algorithm, even when (as here) the gap is cosmetic and doesn't affect any acceptance
  criterion. Owner: `@ios-engineer`, only if Kevin wants literal prototype-handle-generation
  parity — not required. **Addressed at `ea0a4b46` — see Pass 2.**

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

## Smoke tests run (Pass 1)

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

## What's working (Pass 1)

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

---

# QA Pass 2 — 2026-08-28 (Fix verification)

**Reviewed:** `7369d265` (Pass 1) → `ea0a4b46` (the fix commit). Diff reviewed:
`git diff 7369d265..ea0a4b46` — 6 files, +280/-83. Cold re-read; this session did not write
the fix.

**Verdict: MERGE-AFTER-MAC-GATE.** Both Pass 1 Significant findings are correctly and
verifiably fixed — not by narrowing the symptom, but by closing the underlying bug class at
the type level (Finding #1) and by routing through the codebase's own established
single-sheet architecture (Finding #2). Both nits addressed. One new, narrow, pre-existing-
class observation surfaced during the re-trace (a `.identityPrompt` vs. async-Combine-event
collision) — not a defect introduced by this fix, self-heals safely via the same
swipe-to-dismiss catch-all the fix itself added, not blocking. No blockers. This is now ready
for Kevin's Mac gate — the complete gate checklist is restated at the bottom of this section.

## 1. Finding #1 (`upsertProfile` NOT NULL) — verified fixed

- **`upsertProfile(username: String, avatar: String?)` — `username` is non-optional.**
  Verified in `Services/CommunityPinService.swift`: the payload is now built as
  `["id": userId.uuidString, "username": username]` unconditionally (no `if let` around
  `username` anymore) — there is no code path left in this function that can construct a
  payload missing the `username` key or holding an empty one, because the type system no
  longer accepts `nil`.
- **Every caller compiles through `resolvedUsername(rawHandle:)`.** Grepped all
  `IdentitySheet(` instantiation sites — exactly two (`ContentView.swift:1447`,
  `ReportSheet.swift:553`) — and both only *define* the `onSave`/`onSkip` closures; the
  actual username resolution happens *inside* `IdentitySheet.swift`'s own `Button` action
  (`onSave(IdentitySheet.resolvedUsername(rawHandle: handle), selectedAvatar)`), so there is
  no way for a caller to bypass the resolution and hand a raw, possibly-empty string to
  `onSave`. `resolvedUsername` itself: `trimmed.isEmpty ? generateDefaultHandle() :
  trimmed` — and `generateDefaultHandle()` is `"\(streets.randomElement() ?? "Mott")StRegular"`
  against a static, non-empty 8-element array literal, so it cannot itself produce an empty
  string (the `?? "Mott"` fallback is unreachable in practice but harmless, not a smell).
  Hunted for any other path that could still construct an empty username: none — `handle`
  (the `@State` text field) is never read directly by `onSave` anymore, only
  `resolvedUsername(rawHandle: handle)`'s *return value* is.
- **Skip path performs NO upsert.** `onSkip` (`IdentitySheet.swift`) is unchanged by this fix
  and still only clears `pendingIdentityAction`/`activeSheet` and invokes `action?()` — no
  call to `upsertProfile` anywhere on that path, confirmed by reading both `onSkip` closures
  at both call sites.
- **`try?` is gone at both call sites — confirmed by grep.**
  `git grep -n "try? await pinService.upsertProfile\|try? await .*upsertProfile"` across the
  full diff returns zero hits. Both call sites now use `do { try await
  pinService.upsertProfile(...) } catch { #if DEBUG print(...) #endif }` — verified the
  `catch` block only logs (DEBUG-gated) and does not rethrow, swallow-and-continue, or block
  `action?()`, which still fires unconditionally after the `Task` is kicked off — matches the
  documented intent ("a failed profile save is never fatal to the user's actual
  contribution").
- **The replacement tests are real, not tautological.** Three new tests in
  `IdentitySheetTests.swift` (`testResolvedUsername_normalInput_returnsTrimmed`,
  `testResolvedUsername_clearedField_returnsNonEmptyFallback`,
  `testResolvedUsername_whitespaceOnlyInput_returnsNonEmptyFallback`) directly exercise
  `resolvedUsername(rawHandle:)` with the exact two adversarial inputs the finding named
  (empty string, whitespace-only) plus a normal-input control — all three assert
  non-emptiness, and the cleared/whitespace cases are exactly the repro from Pass 1's
  Finding #1. The boundary coverage is real: it directly calls the pure function under test
  with the adversarial input, not a mocked network layer. `CommunityPhase2bWritePathTests.swift`'s
  replacement test (`testUpsertProfile_usernameAlwaysIncludedNonEmpty`) correctly shifted
  scope to proving the payload-shape guarantee now that the nil case is compile-time
  impossible, rather than re-testing the (now-unreachable) nil-input case — the right call,
  not a coverage regression.
- **Residual risk, disclosed for completeness, not a new finding:** this closes the bug at
  the client. I have no way to confirm from a code read whether `@backend-data` also wants a
  schema-level `DEFAULT` as belt-and-suspenders (Finding #1's Option (b)) — the fix took
  Option (a) only. That's a legitimate, sufficient fix on its own (the client can now never
  construct an invalid payload), not a half-fix; flagging only so Kevin knows Option (b) was
  not pursued, in case a *future* caller of `upsertProfile` (or a different, direct
  PostgREST client — e.g. a hypothetical admin tool) could still hit the same NOT NULL wall
  without going through `IdentitySheet`. Not blocking.

## 2. Finding #2 (`ActiveSheet.identityPrompt` restructure) — verified fixed, full state-machine trace

- **`ActiveSheet.identityPrompt` is a real new case**, added to the enum with an `id` string
  (`"identityPrompt"`) and routed through `sheetContent(_:)`'s `switch` like every other
  case — confirmed it's genuinely part of the single `.sheet(item: $activeSheet)` presenter,
  not a parallel mechanism with a similar name.
- **Zero `.sheet(isPresented:)` modifiers remain on `ContentView` — confirmed by grep.**
  `git grep -n "\.sheet(isPresented" origin/ios/community-phase2b --
  ios/WePark/WePark/ContentView.swift` returns only comment references to the old pattern (a
  doc-header bullet and two doc comments explaining the fix), zero live modifiers. The only
  remaining `.sheet(isPresented:` in the entire PR is `ReportSheet.swift`'s own — confirmed
  unchanged from Pass 1 (`git diff 7369d265..ea0a4b46 -- .../ReportSheet.swift` shows only a
  doc-comment addition and the `try?`→`do/catch` change around it, the `.sheet(isPresented:)`
  modifier itself is untouched) — correctly left alone, since Pass 1 already established this
  one is the safe "sheet-from-a-sheet" pattern nested inside `ReportSheet`'s own already-
  presented content, not the at-risk pattern.
- **Spot-post flow, happy path, traced state-by-state:**
  `submitSpotPlacement()` → identity needed → `pendingIdentityAction = proceed;
  activeSheet = .identityPrompt` (same synchronous transaction, confirmed by reading the
  two assignments back-to-back with no `await` between them) → `.sheet(item:)` presents
  `IdentitySheet` via `sheetContent(.identityPrompt)` → user taps Save or Skip →
  `pendingIdentityAction` captured into a local `action` and set to `nil`, `activeSheet` set
  to `nil` (both synchronous, in that order, inside the same closure) → `action?()` invoked,
  which runs `proceed()`'s `Task` (posts the pin; on success sets `spotPlacementActive =
  false`, clears the draft, sets `activeSheet = .browseNav`; on failure shows a toast and
  leaves placement mode active for a retry). Confirmed correct.
- **Swipe-to-dismiss mid-flow, traced state-by-state:** user swipes the identity sheet away
  without tapping Save/Skip → SwiftUI clears the `$activeSheet` binding to `nil` as part of
  its own dismiss mechanics (standard `.sheet(item:)` behavior) → the `onDismiss` closure
  fires → `pendingIdentityAction` is still non-nil (neither button ran to clear it) → the new
  guard (`if pendingIdentityAction != nil { pendingIdentityAction = nil;
  cancelSpotPlacementMode() }`) fires → `cancelSpotPlacementMode()` clears
  `spotPlacementActive`/`spotPlacementDraft` and sets `activeSheet =
  dismissTargetOutsideBrowseNav` (`.browseNav`). **Confirmed: the report/spot-open is
  correctly NOT posted** — `proceed`/`action` is never invoked on this path, only cleared.
  The ordering guarantee this relies on (both button paths clear `pendingIdentityAction`
  *before* triggering the dismiss that fires `onDismiss`, since it's set in the same
  synchronous closure as `activeSheet = nil`, and `onDismiss` only fires after SwiftUI's
  dismiss animation, strictly later) holds — read both button closures to confirm the
  ordering (`pendingIdentityAction = nil` precedes `activeSheet = nil` in both).
- **The new `!spotPlacementActive` guard on the browse-nav auto-restore — verified it fixes
  the described race without breaking the normal restore path.** Traced both branches:
  - *Normal path (report sheet cancel/submit, no spot placement involved):*
    `spotPlacementActive` is `false` throughout (it's a dedicated `@State` only ever touched
    by the spot-placement functions), so `!spotPlacementActive` evaluates `true` and the
    guard imposes no new restriction — the browse-nav restore fires exactly as it did before
    this fix. No regression.
  - *Spot-placement path, identity resolved via Save/Skip:* at the moment `onDismiss` fires,
    `spotPlacementActive` is still `true` (only `proceed()`'s eventual Task completion flips
    it) *or* has already been set to `.browseNav` directly by `proceed()`'s success branch
    (in which case `activeSheet == nil` is already false, so the outer condition short-
    circuits before the new guard even matters). Either way, the guard prevents the
    onDismiss backstop from racing ahead of `proceed()`'s own eventual `activeSheet`
    assignment — confirmed this is exactly the race the fix's comment describes, and the
    guard closes it in both sub-cases.
- **Any path where `activeSheet` gets clobbered mid-flow by something other than this fix's
  own machinery?** Grepped every `activeSheet =` assignment in the file (40+ sites). Nearly
  all are gated behind either a direct user gesture (which can't fire while a modal sheet is
  up — SwiftUI blocks underlying interaction) or `dismissTargetOutsideBrowseNav`/the
  onDismiss backstop (both correctly sequenced, per above). **One genuine, narrow,
  pre-existing-class exception found and worth flagging: `handleFirstPinDropped()`**
  (`ContentView.swift`, fired from `parkPinService.firstPinDropped`, a Combine publisher —
  not a direct tap) unconditionally sets `activeSheet = .notificationRationale` gated only
  on a `UserDefaults` first-time check, with no "is another sheet currently up" guard. In
  the narrow window where a user's first-ever parked-car pin drop is still resolving
  asynchronously *and* they separately reach their first-ever community contribution's
  identity sheet before that publisher fires, `.identityPrompt` could be silently replaced
  by `.notificationRationale`. This is **not introduced by this fix** — it's the same
  "last writer wins" property every other case in this single-presenter enum has always had,
  and it predates this PR entirely (W6). It also **self-heals safely**: `pendingIdentityAction`
  is left non-nil when this happens (neither Save nor Skip ran), so when
  `.notificationRationale` is later dismissed, the SAME `onDismiss` swipe-to-dismiss guard
  this fix added treats it as an unresolved dismissal and correctly cancels the spot
  placement rather than leaving state dangling. Net effect if this ever fires: the user's
  contribution silently doesn't post (same outcome as an explicit swipe-away) instead of a
  crash or corrupted state. Logging this as an observation, not a new finding — it's a
  pre-existing architectural property surfaced by this fix's own thoroughness, not a defect
  this fix created, and it degrades safely.

## 3. Nits — verified addressed

- **#3 (header count):** `IdentitySheetTests.swift`'s header now says "Test inventory (13
  tests)" and lists 1–13, matching `grep -c "func test"` = 13 exactly (10 original + 3 new
  `resolvedUsername` tests). Fixed.
- **#4 (street-flavored handle):** `generateDefaultHandle()` now returns
  `"\(street)StRegular"` from a curated 8-street list (Mott/Mulberry/Elizabeth/Prince/
  Spring/Bowery/Grand/Broome), matching the prototype screenshot's flavor
  ("MottStRegular"). **Sanity-checked for empty/absurd output when street context is
  unavailable:** this function takes no segment/location parameter at all — it was never
  wired to real geo/segment context (the doc comment explicitly, honestly discloses this:
  "NOT derived from the user's actual location... just closer in FLAVOR to the prototype's
  demo content"), so there is no "nil segment" failure mode to guard against — the street
  name always comes from the fixed, always-non-empty static array, with `?? "Mott"` as a
  belt-and-suspenders fallback that Swift's own type system makes unreachable
  (`randomElement()` on a non-empty array literal cannot return `nil`). Cannot produce
  empty or absurd output under any input, because it takes no input. Verified via the new
  `testGenerateDefaultHandle_neverEmpty_matchesStreetRegularFormat` test, which asserts
  every generated handle ends in `"StRegular"` and the street prefix is a member of the
  known set, across 20 random draws — this is a real, non-tautological boundary check
  (it would fail if the format regressed or an unexpected street leaked in).

## 4. Count check

`git grep -c "func test" origin/ios/community-phase2b -- ios/WePark/WeParkTests` sums to
**1067** — matches the expected count exactly (1064 Pass-1 baseline + 3 net-new
`resolvedUsername` tests; `CommunityPhase2bWritePathTests.swift`'s test count is unchanged,
one test renamed/repurposed, not added).

## 5. New issues introduced by the fix?

None found that rise above the one observation logged in §2 above (the `.identityPrompt` vs.
async-Combine-event collision), which is pre-existing-class and self-healing, not introduced
by this fix. Read the `onDismiss` consolidation twice, specifically hunting for:
- **Double-firing of `cancelSpotPlacementMode()` or `proceed()`** — not possible;
  `pendingIdentityAction` is nilled out at the top of every path that reads it
  (`onSave`/`onSkip`/the new guard), so no path can invoke the captured `action` (or run the
  cancel branch) twice.
- **A reintroduced version of the original PR #95 shift-under-finger bug class** — not
  applicable here; this fix touches sheet *presentation state*, not view layout, so there's
  no hit-target-shift mechanism in play.
- **A regression to the pre-existing `dismissTargetOutsideBrowseNav` / block-select /
  drive-mode guards on the same `onDismiss` closure** — confirmed unchanged; the new code is
  purely additive (one new `if` block, one new `&&`-guard clause appended to the existing
  condition), and every pre-existing guard clause (`ft20BrowseSheetEnabled`, `activeSheet ==
  nil`, `!driveModeActive`, `!blockSelectModeActive`) is untouched, still present, still in
  the same order.
- Diff confined to the 6 files listed at the top of this section; nothing outside the
  claimed scope touched (`MapViewRepresentable.swift`, `ReportSheet.swift`'s own
  `.sheet(isPresented:)` modifier itself, `BlockRestrictionReportSheet.swift` all remain
  untouched by this specific fix commit).

## What Kevin's Mac gate must cover (restated, complete, supersedes the Pass 1 list)

1. **`xcodebuild build` + `xcodebuild test`, full suite, confirm 1067/1067.** First real
   compile of the full PR (base + fix) — still genuinely COMPILE-UNVERIFIED against a real
   toolchain.
2. **Full mount-chain live-UI smoke (mandatory — this PR touches `MapViewRepresentable.swift`
   + `ContentView.swift` overlay-attachment code):** launch on sim (UDID
   `F0820726-15F4-4FA3-8602-A5D7B479A277`), screenshot at rest — confirm toolbar
   (gear/find-me/find-car/clock/Drive), ASP banner, and Park Until pill all still render
   (the #31-class regression check); then flip `communityEnabled = true`, open the report
   grid, confirm the fixed 2×2 layout matches `08-report-grid.png` and no tile shifts under a
   tap.
3. **Targeted identity-sheet flow smoke, including swipe-dismiss mid-flow:** flag on,
   first-ever-install state, report grid → "Spot open" → tap a curb → "Post it" → confirm
   `.identityPrompt` presents cleanly (no console sheet-presentation warning) → Save resolves
   it, pin posts, placement mode exits to `.browseNav`. Repeat and this time **swipe the
   identity sheet away instead of tapping Save/Skip** — confirm the spot-open report is
   correctly NOT posted, placement mode fully exits, and the browse sheet restores cleanly
   (this is the exact new path `ea0a4b46` added — the highest-value single check in this
   gate). Repeat the happy path via the report-submit flow (Enforcement active → Report →
   identity sheet) to confirm both call sites still behave identically post-fix.
4. **AC-P2.1 two-device check (Mac simulator + Kevin's phone, no NYC/second-phone needed):**
   post each of the 4 report types from one device, confirm all 4 (including `open_spot`
   with its snapped, non-midpoint position) appear correctly positioned on the other within
   ~2s via Realtime.
5. **Placement-accuracy check (roadmap S5's carried-over note):** with real, non-synthetic
   tile data, tap a curb at a few different points along a blockface (near each end + near
   the middle) and visually confirm the draft pin (and the eventually-posted pin) lands on
   the actual tapped curb position — not a segment midpoint, not visibly off the polyline.
6. **Live cleared-handle test against the real Supabase project (now expected to PASS, not
   fail):** from the identity sheet, clear the pre-filled handle entirely (or replace it with
   only spaces), pick an avatar, tap "Join the board & post." Expect the avatar to visibly
   save successfully this time (a generated `{street}StRegular` handle should appear on the
   posted contribution, not a blank/failed write) — this is the direct live-schema
   confirmation that Finding #1 is actually closed against production, not just against the
   mock.
7. **Flag-off manual pass:** with `communityEnabled = false` (shipped default), confirm the
   report list still shows exactly the pre-Community-2.0 2-type list (no grid, no "Spot
   open"/"Street closure" tiles) and the enforcement/sweeper submit flow is pixel-identical
   to pre-this-PR `main`.

No physical NYC drive-test needed for any of the above — everything is Simulator- or
phone-in-hand testable, consistent with the roadmap's S8 row.
