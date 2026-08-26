# iCloud Parked-Car Sync — QA Pass 1 — 2026-08-26

**Reviewed:** branch `ios/icloud-parked-car-sync` at `aa6ef084` (commits `6fdf7b8f` feature,
`1d2e5ca2` protocol-conformance fix, `aa6ef084` iCloud capability/entitlements), against
`docs/icloud-parked-car-sync-spec.md`.
**Environment:** Linux VPS. No Xcode, no simulator, no `xcodebuild`. 100% static review (full diff
read, execution paths traced by hand, `git merge-tree`/`git log` used to verify branch-vs-main
claims) plus Kevin's real-device evidence supplied in the task brief (full suite 860/0 on a real
device; solo smoke — park → delete app → reinstall → car restored — PASSED; cross-device
verification not performed, calendar-blocked).
**Verdict:** 🟡 **FIX-THEN-MERGE** (one process item to close, not a code defect) — see Findings.
No 🔴 blocking code defects found. The merge/tombstone/migration logic — the part the spec itself
named as the real risk — is implemented faithfully to spec and is well-tested.

## Summary

`ParkPinService`'s rewrite matches `docs/icloud-parked-car-sync-spec.md` almost line-for-line,
including the parts most likely to be gotten wrong: the envelope-level `updatedAt` comparator
(distinct from `car.parkedAt`), the `.cleared` tombstone (never an absent key), the
migration-as-a-single-pass-through-the-same-merge-function, and the three-publisher separation
(`firstPinDropped`/`pinDropped`/`remoteCarChanged`) that keeps a remote arrival from masquerading as
a local pin drop. The protocol-conformance fix (`1d2e5ca2`) is correct and narrow — the widened
`Data?` parameter has exactly one call site in production code (`writeEnvelope`), which always
passes non-nil `Data`, so the widening introduces no new nil-write path. The 28+2 new tests
genuinely exercise the state matrix (§3.3) — both migration-conflict directions, the tombstone
variant of migration conflict, stale/equal-timestamp no-ops, `AccountChange`, `QuotaViolationChange`,
corrupt data, and the notify-toggle propagation case via a second service instance — this is real
coverage, not a happy-path veneer. The one real gap I found is procedural, not a code bug: **this
branch was forked before FT-2 (`2a6084d9`) merged to `main`, so Kevin's reported "860 passed" test
run never included FT-2's code or its 12 tests in the same build.** No file-level conflict is
expected (verified via `git merge-tree`) and I don't consider this blocking, but it means the exact
combined state that will exist post-merge (~872 tests) has never been compiled or run once, and the
task's own framing that "main has only moved by a docs commit since" is incorrect.

## Acceptance criteria checklist

**Unit-testable (spec §5, AC-1 through AC-19):**

- [x] AC-1 — legacy `UserDefaults` key touched only by `load()`'s migration path — verified by
      `testLegacyKey_untouchedBySaveClearAndToggle` + `testLegacyKey_untouchedByApplyRemoteChange`.
- [x] AC-2 — fresh install, empty store, no legacy blob → no car — `testFreshInstall_emptyStoreNoLegacy_noCarOnLaunch`.
- [x] AC-3 — `firstPinDropped` once/install, `pinDropped` every save (regression) — 2 tests, both pass per Kevin's run.
- [x] AC-4 — `save()` writes `.parked` envelope with `updatedAt == car.parkedAt` — `testSave_writesParkedEnvelope_updatedAtEqualsParkedAt`.
- [x] AC-5 — `clearPin()` writes a tombstone, not an absent key — `testClearPin_writesTombstone_notAbsentKey`.
- [x] AC-6 — migration, legacy-only, key removed after — `testMigration_legacyOnly_becomesFirstEnvelope_legacyKeyRemoved`.
- [x] AC-7 — migration + conflict, both directions, plus a tombstone-newer variant not in the spec's own list (extra credit) — 3 tests.
- [x] AC-8 — `hasEverParkedKey` untouched by remote/migration paths, set only by `save()` — 4 tests.
- [x] AC-9 — remote `updatedAt <=` current is a no-op (stale AND equal-with-different-car cases) — 2 tests.
- [x] AC-10 — remote newer `.parked` updates `parkedCar` + fires `remoteCarChanged(newCar, oldCarID)` — `testApplyRemoteChange_newerParked_...`.
- [x] AC-11 — remote newer `.cleared` sets `parkedCar = nil` + fires the event — `testApplyRemoteChange_newerTombstone_...`.
- [x] AC-12 — `firstPinDropped`/`pinDropped` never fire from `applyRemoteChange()`, including `AccountChange` — 2 tests (the `AccountChange` one also exercises §0.2/OQ-2's "no special case" ruling).
- [ ] AC-13 — `activeSheet` never set to `.notificationRationale`/`.parkUntil` by `handleRemoteCarChanged` — **verified by code trace only, not by an automated test.** See Finding #2 — no `ContentViewTests.swift` exists anywhere in the suite (pre-existing project limitation, not introduced here), so this ContentView-level assertion the spec's own Work Stream 2 called for was never built.
- [ ] AC-14 — stale `.parkedCarDetail` sheet dismissed on a matching remote change — same caveat as AC-13, code trace only (`ContentView.swift:3346-3349`, matches spec §3.3.1/§0.3 exactly).
- [ ] AC-15 — `cancelAllThenSchedule`/`cancelAll(forUUID:)` invoked with correct ids on arrival/clear — the `NotificationScheduler` half is unit-tested directly (`testCancelAllForUUID_RemovesRequest`, `testCancelAllForUUID_DifferentUUID_DoesNotRemoveOtherRequests`); the ContentView-level wiring that calls them from `handleRemoteCarChanged` is code-trace-only, same caveat as AC-13/14.
- [x] AC-16 — `updateNotifyOnRestriction()` bumps `updatedAt`, propagates cross-instance — `testUpdateNotifyOnRestriction_bumpsUpdatedAt_propagatesAsRemoteUpdate` is the single best test in the file: it seeds a second `ParkPinService` with the pre-toggle car and proves the toggle wins via `updatedAt` alone, exactly the concrete case §0.1's ruling needed.
- [x] AC-17 — `QuotaViolationChange` handled without crash/partial write — `testApplyRemoteChange_quotaViolation_noCrashNoPartialWrite`.
- [x] AC-18 — representative envelope encodes well under 2 KB — `testSyncedCarEnvelope_encodedSize_staysUnderQuotaCanary`.
- [~] AC-19 — full suite passes. Kevin reports 860/0 on a real device. **Independently recomputed:
      this branch's own baseline is 830 pre-existing tests (not 842 — see Finding #1), + 30 new
      tests this PR adds (28 in `ParkPinServiceSyncTests.swift` + 2 in `NotificationSchedulerTests.swift`,
      not 18) = 860. The total matches, but only because the branch is missing FT-2's 12 tests that
      are already on `main` — the exact combined suite that will exist after merging into current
      `main` (842 + 30 = 872) has never been run.** See Finding #1.

**Device-only (spec §5, AC-20 through AC-24) — none performed, calendar-blocked, pre-accepted as a
post-merge follow-up per the task brief:**

- [ ] AC-20 — cross-device delivery timing. Not performed.
- [ ] AC-21 — remote clear cancels the other device's pending notifications + removes its pin. Not performed.
- [ ] AC-22 — third fresh-install device sees the synced car on first launch with `hasEverParkedKey` still unset. Not performed (the single-device equivalent, AC-8's `testHasEverParkedKey_untouchedByLoadRemoteOnlyPath`, is unit-tested and passes — same assertion, no real device).
- [ ] AC-23 — no double-fire of the W6 rationale sheet / W7.5 auto-prompt on a receiving device, live. Not performed (AC-12/13's unit tests are the single-device proxy for this).
- [ ] AC-24 — entitlement functional in an actual TestFlight-archived build, not just a debug build. Not performed — Kevin's solo smoke was a debug/Xcode-run build per the task brief, not confirmed as archive-distributed.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: This branch predates FT-2's merge to `main`; the reported test run and the task's own
  "main only moved by a docs commit" framing are both incorrect.**
  - Where: branch fork point. `git merge-base origin/main origin/ios/icloud-parked-car-sync` =
    `20e5648b`. `git log --oneline origin/main --not origin/ios/icloud-parked-car-sync -- ios/`
    returns exactly one commit: `2a6084d9` — **FT-2 "let a user delete their own community pin"
    (#90)**, an iOS feature commit (touches `CommunityPinService.swift`, `PinDetailSheet.swift`,
    adds `FT2DeleteOwnPinTests.swift` with 12 tests) that is live on `main` today but absent from
    this branch. `HANDOFF.md:206` confirms: *"main @ c29631bb+. One open PR: #91."* — `c29631bb` is
    well past FT-2. `HANDOFF.md:305` explicitly frames the two as one deliverable: *"BUILD 19 =
    iCloud parked-car sync + FT-2 delete-own-pin."* Commit timestamps show why this happened
    unnoticed: FT-2 merged 2026-08-24 15:36, sandwiched directly between this branch's feature
    commit (14:55 same day) and its fix commit (19:33 same day) — the branch was already cut when
    FT-2 landed.
  - What: Kevin's reported "860 passed / 0 failed" test run was performed on this branch as-is,
    which does not contain FT-2's code or its 12 tests. The arithmetic the task brief gave me ("842
    on main + 18 added by this PR — already reconciled, exact match") is coincidentally
    self-consistent (842 + 18 = 860) but describes a state that doesn't exist: this branch's actual
    pre-existing baseline is **830** (`docs/icloud-parked-car-sync-spec.md` §4 itself cites "830
    tests as of the 2026-08-24 changelog entry" for AC-19), and this PR actually adds **30** new
    tests (`grep -c "func test"`: 28 in `ParkPinServiceSyncTests.swift`, +2 new ones in
    `NotificationSchedulerTests.swift` — not 18). 830 + 30 = 860, matching Kevin's number, but only
    because the 12 FT-2 tests missing from this branch happen to numerically cancel out the 12 extra
    tests this PR added beyond the assumed 18.
  - Expected: the number reported as "full suite passing" should reflect the state that will
    actually exist on `main` after this PR merges, i.e. `main`'s current 842 (830 + FT-2's 12) plus
    this PR's 30 = **872** — not 860.
  - Impact assessment: I ran `git merge-tree 20e5648b origin/main origin/ios/icloud-parked-car-sync`
    (three-way merge simulation) and it produces **no `CONFLICT` markers** — FT-2 touches only
    `CommunityPinService.swift`/`PinDetailSheet.swift`/its own new test file, entirely disjoint from
    this PR's five touched files (`ParkPinService.swift`, `ContentView.swift`,
    `NotificationScheduler.swift`, `SyncedCarEnvelope.swift`, the entitlements/pbxproj pair). So the
    *merge itself* is mechanically safe and very unlikely to break either feature. This is why I'm
    not blocking on it — but it means nobody has actually compiled and run the combined 872-test
    suite even once, and the "exact match" reconciliation given to QA was accepted at face value
    when it should have been checked against the branch's actual fork point.
  - Repro: `git merge-base origin/main origin/ios/icloud-parked-car-sync` →
    `git log --oneline origin/main --not origin/ios/icloud-parked-car-sync -- ios/` on the result.
  - Owner: `@ios-engineer` (rebase or merge `main` into the PR branch, or just let GitHub's merge
    button do it since there are no conflicts) + Kevin (one more `xcodebuild test` run — expect
    872/0 — after the branch actually contains both FT-2 and iCloud sync, before calling build 19
    done). This is the one thing that must happen before merge, hence FIX-THEN-MERGE rather than a
    clean MERGE — but it's a rebase-and-rerun, not a code fix.

- **#2: Spec's Work Stream 2 asked for ContentView-level tests of the remote-arrival wiring; none
  exist, and the gap isn't called out anywhere in the PR description.**
  - Where: `docs/icloud-parked-car-sync-spec.md` §4, Work Stream 2 row: *"Tests: mock-driven
    assertions that `remoteCarChanged` never triggers `.notificationRationale`/`.parkUntil` and that
    `firstPinDropped`/`pinDropped` never fire from `applyRemoteChange()`."* The second half
    (`ParkPinService`'s own publishers) is well covered
    (`testApplyRemoteChange_neverFiresFirstPinDroppedOrPinDropped`). The first half — that
    `ContentView.handleRemoteCarChanged` itself never sets `activeSheet` to `.notificationRationale`
    or `.parkUntil` (AC-13), that it dismisses a stale `.parkedCarDetail` sheet (AC-14), and that it
    calls the right `NotificationScheduler` method with the right ids (AC-15) — has zero automated
    coverage.
  - What: I confirmed (`grep -rn "handlePinDropped\|handleRemoteCarChanged" ios/WePark/WeParkTests/`,
    and a search for any `ContentView(` construction in the test target) that **no
    `ContentViewTests.swift` file exists anywhere in the project, on `main` or this branch** — this
    is a pre-existing limitation (nothing in `ContentView.swift`, including the already-shipped
    `handlePinDropped`, has ever been unit-tested), not a regression this PR introduced. I traced
    `handleRemoteCarChanged` by hand (`ContentView.swift:3312-3349`) and it matches the spec's §3.5
    pseudocode exactly: never touches `activeSheet` with `.notificationRationale`/`.parkUntil`,
    dismisses `.parkedCarDetail` only when `shown.id == oldCarID`, calls
    `cancelAllThenSchedule`/`cancelAll(forUUID:)` correctly. So I have high confidence the code is
    right — but "I traced it by hand and it looks right" is exactly the kind of unverified-but-stated
    confidence this role exists to flag rather than silently accept.
  - Expected: either the tests get built (likely infeasible without a SwiftUI test harness this
    codebase doesn't have — same constraint that made `handlePinDropped` untestable before this PR),
    or the PR description explicitly states the omission and why, the same way it explicitly flagged
    the `SyncedCarEnvelope: Equatable` deviation from the spec's literal snippet. It did the latter
    for one deviation and not this one.
  - Repro: `git ls-tree -r origin/ios/icloud-parked-car-sync --name-only | grep WeParkTests` — no
    `ContentView*Tests.swift` entry.
  - Owner: `@ios-engineer` — not a code fix, a documentation fix (state the limitation explicitly in
    the PR description / spec's own AC-13–15 checkboxes) so a future reader doesn't assume test
    coverage that doesn't exist. Not blocking given it's consistent with existing project practice.

- **#3: Spec §0 named three product decisions (OQ-1 `updatedAt`-as-comparator, OQ-2 `AccountChange`
  handling, OQ-3 dismiss-not-refresh) as things that "don't block starting the code — they block
  *merging* it," each needing "a one-line yes" from Kevin. I could not find a recorded yes.**
  - Where: `docs/icloud-parked-car-sync-spec.md` §0 (items 1–3) and §6 (OQ-1 through OQ-3,
    restated with recommendations). Searched `HANDOFF.md` and `docs/open-items.md` for any entry
    resolving these — found none (`grep -n "OQ-1\|OQ-2\|OQ-3\|updatedAt.*ruling\|AccountChange"`
    against both files turns up only unrelated OQ-numbered items from other features).
  - What: the code implements all three of the spec's own *recommended* defaults (envelope-level
    `updatedAt`, `AccountChange` treated identically to a normal remote update, dismiss rather than
    live-refresh on a stale detail sheet) — I have no disagreement with any of the three choices on
    the merits, and they're all defensible, low-risk defaults. The gap is procedural: the spec
    explicitly gated *merging* (not building) on Kevin answering these, and I can't find where that
    happened.
  - Expected: a one-line confirmation from Kevin (could be as simple as "yes to all three,
    recommendations are fine") recorded somewhere before merge, per the spec's own stated gate.
  - Impact: low — these are the kind of decisions where "ship the sensible default and revisit if
    wrong" costs little, and OQ-2/OQ-3 are both narrow edge cases per the spec's own words. Flagging
    because the spec author built in an explicit checkpoint here and skipping it silently is exactly
    the pattern this project's own docs (`docs/open-items.md`'s cited guidance on migration
    decisions) argue against normalizing.
  - Owner: Kevin (one-line answer) — trivial to close, shouldn't block merge on its own if Findings
    #1 and #2 are otherwise acceptable, but worth a beat before hitting merge.

### 🟢 Minor / nit

- **#4: `WePark.entitlements` includes an empty `com.apple.developer.icloud-container-identifiers`
  array.** Enabling only "iCloud → Key-value storage" via Xcode's Signing & Capabilities UI
  (the exact step spec §4 Work Stream 0 prescribes for Kevin) typically does not emit this key at
  all when no CloudKit/Documents container capability is also checked — its presence as an empty
  array suggests the file may have been hand-authored rather than produced by clicking through the
  capability checkbox. Functionally inert (an empty array declares no containers, so nothing is
  exposed or misconfigured) and de-risked by Kevin's real-device solo smoke passing (which requires
  `CODE_SIGN_STYLE = Automatic` to correctly provision the entitlement end-to-end, confirmed present
  in both Debug and Release build settings) — not asking for a change, just noting the file's
  provenance doesn't obviously match "Kevin clicked the checkbox in Xcode" as the spec assumed.
- **#5: `SyncedCarEnvelope` deliberately drops `Equatable`, deviating from the spec's own illustrative
  code snippet in §3.1.** This is the one deviation the PR description/file-header comment *does*
  flag explicitly and justify well (adding `Equatable` would require also conforming `ParkedCar`,
  a file the spec named out of scope) — calling it out here only as a positive contrast to Finding
  #2/#3's silent gaps, and confirmed via grep that no call site anywhere actually needs `==` on a
  full envelope (every comparison in the diff is field-by-field: `.updatedAt`, `.kind`, `.car?.id`).
  No action needed.

### 💡 Out of scope (logged, not fixed)

- **AC-20 through AC-24 (cross-device delivery, third-device first-launch, live no-double-fire
  confirmation, archived-build entitlement verification)** — genuinely require two physical devices
  signed into the same Apple ID, calendar-blocked per the task brief (Kevin out of NYC 1–2 weeks
  without his second phone). Per spec §7's own honest framing, this residual is real but narrower
  than a typical UI-only bug class, because the merge/tombstone/migration logic that's actually hard
  to get right is fully covered by the mock-store unit tests (verified above) *before* any device is
  involved. I agree with not blocking merge on this, matching the spec's own stated fallback plan for
  "if Kevin does not have a second device available" — but the feature's actual user-facing promise
  (§1: "I pick up my iPad later and my car is still there") remains unverified until that round
  happens. Track it as a hard-required follow-up, not a nice-to-have.
- **No user-visible sync indicator, no settings toggle to disable sync, no live-refresh of
  `ParkedCarDetailView`, no "authoring device" concept for reminders** — all explicitly out of scope
  per spec §2/§9, correctly absent from this diff.
- **Privacy check:** confirmed nothing in this diff creates a Supabase/network write path for
  parked-car data — no file in the diff references `supabase`, and `ParkedCar.swift` itself is
  untouched. `NSUbiquitousKeyValueStore` is Apple-account-private (not shared across a Family Sharing
  group by default, per the spec's own §9 note), consistent with `HANDOFF.md`'s 2026-08-24 standing
  privacy rule that personal-location data (parked car) must stay private — this feature does not add
  a new exposure surface, it only changes *where* the still-private data lives (device →
  per-Apple-ID iCloud KVS). No RLS/schema change needed or made — correct, this is client-only per
  spec §3.

## Smoke tests run

This is a Linux-VPS-only static review — no build, no simulator, no live app on my end. What I
actually did:

- Read `docs/icloud-parked-car-sync-spec.md` in full (all 619 lines) before touching the diff.
- Read the full diff of all 8 changed files across all 3 commits
  (`git diff origin/main...origin/ios/icloud-parked-car-sync --stat` and per-file diffs), not just
  the PR/commit descriptions.
- Traced `ParkPinService.load()`'s migration branch by hand against the spec's own pseudocode
  (§3.6) line by line — implementation matches exactly, including the tie-break-favors-legacy
  edge case and the "always remove the legacy key regardless of which side won" invariant.
- Traced `applyRemoteChange(reason:)` for every `reason` value spec §3.1 names
  (`ServerChange`/`InitialSyncChange`/`AccountChange`/`QuotaViolationChange`/nil) and confirmed the
  strictly-greater-than guard, the tombstone-vs-absent-key distinction, and that `firstPinDropped`/
  `pinDropped`/`hasEverParkedKey` are never touched — all correct per code and per the corresponding
  unit tests.
- Verified the `1d2e5ca2` protocol-widening fix has exactly one call site
  (`writeEnvelope`'s `cloudStore.set(data, forKey:)`, where `data` is always non-optional `Data`
  from `try JSONEncoder().encode(...)`) — grepped for every `.set(` call against the protocol type
  and found no second call site, so widening `Data` → `Data?` introduces no new nil-write path
  (Focus Area 1, resolved clean).
- Traced `ContentView.handleRemoteCarChanged` (`ContentView.swift:3312-3349`) against spec §3.5's
  own code sketch — matches almost verbatim, including the `previousCarID` bookkeeping fix and the
  `parkUntilMode` cleanup on remote clear. Confirmed `.onReceive(parkPinService.remoteCarChanged)`
  is wired parallel to the existing `pinDropped` receiver and `performLaunchSetup()` (the `.task {}`
  body) calls `parkPinService.load()` before anything else, consistent with the existing
  `firstPinDropped`/`pinDropped` lifecycle pattern.
- Confirmed `SyncedCarEnvelope.swift` and `ParkPinServiceSyncTests.swift` (both new files) are
  correctly picked up by the build despite having no explicit `PBXBuildFile`/`PBXFileReference`
  entries in `project.pbxproj` — this project uses `PBXFileSystemSynchronizedRootGroup` for both
  `WePark/` and `WeParkTests/` (Xcode 16+ synced folders), so new files under those roots are
  auto-included; verified by reading the pbxproj's `PBXFileSystemSynchronizedRootGroup` section
  directly rather than assuming.
- Read all 570 lines of `ParkPinServiceSyncTests.swift` and the 56-line addition to
  `NotificationSchedulerTests.swift` — confirmed real state assertions against `service.parkedCar`/
  `service.currentUpdatedAt`/publisher output through a real in-memory `MockUbiquitousStore`, not
  mock-internals assertions. Independently counted `func test` occurrences (28 + 2 = 30) rather than
  trusting the "18 new tests" figure given in the task brief — this is what surfaced Finding #1.
- Ran `git merge-base`, `git log --oneline origin/main --not origin/ios/icloud-parked-car-sync -- ios/`,
  and `git merge-tree <merge-base> origin/main origin/ios/icloud-parked-car-sync` to independently
  verify the task brief's claim that "main only moved by a docs commit since" — found this false
  (FT-2, an iOS feature commit, is on `main` and not on this branch) but confirmed the eventual merge
  is textually conflict-free.
- Grepped for `supabase`/network write paths in every changed file — none found, consistent with
  spec's "iOS-only, no backend" claim.
- Confirmed `ParkedCar.swift` is unchanged (`git diff origin/main...origin/ios/icloud-parked-car-sync -- ios/WePark/WePark/Models/ParkedCar.swift` — empty), matching spec §3's "Not touched" file list.
- Checked `Date+ET.swift`'s `nowET` (used for the tombstone/toggle `updatedAt` bump) — it's a plain
  `Date()`, TZ-neutral absolute instant, so the last-write-wins comparator is immune to DST/timezone
  edge cases (Comparable on `Date` compares raw instants, not calendar-derived components).
- Did **not** build, compile, run tests, or launch a simulator — no toolchain in this environment.
  This PR does touch `ContentView.swift`, which is normally a mount-chain-PR class requiring a live
  simulator screenshot per this project's QA protocol — I could not perform that gate from this
  environment. I rely on Kevin's real-device evidence (solo smoke: park → delete app → reinstall →
  car restored — PASSED) for functional confirmation, but that smoke does not specifically exercise
  or screenshot the toolbar/overlay layer; this PR adds no new visible UI (per spec §2, "no new UI"
  is an explicit constraint), so the toolbar-rendering risk this gate normally targets is largely
  inapplicable here, but I'm stating the gap plainly rather than implying I checked it.

## What's working

- The hardest part of this feature — the merge/tombstone/migration state machine (spec §3.3's
  8-case matrix) — is implemented exactly as spec'd and tested more thoroughly than the spec's own
  AC list required (the migration+tombstone-conflict test and the two-instance notify-toggle
  propagation test both go beyond the letter of AC-7/AC-16).
- The three-publisher separation (`firstPinDropped`/`pinDropped`/`remoteCarChanged`) correctly
  prevents the exact trap the spec's §3.5 exists to name — a remote arrival cannot masquerade as a
  local pin drop and misfire the W6 rationale sheet or the W7.5 auto-prompt. This is verified both
  by direct unit test and by hand-trace of the `ContentView` wiring.
- The protocol-conformance fix (`1d2e5ca2`) is a clean, minimal, correctly-scoped fix for a real
  compile failure Kevin's own `xcodebuild test` run caught — exactly the kind of iteration this
  project's process is supposed to produce, and its doc comment correctly explains *why* a future
  call site must never pass `nil`.
- `ParkPinService` previously had zero test coverage; this PR both rewrites the storage backend and
  builds the regression net for the unchanged local behavior at the same time, as the spec asked —
  the "regression, not rewrite" claim for `save()`/`clearPin()`'s local behavior is backed by real
  tests, not just a comment.
- Privacy posture is correct and unchanged in kind: this feature moves where already-private data
  lives (device UserDefaults → per-Apple-ID iCloud KVS), adds no new exposure surface, and no
  Supabase/network write path — consistent with `HANDOFF.md`'s standing privacy rule for
  personal-location pins.
