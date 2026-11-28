# PR #225 (R35-1 stale goal window) QA Pass 1 - 2026-11-28

**Reviewed:** branch `ios/r35-pr1-stale-window` at `2161a9c6`, against `docs/specs/r35-map-polish-and-trip-destination.md` PR1 and `docs/field-testing-log.md` R35-1.
**Verdict:** PASS with follow-ups (no blocking findings)

## Summary
The goal window now advances. I watched it live on my own sim across a 5-minute boundary: "until 3:35 AM / 2 h 56 min from now" became "until 3:40 AM / 3 h from now", with no tap or pan, and the per-minute tick fired every minute on the wall-clock minute. Inside a cell the tick did zero rebuilds; at the cell flip it did one. Green honesty holds by construction and by my own fake-clock tests.

## Acceptance checklist
- [x] Label moves in 5-minute steps, countdown every minute, untouched app - live: ticks logged at 00:36:02, 00:37:04, 00:38:03, 00:39:02, 00:40:04; label 3:35 -> 3:40 at the 00:40 boundary (screenshots).
- [x] Inside a 5-minute cell the tick only writes state - live log: four minute ticks with no `rebuildOverlays` call between them; one rebuild (276 ms) at 00:40:04.
- [x] Green coloured for `[gridStart, end]` and never looser than the live window - code (`rebuildOverlays` uses `WPWindowClock.instant`, ends computed `from: instant`) + invariant tests.
- [x] Label, countdown and green agree - one instant feeds all three; countdown uses `max(live, instant)` so it can never exceed the window. Own test checks the parsed countdown against the end every minute.
- [x] A few hours stays between 2 h 55 and 3 h (except Overnight-capped) - own test, 3 goals x every minute.
- [x] Foreground after a long background / dead ticker heals - own tests (14 h background, 1 h idle) via the same `needsRecolor` logic; also `handleScenePhaseChange(.active)` calls `handleMinuteTick`. NOT driven live (the sim cannot background for an hour).
- [x] Midnight, Overnight 7:00 - own tests: 6:50 AM run, 31 Dec 20:00 -> 04:00 run.
- [x] Both DST days - own tests: 7 Mar 22:00 + 30 h and 31 Oct 22:00 + 32 h, every minute, 3 goals.
- [x] Clock set back / time zone changed - own tests: clock back 2 h heals on the next tick; device zone set to Asia/Kolkata (+5:30) leaves labels and grid unchanged (everything is ET-calendar based, grid is epoch based and ET offsets are whole hours). Hooks for `significantTimeChangeNotification` and `NSSystemClockDidChange` exist; not triggered live.
- [x] Trip: cache keyed on the plan, "Trip plan ended" uses the live clock - code + builder test. Not driven live.
- [x] No caller passes a stale `now` to the Stoop green: `rebuildOverlays` ignores its argument in Stoop and recomputes from the real clock. Callers with stale values (`handleSegmentsChanged`, region settle, selection) are therefore harmless for the goal path. See finding 1 for the one remaining path.
- [x] Flag off unchanged - full `WeParkTests` on this head with shipped flags: 3372 tests, 0 failures, 1 skipped. Legacy `Timer` path and `handleTimerTick` untouched when the flag is off.
- [x] Dry-run merge into latest `origin/main` (includes #223, #224, #226): clean auto-merge, no conflicts (not re-compiled after merge). #226 is already merged.

## Findings

### Minor
- **#1: the "no goal" path colours for `requestedNow`, not the real clock.** The builder says it "keeps the real instant". That is true for callers that pass a fresh `.nowET`, but `handleSegmentsChanged`, region settle and selection pass `lastEvaluatedAt`, which is now at most about 60 s old (it was unbounded before). Only reachable with the goal dock not owning the filter (full palette). Acceptable, since the tick refreshes it every minute; noting so the claim is accurate. `ContentView.swift` `currentStateKey` block.
- **#2: a cell flip costs one main-thread rebuild of about 280-310 ms in Midtown (1,759 segments).** It lands every 5 minutes, on the wall-clock boundary, regardless of whether anything changed colour (the signature guard only prevents the overlay swap). On a phone it may show as a small hitch. Not verified whether the swap was skipped at the 00:40 flip (my counter printed before the rebuild). Before this PR the rebuild happened on every pan/tile event anyway.
- **#3: legacy Drive Mode goal pill still counts "Now -> ..." from `lastEvaluatedAt`** (`goalPillContent`, `goalWindowLabel`) while the end comes from the grid instant; at most a 5-minute difference in the "tomorrow" wording around midnight. Not an honesty problem.

### Builder's deviations, as asked
- **Signature hashes polyline endpoints plus point count, not segment ids.** Two different polylines with the same count and endpoints would collide; for street segments this does not happen in practice, and the collision would only skip a repaint of a curb that kept its colour. Order-independent wrapping sum and `selectedState` mixing are fine. Accepted.
- **No clock-skew launch arg.** Not needed; I waited for a real boundary (cost me one 5-minute wait). Accepted.
- **No-goal path keeps the real instant:** see finding 1.

## Smoke tests run
- Own sim `wepark-qa225-sim`, Stoop and goal-dock flags flipped locally (never committed), location Penn Station, screenshots read: Overnight "until 7 AM, 6 h 24 min" at 00:36; tapped A few hours: "until 3:35 AM, 2 h 56 min from now" at 00:39:40 -> "until 3:40 AM, 3 h from now" at 00:40:20.
- Per-minute tick and rebuild log with a local `NSLog` (not committed).
- Own tests (`docs/qa/pr225-fake-clock-tests.swift.txt`, 9 tests, all pass): DST x2, New Year midnight, 7 AM Overnight flip, 1 h idle, 14 h background, clock back, time zone change, label step size. They simulate the tick logic with the real `WPWindowClock`, `ParkingGoals`, `WPGoalSheetInput`; they do not exercise SwiftUI.
- Full `WeParkTests`: 3372 / 0 failures.
- Merge dry-run vs `origin/main`: clean.

## What's working
The root cause fix is right: a `.task` loop survives the body re-evaluation that was starving the inline `Timer`. One window clock feeds the label, search count, picker and green, and the strict-superset rule makes "never greener than the live window" true by construction rather than by testing.

## What Kevin should check on a device
1. Leave A few hours open with the screen on for 20 minutes: the "until" time should step by 5 minutes and "from now" should drop every minute, without touching the screen.
2. Lock the phone 10 minutes, unlock: headline, countdown and green should be current at once.
3. Around 6:55-7:05 AM on Overnight: the end should flip to tomorrow 7 AM within a minute of 7:00.
4. Watch for a small hitch every 5 minutes on a dense block (finding 2).
