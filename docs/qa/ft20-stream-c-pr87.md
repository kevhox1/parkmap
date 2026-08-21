# FT-20 Stream C (ContentView Integration — gate flip) QA Pass 1 — 2026-08-21

**Reviewed:** branch `ios/ft20-stream-c-integration` at `b638dab4`, against
`docs/ft20-bottom-sheet-navigation-spec.md` §0/§0b/§0c/§0d/§5/§6/§7 (full AC-1–35 sweep),
`docs/design/ft20-bottom-sheet-review.md`, `docs/qa/ft20-stream-a-pr85.md` (both passes),
`docs/qa/ft20-stream-b-pr86.md`.
**Environment:** Linux VPS — no Xcode, no simulator, no `xcodebuild`. This is a static code
read plus exhaustive `grep`/data-flow tracing; nothing below is a compile or runtime claim.
Kevin compiles and runs the 14-item live smoke on his Mac in parallel.
**Integrity check:** `git status` / `git diff HEAD` confirmed clean before drafting any
finding — the worktree matches `HEAD` (`b638dab4`) exactly. All findings are against the
actual committed diff (`git diff origin/main...HEAD`), not on-disk state.

**Verdict:** ✅ **READY FOR MAC COMPILE + SMOKE + MERGE.** This is careful, disciplined work
that correctly lands every piece of safety net its own predecessor's gate comment demanded,
and every claim I could independently verify by tracing the actual state machine (not by
trusting the doc comments) held up. I found zero blocking defects. One 🟡 finding (the C1/C2
fixes ship with no new regression test coverage) is real and should be tracked, but it is not
a reason to hold this PR — the underlying mechanism is sound by inspection, and Kevin's live
smoke is the actual gate for the geometry/timing claims regardless of what tests exist.

## Summary

I re-examined this PR with the explicit assumption that nothing "unreachable, therefore fine"
in the Stream A/B reviews is still fine now that `ft20BrowseSheetEnabled = true`. Three things
stood out as the highest-risk claims in the PR description, and I verified each independently
rather than trusting the commit message:

1. **The Drive-Mode-boundary clobber guard (the arrival-prompt "Park Here" → `.parkUntil`
   race) is correct, and it is the ONLY instance of that bug class in the file.** I traced
   every `driveModeActive = true/false` assignment site (exactly 2: `enterCruiseMode()`,
   `onRouteReady`) and every code path reachable from `handleDriveModeAndCamera` (the single,
   unbypassable `.onChange(of: driveModeActive)` funnel — confirmed exactly one such
   `.onChange` exists in the file), and found exactly one closure that sets `activeSheet` in
   the same synchronous scope as a `driveModeActive` flip: the arrival-prompt's `onParkHere`.
   The `if activeSheet == nil { activeSheet = .browseNav }` guard correctly lets that
   auto-fired `.parkUntil` win. No second instance exists.
2. **The dismiss-target sweep (Stream A's ~15 converted sites), now live, cannot return to
   `.browseNav` at the wrong moment.** `dismissTargetOutsideBrowseNav` re-evaluates
   `driveModeActive`/`blockSelectModeActive` live at the moment of dismissal (it's a computed
   property, not a captured value), so every one of the 14+ case-dismiss closures I walked
   individually resolves correctly regardless of when it fires — mid-drive, mid-block-select,
   or ordinary browse-mode dismissal. I could not construct a scenario, by trace, where
   `activeSheet` gets stuck at a bare `nil` in ordinary browse mode (the inverted trap state
   the task asked me to hunt for) — see "Priority 1 investigation" below for the full argument.
3. **The C1 fix (`BrowseSheetSearchAreaHeightPreferenceKey`) is a genuine, structurally sound
   fix for the greedy-`List` problem, and does not risk a measure→resize→re-measure feedback
   loop.** See the dedicated section below — this was the one place I expected to find a real
   problem and didn't.

The one real gap: **the C1/C2 fixes (both carried forward from Stream B's QA report as
binding on Stream C) ship with zero new test coverage** — `BrowseSearchAreaViewTests.swift`
is zero-diff. I traced both mechanisms by hand and believe them correct, but "QA traced it by
hand" is a weaker guarantee than a regression test, especially on the one file in this
codebase with a repeated history of "210/0 tests, feature broken in the live app."

## Acceptance criteria checklist (§7, full sweep — independent verification, not the
author's own checklist)

**Sheet mechanics**
- [x] AC-1 (always one of 3 detents in browse mode) — `activeSheet` defaults to `.browseNav`
  (`ContentView.swift:75`); every dismiss/restore path funnels through
  `dismissTargetOutsideBrowseNav` or the two boundary functions, all of which resolve to
  either `.browseNav` or a deliberate `nil` (Drive Mode / block-select only). No path found
  that leaves `nil` in ordinary browse mode — see Priority 1 section.
- [x] AC-2 (never interactively dismissible to nothing) — `.interactiveDismissDisabled(true)`
  on `.browseNav`'s presentation, unchanged from Stream A, now live at the real call site
  (`ContentView.swift:1314`).
- [x] AC-3 (peek on cold launch and Drive-Mode-exit) — `browseSheetDetentKind` defaults to
  `.peek` (`ContentView.swift:397`); `browseSheetBoundaryTarget(driveModeBecameActive: false)`
  → `.browseNavAtPeek` explicitly sets `browseSheetDetentKind = .peek` unconditionally on
  exit (`ContentView.swift:2975`), even in the guarded-out clobber branch.
- [x] AC-4 (search visible at every detent) — `BrowseSearchAreaView.body`'s `searchField` is
  the first, unconditional `VStack` child; only the recents/suggestions/place/error content
  is gated on `detentKind == .large`.
- [x] AC-5 (tap → large + focus) — `.onChange(of: searchFieldFocused)` sets
  `detentKind = .large`, unchanged from Stream B, now reachable.
- [~] AC-6 (drag snaps to nearest of 3) — system-sheet default behavior under Option A; not
  independently re-verifiable without a device. Not touched by this diff.

**Search, place, Go** — AC-7–14: unchanged from Stream B (zero-diff on the relevant logic
except the two named QA fixes, C1/C2), now genuinely live. Verified by inspection that no
Stream C change altered `selectCompletion`/`fetchRouteAndReturn`/`clearResolved` bodies.

**Medium-detent list** — AC-15–18: unchanged from Stream A (zero-diff on `actionList`,
`onSettingsTapped`/`onCruiseTapped`/`onParkingGuideTapped` wiring), now genuinely live.

**Removed / relocated chrome**
- [x] AC-19 (gear/`?` gone as floating controls) — `gearButtonOverlay` deleted
  (`ContentView.swift` diff, `-1552…-1570` region); confirmed no other call site references
  it (`grep` clean).
- [x] AC-20 (`driveEntryButton` deleted, no menu) — deleted along with its two Menu items;
  confirmed no reference remains.
- [x] AC-21 (Locate/Find-my-car unaffected) — both buttons' bodies untouched in the diff
  (only surrounding doc comments changed).
- [x] AC-22 (Park Until preserves 100% of its behavior) — **verified: genuinely NOT touched.**
  `parkUntilMode`/`ParkUntilPill`/the `clock.fill` button's own body (icon, `.background`,
  `.accessibilityLabel`, tap handler `activeSheet = .parkUntil`) all have zero diff. It was
  already the 3rd button in `recenterButtonStack`, alongside Find me / Find my car — deleting
  the 4th button (`driveEntryButton`) is structurally sufficient to make it "the last button
  in a 3-button stack" without moving a single line of Park Until's own code. The PR's "needed
  no relocation" claim is accurate, not a rationalization — confirmed by direct diff read, not
  by trusting the commit message.

**FT-15 boundary**
- [x] AC-23 (block-select entry hides sheet entirely) — `enterBlockSelectMode()`'s
  unconditional `activeSheet = nil` is untouched, confirmed still correct now that
  `.browseNav` is the rest state (see Priority 1 below).
- [x] AC-24 (`blockSelectBar` unmodified) — zero-diff.
- [x] AC-25 (exit restores `.browseNav` at prior detent) — `cancelBlockSelectMode()` now sets
  `activeSheet = dismissTargetOutsideBrowseNav` (new); the report-sheet's dismiss
  (`.blockRestrictionReport`'s `onDismiss`) already routed through the same helper and
  correctly resolves to `.browseNav` once `blockSelectModeActive` is false (set false before
  the report sheet opens, in `submitBlockSelectReport()`). `browseSheetDetentKind` is
  untouched by either block-select entry or exit, so "restores... at whatever detent it was
  at" holds for free, as claimed.
- [x] AC-26 (block tap outside block-select unaffected) — `handleMapTap`/`dismissBlockDetail`
  unchanged by this diff.
- [x] AC-27 (FT-15 restriction banner inside detail sheets unchanged) — zero-diff.

**Drive Mode boundary**
- [x] AC-28 (no overlap frame on entry) — `browseSheetBoundaryTarget(true)` → `.hidden`,
  unconditional `activeSheet = nil`, applied as the FIRST statement inside
  `handleDriveModeAndCamera` — the single funnel every entry path (`enterCruiseMode()`,
  `onRouteReady`) runs through. Same synchronous transaction as the Bottom Dock's own
  `driveModeActive`-gated appearance. No code path found that sets `driveModeActive = true`
  outside this funnel (exhaustive `grep`, 2 sites, both funnel through it).
- [x] AC-29a (no overlap frame on exit) — mirror case, `.browseNavAtPeek`, same funnel.
  Verified the one real interaction risk (the arrival-prompt clobber) by hand — see Priority 1
  investigation.
- [x] AC-30 (zero touches to `MapViewRepresentable.swift`) — **confirmed by direct diff**:
  `git diff origin/main...HEAD -- ios/WePark/WePark/MapViewRepresentable.swift` returns
  0 lines. `recenterDriveMode()` doesn't appear anywhere in the Stream C diff at all (not even
  in a comment). `endDriveControl`/`recenterRow` appear only in comment-only hunks — their
  bodies are byte-identical to `origin/main`.
- [x] AC-31 (FT-17a unaffected) — follows from AC-30's zero-touch guarantee, not re-tested.

**Non-goals held**
- [x] AC-32 (no hardcoded light-mode colors) — the new code in this PR
  (`BrowseSheetSearchAreaHeightPreferenceKey`, `browseSheetBoundaryTarget`,
  `blockSelectTapShouldBeIgnored`) is pure logic/preference-key plumbing with zero color
  literals.
- [x] AC-33 (no Drive-Mode-active visual changes) — Bottom Dock components zero-diff.

**Accessibility**
- [~] AC-34/35 — unchanged from Stream A's already-verified state; not independently
  re-verifiable without a device.

## Priority 1 investigation: can any live path strand the user with no sheet and no way back?

**No — not found, by exhaustive trace, not by sampling.** The reasoning:

`activeSheet` can only ever be a bare `nil` via three mechanisms, and all three are
self-healing by construction:
1. **`enterBlockSelectMode()`'s unconditional `activeSheet = nil`** — restored by
   `cancelBlockSelectMode()` (Cancel button) or the block-restriction report sheet's dismiss,
   both of which resolve through `dismissTargetOutsideBrowseNav` → `.browseNav` (block-select
   is already false by the time either fires).
2. **`handleDriveModeAndCamera`'s `.hidden` case** on Drive Mode entry — restored
   unconditionally (modulo the one documented guard) by the mirror `.browseNavAtPeek` case on
   exit, and Drive Mode can only be exited via `endDriveMode()`, which is called from exactly
   2 sites, both of which flow back through the same funnel.
3. **`dismissTargetOutsideBrowseNav` itself resolving to `nil`** while `driveModeActive` or
   `blockSelectModeActive` is true — this is *correct* behavior (the sheet should stay hidden
   during those modes), not a trap, and it self-corrects the instant either mode ends via
   mechanism #1 or #2 above.

I additionally traced the **interactive swipe-dismiss path** (not just the explicit
close-button closures), since that's the path most likely to bypass a hand-written
`onDismiss` closure: the top-level `.sheet(item: $activeSheet, onDismiss: { ... })` backstop
(`ContentView.swift:797-804`) fires for *any* dismissal, including a swipe, and independently
re-checks `activeSheet == nil, !driveModeActive, !blockSelectModeActive` before restoring
`.browseNav` — so a user swiping away e.g. `ParkedCarDetailView` or the block-restriction
report sheet (neither has `.interactiveDismissDisabled`) is caught by the backstop even though
no `onDismiss:` closure in `sheetContent` fired. I did not find a sheet case with
`.interactiveDismissDisabled(true)` set *and* no dismiss path back to `.browseNav` outside
Drive Mode/block-select — the one interactiveDismissDisabled case that exists
(`.notificationRationale`) still routes its own explicit `onDismiss` through the shared
helper.

**Conclusion: no inverted-trap state found.** This is the single highest-stakes claim in the
whole PR and I could not break it by trace.

## Priority 2: the two Drive-Mode boundary transitions

**AC-28/AC-29a funnel completeness** — confirmed exhaustive, not assumed: exactly one
`.onChange(of: driveModeActive)` exists in the file (`ContentView.swift:1554`), and exactly
2 assignment sites can ever set `driveModeActive = true` (`enterCruiseMode()`, the `onRouteReady`
closure) and exactly 1 can set it `false` (`endDriveMode()`, itself called from exactly 2
sites: the arrival-prompt's `onParkHere`, and `endDriveControl`'s "End" button). Every one of
these funnels through the single `.onChange`. This is not a "probably" — SwiftUI fires
`.onChange` for *any* write to the observed `@State` property regardless of call site, so the
funnel's completeness is structural, not dependent on the author remembering to route every
call through one function.

**The clobber guard** (`if activeSheet == nil { activeSheet = .browseNav }` inside the
`.browseNavAtPeek` case): I did the sweep the task asked for — searched every closure that
touches `driveModeActive` for a co-located `activeSheet` write in the same synchronous scope.
Found exactly one: the arrival-prompt's `onParkHere` (`activeSheet = dismissTargetOutsideBrowseNav`
→ `save()` → `endDriveMode()` → `activeSheet = .parkUntil`, all in one closure). SwiftUI
batches all of these writes into a single transaction before `.onChange` fires, so by the time
`handleDriveModeAndCamera(false)` runs, `activeSheet` already holds `.parkUntil` — the guard
correctly does not overwrite it. No second instance of this bug class exists in the diff.
(One related, **pre-existing, NOT Stream-C-introduced** observation: if this is a user's
literal first-ever pin drop via the arrival-prompt path, `parkPinService.save(car)`
synchronously fires `firstPinDropped` → `handleFirstPinDropped()` → `activeSheet =
.notificationRationale`, which then gets immediately overwritten by the very next line,
`activeSheet = .parkUntil`, in the *original*, unmodified W8.5d code — confirmed byte-identical
on `origin/main` before this PR. Not a Stream C regression; noted for team awareness, not a
finding against this PR.)

**Block-select settling window** (`blockSelectEntryGuardUntil` / `blockSelectTapShouldBeIgnored`):
the mechanism is sound. It's a plain `Date` deadline compared with a strict `<`, so:
- It cannot fail to expire — wall-clock time is monotonic, so `now < guardUntil` is guaranteed
  to eventually become permanently `false`. There is no code path that could leave the map
  "tap-deaf forever."
- Backgrounding mid-guard is a non-issue by construction: since the comparison is against
  wall-clock `Date`, not a `Timer` (which could be invalidated/paused), the guard simply
  expires in the background exactly as it would in the foreground — by the time the user
  returns, `.now` is almost certainly already past `guardUntil` regardless of what iOS did to
  the app in between.
- The guard is correctly reset (`= nil`) on both exit paths (`cancelBlockSelectMode()`,
  `submitBlockSelectReport()`) and freshly re-set on every `enterBlockSelectMode()` call, so
  there's no stale-deadline leakage across sessions.
- The 0.35s constant itself is explicitly, honestly flagged as unmeasured by the author — this
  is correctly Kevin's live-smoke item, not a code defect.

## Priority 3: the C1 substitution — independent opinion

**My independent assessment: this is a better mechanism than the originally spec'd
`@ScaledMetric` + `.frame(height:)` approach, and it does not risk a feedback loop.**

The reviewer's worry (measure → resize → re-measure) requires a closed loop: the measured
value would have to feed back into a layout constraint on the *same view being measured*.
I traced the actual data flow and it's a strict, one-way DAG, not a loop:

```
searchField's own content/font/padding
    → GeometryReader (.background) reports searchField's OWN laid-out size
    → BrowseSheetSearchAreaHeightPreferenceKey bubbles up
    → BrowseNavigationSheet.searchAreaHeight (@State)
    → BrowseSheetDetentMath.peekHeight / .mediumHeight
    → ContentView's browseSheetPeekHeight / browseSheetMediumHeight (@State)
    → .presentationDetents(...) / .presentationBackgroundInteraction(...) on the SHEET CONTAINER
```

Nothing in that chain writes back to anything that constrains `searchField`'s own size.
`searchField` has no `.frame(height:)` tied to any derived value, reads no environment value
that changes with detent, and its parent `VStack` doesn't stretch non-flexible children —
critically, this whole chain rests on Stream A's own established (and previously
QA-scrutinized) claim that **"a system sheet's content is laid out against the FULL
`.large`-sized container regardless of which detent is currently visible."** If that holds
(and it was independently verified in Stream A's Pass 1 QA, not re-litigated here), then
`searchField`'s layout *input* — the container height it's laid out against — never changes
as a function of the *output* it produces (`peekHeight`/`mediumHeight`). No loop is possible.

It also genuinely solves the problem it claims to: because the `List`/place-state/error
content is a VStack **sibling** of `searchField`, not a descendant, the `GeometryReader`
attached via `.background` on `searchField` structurally cannot see or be influenced by
whatever that sibling reports — this is a stronger guarantee than "constrain the whole slot's
frame," because it doesn't rely on getting a ceiling estimate right (the `@ScaledMetric`
approach in the spec would have required deriving a magic number for the search field's height
that has to stay right across Dynamic Type sizes); it just measures the true value directly.
This is, if anything, more robust to accessibility text-size changes than the originally
specified approach, since it reflects the search field's real rendered height rather than an
estimate.

**One caveat, not a defect:** this correctness rests entirely on manual data-flow tracing —
see the test-coverage finding below.

## Priority 4: deletion safety

- `SearchCompleterDelegate`, `SearchTimeoutError`: exactly one declaration each, now in
  `Services/SearchCompleterDelegate.swift`. `RecentDestinationsStore`: exactly one
  declaration, in its own pre-existing file, correctly untouched. Every reference resolves —
  `grep` for `DriveModeDestinationView` across the whole tree returns only comments (18 hits,
  all in doc comments/`//` lines), zero live type references.
- `Views/DriveModeDestinationView.swift` confirmed deleted (619 lines removed, file absent on
  disk).
- `gearButtonVisible`/`parkingGuideButtonVisible`: confirmed genuinely dead — defined in
  `ContentView.swift`, still covered by `FT13Tests.swift`/`FT18Tests.swift`, but zero
  production call sites remain. Reasonable to leave for now, given the stated rationale
  (avoid unrelated test-file churn on an already-large, high-risk diff) — see 🟢 finding below
  for the follow-up recommendation.
- Nothing else references the deleted view or its former properties (`showDriveModeDestination`,
  `driveModeDestinationCover`, `driveEntryButton`) — confirmed by `grep`, zero hits outside
  this PR's own doc-comment history notes.

## Priority 5 / test-count arithmetic

Ran `git grep -c "^\s*func test"` against `origin/main` and `HEAD` for
`ios/WePark/WeParkTests/*.swift`: **776 on `main`, 780 on `HEAD`** — exactly matching the
claimed arithmetic (776 + 6 new `FT20StreamCTests.swift` − 2 removed `DriveModeDestinationView`
render-smoke tests in `W85bTests.swift` + 4 ported-at-net-zero in `W85cTests.swift`).

No `let`-with-default-value memberwise-init pitfall found in any new/changed struct:
`BrowseSheetSearchAreaHeightPreferenceKey` has no instance stored properties (only a
`static var`/`static func`, not subject to the memberwise-init issue); `BrowseSheetDriveBoundaryTarget`
is an enum. `BrowseSearchAreaView` retains its pre-existing explicit custom `init` (unchanged
by this PR). Brace/paren balance checked on all 8 touched Swift files — all balanced (not a
substitute for compilation, flagged as such).

## Findings

### 🔴 Blocking

None found.

### 🟡 Significant

**#1 — The C1 (`BrowseSheetSearchAreaHeightPreferenceKey`) and C2 (auto-expand-to-`.large`-on-error)
fixes ship with zero new regression test coverage.**
- **Where:** `ios/WePark/WeParkTests/BrowseSearchAreaViewTests.swift` — confirmed zero-diff
  (`git diff origin/main...HEAD` returns nothing for this file), despite two behavior-affecting
  fixes landing in `BrowseSearchAreaView.swift`/`BrowseNavigationSheet.swift` in this same PR.
- **What:** `BrowseSearchAreaViewTests.swift`'s existing suite only asserts
  `host.view != nil` (render-smoke) and never exercises geometry, `PreferenceKey` propagation,
  or `detentKind` binding mutation. Neither new mechanism has a test that would catch a future
  regression:
  - Nothing asserts that `searchField`'s reported height feeds `peekHeight`/`mediumHeight`
    correctly, or that it stays small when the sibling `List` is showing at `.large`.
  - Nothing asserts that setting `errorMessage` (e.g. via the existing
    `MockRouteServiceThrowingNetwork` fixture, which the file already has) actually mutates
    the `detentKind` binding to `.large` — the existing route-error test passes
    `detentKind: .constant(.large)`, which cannot detect a regression in the auto-expand logic
    since it starts already-expanded.
- **Why it matters:** Both C1 and C2 were binding QA carry-forwards from Stream B specifically
  *because* they're invisible to a render-smoke-only test suite (Stream B's own QA report
  said as much: "nothing in this suite would have caught it"). I traced both mechanisms by
  hand and believe them correct (see the Priority 3 section and the AC-9/AC-12 sweep above),
  but manual QA tracing is a weaker, non-repeating guarantee than a test — this is precisely
  the codebase with a documented history of "tests all green, feature broken in the live app"
  (W8.5c-polish, 210/0). A future refactor of `BrowseSearchAreaView`'s body structure could
  silently reintroduce either bug with the test suite staying fully green.
- **Fix (not prescribing, QA doesn't fix):** Add a test that starts a `BrowseSearchAreaView`
  hosted with a real `@State`-backed binding (not `.constant()`), triggers the mock
  network-error path, and asserts the binding's wrapped value becomes `.large`. The C1
  geometry claim is harder to test without a snapshot/ViewInspector library this repo doesn't
  have — at minimum, document that gap explicitly rather than silently accepting it, since the
  next engineer reading `BrowseSearchAreaViewTests.swift`'s doc comment might assume this is
  covered.
- **Not a merge blocker** — the mechanism holds by inspection, and Kevin's live smoke directly
  exercises both behaviors (a search error at collapsed detent, and the peek/medium sizing at
  large-detent content) per this PR's own smoke checklist.

### 🟢 Minor / nit

**#2 — `gearButtonVisible`/`parkingGuideButtonVisible` remain defined and unit-tested with zero
production call sites.**
- **Where:** `ContentView.swift:3428-3455` (functions), `FT13Tests.swift`, `FT18Tests.swift`
  (tests).
- **What:** Confirmed genuinely dead — `grep` finds no call site outside their own tests and a
  doc comment. The author's stated rationale (avoid unrelated test-file churn on an already
  large, high-risk diff) is reasonable for this PR specifically.
- **Recommendation:** Fine to leave for this merge; worth a small follow-up cleanup PR (delete
  the 2 functions + their ~6 tests) once the FT-20 feature has stabilized, so a future reader
  doesn't have to figure out why two well-tested pure functions have no caller.

### 💡 Out of scope (logged, not fixed — discovered during this review, not introduced by
this PR)

- **The arrival-prompt "Park Here" flow can silently clobber the first-ever-pin
  `.notificationRationale` sheet with `.parkUntil`** (`ContentView.swift`, the `onParkHere`
  closure in the `.arrivalPrompt` case) — confirmed byte-identical to `origin/main` before this
  PR (this is original W8.5d code, untouched by Stream C). If a user's literal first pin drop
  ever happens via the arrival-prompt "Park Here" path (as opposed to the resting long-press
  flow), `handleFirstPinDropped()` fires synchronously inside `parkPinService.save(car)` and
  sets `activeSheet = .notificationRationale`, which is then unconditionally overwritten one
  line later by `activeSheet = .parkUntil`. This predates FT-20 and is not something Stream C
  introduced or is responsible for fixing — noted for team awareness since it's exactly the
  bug class (co-located `activeSheet` writes racing a mode-change closure) this PR was asked
  to sweep for, and it's adjacent enough to Stream C's own fix that a future engineer touching
  this closure should know about it.
- **`handleCommunityPinTapped`/`handleMapTap`'s block-detail path are not gated against
  `driveModeActive`** — both set `activeSheet` directly (bypassing `dismissTargetOutsideBrowseNav`
  and `noBlockingSheetPresented`'s guard pattern used elsewhere), so a tap on a community pin or
  blockface during Drive Mode could in principle present `.pinDetail`/`.blockDetail` over the
  Bottom Dock. Confirmed pre-existing (zero-diff on both functions, and `MapViewRepresentable.swift`
  is confirmed zero-touch per AC-30) — out of scope for this PR, not evaluated further.
- Real Dynamic Type / AX3 verification of the C1 measurement chain, and live confirmation of
  the block-select 0.35s settling window — cannot be done on this Linux VPS, explicitly
  Kevin's Mac smoke.
- Sunlight legibility (design-review S6) — unrelated to this PR's code, carried forward as a
  smoke-checklist item per Stream A/B QA.

## Smoke tests run

- `git status` / `git diff HEAD` before drafting any finding — confirmed clean worktree
  matching `HEAD` (`b638dab4`).
- `git diff origin/main...HEAD --name-status` — confirmed exactly 11 files touched (1 deleted,
  1 added Swift source, 1 added test file, 8 modified), matching the PR description exactly.
- `git diff origin/main...HEAD -- ContentView.swift` (699 lines) read in full, every hunk
  classified.
- `git diff origin/main...HEAD -- MapViewRepresentable.swift` — confirmed empty (AC-30).
- Exhaustive `grep` for every `driveModeActive = true/false` assignment site (2 + 1) and
  cross-referenced each against `.onChange(of: driveModeActive)`'s single occurrence in the
  file, to prove the AC-28/AC-29a funnel is structurally complete, not just "correct at the
  sites I happened to check."
- Read the full `.arrivalPrompt` case body (both `origin/main` and `HEAD`) to confirm the
  clobber-guard scenario is real, correctly fixed, and that the adjacent
  `.notificationRationale` interaction is pre-existing (byte-identical diff against `origin/main`).
- Read `enterBlockSelectMode()`, `cancelBlockSelectMode()`, `submitBlockSelectReport()`, and
  the `.blockRestrictionReport` sheet-content case in full to trace AC-23/AC-25's restore path
  including the interactive-swipe-dismiss case (via the top-level `.sheet(item:, onDismiss:)`
  backstop).
- Read every one of the ~15 `dismissTargetOutsideBrowseNav`-reading closures in `sheetContent`
  individually (not sampled) to check for a case where returning to `.browseNav` would be
  wrong; found none — the property's own live re-evaluation of
  `driveModeActive`/`blockSelectModeActive` makes this structurally safe.
- Traced `BrowseSheetSearchAreaHeightPreferenceKey`'s full data-flow graph
  (`searchField` → preference → `BrowseNavigationSheet.searchAreaHeight` →
  `BrowseSheetDetentMath` → `ContentView`'s `@State` → `.presentationDetents`/
  `.presentationBackgroundInteraction`) to confirm it's a one-way DAG with no edge back into
  `searchField`'s own layout constraints — the specific feedback-loop concern the task raised.
- `git diff origin/main...HEAD -- BrowseSearchAreaViewTests.swift` — confirmed empty, the basis
  for Finding #1.
- `git grep -c "^\s*func test" origin/main -- 'ios/WePark/WeParkTests/*.swift'` (776) vs. same
  against `HEAD` (780) — confirmed the exact arithmetic claimed in the task brief.
- `grep -n "DriveModeDestinationView"` across the whole `HEAD` tree — 18 hits, all in comments;
  zero live type references. `grep` for declaration sites of `SearchCompleterDelegate`,
  `SearchTimeoutError`, `RecentDestinationsStore` — exactly one each.
- `grep -n "gearButtonVisible\|parkingGuideButtonVisible"` across `HEAD` — confirmed zero
  production call sites, only test references and one doc comment.
- Brace/paren balance check on all 8 touched Swift files — all balanced (not a compilation
  substitute).
- Confirmed `BrowseSearchAreaView`'s call site in `ContentView.swift` matches its `init`'s
  parameter labels/order exactly.
- Checked all new/modified types for the `let`-with-default-value memberwise-init pitfall —
  none found (`BrowseSheetSearchAreaHeightPreferenceKey` has no instance stored properties;
  `BrowseSheetDriveBoundaryTarget` is an enum; `BrowseSearchAreaView`'s custom init is
  pre-existing and unchanged).
- Read `FT20StreamCTests.swift` in full (6 tests) — real, non-tautological assertions against
  the two new pure functions, including boundary-condition pins (`testTapExactlyAtGuardDeadline_isNotIgnored`).
- Checked `git branch --show-current` — `ios/ft20-stream-c-integration`, confirming no
  accidental commit target drift before writing this report.

## What's working

- **The whole "flip the gate atomically with its own safety net" discipline held.** The
  predecessor's gate doc comment listed exactly 3 things that had to land together (cold-launch
  mount, Drive-Mode boundary, block-select boundary) — all 3 are present, and I could not find
  a fourth thing that should have been on that list but wasn't.
- **The state-machine reasoning throughout is unusually rigorous for a PR this size**, and it
  held up to independent re-derivation rather than just being internally consistent — the
  funnel-completeness claim, the dismiss-target liveness claim, and the C1 data-flow claim were
  all things I verified by tracing the actual code paths myself, not by trusting the doc
  comments, and all three came out true.
- **AC-22's "Park Until needed no relocation" claim is exactly as advertised** — a genuinely
  zero-diff piece of a PR that touches almost everything around it, which is exactly the kind
  of restraint this file's regression history rewards.
- **AC-30's zero-touch guarantee on `MapViewRepresentable.swift` is real**, confirmed by direct
  diff, not by trusting the PR description.
- **The block-select settling-window mechanism is well-chosen** — a wall-clock `Date` deadline
  is structurally immune to the "can it fail to expire" and "what about backgrounding" failure
  modes the task specifically asked about, independent of whether 0.35s turns out to be the
  right number.
- **The C1 substitution is a genuine improvement over what the spec originally called for**,
  not just an acceptable deviation — it measures the true value instead of estimating one, and
  the mechanism that makes it safe (siblings, not descendants, of the measured node) is a
  stronger structural guarantee than a `@ScaledMetric` ceiling would have been.

## What only Kevin's live smoke can settle

- Whether AC-28/AC-29a's "no frame shows both" claim actually holds visually at 60fps — the
  code-level funnel guarantee is real, but frame-level animation coordination between a system
  `.sheet` and a `.safeAreaInset` VStack is not something static analysis can observe.
- The block-select 0.35s settling constant — explicitly unmeasured, per the author's own
  framing and the task brief's instruction (Kevin measures this).
- Dynamic Type / AX3 behavior of the C1 measurement chain — cannot render on this VPS.
- Sunlight legibility of the sheet chrome + top-right rail (S6, carried over from Stream A/B,
  unrelated to this PR's code).
- General compile/warnings/test-pass status — `[COMPILE-UNVERIFIED]` per this PR's own commit
  message; no toolchain on this Linux VPS.
