# PR #213 Stoop island time-to-go QA, 2026-11-26

**Reviewed:** `fix/stoop-5b-island-timetogo` @ `5680ba7e` (base `4972c73e`), also merged with #214 onto main `6283cc6a` (clean merge). Source findings: pr211 / pr210 QA.
**Verdict:** MERGE-WITH-FOLLOWUPS (flag defaults off; nothing blocking)

## Summary
The island and lock screen time-to-go layouts now fit and show all three buttons, verified LIVE on a real activity (load had dropped under 40). The passed-custom-time logic is correct and tested; one pre-existing rounding edge (below) can still put a sent time up to 2.5 min in the past. Combined merge: 3182 tests, 1 skipped, 0 failures; all four schemes build.

## Checklist
- [x] Island time-to-go (LIVE, `-wp5bActivity real-timetogo`, flag on, iPhone 17 Pro sim): "Still leaving? / Bodega Cat is waiting" with one row of three pills, Leaving now (taxi) / 5 more min / Not leaving, nothing clipped, expanded height about 148 pt (<160). Pills are 48 pt tall (>=44).
- [x] Island counting (LIVE, `real`): title, timer, "Leaving around 7:06 AM", Leaving now + Not leaving, fits. (Counting intentionally has no "5 more min"; unchanged.)
- [x] Island ended (LIVE, `real-ended`): "Pass ended / Bodega Cat stopped waiting. Nothing to do." wraps to two lines, no truncation, fits.
- [x] Lock screen time-to-go at AX5 (LIVE, sim content size accessibility-XXXL): header + three pills all visible, "Leaving now" / "5 more min" / "Not leaving" fully legible, card well under 160 pt.
- [x] Buttons are the real intents: `wrap(.leavingNow/.fiveMore/.notLeaving, ...)` is the same wrapper used before (LeavingNowIntent / NotLeavingIntent); only layout changed. Not tapped live.
- [x] Passed custom time: `WPPassLogic.resolvedChoice` -> `.now`, polled every 5 s in the choosing view; sheet ticks every 5 s and re-checks `stillOffered` at tap. 3 new tests pass.
- [x] Clip `reminderOnly` copy: `fixedSize` + header capped at xxxLarge; builder's AX5 screenshot shows all three sentences wrapping in full with the page scrolling and buttons visible. Not re-run live by me.
- [x] Flag-off unchanged: `StoopFlag` false; edits are in Stoop views, `WPClipParts` header (Stoop-only clip parts), a pure helper, DEBUG showcase.
- [x] DEBUG: `-wp5bActivity real-*` lives in `WPPhase5bActivityShowcase.swift` wrapped in `#if DEBUG`; its ContentView call site is inside the existing `#if DEBUG` block.

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1: A just-passed custom time can still be sent up to 2.5 min in the past (pre-existing, narrowed by this PR).** `Shared/SpotPass/Driver/LeaveChoice.swift:49-60` `leaveAt(from:)` for `.custom(picked)` with `picked <= now` does `roundToFiveMinutes(max(picked, now))`, which rounds to the NEAREST 5 min, so it can land before `now`; the doc comment says "Always within [now, latest]". The 5 s poll makes the window tiny (a send inside the 5 s tick gap), and the screen resolves to Now otherwise. Suggest `ceil` for the `.custom`/past case or clamp `max(rounded, now)`. Owner `@ios-engineer`.
- **#2: Lock/island pills use fixed 15 pt with 0.7 scale floor.** At AX5 on the lock screen the labels still fit (verified), so no action; flagging only that the island does not honor AX type (system limit) and was not tested beyond default size.

### Out of scope
- None new.

## Smoke tests run
- Merge of #213 + #214 onto origin/main (6283cc6a) on a throwaway branch: clean, no conflicts.
- All four schemes (WePark, WeParkClip, ClipLiveActivities, WeParkLiveActivities) build, Debug, own derivedData.
- Full WePark suite `-parallel-testing-enabled NO -jobs 4`: 3182 tests, 1 skipped, 0 failures (no known flake tripped).
- Live (flags on locally, reverted, `git status` clean): island time-to-go, counting, ended; lock screen time-to-go at AX5. Screenshots read and inspected. Not run live: sent / passed / thanks / cancelled states (builder shows them in `docs/qa/assets/stoop-island-timetogo/`).
- Release-binary `strings` check not run; DEBUG gating verified by reading.

## What's working
- One 48 pt row is a clean fix: island and lock layouts both fit with the taxi primary kept first.
- Found-and-fixed extras (island sub line truncation, clip header mid-word break) were real.
- Good pure-logic extraction and tests for the stale-slot behavior.

**MERGE-WITH-FOLLOWUPS** (finding #1 is a small hardening, not a blocker)
