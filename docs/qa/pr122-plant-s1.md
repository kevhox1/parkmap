# PR #122 QA Pass 1 — Plant model S1: "Park my car" chooser-tile plumbing

**Reviewed:** branch `ios/plant-s1-park-tile` at `5b614dfb`, against `docs/longpress-universal-plant-spec.md` (§3.1, §3.5, §4 Stream 1, OD-5, OD-6), PR #122 body/ambiguity note.
**Verdict:** MERGE-PENDING-MAC-GATE

## Summary
This is exactly what it claims to be: pure additive enum/routing/gating plumbing in `ReportSheet.swift`, with `ContentView.swift` at zero diff from `main`. I traced every path by which the new code could become reachable in production (the grid renderer, the tap handler's switch, the single `ReportSheet(...)` call site, the new closure/flag's defaults) and confirmed all of them leave the new `.parkMyCar` machinery fully inert. Test count and routing-gating logic both check out against the spec. No static-review blockers. Only gate remaining is the Mac compile/test pass, which rides on good-faith trust of a toolchain this agent cannot run.

## Acceptance criteria checklist (Stage 1 scope only — AC-1/2/9/16 etc. are explicitly out of scope per PR body, correctly deferred to Stage 2)

- [x] `ContentView.swift` byte-identical to `main` — verified via `git diff origin/main...origin/ios/plant-s1-park-tile --stat` (2 files touched: `ReportSheet.swift`, new test file; zero mention of `ContentView.swift`).
- [x] `.parkMyCar` / `.parkMyCarHandoff` added as additive enum cases, `Equatable`-safe, no associated-value ambiguity with existing cases — verified by reading the full enum definitions and the structural-regression test (`testDestination_parkMyCarHandoff_neverEqualsAnySelectTypeOrOtherHandoff`).
- [x] `destination(forTapping:communityEnabled:candidates:)` routes `.parkMyCar` → `.parkMyCarHandoff` **unconditionally**, ignoring `communityEnabled` entirely for that arm — verified by reading the switch body directly (`case .parkMyCar: return .parkMyCarHandoff`, no guard).
- [x] `handleGridTileTap`'s new `.parkMyCarHandoff` arm calls `onRequestParkMyCar?()` only — no duplicated park-write logic, no second code path to the W5 park flow.
- [x] `visibleGridTiles(showsParkMyCarTile:communityEnabled:)` — flag-off (`showsParkMyCarTile: false`) collapses to existing 4-tile/empty behavior; `showsParkMyCarTile: true, communityEnabled: false` → exactly `[.parkMyCar]` (OD-5 collapse); `showsParkMyCarTile: true, communityEnabled: true` → 5-tile peer set with Park first. All three verified by reading the function body against its 5 dedicated tests — none are vacuous (each asserts the full array contents + a count, not just non-emptiness).
- [x] New init params (`onRequestParkMyCar: (() -> Void)? = nil`, `showsParkMyCarTile: Bool = false`) are additive defaults; the one production call site (`ContentView.swift:1473`) passes neither — confirmed by reading that call site directly.
- [x] `visibleGridTiles` and `.parkMyCar` are **not consumed anywhere** in `reportGridSection`/`body` — confirmed: `reportGridSection` is a hardcoded 4-`reportGridCard` `LazyVGrid`, with zero reference to the new enum case or the new static function. There is no code path by which `.parkMyCar` can be tapped in the shipped app (nothing renders it).
- [x] Closure-injection ambiguity resolution (closures instead of calling the private `confirmLongPressPark(at:)` directly) is sound: matches the existing `onRequestStreetClosure`/`onRequestSpotPlacement` convention exactly, is documented as Stage 2's wiring job, and — critically — is never invoked by anything today (`onRequestParkMyCar` stays `nil` in production, so even if someone mis-wired it, it's a no-op `nil?()` call, not a crash or dangling reference).
- [x] Test count: `main` = 1449 `func test` (counted directly, not trusted from PR body), branch = 1457 (+8) — matches PR claim exactly.
- [x] `AppConstants.communityEnabled`/`regularsEnabled` untouched — zero diff to `AppConstants.swift`.
- [x] No Supabase/schema changes — full diff is `ReportSheet.swift` + one new test file only.
- [x] No banned copy (avoid/ticket/fine/evasion/dodge) — grepped the full diff, none found (consistent with "no new copy renders yet").
- [x] No switch-statement exhaustiveness breakage elsewhere — grepped the whole repo for `ReportGridTile`/`ReportGridDestination` usage; only two files reference them (`ReportSheet.swift` itself, `ReportSheetPhase2aTests.swift`), and the test file contains no exhaustive switches over either enum, only `destination(forTapping:)`'s own switch and `handleGridTileTap`'s switch (both already updated in this diff with the new case). `isGridTileSelected` uses `if case .type(let type) = tile`, not an exhaustive switch, so it compiles unaffected by the new case.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None.

### 🟢 Minor / nit
- **#1: `visibleGridTiles` is genuinely dead code as of this PR** — not a defect (the PR body says this explicitly and it's the correct staging per OD-6), just noting for Stage 2's reviewer: when Stage 2 wires this into `reportGridSection`, confirm the wiring actually iterates `visibleGridTiles(...)` output rather than re-deriving a parallel hardcoded list, or this function's 5 tests will assert a contract nothing enforces at runtime.
- **#2: `reportGridSection`'s hardcoded 4-tile list doesn't itself consult `communityEnabled`** (pre-existing, not introduced by this PR — the flag gating for the 4-tile grid lives at the call site / sheet-presentation level, not inside `reportGridSection`). Confirmed this is unchanged by the diff, just flagging that Stage 2's rewrite of `reportGridSection` to consume `visibleGridTiles` will need to carry that existing gating knowledge forward correctly, not lose it in the refactor.

### 💡 Out of scope (logged, not fixed)
- AC-1 through AC-16 (entry-point rewiring, tentative marker, live dismiss-and-redo, Mac-gate GPS-vs-long-press proof) are all Stage 2 and correctly not attempted here.
- OD-4 (Spot-open one-tap-when-placed) correctly flagged by the PR author as a separate stream, not snuck into this diff — confirmed by grep: no `SpotPlacementView`/`.spotPlacementHandoff` behavior changed in this diff.

## Smoke tests run
- `git diff origin/main...origin/ios/plant-s1-park-tile --stat` — confirmed exactly 2 files changed, `ContentView.swift` absent. **This is the load-bearing check for the inertness claim and it passes cleanly.**
- Read the full diff to `ReportSheet.swift` (88 insertions/2 deletions) line by line.
- Read `handleGridTileTap`'s full switch body (new `.parkMyCarHandoff` arm calls `onRequestParkMyCar?()` only).
- Read `reportGridSection` and `reportGridCard` in full — confirmed hardcoded 4-tile grid, zero reference to `.parkMyCar` or `visibleGridTiles`.
- Read the single `ReportSheet(...)` construction site in `ContentView.swift` (line 1473) — confirmed neither new param is passed.
- Extracted `WeParkTests` from both `main` and the branch via `git archive` and counted `func test` occurrences directly: 1449 → 1457 (not trusted from the PR description).
- Read the full new test file (`ReportSheetPlantModelS1Tests.swift`, 8 tests) — confirmed each of the 5 `visibleGridTiles` tests asserts full array equality (not just presence/absence), and the 3 routing tests cover flag-on, flag-off (asserting it's reachable unlike the other two hand-offs), and cross-case non-equality.
- Grepped the full diff for banned copy strings (avoid/ticket/fine/evasion/dodge) — none found.
- Grepped `AppConstants.swift` diff (none) and the whole diff for `supabase`/`Supabase` (none).
- Grepped the whole repo for other `ReportGridTile`/`ReportGridDestination` consumers to rule out exhaustiveness-switch compile breaks elsewhere — only the two files already reviewed reference these types.
- **No live-UI smoke performed and none is required.** This PR does not touch `MapViewRepresentable.swift`, `ContentView.swift`, any `Views/DriveMode*.swift`, or any `.safeAreaInset`/overlay-attachment code, and renders zero new UI (confirmed above: `.parkMyCar` is never added to any `LazyVGrid`). The merge-blocking live-smoke rule in `HANDOFF.md` does not apply to this PR class — this is a correct call by the PR author, and I independently verified the premise (nothing renders) rather than taking the PR's word for it.
- **Not run (no Swift toolchain in this sandbox):** `xcodebuild build`, `xcodebuild test`. This is the one gate I cannot close myself. The PR is honestly labeled `[COMPILE-UNVERIFIED]`.

## What's working
- The staging discipline (OD-6) is followed faithfully — this really is a 0.5-session, low-risk, fully-bisectable slice, and the diff size (88 lines in one file + a self-contained test file) matches that claim.
- The ambiguity call (closure injection instead of touching a private `ContentView` method) is the right engineering judgment: it follows an established pattern in the same file (`onRequestStreetClosure`/`onRequestSpotPlacement`) rather than inventing a new mechanism, and the PR body flags the interpretation explicitly instead of silently deciding it — exactly the kind of ambiguity disclosure this process wants.
- Doc comments throughout the diff are unusually conscientious about stating "not yet reachable in production" at every single new symbol, which made this inertness audit fast and high-confidence rather than something I had to reconstruct myself.
- The 8 new tests are not vacuous — each of the 4 gating-matrix cells from spec §3.5 has a dedicated test asserting full contents, and the OD-5 collapse case gets both a contents assertion and an explicit `count == 1` assertion.
- Test-count claim (1449→1457) was independently re-derived, not taken on faith, and matched exactly.

## Mac gate note
No live-UI smoke required for this PR (justified above — nothing renders, no mount-chain files touched). The only remaining gate is a plain compile + test run:
- `xcodebuild -project ios/WePark.xcodeproj -scheme WePark -destination 'platform=iOS Simulator,name=iPhone 15' build`
- `xcodebuild test` — expect **1457/1457**, up from the 1449 baseline on `main` (independently reconfirmed above, not just trusted from the PR body).
This can ride along with another PR's Mac-gate session rather than needing its own dedicated pass — there is nothing for a human to look at on screen.
