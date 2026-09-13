# PR #109 QA — Community 2.0 LAUNCH flip (`communityEnabled` false → true)

**Reviewed:** branch `ios/community-launch-flip` at `877e4e09`, base `main` @ `d07a1d50`, against
`docs/community-2.0-roadmap.md` (flag-flip prerequisite section) and the PR's own stated scope.
**Method:** static review only, no toolchain in this environment (per task instructions) — full
diff read line-by-line, cross-referenced against `docs/community-2.0-roadmap.md`,
`docs/open-items.md`, `docs/field-testing-log.md`, and a grep sweep of every `communityEnabled`
reference in the test tree.
**Verdict: APPROVE** (pending the Mac gate below — this class of PR is not safe to TestFlight
without a live device confirmation, but nothing in the diff itself is wrong).

## Summary

This is a clean, minimal, correctly-scoped flag flip: exactly 4 files, all touching only the
constant + its doc comment + the 4 tests that read the flag's default/real value directly.
Every transformed assertion is the logically correct launched-world expectation (verified by
reading the production functions each test calls), no test was deleted, the static test count is
unchanged at 1365 on both sides of the flip, and a full grep of the test tree turned up no 5th
test that reads the live flag and would silently break. The diff is exactly what it claims to be.

## Acceptance criteria checklist (per the QA dispatch)

- [x] Diff scope is exactly 4 files — verified via `git diff --stat` and per-file `diff --git` header count (4).
- [x] `communityEnabled = true`, doc comment updated — verified by reading the full doc-comment diff; build 22 / 2026-09-13 / Kevin's ruling / "dark through 18–21" all present.
- [x] Each of the 4 guard-test transforms reads correctly against the OLD body on `main` and the production code path it exercises — verified individually below.
- [x] No test deleted; renames accurate — verified (`testCommunityEnabled_defaultsFalse`→`_launchedTrue`, `..._excludesIneligibleTypesAndFlaggedTypes`→`..._excludesIneligibleTypes` [dropped "AndFlaggedTypes" since the flag no longer excludes anything — correct], `testDefaultParameter_usesRealFlag_currentlyFalse`→`_currentlyTrue`; `testCommunityPhase1PinTypes_defaultParameter_matchesShippedFlag` legitimately kept its name — it never encoded a boolean, it encodes "matches whatever's shipped," which is still true post-flip).
- [x] Static test count unchanged at 1365 — re-counted independently via `git archive` on both `main` and the branch tip (`grep -c "func test"`), both 1365.
- [x] Launched-world sweep — grepped every file under `WeParkTests/` for `communityEnabled`; the only spots reading the *live* `AppConstants.communityEnabled` value directly (not via an explicit `true`/`false` parameter) are the 4 tests this PR already transforms, plus one tautological self-referencing assertion (`BlockDetailS13bTests.testDefaultParameter_usesRealFlag`, asserts `result == AppConstants.communityEnabled && true`) that passes under either flag value and correctly was NOT touched. No 5th test needed changing.
- [x] Seven-failure-class / banned-copy / no-`supabase` sweep on the touched files — see below.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None in the diff itself. One process-level item, logged below as out-of-scope, because it's a
pre-existing gap in the documentation trail, not a defect in this PR's code.

### 🟢 Minor / nit

- **#1: Stale comment in an unrelated but flag-adjacent test file, now inaccurate post-flip**
  - Where: `ios/WePark/WeParkTests/PushRegistrationServiceTests.swift:484` (NOT touched by this PR)
  - What: `makeAuthenticatedService()` injects `communityEnabledProvider: { true }` with a comment reading `"AppConstants.communityEnabled is hardcoded false on this branch — inject { true } here..."`. That comment is now false — the real flag is `true` on this branch too.
  - Expected: Comment should read something like "communityEnabled is now true in production too, but this DI seam still exists so these wire tests don't depend on the global flag's value at all."
  - Impact: Zero — the test doesn't assert on the real flag, it uses dependency injection, so nothing breaks. Purely a doc-accuracy nit that will confuse a future reader.
  - Repro: Read the file at the given line.
  - Owner: `@ios-engineer` (fold into the next PR that touches this file; not worth a standalone PR).

- **#2: One-hop-stale historical narrative comment**
  - Where: `ios/WePark/WeParkTests/CommunityPinServiceTests.swift:86-93` (NOT touched by this PR)
  - What: The file-header narrative documents the S3→S4 QA rename (`...excludesIneligibleTypes` → `...AndFlaggedTypes`) but doesn't (and can't, since it predates this PR) mention this PR's further rename to `testMergeablePinTypes_containsExpectedAndLaunchedTypes_excludesIneligibleTypes`.
  - Impact: None — this is explicitly a historical log the file already discloses is allowed to drift ("noted rather than silently left for a future QA pass to re-discover"), and the test name itself is unambiguous and correct.
  - Owner: no action required; noting for completeness only.

### 💡 Out of scope (logged, not fixed)

- **The drive-test gate narrative isn't independently documented anywhere I could find.** The
  roadmap (`docs/community-2.0-roadmap.md`) states the flip is gated on "the build-18 drive test
  proves Realtime solid on a moving car." The new doc comment in this PR instead frames the
  justification as "a week of field use on the flag-ON build 20 in NYC" and "Kevin ruled the
  drive-test gate satisfied on 2026-09-13." I could not find a corresponding entry in
  `field-testing-log.md` or `open-items.md` recording that specific drive test's outcome (the
  log's most recent drive-test entries are build-16-era, predating Community 2.0 entirely). This
  is very plausibly just an undocumented verbal ruling from Kevin (consistent with this repo's
  established pattern of Kevin's calls sometimes only showing up in a commit doc-comment) and is
  explicitly *his call to make*, not something this PR needed to re-litigate — I am not treating
  it as a defect in the code. Flagging only so the roadmap doc gets a matching update in the same
  spirit as the rest of this table (`docs/community-2.0-roadmap.md`'s own S14 row is meticulously
  updated after every gate; the LAUNCH row is conspicuously absent from that table as of this
  PR). Recommend a same-day or next-session docs commit adding the LAUNCH row, for the historical
  record — not a merge blocker.

## Per-file verification detail

**`Constants.swift`** — `communityEnabled` flips `false → true`; doc comment rewritten to past
tense, records build 22 / 2026-09-13 / "Kevin ruled the drive-test gate satisfied" / dark through
builds 18–21. Cross-checked build numbering: `CURRENT_PROJECT_VERSION` is untouched at `21` in
this PR (correct — the bump to 22 is a separate archive-time step per the standard ceremony, and
the doc comment forward-references it correctly rather than lying about the current build). Git
history of `project.pbxproj` shows an unbroken 1→21 sequential bump chain, consistent with "dark
through 18-21" (no skipped/reused build numbers).

**`Community2Phase1ModelTests.swift`** — Header inventory line updated (`Dark-ship flag (2
tests)` → `Launch flag (2 tests)`, test #22 renamed in the list to match the body). Two
transforms:
1. `testCommunityEnabled_defaultsFalse` → `testCommunityEnabled_launchedTrue`: `XCTAssertFalse` → `XCTAssertTrue`. Correct — it's asserting the constant's literal value, which is now `true`.
2. `testCommunityPhase1PinTypes_defaultParameter_matchesShippedFlag`: kept its equality assertion (`communityPhase1PinTypes() == communityPhase1PinTypes(enabled: communityEnabled)` — still valid, self-referencing) and changed the hardcoded expectation from `.isEmpty` to `XCTAssertEqual(..., [.openSpot, .leavingSoon])`. Verified against `AppConstants.communityPhase1PinTypes(enabled:)`'s implementation (`Constants.swift:182-184`: `enabled ? [.openSpot, .leavingSoon] : []`) — `true` returns exactly `[.openSpot, .leavingSoon]` in that order. Match confirmed.

**`CommunityPinServiceTests.swift`** — One test renamed and its two assertion blocks swapped:
`.openSpot`/`.leavingSoon` moved from the "must be excluded" list into the "must be included"
list, comment updated. Verified against `RealtimeMergeGate.computeMergeablePinTypes(communityEnabled:)`
(`baseMergeablePinTypes.union(AppConstants.communityPhase1PinTypes(enabled:))`) and the
production-facing `RealtimeMergeGate.mergeablePinTypes` (reads the real flag) — with the flag
`true`, both types are correctly unioned in. Match confirmed. The rename
(`...excludesIneligibleTypesAndFlaggedTypes` → `...excludesIneligibleTypes`) is the right call:
"flagged types" no longer exist as a distinguishable category once the flag is permanently true,
so keeping that suffix would be actively misleading.

**`ParkedCarDetailPhase4aTests.swift`** — `testDefaultParameter_usesRealFlag_currentlyFalse` →
`_currentlyTrue`, `XCTAssertFalse` → `XCTAssertTrue`. Verified against
`ParkedCarDetailLogic.shouldGateLeavingSoonPost(communityEnabled: Bool = AppConstants.communityEnabled,
identityGateShouldShow:)`, which delegates to `CommunityIdentityInterception.shouldShowIdentitySheet`
= `communityEnabled && identitySheetShouldShow`. With the default flag now `true` and
`identityGateShouldShow: true` passed explicitly, the result is `true`. Match confirmed.

## Smoke tests run

- `git diff --stat origin/main...origin/ios/community-launch-flip` — confirmed exactly 4 files touched, no 5th file, no `project.pbxproj`/`Info.plist`/`Config.xcconfig` in the diff.
- Full `git diff` read line-by-line (all 4 hunks) — no unrelated whitespace/formatting churn.
- Traced every transformed assertion back to the production function it exercises and hand-computed the expected boolean/array under `communityEnabled = true` — all 4 match the new assertions exactly.
- `git log --all -p -- Constants.swift | grep "communityEnabled = "` — confirmed the flag has literally never been `true` in git history before this commit (the "field use on flag-ON build 20" in the doc comment refers to a local, uncommitted sed-flip-for-TestFlight-archive ceremony documented at the roadmap's S12 row — `"TestFlight build 20 (Option B ceremony, archived from main@93cf963a+local flag flip, discarded after)"` — not a claim that the flag was ever committed `true` before now. Consistent, not a fabrication.)
- Independently re-counted the static test suite size on both `main` (`grep -c "func test"` across `WeParkTests/*.swift` = 1365) and the branch tip via `git archive` into a scratch directory (also 1365) — confirms the "no net test count change" claim without trusting the PR description.
- Grepped all 10 test files that reference `communityEnabled` anywhere (`BlockDetailS13bTests`, `Community2Phase1ModelTests`, `CommunityPinServiceTests`, `CommunityS13aTests`, `FT20StreamCTests`, `IdentitySheetTests`, `LongPressParkPopupTests`, `ParkedCarDetailPhase4aTests`, `PushRegistrationServiceTests`, `ReportSheetPhase2aTests`) — confirmed every other test in every other file calls the pure, parameterized decision functions (`shouldGateChatSend(communityEnabled:...)`, `mapMarkerTypes(communityEnabled:)`, `longPressPresentationMode(communityEnabled:)`, `showsStreetClosureTile(communityEnabled:)`, etc.) with an explicit literal `true`/`false`, never the bare default — so none of them are sensitive to the flip. The `RealtimeMergeGate` file's own `testComputeMergeablePinTypes_flagFalse/True_...` pair (pure, parameterized, both branches asserted explicitly) needed no change, correctly untouched.
- Checked `CURRENT_PROJECT_VERSION` in `project.pbxproj` (all 4 build-config blocks) = `21`, unchanged by this PR — consistent with the doc comment's build-22-at-next-archive framing rather than claiming build 22 already exists.
- Read `docs/community-2.0-roadmap.md` in full for the flag-flip prerequisite section and the session table through S14 — cross-checked the "4 named guards" list there (`testCommunityEnabled_defaultsFalse`, `testCommunityPhase1PinTypes_defaultParameter_matchesShippedFlag`, `testMergeablePinTypes_containsExpectedTypes_excludesIneligibleTypesAndFlaggedTypes`, `testDefaultParameter_usesRealFlag_currentlyFalse`) against this PR's 4 transformed tests by NAME — exact match, nothing missing, nothing extra.
- Checked `ContentView.longPressPresentationMode`/`communityMapChromeVisible`/`ZoneStore` fetch/push registration call sites — none are touched by this diff (correctly out of scope); traced that the flag-on `longPressPresentationMode` branch (`.parkConfirmCard`) is the path Kevin explicitly gated live at the S13c gate ("worked perfectly," 2026-09-11), not the untested legacy dialog.
- Grepped the 4 touched files for `supabase`/`apikey`/`eyJ`/hardcoded secrets — only pre-existing, unrelated test-fixture lines outside the diff hunks (fake `test.supabase.co` URL + fake anon key constant); nothing introduced by this PR.
- No live-UI build/sim smoke was run. This PR touches zero files in the mount-chain trigger list (`MapViewRepresentable.swift`, `ContentView.swift`, `Views/DriveMode*.swift`, `.safeAreaInset` sites) so the standard merge-blocking live-smoke rule doesn't technically fire on file-touch — but the flag flip changes RUNTIME behavior of those exact files without touching their source, which is precisely why the Mac gate below is written as effectively mandatory rather than a nice-to-have.

## What's working

- This is about as clean as a launch-flip diff gets: the engineer clearly budgeted for exactly
  the 4 known guard tests (per the roadmap's own explicit "budget it into the flip, don't discover
  it at launch" instruction from 2026-08-28) and didn't scope-creep into touching a single line of
  production code, chrome, or any other test file.
- The doc comment is well-written and historically honest — it doesn't retcon the dark-ship period, it explicitly says flag-off is "no longer a shipped state," which is the correct signal for anyone auditing old builds.
- Test naming discipline is good: the rename choices are all defensible (drop a suffix that stopped being true, keep a name that never encoded the boolean, add "_currentlyTrue"/"_launchedTrue" suffixes that read naturally).
- Independent recount confirms the "1365, no net change" claim rather than just trusting the PR description — it's correct.

## Mac gate checklist (for Kevin, before merge)

1. **Single suite run off the branch as-is — NO sed flip needed.** The flag is committed `true`. Expect **1365/1365**, full green, first try (this is a from-`false` baseline, so no "4 failures" bucket like previous gates — those 4 are exactly the tests this PR already fixed).
2. **Cold-launch smoke — community must be ON by default, no build flag needed:**
   - Report pill visible on the map (not gated behind long-press anymore).
   - "?" map-key legend button visible.
   - Long-press a spot → the slim `LongPressParkConfirmCard` (NOT the old 3-button dialog) appears.
   - Open the browse sheet to `.large` detent → crew feed renders with the 8-chip nearest-first zone picker (home-pinned) + "More" search sheet for the remaining ~33 zones (41-zone universe live since S14's migration 06 apply).
   - My Car detail (parked-car state) shows the Community sections: swept badge / away-note / garage-savings card / "Leaving in N min" button.
   - Report a spot → identity sheet triggers on first-ever contribution (show-once).
3. **Confirm the old flag-revert ritual is retired.** Every prior session's gate notes end with
   "flag reverted ✓" (S13c, S14) — that step no longer exists or applies now that `true` is the
   committed, permanent state. Future sessions should never need a local sed flip again; if a
   future PR's gate notes still mention reverting the flag, that's a process regression worth
   flagging.
4. **Two-device / Realtime sanity re-check is optional here** — it was already the S12 gate's job and isn't reachable-for-the-first-time by this PR; nothing in this diff touches Realtime wiring.

## Expected post-merge TestFlight sequence

1. Merge this PR to `main` (squash, standard process).
2. Bump `CURRENT_PROJECT_VERSION` 21 → 22 in a follow-up commit/PR (not bundled here — correctly separated, matches this repo's established build-numbering-is-its-own-step convention).
3. Archive build 22 from the post-bump `main` — this is the FIRST build where `communityEnabled = true` ships to a real device, no local flag flip involved (contrast with build 20's Option-B "local flip, discarded after" ceremony).
4. TestFlight internal group first (Kevin's own devices) — confirm the cold-launch smoke list above on hardware.
5. Promote to external TestFlight group once internal confirms clean — this is the actual "all TestFlight users" launch moment the task description refers to.
