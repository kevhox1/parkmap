# Drive-Mode Chevron/Compass/Heading-EMA Fix — QA Pass 1 — 2026-10-20

**Reviewed:** branch `fix/36-chevron-lag-visuals` at `b3a5db06`, against `docs/design/drive-puck-chevron-review.md` + open item #36 (`docs/open-items.md` row 36)
**Verdict:** 🟡 FIX-THEN-MERGE discipline not required for architecture — **MERGE, contingent on the mandatory Mac-gate live-UI smoke passing** (no code-level blocker found; this is a code-review pass only, no toolchain available)

## Summary

Three independent, well-scoped fixes in one PR, all traced cold against the spec. The compass-hide deviation (delegate-callback instead of the reviewed `CoordinatorActions.setCompassHidden` closure) is **sound** — I traced the actual call graph on `main` and confirmed the builder's "unconditional `setCamera` on every toggle" claim is true for BOTH entry and exit, through a single funnel with no bypass path. The chevron geometry matches the review's numbers exactly. The speed-scaled EMA alpha is a correct, well-tested pure function fed real GPS speed, with the freeze-on-stop gate and identity-rotation/puck code proven byte-for-byte unchanged. No compile-failure-class or invariant violations found. This PR is low-risk; the main residual uncertainty is a SwiftUI timing assumption (not a code bug) that the live-UI smoke will settle definitively.

## Acceptance criteria checklist

(Cross-referencing the PR's own checklist, which pre-marks the camera/visual items "pending Mac-side live smoke" — appropriate, since the sandbox has no toolchain.)

- [x] Compass force-hide wiring is architecturally sound and traces to a single always-fired funnel for both entry and exit — verified by full call-graph trace (see Finding section). **Visual confirmation still pending Mac smoke.**
- [x] Sweeper/enforcement pin chevron offset/size changed to the review's exact numbers (0.22→0.14, 0.30→0.38) — verified by diff comparison against `docs/design/drive-puck-chevron-review.md` §B. **Pixel-level "fully on fill" confirmation pending Mac smoke** (geometry math alone is not conclusive without rendering the actual SF Symbol bounding box — see Finding #3).
- [x] 5-color curb palette untouched — verified, zero color-constant touches in diff.
- [x] Identity-rotation convention (puck drawn at rest, camera owns rotation) untouched — verified byte-for-byte: `driveNavPuckImage()` and `syncDriveHeading`'s target-identity/2°-dead-band logic are zero-diff (confirmed via `diff` of extracted line ranges main vs. branch).
- [x] `selectDriveHeadingSource`'s freeze-on-stop gate (nil below 0.5 m/s) unchanged — verified, zero diff; `DRIVING_HEADING_MIN_SPEED_MPS` constant and its only call site are untouched.
- [x] Speed-scaled EMA alpha implemented as pure, `nonisolated`, unit-tested function with named tuning-knob constants — verified, correct boundary/interpolation/monotonicity math, real GPS speed threaded in (not stale/default-0) at both call sites (`didUpdateLocations`, `didUpdateHeading`).
- [x] Unit tests cover boundaries, midpoint/quarter interpolation, monotonicity, bounds-clamping, and wraparound regression at both alphas — 14 tests, all logically sound by inspection.
- [ ] Live-UI smoke (compass hide/restore, chevron-on-fill at close zoom, toolbar/banner/pill still render) — **NOT RUN, no toolchain in this sandbox. Mandatory before merge per the live-UI smoke norm (this PR touches `MapViewRepresentable.swift`'s delegate code).**

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: Compass hide-on-entry depends on an unverified SwiftUI ordering assumption (onChange fires after `updateUIView`, not before) — not a new risk, but genuinely unproven by Apple's docs**
  - Where: `Views/MapViewRepresentable.swift` — `regionWillChangeAnimated` reading `parent.driveModeActive`; `ContentView.swift` — `.onChange(of: driveModeActive) { _, active in handleDriveModeAndCamera(active) }` → `handleDriveCameraChange(active)` → `coordinatorActions.applyDrivePitch?(active, preDrivePitch)` → `applyDriveCameraState` → `mapView.setCamera(camera, animated: true)`.
  - What: `Coordinator.parent` is only reassigned at the top of `updateUIView`. If SwiftUI ever fires `.onChange` BEFORE calling `updateUIView` with the new state (not formally guaranteed by Apple's docs for `UIViewRepresentable` + `.onChange` interaction), then on Drive Mode **entry**, the `setCamera` call inside `handleDriveCameraChange(true)` would fire `regionWillChangeAnimated` while `coordinator.parent.driveModeActive` is still `false` — the compass would NOT hide on that transition, only catching up on the *next* region change (e.g., the first `syncDriveHeading` tick once GPS course arrives).
  - Expected: compass hides in the same visual beat as the pitch/zoom/style transition on entry.
  - Why I'm not calling this blocking: this exact ordering assumption (`.onChange`-driven camera mutation reading `parent.driveModeActive` inside a MapKit delegate, relying on `updateUIView` having already run) is the load-bearing assumption for the ENTIRE post-#31 camera architecture in this file — `applyDriveCameraState`, `setShowsBuildings`, `refreshUserLocationPuck` all work this same way and have been smoke-confirmed working correctly across W8.5c-polish PR-1/2/3 and W8.5d (per `HANDOFF.md`). `regionWillChangeAnimated`'s existing FT-17a gesture-detection logic already reads `parent.driveModeActive` inside this exact callback in production today. If the ordering assumption were wrong, the pitch/zoom/style transition itself would already show a visible one-tick lag — which has not been reported in any prior smoke pass. So this is an existing, already-validated risk surface, not a new hole introduced by this PR — but it's also never been explicitly screenshotted at the *exact instant* of transition, only confirmed as "the 4 features are visible and working" after the fact.
  - Repro / verification ask: during the Mac-gate smoke, specifically watch (ideally via screen recording, not a single screenshot) the compass at the *moment* Drive Mode is entered — does it disappear in the same frame the pitch/zoom animates, or is there a visible flash where the compass is still present for one GPS tick before vanishing? Add this to the smoke checklist (see below).
  - Owner: `@ios-engineer` (no code change expected unless the smoke actually shows a flash — if it does, the fix is trivial: also call `compassButton?.isHidden = active` directly from `handleDriveCameraChange`'s `CoordinatorActions` path rather than relying solely on the delegate re-entry).

### 🟢 Minor / nit

- **#2: Chevron geometry math not independently verified at the pixel level (pure code review, no rendering)**
  - Where: `Views/PinMarkerAnnotation.swift:707-760`, `markerImage(for:bearing:)`.
  - What: The offset (`imageSize * 0.14` = 4.48pt from center) and size (`imageSize * 0.38` = 12.16pt point-size) changes exactly match the design review's prescribed numbers. However, whether the resulting SF Symbol bounding box for `chevron.forward` at that point size, after the existing draw-at-origin + translate compositing, visually sits entirely within the 16pt-radius circle is a function of the *actual* glyph bounding box UIKit returns for that symbol/weight — which can't be computed from source alone and isn't covered by a unit test (it's a rendering/compositing question, not pure logic). The review itself flagged this exact uncertainty and recommended a zoomed screenshot as the only real confirmation (`drive-puck-chevron-review.md` §"Verify on device checklist" item 3).
  - Expected: chevron fully inside the colored fill at the changed size/offset.
  - Repro: not applicable — this is "verify, don't assume" rather than a found defect. Numbers match spec; visual outcome pending Mac smoke.
  - Owner: `@ios-engineer` only if the Mac smoke screenshot shows a straddle — otherwise no action needed.

- **#3: PR #131 concurrency note (process, not code)**
  - Where: N/A — cross-PR note.
  - What: The code comment explicitly says the delegate-callback approach was chosen because "`ContentView.swift` is owned by PR #131, in flight." If PR #131 lands first and touches `.onChange(of: driveModeActive)` / `handleDriveModeAndCamera` / `handleDriveCameraChange`, re-verify this PR's "unconditional setCamera on every toggle" assumption still holds against PR #131's version of `ContentView.swift` before merging PR #132 (or merge order should put #132 first, or rebase #132 onto #131 and re-run this specific trace).
  - Owner: orchestrator (merge-order coordination), not an engineering fix.

### 💡 Out of scope (logged, not fixed)

- The review's secondary note about Apple basemap one-way arrows (#10 in the review's glyph inventory) is explicitly out of this PR's scope and not addressed here — correctly so, no code path exists for it.
- `MKCompassButton`'s "wrap in `.regularMaterial` backdrop" fallback option (if Kevin prefers a visible compass) is not implemented — correctly so, the review recommended hide as the default and this PR follows that recommendation.

## Six compile-failure-class static scan

1. **Contextual-type-on-literal-receiver** — none found; no `.method` calls on bare literals in the diff.
2. **Labeled-argument order** — `driveHeadingEMAAlpha(speed:)` called with correct label at both the production call site (`LocationService.swift`) and all 14 test call sites. `stabilizedHeading(rawHeading:speed:current:)` call sites unchanged (zero diff).
3. **Memberwise-init argument order** — no new struct inits introduced.
4. **XCTestCase-extension name shadowing** — `w85cAnchor` (used by the new test file) is a pre-existing top-level `let` in `W85cTests.swift`, reused without redeclaration — no shadowing.
5. **MainActor default isolation** — `driveHeadingEMAAlpha` is correctly marked `nonisolated func`, matching the precedent set by `selectDriveHeadingSource` in the same file, and is called synchronously from non-`@MainActor` XCTest methods.
6. **ObjC-runtime name collision in test targets** — no bare `Category`/`Protocol`/`Method`/`Ivar` identifiers in `DriveHeadingAlphaTests.swift`.

No `Calendar.current` usage introduced. No `import SwiftUI` in `LocationService.swift` (still a pure service). `project.pbxproj` has zero diff (file-system-synchronized groups — new test file picked up automatically, consistent with the smallest-diff convention already established in this repo).

## Smallest-diff discipline

4 files touched, 315 insertions / 9 deletions, one commit. Proportionate to three independent, narrowly-scoped fixes plus 14 new tests and heavy doc-comments (consistent with this codebase's existing comment density). `project.pbxproj`, `Info.plist`, `Config.xcconfig*` untouched. No drive-by refactors found outside the three described changes.

## Identity-rotation / zero-diff invariant verification

Verified by extracting the exact line ranges for each function from `main` and the branch tip and running a byte-level `diff`:

- `driveNavPuckImage()` (`MapViewRepresentable.swift`): **zero diff**.
- `syncDriveHeading`'s target-identity rotation logic + 2° dead-band (`MapViewRepresentable.swift`): **zero diff** (confirmed after correcting for the branch's +18-line offset from the earlier insertions in the same file — content is byte-identical).
- `selectDriveHeadingSource` (`LocationService.swift`): **zero diff** (confirmed via the diff hunk list — only 3 hunks total in this file, none touching that function).
- 5-color curb palette (`ParkingColors.swift` / color constants anywhere in the diff): **not touched** — confirmed no `UIColor`/`systemColor` tokens appear anywhere in the `PinMarkerAnnotation.swift` diff.

## Speed-scaled EMA alpha — pure function correctness

Traced `driveHeadingEMAAlpha(speed:)`:
```
if speed <= 2.0 { return 0.35 }
if speed >= 6.0 { return 0.65 }
t = (speed - 2.0) / 4.0
return 0.35 + t * 0.30
```
- Boundaries: `speed == 2.0` → exactly `0.35`; `speed == 6.0` → exactly `0.65`. Continuous at both knees (no jump discontinuity — `t=0`→0.35, `t=1`→0.65 match the clamp branches exactly).
- Monotonicity: `t` is linear and non-decreasing in `speed` with a positive multiplier, so `alpha` is monotonically non-decreasing over the full domain, including negative/garbage speed inputs (clamped to the low branch via `<=`).
- Wraparound math (`stabilizedHeading`'s circular EMA: `diff` normalized to `[-180, 180]` before applying `alpha * diff`, then re-wrapped `mod 360`): **completely unchanged** — only the `alpha` value fed into the existing formula changed, confirmed by hunk-level diff (the wraparound `while` loops and final `truncatingRemainder` are present verbatim in the diff context, untouched).
- Freeze-on-stop (`DRIVING_HEADING_MIN_SPEED_MPS = 0.5`, gating `stabilizedHeading`'s early-return and mirrored by `selectDriveHeadingSource`): **zero diff**, confirmed both the constant and its guard clause are outside any diff hunk.
- Speed provenance (the task's specific worry — "not a stale/default-0 that would pin alpha LOW forever"): traced both producer call sites in `LocationService.swift`'s `CLLocationManagerDelegate` extension:
  - `didUpdateLocations`: `let speed = loc.speed` (real `CLLocation.speed`, m/s, -1 when unavailable) → `stabilizedHeading(..., speed: max(0, speed), ...)`. Real GPS-derived value every tick.
  - `didUpdateHeading`: `let currentSpeed = max(0, driveSpeed ?? 0)` where `driveSpeed` was itself set from the SAME real `loc.speed` on the most recent location tick (`self?.driveSpeed = speed >= 0 ? speed : 0`). Not a stale default — it's the last real GPS speed reading, refreshed every location update, only used as a cache between location/heading delegate calls (which is the pre-existing design, unrelated to this PR).
  - Verdict: alpha is correctly speed-reactive in both delegate paths; no path feeds a hardcoded `0`.

Constants are named and doc-commented as tuning knobs (`DRIVING_HEADING_EMA_ALPHA_LOW/HIGH`, `DRIVING_HEADING_EMA_LOW/HIGH_SPEED_MPS`) under an explicit `REAL-ROAD TUNING KNOBS` heading, matching the established pattern for voice-gap/arrival-threshold tuning elsewhere in this codebase.

## Compass hide — full adversarial trace (the task's #1 check)

Traced on `main` (pre-PR) to establish ground truth, then confirmed the PR's single-line addition (`compassButton?.isHidden = parent.driveModeActive` at the top of `regionWillChangeAnimated`) against it:

- **(a) Unconditional `setCamera` on both entry and exit:** Confirmed. `ContentView.handleDriveModeAndCamera(_:)` is the single funnel every `driveModeActive` assignment routes through (`.onChange(of: driveModeActive)`), and there are only 3 assignment sites for `driveModeActive` in the whole file (`= true` twice, `= false` once), all of which flow through this one `.onChange`. Inside it: entry calls `handleDriveCameraChange(true)` unconditionally (not gated on sheet state, cruise-vs-destination mode, or anything else); exit calls `handleDriveCameraChange(false)` unconditionally, same unconditional placement. Both branches call `coordinatorActions.applyDrivePitch?(active, preDrivePitch)` → `applyDriveCameraState` → `mapView.setCamera(camera, animated: true)` with no early-return path. The builder's claim is correct.
  - On `regionWillChangeAnimated` firing for non-animated `setCamera` too: not directly load-bearing here, since BOTH the entry and exit calls in `applyDriveCameraState` use `animated: true` (the separate `animated: false` exit reset lives in `syncDriveHeading`'s heading-nil branch, a different code path not used for the compass toggle). For completeness: MapKit's documented contract for `regionWillChangeAnimated`/`regionDidChangeAnimated` is that they fire for ANY region/camera change regardless of the `animated` flag (the `animated` parameter only describes whether *that specific* transition is animated) — and this codebase already depends on that being true elsewhere (FT-17a's gesture-vs-programmatic distinction is made by checking gesture-recognizer state, not by the `animated` flag, which would be meaningless if the delegate didn't fire for programmatic/non-animated changes too).
- **(b) Cold-launch state:** Correct. `compassButton.isHidden` is never explicitly set in `makeUIView` (defaults to UIKit's `false`), and `driveModeActive` defaults to `false` on both the `MapViewRepresentable` struct property and ContentView's `@State`. Any pre-drive region change (viewport-polish auto-center, user panning) will also explicitly re-assert `isHidden = false`. No cold-launch regression.
- **(c) Weak `compassButton` ref lifecycle:** Safe. `MapViewRepresentable` is created once per app session (not torn down/recreated — this is the established pattern this whole file's `#31`-avoidance architecture depends on); `compassButton` is captured once in `makeUIView` right after creation, matching the exact precedent of `panGesture`/`pinchGesture` (also `weak var`, also captured once in `makeUIView`). No other code path mutates `compassButton.isHidden` or repositions it — confirmed by grepping the whole file for `compassButton`/`MKCompassButton` occurrences (exactly 2 sites: creation+constraints in `makeUIView`, and this PR's one new line in `regionWillChangeAnimated`).
- **(d) `parent` staleness:** See Finding #1 (Significant) — architecturally consistent with existing, already-shipped patterns in this file, but not provably safe from Apple's documented API contract alone. Downgraded from blocking because the identical risk already underlies four previously-shipped, smoke-confirmed features in this same file.
- **(e) Drive-exits-without-a-camera-change (the "compass stuck hidden forever" regression scenario):** Verified NOT possible. `handleDriveModeAndCamera` is the only place `driveModeActive`'s `.onChange` fires into, and it unconditionally calls `handleDriveCameraChange(false)` on every exit — independent of `activeSheet` state, cruise vs. destination mode, or the W8.5d arrival-prompt auto-exit path (`endDriveMode()` → `.onChange` → same funnel). A `.sheet` presentation does not unmount the underlying `MKMapView` in SwiftUI (it stays in the view/window hierarchy, just visually covered), so MapKit's delegate callbacks continue firing normally even with a sheet on top. No path found where `driveModeActive` flips to `false` without this funnel running.

## Smoke tests run

No toolchain available in this sandbox (consistent with the PR's own `[COMPILE-UNVERIFIED]` tag) — the following is the **mandatory pre-merge Mac-gate checklist**, cross-referenced against the PR body's existing list (reproduced below with gaps added):

From the PR body (complete, reasonable):
1. Build + install + launch on simulator.
2. Enter Drive Mode — screenshot: compass dial NOT visible; toolbar/ASP banner/Park Until pill still render.
3. Exit Drive Mode — screenshot: compass dial visible again, `.adaptive` behavior intact.
4. Zoom into a sweeper/enforcement pin — screenshot: chevron sits fully on the colored fill.
5. Drive-test / simulate GPS course changes — subjective "feels less laggy" judgment (Kevin-only, not screenshot-verifiable).

**Additions this QA pass recommends folding into the Mac-gate checklist:**
6. **Cold-launch, before any Drive Mode session**: screenshot the map at app launch with the view manually rotated off north (two-finger rotate gesture) — confirm the compass shows per `.adaptive` (pre-drive baseline, so step 2's "not visible" has a clean before/after).
7. **Entry-transition timing**: screen-record (not just screenshot) the exact moment Drive Mode is entered — confirm the compass disappears in the SAME visual beat as the pitch/zoom/style transition, not one GPS tick later (resolves Finding #1's residual ordering uncertainty).
8. **Polylines at close zoom**: per the standing mount-chain live-UI smoke norm for any PR touching `MapViewRepresentable.swift`, confirm parking polylines still render correctly at Drive Mode's tight zoom in the same screenshot as step 2 — this PR doesn't touch overlay code, but the norm exists precisely because "tests passed, overlay layer silently vanished" has happened before in this file (W8.5c-polish revert).
9. **Browse-mode manual rotation, independent of any drive session**: rotate the map by hand (not via Drive Mode) at some point in the same session as steps 2-3, to confirm this PR's `regionWillChangeAnimated` addition doesn't interfere with ordinary `.adaptive` compass behavior outside Drive Mode entirely (i.e., `parent.driveModeActive` is reliably `false` during pure browse-mode gestures too).

Static-only review otherwise: full diff read end-to-end, zero-diff claims verified via byte-level `diff` of extracted line ranges (not by eyeballing), pure-function math hand-traced, call-graph for `driveModeActive`'s `.onChange` funnel fully walked on `main`.

## What's working

- The spec-fidelity norm (flag deviations, don't silently substitute) that was added after the W8.5c-polish incident is being followed correctly here: the compass-hide deviation from the designer review's exact wiring is explicitly called out in the code comment, the commit message, AND the PR body, with a concrete correctness argument rather than a silent swap.
- The file-ownership discipline (not touching `ContentView.swift` because PR #131 owns it) is a sound, low-friction way to keep two concurrent agents from treading on each other, and the resulting workaround turned out to be just as correct as the originally-reviewed approach once traced.
- Chevron and EMA-alpha changes are both textbook "smallest diff that fixes the named problem" — no scope creep, no drive-by edits to the 5-color palette or unrelated puck code.
- Test coverage for the new pure function is genuinely thorough (boundaries, both directions of clamping, interpolation at two different fractions, monotonicity, and bounds — not just the happy path), and the wraparound regression tests at both new alpha extremes show real care about not breaking an orthogonal invariant while fixing this one.
- Tuning knobs are clearly labeled as provisional and tied to the existing "Kevin's drive is the judge" playbook, which sets the right expectation that `0.65`/`2.0`/`6.0` are starting points, not final numbers.
