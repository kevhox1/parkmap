# PR #137 (A1 curb-snap engine) QA Pass 1 — 2026-10-23

**Reviewed:** branch `feat/a1-curb-snap-engine` at `571df39c`, against `docs/longpress-universal-plant-spec.md` Amendment §A.3 / §A.6 / §A.9 / §A.11 (A1-A6) and `docs/design/curb-pin-placement-design.md` (snap-touching parts)
**Verdict:** 🟡 FIX-THEN-MERGE (one ruled constant change plus its dependent test numbers; no engine-logic defect found; Mac compile and perf gates still owed)

## Summary

The engine is correct. I hand-traced the grid math, the 3x3 sufficiency claim, the incumbent/challenger rule and the tie-breaking, and cross-checked the grid claim with an independent Python port (90,000 randomized queries incl. negative coordinates and edges/pins exactly on cell boundaries: 0 misses within 30 m; 100 m probe at ring 4: 0 misses). Nothing in the diff touches `project.pbxproj`, the mount chain, or any UI, so the live-UI smoke gate does not apply to this PR. The only required change is the already-ruled `hysteresisPoints` 8 -> 14, which also forces edits to ~7 hard-coded test numbers (listed in #1). Everything else is 🟢/💡. **Not compiled or run: there is no Swift toolchain on this host** (same as the builder). Static review only; the Mac `xcodebuild test` + Release perf pass remains a hard gate.

## Acceptance criteria checklist

- [x] **A1** (within 24 m returns blockface, fraction, distance, on-line snap) — `testResolve_withinAcquire_...` (hand-checked: x=20 on [-100,100] -> 0.6; foot point same x on curb northing) and `..._multiVertex_matchesNearestPointOnPolyline` (winner's fraction/foot come straight from `CandidateSegmentSearch.nearestPointOnPolyline`, `resolve` lines 462-473). Verified by code read + hand trace; not run.
- [x] **A2** (hysteresis: once per sweep, no return within dead-band, +/-0.3 m jitter zero flips) — tests 23-28 cover both directions, round trip, jitter, noisy crossing. Logic verified analytically (see #1/#2). Expected-number assertions are written for 8 pt and MUST change with the 14 pt ruling.
- [x] **A3** (tie determinism, 100 shuffles) — `isBetter` ties on (d2, groupKey, segment id); per-edge geometry is built from the segment alone, so the per-edge d2 is order-independent. Verified by read; tests 21/22.
- [x] **A4** (blockface in two tiles resolves once) — group id per `blockfaceKey`, best edge tracked per group. Test 20 genuinely discriminates (a per-segment incumbent distance would flip to the rival); test 19 alone would pass without dedup, but 20 covers it.
- [x] **A5** (>30 m -> no curb; incumbent retained 24-30, never acquired in band) — tests 12-18, plus code path lines 431-453 traced.
- [ ] **A6** (perf recorded vs A.6 targets) — NOT VERIFIED. `measure {}` tests exist (build 5k, 1,000 queries x2, 30 Hz 3 s sweep); numbers are a Mac-gate deliverable. Not a defect of this PR, but A6 stays open.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: `hysteresisPoints` default 8 contradicts §A.3 prose (builder deviation #5); the ruled fix to 14 needs a matching test sweep**
  - Where: `Services/CurbSnapIndex.swift:87` (default `8.0`; doc comment at line 98 "8 pt clamped to 1.5-4 m"); `WeParkTests/CurbSnapIndexTests.swift` lines 169, 180, 186, 513 (comment), 523-524, 535-536, 564-569, and the "2.24" comments near 425/461.
  - What: challenger flips when `challengerD < incumbentD - H`, i.e. at `H/2` past the centreline. Hand trace, two curbs S at y=0 and N at y=15 (centre y=7.5), incumbent S, entry zoom 0.28 m/pt:
    - 8 pt: H = 2.24 -> flip at u > 1.12 m (y > 8.62). Prose says "~2 m past the middle": NOT met.
    - 14 pt: H = 14 x 0.28 = 3.92 (inside the 4.0 clamp) -> flip at u > 1.96 m (y > 9.46). Matches the prose exactly. I confirmed the engine math is unchanged by the constant: it is the one default plus tests.
  - Expected test deltas after the change (computed by hand, not run):
    - `testConfig_defaults_matchSpec`: `hysteresisPoints` 8 -> 14.
    - `testConfig_hysteresisMeters_scalesAndClamps`: 0.28 m/pt -> 3.92 (was 2.24); the `1.5 / 8.0` boundary -> `1.5 / 14.0`. The 0.05 (->1.5), 2.0 (->4.0) and 0.5 (->4.0) rows still hold.
    - `testHysteresis_sweepUp_flipsExactlyOnce`: first flip y=10, index 13 (not 12).
    - `testHysteresis_sweepDown_flipsExactlyOnce`: first flip y=5, index 13 (not 12).
    - `testHysteresis_roundTrip_...`: flips ~9.46 / ~5.54 (was 8.62 / 6.38); band width 3.92, so the `assertLessThan(..., 2.5)` at line 569 fails and must become ~4.5; `greaterThan(2.0)` still passes.
    - Unchanged by the constant: `deadbandTracksMetersPerPoint` (0.05 -> clamps to 1.5 -> 8.25; 1.0 -> clamps to 4.0 -> 9.5), jitter, noisy-crossing (ends at y >= 10.7, still one flip), all radii tests (`takesOver` gap 6 > 3.92), test 20 (rival 6.5 < far-copy 12 - 3.92 = 8.08, still discriminates), the oracle and perf tests.
  - Repro: read lines 470-474 of the spec vs `hysteresisPoints = 8.0`.
  - Owner: `@ios-engineer`

- **#2: Scan widening (`ring` > 1) and any non-default `CurbSnapConfig` are untested**
  - Where: `CurbSnapIndex.swift:389-393`; no test constructs `CurbSnapConfig(...)` with arguments (only `CurbSnapConfig()` at test lines 166/178/191).
  - What: the builder's protection for configs whose radius exceeds the 32 m cell is real in code (I verified `ring = ceil(scanRadius/32)`, so 24/30 -> 1, 33 -> 2, and the port confirms ring 4 covers 100 m), but nothing exercises it. It is also the only mechanism that makes the A.3 "nearest curb within 100 m" chip possible without a new API (see #6), so A2/A3 will lean on an untested path.
  - Expected: one test with `CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)` and a curb ~80 m away (beyond the 3x3 block) -> `.snapped` with the right distance/foot point; plus a custom-config test of the explicit init (the reason the builder diverged from the contract sketch).
  - Owner: `@ios-engineer`

### 🟢 Minor / nit

- **#3: `Int(ringRaw)` can trap on a finite but huge radius.** `CurbSnapIndex.swift:392-393`: `ringRaw.isFinite ? min(8, max(1, Int(ringRaw))) : 1` converts before clamping. `Int(1e300)` traps. Not reachable with any shipped config; fix is clamp in Double first (`Int(min(8, max(1, ringRaw)))`). Owner: `@ios-engineer`.
- **#4: `CurbSnapResult ==` doc invites per-frame gating.** Lines 118-121 say the exact-number `==` is "for 'did the outcome change' gating". A2's `onPlacementOutcome` must fire on blockface / outcome-kind change only (A.9, A.11 A23). The foot point and distance change every frame of a pan, so gating on `==` would fire at 30 Hz and write SwiftUI state per frame. Reword to "gate on `blockfaceKey` / case, not `==`". Flag for A2/A3 QA. Owner: `@ios-engineer`.
- **#5: result `distanceMeters` is haversine, scan distance is flat-earth.** Differences of ~0.1% (haversine R=6,371 km = 111,195 m/deg vs 111,320) plus up to ~0.33% longitude-scale variance across Staten Island (40.5N) to the north Bronx (40.92N) vs the 40.7128 origin. At 24 m that is <= ~0.1 m. Downstream must not assert `result.distanceMeters <= acquireRadius` or compare it against the `> 15 m` far-curb rule with zero tolerance. Documented in the header; just carry it into A3.
- **#6: "allocates nothing per call" is true of the scan only.** The winner finalisation (`winner.coordinates` `compactMap`, the cumulative-length array inside `nearestPointOnPolyline`, a `Segment` copy) allocates once per resolve. The doc comment says "Allocation-free in the candidate scan", which is accurate; just don't repeat the stronger claim in the PR body. At 30 Hz with A2's 0.15 m movement skip this is fine.
- **#7: "Why 14 pt is fine, and where it bites" (analysis requested in the brief; no change required).**
  - Clamp behaviour: floor binds at mpp <= 1.5/14 = 0.107; ceiling at mpp >= 4/14 = 0.2857. At the spec's 0.28 entry zoom H = 3.92, just under the cap, so after any pinch-out the effective dead-band is a constant 4.0 m (flip 2.0 m past the centre), shrinking in screen terms (4 m = 8 pt at 0.5 m/pt, 3-4 pt at ~1 m/pt). That is the intended "zoom-out never sticky" ceiling, and it is why the 14 pt number lands exactly on the spec's "~2 m" at entry zoom.
  - Side street (curbs ~12 m apart): incumbent holds until the pin is within `(S - H)/2` = 4.0 m of the challenger curb (8 m from the incumbent). That is the most the incumbent can overshoot: H/2 <= 2 m past the true midpoint. Avenue (~20-25 m): same 2 m past the midpoint. No trap.
  - Where it becomes a trap: two parallel lines separated by S <= H (about 3.9-4.0 m) can never displace the incumbent, even with the pin standing ON the challenger line (needs `d_chal < d_inc - H`, i.e. `0 < S - H`). At 8 pt that threshold was 2.2 m. At 6 m separation the pin must be within 1 m of the challenger. Perpendicular corner pairs are not trapped (moving along the challenger curb grows the incumbent distance). Worth a Mac-gate check on a divided avenue / any block with a closely paired same-direction curb; release is always possible by panning >30 m (drops the incumbent).
  - UX note for the Mac gate: with H = 3.92 there is a ~+/-2 m band (about 14 pt at entry zoom, a third of a 12 m street) where the snapped curb is not the nearer one; the settle nudge will then pull the map to the incumbent's foot point up to ~8 m (28 pt) away. Intended by the dead-band, but it is the "parked on the wrong side" risk to watch, mitigated only by the tether and highlight (A2) being unmistakable. Design doc §Open ideas already floats a loupe if it "feels sticky".

### 💡 Out of scope (logged, not fixed)

- **#8: nearest-curb chip (design doc rows 122/179/233, spec A.3 "No curb in range") — no real API gap, but the recipe must be written down.** `nearestMeters: Double?` alone cannot support the chip (needs bearing, a tap target, and range 100 m; the 3x3 gives guaranteed <= 32 m and best-effort ~64 m). However the engine already supports the probe: call `resolve(pin, incumbent: nil, metersPerPoint:, config: CurbSnapConfig(acquireRadius: 100, releaseRadius: 100))` once on settle. That scans a 9x9 block (ring 4, covers >= 128 m), returns `.snapped(result)` with `snappedCoordinate` (the tap target, from which A3 computes bearing minus camera heading) and `distanceMeters`, and costs 81 cell lookups on a rare event. Requires #2's test and a sentence in A3's brief. The file header's "a wider probe is a follow-up" is therefore pessimistic. A3 should not try to reuse `nearestMeters` for the chip.
- **#9: corrupt-vertex divergence.** The index drops non-finite / >200 km vertices and breaks the chain, but the winner's foot point is computed over all of `segment.coordinates` (`resolve` line 464). For clean data these are identical; for a polyline with one corrupt far vertex the index may not see an edge that the foot-point math still considers. Tile data is build-validated; ignore unless the pipeline starts emitting garbage.
- **#10: `running += count` is `Int32`** (`init`, line 323). Overflows only past ~2.1 billion bucket entries; with the 200 km / 256 m caps a handful of corrupt long edges cannot reach it. Noted for completeness.

## Analysis detail (requested checks)

**1. Grid / correctness.**
- Cell math: `floor(v / 32)` via `.rounded(.down)` (not C-style truncation), so negative coordinates are right (x=-0.0001 -> cell -1; an edge at exactly x=-32 lands in cell -1 and the neighbouring cell -2 query still scans it). Edges register in every cell of their (conservative) bbox, inclusive at both ends, so an edge touching a boundary registers on both sides.
- Cell key `(Int64(cx) << 32) | (Int64(cy) & 0xFFFF_FFFF)` is injective for |cx|,|cy| < 2^31 including negatives.
- 3x3 sufficiency vs 30 m: the pin is inside its cell, so the 3x3 block extends >= 32 m past the pin in every direction (the minimum is when the pin is on a cell EDGE, exactly 32 m; at a corner or interior it is more). Any point within 30 m of the pin is therefore inside the block, and any edge containing such a point is registered in that point's cell. The brief's worry (corner pin has "0-32 m") is inverted: the pin's distance to the *outside* of the block is 32 m + its offset in the cell. 30 < 32 holds for the default config, and `ring` widens automatically if `max(acquire, release) > 32`. Python port confirmed: 0 misses.
- Long diagonal: the 707 m test diagonal splits into 3 collinear pieces (<= 256 m, joints bit-identical because piece k's end uses the same `t1` expression as piece k+1's start, the last piece ends at the exact endpoint); each piece bbox-registers conservatively.
- Duplicate registration: a diagonal edge appears in several scanned cells and is evaluated repeatedly; harmless because `isBetter` returns false for self-comparison.
- Position fraction: computed only for the winner by the repo's own `nearestPointOnPolyline` (cumulative haversine, clamped 0-1), so it is the same convention as `pins.position_fraction` by construction. The multi-vertex test compares against the helper at 1e-12 and against a hand value (130/150).

**2. Hysteresis semantics.** Traced with curbs at y=+/-6 (12 m side street), incumbent S: pin 1 m toward N -> dN=5, dS=7, 5 < 7-3.92 false, stays; 1.96 m -> exact equality, strict `<` keeps S; 2.0 m flips. Centre and 1 m toward S: stays. With no incumbent: the nearest wins, exact tie -> key order. Reverse sweep is symmetric, so total band = H. Acquire gating (`otherD <= acquireRadius`) is applied before the H test, so a challenger in the 24-30 band can never take over; incumbent in 24-30 band with nothing else is retained; incumbent > 30 is dropped and the normal acquire path runs (lines 439-453). Incumbent distance is the minimum over all copies of its blockface.

**3. Seam fidelity.**
- Explicit all-defaulted `init`: correct call. A `let x = default` stored property is excluded from the synthesized memberwise init, so the contract sketch literally could not be customised. `CurbSnapConfig()` and `.standard` behave identically to the sketch; argument order matches the sketch's field order. No memberwise-order hazard (no memberwise use anywhere).
- Type-level `nonisolated`: no repo precedent (grep confirms), but I judge it the safer choice here. The precedent (`ParkingGoals`, `FinalApproachService`) is per-member `nonisolated static`, which cannot cover synthesized members: the derived `Equatable ==` on `CurbSnapConfig` / `CurbSnapOutcome`, the memberwise/stored-property inits, and instance members of a class. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` those would be MainActor-isolated and fail from sync, non-`@MainActor` XCTests (compile class 5). SE-0449 needs Swift >= 6.1; the project setting itself requires Xcode 26 / Swift 6.2, so the toolchain constraint is already met. `private nonisolated struct Edge` is redundant but legal. Residual risk is "first compile on a Mac", not design. `Segment` member access from the nonisolated init/resolve (`.line`, `.blockfaceKey`, `.id`, `.coordinates`) matches the existing `nearestSegmentSnap` precedent, and `FT15ModelTests` already reads `blockfaceKey` from non-`@MainActor` sync tests.
- `@unchecked Sendable`: justified. Seven `let` stored properties (value-type collections), no lazy/mutating state, no class references except through value copies.
- `CurbSnapResult`/`Outcome` `Equatable`: hand-written, exact numbers, id for the segment (see #4). `blockfaceKey` convenience is a good seam addition.

**4. Robustness additions.** Edge splitting >256 m: `ceil(length/256)` pieces, collinear and gap-free (distance-neutral). Non-finite / >200 km vertices: dropped and chain broken; the origin is (40.7128, -74.0060), and the farthest NYC extents are ~20-25 km (Tottenville ~(23.7 km N-S, 20.6 km E-W); Bronx north, Far Rockaway similar), a 8-10x margin, so no legitimate geometry is dropped. Query reject >1,000 km before `Int(floor)`: tested with (-80, 170). Zero-length edge: `invLenSq = 0` -> t=0, no NaN; tested. Malformed-pair handling mirrors `Segment.coordinates`; tested.

**5. Threading / perf.** Immutable after init; hot scan uses ranges, dictionary lookups and a 48-byte struct copy, no heap allocation (see #6). Brute-force oracle is independent: it uses the repo's `nearestPointOnPolyline` per segment, grouped by `blockfaceKey`, no grid, and skips only near-ties (<0.3 m) and acquire-boundary points; it asserts both branches (>20 snapped, >20 no-curb, >200 compared). It does not cover incumbent paths (those are covered by the hysteresis tests).

**6. Compile-class static scan (all four files).** Literal-receiver: none unannotated (`(0...steps).map { (i: Int) -> ... }`, explicit `[(Double, Double)]` types). Labeled-arg order: `Edge(...)` init, `CurbSnapResult(...)`, `Segment(id:street:fromStreet:to:side:line:rules:dominantCategory:)`, fixture helpers, `isBetter(_:_:than:_:)` and `nextDouble(in:_:)` call sites all match declarations. Memberwise order: `CurbSnapResult` and `Edge` call sites match field order. XCTest helper shadowing: no `extension XCTestCase`; file-scope helpers are `private` (`csi*`, `csp*`); the only internal names are `CurbSnapTestFixtures` and `CurbSnapTestRNG`, with no repo-wide duplicate; the seven new XCTestCase class names are unique (existing `CurbSnapDisplayTests.swift` classes are `CoordinateAtFractionTests` etc.). `nonisolated`: covered above; the test target has no `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so fixtures are nonisolated. Bare `Category`: none (only `dominantCategory: nil`). No `Calendar.current`, no dates, no `import SwiftUI` in the service. Synchronized groups: `WePark` and `WeParkTests` are `PBXFileSystemSynchronizedRootGroup`, there are no exception sets, and `ParkingGoals.swift` / `GoalSelectorView.swift` are likewise absent from `project.pbxproj`, so the claim (no pbxproj change) holds and the diff touches only the four files.

**7. Tests are real.** Counts verified: 35 (`CurbSnapIndexTests`) + 6 (`CurbSnapIndexPerformanceTests`) = 41. Assertions are on values, not just "doesn't crash"; fixtures author geometry in local metres with duplicated (not imported) projection constants, so they do not depend on the engine's private numbers. Perf tests assert correctness inside the timed loops.

## Smoke tests run

- Static read of all four files against the spec; compared signatures against §A.9 seam sketch (match, with the documented additions).
- Independent Python port of the registration + 3x3 query vs brute force: 90,000 queries (random + boundary-aligned edges/pins, negatives, lengths to 256 m): 0 misses within 30 m; ring-4 probe 100 m: 0 misses in 20,000 queries; corner/edge worst-case 30 m placement: pass.
- Hand-trace of hysteresis numbers for 8 pt and 14 pt (above).
- Repo-wide greps: nonisolated type-level precedent (none), helper-name and class-name collisions (none), pbxproj synchronization.
- NOT run: `xcodebuild` (no toolchain on this host), the 41 tests, perf `measure {}`, any live-UI smoke (not applicable: no mount-chain files touched).

## What's working

- Core design is sound and clearly reasoned: build-once CSR grid, distance-only kernel, winner-only expensive math reusing the shipped helper, group-based dedup that falls out naturally, deterministic tie-break that never reads input order.
- Robustness thinking beyond the spec (edge splitting, bounded extents, query reject, NaN scale handling) with no collateral damage to NYC geometry.
- The test suite is unusually thorough for blind-build code: independent oracle, boundary sweeps in both axes, round-trip hysteresis with measured flip points, and a non-trivial dedup-vs-incumbent test.
- The builder surfaced its own deviation (#5) and the explicit-init rationale; both are accurate.

## Required before merge

1. Fix-round: `hysteresisPoints` default 14 plus the test edits in #1; add the widened-scan / custom-config tests (#2); optionally #3, #4.
2. Mac gate (hard): `xcodebuild build` + the 41 tests (first compile of type-level `nonisolated`), Release-config perf numbers vs the A.6 targets (A6), recorded in the PR.
