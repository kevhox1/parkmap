# Zoom-Out Crash Fix + Compass QA Pass 1 — 2026-08-24

**Reviewed:** branch `fix/zoom-out-crash-and-tile-perf` at `72679815`, against the PR #89 body/on-device history (no standalone spec doc exists for this PR — reviewed against the six commits' stated intent and `HANDOFF.md` invariants)
**Verdict:** MERGE

## Summary

This is a well-executed, well-documented six-round PR. The crash fix (`TileLoader.tileKeys`/`clampToInt`) is correct for every input class I could construct, including NaN/infinite spans, out-of-`Int`-range spans, and regions entirely outside the tile grid — and the new test suite (`TileLoaderZoomCrashTests.swift`) genuinely exercises those branches rather than asserting tautologies. The three-layer zoom defense (camera ceiling ~41.5km / polyline-hide gate ~8.3km / tile-load backstop ~103.5km) holds numerically, is independently unit-tested (`MapZoomOutLimitTests.swift` Test 6), and every doc comment I found describing the current premise matches the current code — no stale "lock where data ends" comments survived the reversal. No orphaned constants. The `#88` merge is clean (no conflict markers, badge-clear and corner-radius code both intact). One doc-comment imprecision and one untested branch, both cosmetic, are the only findings.

## Acceptance criteria checklist

(Derived from the task's five priorities, since this PR predates a standalone spec doc.)

- [x] Crash fix is correct for all input classes (finite, NaN, ±infinity, out-of-Int64-range, off-grid) — verified by code read + `TileLoaderZoomCrashTests.swift` (25 tests across 5 groups, all exercising real branches)
- [x] `nonisolated` on `tileKeys`/`clampToInt` is necessary and sufficient for the stated compile problem — verified by confirming `TileLoader` carries explicit `@MainActor` (line 99) and the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on the app target (`project.pbxproj:364,404`); not independently compile-verified (no Swift toolchain on this VPS)
- [x] Camera zoom-out limit derivation (`manhattanCoverageBounds` × 1.1 → `altitudeForSpan`) — verified by independent arithmetic re-derivation (≈41,468m, matches doc's 41,467m and the test's 41,470±200m assertion)
- [x] Three-layer ordering (camera < tile-load backstop, polyline-hide < camera) — verified by independent arithmetic AND by `MapZoomOutLimitTests.testMaxZoomOutCenterCoordinateDistance_isTighterThanTileLoadBackstop`
- [x] `polylineHideSpanThreshold` move preserved value (0.04) and all readers resolve — verified, single production call site (`ContentView.swift:1447`), value unchanged
- [x] No vestigial constants from the three-round retuning — verified, all four new/moved constants (`maxLoadSpanDegrees`, `manhattanCoverageZoomOutMarginFactor`, `maxZoomOutCenterCoordinateDistance`, `polylineHideSpanThreshold`) have exactly one real call site each
- [x] No stale doc comments asserting the old "lock where data ends" premise — verified, all surviving references to the old premise are in explicitly-labeled "Round 1" history sections
- [x] Test churn is a genuine reversal, not a weakened/vague re-assertion — verified by reading commit `0510b252`'s and `44980256`'s diffs directly; old test names are gone, replacement tests assert the opposite (and correct) relationship
- [x] Compass added once in `makeUIView`, not `updateUIView` — verified, `addSubview`/constraint-activation is at `MapViewRepresentable.swift:1105-1113`, before `return mapView` (1115); `updateUIView` (starts 1118) has zero compass-related code
- [x] Nothing else claims top-leading in browse or Drive Mode — verified, `recenterButtonStack`/`endDriveControl` are `topTrailing`, `parkingGuideBannerOverlay` is bottom-anchored, gear/? buttons are deleted (FT-20)
- [x] `recenterOnCar()` and the deep-link path deliberately unguarded (user-placed data, existing precedent) — verified, both call `recenterMap(on:)` directly with no `isInManhattanCoverage` check; `AppConstants.isInManhattanCoverage`'s own doc comment predates this PR and states "the deep-link / parked-car path bypasses this check"
- [x] Launch fallback to `manhattanCenter` untouched — verified, zero diff lines in that code path
- [x] FT-20 confirmed-working set undisturbed (`.onGeometryChange`, `.presentationBackground(.regularMaterial)` ×9, `ft20BrowseSheetEnabled = true`) — verified present and unchanged
- [x] PR #88 (badge-clear, corner-radius) survived the merge — verified, `clearBadge()` call site intact at `ContentView.swift:2779`, `cornerRadius: 10` search-field styling intact, no conflict markers anywhere in the tree

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

None.

### 🟢 Minor / nit

- **#1: `nonisolated` doc comment slightly misattributes its own cause**
  - Where: `ios/WePark/WePark/Services/TileLoader.swift:52-58`
  - What: The comment says `tileKeys`/`clampToInt` needed `nonisolated` because "this project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`... unannotated members of an `@MainActor` type inherit that isolation." The build setting is real (`project.pbxproj:364,404`) but isn't actually the operative cause here — `TileLoader` is *explicitly* `@MainActor` (line 99), and an explicit `@MainActor` on a type isolates all its members (instance and static) regardless of the project's default-actor-isolation setting; that's been true since actor isolation propagation was introduced, independent of the newer `SWIFT_DEFAULT_ACTOR_ISOLATION` build flag. Confirmed this isn't a live risk elsewhere: `MapViewRepresentable` (a plain `struct`, no `@MainActor` annotation) has several un-`nonisolated` static pure functions (`altitudeForSpan`, `targetPitch`, `driveModeCameraSpan`, etc.) that are already called synchronously from six pre-existing XCTestCase files (`DriveCameraTiltTests.swift`, `FT17aTests.swift`, `TF211Tests.swift`, `DriveZoomStyleTests.swift`, `FT8Tests.swift`, `FT10Tests.swift`) without incident — including the brand-new `MapZoomOutLimitTests.swift` added by this same PR, which follows that exact established pattern. So the fix's *scope* (added only to `TileLoader`, not `MapViewRepresentable`) is correct; only the comment's causal narrative overstates the build setting's role.
  - Expected: N/A — not a functional bug, no fix required. Worth a one-line comment tweak next time this file is touched.
  - Owner: `@ios-engineer` (low priority, opportunistic)

- **#2: `loadTiles(forRegion:)`'s `maxLoadSpanDegrees` early-return guard is untested**
  - Where: `ios/WePark/WePark/Services/TileLoader.swift:188-194` (the `guard region.span.latitudeDelta <= Self.maxLoadSpanDegrees ... else { return }` inside the instance method `loadTiles`)
  - What: `TileLoaderMaxLoadSpanTests.testMaxLoadSpanDegrees_isDocumentedValue` only locks in the *value* of the constant (0.5). No test exercises the actual branch that uses it — i.e., that `loadTiles` returns early (no `tileKeys` call, no cache touch, no decode `Task`) when span exceeds 0.5°. This is a simple one-line guard so risk is low, but Priority 3 of this review explicitly asked to name untested branches, and this is the one that exists.
  - Expected: A test instantiating a real (or lightly-mocked) `TileLoader`, calling `loadTiles` with a >0.5° region, and asserting no state mutation (e.g., `segments`/`cache` unchanged) would close this gap. Not required for merge — the guard is trivial and the value is locked.
  - Owner: `@ios-engineer` (opportunistic follow-up)

### 💡 Out of scope (logged, not fixed)

- The 56pt compass top-offset is explicitly documented as a derived estimate ("no simulator/Xcode in this environment... nudge the constant below if it's still off") and is already in Kevin's ALREADY-CONFIRMED list for this pass — not relitigated here.
- Kevin's open "zoom/pan lag" complaint is explicitly out of scope for this PR per its own doc comments (`polylineHideSpanThreshold` stays at 0.04 specifically to not reopen that regression) — correctly scoped, not a PR #89 defect.
- `TileLoader.tileKeys`'s instance wrapper copies `tileSet: Set<String>` (~1,071 entries) by value into the static function on every call. Pre-existing characteristic (the old code also read `idx.tileSet` per-call), unchanged by this PR — not a new regression, just noting it's unreviewed as a potential contributor to the lag complaint above.

## Priority-by-priority notes (per the dispatch brief)

**P1 — retuning damage.** No vestigial constants found. All four constants introduced/moved by this PR (`maxLoadSpanDegrees`, `manhattanCoverageZoomOutMarginFactor`, `maxZoomOutCenterCoordinateDistance`, `polylineHideSpanThreshold`) resolve to exactly one production call site each:
- `TileLoader.maxLoadSpanDegrees` → `TileLoader.swift:189` (`loadTiles` guard)
- `MapViewRepresentable.manhattanCoverageZoomOutMarginFactor` → `MapViewRepresentable.swift:792-796` (feeds `maxZoomOutCenterCoordinateDistance`)
- `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` → `MapViewRepresentable.swift:841` (`setCameraZoomRange`)
- `AppConstants.polylineHideSpanThreshold` → `ContentView.swift:1447` (`rebuildOverlays` guard), value confirmed unchanged at 0.04
No leftover `53,000`/`7,457` literals exist as live code — every hit is inside a doc-comment history section, correctly labeled as prior rounds. Test churn (commit `0510b252` → `44980256`) is a genuine reversal, not weakening: old test names (`...staysInsidePolylineHideThresholdWithMargin`, `...tracksPolylineHideThreshold`) are gone entirely; replacements assert the new, opposite relationship with equal or greater specificity.

**P2 — three-layer coherence.** Numerically verified independently (not just re-reading the PR's own arithmetic): polyline-hide implied span 0.04° (~8,285m) < camera ceiling implied span 0.2002° (~41,468m) < tile-load backstop 0.5° (~103,567m). `MapZoomOutLimitTests.testMaxZoomOutCenterCoordinateDistance_isTighterThanTileLoadBackstop` locks this ordering in code, so a future retune that breaks it fails CI, not just silently drifts. The claim that `maxLoadSpanDegrees` is now unreachable via steady-state camera holds — confirmed by the same numeric check — and the reasoning that it remains necessary as a mid-gesture backstop (MapKit's `regionWillChangeAnimated`/`regionDidChangeAnimated` delegate callbacks read live `mapView.region` during active gestures, which `setCameraZoomRange` constrains at settle time but not necessarily every intermediate frame) is architecturally sound, though ultimately only device testing (which Kevin already did — "no crash at maximum zoom-out") can fully confirm transient span behavior.

**P3 — crash fix correctness.** `clampToInt` never traps: NaN → `lower` (via `value > 0` being false for NaN), `+inf` → `upper`, `-inf` → `lower`, in-range → truncated `Int(value)`. `tileKeys`'s finite-guard runs before any `Int` conversion; the grid clamp bounds every row/col to `[0, gridRows-1] × [0, gridCols-1]`, making iteration count bounded at `gridRows × gridCols` (≤4,000 for the real 80×50 grid) for literally any input. `TileLoaderZoomCrashTests.swift`'s 25 tests are not tautological — they use a hand-verifiable synthetic 10×8 grid with two deliberately-excluded corners specifically so "clamped into range" and "clamped into a real tile" are distinguishable, and cover NaN/±infinity/1e300/negative-span/zero-span/world-span/off-grid-both-directions. One untested branch found: the `loadTiles` early-return guard itself (see Finding #2, 🟢).

**P4 — compass and coverage guard.** Compass subview add + constraint activation confirmed one-time, inside `makeUIView`, before `return mapView`; zero compass code in `updateUIView`. Nothing else claims the top-leading corner in any mode I could find (browse: `recenterButtonStack`/`endDriveControl` are `topTrailing`; `parkingGuideBannerOverlay` is bottom-anchored; FT-20 already deleted the gear/`?` buttons that used to float top-leading). `recenterOnCar()` and the notification deep-link path (`routePendingDeepLink`) both call `recenterMap(on:)` unguarded — confirmed deliberate and consistent with `AppConstants.isInManhattanCoverage`'s own pre-existing doc comment ("the deep-link / parked-car path bypasses this check — user explicitly parked there"). Launch fallback to `manhattanCenter` (`ContentView.swift` Priority-3 branch) has zero diff lines — untouched. The "self-tracking" claim for `safeAreaLayoutGuide.topAnchor` (that it automatically reflects the ASP banner's height because `.safeAreaInset(edge: .top)` is attached directly to `mapRepresentable`) is architecturally the correct SwiftUI/UIKit-interop pattern and is consistent with Kevin's own on-device confirmation that the compass clears the banner — not relitigated per the dispatch brief.

**P5 — regression sweep.** FT-20 constructs (`.onGeometryChange`, `ft20BrowseSheetEnabled = true`, `.presentationBackground(.regularMaterial)` at 9 call sites, conditional action-content rendering) all present and untouched by this branch's diff. PR #88's badge-clear (`NotificationScheduler.clearBadge()`, called at `ContentView.swift:2779`) and corner-radius fix both survived the merge intact — confirmed via `git diff 747f1e90 -- ContentView.swift`, which shows only PR #89's own changes layered on top of #88's content, and via a repo-wide grep for unresolved conflict markers (none found).

## Smoke tests run

No simulator/Xcode available on this VPS — cannot compile, run `xcodebuild test`, or take a screenshot. This PR does not touch `MapViewRepresentable.swift`'s render/overlay chain in a way that would normally require a live-UI smoke per the dispatch brief's mount-chain trigger list (it adds a plain UIKit subview + a camera zoom-range call in `makeUIView`, doesn't touch overlay rendering, toolbar layout, or `.safeAreaInset` structure itself) — and Kevin has already run the live-device smoke this PR class requires (listed in "ALREADY CONFIRMED," including the exact assertion this review would otherwise most want to see live: "Compass appears top-left on rotation, clears the ASP banner, aligns with the right-hand rail"). Everything else in this report is static analysis: full `git diff origin/main...HEAD` read line-by-line across all 6 changed files, independent re-derivation of every piece of arithmetic (altitude formula, three-layer span ordering, `clampToInt`/`tileKeys` boundary behavior), cross-referencing every doc-comment claim against actual code (actor isolation, `SuspensionBannerState` case list, `ASPBanner`'s always-visible rendering, `paddingForBannerState` existence, deployment target for `MKCompassButton`/`.adaptive`/`setCameraZoomRange` API availability), and a full commit-by-commit read of the six-round history to verify the test-churn narrative against the actual diffs (not just the commit messages).

**Not verified — recommend Kevin's routine `xcodebuild test` pass (already required per PR body) settle this:** whether `nonisolated static func tileKeys`/`clampToInt` actually compiles and is callable from the new `TileLoaderZoomCrashTests.swift` XCTestCase methods as intended. The reasoning is sound (see Finding #1) but this environment has no Swift toolchain to confirm it.

## What's working

- The crash fix itself is genuinely excellent: bounded to ≤4,000 iterations for any input including pathological ones, with a real (not tautological) test suite that would have caught the original bug.
- The six rounds of retuning left the codebase *cleaner* than a typical multi-round churn history would — every reversal is explicitly labeled ("Round 1"/"Round 2"/"Round 3"), every deleted test's replacement is named to make the diff obvious, and I found zero stale comments asserting a premise the code no longer implements. This is exactly the discipline the dispatch brief was worried might be missing, and it's present.
- The three-layer defense-in-depth reasoning holds up under independent arithmetic re-derivation, not just re-reading the PR's own claims, and is now locked in by a dedicated ordering test rather than left to drift.
- Good precedent-following on the coverage guard: rather than inventing a new guard pattern for `recenterOnUser`/`handleLocationUpdate`, the fix reuses the existing out-of-coverage toast, and correctly leaves `recenterOnCar()`/deep-link alone by recognizing they're a different case (user-placed data) with existing precedent already documented elsewhere in the codebase.
- The compass repositioning correctly diagnosed and fixed its own initial mistake (round 3 caught that `mapView.topAnchor` ≠ `recenterButtonStack`'s effective origin because one is a `mapRepresentable` descendant and the other is a ZStack sibling) rather than papering over it with a fudged constant — that's the right instinct for this codebase's `.safeAreaInset`-heavy layout.
