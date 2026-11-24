# PR #180 QA: sign reclassification (2026-11-24)

**Reviewed:** branch `fix/sign-reclassification` at `d4355ea9` against `docs/sign-types-review.md` (incl. "Kevin's decisions")
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
Data-only change. All 5 `scripts/test-*.js` pass on the branch. Independent analysis of the regenerated tiles (rule-level diff vs main, 47,209 vs 46,908 segments) found no over-reach that turns legal parking red and no change to ASP rules. The unrequested Sunday/ALL DAYS fix is correctly scoped. Follow-ups are minor.

## Checklist
- [x] Commercial-only meters -> NO_PARKING in their window. Bowery Bleecker->E Houston W is NO_PARKING Mon-Fri 8-6 in all 6 sub-segments. "COMMERCIAL VEHICLES ONLY ... EXCEPT SUNDAY" gives days [1-6], 7AM-7PM. The "COMMERCIAL VEHICLES ONLY OTHERS NO STANDING" sign goes to NO_STANDING (stricter, correct).
- [x] Plate/vehicle/use-only -> SPECIAL, anytime when no window. Midtown East taxi stand (E 44th St 2nd->1st) and diplomat curb (E 41st St FDR->1st) are SPECIAL, 7 days, anytime. Windowed ones keep their window (Mon-Fri 7-7 doctor, Sunday-only farmers market, 7PM-4AM taxi).
- [x] Bus layover -> SPECIAL. Present in the top-description list (MTA/non-MTA, with and without windows). "NO BUS LAYOVER" stays UNKNOWN (lookbehind works; covered by the new test).
- [x] Hard-hat construction -> stated regulation + `temporary:true`. 210 segments carry it; NO STANDING anytime 7 days. Bare riders without regulation text are skipped.
- [x] Restriction signs naming no day -> 7 days. I diffed every description present in both tile sets with the same category. All 209 distinct-description schedule changes are one of: "ALL DAYS" (Mon-Sat to 7 days), or no day named (anytime, or 7 days with the stated hours). Zero changes involve a description that names a weekday, EXCEPT, or SCHOOL DAYS. Those fall through to the old Mon-Sat default. "EXCEPT SUNDAY" and "MONDAY-FRIDAY" signs are unaffected (checked samples: days [1-6] and [1-5]).
- [x] Sunday-free regression on explicit days: none found. The only 7-day rules with an EXCEPT in the text are "NO STANDING ANYTIME EXCEPT AUTHORIZED VEHICLES", and those were already 7 days on main.
- [x] ASP untouched by the day default. The category guard is NO_STANDING/NO_PARKING/TRUCK_LOADING/SPECIAL only. ASP category totals are identical apart from ASP_DAILY 5887->5890. 65 shared-id ASP diffs are all because the ids were re-indexed in blocks with new zone boundaries (geometry differs; ASP_TUE_FRI rules moved to other `_N` ids), not schedule changes.
- [x] Non-restrictive stays UNKNOWN: BACK IN ANGLE / 90 / 60 DEG PARKING ONLY (404+149+60+...), PARALLEL PARKING ONLY, HEAD IN ANGLE, "2 HOUR PARKING SATURDAY 9AM-7PM", carshare/info/panels, "METERS ARE NOT IN EFFECT". None are SPECIAL.
- [x] Still-METERED descriptions: 256 distinct. The only ones matching ONLY/COMMERC/TRUCK/BUS/PERMIT/TAXI/PLATE are "PARKNYC APP PAYMENT ONLY ZONE" (pay by app, correctly metered) and "METERED PARKING (FOR BUS STOP ONLY)" riders. 5 random metered segments were plain "2 HMP ... EXCEPT SUNDAY".
- [x] 5 random formerly-METERED to NO_PARKING (of 3,715 shared ids): 4 of 5 had a COMMERCIAL VEHICLES ONLY rule, and every description exists verbatim in the raw sign pull. The 5th (Columbus Ave W81->W77) is NO_PARKING because of `1 HMP COMMERCIAL VEHICLES ONLY MON-FRI 7AM-4PM`, which sits at the third rule (my sample print showed only the first two).
- [x] 5 bus stops: 4 of 5 are NO_STANDING 7 days anytime. The 5th (Norfolk St) carries NO STANDING anytime on a sibling rule; the UNKNOWN/METERED items on it are generic panel/rider text, so the curb is red.
- [x] 5 random untouched segments are byte-identical to main (`P[id]==M[id]`). 36,471 shared ids are identical, so the diff is contained.
- [x] iOS decode: `ParkingRule` is synthesized `Codable` (`Models/ParkingRule.swift:32`, no custom `init(from:)`), so the extra `temporary` key is ignored. The custom `init(from:)` in the models belong to CommunityPin/ParkedCar only.
- [x] PWA: `index.html` reads `days/timeRanges/anytime` directly and never references `temporary`; additive key is harmless.
- [x] Tests: `test-arrow-direction-fix` 26/0, `test-bowery-detour` PASS, `test-pipeline-determinism` PASS, `test-sign-reclassification` PASS, `test-width-offset-resurrection` 41/0 (run in a temp worktree under ~/Library/Caches).

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1 `dominantCategory` is priority-based and now hides meters.** Segments with both a metered window and a commercial-only/NO_PARKING sub-window report `NO_PARKING` as the dominant category (e.g. Columbus Ave W81->W77: M-F METERED + NO_PARKING 7AM-4PM -> dominant NO_PARKING). The engine uses `rules`, so map colour is right per time window, but anything reading `dominantCategory` alone (legend/filter, "show all signs") will over-state red. Owner: `@backend-data`/`@ios-engineer`, check consumers.
- **#2 Dominant-category change count (5,072) is large for a "data-only" PR.** Expected, but note for release notes: expect a visible red increase in Midtown/Chelsea/Hell's Kitchen/Bowery commercial-meter blocks.
- **#3 "SCHOOL DAYS" AVO (394+252+... rules) still use the Mon-Sat default** until the DOE school calendar work lands. Known (decision #5), not a regression.
- **#4 Over-broad `AVO` substring (pre-existing)** `d.includes('AVO')` would catch any word containing "AVO". No hit in the data sample, but worth a word-boundary.

### Out of scope
- UNKNOWN residual (4,419 rules, 69 distinct) are info panels, idle-law, angle-parking, "FOR BUS STOP ONLY" riders, "EXCEPT BUSES", "Description Not Available". All reasonable; no restriction found hiding there.

## Smoke tests run
- Rule-level A/B of every description in main vs PR tiles (script in session scratchpad), schedule-change taxonomy, ASP diff, EXCEPT-sign category diff, METERED/UNKNOWN residual audit, random samples as listed, 5 test scripts, Codable read. No simulator needed (data-only; no mount-chain files touched).

## What's working
Narrow, mostly additive regex set with the right precedence (NO_* first, then commercial, then reserved, then meter); the day-default fix is guarded by category, no-day, and no-EXCEPT conditions, and the added test pins the lookbehind and negative cases.

## CI
`Build and XCTest (Xcode 26)` run 45498556697: completed, success (ran normally; no runner-acquisition failure).
