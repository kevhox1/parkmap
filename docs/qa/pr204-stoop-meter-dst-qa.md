# PR #204 Stoop meter-start DST fix: QA Pass 1 (2026-11-26)

**Reviewed:** `fix/stoop-meter-dst` at `5bc9382e` merged locally with `origin/main` (`7570733b`, already up to date), against `docs/qa/pr202-stoop-polish-1-qa.md` finding #1.
**Verdict:** MERGE

## Summary
`WPCurbCopy.nextMeterStart` (`ios/WePark/WePark/DesignSystem/WPCurbSheetLogic.swift:302`) now builds each meter start with `cal.date(bySettingHour:minute:second:of:)` on the ET calendar instead of `startOfDay + N elapsed minutes`. An exhaustive scratch test against a brute-force minute scan across both DST eves showed zero disagreements. No other elapsed-minute date math exists in Stoop or app code. Flag-on only (curb sheet); flag-off untouched.

## Checklist
- [x] Wall-clock construction: line 302, `bySettingHour` (same construction `ParkingGoals.swift:142` and the engine use).
- [x] Agrees with a minute scan on DST eves. Scratch test (removed, not committed): meter starts every 30 min across 00:00-23:30 (includes 1:30 and 2:30 AM, inside the skipped hour on 2027-03-14 and the repeated hour on 2026-11-01), durations 10 and 90 min, from 7 different instants (eve 22:00, eve noon, 00:10 on the change day, 03:00 fall-back day, for both Mar 13 2027 and Oct 31 2026), skipping from-instants where the meter is already on. 0 mismatches over the whole matrix. Neither side was vacuously nil: the eve-22:00 starts always find a meter within the 7 day window.
- [x] PR's own tests: 3 new DST tests plus extended minute-scan test (4 DST `froms`) pass.
- [x] Grep for other elapsed-minute math: `byAdding: .minute|.hour|.second` has zero hits anywhere in `ios/WePark/WePark`. Remaining `startOfDay` uses are day-granular (`byAdding: .day`, `dateComponents([.day])`, `startOfDayET(offsetDays:)`), which are DST-safe. No `addingTimeInterval(86400)` style in `DesignSystem` or `Views/WP*`.
- [x] Flag-off unchanged (diff touches only `WPCurbCopy` and a test file).

## Findings
### Blocking
None.
### Significant
None.
### Minor / nit
- **#1 (green)**: the exhaustive scratch DST test (every 30 min start x 2 durations x 7 DST `froms`, ~2 s) is a stronger regression net than the 4 hand-picked cases. Optional follow-up: add it to `StoopPolish1Tests`. Not required.
### Out of scope
- Starts inside the skipped hour (2:30 AM on spring-forward) resolve via `bySettingHour`'s default `.nextTime` policy to 3:00 AM EDT; this matches the minute scan (and the engine, which can never observe 2:30) so there is no disagreement, just worth knowing.

## Smoke tests run
- Scheme `WePark` full suite on a private iPhone SE (3rd gen) sim, `-parallel-testing-enabled NO -jobs 4`: **3062 tests, 1 skipped, 0 failures** (merged result).
- Scratch DST matrix test: passed, 0 mismatches (removed before commit).
- Builds: WeParkClip, ClipLiveActivities, WeParkLiveActivities all BUILD SUCCEEDED.
- No live-UI smoke: the diff does not touch the mount chain (pure date math in a logic file).

## What's working
Minimal one-line fix, with a clear comment, correct reuse of the engine's construction, and tests that include the failing DST cases the original QA called out.

**MERGE**
