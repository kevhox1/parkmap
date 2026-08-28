# Community 2.0 Phase 2a (PR #95) QA Pass 1 — 2026-08-28

**Reviewed:** branch `ios/community-phase2a` at `65965015`, against
`docs/community-2.0-reconciliation-spec.md` §3 Phase 2 (AC-P2.3, AC-P2.5),
`docs/community-2.0-roadmap.md` S6 row, `design/prototype.html:361-411`,
`design/screenshots/09-report-confirm-street.png`, `docs/w5-pin-drop-spec.md`.
**Verdict:** MERGE-AFTER-MAC-GATE

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
