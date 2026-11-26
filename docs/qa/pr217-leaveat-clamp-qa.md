# PR #217 QA: LeaveChoice.leaveAt never before now (2026-11-26)

**Reviewed:** `fix/leaveat-clamp` at `66889b72`, also merged with #218 onto origin/main `7d09b992` (throwaway local branch, no merge pushed).
**Verdict:** MERGE

## Summary
`min(max(rounded, now), ceiling)` for `.custom` and `.minutes` is correct and minimal. The ceiling (`floor5(now+239m)`) is always greater than `now`, so the clamp can never invert. The result is inside the server window and the new tests fail without the fix.

## Checks
- [x] Diff read: `.now` unchanged (returns `now`); `.minutes` and `.custom` clamp to `>= now`; ceiling still applied last. `latest(from:)` > `now` always, so no min/max inversion.
- [x] Both consumers covered: `Shared/` is compiled into the app and the clip. App path `ios/WePark/WePark/Services/SpotPass/Driver/DriverFlowController.swift:323`; clip path `ios/WePark/Shared/SpotPass/Driver/ClipFlowController.swift:263` (and `Clip/ClipRootViewV2.swift:149`, display only). Both call the same function with `startedAt`.
- [x] Server: `supabase/13-spot-handoffs.sql:634` rejects `leave_at` outside `[now-10min, now+240min30s]`. The clamped value is in `[now, floor5(now+239m)]`, inside. `supabase/functions/_shared/handoff.ts:70-72` only validates ISO parse. The server rounds to nearest 5 and caps (line 649); a server re-round of an unrounded `now` can land up to 2.5 min before server now, well inside the 10-min tolerance. No server change needed.
- [x] Mutation: reverted `LeaveChoice.swift` to main; 4 of 5 `LeaveChoiceClampTests` fail (`alreadyPassed`, `nearestMarkIsBeforeNow`, `minutes_small`, `acrossOffsets`). The 5th (`future_stillRoundsToFiveMinutes`) is a regression guard and correctly passes both ways.
- [x] 4 scheme builds on the combined merge (WePark, WeParkClip, ClipLiveActivities, WeParkLiveActivities): all succeed.
- [x] Full WePark suite, `-parallel-testing-enabled NO -jobs 4`, combined merge: 3210 tests, 1 skipped, 0 failures. No known flake tripped.

## Findings
### Blocking
none
### Significant
none
### Minor
- `leaveAt(from: startedAt)` uses flow start, not send time; a slightly stale `now` is covered by the server's 10-min lower tolerance. Pre-existing, not a regression.
- File header comment could mention "never before now". Cosmetic.

## Smoke
Pure function change; no mount-chain files touched. Live handoff flow not driven (needs a real token); verified by reading, server bounds, and unit tests.

## Verdict: MERGE
