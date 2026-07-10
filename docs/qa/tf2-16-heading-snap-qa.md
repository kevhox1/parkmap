# TF2-16 Drive Mode Heading Snap-to-Street — QA Pass 1 — 2026-07-09

**Reviewed:** PR #64, branch `ios/tf2-16-heading-snap` at `c8392d6` (worktree
`/Users/kevinhoxha/repos/parkmap/.claude/worktrees/agent-ac7a63801045dd284`), against
`docs/tf2-16-heading-snap-spec.md`. Merge-base with `main`: `893cf51`.
**Verdict:** 🟡 SHIP WITH CAVEATS

## Summary

The implementation matches the spec's decision logic (§5) verbatim — hand-traced the hysteresis
state machine, bearing selection, and boundary conditions and found no bugs. `MapViewRepresentable.swift`
has genuinely zero diff (independently confirmed via `git diff`), `RegionSyncGuardTests` pass 5/5
unmodified, and no new camera-mutation call sites exist anywhere in the diff. The full suite is
533/0, confirmed deterministic across two independent runs I executed myself (not just the
builder's claim), and a cold clean build succeeds with zero errors. I also independently
reproduced and confirmed the builder's "pre-existing polyline gap" claim by building and launching
`main` at the exact PR merge-base under identical simulator conditions — both show the same
missing-polylines behavior, so that is not a regression from this PR. The one real gap: the PR's
live-UI smoke never actually entered Drive Mode (no gesture-injection tooling in either the
builder's or my environment), so AC-15's literal requirement ("renders after Drive Mode entry")
is unverified for the exact code path this PR touches. Given the strength of the code review,
independently-reproduced test suite, and Kevin's on-device drive-test being the next and
irreducible gate regardless, this is a caveat, not a blocker.

## Acceptance criteria checklist (spec §7)

- [x] AC-1 — `DriveHeadingSnap.swift` exists, `import Foundation` only, contains
  `nextHeadingSource(current:hasBlockMatch:speed:courseAccuracy:)` and
  `snappedHeading(segment:lastGoodHeading:)` matching §5 exactly (diff-read line-for-line).
  Covered by all 13 Test Inventory items (verified by name, see Findings quality section).
- [x] AC-2 — `LocationService.driveCourseAccuracy` set from the same `didUpdateLocations` tick as
  `driveSpeed`/`driveHeading` (`courseAccuracy: loc.courseAccuracy >= 0 ? loc.courseAccuracy : nil`,
  `LocationService.swift:364,370`), cleared in `endDriveMode()` (`LocationService.swift:337`).
  Verified by `LocationServiceDriveCourseAccuracyTests` (3/3 pass, independently re-run).
- [x] AC-3 — `DrivingContextService.matchedSegment` set from the exact `closest` value `update()`
  already computes (`DrivingContextService.swift:303-311`); no second `findClosestSegment` call
  or distance-search introduced — confirmed by code review, only one call to `findClosestSegment`
  in the diff and in the file.
- [x] AC-4 — `update()`'s signature/`heading:`/`currentContext` unchanged; verified the function
  signature is byte-identical and that 18 existing call sites (`DrivingContextServiceCruiseModeTests.swift`:
  8, `W85cTests.swift`: 10 — counted directly with `grep`) are absent from the diff and unmodified.
- [x] AC-5 — `MapViewRepresentable(driveHeading:)` takes `effectiveDriveHeading`
  (`ContentView.swift:1161`, the only changed line at that call site); reset to `.course`/`nil` in
  both entry and exit blocks of `handleDriveModeChange(_:)` (`ContentView.swift:1745-1746, 1785-1786`).
- [x] AC-6 — one-way bearing selection verified by code read + `testSnappedHeading_onewayTowardTo_*`
  and `..._onewayTowardFrom_*` (pass).
- [x] AC-7 — two-way circular-closest selection verified by code read + hand trace (§ below) +
  `testSnappedHeading_twoWay_picksDirectionClosestToLastGoodHeading` (pass, both directions).
- [x] AC-8 — fast+accurate course path is byte-identical to pre-spec `locationService.driveHeading`;
  verified by code read (the `.course` case is a direct passthrough) and
  `testNextHeadingSource_highSpeedCleanCourse_staysOnCourse` (pass).
- [x] AC-9 — no-block-match freeze-on-stop preserved; `nextHeadingSource` short-circuits to
  `.course` unconditionally when `hasBlockMatch == false`, verified by code read and 2 tests
  (from `.course` and from `.streetSnap`).
- [x] AC-10 — hysteresis verified by hand-trace + `testNextHeadingSource_hysteresis_*` (pass, both
  directions of the band).
- [x] AC-11 — turn-recovery single-tick exit verified by hand-trace + the exact spec-named test
  (pass).
- [x] AC-12 — `RegionSyncGuardTests` 5/5, unmodified file, independently re-run twice by me (pass
  both times).
- [x] AC-13 — zero `MapViewRepresentable.swift` diff independently confirmed
  (`git diff main...HEAD -- '*MapViewRepresentable*'` → 0 lines in the worktree); no new
  `setCamera`/`setRegion`/`userTrackingMode =` call sites anywhere in the PR diff (grep clean —
  the only match is a pre-existing comment).
- [x] AC-14 — full suite green, 533/0, independently re-run by me twice
  (`xcodebuild test`, both runs 533 passed / 0 failed / 0 skipped via `xcresulttool` summary) —
  deterministic, matches the builder's claim exactly.
- [ ] AC-15 (live-UI smoke) — **PARTIALLY VERIFIED.** Toolbar/ASP-banner rendering confirmed at
  launch (pre-Drive-Mode), by both the builder and independently by me. The spec's literal wording
  ("renders after Drive Mode entry") was not exercised by either party — Drive Mode requires
  destination selection via taps, and no gesture-injection tooling was available in this
  environment either. See Finding #1.
- [x] AC-16 — this document.
- [ ] AC-17 (Kevin on-device) — pending, correctly deferred; irreducible final gate per spec and
  per this report's verdict below.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: AC-15's literal requirement (render check *after Drive Mode entry*) was never exercised by anyone**
  - Where: PR description "Live-UI smoke" section; `ContentView.handleLocationUpdate()` (the code
    this PR actually touches, gated entirely under `if driveModeActive`).
  - What: The builder's smoke screenshot (and mine, on both the PR build and `main`) is the
    pre-Drive-Mode explore map. Entering Drive Mode requires a destination pick (tap-driven UI
    flow) that neither the builder's headless environment nor my QA environment can perform — no
    gesture-injection tooling (XCUITest driver / idb / accessibility taps) is wired into either
    sandbox. This means the exact code path this PR adds (`driveHeadingSource` /
    `effectiveDriveHeading` computation, and its consumption by `syncDriveHeading`) has never been
    visually confirmed rendering correctly in a live, running app — only inferred from code review
    and unit tests.
  - Expected (spec §7, AC-15): "Sim screenshot confirms the full overlay chain ... still renders
    after Drive Mode entry."
  - Repro: `xcrun simctl launch <udid> com.kevinhoxha.wepark`, tap through to select a destination
    and enter Drive Mode, screenshot, confirm the bottom card / Park Until pill / heading arrow
    render — none of this was performed by the builder or by me.
  - Why not Blocking: the wiring is narrowly confined to `handleLocationUpdate()` (confirmed by
    diff-read — no `updateUIView` mutation added, `MapViewRepresentable.swift` has zero diff), the
    15+3 new unit tests exercise the pure decision logic exhaustively and pass, and Kevin's
    on-device drive-test (AC-17, already the plan) will directly exercise Drive Mode entry with
    real GPS — which is a strictly stronger check than a static sim screenshot could ever be for
    this feature (the sim has no moving GPS to trigger the low-speed snap in the first place, so a
    sim-only screenshot of Drive Mode would only confirm overlay presence, not the actual behavior
    under test). Recommend the team acquire tap-capable tooling for future #31-class PRs so this
    gap can close before merge rather than being deferred to Kevin every time.
  - Owner: `@ios-engineer` (tooling gap, not a code fix) / process note for whoever runs the next
    #31-class QA pass.

### 🟢 Minor / nit

- **#2: `lastGoodHeading` doc language slightly overstates what's passed at the call site**
  - Where: `DriveHeadingSnap.swift:240-241` doc comment ("the last trustworthy EMA value before
    confidence dropped") vs. `ContentView.swift:1923` (`lastGoodHeading: locationService.driveHeading`,
    read live on the current tick).
  - What: In the 0.5–1.5 m/s band (where `.streetSnap` can be entered purely on speed, with good
    course accuracy), `LocationService.stabilizedHeading` is still live-updating the EMA every
    tick (the freeze-on-stop path only kicks in below 0.5 m/s). So `lastGoodHeading` at the moment
    `snappedHeading` is called is not always a frozen pre-drop snapshot — it can itself be a
    still-noisy, currently-updating EMA value.
  - Impact: cosmetic/documentation only, not a functional bug. The implementation matches the
    spec's own §5.2 pseudocode literally (`lastGoodHeading: locationService.driveHeading` is
    exactly what the spec's code block specifies), and the two candidate bearings for a two-way
    street are ~180° apart, so ordinary GPS course noise (tens of degrees at most) can't flip the
    circular-closest selection. Only relevant on two-way streets during low-confidence entry;
    one-way streets (the reported failure mode, and most of Manhattan) are unaffected since they
    don't consult `lastGoodHeading` at all.
  - Owner: `@ios-engineer`, doc-only fix, non-blocking.

### 💡 Out of scope (logged, not fixed)

- **Pre-existing polyline non-render at cold launch/low simulator zoom** — independently
  reproduced and confirmed pre-existing (see Smoke tests run, below). Not introduced by this PR.
  Recommend a dedicated follow-up ticket for `rebuildOverlays`/launch-recenter timing (the
  builder's diagnosis — recenter runs after the initial `rebuildOverlays` computes against the
  wider pre-recenter span, and only a later trigger re-runs it) rather than folding it into TF2-16.

## Hand-traces (per spec §5.3 and the assignment)

**(a) One-way approach → turn onto cross street (Kevin's reported scenario).**
Approaching at low speed on a matched one-way segment: `hasBlockMatch=true`, `speed<1.5` (or
`courseAccuracy>45`) → `nextHeadingSource` returns `.streetSnap`; `snappedHeading` returns the
fixed `onewayToward`-derived bearing regardless of GPS noise — arrow holds steady, matching the
reported symptom's fix. As the turn is executed: entry/exit are gated on speed+courseAccuracy
*only* (§5.1's `lowConfidence`/`highConfidence` predicates never reference course/EMA
disagreement — confirmed by direct code read, there is no such comparison anywhere in
`DriveHeadingSnap.swift`), so a real course swing during the turn cannot itself be misread as
"noise, stay snapped." If the driver is still slow mid-turn, `matchedSegment` re-targets
automatically as `findClosestSegment` (unchanged, pre-existing) picks up the new street once GPS
crosses onto it — the snap bearing itself updates to the new street, it doesn't stay locked to the
old one. The moment speed ≥ 3.0 m/s **and** courseAccuracy ≤ 25° in the same tick, `.course` is
returned immediately with no artificial lag (confirmed by `testNextHeadingSource_turnRecovery_*`
and by direct trace of the `switch current { case .streetSnap: return highConfidence ? .course :
.streetSnap }` line — there is no counter, timer, or multi-tick state). **No fighting-the-turn
bug found.**

**(b) Two-way street crawl.** At crawl speed (0.5–1.5 m/s) with a two-way match, `.streetSnap`
bearing is chosen via `circularDelta` against `lastGoodHeading` (live EMA per Finding #2 above).
Because the two candidate bearings are ~180° apart, only GPS noise exceeding ~90° could flip the
selection mid-crawl — implausible for real GPS course noise. No flip-flop risk found beyond what
Finding #2 already notes as cosmetic.

**(c) GPS course briefly nil at speed.** CoreLocation typically invalidates `course` and
`courseAccuracy` together (both go negative) when it can't determine heading. `driveCourseAccuracy`
correctly publishes `nil` in that case (`loc.courseAccuracy >= 0 ? ... : nil`), and
`nextHeadingSource`'s `lowConfidence` treats `courseAccuracy == nil` as low confidence
unconditionally (test #7, pass) — so a momentary course dropout at speed correctly triggers (or
holds) the street-snap rather than exposing raw noise. If `course` (not `courseAccuracy`) is the
only invalid field, `stabilizedHeading`'s existing haversine-movement fallback (unchanged,
pre-existing, not part of this PR) still applies before freeze-on-stop. No new gap found.

## #31 protections — independently confirmed

- `git diff main...HEAD -- '*MapViewRepresentable*'` in the worktree: **0 lines.**
- `git diff main...HEAD -- '*RegionSyncGuardTests*'`: **0 lines**; suite re-run by me, 5/5 pass.
- `grep -n "setCamera\|setRegion\|userTrackingMode ="` across the full PR diff: only one match,
  and it's a pre-existing code comment (`// setCamera has applied...`), not a new call site.
- All new logic (`DriveHeadingSnap` computation, source-selection, bearing selection) lives inside
  `ContentView.handleLocationUpdate()`, confirmed by direct read of the surrounding function body —
  same `.onChange(of: locationUpdateCount)`-driven, outside-`updateUIView` location already used
  by `setDriveCamera`. No new mutation surface inside `updateUIView`.

## Test quality

All 13 spec Test Inventory items (§8) are present and correctly named/behaviored — confirmed by
reading each test body against its spec item, not just counting: `testNextHeadingSource_highSpeedCleanCourse_staysOnCourse`,
`..._lowSpeed_entersSnapWhenBlockMatched`, `..._lowSpeed_noBlockMatch_staysOnCourse`,
`..._poorCourseAccuracy_entersSnapEvenAtModerateSpeed`, `..._hysteresis_hoveringNearSingleThreshold_doesNotOscillate`,
`..._turnRecovery_speedAndAccuracyJumpTogether_exitsInSameTick`, `..._nilCourseAccuracy_treatedAsLowConfidence`,
`testSnappedHeading_onewayTowardTo_returnsForwardBearing`, `..._onewayTowardFrom_returnsReverseBearing`,
`..._twoWay_picksDirectionClosestToLastGoodHeading`, `..._twoWay_noLastGoodHeading_defaultsToForwardBearing`,
`..._onewayDataMalformed_fallsBackToTwoWayLogic`, `..._circularDelta_wrapsCorrectlyAcrossZero`. Plus
2 well-motivated extra tests (`..._noBlockMatch_fromStreetSnap_returnsToCourse`,
`..._nilCourseAccuracy_blocksExitFromStreetSnap`) that close real gaps in the state-machine's
transition table rather than padding the count. None are tautological — each asserts a specific
numeric/enum outcome against a hand-computable expected value, not just "doesn't throw."

The `#if DEBUG` test seam (`setDriveModeActiveForTesting`) is correctly scoped — confirmed
`#if DEBUG` / `#endif` bracket it directly (`LocationService.swift:313-332`), it's a pure setter
touching only `driveModeActiveInternal`, and it introduces no new branch in any
production/non-DEBUG code path (it doesn't wrap or gate any existing logic — it's an additional
function, not a conditional inside one).

## Smoke tests run

1. **Full test suite, run 1:** `xcodebuild test` in the PR worktree → 533 passed / 0 failed / 0
   skipped (via `xcresulttool get test-results summary`).
2. **Full test suite, run 2 (determinism check):** same command, independent invocation → 533
   passed / 0 failed / 0 skipped, identical to run 1.
3. **Suite composition check:** confirmed via `xcresulttool get test-results tests` that
   `DriveHeadingSnapTests` has exactly 15 tests (all pass), `LocationServiceDriveCourseAccuracyTests`
   has exactly 3 (all pass), `RegionSyncGuardTests` has exactly 5 (all pass) — matching the PR's
   claimed composition exactly.
4. **Cold clean build:** `xcodebuild clean` then `xcodebuild build -configuration Debug` →
   `** BUILD SUCCEEDED **`, 0 `error:` lines.
5. **Existing regression call-site count:** `grep -c` on `DrivingContextServiceCruiseModeTests.swift`
   (8) + `W85cTests.swift` (10) = 18, matching AC-4's claimed count exactly; neither file appears
   in the PR diff.
6. **Live-UI smoke, PR build, fixed sim location (40.7229,-73.9935), ~10s and ~78s after launch:**
   installed and launched `WePark-aqfdtrwtdwcalpecrisqreejrbqd`'s build on UDID
   `F0820726-15F4-4FA3-8602-A5D7B479A277`, screenshotted, and Read the screenshots. Toolbar (gear,
   find-me, Park Until clock, Drive/route button) and the "ASP in Effect Today" banner render
   correctly at both timestamps. **No street polylines visible at either timestamp** — matches the
   builder's report, does not resolve after 78s.
7. **Adversarial pre-existing-polyline check:** created a temporary `git worktree` at the PR's
   exact merge-base (`893cf51`), built Debug for the same simulator, installed, and launched under
   *identical* conditions (same fixed location, same wait interval, location permission freshly
   granted for a clean comparison). **`main` at the merge-base shows the identical
   no-polylines-visible behavior** — confirms the builder's "pre-existing, unrelated" claim is
   correct, not a regression introduced by this PR. Screenshots compared side-by-side (both
   Read and visually inspected): identical street layout, identical absence of curb-rule
   polylines, identical ASP banner and toolbar rendering. Temporary worktree removed after use
   (`git worktree remove --force`), no mutation to the persistent worktree or main repo history.
8. **AC-15 as literally specified (post-Drive-Mode-entry render check):** **NOT performed** — see
   Finding #1. No gesture-injection tooling available to enter Drive Mode via UI taps in this
   sandbox.

## What's working

- The core fix is well-designed and, on code review + hand-trace, correctly solves the reported
  problem without the turn-fighting failure mode the spec explicitly worried about (§5.3) — the
  deliberate omission of course/EMA disagreement as an entry/exit signal is implemented exactly as
  reasoned in the spec, and I could not find a path where a real turn gets misread as noise.
  Confirmed with a real 933-tick worth of confidence via hand trace of the state machine boundaries
  — no oscillation, no lag, no wraparound bugs, no off-by-one at threshold values.
- `#31` discipline was followed to the letter: this is one of the cleaner "confined blast radius"
  PRs I've reviewed for this codebase — zero `MapViewRepresentable.swift` diff, zero new
  `updateUIView` mutation, all new state changes gated behind the existing `.onChange`-driven
  per-tick location handler.
- Test coverage is genuinely thorough, not just numerically padded — every named spec test
  inventory item is present and asserts the correct value, plus two well-reasoned extra tests that
  close real transition-table gaps.
- The builder's PR description was largely trustworthy: I independently re-derived every
  quantitative claim (533/0 suite, 18 existing call sites, 5/5 RegionSyncGuardTests, 15+3 new test
  counts, zero MapViewRepresentable diff) and every one checked out exactly as stated. The one
  claim that needed adversarial verification (pre-existing polyline gap) also checked out under
  independent build-and-compare.

## Final note

Per the QA brief for this feature class: **Kevin's on-device drive-test (AC-17) remains the
irreducible final gate regardless of this report's verdict.** The sim has no moving GPS or
magnetometer to reproduce the actual low-speed hunt-then-turn scenario this PR exists to fix — a
"SHIP CLEAN" verdict from this pass would not and could not mean the on-device behavior has been
confirmed. Recommend merging conditional on Kevin's drive-test as already planned, and closing
Finding #1 as a process note for tooling rather than a merge blocker.
