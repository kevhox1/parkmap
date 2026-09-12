# PR #107 — Polish (curb widths #19, legacy long-press #17b, blue car marker #20, dedupe) — QA Pass 1 — 2026-09-12

**Reviewed:** branch `ios/polish-19-17b-20` at `2beaf3f0` (tip; payload commit `df9beb6b`), base
`main` at `28273043`, against `docs/open-items.md` rows #19/#17b/#20, the S13c/#106 gate's
headline/status-line dedupe follow-up, `HANDOFF.md`'s 2026-09-12 entry, and the PR #107 body.
**Environment:** Linux VPS. No Xcode, no simulator, no `xcodebuild`. 100% static review — read the
diff, traced execution paths by hand across `MapViewRepresentable.swift`/`ContentView.swift`, and
cross-checked against the Coordinator→parent camera-toggle machinery already in the file. No build,
no test run, no live smoke performed by me. `[COMPILE-UNVERIFIED]` per the PR title — a Mac
`xcodebuild build` + `test` pass is a hard gate before merge regardless of this review's verdict.
**Verdict:** 🔴 **DO NOT MERGE** (as-is) — one well-evidenced functional gap in #19's Drive-Mode
wiring; #17b, #20, and the dedupe guard are sound and ready pending the Mac gate.

## Summary

Three of the four payload items check out on static review: the #17b root-cause narrative is
plausible and directly corroborated by the codebase (both presentation modifiers really are
attached to the same view, `ActiveSheet` really isn't `Equatable`, the fix's guard is a pure
id-comparison that never skips a needed reassignment); the #20 marker swap is applied at the single
real render site with no strays, uses distinct reuse identifiers so the tentative/parked alpha
values can't cross-contaminate, and the legend copy was correctly updated; the dedupe predicate is
a clean one-line equality guard with real-engine tests proving the mixed-ASP+METERED divergence
case is NOT collapsed. Test count is exactly 1314→1338 (+24), verified by extracting both trees and
counting `func test` — matches the PR's own math test-by-test. However, **the #19 Drive-Mode width
step-up almost certainly does not take effect when Drive Mode is toggled on** — it only takes effect
whenever `applyOverlayPayload` next runs (60s timer / segment-count change / selection change / Park
Until toggle), none of which are wired to `driveModeActive`. This directly contradicts the PR's own
claim that this is wired via "the SAME Coordinator→parent flow" the user-location puck uses — the
puck's flow includes an explicit forced re-query (`refreshUserLocationPuck` toggles
`showsUserLocation` specifically to make MapKit re-invoke the delegate); the curb-line change has no
equivalent and doesn't need one to compile, only to actually render correctly on toggle. This is
exactly the risk the dispatching brief asked me to check for, and it is real.

## Acceptance criteria checklist

- [ ] **#19 — Drive-Mode-specific width applies immediately on entering Drive Mode.** FAILED (as
      currently wired) — see Finding #1. Browse-mode base thickness bump itself is fine.
- [x] #19 — `CurbLineWidth` constants (standardBrowse 4.5, meteredBrowse 6.0, standardDrive 8.0,
      meteredDrive 10.5) are real, consumed (not dead) by all 4 non-metered + 1 metered
      `mapView(_:rendererFor:)` branches — verified by reading the diff hunk directly.
- [x] #19 — no pre-existing zoom-dependent scaling was flattened; confirmed by reading the pre-PR
      renderer, which used flat literal widths (3/3/4/3/3) regardless of `region.span` — the PR's own
      commit message correctly identifies this ("no zoom-dependent scaling to preserve").
- [x] #19 — zero color changes anywhere in the diff — every `strokeColor =` line is untouched
      context in the diff; only `lineWidth =` lines were replaced.
- [x] #19 — selected-block highlight (`lineWidth = 6`, two call sites), route polyline, block-select
      highlight, and zone-boundary overlay widths are untouched — grepped, unaffected by the diff.
- [x] #17b — root cause is plausible and directly corroborated: `.sheet(item: $activeSheet)`
      (`ContentView.swift:953`) and `.confirmationDialog(isPresented: $showRestingActionMenu)`
      (`:1036-1038`) are both chained onto the same `mapLayerWithEvents` view; `ActiveSheet` is
      `Identifiable` but not `Equatable` (confirmed, `ContentView.swift:226`); the id-based equality
      the fix relies on (`ActiveSheet.id`, `:325-344`) is content-aware (incorporates associated
      Segment/PinDropIntent/coordinate identity, not just the case name), so it doesn't collapse two
      *different* payloads of the same case.
- [x] #17b — fix doesn't skip a needed reassignment in any of the four traced scenarios: different
      sheet open (ids differ → write proceeds), `activeSheet == nil` (nil≠`.browseNav` id → write
      proceeds), long-press mid-drive-mode (early-returns before reaching the guard, unaffected),
      flag-on card path (never reads `activeSheet`/`showRestingActionMenu` at all — the guard being
      unconditional plumbing is provably inert for that path).
- [x] #20 — marker swap applies at the single real render site (`CarPinAnnotation` branch of
      `viewFor annotation`); no other parked-car render site exists in the codebase (grepped the
      full `ios/WePark/WePark` tree for `mappin.circle.fill`/`CarPinAnnotation` — the only two other
      `mappin.circle.fill` hits are an unrelated search-result icon and the arrival-prompt icon, not
      the parked car).
- [x] #20 — tentative (alpha 0.85, `PendingParkPinAnnotation`, reuse ID `PendingParkPinAnnotation`)
      vs. parked (alpha 1.0, `CarPinAnnotation`, reuse ID `CarPinAnnotation`) use **distinct**
      `MKMarkerAnnotationView` reuse pools — no risk of a recycled tentative-pin view leaking its
      0.85 alpha onto a real parked pin or vice versa.
- [x] #20 — `MapKeyLegendView` footer copy updated: "Blue circular pin" → "Blue car icon", matching
      the new `car.fill`-glyph marker, no stale keyhole/mappin references left in user-facing copy.
- [x] Dedupe — suppression predicate (`ParkedCarDetailLogic.shouldSuppressStatusLine`) is a pure
      one-line string-equality guard; mixed ASP+METERED divergence is proven NOT collapsed by a
      real-`ParkingRulesEngine` integration test (`testRealEngine_mixedASPAndMeteredSegment_
      activelyMetered_mustNotSuppress`) that asserts the two derived strings actually differ before
      asserting the guard doesn't suppress them.
- [x] Test count 1314 → 1338 (+24) — verified independently by extracting both git trees and
      counting `^\s*func test`, not by trusting the PR body's arithmetic.
- [x] `AppConstants.communityEnabled` untouched (`false`); no `supabase/` changes; no banned copy
      (avoid/ticket/fine/evasion/dodge — none found); no `Calendar.current` introduced.
- [x] `docs/open-items.md` rows #19/#17b/#20 correctly annotated `→ PR #107` (not falsely marked ✅).

## Findings

### 🔴 Blocking

- **#1: Drive-Mode curb-width step-up does not apply when Drive Mode is toggled on — only at the
  next incidental overlay rebuild, which may be up to 60 seconds later or may never happen for the
  duration of a short drive.**
  - Where: `Views/MapViewRepresentable.swift` — `mapView(_:rendererFor:)` reads
    `parent.driveModeActive` (new in this PR) inside the delegate's renderer-vending method; but
    that method is only invoked by MapKit the first time a renderer is requested for a **given
    overlay object**, and MapKit caches the result per-overlay after that. `ContentView.swift`'s
    `.onChange(of: driveModeActive) { handleDriveModeAndCamera($0) }` (the SINGLE funnel for every
    Drive Mode entry/exit, per the file's own documentation) never calls `rebuildOverlays(at:)`,
    never bumps `overlayGeneration`, and never removes/re-adds the 5 `TaggedMultiPolyline` overlays.
    The only thing that does either of those is: the 60s `Timer.publish` tick
    (`handleTimerTick`), a `tileLoader.segments.count` change (`handleSegmentsChanged`), a
    selection change (`handleSelectionChanged`), or a Park Until confirm/skip/clear. None of these
    fire as a *guaranteed* side effect of `driveModeActive` flipping.
  - What: enter Drive Mode with curb lines already loaded for the area (the common case — you were
    just browsing the same block before you started driving). The renderer objects already exist
    with the old, cached browse-mode `lineWidth`. `handleDriveCameraChange` (called synchronously
    from the same `.onChange`) zooms the camera IN to the Drive Mode altitude — a subset of the
    already-loaded browse view — so `tileLoader.loadTiles(forRegion:)` (fired from the resulting
    `regionDidChangeAnimated` → `handleRegionChanged`) very likely does not need any tile not
    already cached, so `tileLoader.segments.count` does not change, so `handleSegmentsChanged` does
    not fire, so `applyOverlayPayload` does not re-run, so `mapView(_:rendererFor:)` is never
    re-invoked for the existing overlays, so the lines stay at the OLD (thin) browse width for as
    long as nothing else happens to trigger a rebuild — which, absent a 60s timer tick landing in
    that window, could be the entire early portion of the drive. This is precisely the moment Kevin
    said matters most ("especially in the drive mode").
  - Expected: per the PR's own commit message and the ⑨ acceptance checkbox — "wired via
    `parent.driveModeActive` … the SAME Coordinator→parent flow … syncDriveHeading already
    use[s]" — implying it composes correctly and takes effect on toggle, the way the file's OTHER
    driveModeActive-dependent rendering already correctly does.
  - Why this is a real gap and not a stylistic nitpick: the codebase already has the established,
    working pattern for exactly this problem, immediately adjacent in the same file.
    `mapView(_:viewFor:)`'s `MKUserLocation` branch (`:2177-2178`) also reads
    `parent.driveModeActive` to decide what to render, and its own doc comment explains why that's
    safe: *"On Drive Mode exit, `refreshUserLocationPuck` toggles `showsUserLocation` which causes
    MapKit to re-query this delegate."* `handleDriveCameraChange` (`ContentView.swift:3371-3412`)
    calls `coordinatorActions.refreshUserLocationPuck?(active)` on every single toggle, specifically
    to force that re-query. The curb-width change reads the identical style of `parent.<flag>`
    inside a delegate method but has **no equivalent forced-refresh call** — it relies entirely on
    an overlay rebuild that something else happens to trigger anyway. That's the gap: it borrowed
    the *read* half of the pattern but not the *invalidate* half, and the PR's own description
    describes it as fully wired.
  - Repro (for the Mac gate — this cannot be proven from a screenshot alone, it needs timing):
    1. Launch the app, let curb lines load and settle in an area you're not moving through (so no
       incidental tile loads are pending).
    2. Enter Drive Mode (Cruise or Destination, either path funnels through the same
       `.onChange(of: driveModeActive)`).
    3. **Within the first ~55 seconds**, screenshot the map. Expect (bug): lines are still the
       thin browse-mode width, NOT the drive-mode width. Expect (if fixed): lines are already
       thick immediately on entry.
    4. Wait past the 60s timer tick (or pan slightly to force a tile reload) and screenshot again.
       If the lines visibly thicken at that point but not at step 3, this finding is confirmed live.
    5. Repeat on Drive Mode EXIT — same funnel, same gap, same expected regression (lines should
       drop back to browse width immediately, likely also lag).
  - Fix shape (not prescriptive, for the follow-up PR): the cheapest correct fix is almost certainly
    a one-line addition to `handleDriveCameraChange` (or `handleDriveModeChange`) —
    `rebuildOverlays(at: .nowET)` — mirroring how `refreshUserLocationPuck` is already called from
    the exact same function for the exact same class of problem. Alternatively, force
    `applyOverlayPayload` to be keyed off `driveModeActive` too (e.g. fold it into the payload's
    `generation` or add a second dependency), or explicitly `removeOverlay`/`addOverlay` the 5
    `TaggedMultiPolyline`s from within `refreshUserLocationPuck`'s sibling action. Small, contained,
    should not need new tests beyond a `driveModeActive` toggle asserting `overlayGeneration`
    increments (or equivalent).
  - Owner: `@ios-engineer`

### 🟡 Significant

None. (The above is the only defect found that rises above cosmetic/polish severity; everything
else traced clean.)

### 🟢 Minor / nit

- **#2: `CurbLineWidthTests.swift`'s own header comment concedes the actual UIKit wiring is
  untested** ("the actual `MKPolylineRenderer.lineWidth` assignment itself is UIKit rendering,
  verified live/on-sim per the PR's test plan, not here"). True and appropriately honest, but worth
  noting explicitly: the unit suite covers `CurbLineWidth.width(for:driveModeActive:)` in isolation
  only — it cannot and does not catch Finding #1, because Finding #1 is entirely about *when* that
  pure function's result reaches the screen, not what it returns. This is why the Mac live-gate for
  #19 must specifically test the toggle-timing scenario in Finding #1's repro, not just "lines look
  thicker in Drive Mode eventually."
- **#3: `MKMarkerAnnotationView`'s built-in shadow silently replaces the old manual
  `layer.shadow*` properties** (`shadowColor`/`shadowOpacity`/`shadowOffset`/`shadowRadius`,
  removed in this diff). This is very likely fine — `MKMarkerAnnotationView` draws its own balloon
  shadow by default, and `DestinationPinAnnotation`/`DraftSpotPinAnnotation`/
  `PendingParkPinAnnotation` in this same file already use `MKMarkerAnnotationView` with no manual
  shadow code, so the pattern is proven elsewhere in this codebase — but it's a visual delta (the
  balloon shadow shape/softness differs from the old custom `CALayer` shadow) worth a glance during
  the Mac visual gate rather than assuming it's cosmetically identical.

### 💡 Out of scope (logged, not fixed)

- Nothing new surfaced. The PR correctly stayed inside its four named items and did not touch
  `AppConstants.communityEnabled`, `supabase/`, or the 5-color legality palette.

## Smoke tests run

- **Diff read, adversarial pass** — all 5 changed source files + 3 changed/new test files, full
  unified diff against `origin/main`, twice (once cold, once after tracing the Drive-Mode overlay
  refresh path).
- **Test count reconciliation** — `git archive` of `ios/WePark/WeParkTests` at both `origin/main`
  and `origin/ios/polish-19-17b-20`, `grep -rhoE '^\s*func test'` count: **1314 → 1338**, independently
  confirming the PR's claimed `+24` (not just trusting the commit message's arithmetic).
- **Compile-failure-class sweep** — checked all 3 new/modified test files against the 7 known
  classes: no bare `Category` literal introduced (the one `WePark.Category` hit in
  `ParkedCarDetailCoreParkingTests.swift` is pre-existing, correctly qualified code untouched by
  this diff); `Segment`/`ParkingRule` fixture construction argument order matches the model files'
  memberwise-init order exactly (`id, street, fromStreet, to, side, line, rules, dominantCategory`
  / `category, description, days, timeRanges, anytime, arrow`); no duplicate `XCTestCase` subclass
  names anywhere in the test target (`CurbLineWidthTests`, `ShouldReassignActiveSheetTests`,
  `ParkedCarDetailShouldSuppressStatusLineTests` all unique); no `Calendar.current` introduced (only
  a comment noting its absence); `nonisolated static func` usage matches existing house style
  (7+ precedents already in `ContentView.swift`/`ParkedCarDetailView.swift`).
- **Standard sweeps** — `git diff` grepped for banned copy (avoid/ticket/fine/evasion/dodge): zero
  hits. `git diff --stat -- supabase/`: zero files. `communityEnabled` grep: still `false`.
  `docs/open-items.md` diff read in full: all three rows correctly annotated `→ PR #107`, none
  falsely marked ✅ (that's reserved for merge).
- **Cross-file trace: #19 Drive-Mode wiring** — read `mapView(_:rendererFor:)`,
  `mapView(_:viewFor:)`'s `MKUserLocation` branch, `applyOverlayPayload`, `rebuildOverlays(at:)`,
  every call site of `rebuildOverlays`, `handleDriveModeChange`, `handleDriveModeAndCamera`,
  `handleDriveCameraChange`, `refreshUserLocationPuck`'s wiring, `handleRegionChanged`, and
  `TileLoader.rebuildSegments`/`loadTiles` — this is how Finding #1 was found and corroborated (not
  a guess from reading one call site in isolation).
- **Cross-file trace: #17b guard scenarios** — read `ActiveSheet`'s full `id` implementation (all
  16 cases), `dismissTargetOutsideBrowseNav`, `handleLongPress(at:)`'s full body, and all
  `.sheet(item:)`/`.confirmationDialog(isPresented:)` attachment points on `mapLayerWithEvents`, to
  construct and reason through the four required scenarios (different sheet open, `nil` activeSheet,
  mid-drive no-op, flag-on card path).
- **Cross-file trace: #20 marker uniqueness** — grepped the entire `ios/WePark/WePark` tree (not
  just the diff) for `CarPinAnnotation` and `mappin.circle.fill` to confirm no second render site
  was missed, and confirmed the tentative/parked pins use distinct `MKMarkerAnnotationView` reuse
  identifiers.
- **NOT run** (no toolchain available): `xcodebuild build`, `xcodebuild test`, any simulator launch
  or screenshot. This PR does not touch `MapViewRepresentable.swift`'s mount chain or
  `ContentView.swift`'s toolbar/overlay-attachment structure in a way that changes what's mounted
  (only internal wiring + one delegate-vended marker's styling), so the live-UI-smoke merge-blocker
  in the standing QA policy applies in spirit but the specific failure mode it guards against
  (missing overlay layer) is not implicated here — the Mac gate is still mandatory, per
  `[COMPILE-UNVERIFIED]`, but for compile-correctness and Finding #1's timing behavior, not for a
  missing-chrome regression.

## What's working

- The #17b root-cause narrative is unusually well-supported for a from-diff review — every claim in
  the commit message (same view, non-`Equatable` type, id-based short-circuit) checks out against
  the actual code, not just against itself. This is the strongest piece of engineering in the PR.
- The dedupe guard is exactly the right shape: a pure one-line predicate, with a real-engine test
  that PROVES the divergent case rather than just asserting the suppression case — this is the kind
  of test that would have caught a "collapse everything" overreach if one had been written.
- The #20 marker swap is clean: single render site, correct reuse-identifier separation, and the
  legend copy update actually matches what now renders (the PR did not forget the "describe
  reality" rule this time, unlike the standing item this same open-items file has flagged before).
- Independent test-count verification matched the PR's claimed arithmetic exactly (1314→1338,
  +24) — the PR description is trustworthy on this specific claim, for what that's worth given the
  broader finding above.
