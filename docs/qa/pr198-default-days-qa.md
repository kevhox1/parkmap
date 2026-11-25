# PR #198 QA: tiles default-days (`fix/tiles-default-days`) - 2026-11-25

**Reviewed:** `fix/tiles-default-days` at `54769b79`, against `docs/qa/tiles-default-days.md`
**Verdict:** SHIP (one yellow caveat on the ParkNYC meterless pilot, not blocking)

## Summary
The change is exactly what the PR says. A rebuild from the cached 96,268-sign pull is byte-identical to the committed tiles apart from `index.json generatedAt`. The diff against main is 2,180 UNKNOWN rules, `[1..6]` to `[0..6]`, in 1,263 segments, and nothing else. Zero red-to-green anywhere. All script tests pass.

## Checklist
- [x] Rebuild identical: `SIGNS_CACHE_PATH=<signs.json, 96,268 signs> TILES_OUTPUT_DIR=<scratch> node build/preprocess.js`. `diff -rq` against `tiles/` reports only `index.json`, and the only differing line there is `generatedAt`. 1,078 files in each. `ios/.../Resources/tiles` is identical to `tiles/`.
- [x] Diff is exactly 2,180 rules: a custom comparer (segment headers, rule counts, every non-`days` rule field) against main's tiles gave `ruleChanges 2180, segments 1263, other 0, cats {UNKNOWN: 2180}, days {1..6 -> 0..6: 2180}`. Same 47,696 segment ids on both sides.
- [x] Verdict diff re-run (`UNKNOWN_RESTRICTS=1 node scripts/diff-tiles-days.js main new`): A Few Hours Sun 10 AM 352 green->red, Sun 8 PM 364 green->red, all Tue/Sat cells 0, Overnight and Park & Forget 0 everywhere, `redToGreen: 0`. Matches the PR's claim. Absolute A Few Hours green: Sun 10 AM 31,124 (current engine, both tile sets) / 31,123 (restricts, main tiles) / 30,771 (restricts, new tiles). Sun 8 PM 31,292 / 31,292 / 30,928.
- [x] Tests: `test-day-parsing`, `test-default-days`, `test-sign-reclassification`, `test-unknown-classifier`, `test-residual-fake-spots`, `test-arrow-direction-fix` (26/0), `test-bowery-detour`, `test-width-offset-resurrection` (41/0), `test-pipeline-determinism` (205 blocks x 10 trials): all pass, exit 0.

## Convention judgments
- **SCHOOL DAYS stays Mon-Sat.** School days are really Mon-Fri, so keeping Saturday is over-red (safe), not under-red. Sunday stays green for 1,664 windowed rules. That is correct, because no school meets on Sunday. Accepted.
- **METERED / ASP Mon-Sat.** The DOT 2005 press release and 311 KA-01011 support "no meter payment and no ASP on Sundays" for ordinary meters.
- **ParkNYC "meterless pilot": not independently verified.** See finding #1.

## Findings
### Blocking
None.

### Significant
- **#1: the 49 defaulted METERED rules are the only no-day-stated rules left green on Sunday, and the pilot's hours are unsourced.**
  - Where: `build/preprocess.js` `parseSchedule`, the `category === 'METERED'` branch.
  - What: 42 of the 49 rules are the sign "PARKNYC APP PAYMENT ONLY ZONE (FOR METERLESS CURB PILOT)" (the signs.json sample shows no days or hours). Their window is 00:00-00:00, all day. They sit on 41 segments, none meter-only. The DOT 2005 source covers physical meters and muni-meters. It does not cover the app-only pilot, whose hours are set in the ParkNYC app. I found nothing offline that confirms the pilot is off on Sundays. The PR doc's own "Verified" section covers meters, not the pilot.
  - Expected: under the product rule, an unreadable sign is red. The pilot sign is arguably unreadable for days.
  - Impact: small. At most 41 segments, each with other rules, only on Sundays. Suggest either sourcing the pilot hours or flipping the pilot sign text to 7 days. Not blocking.
  - Owner: `@backend-data`

### Minor
- Sourcing for the general "no days shown" convention (34 RCNY 4-08) is still open, as the PR doc admits. It currently matters only for a hypothetical category.
- The `DEBUG_DEFAULTED_DAYS` `_dd` flag is off in real builds. The committed tiles contain no `_dd`.

## What's working
Narrow, auditable change with a regression test, an inventory flag and a reproducible diff script. The rebuild is deterministic.
