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

---

## Pass 2 — 2026-08-22 — post-six-rounds-of-live-smoke re-review

**Reviewed:** branch `ios/ft20-stream-c-integration` at `f6786baf` (round 6, tip), diffed
against Pass 1's reviewed commit `b638dab4..HEAD` (9 commits: 2636ccc6 round 1, f0be3583
round 2, 56f0d7dc/6482ee84 spec updates, d6fed6d0 round 3, 134442d1 round 4, 8624b07e round
5, f6786baf round 6, plus Pass 1's own QA doc commit 0cbe96c6), against
`docs/ft20-bottom-sheet-navigation-spec.md` §0e/§0f/§0g (authoritative, in that supersession
order), §0/§0d/§5/§6/§7.
**Environment:** Linux VPS — no Xcode, no simulator, no `xcodebuild`, confirmed unavailable
before starting. Nothing below is a compile or runtime claim; this is a static code read
against the spec, the commit history, and — where possible — the exact on-device numbers
Kevin's `#if DEBUG` readout reported, which this pass independently re-derived by hand.
**Integrity check:** `git fetch origin && git checkout -B ios/ft20-stream-c-integration
origin/ios/ft20-stream-c-integration` then `git status`/`git diff HEAD` — clean, matches
`HEAD` (`f6786baf`) exactly before any finding was drafted.
**Independence note:** this is a fresh read, not a continuation of Pass 1's session — I did
not carry forward Pass 1's specific findings as assumed-still-true; each one below was
re-verified against the current diff.

**Verdict: ✅ MERGE.**

### Summary

Six live-smoke rounds in ~16 hours is a lot of churn to land on the same file without
accumulating damage, and that was the real question for this pass — not "is round 6 correct
in isolation" (it plainly is) but "did rounds 1–5 leave orphaned constants, contradictory
guards, or quietly-hollowed test coverage in their wake." I did not find meaningful damage.
Every constant introduced across the six rounds (`interSectionGutter`, `peekBreathingRoom`,
`peekToActionContentMinimumGap`, `minimumPeekHeight`, `isGenuineMeasurement`,
`actionContentTopOffset`) is still read from a live call site — I grepped each one
individually rather than sampling. Every constant *removed* along the way
(`grabberAndInsetAllowance`, `listSectionChromeAllowance`, `peekSafetyMargin`, the
`PreferenceKey` itself) has zero remaining production references; the only hits are doc
comments explicitly kept as root-cause history, which is this file's own established
convention (Stream A already did this for earlier removals) and is genuinely useful, not
clutter. The `#if DEBUG` readout is completely gone — both blocks, confirmed via `git show
f6786baf`'s actual diff, not the commit message.

The one thing I verified that surprised me in a good way: I hand-computed
`BrowseSheetDetentMath.peekHeight`/`.mediumHeight`/`.actionColumnHeight` against the exact
`searchH: 76.0` input from Kevin's round-6 device readout and got `peek: 80.0`, `medium:
186.0`, `actionTop: 84.0` — an exact match to all four numbers quoted in spec §0g, including
`actionColumnHeight` backing out to exactly `102` from the default `@ScaledMetric` values.
That's independent confirmation the shipped formula is the formula that actually produced the
confirmed-working on-device screenshot, not just "internally consistent with itself."

Test coverage was **not** hollowed out by the accumulated deletions — see the dedicated
section below. Every deletion across all three rounds that removed tests
(`grabberAndInsetAllowance`'s pinning tests, the two `PreferenceKey.reduce` tests, the two
`SearchFieldHeightMeasurementTests`) is accompanied by an explicit, specific doc comment
naming what broke, why it was wrong to keep, and — critically — what (if anything) now covers
the same ground. That is a materially higher bar than "we deleted a failing test," and I
verified the claims in those comments against the actual remaining suite rather than trusting
them.

One carried-forward gap from Pass 1 remains open (C2's auto-expand-on-error binding mutation
still has no test with a real, non-`.constant()` binding), and one pre-existing (not
introduced by these six rounds) minor spec-table inconsistency surfaced that's worth a
follow-up look. Neither blocks merge.

### Acceptance criteria re-sweep (post-six-rounds, prioritized per task brief)

- [x] **AC-30** (`MapViewRepresentable.swift` zero-diff) — re-confirmed: `git diff
  b638dab4..HEAD -- ios/WePark/WePark/MapViewRepresentable.swift` and `git diff
  origin/main..HEAD -- <same file>` both return 0 lines. None of the six rounds touched it.
- [x] **AC-22** (Park Until preserves 100% of its behavior) — re-confirmed: the only mention
  of `parkUntilMode` in the six-round diff is inside `parkingGuideBannerOverlay`'s visibility
  guard (`!driveModeActive && !parkUntilMode && !blockSelectModeActive`), which is a verbatim
  carry of the pre-existing `ParkingGuidePromptBanner` gate, relocated wholesale from
  `bottomSafeAreaContent` to a new floating overlay (round 2, §0e Ruling 2). `ParkUntilPill`,
  the `clock.fill` toolbar button, and `parkUntilMode`'s own read/write sites are untouched.
- [x] **AC-28/AC-29a** (no frame shows both sheet and Bottom Dock, entry AND exit) — the
  funnel Pass 1 verified exhaustively (`.onChange(of: driveModeActive)`, single occurrence;
  `handleDriveModeAndCamera`; `browseSheetBoundaryTarget`) has **zero diff across all six
  rounds** — confirmed by re-reading the full `ContentView.swift` diff for this range, which
  contains only doc-comment updates, the `browseNavigationSheetContent` builder-closure
  change, and the new `parkingGuideBannerOverlay`. None of that logic is anywhere near the
  Drive-Mode boundary funnel.
- [x] **AC-23–27** (FT-15 block-select boundary) — same result: `enterBlockSelectMode()`,
  `cancelBlockSelectMode()`, `submitBlockSelectReport()`, `blockSelectTapShouldBeIgnored`,
  and `browseSheetBoundaryTarget` are **byte-identical** across the six-round diff. Only
  `FT20StreamCTests.swift` gained additional coverage of the pure functions (no production
  change).
- [x] **AC-4** (search visible at every detent, peek shows search ONLY) — re-verified against
  the FINAL code, not the intermediate rounds: `BrowseSearchAreaView.body`'s own
  large-detent-only gate (`if detentKind == .large`) is unchanged since before Pass 1;
  `BrowseNavigationSheet.body`'s `showsActionContent` gate (round 4) additionally prevents the
  action column from mounting at all at peek. Combined, peek shows exactly the search field
  and nothing else — matches §0g's confirmed device readout description.
- [~] **AC-6, AC-34/35** — unchanged from Pass 1's assessment; not independently
  re-verifiable without a device this pass either.

### Priority 1: regression risk from six sequential fixes

**Vestigial constants — none found.** I grepped every constant this file has ever defined
(current and historically-removed) individually across the whole `ios/WePark` tree:

| Constant | Status | Where it's still load-bearing |
|---|---|---|
| `minimumPeekHeight` | **Live** | `peekHeight`'s floor; `searchArea`'s `.frame(minHeight:)`; `ContentView`'s initial `@State` default |
| `interSectionGutter` | **Live** | `actionContentTopOffset`; the conditionally-mounted `Color.clear.frame(height:)` spacer in `body` |
| `peekBreathingRoom` | **Live** | `peekHeight`'s additive candidate (round 4 replacement for the removed subtractive `peekSafetyMargin`) |
| `peekToActionContentMinimumGap` | **Live** | `peekHeight`'s ceiling clamp |
| `isGenuineMeasurement` | **Live** | all three `reportHeights()` call sites in `body` |
| `grabberAndInsetAllowance` | **Deleted, zero refs** | doc-comment history only (`BrowseSheetDetentMath`'s removed-constant note) + explanatory comments in test files |
| `listSectionChromeAllowance` | **Deleted, zero refs** | never referenced anywhere in `HEAD` — confirmed via `grep -rn` across the whole tree, no hits at all (not even in doc comments, unlike its siblings — it was cut cleanly in round 2 alongside the `List`→icon-row anatomy change) |
| `peekSafetyMargin` | **Deleted, zero refs** | mentioned only in `FT20StreamATests.swift`'s own historical doc comments explaining why old tests were rewritten |
| `BrowseSheetSearchAreaHeightPreferenceKey` (the whole mechanism) | **Deleted, zero refs** | 70-line root-cause doc comment kept in its place; replaced by `.onGeometryChange` |

No constant is defined-but-unused, and no removed constant has a lingering reference outside
explanatory prose. This matters specifically because the task flagged this file's history
("vestigial height constants in THIS file are a real hazard") — six rounds of live-fire
editing did not leave debris.

**Contradictory belt-and-braces — checked, not found to be contradictory.** The four
overlapping guards the task asked me to check against each other:

1. `isGenuineMeasurement` (gates *whether* a height gets reported up to `ContentView`'s
   persistent state)
2. `.frame(minHeight: minimumPeekHeight)` on `searchArea` (a rendering-time floor on the
   built view)
3. Conditional mounting of `actionColumn`/gutter at peek (`showsActionContent`)
4. `peekHeight`'s hard clamp against `actionContentTopOffset`

These operate at four different points in the pipeline (measurement-reporting, rendering
floor, tree-membership, arithmetic ceiling) and I could not construct an input where any two
disagree or one silently masks a defect in another — each is independently sufficient for its
own failure mode, and the doc comments are explicit that #3 and #4 are now redundant-by-design
("belt-and-braces," in the code's own words) rather than accidentally overlapping. This is the
opposite of round 1's original bug (the old exact-match `PresentationDetent` classification,
which was a *single* mechanism silently masking the real defect) — I specifically looked for a
NEW instance of that pattern and didn't find one. The one thing I'd flag as worth watching
(not a defect): `.frame(minHeight:)` on `searchArea` (item #2) and `peekHeight`'s floor logic
(item #4, via `minimumPeekHeight`) both encode "64pt" as the realistic minimum via the *same*
named constant, so they can't silently drift apart — a genuine strength, not a risk, since it
was a `24`-vs-`12` version of exactly this kind of drift that caused two of the six rounds.

**Debug overlay — confirmed fully gone.** `git show f6786baf -- BrowseNavigationSheet.swift`
shows both `#if DEBUG` blocks (the `.overlay` call site and the `debugReadout` property)
removed as a single clean diff, and a repo-wide `grep -n "^#if DEBUG"` against
`BrowseNavigationSheet.swift`, `BrowseSearchAreaView.swift`, and `FT20StreamCTests.swift`
returns zero matches — every remaining occurrence of the string `"#if DEBUG"` in those three
files is inside a `///` doc comment narrating the removal, not a live directive. `ContentView.swift`'s
own pre-existing, unrelated `#if DEBUG` blocks (untouched by this PR) and
`MockRealtimePinChannel`/similar test doubles elsewhere in the codebase are exactly the
legitimate `#if DEBUG` usage the task said not to flag, and I didn't.

### Priority 2: test honesty after the deletions — coverage was NOT quietly hollowed out

Test-count arithmetic, verified independently (not trusting the commit messages):

| File | b638dab4 (Pass 1) | HEAD (Pass 2) | Δ |
|---|---|---|---|
| `FT20StreamATests.swift` | 18 | 33 | +15 |
| `FT20StreamCTests.swift` | 6 | 15 | +9 |
| `BrowseSearchAreaViewTests.swift` | 5 | 5 | 0 (init-signature update only) |
| `W85cTests.swift` | 48 | 48 | 0 (init-signature update only) |
| **Whole suite** (`git grep -c "^\s*func test"`, all `WeParkTests/*.swift`) | **780** | **804** | **+24** |

`780 + 24 = 804` — the expected count in the task brief, confirmed exactly, not approximately.

Each of the three test-removal events across the six rounds is individually justified and I
verified the justification against the code, not just the comment:

1. **`grabberAndInsetAllowance` pinning tests (round 2→3), deleted.** These tested a formula
   (`peekHeight == searchAreaHeight + 12`) that was itself replaced. The replacement invariant
   (`BrowseSheetPeekInvariantTests.testPeekHeight_isStrictlyLessThanActionContentTopOffset_acrossRealisticDynamicTypeRange`,
   sweeping `searchAreaHeight` from 40 to 400 in steps of 4) is a **stronger** test than what it
   replaced: it pins the *outcome* ("peek can never reveal the action content") independent of
   the internal formula, so it can't go stale the way the deleted formula-level test did when
   the formula changed twice. I confirmed this test exists at `FT20StreamATests.swift:270` and
   its assertion is exactly what the doc comment claims.
2. **`BrowseSheetSearchAreaHeightPreferenceKeyTests`' two `reduce` tests (round 5), deleted.**
   These are the ones the task specifically flagged as having "pinned the broken last-write-
   wins behavior as intentional." I read the removal comment
   (`FT20StreamCTests.swift:249-276`) and independently agree with its self-critical framing:
   calling `reduce` directly with hand-fed values genuinely cannot exercise the bug (which is
   about how many times and in what order SwiftUI itself invokes `reduce` across a live view
   tree, not about `reduce`'s own per-call arithmetic) — this is not a rationalization, it's an
   accurate description of why that test *structurally could not* have caught the bug even
   though it was "passing." No replacement PreferenceKey-level test exists, correctly, because
   the mechanism it tested no longer exists.
3. **`SearchFieldHeightMeasurementTests` (round 5→6), deleted.** This is the most defensible of
   the three deletions and the one I scrutinized hardest, since "the test doesn't work, delete
   it" is exactly the kind of claim that deserves skepticism. The stated reason
   (`UIHostingController` + `layoutIfNeeded()` doesn't reliably drive `.onGeometryChange` off a
   real window) is a real, previously-documented category of SwiftUI testing limitation, not
   invented for this PR — and the falsification evidence given (both tests failed with
   `reportedHeight == 0.0` on Kevin's Mac on the exact same build whose on-device readout
   showed a real `76.0`) is about as strong as evidence gets without me being able to run it
   myself. I could not run this test to confirm it fails on this machine (no Xcode/simulator),
   so this specific claim rests on Kevin's Mac run, not my own verification — flagged as such,
   not silently accepted.

**What is genuinely, honestly uncovered by any unit test after all six rounds (both this pass
and the code's own doc comments agree on this):** *"does `.onGeometryChange` actually deliver
a non-zero measurement in the live, on-screen app"* — a question about whether a real SwiftUI
render pass ran, which is not expressible as a headless XCTest on this SDK. That gap is real,
named explicitly in the removal comment, and is covered by live-device smoke (round 6's
confirmed readout) rather than a repeatable automated test — this is a legitimate, disclosed
trade-off, not a silently-dropped guarantee. It is the same category of gap Pass 1's Finding #1
already flagged for C1's mechanism generally; six rounds later it is *narrower* (the pure
height-math half is now thoroughly covered by `BrowseSheetPeekInvariantTests`, and the
"does it fire" half has a real device confirmation with numbers that independently check out
against the formula) but not fully closed.

**Pass 1's Finding #1, C2 half, is still open — unaddressed across all six rounds.**
`BrowseSearchAreaViewTests.swift` still constructs every render-smoke test with
`detentKind: .constant(detentKind)` (confirmed via `grep -n "detentKind"` — every call site).
No test in this PR's entire six-round history uses a real, mutable binding to assert that
setting `errorMessage` actually flips `detentKind` to `.large` (the C2 fix). This is not new —
Pass 1 flagged the identical gap — but I checked whether any of the six rounds happened to
close it as a side effect (several of them touched adjacent code) and none did. Downgraded
from Pass 1's 🟡 to a 🟢 here only because it's unchanged risk, not a new or worsened one, and
because Kevin's live smoke checklist already exercises the search-error-at-peek scenario
directly per the PR's own process.

### Priority 3: spec conformance against §0f/§0g (final rulings)

- [x] Search field with trailing `gearshape` — `BrowseSearchAreaView.searchField`'s
  `settingsButton`, in the outer `HStack`'s trailing position, wired to `onSettingsTapped`
  (`ContentView.swift` sets `activeSheet = .settings`, the same target the deleted
  `gearButtonOverlay` used).
- [x] One primary `car.fill` + "Find a Spot" — `BrowseNavigationSheet.actionColumn`'s first
  child, `.buttonStyle(.borderedProminent)`, full-width, calling `onCruiseTapped` →
  `enterCruiseMode()` — confirmed the internal identifier chain
  (`enterCruiseMode()`/`driveModeStyle`/`.cruise`/`onCruiseTapped`) is completely unrenamed,
  a label-only change as §0f Ruling 2 requires. `car.front.waves.right.fill` (the invalid SF
  Symbol) has zero remaining references in any `.swift` file — only in historical spec/design
  docs, which is correct (those are dated records of what was originally asked for, not live
  instructions).
- [x] Quiet "New to parking?" link — `actionColumn`'s second child, `.buttonStyle(.plain)`,
  `.foregroundStyle(.secondary)`, `.underline()`, visually subordinate as specced.
- [x] Peek shows search ONLY — confirmed above (AC-4 re-sweep).
- [x] Internal Cruise identifiers unrenamed — confirmed above.
- [x] No new hardcoded colors (AC-32) — the two new color usages added across these six rounds
  (`BrowseSearchAreaView.searchField`'s `.background(Color(.systemGray4), ...)` and
  `.strokeBorder(Color(.separator), ...)`) are both semantic/system `UIColor`-backed values
  (`Color(.systemGray4)`, `Color(.separator)`), not new hex/RGB literals — same category as
  every other `Color(.something)` usage already in this codebase. `.presentationBackground(.regularMaterial)`
  is a system material, not a color. No violation.
- **Not independently verified by me, only by the code's own claim + Kevin's device
  confirmation:** whether `.systemGray4` actually reads as sufficiently higher-contrast than
  `.secondarySystemGroupedBackground` against the sheet's blurred material *in direct
  sunlight* — this is S6's carried-forward, device-only risk, unrelated to correctness of the
  code change itself.

### Priority 4: original §7 AC sweep — re-verified after six rounds, results unchanged from Pass 1

Re-ran the full sweep rather than trusting Pass 1's checklist was still accurate; results are
identical to Pass 1 for every AC not already covered above in the prioritized re-sweep
(AC-1/2/3/5/7-21/31/32/33 all hold, same reasoning as Pass 1, none touched by these six
rounds' diffs). No AC regressed.

### Priority 5: can anything strand the user with no sheet, or an undismissable one?

**No new mechanism introduced across these six rounds changes this answer from Pass 1's
"no."** The only net-new piece of UI added since Pass 1 is `parkingGuideBannerOverlay` (round
2), and it's purely additive/cosmetic — it doesn't touch `activeSheet`, doesn't gate any
dismiss path, and its own visibility condition is a straight carry of the pre-existing banner
gate. I checked whether its `.frame(maxWidth: .infinity, maxHeight: .infinity)` container
could intercept touches meant for the map or the sheet's grabber underneath it: it's a plain
`VStack { Spacer(); ParkingGuidePromptBanner(...) }` with no background modifier on the
container itself, matching the pre-existing `ToastHostView` overlay's identical pattern one
sibling above it in the same `ZStack` — SwiftUI does not hit-test empty (backgroundless)
regions of a container, only its actual rendered content, so this should not block taps to
what's underneath. **Not independently confirmed on a device this pass** (this specific claim
about SwiftUI hit-testing behavior for `Spacer()`-only regions is standard SwiftUI behavior,
not something unique to this PR, and the identical pre-existing `ToastHostView` pattern has
presumably already been live-tested); flagged as a device-checkable item below rather than
silently assumed.

### Findings

#### 🔴 Blocking

None found.

#### 🟡 Significant

None found this pass. Pass 1's one 🟡 (C1/C2 zero regression coverage) is downgraded — see
Priority 2 above for the full reasoning: C1's mechanism now has strong indirect confirmation
(an exact hand-verified match between the pure-math formula and Kevin's real device readout,
plus thorough invariant-test coverage of the arithmetic itself) and an honestly-documented,
narrowly-scoped remaining gap ("does a real render pass fire `.onGeometryChange`" — not
testable on this SDK, covered by live smoke instead). C2's gap is unchanged, not worsened.

#### 🟢 Minor / nit

**#3 — The medium-detent action column (`actionColumn`: "Find a Spot" + "New to parking?")
also mounts at the LARGE detent, not just medium — `BrowseSheetDetentKind.showsActionContent`
is `self != .peek`, true for both `.medium` and `.large`.** This predates Pass 1's reviewed
commit (it was already true of the original `List`-based `actionList` at Stream A) and is
**not introduced or worsened by any of these six rounds** — but three of the six rounds
(2, 3, 4) rewrote this exact gating logic and none of them revisited whether `.large` should
be included. Spec §4.2's detent table describes Large as showing only "search field (focused)
+ suggestions list or recent-destinations list... or the resolved 'place' state" — no mention
of the action column. In practice this means: while a user is actively viewing search
suggestions/recents at the large detent, the "Find a Spot" primary button and "New to
parking?" link also render below that list. Round 6's confirmed device readout says "the
large detent also renders correctly," which is consistent with this being intentional and
already seen/accepted by Kevin, but doesn't unambiguously confirm he was looking at (or
approves of) the action column appearing under the suggestions list specifically. Not a
regression, not blocking — worth a device screenshot at `.large` with a non-empty query to
settle whether this is deliberate or an oversight that survived three rewrites of the same
conditional.
- **Where:** `BrowseNavigationSheet.swift:390` (`showsActionContent`).
- **Owner:** `@ios-engineer` (confirm intent against Kevin, or scope the gate to
  `self == .medium` if it's not).

**#4 — C2 (auto-expand-to-`.large`-on-error) still has no test with a real, mutable
`detentKind` binding, unchanged across all six rounds.** Carried forward from Pass 1's Finding
#1; not newly introduced, not worsened, but also not addressed despite several of the six
rounds touching adjacent code in the same file.
- **Where:** `ios/WePark/WeParkTests/BrowseSearchAreaViewTests.swift` — every test still uses
  `detentKind: .constant(...)`.
- **Owner:** `@ios-engineer`, low priority — Kevin's live smoke already exercises the
  search-error-at-peek scenario per the PR checklist.

**#5 — `gearButtonVisible`/`parkingGuideButtonVisible` remain dead code, unchanged from Pass
1's Finding #2.** Same file/lines, same reasoning, still not blocking. Carried forward, not
re-litigated in depth this pass.

#### 💡 Out of scope (logged, not fixed)

- Whether `.systemGray4` + hairline separator actually reads well in direct sunlight against
  the sheet's blurred `.regularMaterial` — S6's carried-forward risk, explicitly a device-only
  question, unrelated to this pass's code-correctness review.
- Whether `SearchFieldHeightMeasurementTests` genuinely could not be made to work with a
  differently-constructed harness (e.g. a real, key `UIWindow` + hosting controller) — I did
  not attempt to re-derive this myself (no toolchain), and I'm relying on Kevin's Mac-run
  failure evidence as reported in the round-6 commit message and spec §0g. If a future agent
  is tempted to second-guess this deletion, the removal comment itself
  (`FT20StreamCTests.swift:278-317`) already anticipates and answers that.
- The 32×32pt Settings gear tap target (below Apple HIG's 44×44 minimum) — already
  self-flagged in `BrowseSearchAreaView.swift`'s own doc comment as a deliberate, disclosed
  trade-off pending VoiceOver/Switch Control testing. Not new this pass; noted for the
  eventual accessibility sweep, not a finding against this PR.
- `parkingGuideBannerOverlay`'s hit-testing behavior (Priority 5) — reasoned to be safe by
  analogy to the pre-existing `ToastHostView` pattern, not independently confirmed on a
  device this pass.

### Smoke tests run (Pass 2)

- `git fetch origin && git checkout -B ios/ft20-stream-c-integration
  origin/ios/ft20-stream-c-integration`, then `git status` / `git diff HEAD` — confirmed clean,
  matches `HEAD` (`f6786baf`) before drafting any finding.
- `git log --oneline b638dab4..HEAD` — enumerated and cross-referenced all 9 commits (Pass 1's
  own QA doc + 6 fix rounds + 2 spec-only doc commits) against the task brief's own numbered
  history; confirmed the mapping (round 1 = `2636ccc6`, round 2 = `f0be3583`, round 3 =
  `d6fed6d0`, round 4 = `134442d1`, round 5 = `8624b07e`, round 6 = `f6786baf`).
- Read `docs/ft20-bottom-sheet-navigation-spec.md` §0/§0b/§0c/§0d/§0e/§0f/§0g/§5/§6/§7 in full
  (not skimmed) before reading any code, to establish the correct supersession order (§0f > §0e
  > S1; §0g explains WHY §0f's peek fix still didn't fully work until round 5/6).
- Read the full, current `BrowseNavigationSheet.swift` (774 lines) and `BrowseSearchAreaView.swift`
  (817 lines) top to bottom.
- `git diff b638dab4..HEAD -- ContentView.swift` read in full — confirmed the only production
  changes are `browseNavigationSheetContent`'s builder-closure/`.presentationBackground`
  update and the new `parkingGuideBannerOverlay`; confirmed via direct read (not assumption)
  that none of AC-28/29a's funnel or AC-23-27's block-select functions appear anywhere in this
  diff.
- `git diff b638dab4..HEAD -- MapViewRepresentable.swift` and `git diff origin/main..HEAD --
  MapViewRepresentable.swift` — both empty (AC-30 re-confirmed at two different base points).
- Grepped every `BrowseSheetDetentMath`/`BrowseSheetDetentKind` constant and function
  (current and historically-removed) individually across the whole `ios/WePark` tree to build
  the vestigial-constant table in Priority 1 — not sampled, all nine constants/mechanisms
  checked.
- `grep -n "^#if DEBUG"` (anchored, to exclude doc-comment mentions of the string) against
  `BrowseNavigationSheet.swift`, `BrowseSearchAreaView.swift`, `FT20StreamCTests.swift` — zero
  matches, confirming the debug overlay is fully gone, not just renamed/relocated.
- Hand-computed `BrowseSheetDetentMath.peekHeight(76)`, `.actionContentTopOffset(76)`, and
  `.actionColumnHeight(22, 14, 10, 18, 12)` against the current formulas and confirmed each
  result (`80`, `84`, `102`) exactly matches spec §0g's quoted on-device readout
  (`searchH: 76.0, peek: 80.0, medium: 186.0, actionTop: 84.0` — `84 + 102 = 186`) — the
  strongest single piece of evidence in this pass that the shipped math is genuinely correct,
  not merely self-consistent.
- `git grep -c "^\s*func test"` against `b638dab4` and `HEAD` for every file in
  `ios/WePark/WeParkTests/*.swift`, summed both ways (780 → 804, Δ+24) and per-file for the
  four files with any diff in this range (`FT20StreamATests.swift` +15,
  `FT20StreamCTests.swift` +9, `BrowseSearchAreaViewTests.swift`/`W85cTests.swift` both 0 net
  — confirmed both of those two are init-signature-only changes by reading their diffs).
- Read all three test-removal doc comments in `FT20StreamCTests.swift` in full
  (`grabberAndInsetAllowance`'s removal note, the `PreferenceKey.reduce` tests' removal note,
  `SearchFieldHeightMeasurementTests`' removal note) and independently assessed each
  justification against what I could verify from the code, rather than accepting the stated
  reasoning at face value.
- Read `FT20StreamATests.swift`'s `BrowseSheetPeekInvariantTests` and
  `BrowseSheetActionColumnHeightTests` in full to confirm the replacement coverage claimed in
  the removal comments genuinely exists and genuinely tests what it claims to.
- `grep -rn "BrowseSearchAreaView(" ios/WePark` and `grep -rn "BrowseNavigationSheet(" ios/WePark`
  — enumerated every call site (5 and 1 respectively) and confirmed each supplies the new
  required parameters (`onSearchFieldHeightChange`, `detentKind`) introduced across these six
  rounds — no orphaned/stale call site found.
- `grep -n "detentKind"` in `BrowseSearchAreaViewTests.swift` — confirmed every test still uses
  `.constant(...)`, the basis for Finding #4.
- Checked `git branch --show-current` before drafting — `ios/ft20-stream-c-integration` —
  and again immediately before committing this report, to guard against commit-target drift.

### What's working

- **Six rounds of live-fire editing under real time pressure did not leave the file worse than
  it started.** This is the actual headline finding of this pass: no vestigial constants, no
  contradictory guards, no hollowed-out test coverage, no orphaned debug scaffolding. That's a
  genuinely good outcome for this failure mode, not a given one.
- **The round-6 root-cause diagnosis (PreferenceKey `reduce` contract violation) is correct,
  well-cited against the actual Apple-documented contract, and the fix is structurally
  superior, not just a patch** — `.onGeometryChange` has no cross-tree aggregation step, so
  this exact bug class (an unrelated sibling silently contributing a defaultValue that
  clobbers a real measurement) is not just fixed but eliminated as a possibility.
- **The formula genuinely reproduces the confirmed on-device numbers** — verified by hand,
  not by trusting the doc comment. This is about as strong a piece of independent evidence as
  a Linux-VPS-bound QA pass can produce for a geometry claim.
- **Test-deletion discipline across all three removal events is unusually good.** Every
  deletion names the specific mechanism that was wrong, why it was wrong, and what (if
  anything) remains as coverage — this is a meaningfully higher bar than "we deleted a
  failing/obsolete test," and it held up to independent scrutiny in this pass, not just to a
  re-read of the comments.
- **The doc-comment-as-history convention this file established in Stream A survived six
  rounds of pressure intact** — every removed mechanism/constant has a root-cause note in its
  former place, which is exactly what let me verify Priority 1's "no vestigial debris" finding
  without a device.

### Merge recommendation

**MERGE.** No blocking findings across either pass. The two 🟢 carry-forwards (C2 test gap,
the large-detent action-column question) and the one dead-code nit are appropriate follow-up
items, not merge conditions — none of them represent a state where the shipped feature is
broken, unsafe, or contradicts a settled Kevin ruling. The device-only items below are the
actual remaining gate, and they're Kevin's to close on his Mac, not something further static
review on this VPS can resolve.

### What only Kevin's live smoke can settle (Pass 2 additions to Pass 1's list)

- Whether `.systemGray4` + hairline separator reads acceptably in direct sunlight (S6,
  unresolved since Stream A).
- Whether the large-detent action-column question (Finding #3) is something Kevin has already
  seen and is fine with, or an oversight — a fresh screenshot at `.large` with a non-empty
  search query would settle it in one look.
- `parkingGuideBannerOverlay`'s actual on-screen behavior — does it correctly clear the peek
  detent under Dynamic Type, and does it avoid intercepting taps meant for the map/sheet
  beneath it (Priority 5) — reasoned sound by analogy to `ToastHostView`, not device-confirmed
  this pass.
- Everything already carried over from Pass 1's own list (AC-28/29a frame-level animation
  timing, the 0.35s block-select constant, AX3/Dynamic Type rendering, general
  compile/test-pass status — `[COMPILE-UNVERIFIED]` on this environment for both passes).
