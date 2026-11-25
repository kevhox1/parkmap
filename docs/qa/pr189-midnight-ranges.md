# PR #189 Midnight Ranges + AX5 QA Pass 1 - 2026-11-24

**Reviewed:** branch `fix/midnight-ranges-and-ax5` at `0a9a6535`, against the PR description and `docs/qa/pr188-mycar-v2.md` finding 1
**Verdict:** MERGE (one follow-up note, nothing blocking)

## Summary
The root cause is real and the fix is correct. The shared `TimeRange` semantics (end 0 = 24:00 same day, `0 < end <= start` wraps, the tail follows the previous day's membership) are consistent across every engine caller. I ran the pre-PR (main) and PR engines side by side over the real bundled tiles. Every one of the 669 isFree/goal changes in the sample went green to red, which is the safe direction, and every one of them is on a segment with a midnight-touching range. The 7,605 `currentState` changes have the same cause. Three of them go the other way (red to orange, 1 segment), explained below. CI is green.

## Acceptance criteria checklist
- [x] Root cause matches the description. `meteredStatus` and `currentState` used `minute >= start && minute <= end`, so {540, 0} was never active. Verified by reading the diff, then confirmed empirically: on main, 1,725 segments are `freeComfortably` at Tue 10:42 PM that the PR flips to `meteredActive`.
- [x] Shared semantics in `ParkingRule.swift` are correct. Hand-checked the edge cases: {0,0} is the whole day (same as before), start == end wraps (same as before), and 9AM-midnight does not wrap.
- [x] `meteredStatus`, `currentState`, `isScheduleActive`, `isFree`/`timeRangeOverlaps` and the My Car `meterUntil` all go through `rangeActive` / `endMinute`.
- [x] Missed callers audited. I grepped every `tr.start/end` and `range.start/end` use:
  - `computeHoursUntilASP` builds the end on `nextMidnight`, so end 0 resolves to the next day's 00:00 and is correct by construction.
  - `computeHoursUntilActive` is start-based and unaffected.
  - `ClipBlockInsight` uses `end <= start` then `+24h`, which is correct for end 0.
  - `BlockDetailView` and `formatMinutes` only format text.
- [x] Half-open boundaries. `timeRangeOverlaps` still uses `rStart < windowEnd && rEnd > windowStart`, so leaving exactly at a restriction start stays allowed, and a window that starts exactly at a range end has no overlap.
- [x] DST. `timeRangeOverlaps` now uses `date(byAdding: .day)` for the next midnight instead of `+24h`, so it is more correct. Both DST nights (2026-10-31 and 2027-03-13, 10:42 PM) are in the dataset below. They show the same metered flips as ordinary Saturdays and no unexplained changes.
- [x] ASP and `dayOffset == -1`. The previous-day pass only contributes `wrapsPastMidnight` ranges. Empty-range rules are skipped for offset -1. Suspension is checked against the anchor (previous) day, which is the right semantic.
- [x] Copy and AX5 changes were read in the diff (`nonBreakingMeridiem`, chip grid, `leavingSoonMinutesLeft`, "Next:" naming). Not verified live, see Smoke tests.
- [x] CI: `gh pr checks 189` shows `Build and XCTest (Xcode 26)` pass (8m28s).

## Findings

### Blocking
None.

### Significant
None.

### Minor / nit
- **#1: Copy inconsistency, "paid until 12am" vs "meter until midnight".**
  - Where: `ParkingRulesEngine.formatMinutes` (used by `meteredStatus` / `safetyLabel`) vs `MyCarSheetV2Logic.clockOrMidnight`.
  - What: the hero label reads "paid until 12am" and the My Car line reads "meter until midnight". `MidnightRangesTests` pins "paid until 12am" on purpose.
  - Expected: the same word in both places. A bare "12am" reads like the start of the next morning, which is the ambiguity the PR already fixed in the My Car copy.
  - Owner: `@ios-engineer`. Follow-up, not a blocker.
- **#2: `nonBreakingMeridiem` is a blind " AM" / " PM" replace.**
  - Where: `ParkingGoals.nonBreakingMeridiem`.
  - What: it would also touch any word that starts with " AM" or " PM" (for example " AMBULANCE"). Current inputs are only date/time labels, so there is no live impact.
  - Owner: `@ios-engineer`, nit.

### Out of scope (logged, not fixed)
- **Tile data defect, pre-existing.** Some rules that read "ALL DAYS" have `days: [0]`. Examples are `3RD_AVENUE_EAST_34TH_STREET_EAST_35TH_STREET_E_0` and `COLUMBUS_AVENUE_WEST_93RD_STREET_WEST_92ND_STREET_W_0` (truck loading 7PM-7AM / 10PM-6AM). Because the tail follows the anchor day, those segments are restricted at Mon 00:30 (Sunday's tail) but not at Tue/Wed 00:30. This is a tile-pipeline day-parse problem, not an engine one.
- Several taxi-stand SPECIAL rules store only the weekday part ("MON-FRI 6PM-2AM, SAT & SUN ALL DAY" becomes days [1..5]).

## Red to green / more permissive cases (the flagged class)
Across the full dataset, **zero isFree/goal results went red to green**. In `currentState`, two cases moved toward less restrictive, both at Mon 00:30 and both the correct reading of the sign:
1. `WEST_31ST_STREET_5TH_AVENUE_BROADWAY_N_1` went from `restrictedNow` to `freeButRestrictionSoon`. The SPECIAL taxi stand is "MON-FRI 6PM-2AM", days [1..5]. Main treated the 12-2AM tail as belonging to Monday's own membership. The tail belongs to Sunday, which is not in `days`. The weekend-all-day part of the sign is lost in the tile data (see Out of scope). The more restrictive-looking old answer was right only by accident.
2. The same class (anchor-day tail attribution) explains the other Mon 00:30 / Wed 00:30 movers.

In the opposite direction, 11 + 1 + 1 segments became more restrictive (free or orange to `restrictedNow`) at Mon/Wed 00:30 via previous-day spill. Examples: Sunday's truck-loading tail, Tuesday's 8AM-5AM truck loading.

## Before/after quantification
Method: a throwaway XCTest (not committed) ran on the iOS 26.5 simulator against main (`17a49258`) and the PR head, using the real bundled tiles.
- `currentState` for **all 47,209 segments** at 13 time points: Tue 9:30 AM, Tue noon, Tue 6:59 PM, Tue 10:42 PM, Tue 11:59 PM, Wed 12:30 AM, Sun noon, Thu 11/26 10 AM (a suspension day), Sat 11:30 PM, Mon 12:30 AM, Sat 10 AM, and DST fall-back and spring-forward Saturdays at 10:42 PM.
- `isFree` (1 minute and 1 hour windows) and all three goals (Overnight, A Few Hours, Park & Forget including rung) for **1,400 segments** at the same 13 time points: 700 uniform random, and 700 from the 2,906 midnight-touching segments (47,209 total in the tiles). That is 84,760 comparisons.

`currentState` changes: 7,605 of 613,717 (1.2%).

| Time | Change | Segments |
|---|---|---|
| Tue 10:42 PM | freeComfortably to meteredActive | 1,725 |
| Tue 11:59 PM | freeComfortably to meteredActive | 1,725 |
| Tue 6:59 PM | freeComfortably to meteredActive | 1,225 |
| Sat 11:30 PM | freeComfortably to meteredActive | 736 |
| DST fall-back Sat 10:42 PM | freeComfortably to meteredActive | 736 |
| DST spring-forward Sat 10:42 PM | freeComfortably to meteredActive | 736 |
| Sat 10 AM | freeComfortably to meteredActive | 192 |
| Tue noon | freeComfortably to meteredActive | 176 |
| Thu (suspension day) 10 AM | freeComfortably to meteredActive | 176 |
| Tue 9:30 AM | freeComfortably to meteredActive | 164 |
| Mon 12:30 AM | freeComfortably to restrictedNow | 11 |
| Mon 12:30 AM | freeButRestrictionSoon to restrictedNow | 1 |
| Wed 12:30 AM | freeComfortably to restrictedNow | 1 |
| Mon 12:30 AM | restrictedNow to freeButRestrictionSoon | 1 |

The metered 9AM/10AM-to-midnight cases are the 1,898-segment bug. The daytime counts (164 to 192) are metered rules whose ranges are not midnight-ending but whose segments also carry a midnight-ending metered rule.

`isFree` / goal changes: 669 of 84,760, **all green to red**.

| Check | Changes |
|---|---|
| `isFree` 1 min | 182 |
| `isFree` 1 h | 179 |
| A Few Hours goal | 176 |
| Overnight goal | 131 |
| Park & Forget goal | 1 |

(The Park & Forget change is a lost rung 2 that became non-matching. Rung 8 and rung 4 were already red.)

All 89 changed segments have a midnight-touching range (ends 0, starts 0, or wraps). By range type: NO_STANDING wrap 104, METERED end-0 24, NO_PARKING wrap 10, SPECIAL wrap 10, TRUCK_LOADING wrap 7. No change was found on a segment with only ordinary ranges, so I found no non-midnight regression (8AM-6PM, 7:30AM-7PM, ASP 9-10:30, anytime, EXCEPT SUNDAY).

## Smoke tests run
- `df -h /`: 38 GB free before building. Built main and the PR in separate derivedData folders under `~/Library/Caches/wepark-qa189-dd`, both deleted afterwards.
- The side-by-side engine dump above (two `xcodebuild test` runs, my own dump class only; not committed).
- `gh pr checks 189`: green.
- **Not verified live:** the simulator UI check (St Marks Pl at 10:40 PM, AX5 chips, goal banner). The PR touches no mount-chain files (`MapViewRepresentable`, `ContentView`, `DriveMode*`, `safeAreaInset`), so I judged the live smoke optional. The engine behaviour is covered by the dump. The AX5 layout is covered only by reading the diff and by CI. A quick visual check at AX5 is recommended before the owner's drive.

## What's working
- A single definition of "active" now feeds hero, meter line, map state, goals and `isFree`, which removes the class of bug rather than patching two call sites.
- The `isFree` rewrite (full-window absolute overlap plus previous-day spill) never loosened anything. It also closes a latent gap where a wrap range's tail past midnight was missed on the first day of a window.
- `MidnightRangesTests` is oracle-based over real tile rules. My independent run found nothing it missed.
