# A3.6 driving-look launch (PR #138) QA Pass 1 - 2026-10-23

**Reviewed:** branch `feat/a36-driving-look-launch` at `01cd4e2f` (2 commits on top of `2dc3b61a`), against `docs/design/goal-first-ambient-design.md` Addendum 3 A3.6, `docs/drive-mode-default-spec.md` ruling 6 / AC-13, and Kevin's Option A ruling.
**Verdict:** FIX-THEN-MERGE (0 blocking, 3 significant, all small; plus a mandatory Mac live smoke that nobody has run yet)

## Summary

Cold read, hunk by hunk, of the 5 changed files. I found no flag-off regression, no AC-13 violation, and no `updateUIView` camera mutation, and every remaining `setRegion` path is correctly bypassed flag-on at rest. Three things should be fixed before merge. The Cruise-End restore races an un-animated `syncDriveHeading(nil)` camera snap. A wide-to-tight tighten does not re-center on the new fix. A `==` on a nested enum inside `nonisolated` statics is a plausible Swift 6.2 compile break on Kevin's Mac. **I could not build, run tests, or do the live-UI smoke** (Linux VPS, no `xcrun`/`xcodebuild`/`swift`). This PR touches the mount-chain files (`MapViewRepresentable.swift`, `ContentView.swift`), so the Mac smoke is merge-blocking and nothing below substitutes for it. The branch is 1 commit behind `main` (PR #137, Curb files only); `git merge-tree` merges clean and I found no name collisions.

## Acceptance criteria checklist

- [x] Flag-off byte-identical - verified by diff trace (see "Flag-off trace"); every new path hangs off `isInEffect` / `AppConstants.driveModeDefaultEnabled` (constant `false`).
- [x] `driveModeActive` stays false at rest; no `startDriveMode()`, wake lock, continuous GPS, voice - verified by grepping the full diff: no added call to `startDriveMode`, `isIdleTimerDisabled =`, `userTrackingMode`, `Calendar.current`, or voice. The only location call is the pre-existing `requestAndFetchLocation()`.
- [x] Camera mutation only via `CoordinatorActions` from handlers, single `setCamera` per transition, no `setRegion` in the look - verified (`setAmbientDrivingLook` is one `mapView.setCamera`; callers are `performLaunchSetup`, `handleLocationUpdate`, `handleDriveCameraChange`, `recenterMap`).
- [x] Cruise constants referenced, not duplicated - `driveModePitch` and `altitudeForSpan(span(for:cruiseSpan: driveModeCameraSpan))`; the only new number is `wideStepSpanMultiplier = 2` (flagged).
- [x] Accuracy guard 65 m inclusive; negative/nil go wide - code and tests agree.
- [x] Overlay-hide guard holds at both steps - bounded analytically below.
- [x] Recenter measured in screen space from handlers, never a view body - verified (`refreshAmbientUserDotOffCenter` is called from `handleRegionChanged` and `handleAmbientLookLocationUpdate` only).
- [ ] End returns to the exact launch look - PARTIAL. See finding #1.
- [ ] No big accuracy ring - NOT VERIFIED (finding #4; needs the Mac).
- [ ] Compiles / 4 new test classes pass - NOT VERIFIED (finding #3 is a plausible compile break).
- [ ] Live-UI mount-chain smoke - NOT RUN (cannot on this machine).

## Flag-off trace (priority 1)

| Site | Flag-off behavior |
|---|---|
| `CoordinatorActions` 3 new closures | Installed unconditionally in `makeUIView` but nothing calls them flag-off: every caller sits behind `ambientDrivingLookInEffect` / `startAmbientDrivingLook`'s flag guard. No observer, overlay, link, or animation is added. |
| `viewFor` user-location branch | `guard AppConstants.driveModeDefaultEnabled else { return nil }` - the same stock dot as main. |
| `regionDidChangeAnimated` | Gated on `AppConstants.driveModeDefaultEnabled, !driveModeActive, wasUserInteracting`; the constant is false, so it is inert. |
| `recenterMap(on:usingUserFix:)` | `else { coordinatorActions.setRegion?(newRegion) }` - the same call as main. The new default parameter keeps callers working. |
| Find-me / launch-recenter | Only an added `usingUserFix: true` argument, which is ignored flag-off. |
| `handleRegionChanged` | One added `refreshAmbientUserDotOffCenter()`; its first line is `guard ambientDrivingLookInEffect`. |
| `handleLocationUpdate` | Adds a `let ambientRecenterPending` read and a hook that returns at its first guard flag-off. |
| `handleDriveCameraChange` | The early return fires only when `restoresAmbientLookOnDriveExit(flag)` is true. Flag-off falls through to the unchanged restore. |
| `ambientRecenterButtonVisible` | New defaulted parameter. `ambientUserDotOffCenter` is only ever written flag-on, so it is always nil flag-off and the region test runs. |
| `LocationService` | See priority 2 below. |

Result: byte-identical in behavior. The one flag-off-visible runtime delta is an additional `@Observable` property write per resting fix (`userHorizontalAccuracy`). Nothing flag-off reads it, so no extra view invalidation.

## Findings

### Blocking
None.

### Significant

- **#1: Cruise End races an un-animated heading-0 `setCamera` against the animated ambient restore**
  - Where: `ContentView.handleDriveCameraChange(false)` -> `restoreAmbientDrivingLookAfterDrive()` vs `MapViewRepresentable.Coordinator.syncDriveHeading(nil, on:)` (`else` branch, `setCamera(camera, animated: false)`), reached from `updateUIView`.
  - What: The ordering is: `driveModeActive` flips -> `.onChange` runs `handleDriveModeAndCamera(false)` -> `handleDriveCameraChange(false)` starts the animated `setAmbientDrivingLook` -> `handleDriveModeChange(false)` writes `effectiveDriveHeading = nil` -> next render -> `updateUIView` -> `syncDriveHeading(nil)`. That last step runs whenever `lastAppliedHeading != nil`, which is nearly always after any real drive with GPS course. It copies `mapView.camera` (the codebase's own comment at `syncDriveHeading` says `camera` lags during an animation, i.e. returns in-flight values) and issues an un-animated `setCamera` with heading 0. This cancels the in-flight animation. Consequences: (a) the heading unwinds as a snap, not the intended single smooth animation. (b) If the user pinched or panned in Cruise (so the camera distance, or pitch, differs from the tight/30 target), the camera freezes at the mid-animation distance. `ambientLookStep` is already `.tight`, so `shouldTighten` never re-asserts it. Worst case is a stuck non-launch zoom after End. In the default case (Cruise pitch/distance equal the look's), the final state is correct (heading 0, pitch 30, tight) and only the smoothness is lost. This is not the `setRegion`-flattens-pitch bug class: nothing here resets pitch, since `syncDriveHeading` copies the current pitch. It is an animation-cancel class.
  - Expected: A3.6.3 "End returns to this exact launch look" in one clean animation.
  - Repro (Mac): flag on, Start Driving, simulate a drive so `driveHeading` is non-nil, pinch out once, tap End. Watch for a rotation snap and a final zoom that is not the launch zoom.
  - Owner: `@ios-engineer`. Suggested direction (not applied by me): have the restore path also clear the coordinator's `lastAppliedHeading` (a `CoordinatorActions` closure) so `syncDriveHeading(nil)` is a no-op, or defer the restore until after the heading reset.
  - Not verified on device; the MapKit "camera returns in-flight values during animation" premise comes from the existing code comment.

- **#2: Wide-to-tight tighten does not re-center on the new fix**
  - Where: `ContentView.handleAmbientLookLocationUpdate` -> `applyAmbientDrivingLook(center: nil, step: .tight, animated: true)`.
  - What: `center: nil` keeps the current camera center. Launch recenter (`recenterOnUserAtLaunch`) is one-shot: it clears after the first fix. If the first fix is poor (>65 m) the look opens wide centered on that fix, then a later good fix tightens in place around the OLD, possibly 100+ m-off coordinate. At the tight span (~333 m tall visible) the real dot can land off-center or near the edge. The new screen-space check can then show Recenter even though the user touched nothing. This is the exact scenario the accuracy guard exists for.
  - Expected: tightening onto a better fix should center on that fix (the user has not adjusted the map).
  - Repro: sim location with accuracy ~100 m, then a second fix 80-100 m away at accuracy <=65 m; the tightened camera stays on the first position.
  - Owner: `@ios-engineer` (pass `locationService.userLocation` as the center in the tighten call).

- **#3: Plausible compile break - `==` on a nested enum inside `nonisolated` statics**
  - Where: `AmbientDrivingLook.shouldTighten` (`currentStep == .wide`, `zoomStep(...) == .tight`) and `ZoomStep: Equatable` declared inside an enum in a `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES` module.
  - What: Under MainActor default isolation the nested enum is implicitly `@MainActor`. With approachable concurrency (isolated-conformance inference), `==` used from a `nonisolated` function can fail with "main actor-isolated conformance ... cannot be used in nonisolated context". The existing precedent in this repo for the same shape (`HeadingSourceKind` in `DriveHeadingSnap.nextHeadingSource`) uses `switch`, not `==`. The builder's header note is aware of the MainActor-in-nonisolated class of error but did not apply it to this conformance.
  - Expected: compiles on the first Mac build.
  - Owner: `@ios-engineer`. Cheapest fixes are declaring the enum `nonisolated`, or using `switch`. Also confirm the test file's `XCTAssertEqual(..., .tight)` calls still compile after the change.
  - This is a risk, not a confirmed error; I cannot compile here. It is the one place worth looking at first when Kevin's Mac build runs.

### Minor / nit

- **#4: Accuracy-ring suppression via a replacement `MKAnnotationView` is unverified (deviation #4) - smoke-gate, not a code finding.** Returning a custom view from `viewFor` for `MKUserLocation` replaces `MKUserLocationView`, which is where MapKit draws the accuracy circle and the pulse; widely reported behavior, and no public alternative exists. The branch is correct in structure: ambient reuse id `ambientUserDot` vs drive `driveUserPuck`, `.identity` transform, never rotated. The chevron's `syncDriveHeading` puck transform only touches `mapView.view(for: userLocation)` during drive, so it cannot leak onto the dot. Cruise entry/exit swaps views through the existing `refreshUserLocationPuck` re-query, same mechanism as main. Risk: it depends on `parent.driveModeActive` already being false in the coordinator's `parent` copy at re-query time on End; this is the same dependency main's chevron removal already has. Confirm on device (smoke item 2); the builder's fallback is "hide it differently".
- **#5: `userHorizontalAccuracy` goes stale across a drive.** The drive branch of `didUpdateLocations` updates `userLocation` but not the accuracy, and `endDriveMode` does not clear it. A Find-me after End reads the pre-drive accuracy until the post-End single-shot fix lands (self-heals through the tighten path, subject to #2). Low impact.
- **#6: A pure two-finger rotate or tilt is not detected as "user adjusted".** `onAmbientUserAdjusted` keys off the observer pan/pinch recognizers. If the user only rotates or tilts, a later tighten (or Recenter) re-applies heading 0 and pitch 30 via `setAmbientDrivingLook`. A tighten that fights a rotation is a mild annoyance; Recenter re-asserting north-up is by design.
- **#7: `AmbientDrivingLookLocationPostureTests` wake-lock asserts are weak.** `isIdleTimerDisabled == false` is also true on a fresh process. The tests are real (they drive `didUpdateLocations` on a real `LocationService` and assert `driveHeading/Speed/CourseAccuracy` stay nil and the accuracy publishes, including the invalid -> nil path), but "no `startDriveMode()` at rest" is only proven by my code read (clean), not by a test. Order-dependence risk with `W85cTests` is low: its start/end pairs enqueue `true` then `false` on main in order.
- **#8: Two pure-logic tests are partly tautological.** `testBothSteps_stayUnderPolylineHideThreshold...` compares constants times 3 and says nothing about what MapKit reports; see the analytic bound below, which is what actually supports it.
- **#9: `onAmbientUserAdjusted` closure captures the `ContentView` struct (`self.ambientLookUserAdjusted = true`).** Works for `@State` once the view is installed (it is: `.task`), consistent with existing patterns; the Mac smoke "pan during wide phase must not tighten" covers it.

### Out of scope (logged, not fixed)

- Branch is behind `main` by PR #137 (Curb index, new files only). Merges clean; no action needed beyond a normal rebase/merge.
- Flag-on denied-location user stays on the wide step forever (deviation #5). Acceptable and arguably right ("never tight-then-widen", and with no dot there is nothing to be wrong about); Kevin's call whether a no-fix user should instead open tight over the default center.
- 3D buildings hidden in the ambient look (deviation #3) goes beyond "camera + style only". Flag-on only, matches Cruise, one-line revert; I accept it but it should be an explicit Kevin ruling.

## Priority-by-priority notes

2. **AC-13 / LocationService deviation.** The diff in `LocationService.swift` is exactly: one `private(set) var userHorizontalAccuracy` plus, in the `else` (non-drive) branch of `didUpdateLocations`, a local computed before the existing `DispatchQueue.main.async` and one extra assignment inside it, set BEFORE `locationUpdateCount += 1` so `.onChange(of: locationUpdateCount)` readers see the matching value. Verified unchanged: `startDriveMode`/`endDriveMode` (desiredAccuracy, activityType, pauses, distanceFilter, wake lock), the heading path, and the whole drive branch. The `else` is genuinely the `driveModeActiveInternal == false` branch. Thread-safety: written on the main queue like `userLocation` (the delegate computes the value on the callback thread and only the property write is main-dispatched), so no new actor hazard. Could it be done without touching the file? Only via `CLLocationManager.location` (not exposed) or reading it in ContentView's own manager, which does not exist - so the deviation was necessary, and it is minimal and isolated in its own commit. **Acceptable**, but requires Kevin's explicit sign-off since it overrides the brief. See #5 for staleness.
3. **Camera / #31.** `updateUIView` is untouched except the existing `syncDriveHeading` call; no new mutation. No `userTrackingMode`, no headless-window guard. Pure decisions live in `AmbientDrivingLook.swift` with only Foundation/CoreGraphics/CoreLocation imports, `nonisolated` on every member, no `Calendar.current`, no force-unwraps. Every `setRegion` in the tree: `makeUIView:1205` initial un-animated region before the look, the `setRegion` closure (called only from `recenterMap`'s flag-off else), nothing else. `recenterMap` is the single funnel for car recenter, deep link (`routePendingDeepLink`, Priority 1), launch Priority 2a, `handleLocationUpdate` request/launch branches and Find-me; all bypass `setRegion` flag-on at rest.
4. **Start Driving.** `enterCruiseMode()` and `applyDriveCameraState` are unchanged. From tight there is no jump (same pitch, same `altitudeForSpan(driveModeCameraSpan)`). From wide it is one animated `setCamera`. `preDrivePitch` captured at entry is now 30, but the flag-on exit no longer reads it. End: see finding #1.
5. **User-adjusted false positive.** Cannot misfire on the look's own `setCamera`: `isUserInteracting` is set only in `regionWillChangeAnimated` when the observer pan/pinch recognizers are active, and `setCamera` fires neither; taps/long-press/compass button are excluded; it is cleared on every `regionDidChange`. The flag is set asynchronously after the settle, and `applyAmbientDrivingLook` clears it on every explicit apply (launch, Recenter, exit), so Recenter re-arms tightening. Sound. (Rotate/tilt gap: #6.)
6. **Overlay-hide bound (analytic).** Taking the repo's own assumption (vertical FOV 30 deg, matching `altitudeForSpan`), pitch 30 deg, camera distance D: camera height 0.866 D, ground depth = 0.866 D (tan 45 deg) - 0.232 D (tan 15 deg) = 0.634 D versus 0.536 D for a nadir view, i.e. 1.18x. Wide: `altitudeForSpan(0.006) ~ 1,243 m` -> ~788 m depth -> 0.0071 deg latitude; even a rotated bounding-box diagonal is ~0.008 deg. Tight (621 m): ~0.0035 deg. The threshold is 0.04 deg, i.e. a 5x margin, so curb colors cannot vanish at the launch camera, and the builder's 3x margin is conservative. The `handleRegionChanged` -> `rebuildOverlays` gate is untouched. The prior cold-launch `initialLaunchRegion` (400 m) fix means `rebuildOverlays` at `performLaunchSetup` runs before the look and the subsequent `regionDidChange` repaints with the settled region. Residual (needs the smoke, not code): user pinch-out while tilted trips the hide ~20% earlier in altitude, as the PR says.
7. **Recenter under tilt.** `userDotOutsideCentralHalf` converts via `MKMapView.convert(_:toPointTo:)` inside a `CoordinatorActions` closure, returns nil for a zero-size map, and is re-measured only after settled region changes and fixes (`cameraMoveInFlight` suppresses the pre-move measurement). The optional parameter defaults to nil, so old callers and tests are unchanged; the tests cover center, boundaries, each axis, off-screen, zero size, skew override, nil equivalence across every auth status, and auth-gating-never-overridden. Minor: out-of-coverage `recenterOnUserRequested` sets `cameraMoveInFlight` without a camera move, so the measurement stays stale until the next region change (trivial).
9. **Other deviations.** Wide = 2x Cruise span is a clean single tunable and fine. Buildings: see out-of-scope above.
10. **Compile-failure-class scan.** No bare `Category`. No literal-receiver or labeled-argument-order issue found (`ambientRecenterButtonVisible` appends a trailing defaulted parameter; call sites pass labels in declaration order). No memberwise inits added. Test helpers are `private` to their classes, no `XCTestCase` extension shadowing (`waitUntil`/`makeFix`/`user`/`mapSize` don't collide with `NotificationSchedulerTests`/`ParkingRulesEngineParityTests` extensions or the new `CurbSnap*` fixtures on `main`). MainActor `MapViewRepresentable.*` values are read into locals before assertions. The one open class is #3 (`==` on the nested enum). No `Calendar.current`, no SwiftUI import in the pure file, flag still `false`, smallest-diff respected (no drive-bys; the `ambientRecenterButtonVisible` doc update is on-topic). Synchronized folders: confirmed `project.pbxproj` uses `PBXFileSystemSynchronizedRootGroup`, so a new file in `Services/` and in `WeParkTests/` needs no pbxproj edit.

## Smoke tests run

- Hunk-by-hunk diff read of all 5 files against the spec and the brief's 11 points.
- Greps over the full diff and tree: `setRegion`/`setCenter`/`setCamera` sites, `userTrackingMode`, `startDriveMode`, `isIdleTimerDisabled`, `Calendar.current`, `ZoomStep` collisions.
- `git merge-tree origin/main HEAD`: clean.
- Not run: `xcodebuild`, unit tests, simulator launch, screenshot (no Xcode toolchain on this machine). The mount-chain live smoke is therefore NOT done; I make no claim about whether the toolbar/rail/ASP banner/Park Until pill/polylines render at the tilted launch camera.

## What's working

- Clean seam discipline: self-contained marked blocks, an isolated `LocationService` commit, and a pure decision file with dense tests. The `isInEffect` gate really does carry the flag-off identity.
- The #31 lesson is applied correctly: all camera work is outside `updateUIView`, in a single `setCamera`, with `setRegion` routed around.
- The `recenterMap` choke point is the right fix for "Find-me/Recenter flatten the pitch"; the builder found that every recenter path funnels through it.
- Screen-space recenter measurement is the right yardstick under pitch, and the optional-parameter design keeps old callers untouched.
- The accuracy guard's direction (never tight-then-widen) and the invalid-sentinel handling are right.
- The PR body's disclosure of deviations is candid and accurate.

## Mac smoke checklist (Kevin's re-smoke script) - PR list plus additions

PR's items 1-8 all stand. Add:

9. **Cold launch with poor first fix (sim accuracy ~100 m) followed by a good fix 80-100 m away (finding #2):** after the tighten, is the dot still near center, or off to one side with Recenter showing unprompted?
10. **Cruise End after real motion (finding #1):** Start Driving, simulate a drive (City Run), pinch zoom out/in once, tap End. Check for a rotation snap and that the final zoom equals the launch zoom; check pitch stays 30.
11. **Denied-location launch:** wide, tilted, muted, curb colors painted over Manhattan center, no dot; Recenter hidden.
12. **Two-finger rotate and tilt gestures, then wait for/trigger a better fix:** does the tighten fight the rotation? (finding #6)
13. **Deep link (notification tap) and recenter-on-car flag-on:** camera stays tilted (not flattened), car visible; and cold-kill deep link path.
14. **Dot semantics:** blue dot is not the chevron, no accuracy ring (finding #4), no pulse is expected (drawn replica), dot never rotates when the map is rotated by the user, accessibility label "Your current location" in VoiceOver.
15. **Start Driving from the wide step vs the tight step:** one animation vs no jump; chevron appears; End brings the plain dot back with an identity transform (no leftover rotation).
16. **First Mac build:** watch for the finding #3 compile error in `AmbientDrivingLook.shouldTighten`; run `AmbientDrivingLookTests` and `AmbientDrivingLookLocationPostureTests` and confirm `W85cTests` still pass in the same run.
17. **Tile loading under pitch:** the pitched `region` is a larger trapezoid bounding box; confirm no visible tile-load lag at the wide step.

---

# QA Pass 2 addendum - 2026-10-23

**Reviewed:** branch `feat/a36-driving-look-launch` at `d11d614d` (fix commit on top of merge `181da4ba`, which brought in PR #137).
**Verdict:** MERGE, gated on Kevin's Mac compile + live-UI smoke (still not runnable here: no Xcode toolchain; this is a mount-chain PR, so that gate is not waived). 0 blocking, 0 significant, 3 new minor.

## Scope of change since pass 1

- `git diff 7fe90acc 181da4ba` (the merge) touches only PR #137 files (`CurbSnap*`, `docs/open-items.md`, `docs/qa/pr137-*`). It does not touch any PR #138 file.
- `git diff 181da4ba d11d614d` touches only the 5 expected files: `ContentView` (+13), `AmbientDrivingLook` (+32), `LocationService` (+4), `MapViewRepresentable` (+10), `AmbientDrivingLookTests`. No drive-by.
- Flag still `false` (`AppConstants.driveModeDefaultEnabled`; `testFlagShipsDark` unchanged).

## Pass-1 findings: status

| # | Status | Basis |
|---|---|---|
| 1 Cruise End race | RESOLVED (flag-on); needs Mac smoke | Re-trace below |
| 2 Tighten does not re-center | RESOLVED | `tightenCenter` + call site below |
| 3 `==` on nested enum | RESOLVED (best-effort; still uncompiled) | `switch`; `exitZoomStep()` is now a function |
| 5 Stale accuracy across drive | RESOLVED | nil-reset in `startDriveMode`/`endDriveMode` |
| 7 Weak wake-lock assert | RESOLVED with one nit (#12) | Positive control added |
| 6 Rotate/tilt not "user adjusted" | Stays minor; deferral is reasonable | Needs a new recognizer in the highest-risk file |

## (1) Cruise End re-trace, every writer, flag-on

1. Tap End: `driveModeActive = false`. SwiftUI renders; `updateUIView` runs. `context.coordinator.parent = self` is the first line (MapViewRepresentable:1534), so the coordinator sees `driveModeActive == false` from this render on. `effectiveDriveHeading` is still the stale non-nil value, so `syncDriveHeading(h)` hits its dead-band (same value, diff <= 2) and does not write.
2. `.onChange` -> `handleDriveModeAndCamera(false)` -> `handleDriveCameraChange(false)` -> early-returns into `restoreAmbientDrivingLookAfterDrive()`: muted style, buildings off, `refreshUserLocationPuck`, then ONE animated `setAmbientDrivingLook`. That closure copies the current camera (center kept) and sets `pitch = 30`, `heading = AmbientDrivingLook.heading (0)`, and `centerCoordinateDistance = altitudeForSpan(tight)`, all in the same `setCamera`. So the restore carries its own heading 0 and its own explicit tight distance. A pinch or rotation in Cruise is overwritten by absolute values, not deltas. `ambientLookStep = .tight` and `ambientLookUserAdjusted = false` are set inside `applyAmbientDrivingLook`.
3. `handleDriveModeChange(false)`: `locationService.endDriveMode()`, `effectiveDriveHeading = nil`, `followPaused = false`. No camera call.
4. Next render -> `syncDriveHeading(nil)`: `lastAppliedHeading` is cleared (state still reset), then `isInEffect(flag, parent.driveModeActive == false)` is true -> returns before the un-animated `setCamera`. The in-flight restore animation is no longer cancelled.
5. `applyDriveCameraState`'s exit branch is NOT reached flag-on (the early return precedes `applyDrivePitch`). `lastCapturedPriorDistance` goes unused, which is harmless.
6. `regionDidChangeAnimated` at settle: `wasUserInteracting` is false (programmatic), so no adjusted flag. It dispatches the usual `onRegionChanged` -> `handleRegionChanged` -> re-measure Recenter, and `rebuildOverlays` (the `!driveModeActive` gate is now open). No camera write.
7. Is the skipped write ever needed? It runs only when `lastAppliedHeading != nil`, which means a heading-up Cruise session happened. Every `driveModeActive` true->false path goes through `handleDriveModeAndCamera(false)` -> `handleDriveCameraChange(false)` -> restore, which sets heading 0 itself. So there is no state where the skip leaves a non-zero heading. The restore always runs before step 4.
8. Flag-off `syncDriveHeading(nil)`: the new block is `isInEffect(false, ...) == false`, so it falls through to the original `camera.heading = 0; setCamera(animated: false)`. Byte-identical apart from one pure `Bool` call.
9. Residual, unverifiable here: MapKit's heading interpolation for an animated `setCamera` from a Cruise heading to 0 (shortest arc vs. long way round) is MapKit's behavior, not ours. Covered by smoke item 10 below.

No remaining double write, snap, or freeze found in the trace.

## (2) Tighten

- `handleAmbientLookLocationUpdate` -> `shouldTighten(currentStep, userAdjusted, newAccuracy)` -> `applyAmbientDrivingLook(center: tightenCenter(fix:, fixInCoverage:), step: .tight, animated: true)`. `tightenCenter` returns the fix only when it is in Manhattan coverage, else nil (keep the current center). `cameraMoving = true` suppresses the pre-move Recenter measurement, and `handleRegionChanged` re-measures once the camera settles on the new fix. Result: a good fix after a poor one lands the dot at screen center, with no unprompted Recenter. Pass-1 repro is resolved.
- Already-tight: `shouldTighten` returns false. User-adjusted: false at the first guard. Poor or nil accuracy: false. Out-of-coverage with a good fix: tightens in place around the current center (acceptable: no data to center on, and no recenter could have happened).
- Launch double-move check: `recenterMap(usingUserFix: true)` (launch branches) applies the step from the same accuracy, so `ambientLookStep` already matches and `shouldTighten` is false in the same tick. One camera move, not two.
- False-positive check: the tighten `setCamera` is programmatic, so `regionWillChangeAnimated` sees no active observer pan/pinch and never sets `isUserInteracting`. It cannot mark the look "user adjusted". Same for Cruise End.
- Mid-gesture edge (new minor #10): `ambientLookUserAdjusted` is set only after the gesture settles (async from `regionDidChangeAnimated`). A good fix landing while the user's finger is still down in the wide phase would tighten mid-pan. Needs a pan plus a fix arrival in the same sub-second window; cosmetic.

## (3) Compile-class scan (independent)

- Every `nonisolated` member in `AmbientDrivingLook.swift` (`maxTightHorizontalAccuracyMeters`, `wideStepSpanMultiplier`, `heading`, `exitZoomStep()`, `centralHalfFraction`, `isInEffect`, `zoomStep`, `span`, `shouldTighten`, `tightenCenter`, `restoresAmbientLookOnDriveExit`, `userDotOutsideCentralHalf`): the stored statics are `Double`/`CGFloat` (Sendable, no MainActor reads); none reads `MapViewRepresentable.*` or any `AppConstants` value (those arrive as parameters).
- The only `==` on a nested enum in the library file was in `shouldTighten`; it is now a nested `switch` (no `==` left in the file). The old `static let exitZoomStep: ZoomStep` is gone. All call sites updated: `ContentView:4411` and the 3 test uses call `exitZoomStep()`; a grep for the bare property finds none.
- Tests use `XCTAssertEqual(..., .tight/.wide)` on `ZoomStep`. The test classes are default-MainActor, and `DriveHeadingSnapTests` already does the same on `HeadingSourceKind`, so this has precedent.
- MainActor values in the new tests (`MapViewRepresentable.driveModeCameraSpan`) are read into locals first. No bare `Category`, no literal-receiver pattern, no labeled-argument-order issue (`tightenCenter(fix:fixInCoverage:)` matches its declaration at both call sites), no memberwise init, no `XCTestCase` extension. `ContentView`'s `fix.map { AppConstants.isInManhattanCoverage($0) } ?? false` is MainActor-to-MainActor.
- `Calendar.current`: none. SwiftUI import in the pure file: none.
- Still not compiled. The Mac build is the real check.

## (4) LocationService diff vs `main`

Total: one `private(set) var userHorizontalAccuracy`, the resting-branch local + assignment (set before `locationUpdateCount` increments), and two `userHorizontalAccuracy = nil` lines (one each in `startDriveMode` and `endDriveMode`, both after the `guard`). `desiredAccuracy`, `activityType`, `pausesLocationUpdatesAutomatically`, `distanceFilter`, `startUpdatingHeading`, the wake lock, and the drive branch of `didUpdateLocations` are unchanged. Pass.

Side effect to note: during Cruise the accuracy is nil, and just after End (until the post-End single-shot fix lands) a Find-me tap in that window would choose `.wide` and then self-tighten when the fix arrives (the tighten path re-centers now). Self-healing; not a finding.

## (5) Wake-lock positive-control test

- Real `startDriveMode()` in a unit test: `LocationService.init` only reads `authorizationStatus` and never requests authorization, and `startUpdatingLocation()` without a grant does not show a prompt. `W85cTests` already calls real `startDriveMode()` / `endDriveMode()` in six tests, so this adds no new class of side effect. `LocationServiceTests` documents avoiding it only because a live session can race simulator-synthesized fixes; here the only consequence of a stray fix is a drive-branch write nothing in the test asserts on.
- Leaves the lock on if an assertion fails? `XCTAssert*` records a failure and does not abort (`continueAfterFailure` defaults to true), so `endDriveMode()` still runs. It would stay on only on a crash, and the test has no throwing or early-exit path. Low risk, but not structurally guaranteed (nit #12).
- Test strength: the sleep drains the main queue and the positive control proves the lock is observable, so `false` after resting fixes is now a meaningful assertion. It also resets the lock to `false` at start, which defends against ordering with `W85cTests`' paired async set/clear.

## (6) Diff scope

Confirmed in "Scope of change" above.

## New findings

### Minor / nit
- **#10: Tighten can fire mid-pan** (`ambientLookUserAdjusted` is set only on settle). See (2). `@ios-engineer`, low priority.
- **#11: `startDriveMode`'s nil-reset is untested.** `testDriveStartAndEnd_dropTheStaleRestingAccuracy` uses `setDriveModeActiveForTesting(true)` then `endDriveMode()`, so only the `endDriveMode` line is covered. One-line test addition.
- **#12: Wake-lock test lacks `addTeardownBlock { endDriveMode(); isIdleTimerDisabled = false }`.** Defensive; makes cleanup structural rather than reliant on non-aborting assertions.

## Smoke checklist deltas (Kevin's Mac)

The pass-1 list (items 1 to 17) stands. Re-point and add:

- Item 10 (Cruise End after real motion): now expect ONE smooth animation, with no rotation snap, ending at the launch zoom regardless of any in-Cruise pinch. Try a Cruise heading near 270 and watch which way it rotates to north (MapKit's choice; report if it takes the long way round).
- 18. Poor-then-good fix: after the tighten the dot sits at screen center and Recenter stays hidden (confirms #2).
- 19. Compile: confirm `AmbientDrivingLook.swift` and the 2 test classes build clean on the first Mac build (the switch-based `shouldTighten` was the targeted fix).
- 20. Flag-off Cruise End regression: with the flag off, End must still show the old pre-drive camera restore with the un-animated heading reset (byte-identical path).

## Verdict

MERGE once Kevin's Mac build is green and the live-UI smoke (items 1 to 8 plus 10, 18 to 20) passes. All pass-1 significant items are fixed; the remaining items are minor and not merge-gating.
