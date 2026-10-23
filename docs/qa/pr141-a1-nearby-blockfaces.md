# PR #141 (A1 `nearbyBlockfaces`) QA Pass 1 — 2026-10-23

**Reviewed:** branch `feat/a1-nearby-blockfaces` at `2cd99153` (base `9b8ba089` = current `origin/main`, no drift), against `docs/design/curb-pin-placement-design.md` (blocker #2) and the PR #137 engine contract
**Verdict:** ✅ MERGE (code-wise). The refactor of `resolve` is behavior-identical. The Mac compile + test run and a Release perf re-measure remain hard gates (no Swift toolchain on this host; static review plus an independent Python port only; nothing in Swift was executed).

## Summary

The three private helpers (`projectedQuery`, `scanRing(forRadius:)`, `forEachCandidateEdge`) are a pure move of the old inline code: same expressions, same iteration order, same arguments. A Python port of the OLD inline `resolve` core and the NEW helper-based core agreed on 90,000 randomized queries with 0 mismatches. `nearbyBlockfaces` is correct against a brute-force oracle (see below). No existing test is touched (the diff is two files: the service and one new test file), and no `MapViewRepresentable.swift` overlap with PR #140. Live-UI smoke does not apply (no mount-chain file changed). Zero blocking or significant findings; three minor notes.

## Acceptance criteria checklist

- [x] **`resolve` behavior-identical after refactor** — hunk-by-hunk diff plus Python old-vs-new equivalence, 90,000 queries, 0 mismatches. Details in "Refactor proof".
- [x] **Existing 42 CurbSnap tests unmodified** — `git diff main...HEAD --name-only` = `CurbSnapIndex.swift` + new `CurbSnapNearbyBlockfacesTests.swift` only. `CurbSnapIndexTests.swift` has an empty diff. (Logically still pass: `resolve` is unchanged per the port.)
- [x] **Closure risk (escaping / exclusivity / Sendable / allocation)** — safe; see "Closure analysis".
- [x] **One entry per `blockfaceKey` at the nearest point, dedup across tiles and multi-edge polylines** — per-group best edge in a dictionary keyed by group id; port: 0 duplicate groups over 90,000; nearest-copy chosen with `isBetter` (d2, then group key, then segment id). Test 2 covers two-tile case, test 9 the synthetic grid (4-vertex polylines crossing cells).
- [x] **Ascending distance, same tie-break as `resolve`** — sort key `(distanceSquared, groupKeys[group])`; group keys unique so the order is total. Test 7 (100 shuffles, exact tie) is real: identical geometry on N/S sides gives bit-identical d2.
- [x] **Radius inclusive; NaN / negative / -inf / empty index / off-map -> empty; huge / +inf clamp to the 17x17 cap** — traced: guard `!radius.isNaN, radius >= 0`; `projectedQuery` nil for non-finite or >1,000 km; `scanRing` clamps in Double before `Int(...)`. Tests 3, 4, 8.
- [x] **Element 0 equals `resolve` winner (incumbent nil, radius >= acquire)** — port: 90,000 queries, `resolve(acq=rel=R, incumbent nil)` vs `nearby(R)[0]`: 0 mismatches, and empty/non-empty agreement exact. See finding #2 on the test's independence.
- [x] **Doc comment warns not to re-sort; documents best-effort beyond ~256 m** — both present in the `nearbyBlockfaces` header comment.
- [x] **Tests: 9 real, fixtures reused, `cnb` prefix, tolerances >= 0.15 m** — checked below.
- [x] **Six-class compile scan** — clean (below). Not compiled.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None.

### 🟢 Minor / nit

- **#1: Release perf must be re-recorded because the hot loop changed shape.**
  - Where: `CurbSnapIndex.swift` `resolve` (closure call replaces the inline innermost loop body).
  - What: `@inline(__always)` plus a non-escaping closure normally specializes to the old code in Release, but that is a compiler promise, not a source guarantee, and Debug will pay an indirect call per candidate edge. PR #137's A6 numbers (30 Hz sweep, 1,000-query measure) were taken or owed against the inline version.
  - Expected: the Mac gate's Release `measure {}` for `CurbSnapIndexPerformanceTests` should be compared with the pre-refactor figure (or with PR #137's recorded one). Not a defect; "behavior-preserving" is proven, "performance-preserving" is not.
  - Owner: `@ios-engineer` (Mac gate).

- **#2: Test 6 shares the grid scan with `resolve`, so it validates the bookkeeping, not the scan.**
  - Where: `CurbSnapNearbyBlockfacesTests.testNearby_consistentWithResolve_...`.
  - What: both functions now call the same `forEachCandidateEdge`, so a scan bug would pass this test. It is still not tautological: `resolve` tracks incumbent/other bests and `nearbyBlockfaces` tracks a per-group dictionary then a sort, and the test asserts winner key, segment id, fraction (1e-9) and distance on 300 pins with both branches exercised (>20 snapped, >20 empty; expected about 190 / 110). The scan itself stays covered by the unmodified brute-force oracle in `CurbSnapIndexTests`, plus test 9 here (sorted, no duplicate keys, within radius). Acceptable as is.
  - Doc nuance: the `nearbyBlockfaces` comment says that with `radius >= acquireRadius` element 0 is "exactly the blockface `resolve` acquires". True when `resolve` acquires; with a radius larger than acquire, `nearbyBlockfaces` can return a curb in the 24..radius band where `resolve` says `.noCurbInRange`. Worth one clause when A2 wires the VoiceOver element (use `radius == acquireRadius` if the list must agree with the pin's snapped state). Owner: `@ios-engineer`.

- **#3: `distanceMeters` can exceed `radius` by ~0.1%.** The radius filter is the flat-earth distance (matches `resolve`), the reported value is haversine. A consumer that re-filters on `distanceMeters <= radius` could drop an entry the list just returned. The comment covers re-sorting but not re-filtering; add four words. Test 9 correctly allows +0.15. Owner: `@ios-engineer`.

### 💡 Out of scope (logged, not fixed)

- **#4: Unbounded radius on a dense block is a big list.** `radius: .infinity` returns everything in the 17x17 block (544 m square) and runs `nearestPointOnPolyline` (allocating) per entry. A2 should pass a bounded radius (the acquire radius or similar), not infinity. Documented as a gesture-time call, so fine.
- **#5: Pre-existing 1e-13 m registration boundary.** My port found 1 case in 90,000 where `nearbyBlockfaces` missed a blockface at exactly `radius == ring x 32 m` (pin at x=64.000000001, y=128, radius 64, an aligned edge whose bbox top is recomputed as `ax + dx`, a float ulp under the true endpoint, so it registers one cell short). It is a property of the PR #137 registration (`resolve` shares it), needs an edge exactly on a cell line and the query exactly at the guaranteed reach; irrelevant at real coordinates.
- **#6: PR #137 carry-forward items** (corrupt-vertex divergence, `Int32` running count, 14 pt trap analysis) are unchanged.

## Refactor proof (item 1)

Hunk by hunk (old inline -> new helper), `resolve`:

| Piece | Old | New | Same? |
|---|---|---|---|
| Query projection and reject | `project`, guard `isFinite` x2, `abs(px/py) <= maxQueryExtentMeters`, else `.noCurbInRange(nil)` | `projectedQuery(p)` has the same guard, returns `(x, y)?`; caller returns `.noCurbInRange(nil)` on nil | yes (same expressions, same order after the `edges.isEmpty` guard) |
| Ring | `ringRaw = (max(acq,rel)/cell).rounded(.up)`; `ringRaw.isNaN ? 1 : Int(min(8, max(1, ringRaw)))` | `scanRing(forRadius: max(acq, rel))`, body verbatim | yes: NaN -> 1, +inf -> 8, -inf/neg -> 1, 1e300 -> 8 (no trap) |
| Pin cell | `Int((px/cell).rounded(.down))` before the ring math | same expressions at top of `forEachCandidateEdge` | yes (px/py bounded to 1e6 so `Int` safe) |
| Cell walk | `cy` outer, `cx` inner, `cellSlots` lookup, `cellStarts` range, `k` loop | identical loops; `body(Int(cellEdgeIndices[k]))` then `k += 1` (old: read, `k += 1`, then process; the sequence of edge indices visited is identical) | yes |
| Candidate ranking | `edges[edgeIndex]`, `distanceSquared`, `edge.group == incumbentGroup` -> `isBetter(...)` on incumbent best else other best | closure body is the same statements | yes |
| Tie-break / `isBetter` | unchanged function | unchanged | yes |
| Hysteresis, incumbent, acquire / release radii, finalisation | lines after the scan | untouched (diff shows no change below the loop) | yes |

Independent check: Python port of the OLD inline `resolve` core and the NEW helper/closure core (shared registration, ties on blockface key then segment id, configs: default, 100/100, 50/40, 10/12 with custom dead-band, 24/30; incumbents none / real / unknown; mpp 0.05 to 1.0; random indices of 3-60 segments with repeated blockface keys, edges up to 300 m long, vertices and pins snapped to cell boundaries, negative coordinates, pins at cell boundaries +/-1e-9). **90,000 queries, 0 mismatches** on (chosen edge, nearest distance). Script is in the session scratchpad; the port mirrors, but does not execute, the Swift.

`nearbyBlockfaces` vs a brute-force per-group oracle (no grid) at radii 0, 0.01, 5, 24, 30, 31.9, 40, 64, 100, 200, 255 (all within guaranteed reach): 90,000 queries, 1 mismatch (finding #5, a 1e-13 m boundary artefact shared with `resolve`), 0 duplicate groups. Element 0 vs `resolve` (acq = rel = R, no incumbent): 90,000 queries, 0 mismatches.

## Closure analysis (item 2)

- **Escaping:** the parameter is `_ body: (Int) -> Void`, non-escaping by default. Implicit `self` (`edges`, `isBetter`) inside a non-escaping closure is legal, so no explicit `self.` is required. No compile error.
- **Exclusivity:** the helper never touches `incumbentD2/Edge`, `otherD2/Edge` or `bestPerGroup`; the closure is the only accessor. No inout passing, no overlapping access. Inside `nearbyBlockfaces` the `if let current = bestPerGroup[...]` copies out before the assignment, so no read/write overlap. `edges` and the grid arrays are `let`.
- **Sendable:** `@unchecked Sendable` class, unchanged stored properties (still immutable `let`s); the closure is non-escaping and never crosses an isolation boundary. `NearbyCandidate` is a private `nonisolated` struct of three value fields. No new concurrency surface.
- **Hot-path allocation:** non-escaping closure contexts and their captured `var`s live on the stack (no box); `@inline(__always)` further specializes it. No `Array(...)`, no dictionary, no `NearbyCandidate` in `resolve`. The 30 Hz path allocation profile is unchanged. (Finding #1 is about speed, not allocation.) Not verified by running; static.
- `nearbyBlockfaces` itself allocates (dictionary, array, per-entry `nearestPointOnPolyline`) and says so; it is a gesture API, not display-link.

## Tests (item 4)

All 9 are real, with value assertions. Hand-traced against the fixtures: 1 (5.5/9.5 m and mirror order), 2 (two-tile blockface; swapped from/to gives the same key; nearer copy `NB-T1` represents it), 3 (15 m curb, 15.5 vs 14.5; second pair across a 32 m cell edge, 23 m vs 23.5/22.5), 4 (empty, out of range, 0 and negative radius, pin on curb at 0.01, off-map -80/170 rejected), 5 (80 m curb found only by the widened ring, 24 m radius excludes it; haversine error at 80 m about 0.09 inside the 0.15 tolerance), 6 (see #2), 7 (N/S exact tie, far curb last because distance orders before key), 8 (1e300, greatestFiniteMagnitude, +inf, NaN, -inf, NaN/inf coordinates), 9 (100 random pins/radii, ascending within 0.15, no duplicate keys, within radius+0.15, >20 multi-entry cases; the `1..<max(count, 1)` loop is safe for 0/1 entries). Fixture reuse is correct: `eastWestCurb` / `key` / `syntheticGrid` / `shuffled` / `CurbSnapTestRNG.nextDouble(in:_:)` are called with the declared argument order (defaulted `street` skipped legally). Helpers are file-private with the `cnb` prefix; repo-wide grep finds no `cnb*` elsewhere and no collision of the class name. Tolerances: 0.15 everywhere flat-earth vs haversine matters.

## Compile-failure-class scan (item 5)

1. Literal-receiver contextual types: none unannotated; closures in the service are explicitly typed. Clean.
2. Labeled-arg order: `forEachCandidateEdge(x:y:ring:)` and `NearbyCandidate(group:edge:distanceSquared:)` match declarations; `CurbSnapResult(segment:positionFraction:distanceMeters:snappedCoordinate:)` unchanged; fixture calls match.
3. Memberwise-init order: `NearbyCandidate` call sites are in declaration order.
4. XCTest helper shadowing: no `extension XCTestCase`; all helpers `private` with `cnb`.
5. Type-level `nonisolated` plus closures: closures are non-escaping, nonisolated by context, capture only locals and nonisolated-class members; no `@Sendable` requirement; no `==` on nested enums (`edge.group == incumbentGroup` compares `Int32`).
6. Bare `Category`: none. No `Calendar.current`, no SwiftUI import (`Foundation` + `CoreLocation` only). Files touched: exactly two; zero overlap with `MapViewRepresentable.swift` (PR #140); no pbxproj change needed (synchronized groups).

## Smoke tests run

- `git fetch` + checkout of the PR head, `git diff main...HEAD` read in full; `main` equals the branch base so there is no drift.
- Python equivalence harness (above): 90,000 old-vs-new `resolve`; 90,000 `nearbyBlockfaces` vs oracle; 90,000 element-0 vs `resolve`.
- Hand-traces of all 9 new tests against the fixture geometry.
- NOT run: `xcodebuild` / the tests / `measure {}` (no toolchain). Live-UI smoke not applicable (no mount-chain, overlay, or `.safeAreaInset` file in the diff).

## What's working

- The refactor was done the careful way: the helpers are small, the hot-loop statement order is preserved, and the closure explicitly typed for the type checker.
- `nearbyBlockfaces` reuses `isBetter` and the same ring clamp, which is exactly why element 0 agrees with `resolve` and why the tie order is deterministic without a second source of truth.
- The doc comment is candid about allocation, the 256 m best-effort cap, and the haversine / flat-earth ordering caveat.

## Required before merge

1. Mac gate: `xcodebuild build` + the full CurbSnap suite (42 + 6 perf + 9 new, first compile of the shared helpers), and re-record Release perf vs PR #137's numbers (finding #1).
2. Optional doc touch-ups (#2 nuance, #3).
