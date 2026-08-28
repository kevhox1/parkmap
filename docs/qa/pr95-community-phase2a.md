# Community 2.0 Phase 2a (PR #95) QA Pass 1 — 2026-08-28

**Reviewed:** branch `ios/community-phase2a` at `65965015`, against
`docs/community-2.0-reconciliation-spec.md` §3 Phase 2 (AC-P2.3, AC-P2.5),
`docs/community-2.0-roadmap.md` S6 row, `design/prototype.html:361-411`,
`design/screenshots/09-report-confirm-street.png`, `docs/w5-pin-drop-spec.md`.
**Verdict (Pass 1, superseded by Pass 2 below):** MERGE-AFTER-MAC-GATE — one 🟡 Significant
finding (animation-timing risk on the new `enterBlockSelectMode()` call site), no blockers.
**This verdict did not hold**: Kevin's live Mac gate found a 🔴 blocker Pass 1 missed (see
Pass 2). Kept below for the record, not as the operative verdict.

## Summary

This is a clean, reuse-heavy PR that does what it says: adds a gated third report-grid tile
that hands off to the already-shipped `BlockRestrictionReportSheet` with zero new code in
that file, extracts the W5 candidate-search algorithm into a testable service with a
byte-for-byte-preserved wrapper for the existing `ParkConfirmView` path, and stamps
`zone_id` at write time closing PR #94's Finding #3. The flag-off parity claim — the PR's
central assertion — traces out correctly: `confirmedSegment` has exactly two write sites
(init and a tap handler mounted only when the flag is on), so `effectiveSegment == segment`
is provably true whenever `communityEnabled == false`. No compile access (Linux VPS); this
is a cold code read, not a build.

One real, previously-uncalibrated interaction was found: the new "Street closure" tile
routes `enterBlockSelectMode()` from inside a live `.sheet`, but that function's animation-
settling guard (`blockSelectEntrySettlingDuration`, 0.35s) was tuned and previously
live-smoke-verified only for its original caller, a `.confirmationDialog`. The PR's test
plan explicitly opts out of live-UI smoke on the grounds that `MapViewRepresentable.swift`
isn't touched — technically true, but this new call path feeds the exact block-select
overlay mechanism that has the "3 documented live-UI regressions" + mandatory-smoke history
in this codebase. Recommend one targeted smoke check rather than a full mount-chain gate.

## Acceptance criteria checklist

- [x] AC-P2.3 "Street closure" opens the existing `BlockRestrictionReportSheet` unchanged —
      verified `git diff origin/main..65965015 -- .../BlockRestrictionReportSheet.swift` is
      empty, and traced `onRequestStreetClosure: { enterBlockSelectMode() }` to the same
      function the pre-existing long-press dialog's "Report closure" button already calls
      (`ContentView.swift:934-936` vs `:1183`) — identical downstream flow.
- [x] AC-P2.5 no "avoid"/"ticket"/"fine"/"evasion"/"dodge" in user-facing copy — grepped the
      full diff; the only two "avoid" hits are in code comments, not UI strings.
- [x] Grid gating: `ReportSheet.showsStreetClosureTile(communityEnabled:)` is a pure
      passthrough of the flag, tested both states; the tile's `if` wraps its own row (not an
      opacity/hidden trick), so flag-off never mounts it — no layout shift risk.
- [x] Confirm-the-street candidate list: current + opposite side + one neighbor each
      direction, capped at 4, matches the screenshot fixture exactly (test
      `testConfirmStreetCandidates_matchesScreenshotFixture_allFourFound` reproduces the
      09-report-confirm-street.png ordering verbatim).
- [x] Picking a candidate updates only `segmentId` in the submit payload, not `coordinate` —
      confirmed at the `insertCrowdPin` call site (`segmentId: effectiveSegment?.id`, no
      other reference to `confirmedSegment` near `coordinate`).
- [x] `HeadingTowardPicker`'s downstream cross-street labels read `effectiveSegment`, not
      stale `segment` — `headingTowardPickerRow`, `shouldShowDirectionPicker`,
      `autoHeadingToward` all switched; the picker's own bearing/rendering code is untouched.
- [x] Zone stamping: `resolveZoneId(explicit:lat:lng:)` — explicit always wins (tested,
      including the case where the coordinate is *inside* a box but an explicit id is
      supplied), box-match only on `nil`, outside-all-boxes returns genuine `nil`. Verified
      the box literals are byte-identical to the applied `supabase/03-community-2.0-schema.sql`
      seed values (`40.7237` soho `lat_max`, not the stale `40.7280`).
- [x] `BlockRestrictionReportSheet.swift`, `BrowseNavigationSheet.swift`,
      `ParkedCarDetailView.swift` zero-diff — confirmed via `git diff --stat`, no output for
      any of the three.
- [ ] Flag-off byte-identical behavior — code trace is airtight (see Findings, no blocker),
      but **no test in the 31 actually instantiates `ReportSheet` and asserts
      `effectiveSegment == segment` / the submitted `segmentId`** end-to-end when
      `communityEnabled == false`; the tests only exercise the pure gating functions in
      isolation. Not a merge blocker (the trace itself is sound), but a real coverage gap —
      see Finding #2.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: New `enterBlockSelectMode()` call site changes the caller of a timing-calibrated
  guard, and the PR's smoke-test opt-out doesn't account for it**
  - Where: `ContentView.swift:1183` (`onRequestStreetClosure: { enterBlockSelectMode() }`)
    vs. `ContentView.swift:2978-2985` (`enterBlockSelectMode()`) and
    `ContentView.swift:783-790` (`blockSelectEntrySettlingDuration = 0.35`, its doc comment).
  - What: `enterBlockSelectMode()`'s 0.35s tap-ignore guard was sized and doc-commented
    against a specific overlap of three animations fired from a `.confirmationDialog`
    action ("comfortably longer than a standard ~0.3s sheet dismiss animation... Kevin's
    live smoke... is what confirms or corrects it"). This PR adds a second call site that
    fires the same function from inside an actual `.sheet(item:)` presentation
    (`ReportSheet`, `.presentationDetents([.medium, .large])`) — a different, and plausibly
    slower/differently-timed, dismiss animation than a confirmationDialog's action list. The
    PR's own test plan explicitly declines the live-UI smoke gate ("This PR does not touch
    `MapViewRepresentable.swift`/overlay-attachment code, so the mount-chain live-UI smoke
    gate does not apply") — true for the *mount chain*, but this specific mechanism
    (block-select entry timing) was previously gated on live smoke for exactly this class of
    risk, and the PR adds a new, uncalibrated entry path into it.
  - Expected: either a recalibration/re-justification of the 0.35s guard for the new sheet-
    sourced dismissal, or an explicit live-smoke check of this one interaction.
  - Repro (for Kevin's Mac gate, not required to reproduce a known failure — this is a
    verify-before-ship ask): flip `communityEnabled = true` locally, open the report sheet,
    tap "Street closure," and immediately (within the first ~0.3s) tap a blockface on the
    map. Confirm the tap lands on the map (enters block-select correctly) and that there is
    no visible flash of leftover `ReportSheet` chrome or a dead-tap window longer than what
    the confirmationDialog path already tolerates.
  - Owner: `@ios-engineer`

### 🟢 Minor / nit

- **#2: The 31-test suite doesn't exercise the flag-off invariant at the instance level.**
  - Where: `WeParkTests/ReportSheetPhase2aTests.swift` (all 11 tests call the `static`
    gating functions directly with explicit bool params).
  - What: The tests correctly prove `showsConfirmStreetStep`/`showsStreetClosureTile` return
    `false` when `communityEnabled == false`. They do not prove that `confirmedSegment` is
    actually never reassigned, or that `insertCrowdPin`'s `segmentId` argument equals the
    original `segment.id`, when the flag is off — that guarantee currently rests entirely on
    a manual code trace (which holds today: `confirmedSegment`'s only two write sites are
    `init` and `confirmStreetRow`'s tap handler, which only mounts inside a gated `if`). If a
    future edit adds a second, ungated write path to `confirmedSegment` (or a mount condition
    that doesn't route through `showsConfirmStreetStep`), none of the 31 tests would catch
    the regression — SwiftUI view instantiation isn't straightforward to unit-test without
    ViewInspector or similar, so this is a real but not cheaply-fixed gap. Flagging for
    awareness, not requesting a blocking fix — the current trace is sound.
  - Owner: `@ios-engineer` (follow-up, not this PR)

- **#3: Section header casing diverges from the "visual truth" screenshot; deviation is
  reasonable and disclosed.**
  - Where: `ReportSheet.swift` `confirmStreetSection` — `Text("Confirm the street")`, title
    case, no `.textCase(.uppercase)`.
  - What: `design/screenshots/09-report-confirm-street.png` (visually inspected) shows
    "CONFIRM THE STREET" and "HEADING TOWARD" as small-caps section labels — the prototype's
    established convention. The shipped code uses sentence case, matching this file's own
    *pre-existing* header style ("What kind?", "Direction?", "Which way?" — confirmed all
    three exist verbatim in the file today). The reconciliation spec's verbatim-copy list
    (§6) does not enumerate this label, so this isn't a spec violation, and the PR discloses
    the deviation explicitly and offers to flip it. Ruling: acceptable as shipped; a one-line
    `.textCase(.uppercase)` change is trivial if Kevin wants literal parity with the
    screenshot instead of in-file consistency.
  - Owner: `@ios-engineer` (only if Kevin wants the flip)

- **#4: Duplicated `oppositeSideCandidate` predicate has a one-way cross-reference, not a
  two-way one.**
  - Where: `Services/CandidateSegmentSearch.swift`'s `oppositeSideCandidate(of:in:)` doc
    comment references `ContentView.oppositeSideSegment(of:in:)`; the reverse is not true —
    `ContentView.swift:3098`'s `oppositeSideSegment` has no comment pointing back at the new
    duplicate.
  - What: The duplication itself is a reasonable, disclosed call (avoids a Service→View
    dependency) and both copies are independently unit-tested and currently byte-identical.
    But drift risk is asymmetric: an engineer editing `ContentView.oppositeSideSegment` later
    has no signal that a twin exists in `CandidateSegmentSearch` needing the same edit.
  - Expected: a one-line "kept in sync with `CandidateSegmentSearch.oppositeSideCandidate` —
    update both" comment on the `ContentView` side too.
  - Owner: `@ios-engineer`

- **#5: `CommunityZoneStampingTests.swift`'s header comment claims file-scoped mock
  isolation it doesn't actually have.**
  - Where: `WeParkTests/CommunityZoneStampingTests.swift`, the comment above
    `zoneStampAuthMockSession()`/`zoneStampWriteMockSession()`: "Local mock plumbing...
    but file-scoped (this project's convention: file-private mock URLProtocols + helpers per
    test file, to avoid shared static state races between files running in parallel)."
  - What: The file does not define its own `WriteMockURLProtocol`/`AuthMockURLProtocol` — it
    references the existing `internal`-scoped classes already defined once in
    `Tier3AuthReactionsTests.swift` (`final class WriteMockURLProtocol`, `nonisolated(unsafe)
    static var requestHandler`). Those are shared, mutable, global static state across every
    file in the test target, not file-scoped. The comment's stated rationale ("to avoid
    shared static state races") is not what the code does. Not a functional bug today if the
    test plan runs serially, but it's a misleading comment and a latent flaky-test risk if
    parallel test execution is ever turned on for this scheme — one file's `requestHandler`
    assignment could stomp another's mid-run.
  - Owner: `@ios-engineer` (comment fix; pre-existing shared-mock pattern is out of scope for
    this PR to redesign)

### 💡 Out of scope (logged, not fixed)

- The prototype's "Enforcement active" / "Street sweeper" tile sublabel copy differs from
  this file's shipped sublabels ("Officer or cleaning truck on the block" /
  "Sweeping truck on or near this block" vs. the prototype's "Agent working this block..." /
  "The broom came through..."). The PR correctly leaves these untouched per product rule 7
  (flag-off parity) — the spec's verbatim-copy list also never claimed these two rows for a
  refresh. No action needed in this PR; a hero-parity copy pass (S13) is the right place if
  Kevin wants literal prototype wording on the two pre-existing tiles.
- `ReportSheet.sideDisplayName(_:)` duplicates `ParkConfirmView`'s existing `sideLabel(_:)`
  helper (same N/S/E/W → "X side" mapping). Same shape as Finding #4 — reasonable, low-risk
  duplication, not worth a shared-utility refactor for a 5-line switch.

## Smoke tests run

This PR does not touch `MapViewRepresentable.swift`, `ContentView.swift`'s body/overlay-
attachment code, `Views/DriveMode*.swift`, or any `.safeAreaInset`/toolbar code — confirmed
by reading the full diff (`ContentView.swift`'s changes are confined to `ActiveSheet.reportPin`'s
associated values, two call-site wiring blocks, and the `findCandidateSegments` wrapper body).
Per the mount-chain gate criteria in the QA charter, a live-simulator screenshot smoke is
**not** required for this PR class. No build/xcodebuild was run in this sandbox (no
toolchain) — all verification here is a cold code read against the diff, cross-referenced
against the pre-PR `origin/main` state and the applied production schema
(`supabase/03-community-2.0-schema.sql`).

Specifically verified by direct comparison (not by trusting the PR body):
- `git diff --stat origin/main..65965015` — file list matches the PR's claimed touch list
  exactly; zero-diff claim for the three files confirmed independently.
- `CandidateSegmentSearch.findCandidateSegments` vs. the pre-PR `ContentView` private method —
  byte-for-byte identical algorithm (dedup-by-block-key, sort-by-distance, prefix(max)); only
  the `segments` source changed from an implicit property to an explicit parameter.
- `CommunityZoneBounds` box literals — identical before/after the move, and identical to the
  applied migration's seed values.
- Every non-test call site of `insertCrowdPin` (there is exactly one, `ReportSheet.swift:752`)
  passes `zoneId: nil`, so the write-time stamping added inside `insertCrowdPin` itself
  applies unconditionally to all current and future callers without per-call-site opt-in.
- `confirmedSegment`'s only two write sites (`init`, `confirmStreetRow`'s button action) via
  grep across the full file.
- `enterBlockSelectMode()`'s single other call site (`ContentView.swift:934-936`, the
  pre-existing long-press dialog) is functionally identical to the new one, confirming the
  AC-P2.3 hand-off claim — but see Finding #1 for the one caveat on animation-timing context.
- Copy grep for the five AC-P2.5 banned words across the entire diff — only non-UI comment
  hits.
- Visually inspected `design/screenshots/09-report-confirm-street.png` (Read tool) — confirms
  the ALL-CAPS section header styling behind Finding #3, and confirms the 4-row
  current/opposite/neighbor/neighbor ordering the new test fixture reproduces.

## What's working

- The core flag-off parity argument is exactly as strong as the PR body claims — this is a
  rare case where tracing the state-write graph fully vindicates the stated invariant with no
  hedging needed.
- The W5 extraction is a genuinely careful, behavior-preserving port: the wrapper left in
  `ContentView` is a pure passthrough, and the geometry helpers were correctly left alone in
  `ContentView` because they're still used by unrelated call sites (`handleMapTap`, block-select
  tap) — the PR didn't over-refactor.
- Zone-stamping closes the PR #94 Finding #3 gap cleanly: explicit-wins-over-derived is
  correct, the "outside all zones → genuine nil, never a guess" behavior is explicitly tested,
  and the box values were checked against the actual applied production migration, not just
  copied from the spec doc (which matters — the spec doc's OQ-1 boxes and the QA-corrected
  applied boxes differ on `soho`'s `lat_max`, and this PR has the corrected value).
- Test naming and inventory bookkeeping is accurate: 11+9+11 = 31, and the "982 baseline"
  claim matches the S5 roadmap row.
- The PR body's "Deviations / notes for the orchestrator" section flags exactly the three
  things worth scrutinizing (header casing, unchanged tile copy, duplicated predicate) before
  QA even started looking — that's the right instinct and made this pass faster and more
  targeted.

## What Kevin's Mac gate must cover

1. **`xcodebuild test`, full suite, confirm 1013/1013.** No reason to expect a real compile
   failure from this diff (types are all plausible against the existing `Segment`/`CommunityPin`
   models), but this hasn't touched a real toolchain.
2. **Targeted live-sim check for Finding #1** (not a full mount-chain smoke — this PR
   correctly doesn't need that): flag on, report sheet → "Street closure" → immediate map tap.
   Confirm no dead-tap gap wider than the existing confirmationDialog-sourced path and no
   visual sheet/overlay overlap glitch during the transition.
3. **Flag-off manual pass** (belt-and-suspenders given Finding #2's test-coverage gap): with
   `communityEnabled = false` (shipped default, no override needed), confirm the report grid
   still shows exactly 2 tiles and the enforcement/sweeper submit flow's behavior is
   unchanged from pre-PR `main` — this is cheap to eyeball and directly covers the one gap
   the test suite doesn't.
4. **Flag-on happy path**: confirm-the-street list renders per the screenshot, picking a
   different candidate visibly changes the heading-picker's cross-street chip labels, and the
   submitted pin lands with the picked segment's id (not the original detected one).

No physical device or second phone needed — everything above is Simulator-testable.

---

# QA Pass 2 — 2026-08-28 (Mac-gate blocker fix verification)

**Reviewed:** `6c22b92a` (Pass 1's nit-fixes commit — ALL-CAPS confirm-street label, two-way
`oppositeSideSegment` cross-ref, mock-comment correction; addresses Pass 1 Findings #3/#4/#5,
not independently re-verified line-by-line since none of them touch the bug below) → `c637438d`
(the Mac-gate blocker fix). Diff reviewed: `git diff 6c22b92a..c637438d`. Cold re-read — this
session did not build the fix.

**Reported bug (Kevin, live sim, flag-on, iPhone 17 / iOS 26.5):** tapping "Enforcement active"
in the report sheet tore down the entire flow — report sheet dismissed, browse sheet also gone,
bare map, no crash / no `.ips`. Deterministic ("does not work anymore"), not intermittent.

## 1. RCA credibility

**The elimination step is solid and independently verifiable; the specific touch-mechanism
claim is plausible but not fully nailed down — and it doesn't need to be, because the fix is
mechanism-agnostic.**

- Verified independently (not trusted from the commit message): the only code path in this
  file that sets `blockSelectModeActive = true` — required for the browse sheet to stay hidden
  after dismissal, per `dismissTargetOutsideBrowseNav`'s logic — is `enterBlockSelectMode()`,
  and its only two callers are the pre-existing long-press-dialog "Report closure" button
  (`ContentView.swift:934-936`, unreachable from inside an already-open `ReportSheet`) and this
  PR's `streetClosureRow` → `onRequestStreetClosure` (`ReportSheet.swift:1183`/`:730`). Reported
  symptom (report sheet AND browse sheet both gone) can therefore *only* be produced by
  `streetClosureRow`'s Button firing. This part of the RCA is airtight, not just plausible.
- Verified `reportTypeRow`'s Button action is untouched by this PR (`git diff origin/main -- ...`
  from Pass 1) and never references `onRequestStreetClosure` — so this was never a simple
  "wrong handler wired to the wrong button" bug, confirming the commit message's claim that
  QA's original mis-routing hypothesis was correctly refuted before the fix was written.
- The specific micro-mechanism ("the SAME touch-up raced the relayout") is plausible but not
  fully certain from a code read alone: SwiftUI `Button` fires its action on release, and the
  layout shift (inserting `subTagPickerRow`/`confirmStreetSection`/`headingTowardPickerRow`
  above Row 3) is a *result* of that action, which makes a same-touch-cycle race for the exact
  reported tap mechanistically subtle to pin down without instrumenting a real device. An
  equally consistent alternative mechanism is a second, closely-following tap (e.g. tapping
  once to select the type, then tapping again near the same screen position to proceed/confirm)
  landing on Row 3's new position — also fully deterministic for the same repro steps and
  finger placement. **This nuance doesn't change the verdict**: both variants share the same
  precondition (Row 3's position/hit-target moves as a side effect of selecting a type), and the
  fix eliminates that shared precondition outright, so it resolves the observed defect
  regardless of which precise SwiftUI touch-dispatch behavior was operating. RCA is not
  "wrong," but the commit message states the touch-racing mechanism with more certainty than a
  code read alone can support — worth a lighter-touch phrasing next time, not a blocker.

## 2. The fix — position, flag-off parity, and the shift-under-finger class generally

- **Verified the reorder is exactly what's claimed**: `git diff 6c22b92a..c637438d` shows Row 3
  (`streetClosureRow`, gated by `showsStreetClosureTile`) cut from its old position (after Row
  2's conditional detail) and pasted as the very first element in the `ScrollView`'s `VStack`,
  before Row 1. Rows 1/2 and all their per-type conditional detail blocks
  (`subTagPickerRow`/`confirmStreetSection`/`headingTowardPickerRow`/`sweeperDirectionRow`) are
  byte-for-byte unchanged — confirmed via diff, not just the commit message's claim.
- **Flag-off parity survives the reshuffle — verified, not assumed.** `showsStreetClosureTile`
  returns `false` when `communityEnabled == false`, so Row 3's `if` block renders nothing
  regardless of where it sits in the `VStack` — an absent element has no positional footprint.
  Since nothing else in Rows 1/2's code changed, the flag-off rendered tree (order, content,
  padding) is identical to pre-Phase-2a `main`, exactly as before this fix. The reorder is a
  no-op for the flag-off path by construction, not by luck.
- **The Submit ("Report") button is structurally immune to this entire bug class — verified by
  reading the full `body`.** It lives in a separate `VStack` *outside* the `ScrollView`
  (`Divider()` → error/CTA `VStack` → `.toolbar`), positioned by the outer
  `VStack(alignment: .leading, spacing: 0)`. `ScrollView` clips and scrolls its own content but
  does not resize based on it, so inserting/removing rows inside the `ScrollView` (subtag
  picker, confirm-street section, heading picker, all of it) never moves the Submit button's
  on-screen position by even one point. Directly answers the coordinator's question: the
  heading picker appearing/disappearing below the confirm-street section cannot shift the
  Report button — it's in a different layout container entirely.
- **Residual shift-under-finger risk inside the `ScrollView`, post-fix**: tapping Row 1 still
  shifts Row 2 downward (unchanged pre-existing pattern), and tapping a confirm-street candidate
  can still cause `headingTowardPickerRow` to newly appear/disappear (if the picked segment's
  `oneway`/`onewayToward` differs from the original), which can still shift Row 2 further. This
  is exactly the class the fix's own comment calls out as "harmless" — a mis-hit there only
  re-fires `selectedType = .sweeper` (same-type-selection destination), not a sheet teardown.
  Confirmed: with Row 3 now permanently first and never reactive to `selectedType`, Row 2's
  `reportTypeRow` is the *only* thing that can still be shifted-into by a Row-1-triggered
  relayout, and its action's blast radius is bounded to "re-selects a type," not "destroys the
  flow." No other row is exposed to the class of harm Row 3 was.

## 3. `destination(forTapping:communityEnabled:candidates:)` — not wired into the live tap path

**Confirmed: this is a test-only fiction, and the fix's commit message says so almost as
plainly as this report does — but the framing ("the regression NET") oversells what it
protects.**

- Grepped the full file: `destination(forTapping` appears exactly once — its own `static func`
  declaration (line 945). `reportTypeRow`'s Button action still does `selectedType = type`
  directly; `streetClosureRow`'s Button action still does `onRequestStreetClosure?()` directly.
  Neither calls through `destination(forTapping:)`. There is no other call site anywhere in the
  diff. This is a pure, disconnected model — production behavior is governed entirely by the
  two Button closures, which the routing model merely *describes* without enforcing.
- The new test file's own doc comment is honest about this ("these tests are the regression
  NET, not a literal reproduction of the race... even though it wasn't the literal cause this
  time") — credit for not overclaiming in the code itself. But the top-level commit message's
  framing ("THIS enum is the regression net") reads as stronger than it is: it is a regression
  net for a bug class (wrong destination resolved for a tap) that (a) was explicitly *not* the
  actual root cause here, and (b) is not actually exercised by the real tap handlers, so even a
  regression *in that hypothetical bug class* would not be caught — a future edit could make
  `reportTypeRow`'s Button diverge from what `destination(forTapping:)` says it should do, and
  all 8 new tests would keep passing, because nothing calls the function they're testing.
- The 8 tests themselves are well-constructed and correctly assert the *model's* stated
  contract (flag/type/candidates → destination, tile-identity separation, closure-handoff never
  conflated with a type-select). They're good documentation-as-tests for the intended contract.
  They are not a regression guard for the shipped code today.
- **Recommendation** (not required for this merge, since the actual fix doesn't depend on this
  model): either wire the two Button actions through `destination(forTapping:)` so the model is
  authoritative (turning the tests into real regression coverage), or soften the commit
  message's "regression net" framing to "documents the intended contract" so a future reader
  doesn't mistake test-green for tap-path coverage.

## 4. Count check

`git grep -c "func test"` at `c637438d`: `ReportSheetPhase2aTests.swift` = 19 (was 11, +8
routing tests), `CandidateSegmentSearchTests.swift` = 11 (unchanged — confirmed untouched by
this commit's diff), `CommunityZoneStampingTests.swift` = 9 (unchanged). 19 + 11 + 9 = **39**
(was 31). 982 (S5 baseline) + 39 = **1021** — matches the expected count exactly.

## 5. Disclosed tradeoff — closure tile now first in the flag-ON grid

**Acceptable as shipped.** The prototype's grid order (Enforcement, Sweeper, Spot open, Street
closure — `prototype.html:361-380`) puts closure last in a planned 2×2 grid; this app currently
renders a linear `VStack` of rows (Spot open doesn't exist yet — Phase 2b), so "grid order"
doesn't map cleanly onto the current layout regardless. Moving Street closure to visually-first
is a real, disclosed, flag-ON-only UX deviation from the prototype's ordering, but:
(1) `communityEnabled == false` in production today, so zero live-user impact from this
ordering change until the flag flips; (2) S13's hero-parity pass is already scoped to do a
screenshot-by-screenshot audit and will restructure this exact grid into the prototype's real
2×2 layout once Phase 2b lands "Spot open" — the current vertical-list ordering was never going
to be the final shipped form regardless of this fix; (3) the alternative (a structural fix that
keeps Row 3 visually-last *and* position-stable) is legitimately harder and not worth blocking
a safety-relevant fix on. Ruling: ship as-is, let S13 absorb the reordering.

## New issues introduced by the fix?

None found. Diff is confined to `ReportSheet.swift` (Row 3 relocation + new routing model, both
verified additive/non-destructive to Rows 1/2) and its own test file. `ContentView.swift` and
every other file in this PR's scope are untouched by `c637438d` — re-confirmed via
`git diff 6c22b92a..c637438d --stat`.

## What Kevin's Mac gate must specifically re-run

1. **The exact reported repro**: flag on, open report sheet, tap "Enforcement active" — confirm
   the sheet stays open, sub-tag picker + (if on-segment) confirm-street section appear inline,
   and the browse sheet is unaffected. This is the one that must not regress.
2. **Same check for "Street sweeper" (Row 2)** — not the row Kevin's report named, but it has
   the analogous conditional-detail-insertion pattern; confirm it behaves the same
   (harmlessly re-selects on a stray shift, never tears anything down).
3. **Re-run this session's Pass 1 targeted check (Finding #1, still open)**: "Street closure" →
   immediate map tap, confirm no dead-tap gap / overlay glitch on entry to block-select. Not
   touched by this fix, still outstanding.
4. **`xcodebuild test`, full suite, confirm 1021/1021** (was 1013 at Pass 1's expected count;
   +8 from this fix).
5. **Visual check of the new tile order**: flag on, confirm "Street closure" now renders first,
   above "Enforcement active" — expected per the disclosed tradeoff (§5 above), not a bug if
   seen.

## Verdict

**MERGE-AFTER-MAC-GATE.** The fix correctly and verifiably closes the reported blocker via a
structural change (Row 3 can never move) that is robust regardless of the exact SwiftUI
touch-dispatch mechanism at play, and flag-off parity is preserved by construction, not by
coincidence. No new defect was introduced. The one open item is a documentation/expectations
gap, not a functional one: `destination(forTapping:)` and its 8 tests are not wired into
production and should not be read as regression coverage for this bug class — flagging so
nobody treats "tests green" as "this specific defect can't recur," since the actual protection
here is the structural reorder, not the test suite. Recommend the `@ios-engineer` either wire
the routing model into the live Button actions in a fast-follow, or adjust the commit
message/code comments to stop calling it a "regression net." Neither blocks this merge.
