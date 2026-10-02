# QA Report: PR #121 — curb-snap-on-display (split from #118)

**Reviewed:** `ios/curb-snap-display` @ `8c60b960`, forked from `main` @ `6eded5b6`, against `docs/report-tap-to-place-spec.md` §2 and `docs/qa/pr118-tap-to-place.md` (prior QA of this same code, inside #118). Static-only (no toolchain on this VPS). This is a split-integrity + ships-unflagged pass, not a from-scratch logic re-review — the projection logic itself was already QA'd and found sound in #118 pass 1.

**Verdict: MERGE-PENDING-MAC-GATE** — the split is clean, the carve introduces zero new logic, and nothing from the excluded reposition half leaked in or was left dangling. No blocking defects found. Two Mac-gate items are still owed (both already flagged by the engineer, not new findings from me).

## Split integrity — the main job

**Grep-proof (empty, as claimed):**
```
git diff main...origin/ios/curb-snap-display -- ios/ | grep -E '^[+-]' | \
  grep -Ei 'reposition|presentationBackgroundInteraction|reportSheetDetent|ReportRepositionUpdate|handleReportRepositionTap'
```
Zero matches (exit code 1). `ContentView.swift` has zero lines changed (`git diff --stat` shows no entry for it at all). `docs/report-tap-to-place-spec.md` and `Views/ReportSheet.swift` are likewise absent from the diff.

**Files touched (7, matches PR description exactly):**
`docs/open-items.md`, `Models/CommunityPin.swift`, `Models/ParkedCar.swift`, `Services/CandidateSegmentSearch.swift`, `Views/MapViewRepresentable.swift`, `Views/PinMarkerAnnotation.swift`, `WeParkTests/CurbSnapDisplayTests.swift` (new).

**Byte-identical-extraction claim, independently verified** by diffing `main...origin/ios/curb-snap-display` against `main...origin/ios/report-tap-to-place` for each shared file:
- `Models/CommunityPin.swift` — identical, `diff` rc=0
- `Models/ParkedCar.swift` — identical, `diff` rc=0
- `Views/MapViewRepresentable.swift` — identical, `diff` rc=0
- `Views/PinMarkerAnnotation.swift` — identical, `diff` rc=0
- `Services/CandidateSegmentSearch.swift` — **diverges exactly where it should and nowhere else**: the only differences are (a) one doc-comment reword on `nearestPointOnPolyline` dropping the now-irrelevant reference to the sibling `reportRepositionCandidates`/"QA pass 1 (PR #118) nit" attribution, and (b) the `reportRepositionCandidates` struct+function (lines 71–100 of #118's hunk) are absent here. `coordinate(atFraction:along:)` and the `private`→`internal` promotion of `nearestPointOnPolyline` are otherwise identical.

**Test file, independently verified as a true subset, not a rewrite.** #118's `ReportTapToPlaceSpecTests.swift` has 40 `func test...` and #121's `CurbSnapDisplayTests.swift` has 14. I extracted the test name list from both and confirmed: the 14 names in #121 are the exact first 14 names in #118 (in the same order), and the class boundary (`ShowsRepositionAffordanceTests`, #118 line 325) is precisely where the reposition tests begin — nothing from that class or later leaked into #121. I also read both files' bodies side-by-side (fixture helpers, `CoordinateAtFractionTests`, `ResolveDisplayCoordinateTests`, `ResolveDisplayCoordinatePrimitiveCarPinShapeTests`) and confirmed the test logic — assertions, fixture values, accuracy tolerances, comments — is byte-identical between the two files for all 14 overlapping tests.

## Self-containment / nothing left dangling

Traced every new/changed symbol back to something that already exists on `main` (not something living only in the excluded reposition commits):
- `MapViewRepresentable.segments: [Segment]` (line 381) is a pre-existing stored property, already consumed by the pre-existing `syncCommunityPinAnnotations(_:segments:on:)` call at line 1479. `syncCarPin`'s new `segments:` parameter is fed from this same already-in-scope property at its one call site (`updateUIView`) — no new plumbing needed, no excluded type involved.
- `syncCarPin(_:on:)` has exactly one call site in the whole codebase (`updateUIView`); the diff updates both the signature and that one call site together. No orphaned caller.
- `CommunityPinAnnotation(pin:bearing:)` (two-arg) has exactly one production call site (`MapViewRepresentable.swift:1966` on `main`) and it's the one the diff upgrades to the new three-arg `displayCoordinate:` initializer. The only remaining callers of the two-arg and one-arg convenience inits are `Tier3PinFeedbackTests.swift` (test fixtures) — consistent with the doc comments' claim that those inits are the deliberate raw-fallback path for callers with no segment data.
- `ParkedCar.detectedSegmentID` (pre-existing field, `ParkedCar.swift:37`) and `Segment.coordinates` (pre-existing computed property) are both already on `main` — not reposition-branch additions.
- `CandidateSegmentSearch.nearestPointOnPolyline`'s `private`→`internal` promotion only widens visibility; nothing about its implementation changed, so this is a compile-safe, logic-safe change in isolation.

No dangling reference to an excluded symbol anywhere in the diff. This branch should compile standalone off `main` with no missing-symbol errors attributable to the carve.

## Ships-unflagged safety

Re-confirmed (not re-litigated — #118 pass 1 already did the hard verification work on this exact logic, carried over unmodified):
- `resolveDisplayCoordinate`'s nil/unresolved-segment fallback (`guard let segmentId, let segment = segmentByID[segmentId] else { return raw }`, plus the `polyline.count >= 2` degenerate-polyline guard) returns the raw, untouched `lat`/`lng` — byte-identical to today's render position for every pin that doesn't carry a resolvable segment. No force-unwraps.
- `coordinate(atFraction:along:)` clamps `fraction` to `[0,1]` before use (`min(1, max(0, fraction))`) — a malformed/out-of-range stored value can't extrapolate past either endpoint.
- Per-pin-type question re-confirmed: `positionFraction` is a generic field on `CommunityPin` (not type-specific), and the nearest-point-projection branch (no fraction, resolved segment) is distance-agnostic — it snaps the pin's own GPS-noise-y coordinate onto the correct, already-known curb line, for every pin type that carries a `segmentId`. It does not reinterpret or relocate the pin to a *different* position than where it was reported/detected; it only removes off-line jitter. This holds for `leaving_soon`/`enforcement_active`/`sweeper_passed`/the parked-car marker alike — none of them get moved to a materially different place, just onto the curb they're already associated with. Same conclusion as #118 pass 1 line 9 of `docs/qa/pr118-tap-to-place.md`.
- Perf: traced `syncCommunityPinAnnotations` — `resolveDisplayCoordinate(for:segmentByID:)` is called exactly once, inside the `toAdd` loop (new pins only, gated by `guard !toAdd.isEmpty else { return }`), using the same `segmentByID` dict built once per sync pass that `resolveBearing` already uses. Not called from `coordinate`'s getter, not called per-frame, not called for already-tracked pins. `syncCarPin`'s projection likewise only runs on the car-changed path (gated by the existing fast-path check above it), not per frame.
- Inherited (not new) nit, carried forward unchanged from #118 pass 1: a pin added to the map before its segment's tile has loaded renders raw and stays raw until the annotation is removed+re-added (same class of race as the pre-existing `bearing` precomputation). This is unchanged by the split — not a regression introduced here, and already a known 🟢 in the prior pass.

## Count / flags / supabase

- `main`: `grep -rE '^\s*func test' ios/WePark/WeParkTests/*.swift` → **1407**, confirmed.
- `origin/ios/curb-snap-display` touches exactly one test file (`CurbSnapDisplayTests.swift`, new, +14 tests) and zero other test files — so the branch total is **1421** (1407 + 14), matching the PR's claimed count exactly.
- `Services/Constants.swift` is absent from the diff — `communityEnabled = true`, `regularsEnabled = false` untouched.
- No `supabase/` path appears in the diff.

## Acceptance criteria checklist (spec §2)

- [x] AC-1: resolved `segmentId`, no `positionFraction` → nearest-point projection, not raw — implemented in `resolveDisplayCoordinate`, tested (`testResolveDisplayCoordinate_noPositionFraction_projectsRawCoordOntoPolyline`)
- [x] AC-2: resolved `segmentId` + `positionFraction` → fraction-interpolated — implemented, tested (`testResolveDisplayCoordinate_positionFractionPresent_interpolatesAlongPolyline`)
- [x] AC-3 / OD-1: no resolvable segment (nil, not-loaded, or degenerate <2-vertex polyline) → raw lat/lng unchanged — implemented, tested (3 tests covering all three sub-cases)
- [x] AC-6: pure function `(pin, segmentByID) → coordinate`, no `MKMapView` dependency — confirmed by reading the function signature and call graph; directly unit-tested
- [x] Kevin's live-gate F2 (parked car renders on curb, not in a building) — `syncCarPin` now projects through the same primitive overload; tested (`testResolveDisplayCoordinate_carPinShape_segmentResolves_projectsOntoCurb`). **Not yet confirmed live** — see Mac gate checklist.
- [x] `ParkedCar.latitude`/`.longitude` and `CommunityPin.lat`/`.lng` never mutated — confirmed by reading the diff; both files' non-comment lines are unchanged, only doc comments were edited

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None new. (The two 🟡s from #118 pass 1 — OD-1 scroll-guard auto-scroll and the transient dual-active-mode window — both live entirely in `ReportSheet.swift`/`ContentView.swift`'s reposition machinery, which this PR doesn't touch. They remain owed on `ios/report-tap-to-place`, not here.)

### 🟢 Minor / nit
- Inherited race (not introduced by this PR): a community pin or the parked-car marker added to the map before its segment's tile finishes loading renders at raw coordinates and won't re-snap until the annotation is removed and re-added. Pre-existing class, already noted in #118 pass 1 against the `bearing` precomputation; now applies identically to `displayCoordinate`. No action needed for this PR; worth a follow-up ticket if tile-load-order jank around curb-snap is ever reported live.

### 💡 Out of scope (logged, not fixed)
- Live on-device confirmation of the F2 fix (parked car on the curb, not in a building) — explicitly flagged by the engineer as owed, no toolchain available on the VPS session that wrote this PR.
- `ios/report-tap-to-place` (#118) still needs a rebase onto this PR's merge commit, reduced to reposition-only, before its next live-gate attempt — tracked in `docs/open-items.md` item #22.

## Smoke tests run

- `git diff main...origin/ios/curb-snap-display -- ios/ | grep -Ei 'reposition|presentationBackgroundInteraction|reportSheetDetent|ReportRepositionUpdate|handleReportRepositionTap'` → empty. PASS.
- `git diff --name-only` for `ContentView.swift`, `ReportSheet.swift`, `report-tap-to-place-spec.md`, `ReportTapToPlaceSpecTests.swift`, `CommunityS13aTests.swift` → none present. PASS.
- Per-file diff-of-diffs against `main...origin/ios/report-tap-to-place` for all 4 shared production files → byte-identical. PASS.
- `CandidateSegmentSearch.swift` diff-of-diffs → diverges only at the excluded `reportRepositionCandidates` function + one doc-comment reword. PASS.
- Test name/body comparison between `CurbSnapDisplayTests.swift` (14 tests) and `ReportTapToPlaceSpecTests.swift` (40 tests) → the 14 are an exact, byte-identical prefix subset. PASS.
- Call-graph trace: `segments` property, `syncCarPin`/`CommunityPinAnnotation` call sites, `detectedSegmentID`/`Segment.coordinates` fields — all pre-existing on `main`, none sourced from excluded reposition commits. PASS.
- Test count: `main` = 1407 (counted directly); branch adds exactly one test file with 14 tests and touches no other test file → 1421. PASS.
- `Constants.swift` and any `supabase/` path absent from diff. PASS.
- This is NOT a mount-chain PR (no `MapViewRepresentable`'s `.safeAreaInset`/overlay-attachment chain touched, no `ContentView.swift`, no `DriveMode*.swift` files) — the live-UI-smoke-mandatory gate from the operating doc does not apply here as a merge-blocker. A build+screenshot smoke was not performed, consistent with that scoping; however, given the "ships to 100%, unflagged, every pin" blast radius, the two visual checks below are still owed before merge and are called out explicitly in the Mac gate checklist, matching the PR description's own framing.

## What's working

- The split is exactly what it claims to be: a pure textual carve with zero logic drift on every file shared with #118, and a precisely-scoped exclusion on the one file that needed one (`CandidateSegmentSearch.swift`). This is a model example of how to split a PR — I found no surprises.
- No new dependency surface was introduced by the carve — every new/changed symbol resolves against something already on `main`, so there's no reason to expect a compile failure attributable to the split itself (compile status of the underlying logic is unchanged from #118, which already compiled cleanly enough to reach a live gate).
- Test extraction discipline is excellent — exact byte-for-byte subset, not a re-derivation, which eliminates an entire class of "looks similar but isn't" risk.
- The doc-comment-only changes to `CommunityPin.swift`/`ParkedCar.swift` are accurate and don't overstate what the code does (correctly distinguish the persisted-model "never snapped" invariant from the new display-only marker position).

## Mac gate checklist

1. `xcodebuild test` — expect **1421/1421** (first compile of this specific branch; if it fails to compile, the failure is very unlikely to be attributable to the split given the self-containment trace above — more likely a pre-existing issue carried over from #118, which itself was `[COMPILE-UNVERIFIED]` at gate time).
2. Visual check #1 — curb-snap on a community pin: find a known mid-block community pin (ideally one on a curved or offset blockface) and confirm it renders ON the curb line, not at its old raw/mid-block position.
3. Visual check #2 — curb-snap on the parked-car marker: set a parked car on a segment with a resolvable `detectedSegmentID` and confirm the blue car marker renders on the curb, not mid-block or inside a building (this is Kevin's original F2 repro — the primary reason this PR exists).
4. Quick negative check: a pin or parked-car state with no resolvable segment (e.g. immediately after a fresh tile-boundary cross, before the new tile loads) should still render at today's raw position — no crash, no visible jump once the tile does load (beyond the intended snap).
