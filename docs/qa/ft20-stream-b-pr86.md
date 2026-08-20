# FT-20 Stream B (Search/Place Relocation + OQ-4) QA Pass 1 — 2026-08-20

**Reviewed:** branch `ios/ft20-stream-b-search-place` at `3aca27bb`, against
`docs/ft20-bottom-sheet-navigation-spec.md` §0/§0b/§0c/§3.2/§3.3/§4.3/§7/§9,
`docs/design/ft20-bottom-sheet-review.md` (S2, S5), and `docs/qa/ft20-stream-a-pr85.md` (prior pass).
**Environment:** Linux VPS — no Xcode, no simulator, no `xcodebuild`. This is a static code read; nothing
below is a compile or runtime claim. Kevin verifies compile/test status and live-UI smoke on his Mac.

**A methodology note, stated plainly per the "no silent passes" rule:** partway through this review, this
worktree's `Services/ParkingProximityScorer.swift` and `WeParkTests/ParkingProximityScorerTests.swift` were
found to be locally, silently modified on disk relative to `git HEAD` — the working-tree copies had reverted
a bucket-boundary tie-break fix and dropped 4 boundary-condition tests that are genuinely present in the
committed branch (cause unknown; possibly shared-worktree contention with another process). This was caught
by a `git status`/`git diff HEAD` check before committing this report, and both files were restored via
`git restore --source=HEAD` before finishing the review. **All findings below are against the actual
committed content at `3aca27bb` (verified via `git show HEAD:<path>`), not the transient on-disk state.**
Flagging this because it nearly produced a false "bug" finding (a bucket-tie-break defect that does not
actually exist in this branch) — worth Kevin's awareness given the "Parallel iOS agents collide on shared
simulator/worktree" pattern already in project memory.

**Verdict:** 🟡 **SHIP WITH CAVEATS — ready for Mac compile + merge (no-op confirmed), with one real
architecture risk (Finding #1) that must be verified or fixed before Stream C flips the gate.** The no-op
merge property is genuinely proven, the reuse discipline (Priority 2) is excellent, and `ParkingProximityScorer`
(Priority 3) — once reviewed against its actual committed content — is careful, well-reasoned work with a
notably thorough tie-break test suite. The one real defect found is a reintroduction of the exact
`List`-greedy-sizing trap Stream A's own doc comments describe solving, in a new location Stream A never
anticipated (Finding #1). It doesn't break the no-op merge guarantee, but Stream C must not inherit it
silently.

## Summary

Stream B's actual deliverable is careful, well-documented work that takes the §0c correction (don't gut
`DriveModeDestinationView.swift` while its cover is still live) seriously and executes it correctly: the
port to `BrowseSearchAreaView.swift` is genuinely additive, genuinely reuses `SearchCompleterDelegate`/
`RecentDestinationsStore`/`SearchTimeoutError` rather than duplicating them, and preserves every piece of
`DriveModeDestinationView`'s behavior §4.3 promises to keep (completer, recents, suggestions, inline error
banner, auth gate, out-of-coverage toast, M-1's timeout race) with one behavior-affecting gap found (Finding
#2, error banner visibility). `onRouteReady`'s duplicated closure body is byte-for-byte identical to
`driveModeDestinationCover`'s (confirmed by direct comparison, not by trusting the comment). S2 (semantic
color) and S5 (`.scrollDismissesKeyboard`) are both correctly and completely implemented.
`ParkingProximityScorer`'s bucket-boundary math is correct and unusually well-defended: a strict-majority
(`> 0.5`) tie-break with an explicit doc-comment "contract" section reasoning through every tie
configuration (50/50 free/restricted, 50% restricted with a free+metered remainder, 50% free with an
all-metered remainder, 100% metered), backed by 22 tests including 4 dedicated boundary-condition tests. The
one real finding is in the detent-height measurement plumbing — precisely the area the task briefing flagged
as the known failure class for this file (`List`-greedy-sizing), which is exactly where careful adversarial
review earns its keep.

## Acceptance criteria checklist (Stream B's actual scope — §7 AC-7 through AC-14, plus AC-4/AC-5)

- [x] AC-4 (search field visible/tappable at every detent) — `BrowseSearchAreaView.body`'s `searchField` is
  unconditional at the top of the `VStack`, unaffected by `detentKind`. Verified by inspection; not
  reachable at runtime (gate off).
- [x] AC-5 (tap search field at peek/medium → large + focus) — `.onChange(of: searchFieldFocused)` sets
  `detentKind = .large` (`BrowseSearchAreaView.swift:184–193`).
- [x] AC-7 (live suggestions) — `suggestionsList` reused verbatim from `DriveModeDestinationView`, plus S5.
- [x] AC-8 (empty query → recents, 5 MRU, swipe-to-delete) — `recentDestinationsList` reused verbatim;
  `RecentDestinationsStore` (`Services/RecentDestinationsStore.swift`, zero-diff) is the actual reused type,
  not a re-implementation. Confirmed max-5/MRU/swipe-delete logic untouched.
- [x] AC-9 (selection resolves to place state: name/subtitle/distance/Go, no auto-drive) — `placeState`
  (`BrowseSearchAreaView.swift:366–436`). Confirmed nothing in `selectCompletion`/`selectRecent` calls
  `onRouteReady` or otherwise starts Drive Mode — Go (`handleGoTap`) is the only path in.
- [x] AC-10 (OQ-4 summary, ≤100m, no network, S2 color) — `ParkingProximityScorer.score` scans
  `segments` (already `TileLoader.segments`, in-memory) with `defaultRadiusMeters = 100`, no network call.
  Color via `bucket.color` reusing `ParkingColors.freeComfortably`/`.meteredActive`/`.restricted` — no new
  color constants. Bucket-boundary math verified correct against the committed content (see Priority 3
  section below) — a strict `> 0.5` majority with ties landing in `.mixed`, matching the doc comment's
  explicit contract and 22 tests (4 of them dedicated boundary-tie cases).
- [x] AC-11 (Go fires the identical `onRouteReady` sequence) — confirmed byte-for-byte identical to
  `driveModeDestinationCover`'s closure body (`ContentView.swift:856–863` vs. `:1271–1276`), same 4
  assignments in the same order, same CM-3 ordering comment preserved. Sheet-disappearing-per-§6 half of
  AC-11 is Stream C's mount-level wiring, correctly not attempted here.
- [x] AC-12 (`MapboxRouteError` inline banner, same copy) — `friendlyErrorMessage` reused verbatim
  (identical switch, identical strings). **But see Finding #2 — the banner's visibility condition changed.**
- [x] AC-13 (out-of-coverage toast) — `AppConstants.isInManhattanCoverage` + `ToastService.shared.show`,
  same 0.3s delay, reused verbatim.
- [x] AC-14 (clearing query → recents + clears place state) — `clearResolved()` wired to both the xmark
  button and `.onChange(of: query)`'s empty branch.
- [ ] AC-1/2/3/6 (sheet mechanics), AC-15–33 (medium list / chrome removal / FT-15 boundary / Drive Mode
  boundary / non-goals / accessibility minimum) — **out of Stream B's scope**, see the explicit deferred
  list below.

## §7 ACs explicitly deferred to Stream C (not evaluated as failures here)

- **AC-1, AC-2, AC-3, AC-6** — sheet container mechanics, Stream A's scope, unmodified by this PR
  (`BrowseNavigationSheet.swift` is zero-diff — confirmed via `git diff origin/main...HEAD`).
- **AC-15–18** (medium-detent 3-item list content/actions) — Stream A's scope, unmodified.
- **AC-19–22** (gear/`?`/Menu deletion, Locate/Find-my-car unaffected, Park Until relocation) — Stream C's
  scope per spec §9; nothing in this PR touches `gearButtonOverlay`, `driveEntryButton`, or the Park Until
  toolbar button. Confirmed: `driveEntryButton` and the in-Drive "Park here" button, and their
  `noBlockingSheetPresented` guards, are untouched by this diff.
- **AC-23–27** (FT-15 block-select boundary: hide/restore of `.browseNav`) — Stream C's scope; this PR adds
  no `blockSelectModeActive` interaction.
- **AC-28–31** (Drive Mode boundary: sheet hide-on-entry/reappear-on-exit, zero-touch guarantee on
  `MapViewRepresentable.swift`/`recenterDriveMode()`/`endDriveControl`/`recenterRow`) — Stream C's scope.
  Zero-touch confirmed for this PR too: `git diff origin/main...HEAD -- MapViewRepresentable.swift` is
  empty.
- **AC-32–33** (non-goal: no new hardcoded colors, no Drive-Mode-active visual changes) — Stream B's own new
  UI is conformant (`.secondary`/`.primary`/`Color(.secondarySystemGroupedBackground)`/`ParkingColors`
  only), but full-app conformance is still contingent on Stream C not introducing a violation elsewhere.
- **AC-34** (VoiceOver grabber) — system-sheet feature, Stream A's scope, unaffected.
- **AC-35** (accessibility labels ported) — search field's "Clear search" label ported verbatim; Go carries
  a new, reasonable `accessibilityLabel`/`accessibilityHint` (no prior per-button label existed to port,
  since the old button had no explicit accessibility label at all — this is new coverage, not a regression).

## Direct answers to the four questions asked

**1. Is merging this branch a user-visible no-op?** **Yes**, with the same rigor as Stream A Pass 2's proof,
not a spot-check:
- `ContentView.swift`'s only behavioral diff is the `searchArea:` closure argument inside
  `browseNavigationSheetContent` (plus doc comments). `browseNavigationSheetContent` has exactly one
  reference site in the whole file (`ContentView.swift:1232`, the `.browseNav` case of `sheetContent`'s
  switch), and `.browseNav` can only ever be assigned while `Self.ft20BrowseSheetEnabled == true`
  (`dismissTargetOutsideBrowseNav`'s guard, `ContentView.swift:926`, and the gated backstop at `:755`) —
  `ft20BrowseSheetEnabled` is `private static let ft20BrowseSheetEnabled = false`
  (`ContentView.swift:905`), and the diff's only touch to that identifier is a doc-comment mention
  (`grep`-confirmed: the string `ft20BrowseSheetEnabled` appears once in the diff, in a comment, at line 25
  of the `ContentView.swift` hunk).
- `Views/DriveModeDestinationView.swift` and `MapViewRepresentable.swift` are both confirmed zero-diff
  (`git diff origin/main...HEAD` returns empty for both).
- `BrowseSearchAreaView` is constructed only inside the `searchArea:` closure passed to `BrowseNavigationSheet`
  inside `browseNavigationSheetContent` — a computed property evaluated lazily by SwiftUI only when the
  `.browseNav` sheet case is actually rendered. `ParkingProximityScorer.score` is called from exactly one
  site, `BrowseSearchAreaView.updateNearbyParkingScore()` (`grep`-confirmed, no other call site in the
  non-test source). Neither type does any work in `init`, registers an observer, or starts a `Task` outside
  this unreachable chain — no eager side effects at launch.
- The new files add no new mutable global/singleton state and touch no existing `@State` read outside this
  chain.

**2. Was anything claimed reused actually duplicated instead?** **No.** Verified by `grep` for each type's
declaration site: `SearchCompleterDelegate` (`final class`, `DriveModeDestinationView.swift:40`),
`RecentDestinationsStore` (`final class`, `Services/RecentDestinationsStore.swift:39`), and
`SearchTimeoutError` (`struct`, `DriveModeDestinationView.swift:602`) each have exactly one declaration in
the codebase. `BrowseSearchAreaView` references all three by name without redeclaring them.

**3. Was any `DriveModeDestinationView` behavior silently dropped in the port?** **Mostly no, with one real
gap (Finding #2).** A line-by-line diff of the two files' bodies (search field, error banner content,
recents list, suggestions list anatomy, auth-gate spinner/alert, `selectCompletion`'s M-1 timeout race,
`fetchRouteAndReturn`'s route-fetch/scoring/recent-save/toast sequence, `friendlyErrorMessage`) found the
logic itself preserved verbatim in every case. The one behavior-affecting change not called out in the
file's own "Deltas from `DriveModeDestinationView`" doc comment: **the error banner's visibility condition
changed from unconditional (`if let error = errorMessage`) to conditional on `detentKind == .large`**
(Finding #2) — a real, if narrow, regression the port's own doc comment doesn't mention.

## Findings

### 🟡 Significant

**#1 — `searchArea`'s height measurement in `BrowseNavigationSheet` has no guard against the `List`-greedy-
sizing trap Stream A's own doc comments describe solving for `actionList` — and Stream B's real content
(unlike Stream A's static stub) can now contain a `List`, reintroducing exactly that trap in a location
Stream A never anticipated.**
- **Where:** `Views/BrowseNavigationSheet.swift:238–247` (the un-constrained `searchArea` slot) vs.
  `BrowseSearchAreaView.swift:152–174` (the body that, at `detentKind == .large`, conditionally renders
  `recentDestinationsList`/`suggestionsList` — both real SwiftUI `List`s).
- **What:** `BrowseNavigationSheet.body` places `searchArea` directly with `.onGeometryChange` and no
  `.frame` constraint, then feeds the reported height straight into `reportHeights()` → both
  `onPeekHeightChange` and `onMediumHeightChange` (`BrowseNavigationSheet.swift:297–306`). `actionList`, by
  contrast, is explicitly `.frame(height: actionListHeight)`-constrained, with a detailed doc comment
  explaining exactly why: *"`List` is a UIKit-bridged, flexible/greedy-sizing container: left unconstrained,
  it expands to fill whatever vertical space its parent offers... a system sheet's content is laid out
  against the FULL `.large`-sized container regardless of which detent is currently visible."* Stream A's
  own `searchArea` doc comment (`BrowseNavigationSheet.swift:156–165`) explicitly assumed Stream B's content
  would "stay close in height to the stub's single-line row at rest" — true only while `detentKind !=
  .large` (only `searchField` renders then, an intrinsically-sized `HStack`, no `List`, no `Spacer`). The
  moment a user taps the search field (or has typed something) and `detentKind == .large`,
  `BrowseSearchAreaView`'s body now includes a real `List` with no height constraint of its own — by Stream
  A's own established reasoning, that `List` will greedily report a height close to the sheet's full
  large-detent size, not "however tall the search field is." That inflated `searchAreaHeight` then flows
  straight into `peekHeight`/`mediumHeight` via `.onChange(of: searchAreaHeight) { reportHeights() }`.
- **Why it matters:** `peekHeight`/`mediumHeight` are supposed to represent "search field alone" /
  "search field + 3 rows" — the entire point of OQ-3's custom-detent math. If they get corrupted to a
  near-`.large` value every time the user is genuinely at `.large` (viewing suggestions or recents), the
  `.presentationDetents` array ContentView feeds the system sheet (`.height(peek)`, `.height(medium)`,
  `.large`) could carry a stale, oversized peek/medium value for at least one layout pass when the user
  later collapses the sheet — precisely the class of transition-timing bug this file has a documented,
  repeated history of (FT-17a, FT-18, W8.5c-polish; also S3/S4's exact concern in the design review). Best
  case this self-corrects within a frame once `BrowseSearchAreaView`'s `List` is conditionally removed from
  the tree and `.onGeometryChange` re-fires with the correct smaller value; worst case there's a visible
  snap/flicker or a persistently-oversized peek/medium detent — this can't be distinguished from the code
  alone and needs on-device confirmation, which this PR's own tests don't attempt (`BrowseSearchAreaViewTests`
  only asserts `host.view != nil`, never measures geometry or exercises detent transitions).
- **Repro (by trace, not yet device-verified):** Once the gate is flipped: tap the search field (sheet →
  `.large`, `recentDestinationsList` renders) → drag the sheet down toward medium/peek. Watch whether the
  sheet snaps to a visibly oversized medium/peek height for a frame, or settles at the correct small one.
- **Fix options:** mirror `actionList`'s own fix — constrain `searchArea`'s frame (or, more precisely, only
  the conditionally-rendered `List`/`placeState` portion) so its measured height can't exceed some sane
  ceiling, or restructure so only the always-visible `searchField` feeds `BrowseNavigationSheet`'s height
  measurement and the large-detent-only content (recents/suggestions/place state) is laid out separately,
  outside the geometry-change pipeline that drives peek/medium sizing.

### 🟢 Minor / nit

**#2 — The inline error banner's visibility condition silently changed from "always shown when `errorMessage`
is set" to "only shown when `detentKind == .large`," which can make a route-fetch or address-resolution
failure invisible if the user has collapsed the sheet in the meantime.**
- **Where:** `BrowseSearchAreaView.swift:162–173` (`if detentKind == .large { if let errorMessage {
  errorBanner(errorMessage) } ... }`) vs. `DriveModeDestinationView.swift:151–154` (`if let error =
  errorMessage { errorBanner(error) }`, unconditional, rendered directly under the search field regardless
  of any other UI state).
- **What:** Nothing prevents the user from dragging the sheet from `.large` down to `.medium`/`.peek` while
  `isResolvingAddress` or `isLoadingRoute` is `true` (there's no interaction lock during either async
  operation). If the operation then fails (`selectCompletion`'s timeout/network catch, or
  `fetchRouteAndReturn`'s `MapboxRouteError`/generic catch) while `detentKind != .large`, `errorMessage`
  gets set but the banner never renders — the user sees the sheet quietly return to peek/medium's action
  list or search field with no indication anything failed, and `isLoadingRoute`/`isResolvingAddress` simply
  goes back to `false`. The file's own top-of-file "Deltas from `DriveModeDestinationView`" doc comment does
  not mention this change, which suggests it may not have been a deliberate design decision so much as a
  side effect of nesting the error banner inside the same `if detentKind == .large` block as the
  large-detent-only lists.
- **Why it matters:** Low-frequency (requires the user to actively collapse the sheet mid-request) but a
  real, silent-failure UX regression once reachable — a failed search/route with zero feedback is worse than
  the un-gated original.
- **Fix:** Hoist the `if let errorMessage { errorBanner(errorMessage) }` block out of the `detentKind ==
  .large` gate so it renders regardless of detent (matching the original's unconditional placement), or
  explicitly decide and document that errors should only surface at large and force `detentKind = .large`
  when one occurs.

**#3 — `ParkingProximityScorerTests` never exercises the `.freeButRestrictionSoon` branch, despite the
production code giving it special "free-equivalent" treatment with its own explanatory comment.**
- **Where:** `ParkingProximityScorer.swift:213–219` (the `.freeButRestrictionSoon` case, folded into
  `freeCount` with a comment explaining the "still parkable RIGHT NOW" reasoning) — no corresponding test
  fixture in `ParkingProximityScorerTests.swift` (22 tests, checked all by name and fixture category)
  produces a segment whose `currentState` resolves to `.freeButRestrictionSoon` (would require a restriction
  scheduled within `ParkingRulesEngine.nearFutureWindow`, 6h, per `ParkingRulesEngine.swift:335`). All
  "free" test fixtures use `category: .free`, which resolves to `.freeComfortably`, not
  `.freeButRestrictionSoon`.
- **Why it matters:** Small, but this is precisely the kind of "documented, deliberate, but unverified"
  branch the task asked to be named explicitly. Not a correctness concern found by inspection — the logic
  reads correctly — just genuinely untested, in an otherwise unusually thorough test file (22 tests, 4 of
  them dedicated to the bucket-boundary tie-break alone).
- **Fix:** Add one fixture with a restriction scheduled ~2–3h out (non-metered category) and assert it
  counts toward `freeCount`, not `restrictedCount` or excluded.

### 💡 Out of scope (logged, not fixed)

- The `weightedScore`/route-scorer weight equivalence (`+3`/`+1`) is real but achieved via a different
  underlying classification call (`ParkingRulesEngine.currentState(for:at:)`) than
  `RouteService.pickBestParkingAwareRoute` uses (`ParkingRulesEngine.safetyLabel(for:at:).severity`). Traced
  both functions by hand: for the practical (non-`.comingSoon`) cases this PR's own comment at
  `RouteService.swift:294–301` confirms `.comingSoon` severity is unreachable from `safetyLabel(for:at:)` in
  production — the two functions' free/metered/restricted groupings are behaviorally equivalent for every
  case checked, but they are two independently-maintained pieces of logic, not one shared classifier calling
  the other. This is the *correct* choice per design-review S2's own explicit instruction ("reuse the
  classification from ParkingRulesEngine/CurrentState") rather than a drift risk — `CurrentState` is the
  more canonical, map-coloring classification, and `safetyLabel` is a separate PWA-text-parity function. Not
  a finding, just worth naming so a future reader doesn't assume literal code sharing exists where it
  doesn't.
- AC-1/2/3/6, AC-15–33 — Stream A/C scope, see the deferred list above.
- Live-UI confirmation of Finding #1's actual on-screen severity (flicker vs. persistent oversizing) —
  cannot be done on this Linux VPS; explicitly flagged for Kevin's Mac smoke once Stream C flips the gate.
- Dynamic Type / AX3 verification of `BrowseSearchAreaView`'s new `placeState` layout — same
  simulator-required limitation Stream A Pass 1's Finding #3 already named for `actionListHeight`.

## Smoke tests run

- `git diff origin/main...HEAD --name-status` — confirmed exactly 5 files touched: `ContentView.swift`,
  `Services/ParkingProximityScorer.swift`, `Views/BrowseSearchAreaView.swift`, and their two test files. No
  Stream A/C file leakage.
- `git diff origin/main...HEAD -- ContentView.swift` read in full (one hunk) — confirmed the only behavioral
  change is the `searchArea:` closure argument to `browseNavigationSheetContent`, plus doc comments; no
  other line touched.
- `git diff origin/main...HEAD -- Views/DriveModeDestinationView.swift` and
  `-- MapViewRepresentable.swift` — both empty, confirming zero-diff.
- `grep -n "ft20BrowseSheetEnabled"` across `ContentView.swift`, cross-referenced against the diff — the
  identifier appears 9 times in the file, exactly once in the diff (a doc comment), confirming the flag's
  own declaration/value is untouched (`private static let ft20BrowseSheetEnabled = false`).
- `grep -n "browseNavigationSheetContent"` — exactly 2 hits (declaration + the one `.browseNav` switch-case
  reference), confirming single-reachability.
- `grep -rn "ParkingProximityScorer\|BrowseSearchAreaView("` across non-test source — exactly one call site
  each, both inside the gated chain.
- Declaration-site `grep` for `SearchCompleterDelegate`, `RecentDestinationsStore`, `SearchTimeoutError` —
  exactly one declaration each, confirming genuine reuse rather than duplication.
- Line-by-line diff of `BrowseSearchAreaView.swift` against `DriveModeDestinationView.swift` (via `diff` on
  extracted body ranges) to enumerate every behavioral delta — found the documented deltas (NavigationStack/
  Cancel removal, auto-focus→expand-on-tap, unified place-state card, S5 addition, no `dismiss()`) all
  present as claimed, plus the one undocumented delta (Finding #2).
- Direct byte-comparison of `onRouteReady`'s closure body at both call sites
  (`ContentView.swift:856–863` and `:1271–1276`) — identical.
- Read `RecentDestinationsStore.swift` in full (zero-diff) to confirm MRU-5/swipe-delete/persist logic is
  what's actually being reused, not re-derived.
- Read `ParkingProximityScorer.swift` and `RouteService.swift`'s `pickBestParkingAwareRoute` (both the
  protocol-dispatch wrapper and the `static` implementation) **in full via `git show HEAD:<path>`** to verify
  the skip-category set (confirmed identical: `.noStanding, .noParking, .special, .truckLoading, .unknown`),
  the `+3`/`+1` weight claim (confirmed equivalent via `CurrentState` vs. `SafetyLabel.Severity`, see the
  out-of-scope note above), and the bucket-threshold math (a strict `> 0.5` majority with explicit tie
  handling, confirmed correct — see the methodology note at the top of this report for why this needed a
  second, `git show`-verified pass).
- Cross-checked `ParkingProximityScorerTests.swift`'s 22 tests against the committed content (`git show
  HEAD:...`) — 3 no-data/skip-category tests, 3 straightforward bucket tests, **5 boundary/tie-break tests**
  (the exact 50/50 case plus 3 variants plus "just over/under 50%" pins), 2 dedup tests, 2 radius-boundary
  tests, 1 unknown-exclusion test, 1 weighted-score test, 4 color/label tests — all real assertions against
  real fixtures, not tautologies.
- Read `CurrentState.swift`, `SafetyLabel.swift`, and `ParkingRulesEngine.swift`'s `currentState(for:at:)`/
  `safetyLabel(for:at:)`/`nextRestriction(for:at:)` in full to verify the classification-reuse claim (S2)
  and the free/metered/restricted grouping equivalence.
- Read `Segment.swift`'s `blockfaceKey`/`midpoint`/`dominantCategory` in full to verify the dedup-key and
  radius-scan claims; confirmed `blockfaceKey` (includes `side`) is a deliberate, documented improvement
  over `RouteService`'s own `street|from|to` dedup key (which conflates both sides of a block), not a
  mismatch.
- Read `BrowseNavigationSheet.swift` in full (zero-diff, but load-bearing for Finding #1) to trace exactly
  how `searchArea`'s measured height feeds `BrowseSheetDetentMath.peekHeight`/`.mediumHeight`, and to
  confirm `actionList`'s own `.frame(height:)` guard has no analog applied to `searchArea`.
- Read `BrowseSearchAreaViewTests.swift` in full — 5 render-smoke tests, asserting `host.view != nil` only,
  no geometry/detent-transition coverage (relevant to Finding #1 — nothing in this suite would have caught
  it).
- Checked all new/modified structs (`ParkingProximityScore`, `BrowseSearchAreaView`) for the known
  `let`-with-default-value memberwise-init pitfall — none found; `ParkingProximityScore` has no default
  values and no custom init (synthesized init used correctly), `BrowseSearchAreaView` has an explicit custom
  init.
- Confirmed the call-site argument order in `ContentView.swift`'s `BrowseSearchAreaView(...)` construction
  matches the declared init parameter order exactly (Swift requires this for labeled-argument calls).
- **Mid-review integrity check:** `git status`/`git diff HEAD` run before drafting findings, which surfaced
  the local on-disk drift on `ParkingProximityScorer.swift`/`ParkingProximityScorerTests.swift` described in
  the methodology note above; both files restored via `git restore --source=HEAD` and re-read from `git
  show HEAD:<path>` to confirm the review below reflects the actual committed branch content, not transient
  worktree state.

## What's working

- **The no-op merge property is real, not aspirational** — traced with the same rigor Stream A Pass 2 used,
  and it holds. `.browseNav` remains unreachable, `ft20BrowseSheetEnabled` is untouched, and both files the
  task asked to be zero-diff (`DriveModeDestinationView.swift`, `MapViewRepresentable.swift`) are.
- **§0c's judgment call — leaving `DriveModeDestinationView.swift` alone — was executed correctly and with
  real discipline.** The new file's own top-of-file doc comment explains *why* not to consolidate yet in
  more detail than most PRs bother with, and correctly identifies exactly what Stream C inherits.
- **The reuse claims for `SearchCompleterDelegate`/`RecentDestinationsStore`/`SearchTimeoutError` are true**,
  verified by declaration-site grep, not assumed from the doc comment.
- **`onRouteReady`'s duplicated body is genuinely identical**, not just claimed identical — this was the
  single highest-stakes behavioral claim in this PR (AC-11) and it holds under direct comparison.
- **S2 and S5 are both fully and correctly implemented** — semantic color reuse with no new `ParkingColors`
  constants, and `.scrollDismissesKeyboard(.interactively)` present on both relocated lists.
- **The "Go is the only path into Drive Mode" constraint holds** — no code path in `BrowseSearchAreaView`
  auto-starts a drive on search or selection, matching Kevin's explicit ruling.
- **`ParkingProximityScorer`'s bucket-boundary tie-break is genuinely excellent work** — a strict `> 0.5`
  majority requirement with an explicit "Bucket boundary contract" doc-comment section reasoning through
  every tie configuration by hand (50/50 free/restricted, 50% restricted with a mixed remainder, 50% free
  with an all-metered remainder, 100% metered), backed by 5 dedicated boundary/tie-break tests out of 22
  total. This is exactly the level of rigor the task briefing asked for given patrol mode's future reuse,
  and it holds up under a second, `git show`-verified read after this review's own methodology hiccup (see
  the note at the top of this report).
- **The `blockfaceKey`-based dedup is a deliberate, documented improvement** over `RouteService`'s own
  `street|from|to` key (which doesn't distinguish sides of a divided street) — correctly reasoned as a
  reuse of FT-15's established block identity rather than inventing a third key.
