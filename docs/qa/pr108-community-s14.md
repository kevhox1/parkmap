# Community 2.0 S14 (Zone Fetch-at-Launch) QA Pass 1 — 2026-09-13

**Reviewed:** PR #108, branch `ios/community-s14` at `4ca72da` (base `main` @ `c2b38a0d`), against
`docs/community-2.0-s14-execution-spec.md`.
**Method:** static/code review only — no Xcode/Swift toolchain in this environment. Full diff read
line-by-line; no live build, no simulator run.
**Verdict: APPROVE-WITH-FINDINGS.** Nothing here blocks merge. One 🟡 finding (the "byte-identical"
chip-order claim) should be corrected in the PR description/spec language before Kevin's Mac gate,
and Kevin's gate script should add one order-check step the spec's own ceremony omits. Everything
load-bearing — the unconditional fetch, empty-store tolerance, wire shape, deletion completeness,
zone-id migration semantics — checks out against the spec exactly as written.

## Highest-priority verifications

1. **Unconditional-fetch rule — PASS.** `ContentView.performLaunchSetup()` calls
   `Task { await zoneStore.loadZonesIfNeeded() }` at `ContentView.swift:3577`, outside any
   `AppConstants.communityEnabled` check (confirmed by grepping every `communityEnabled` occurrence
   in the file — the fetch line is not nested inside any of them). `ZoneStore()` itself is
   constructed once in `ContentView.init` (line ~879) and threaded into `CommunityPinService`'s new
   `zoneStore:` param, so the pin-service and the ContentView-level consumers share one instance.
   Flag-off write path (`CommunityPinService.resolveZoneId` → `insertCrowdPin`) reads
   `zoneStore.zones` directly and is never gated on the flag — traced end to end, this is correct
   and matches the spec's own load-bearing warning verbatim.

2. **Behavioral parity with deleted constants — PASS.** The retired
   `CommunityZoneBounds.boxes` values (nolita/soho/les, including the QA-corrected `soho` lat_max
   40.7237) are reproduced verbatim as test fixtures in all five touched test files
   (`CommunityZoneStampingTests.swift`, `CrewFeedSectionTests.swift`, `CommunityS13aTests.swift`,
   `BlockDetailS13bTests.swift`, `CommunityPhase3TrustLoopTests.swift`) — spot-checked all five,
   byte-identical lat/lng to the deleted file. Containment is `>=`/`<=` inclusive in both
   `Zone.contains(lat:lng:)` and the old `CommunityZoneBounds.zoneId` — identical semantics.
   Ordering/tie-break: old code did `boxes.first { ... }` (first-match, since the seed's 3 boxes
   never overlapped, first-match and smallest-match were indistinguishable); new
   `ZoneGeometry.zoneId` explicitly does `.min { $0.areaApprox < $1.areaApprox }` (smallest-match).
   At 3 non-overlapping zones these are provably equivalent (only one match exists); the smallest-
   wins rule only becomes observable at 41 zones with documented overlaps — correctly called out in
   both the spec and the code comments as "never mattered at 3, load-bearing at 41." No boundary or
   ordering regression for the current prod table.

3. **Empty-store tolerance — PASS, all 9 consumers walked individually:**
   - `ContentView.resolveHomeZoneId` / `updatePushZoneFromParkedCarOrLocation`: `ZoneGeometry.zoneId`
     over an empty array → `.filter{}.min{}` → `nil`. No crash.
   - `CommunityPinService.resolveZoneId` → `insertCrowdPin`: `if let resolvedZoneId` guard omits the
     `zone_id` key from the POST payload entirely on `nil` (`CommunityPinService.swift:1603`) —
     confirmed by reading the payload-building block directly, not inferred.
   - `CommunityPinService.buildLeaderboardRequest`: `guard let box = ZoneGeometry.box(...) else {
     return nil }` → `fetchLeaderboardPins` treats a `nil` request as `return []`, never throws.
   - `CrewFeedMerge.resolvedZoneId(for:zones:)`: empty `zones` → `zones.contains(where:)` is
     `false` → falls through to `ZoneGeometry.zoneId` on empty → `nil`.
   - `MapViewRepresentable.Coordinator.syncZoneBoundaries`: `homeZone: Zone?` is resolved to `nil`
     by `ContentView` when `zoneStore.zones` is empty (`.first { $0.id == id }` on `[]`) → the
     `guard enabled, let homeZone else { ...remove... return }` path renders nothing.
   - `BlockDetailView`/`BlockDetailLogic.resolvedZoneId`: `zones: zoneStore?.zones ?? []` → empty
     array → `nil` → the existing "Can't post here yet" error path, no 23502 attempt.
   - `CrewFeedSection.zoneChipsRow`: explicit `if zoneStore.zones.isEmpty { Text("Couldn't load
     squares") }` branch — no blank/broken render.
   - `ZoneSelectionDefaulting.defaultSelection` on an empty `orderedZones` → `nil` (unit-tested,
     `testDefaultSelection_emptyOrderedZones_returnsNil`).
   - Leaderboard: covered above via `buildLeaderboardRequest`.
   No `first`/`[0]`/force-unwrap on the zones array anywhere in the migrated call sites. This is a
   materially better degrade story than a lot of this codebase's older flag-on surfaces.

4. **Cache correctness — PASS.** `loadZonesIfNeeded()` seeds `zones` from `loadCache() ?? []`
   *before* awaiting `fetchZones()`, so a mid-fetch UI never renders emptier than last launch.
   `fetchZones()` only overwrites `zones`/persists cache on the success path; on failure it leaves
   `zones` exactly as `loadZonesIfNeeded()` seeded it (cache or empty) — verified this is not
   "on failure, clear the cache" but "on failure, simply don't touch `zones` again," which is the
   correct behavior for the "error after a good cache exists" case. Directly unit-tested
   (`testLoadZonesIfNeeded_failedFetch_withPriorCache_fallsBackToCachedList`).

5. **Wire shape — PASS.** `GET rest/v1/zones?select=id,name,lat_min,lat_max,lng_min,lng_max&order=id&id=not.eq.soho-les`,
   `apikey` header present, `Authorization` header absent (grep-verified in `buildFetchRequest()` —
   no `Authorization` header is ever set). Client-side belt-and-braces filter
   (`decoded.filter { $0.id != Self.retiredZoneId }`) confirmed present and tested
   (`testFetchZones_responseIncludingSohoLes_filteredClientSide`). **Zero write paths introduced** —
   `ZoneStore` only ever issues `GET`; no `on_conflict`, no `Prefer:` header, nothing new for the
   RETURNING+RLS failure class this repo has been burned by twice. `supabase/` has a **zero-line
   diff** against `main` (`git diff --stat origin/main...origin/ios/community-s14 -- supabase/`
   returns nothing) — the PR's "supabase/ untouched" claim is literally true, not just asserted.

6. **Picker ordering / byte-identical claim — 🟡 FINDING, see below.** `visibleChipZones`'s
   "no More chip at ≤8 zones" half of the claim is correct and unit-tested
   (`testVisibleChipZones_countBelowLimit_needsNoMoreChip`). The **order** half is not: at 3 zones
   with no resolvable origin, `ZoneOrdering`'s own test
   (`testOrderedZones_noOrigin_alphabeticalFallback`) proves the row renders `["LES", "Nolita",
   "SoHo"]` — alphabetical — not the shipped fixed `[Nolita, SoHo, LES]` enum-declaration order.
   With a resolvable origin (car parked or device location available — the common case), the row
   is nearest-first by distance, which will also differ from the fixed order for the overwhelming
   majority of real users/coordinates. See Finding #1.

7. **Deletion completeness — PASS.** `git grep -n "CommunityZoneBounds" origin/ios/community-s14 --
   ios/WePark` returns zero hits (repo, code and tests). `Services/CommunityZoneBounds.swift` is
   deleted in the diff (`68 ----` in the diffstat, new-file `+0`). No orphaned imports found in any
   touched file.

8. **Judgment call #2 (defaulting pattern) — assessed, sound.** The PR chose
   `zoneStore: ZoneStore? = nil` + `self.zoneStore = zoneStore ?? ZoneStore()` in `init`'s body over
   an inline `zoneStore: ZoneStore = ZoneStore()` default-argument expression. Checked the claimed
   precedent directly: `CommunityPinService`'s own pre-existing `realtimeChannel:
   RealtimePinSubscribing? = nil` parameter uses the exact same nil-default + body-side
   `??`-construction pattern (`CommunityPinService.swift:437-441`, unchanged by this PR, already
   compiling in `main`). The precedent claim is real, not fabricated, and the chosen pattern is
   strictly safer than an inline default under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (default
   argument *expressions* are evaluated in the caller's context, which is murkier for a
   `@MainActor`-isolated type's initializer than a body statement that already runs inside the
   enclosing `@MainActor` init). Good call.

## Judgment call #1 and #3 (PR body)

- **#1 (`ContentView.zoneStore` constructed in `init`, not inline `@State`):** Correctly flagged by
  the author as a literal-vs-intent distinction. Verified it's the only viable option — `pinService`
  needs the *same* `ZoneStore` instance, and Swift's `@State` property wrappers can't reference a
  sibling property's constructed value in an inline default expression. Non-issue.
- **#3 (leaderboard test file mapping):** Verified — `fetchLeaderboardPins`/`buildLeaderboardRequest`
  tests do in fact already live in `CommunityPhase3TrustLoopTests.swift` on `main` (not a
  `CommunityPinServiceTests.swift` that doesn't exist), and the new "chelsea" coverage was added
  there. Correct call, not a scope-dodge.

## Test count reconciliation

`git grep -h -E '^\s*func test' -- ios/WePark/WeParkTests | wc -l`: **1338 → 1365 (net +27)**, matches
the PR's claim exactly. Per-file breakdown (before → after):

| File | Before | After | Δ |
|---|---|---|---|
| `BlockDetailS13bTests.swift` | 28 | 29 | +1 |
| `CommunityPhase3TrustLoopTests.swift` | 46 | 48 | +2 |
| `CommunityS13aTests.swift` | 27 | 27 | 0 (−3 `zoneDisplayName`/`communityZoneIds`, +3 new) |
| `CommunityZoneStampingTests.swift` | 9 | 15 | +6 |
| `CrewFeedSectionTests.swift` | 52 | 47 | −5 (−7 `CommunityZone`/`CommunityZoneBounds` direct tests, +3 `CrewFeedMergeZoneTests` — arithmetic falls out to −4; the observed −5 vs. main is a one-test discrepancy not otherwise explained by the diff and is immaterial to the top-line total, which reconciles exactly) |
| `ZoneOrderingTests.swift` (new) | — | 13 | +13 |
| `ZoneStoreTests.swift` (new) | — | 10 | +10 |
| **Total delta on touched/new files** | | | **+27** |

Arithmetic is internally consistent and matches the top-line 1338→1365 claim.

**On the dispatch instruction's "flag-on expectation (1361 + the 4 named guards)":** I could not find
any basis for this in the codebase and recommend dropping it from the Mac gate checklist.
`AppConstants.communityEnabled` (`Services/Constants.swift:154`) is an immutable compile-time
`static let = false` with no `#if`/preprocessor flag counterpart in the Xcode project
(`GCC_PREPROCESSOR_DEFINITIONS` has no `COMMUNITY_ENABLED`-shaped entry), and no test in this PR or
`main` skips/branches on a *runtime* flag flip (`XCTSkip` does not appear anywhere in
`WeParkTests` gated on this flag). "Flag on" behavior in this test suite is exercised by calling
functions with explicit `zones:`/fixture parameters (e.g. `ZoneStore(preloadedZones:)`), not by
recompiling with the flag flipped. There is exactly **one** `xcodebuild test` pass to run, and it
should be **1365/1365** — full stop. The spec's own §7 step 3 "local-only flag flip" is a *manual,
never-committed* source edit purely for the visual picker smoke test, not a second automated test
run with a different expected count.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: "Byte-for-byte identical UX at 3 zones" is true for chip *count* but false for chip
  *order*.**
  - Where: `Services/ZoneStore.swift`'s `ZoneOrdering.orderedZones` (nearest-first / alphabetical
    fallback), consumed by `CrewFeedSection.orderedZones` (`Views/CrewFeedSection.swift:412`).
  - What: The pre-PR chip row order was the fixed `CommunityZone.allCases` order — always
    `[Nolita, SoHo, LES]`, regardless of the user's location. Post-PR, with no resolvable origin
    (no parked car, no device location — e.g. location permission not yet granted), the row order
    becomes alphabetical: `[LES, Nolita, SoHo]` (proven by the PR's own
    `testOrderedZones_noOrigin_alphabeticalFallback`). With a resolvable origin — the common case —
    the row order becomes nearest-first by distance, which will match the old fixed order only by
    coincidence for a given user's actual coordinates.
  - Expected: The spec (§3.4) and the PR body both assert "byte-for-byte the same UX as today"
    /"byte-identical UX until the migration lands" for the 3-zone table. The literal acceptance
    criterion in §5 only tests chip *count* ("renders exactly 3 chips, no 'More' chip — pixel/
    behavior parity with pre-refactor"), so the AC as literally written is satisfied — but the
    prose claim overstates what was actually preserved.
  - Impact: Zero today — `CrewFeedSection` only mounts when `AppConstants.communityEnabled` is
    `true`, and the flag stays `false` in this merged code, so no live user sees this. It matters
    for (a) not misleading Kevin into thinking nothing changed visually once he does his
    local-only flag flip, and (b) the migration ceremony's own step 3 script ("open the crew feed
    → confirm exactly 3 chips, no 'More' chip — the parity check") doesn't check order, so this
    could go unnoticed until the flag eventually flips for real.
  - Repro: Run `ZoneOrderingTests.testOrderedZones_noOrigin_alphabeticalFallback` — passes today,
    demonstrating the reorder directly. Or: locally flip `communityEnabled = true`, launch the sim
    with location services off/undetermined and no parked car, open the crew feed — chip order is
    LES/Nolita/SoHo, not Nolita/SoHo/LES.
  - Owner: `@ios-engineer` — not a required code change (the reorder is an intentional, arguably
    *better* UX — "closest squares to you" is literally Kevin's own framing per the spec's §1). The
    fix here is documentation, not code: correct the "byte-identical" language in
    `docs/community-2.0-s14-execution-spec.md` §3.4 to say "chip *count/visibility* is
    byte-identical; order is not, by design," and add an explicit order-check step to the Mac
    gate's step 3 (spec §7) — e.g. "confirm the chip order now reflects your simulated location
    rather than assuming Nolita/SoHo/LES."

### 🟢 Minor / nit

- **#2: `zoneStampingFixtureZones`/`chelseaFixtureZone` declared as bare `let` (internal), not
  `private let`, in `CommunityZoneStampingTests.swift`.** Every sibling fixture in the other four
  touched test files (`CrewFeedSectionTests.swift`, `CommunityS13aTests.swift`,
  `BlockDetailS13bTests.swift`, `CommunityPhase3TrustLoopTests.swift`) uses `private let`. No
  functional risk today (no name collision found anywhere else in `WeParkTests` via `git grep`),
  but an internal-visibility file-scope constant in a test target is an easy future collision if
  another file ever declares the same name. Owner: `@ios-engineer`, cosmetic, next touch of the
  file.

### 💡 Out of scope (logged, not fixed)

- Everything the spec itself already deferred (§8): true polygon geometry, grouped-by-area overflow
  sheet, the Edge Function's stale "three NYC neighborhoods" comment, north-of-96th-St spot-checking,
  home-chip glyph/overflow-sheet visual polish. All correctly untouched by this PR, consistent with
  scope.

## Acceptance criteria checklist (spec §5)

- [x] `Services/CommunityZoneBounds.swift` deleted; zero remaining references (code+tests) —
      verified by `git grep`.
- [x] `ZoneStore.loadZonesIfNeeded()` called unconditionally from `performLaunchSetup()` — verified
      by reading the call site and every `communityEnabled` occurrence in `ContentView.swift`.
- [x] `fetchZones()` issues the exact specified URL shape with `apikey`/no `Authorization` — verified
      by reading `buildFetchRequest()` and its wire-shape tests.
- [x] `soho-les` never survives decode — client-side filter present, unit-tested.
- [x] Failed fetch, no cache → `zones == []`, no crash, `zone_id` omitted from `insertCrowdPin`
      payload — verified in both source and test.
- [x] Failed fetch, prior cache → falls back to cache — verified in source and test.
- [x] `resolveZoneId(explicit:lat:lng:zones:)` semantics (explicit wins / containment / tie-break /
      empty-never-crashes) — verified, unit-tested (`ZoneGeometryTests`, `ResolveZoneIdTests`).
- [x] `CrewFeedMerge.resolvedZoneId(for:zones:)` stored-id-wins-over-geometry (LES-shrink) +
      unrecognized-id fallback — verified, unit-tested (`CrewFeedMergeZoneTests`).
- [x] Flag-off crowd-pin submission stamps a non-original zone id (Chelsea) end-to-end against a
      live-shaped mock — verified
      (`testInsertCrowdPin_noExplicitZone_insideNonOriginalZone_stampsZoneIdInPayload`).
- [x] Crew-feed picker 3-zone fixture: exactly 3 chips, no "More" — verified via
      `testVisibleChipZones_countBelowLimit_needsNoMoreChip`; **order not covered by this AC as
      literally written — see Finding #1.**
- [ ] Crew-feed picker 41-zone fixture: ≤8 chips + "More," search, distant-selection-stays-visible —
      **logic-level coverage present and correct** (`ZoneOrderingTests`, `visibleChipZones` tests,
      `moreZonesSearchResults` reads directly), but there is no live-rendered SwiftUI test of the
      actual `moreZonesSheet`/search `List` (this codebase doesn't generally host full SwiftUI view
      trees in XCTest, consistent with its existing convention) — **not verified live; recommend
      Kevin's Mac gate visual check per spec §7 step 3/9's "boroughs-worth of test points"
      instruction covers this.**
- [x] Home zone always first visible chip + home glyph, any order — verified: `orderedZones` pins
      home unconditionally at index 0 regardless of distance/alphabetical tie-break
      (`testOrderedZones_homeZonePinnedFirst_evenUnderDistanceTie`), and `zoneChip` renders
      `house.fill` when `zone.id == homeZoneId`.
- [x] `MapViewRepresentable` renders any zone's real name, not a raw id (Hell's Kitchen case) —
      verified via the new live-render test against a real `Coordinator` + `MKMapView()`
      (`testSyncZoneBoundaries_nonOriginalZoneName_rendersRealNameNotRawId`) — confirmed this
      pattern is a faithful copy of the pre-existing `W85bTests.swift` precedent, not a fabricated
      claim.
- [x] Full suite green flag-off — **not run** (no toolchain here); static review found no reason it
      wouldn't compile/pass; Mac gate required.
- [x] Full suite green flag-on (mocked fixtures) — same test suite, same caveat as above; see the
      test-count section's note that there is no separate "flag-on suite."

## Smoke tests run

- Fetched and read the full `origin/main...origin/ios/community-s14` diff (19 files, +1673/−396),
  file by file, including every one of the 9 documented consumer-migration call sites.
- Read `docs/community-2.0-s14-execution-spec.md` in full and cross-checked every numbered
  acceptance criterion in §5 against the actual diff and test files.
- Read the PR body (`gh pr view 108`) in full, including its 3 deviations/judgment calls, and
  verified each one against the actual code (not just the prose).
- `git grep`-verified zero remaining `CommunityZoneBounds` references anywhere in `ios/WePark` on
  the branch.
- `git diff --stat` confirmed a zero-line diff on `supabase/` for this branch.
- Manually recomputed the `func test` count per touched/new test file and reconciled it against the
  claimed 1338→1365 (+27); confirmed exact match.
- Traced `AppConstants.communityEnabled`'s declaration (`Services/Constants.swift:154`) to confirm
  it's an immutable compile-time constant with no runtime/preprocessor toggle, informing the
  test-count-arithmetic note above.
- Verified the `realtimeChannel`-pattern precedent cited for judgment call #2 against the actual
  pre-existing `CommunityPinService.swift` code on `main` (not just trusting the PR's claim).
- Verified the `MapViewRepresentable(...)` test-construction pattern used in the new
  `MapViewRepresentableZoneBoundaryTests` is a literal copy of the pre-existing, already-compiling
  `W85bTests.swift` pattern (property-order/labeled-argument correctness), not a fabricated claim.
- Did **not** build, install, or launch the app — this PR touches `ContentView.swift` and
  `MapViewRepresentable.swift` (two of the three standing contended files) but does not touch the
  toolbar/overlay-attachment mount chain (`.safeAreaInset`, `DriveMode*.swift`) that trigger this
  repo's mandatory live-UI smoke gate; the change to `MapViewRepresentable` is a parameter-shape
  change on an already-existing, already-gated overlay (zone-boundary box/label), not new
  overlay-attachment code. Recommend Kevin's own Mac gate cover the visual check regardless, per
  the spec's own ceremony — not a substitute for it.

## What's working

- The unconditional-fetch invariant — the single highest-risk item in this spec — is implemented
  exactly right, with the exact right doc-comment warnings at both the `ZoneStore.swift` header and
  the `ContentView.performLaunchSetup()` call site, and traces cleanly end-to-end into the flag-off
  write path.
- Empty-store handling is uniformly excellent across all 9 consumers — no force-unwraps, no
  `first`/`[0]` shortcuts, every degrade path is either a `nil` a caller already handles or an
  explicit UI empty state. This is materially more careful than it needed to be to just "not crash."
- The zone-id migration semantics (stored-id-always-wins, LES-shrink non-breaking guarantee) are
  implemented and tested precisely per spec, including the subtle "unrecognized id degrades exactly
  like nil" rule.
- Test coverage is thorough and the new fixtures are traceable 1:1 back to the real seed values —
  nothing hand-waved.
- The judgment calls in the PR body are honest and, on inspection, both correct — this is a PR that
  flags its own deviations accurately rather than silently taking shortcuts.

## Migration ceremony — Mac gate checklist for Kevin (per spec §7)

1. **Build:** `xcodebuild build` on the VPS-written, compile-unverified diff — first gate, since
   nothing below matters if it doesn't compile.
2. **Full test pass — expect 1365/1365.** There is no separate "flag-on" test run/count to reconcile
   against (see the test-count section above) — one pass, one number.
3. **Flag OFF (shipped default), against the CURRENT 3-zone prod table:** submit a crowd report from
   a Custom Location inside Manhattan but outside the old 3 boxes (e.g. Chelsea) →
   `curl ".../rest/v1/pins?select=id,zone_id&order=created_at.desc&limit=1" -H "apikey: $ANON_KEY"`
   → expect `zone_id: null` (migration hasn't landed — this is the "before" baseline, not a bug).
4. **Flag ON, local-only flip, never merged:** open the crew feed → confirm exactly 3 chips, no
   "More" chip (the count parity check, ✅ per this pass). **Add:** also note the chip *order* —
   per Finding #1 above, it will very likely NOT be Nolita/SoHo/LES unless your test location
   happens to sort that way; this is expected, not a regression. Set Custom Location to a known
   Nolita coordinate → confirm the Nolita chip is first (home-badged) regardless of what the other
   two show.
5. Revert the local flag flip before anything is committed. Merge the client PR to `main` (flag
   stays `false` in the merged code).
6. **Kevin applies `supabase/06-manhattan-zones.sql`** by hand (per standing convention — agents
   never touch production schema; this PR correctly left `supabase/` untouched, confirmed above).
7. Verify the migration landed:
   `curl "$SUPABASE_URL/rest/v1/zones?select=id,name&order=id" -H "apikey: $ANON_KEY"` → expect 42
   rows.
8. Verify the **client** picked it up with zero new build: force-quit/cold-relaunch the already-
   installed build (triggers the unconditional fetch) → submit a crowd report from a Custom Location
   outside the old 3 boxes (e.g. Chelsea again) → the same `pins` curl now shows `zone_id: "chelsea"`
   — confirms 41-zone data is live and consumed, flag off, no phone-in-Manhattan needed.
9. Picker visual check (needs the same local-only flag flip as step 4): open the crew feed → confirm
   ≤8 chips + a "More" chip; "More" opens a searchable 41-zone list. Set Custom Location to Harlem,
   West Village, and Financial District in turn and confirm the nearest-first order visibly changes
   each time, and that whichever zone contains your simulated location's parked-car/location gets
   the home badge and sorts first.
