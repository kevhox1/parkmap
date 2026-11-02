# PR #148 Heading Wrong-Way Hardening QA Pass 1 — 2026-11-02

**Reviewed:** branch `fix/heading-wrong-way-hardening` at `74f2e9f9`, against the PR body's stated acceptance criteria (no separate spec doc exists for this fix — it's a hardening patch over the existing TF2-16 / open-item-#36 heading pipeline)
**Verdict:** ✅ ship it

## Summary

This PR adds two pure upstream guards (`courseAccuracyQualifies`, `DriveHeadingFlipGuard`) in front of `LocationService.stabilizedHeading`'s EMA to close the "wrong-way" class Kevin hit on build 24. The layering is correct: the new EMA-level gate and the pre-existing TF2-16 street-snap fallback consume the same raw, unfiltered `driveCourseAccuracy` independently, so a poor-accuracy fix while matched to a street still gets rescued by the street bearing exactly as before — the hypothesized regression (gate starving TF2-16) does not occur, because TF2-16 reads the published course-accuracy value directly rather than anything gated by this change. The flip-guard state machine checks out by hand against all the named behaviors (single-glitch rejection, 2-fix confirmed adoption, challenger reset, progressive-U-turn immunity, wraparound correctness), and `endDriveMode()` resets it alongside `headingEMA` so no stale hold leaks across sessions. CI is green (41391726852, 17m23s), 20 new tests all map to real assertions, and the diff is exactly as advertised (one new file + a parameter/call-site change in `LocationService.swift` + two test files, no flag).

## Acceptance criteria checklist

- [x] Course-quality gate added, screens only a REPORTED numeric `courseAccuracy > 45°`, `nil` always passes — verified by reading `courseAccuracyQualifies` and its 5 unit tests (threshold-inclusive, nil-passes, large-value-fails)
- [x] `-1`/invalid courseAccuracy doesn't brick heading — verified: `loc.courseAccuracy >= 0 ? ... : nil` upstream sentinel-parsing is untouched (pre-existing TF2-16 code); `courseAccuracyQualifies(nil) == true` confirmed by test and by hand-trace
- [x] Large-flip confirmation: single glitch rejected, reversal adopted after N=2, U-turn never held, wraparound correct — verified by hand-tracing `DriveHeadingFlipGuard.next()` against all 9 `DriveHeadingFlipGuardTests` cases; math checks out (see Smoke tests below)
- [x] Gate/flip-guard sit upstream of the EMA, not replacing TF2-16's independent street-snap fallback — verified by tracing `driveCourseAccuracy`'s publish path (raw, unfiltered by the new gate) into `ContentView.handleLocationUpdate`'s `DriveHeadingSnap.nextHeadingSource` call, which is unaffected by whether `stabilizedHeading` froze that tick. See Finding discussion below (not a bug, flagged as verified-correct).
- [x] `flipGuard` reset in `endDriveMode()` alongside `headingEMA`/`driveCourseAccuracy`/`prevDriveCoordinate` — verified by reading the diff directly
- [x] `syncDriveHeading`'s dead-band/identity-rotation and `MapViewRepresentable` untouched — verified: not in the diff's changed-file list (`git diff --stat` shows only `DriveHeadingGuard.swift`, `LocationService.swift`, `DriveHeadingGuardTests.swift`, `W85cTests.swift`)
- [x] No feature flag — ships live, matches PR body and #132 precedent — verified by grepping the diff for `AppConstants.`/`flag` (zero hits besides an unrelated doc-comment word)
- [x] CI green — verified via `gh run view 41391726852` (Build and XCTest, Xcode 26, 17m23s, ✓)
- [x] Drive-start posture audit (change 3) correctly scoped as "no production change, test-only lock" — verified: diff touches zero production camera code, only adds a regression test using a `setCamera` call-count spy

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: A dropped/delayed GPS fix during a tight, low-speed U-turn (e.g. a 3-point turn, or a parking-lot turn with momentary signal loss) can exceed the 120° single-fix flip threshold and get held for 2 extra fixes before resuming — a real, if narrow, false-positive on the flip guard.**
  - Where: `DriveHeadingGuard.swift:54` (`flipThresholdDeg = 120.0`), consumed in `LocationService.stabilizedHeading` (`LocationService.swift:380`)
  - What: The guard's U-turn immunity depends on the assumption that consecutive fixes arrive close enough in time that no single raw-to-raw delta exceeds 120°. At 1 Hz GPS this holds for ordinary turns (~25-40°/fix, per the PR's own test comments). But CoreLocation does not guarantee a fix every second — a dropped fix during a tight turn at a slightly elevated speed (e.g. a U-turn taken at 8-10 mph with a 2s gap between fixes) can plausibly produce a single apparent jump > 120°, which the guard cannot distinguish from a genuine glitch/reversal. The guard then holds the heading (freezes on last-good) for up to 2 additional fixes before resuming — a brief, conservative freeze, not a wrong-way snap, so it fails safe. Still, it's a real UX cost (puck looks stuck mid-turn for ~1-2s) that the PR's test suite does not exercise (all tests assume a clean, evenly-spaced fix cadence).
  - Expected: Either accept this as a known, bounded, fail-safe trade-off (freezing briefly is strictly better than the wrong-way bug being fixed), or add a time-delta-aware variant in a follow-up (e.g. scale `flipThresholdDeg` by elapsed time since the last fix).
  - Repro: Not reproducible deterministically on the simulator (requires a real dropped/delayed fix); can be approximated in a unit test by feeding `DriveHeadingFlipGuard.next()` a candidate >120° away after simulating a multi-second gap — no such test exists today.
  - Owner: `@ios-engineer` (follow-up, non-blocking — recommend tracking as an open item rather than fixing pre-merge, since it fails safe and the base rate is low: dropped fixes concurrent with a sharp low-speed turn).

### 🟢 Minor / nit

- **#2: `maxCourseAccuracyDeg` (45°) exactly matches TF2-16's pre-existing `enterCourseAccuracyDeg` (also 45°) in `DriveHeadingSnapConstants` — the PR doesn't call out that this is the same number, which reads like an unexamined coincidence rather than a deliberate alignment.** Not a bug (the two gates serve different purposes and are correctly independent — see Summary), but worth a one-line comment cross-referencing the two constants so a future engineer tuning one doesn't assume they're silently coupled when they aren't (they're not coupled; they just happen to share a value today).
  - Where: `DriveHeadingGuard.swift:46` vs `DriveHeadingSnap.swift:64`
  - Owner: `@ios-engineer` (doc-only, trivial)

### 💡 Out of scope (logged, not fixed)

- **Stale manual-rotation at drive entry** — the PR body correctly flags this (browse-mode two-finger rotate held into drive entry until the first qualified course corrects it) as a pre-existing, adjacent risk, explicitly out of scope for this dispatch. Confirmed pre-existing: `syncDriveHeading`'s early-return-on-nil behavior (the mechanism that holds the stale rotation) is untouched by this diff, and the PR's own regression test (`testSyncDriveHeading_freshCoordinator_nilHeading_holdsEntryHeading`) locks in that exact behavior as correct-per-spec (hold the entry heading), not a bug this PR introduced or worsened. Agree with leaving it out — correctly scoped.

## Smoke tests run

- `gh run view 41391726852` — CI green, "Build and XCTest (Xcode 26)" job ✓ in 17m23s, no annotations beyond an unrelated Node.js deprecation warning. Not re-run locally (no sandbox Xcode toolchain available in this environment) — relying on the CI result, which is authoritative for compile + test pass/fail.
- **Read `DriveHeadingGuard.swift` in full** (211 lines) — adversarial read of `courseAccuracyQualifies` and `DriveHeadingFlipGuard.next()`.
- **Hand-traced `DriveHeadingFlipGuard.next()` against all 9 `DriveHeadingFlipGuardTests` cases**, including:
  - `circularDelta(10, 350)` and `circularDelta(350, 10)` both = 20 (wraparound correct, verified against the modular-arithmetic formula by hand)
  - Progressive U-turn sweep `[80, 160, 240, 320, 40]` with per-step current-update: every step delta = 80° ≤ 120°, all blend, none hold — matches test expectation
  - Reversal-adoption: `(current=90, candidate=270)` → delta 180 > 120 → hold; `(current=90, candidate=268)` → delta(268,90)=178>120, delta(268,held-270)=2≤30 → confirmCount=2 → adopt(268) — matches
  - New-challenger reset: `270` then `220` (delta to held 270 = 50 > 30 tolerance) → new challenger, count=1, still hold; then `222` (delta to held 220 = 2 ≤ 30) → count=2 → adopt(222) — matches
- **Traced the cross-system interaction (check #1 in the dispatch) end-to-end:** `LocationService.locationManager(_:didUpdateLocations:)` → `courseAccuracy` computed once, fed to `stabilizedHeading` (gates/freezes the EMA) AND published raw to `self.driveCourseAccuracy` (unfiltered) in the same `DispatchQueue.main.async` block. `ContentView.handleLocationUpdate` → `DriveHeadingSnap.nextHeadingSource(... courseAccuracy: locationService.driveCourseAccuracy ...)` reads that same raw published value, independent of whether `stabilizedHeading` froze `driveHeading` that tick. Confirmed: when matched to a segment and accuracy is poor, TF2-16 still overrides `effectiveDriveHeading` with the street bearing regardless of the new gate's freeze — no regression. The PR body's own "audit finding" paragraph confirms this was the intentional design: the gap this PR closes is specifically the *unmatched* case, which TF2-16 never covered.
- **Traced `endDriveMode()`** — confirmed `flipGuard = DriveHeadingFlipGuard()` resets alongside `headingEMA = nil`, `driveCourseAccuracy = nil`, `prevDriveCoordinate = nil`; no stale hold can leak into the next session.
- **Traced `ContentView.handleDriveModeChange`** — confirmed `driveHeadingSource`/`effectiveDriveHeading` reset to `.course`/`nil` on both entry and exit, independent of but consistent with the `LocationService`-side reset.
- **Read the `.hold` → EMA no-op mechanism** by hand: `flipGuard.next(current: headingEMA, candidate: heading)` returning `.hold(current)` means `value == headingEMA` in the switch, so `diff = value - headingEMA! == 0` and the EMA update is a true no-op — matches the doc comment's claim exactly.
- **Read the `.adopt` bypass**: `headingEMA = confirmed` directly, skipping the alpha blend — confirmed this is a crisp jump as advertised, not a slow-blend through the wrap.
- **Counted the "20 named" tests claim**: `CourseAccuracyGateTests` (5) + `DriveHeadingFlipGuardTests` (9) + `DriveHeadingGuardIntegrationTests` (5) + `W85cTests.swift`'s 1 new test = 20. Matches.
- **Read the CI test-fix (spy-subclass) change** (`SyncDriveHeadingSpyMapView` in `W85cTests.swift`) against the production `syncDriveHeading` code it tests (`MapViewRepresentable.swift:2450-2500`, confirmed untouched by this diff) — the early-return-on-nil-when-`lastAppliedHeading`-is-nil guard is real production logic, and spying on `setCamera` call count is a *stronger* assertion than the headless-camera-heading readback it replaces (which is documented as unreliable in a zero-frame CI `MKMapView`). Not a weakened test.
- **Grepped the full diff for flag/AppConstants references** — zero hits (confirms "no flag" claim, matches #132 precedent).
- **Confirmed `git diff --stat` scope**: only `DriveHeadingGuard.swift` (new), `LocationService.swift` (+56/-16), `DriveHeadingGuardTests.swift` (new), `W85cTests.swift` (+73) — no `MapViewRepresentable.swift`/`ContentView.swift`/`DriveHeadingSnap.swift` changes, confirming the "smallest diff" and "TF2-16/syncDriveHeading untouched" claims.
- Did **not** run a live-UI sim smoke — this PR touches no mount-chain file (`MapViewRepresentable.swift`, `ContentView.swift` body, `DriveMode*.swift` views, `.safeAreaInset`/overlay code are all absent from the diff), so the live-UI smoke gate in the QA charter does not apply here. The one test-file touch to `W85cTests.swift` is a headless unit test, not a UI change.

## What's working

- The course-quality gate and flip guard are both genuinely pure value types/functions with zero CoreLocation-session or UIKit dependency — directly testable, matching the house style (`FinalApproachService`, `DriveHeadingSnap`).
- The PR's own "audit finding" write-up correctly identifies and closes exactly the gap it claims to (unmatched-segment + poor-accuracy case), and the interaction with the pre-existing TF2-16 fallback is correctly layered, not duplicative or conflicting — this was the single highest-risk thing to get wrong in this PR and it's right.
- The flip-confirm state machine's wraparound math is correct at every edge tested, including the trickiest case (a flip that straddles 0°/360°, which a naive linear delta would misjudge).
- `endDriveMode()`'s reset list correctly grew to include the new `flipGuard` state — easy to miss, wasn't missed.
- Test naming and structure make the intent of each case legible without needing the production code open side-by-side — a QA-friendly test suite.
- The PR explicitly audited and found change 3 (drive-start posture) to be *already correct* rather than inventing a fix for a non-problem, and correctly declined to expand scope into the adjacent stale-rotation risk — good judgment on scope discipline.

## Open follow-up (not blocking)

Recommend an open item for Finding #1 (dropped-fix-during-sharp-turn false positive) — low priority, fails safe, but worth a line in the backlog so a future "puck looked stuck for a second during my 3-point turn" field report isn't treated as a surprise regression.
