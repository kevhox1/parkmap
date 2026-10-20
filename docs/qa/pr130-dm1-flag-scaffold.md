# PR #130 — DM-1 Flag Scaffold QA Pass 1 — 2026-10-20

**Reviewed:** branch `feature/dm1-flag-scaffold` at `d37f26dd`, against `docs/drive-mode-default-spec.md`
(§0.1, §0.4, §0.6 ruling 3, §3.1, §3.3, AC-1/AC-2/AC-14 — DM-1's binding slice only; AC-3 onward are
DM-2/DM-2e/DM-3/DM-4 scope and have no production surface yet to test against).

**Verdict:** MERGE (one 🟡 finding to carry forward into DM-2's dispatch, not a DM-1 blocker)

## Summary

DM-1 does exactly what it says: adds a dark-shipped `AppConstants.driveModeDefaultEnabled = false`
flag and routes `activeSheet`'s initial value and `dismissTargetOutsideBrowseNav`'s rest-state branch
through one new shared pure function, `driveModeDefaultRestStateSheet(driveModeDefaultEnabled:)`.
The diff is exceptionally tight for `ContentView.swift` (the repo's worst-regression-history file) —
66 insertions / 2 deletions across exactly the three files the spec's §3.3 file-ownership table
assigns to this stream, nothing more. The flag-off byte-identical claim (AC-1) checks out by direct
code trace, and the PR correctly closes the exact "default-parameter-binding gap" class a prior QA
pass flagged for `RegularsFlagGuardTests`. One real gap: two pre-existing, undocumented `.browseNav`
literal-assignment sites elsewhere in `ContentView.swift` were not folded into the new shared
function, and will misbehave once the flag flips — not a DM-1 regression (both sites predate this
PR and DM-1 never claimed to own them), but DM-2's engineer needs to know about them before
wiring the ambient screen's dismiss behavior on top of an incomplete "both rest-state sites" model.

## Acceptance criteria checklist (DM-1's slice)

- [x] **AC-1 (`activeSheet` default + `dismissTargetOutsideBrowseNav`):** verified by direct code
  trace. `@State private var activeSheet: ActiveSheet? = driveModeDefaultRestStateSheet()` and
  `dismissTargetOutsideBrowseNav`'s rest-state branch both call the same no-arg function, whose
  default parameter reads the real `AppConstants.driveModeDefaultEnabled` (currently `false`) →
  both resolve to `.browseNav`, byte-identical to pre-DM-1 behavior. Backed by
  `testActiveSheetDefault_resolvesBrowseNav_whenFlagOff`,
  `testDismissTargetOutsideBrowseNav_resolvesBrowseNav_whenFlagOff`, and — the gap-closing one —
  `testRestStateSheet_defaultParameter_matchesShippedFlag`, which specifically proves the no-arg
  call site (what `ContentView` actually uses) is wired to the live flag rather than only testing
  an explicit `false` argument. I independently grepped both real call sites
  (`ContentView.swift:492`, `:1268`) and confirmed neither passes a literal — both use the
  no-arg form. This is exactly the gap class `RegularsFlagGuardTests.testRegularsSettingsRow_
  hidden_whenDisabled` once closed for `regularsEnabled`, and it's closed correctly here too.
- [x] **AC-2 (no ambient pill / Search icon / priming card render anywhere while flag off):**
  trivially true — DM-1 adds no new View, no new render path. `testFlagOff_noNewUISurfaceIntroducedByDM1`
  documents this honestly (see Minor finding below re: it being an empty assertion) rather than
  silently omitting AC-2 from the test inventory.
- [x] **AC-14 (this stream's slice — named guard tests, no `Calendar.current`, no `import SwiftUI`
  in service files):** 6 tests, each named per a specific AC/claim, no tautologies except the one
  flagged below. `Constants.swift` diff has no `Calendar.current`, no `import SwiftUI`. Full
  `xcodebuild test` exit-0 is honestly deferred to Kevin's Mac gate — both the test file and the
  prior `FT20StreamCTests.swift` precedent are marked `[COMPILE-UNVERIFIED]` (no toolchain on this
  box); I could not run the suite either. **Not verified — recommend Mac-side `xcodebuild test`
  before flipping the flag or landing DM-2 on top of this.**
- [ ] **Flag-on coherence (not a spec AC number, but §0.4's explicit "half-converted" trap, and
  this review's binding checklist item #3) — PARTIAL.** See 🟡 Finding #1. The two call sites the
  spec names (`activeSheet` default, `dismissTargetOutsideBrowseNav`) are correctly unified.
  Two OTHER, pre-existing literal `.browseNav` assignments elsewhere in the file are not, and will
  resolve to `.browseNav` instead of `nil` once the flag flips, contradicting AC-6/AC-30's "every
  dismissal lands on the ambient rest state."

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: Two pre-existing literal `.browseNav` restores bypass the new shared rest-state function
  — DM-2 will inherit a silent half-converted state unless told**
  - Where: `ContentView.swift:1114` (the top-level `.sheet(item:, onDismiss:)` catch-all backstop
    — the mechanism that restores `.browseNav` after any dismiss path that doesn't already route
    through `dismissTargetOutsideBrowseNav`, e.g. interactive swipe-to-dismiss on `.settings`,
    `.mapKeyLegend`, or `.regularsInviteRedemption`, confirmed via the catch-all's own doc comment
    at `:1698`); and `ContentView.swift:4467` (the `.onChange(of: driveModeActive)` handler's
    `.browseNavAtPeek` branch, which fires on every Drive Mode exit and unconditionally sets
    `activeSheet = .browseNav` when nothing else has already claimed it).
  - What: both sites hardcode the `.browseNav` literal directly, rather than calling
    `driveModeDefaultRestStateSheet()` (or going through `dismissTargetOutsideBrowseNav`, which
    now correctly does). I grepped every `activeSheet = ` and `= \.browseNav` occurrence in the
    diffed file (46 assignment sites total) — these are the only two that bypass the new shared
    function while not being one of the file's own documented deliberate force-hides (contrast
    with `enterBlockSelectMode()`'s `activeSheet = nil` at `:3954`, which has an explicit doc
    comment at `:3932` explaining why it's intentionally a literal, not a dismiss-target call).
  - Expected (spec §0.4): "Both the initial `@State` and this rest-state target must flip together,
    or this ships half-converted" — the spirit of that line is "every place that currently assumes
    `.browseNav` is the rest state," not just the two named variables. Once the flag flips, a user
    who swipe-dismisses `.pinDetail` or exits an escalated Cruise session (entered via DM-2's
    future ambient-screen "start driving" affordance, §0.8.7) will land back in the full
    `.browseNav` sheet instead of the ambient nil rest state — the exact AC-6/AC-30 regression the
    spec is explicit about avoiding.
  - Repro (once flag flips to `true` in a later build): (a) open any sheet with no explicit
    `onDismiss` closure of its own (e.g. `.settings`) and swipe it away — `activeSheet` lands on
    `.browseNav`, not `nil`. (b) Enter the escalated Cruise session via DM-2's future secondary
    "start driving" affordance, then exit Drive Mode — `activeSheet` lands on `.browseNav` at peek
    instead of the ambient home screen.
  - Severity note: **not a DM-1 regression** — both sites predate this PR, flag dark-ships `false`
    today, and DM-1's own stated scope (§4 work-streams table: "Flag scaffold +
    `activeSheet`/`dismissTargetOutsideBrowseNav` default flip + guard tests") never claimed to own
    these. Flagged 🟡 because the new function's own doc comment ("Both call sites read this SAME
    function so they can never drift apart") overclaims completeness in a way that could give
    DM-2's engineer false confidence there are only two rest-state sites in the file. Recommend:
    either (a) a one-line addendum to this PR's description naming these two sites explicitly as
    "known, not yet converted" for DM-2's engineer to pick up, or (b) fold the two-line fix into
    DM-2 itself when it wires `BrowseNavigationSheet`'s presentation rework (same stream that
    already owns "reconciling the demoted escalation trigger... with the goal selector's new
    layout" per spec §3.3/§2.1 item 15).
  - Owner: `@ios-engineer` (DM-2, or a trivial DM-1 follow-up before DM-2 starts).

### 🟢 Minor / nit

- **#2: `testFlagOff_noNewUISurfaceIntroducedByDM1` has no assertions.**
  - Where: `WeParkTests/DriveModeDefaultFlagTests.swift`.
  - What: the test body is a comment only — no `XCTAssert*` call. The doc comment is honest about
    why ("AC-2 has no production code surface yet to assert against... DM-1 adds no new view, no
    new render path") and I agree this is better than silently omitting AC-2 from the test
    inventory. Still, a reader skimming test names/counts (e.g. "6/6 passing") would reasonably
    assume all 6 assert something. Low priority — worth deleting or converting to a real assertion
    once DM-2/DM-3 land actual UI to check against.
  - Owner: `@ios-engineer`, no urgency.

### 💡 Out of scope (logged, not fixed)

- Everything downstream of DM-1 — goal selector UI, `isFree(ignoringMeteredPayment:)`, priming
  card, auth-request fix, empty-map guard, full-palette toggle (AC-3 through AC-32) — correctly has
  zero production surface in this PR and is explicitly deferred to DM-2/DM-2e/DM-3/DM-4 per the
  spec's own work-stream table. Nothing to QA here yet.

## Smoke tests run

- **Diff inspection:** `git diff origin/main..origin/feature/dm1-flag-scaffold --stat` — confirmed
  exactly 3 files touched (`ContentView.swift`, `Services/Constants.swift`, new
  `WeParkTests/DriveModeDefaultFlagTests.swift`), 66 insertions / 2 deletions. Matches spec §3.3's
  file-ownership table for DM-1 exactly — no drive-by changes found.
- **Exhaustive `.browseNav` / `activeSheet =` grep** across the full post-diff `ContentView.swift`
  (46 assignment sites, ~90 comment/reference hits) — confirmed only 2 of 46 assignment sites bypass
  the new shared function (Finding #1); all others correctly route through
  `dismissTargetOutsideBrowseNav` or are documented deliberate force-hides.
  `driveModeDefaultRestStateSheet()`'s two real call sites (`:492`, `:1268`) both confirmed to use
  the no-arg form (reads the live flag), not a literal — closes the exact gap class flagged for
  verification.
- **Biggest-risk invariant:** confirmed via `git diff ... | grep driveModeActive` and a direct diff
  of `LocationService.swift` that the diff never modifies `driveModeActive`'s definition,
  `enterCruiseMode()`'s escalation body, or `LocationService.swift` at all (zero lines changed in
  that file). The one-boolean-gates-two-postures risk this spec's header paragraph warns about is
  not implicated by this PR.
- **`noBlockingSheetPresented` rationale, independently re-traced (not just trusted from the PR
  description):** grepped `onCruiseTapped` and `enterCruiseMode()`'s only call site
  (`ContentView.swift:1785`, wired to `BrowseNavigationSheet`'s "Find a Spot" button) and confirmed
  it can only fire while `activeSheet == .browseNav` is presented, in both flag states, because
  DM-1 doesn't move that entry point. The PR's decision to leave the `.browseNav` special case in
  `noBlockingSheetPresented` (rather than deleting it per the spec's "likely can be deleted"
  suggestion) is correct and independently verified, not just taken on faith.
- **Compile-failure-class static scan** (no toolchain available, per project norm): checked for
  literal-receiver contextual-type issues (the `driveModeDefaultEnabled ? nil : .browseNav` ternary
  mirrors the already-shipped `browseSheetBoundaryTarget` pattern — fine), labeled-arg order
  (single-parameter function, no ambiguity), memberwise-init order (no new structs), bare
  `Category` (not present), `Calendar.current` / `import SwiftUI` in service files (absent from the
  `Constants.swift` diff). The new function's explicit `nonisolated` modifier is defensible but
  inconsistent with sibling top-level functions in the same file
  (`browseSheetBoundaryTarget`, `parkingGuideButtonVisible`, etc.) that are tested the same way
  (plain, synchronous `XCTestCase` methods) without `nonisolated` — I could not determine from
  static reading alone whether the module's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build
  setting (confirmed present in `project.pbxproj`) actually requires it or whether it's harmless
  defensive redundancy; either way it is not a compile-breaking addition. **Not verified — compile
  is Kevin's Mac-side gate**, consistent with this file's own `[COMPILE-UNVERIFIED]` header and the
  project's established environment split.
- **Mount-chain live-UI-smoke applicability check:** confirmed this diff touches no `View` body, no
  `.safeAreaInset`, and does not touch `MapViewRepresentable.swift` or any `Views/DriveMode*.swift`
  — the PR's own claim that the mandatory live-UI-smoke gate doesn't apply to this slice is accurate
  by direct inspection, not merely taken on the PR description's word. No screenshot smoke performed
  or required for this PR.
- **pbxproj / backend / PWA scope check:** confirmed `project.pbxproj` untouched (project uses
  `PBXFileSystemSynchronizedRootGroup`, so the new test file needs no manual registration) and no
  Supabase/backend/PWA files appear in the diff — matches spec §3.2's "iOS only, no backend work."

## What's working

- Exemplary smallest-possible-diff discipline in `ContentView.swift`, the file with this project's
  single worst regression history — exactly the files/lines the spec's §3.3 table assigns, nothing
  extra.
- The exact "default-parameter-binding gap" class a prior QA pass caught for `regularsEnabled` is
  explicitly, deliberately closed here with a dedicated test
  (`testRestStateSheet_defaultParameter_matchesShippedFlag`) rather than left as an implicit
  assumption — a genuine process improvement carried forward from a past finding.
- The `noBlockingSheetPresented` "verify, don't assume" instruction from the spec was actually
  honored — the engineer traced the real call site, found the special case still load-bearing, and
  documented why rather than either blindly deleting it or blindly leaving it unexplained. I
  independently reproduced the same conclusion from the code.
- Flag constant (`AppConstants.driveModeDefaultEnabled = false`) is a clean, doc-commented copy of
  the `communityEnabled`/`regularsEnabled` precedent — no new pattern invented, no drift.
  Dark-ship discipline (defaults `false`, guard tests in place, named per-AC) matches the PR #109
  playbook this project has already validated once.
- Honest, non-defensive framing throughout the PR description about what's deferred to the Mac
  gate (compile, full test run) versus what's actually verifiable here — no overclaiming of a
  `xcodebuild test` pass that didn't happen.
