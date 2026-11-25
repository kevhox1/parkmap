# PR #197 QA: cached ET DateFormatter and memoized ASP suspension (Pass 1, 2026-11-25)

**Reviewed:** branch `perf/aspsuspension-dateformatter` (head `3467daf2`), base `origin/main` `0d0b78f9`.
**Verdict:** ✅ MERGE (no behavior change found; perf claims reproduce; cold-launch gain is real but noisy).

## Summary
The change caches two DateFormatters, memoizes `ASPSuspensionService.isSuspended` per UTC hour behind an NSLock, and hoists one ET-midnight computation. The overlay digest over 15k rows is byte-identical to main, the perf claims reproduce on my machine, and the DST/suspension-date tests pass. No blocking or significant issues.

## Acceptance criteria checklist
- [x] Cached ET date formatter is thread-safe: `DateFormatter.string(from:)` is documented thread-safe (iOS 7+); the static `let` initializes once (`swift_once`); the memo dictionary is guarded by `NSLock`; `suspensionsByDate` is an immutable `let`. Verified by reading. A concurrent stress test was NOT run (not verified dynamically).
- [x] Timezone/locale: ET formatter uses `.easternTime` (America/New_York), `en_US_POSIX`, Gregorian calendar, "yyyy-MM-dd", so keys always match asp-2026.json even on a non-Gregorian device calendar (old code used the device locale and calendar, so this is a small robustness gain). The clock formatter keeps `en_US`, `.easternTime`, "h:mm a" exactly as before.
- [x] DST edges: the memo key is `floor(epoch / 3600)`. New York's offsets (-5/-4) are whole hours, so every instant in one UTC hour is on the same ET calendar date; the memo is exact across both 2026 transitions. `testDateKeyMatchesReferenceFormatter_everyHourAcrossDST` (every hour 2026-03-01 to 12-31) and `testIsSuspendedMatchesReference_everyHour` passed.
- [x] Calendar still applies: `isSuspended` is true for 2026-12-08 at 00:00 and 23:59 ET and false for 2026-12-15 (test passed). Live app also showed "ASP Suspended Tomorrow, Thanksgiving Day" on 2026-11-25.
- [x] No behavior change: I ran the PR's `testOverlayDigest_dumpForBeforeAfterComparison` on both trees (the new test file was copied onto main, uncommitted, for this). 14,999 rows (3 times x 5,000 segments of `currentState`, two `isFree` goals, and label text); `cmp` reports the files byte-identical. Full suite on the branch also passes the existing ASP tests.
- [x] Perf claims (Debug sim, median of 10, my machine): currentState overlay pass 486 ms -> 131 ms (claim 453 -> 135); goal pass 331 ms -> 164 ms (claim 302 -> 158); `isSuspended` x20k 1,663 ms -> 6.4 ms (claim 1369 -> 7). Reproduced.
- [x] Cold launch to first map content (see below): faster on #197 in both paired runs, but the absolute numbers vary with simulator state.
- [x] Full WeParkTests on the branch: 2,958 passed, 2 failed, 1 skipped. Failures: `W7ToastServiceTests.testToastService_autoDismiss_clearsMessage` (12.7 s timing test, unrelated, passed on main and on the merge run) and `AmbientDrivingLookLocationPostureTests.testRestingFix_publishesAccuracy_withoutAnyDrivePosture` (also fails on `origin/main`; pre-existing flake).

## Cold launch, first map content (fresh erased simulator, Debug build, location pre-granted)
Measured by polling `simctl io screenshot` after `simctl launch`; "map" = first frame whose size jumps to the 1.4 MB map render (confirmed visually on the final frame of the first main run). Times are seconds from the launch command.

| Run | main | #197 |
|---|---|---|
| 1 | 46.9 | 38.3 |
| 2 | 35.0 | 26.2 |
| earlier single trial (different harness) | 18.7 | not valid (springboard captured) |

Average of the paired runs: main about 41 s, #197 about 32 s, roughly 9 s faster, consistent with the removed main-thread work, but simulator launch latency (the `launch` call alone took 3 s to 17 s) adds variance of the same order. The 15-60 s black period reported earlier is reproduced on main (first 8-30 s of frames are the ~70 KB black/launch frame). Treat the gain as directional, not exact.

## Findings

### 🔴 Blocking
- None.

### 🟡 Significant
- None.

### 🟢 Minor / nit
- **#1: unbounded memo growth.** `suspendedByHour` gains at most one entry per distinct UTC hour queried (about 8,800 per year of dates at most, tens of bytes each). Negligible, but a long-lived process asked about many future years grows without eviction. Owner: `@ios-engineer`, optional.
- **#2: memo assumes whole-hour UTC offset for ET.** True today and for any foreseeable tz rule; a comment already documents it. If `Calendar.easternTime` is ever swapped for a zone with a half-hour offset the memo would silently be wrong. Owner: `@ios-engineer`, optional.
- **#3: no concurrent-call test.** The thread-safety claim rests on documented API guarantees plus the lock; a short `DispatchQueue.concurrentPerform` test would pin it. Owner: `@ios-engineer`, optional.

### 💡 Out of scope (logged, not fixed)
- Curb polylines did not render in the live simulator at the launch zoom on main or this branch (separate from this PR).
- `W7ToastServiceTests` auto-dismiss test is timing-sensitive (12.7 s) and can fail under load.

## Smoke tests run
- Full WeParkTests on the branch: 2,958 passed / 2 failed / 1 skipped (failures above); on `origin/main`: 2,953 passed / 1 failed (Ambient posture flake) / 1 skipped.
- Perf and digest tests on both trees, results above. Timings written via the PR's own `WEPARK_TIMING_PATH`.
- Merge with #196: `git merge-tree` clean (both edit `ParkingRulesEngine.swift` in different regions). Full suite on a temporary merge commit: 2,971 passed, 2 failed (both Ambient posture, the known flake), parity test passed.
- Live launch on the iPhone 17 simulator: map, toolbar buttons, ASP banner and Park Until pill render (mount-chain files are untouched by this PR, so this was a sanity check only).
- `LocationServiceDriveCourseAccuracyTests` passed on main, #196, #197 and the merge; only the Ambient posture test fails intermittently, including on main.

## What's working
- The memo reasoning is correct and documented; the formatter fixes are minimal and keep output byte-identical.
- The PR ships its own before/after digest and DST sweep tests, which made the no-behavior-change claim cheap to verify independently.
