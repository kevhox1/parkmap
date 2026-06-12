# TF2-11: Drive Mode Camera Ownership — Zoom War with `.follow`

**Feature:** Durable drive-mode altitude control  
**Owner:** @ios-engineer (after Kevin approves this spec); @qa-verifier per pass  
**Created:** 2026-06-12  
**Status:** SPEC — awaiting Kevin review before any engineering

---

## Decisions Kevin Needs Before Engineering Starts

These surface first. **No engineering until Kevin confirms.**

**OQ-1 (BLOCKING): Try Option C before committing to Option A?**  
Option C is a ~5-line, low-risk experiment. If it holds on-device, it closes TF2-11 cheaply. If it fails (visible ping-pong or the clamp does not cover MapKit's re-assert) Kevin runs the experiment and reports back; engineering then proceeds to Option A with no wasted build. The recommended path is: attempt C first → Kevin's on-device verdict → proceed to A if C fails. If Kevin would rather skip the experiment and go straight to the durable fix, Option A can be built directly with no penalty — it is fully spec'd here.

**OQ-2 (if C ships): Acceptable altitude ceiling during Drive Mode?**  
Option C's `maxCenterCoordinateDistance` determines how far out the user can pinch while driving. The spec recommends 900m (~0.0043° span) as the max. If Kevin wants more zoom freedom (e.g., backing out to see the whole route) a higher max is possible, but it narrows the gap between our target (~621m) and the ceiling, reducing protection against `.follow`'s re-assert. Kevin confirms the ceiling before C is built.

**OQ-3 (Option A only): Preserve user-adjusted altitude between GPS ticks?**  
If the user pinches to a different zoom during Drive Mode (per-tick custom follow), should the next GPS tick re-impose the spec'd ~621m altitude, or should it honor the user's manual zoom? Waze behavior: user pinch adjusts zoom and follow continues at the new zoom. The spec recommends tracking a `currentDriveAltitude` that user zoom updates (same model as Waze). Kevin confirms before Option A is built.

**OQ-4 (Option A only): Gesture-pause threshold for the Recenter button.**  
In Option A there is no `.follow` to break on pan — the Recenter button must be driven by `isUserInteracting` (the `regionWillChangeAnimated` gesture flag, which already exists for FT-5 browse mode). The relevant question: should any user gesture (pan AND pinch) show Recenter, or only pan? Pinch to zoom is arguably a "I want a different zoom level, keep following me" gesture (Waze model), while pan is "I want to look somewhere else." Recommended: pan shows Recenter; pinch does not (pinch updates `currentDriveAltitude` per OQ-3 and keep following). Kevin confirms.

---

## 1. Problem and User Story

**The problem — three failed fix rounds, all on-device confirmed:**

- **TF2-6:** Ordered our `setCamera` (pitch + tight zoom) AFTER engaging `.follow` → MapKit's asynchronous follow-zoom clobbered it. Fix: swap order — engage `.follow` FIRST, then issue our `setCamera`. This worked for the synchronous initial placement.
- **TF2-8:** Even with the correct order, MapKit's `.follow` performs its own zoom-to-default ASYNCHRONOUSLY after the user location is first acquired — after our synchronous `setCamera`. Fix: armed `pendingDriveCameraReapply` flag, fire one re-apply in `regionDidChangeAnimated` when the altitude has drifted >25% from target (one-shot, idempotence guarded, 6s backstop, user-takeover disarm).
- **TF2-11 (current, on-device confirmed):** Kevin observed TWO bounces (our entry zoom + our re-apply both visually fire) then MapKit zooms out again and WINS. **Root cause confirmed:** `userTrackingMode = .follow` re-asserts its preferred altitude on each subsequent location update, not just on initial acquisition. Our re-apply corrects one zoom-out; `.follow`'s location-update handler fires the next one. Any repeating correction produces visible camera ping-pong. A one-shot correction cannot durably win against a per-update re-assert.

**Conclusion:** A custom altitude cannot coexist with `userTrackingMode = .follow`. The two architecturally conflict. One of them must own the altitude exclusively.

**User story:** "As a WePark user in Drive Mode, I want the camera to stay at the tight FT-8 zoom (~621m altitude, one Manhattan block) throughout my drive — not bounce between tight and wide on every GPS update. The camera must feel as stable as Apple Maps."

**Why now:** TF2-11 is the last camera-correctness blocker before Drive Mode is usable for real-car navigation. The bounce is impossible to miss — Kevin observed it immediately on-device. Building further Drive Mode features (voice calibration, guidance, community-pin callouts) on top of a bouncing camera is not viable.

---

## 2. Scope — In / Out

### In (both options)

- iOS only. `ios/WePark/WePark/Views/MapViewRepresentable.swift` and `ios/WePark/WePark/ContentView.swift`.
- Durable altitude control during Drive Mode (Destination mode and Cruise/Find-Parking mode).
- Recenter button behavior preserved or improved.
- #31 architectural invariant maintained: no camera mutation inside `updateUIView`.

### Option C only (in)

- `mapView.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance:maxCenterCoordinateDistance:), animated:)` applied on Drive Mode entry, removed on exit.
- Keep the existing `pendingDriveCameraReapply` machinery as a belt-and-suspenders layer for the initial entry zoom (or remove it if the clamp makes it unnecessary — see §6.1).
- No change to `.follow` tracking mode.

### Option A only (in)

- Remove `userTrackingMode = .follow` from Drive Mode entirely. `userTrackingMode = .none` for the whole Drive Mode session.
- Per-tick animated `setCamera` combining center (user GPS position), heading (EMA course from FT-7), pitch (30°), and altitude (~621m / user-adjusted).
- Pause-follow state machine: `followPaused` flag; set on user-gesture pan via `isUserInteracting`; cleared on Recenter tap.
- `currentDriveAltitude` state variable tracking the user's pinch-adjusted altitude (persists across GPS ticks; re-imposed only on Drive Mode entry/Recenter).
- Remove `pendingDriveCameraReapply`, `pendingReapplyPriorPitch`, `CoordinatorActions.setDriveTrackingMode`, and `mapView(_:didChange:animated:)` delegate callback from the codebase.

### Out (both options)

- Changes to voice, commentary, FinalApproachService, DrivingContextService.
- Changes to PWA (`index.html`, `sw.js`).
- Changes to `@backend-data` or Supabase.
- Changes to `driveModePitch` or `driveModeCameraSpan` constants (tuning is a separate pass after on-device feedback).
- Full nav turn-by-turn ribbon, maneuver voice, ETA row (out per drive-mode-scope-spec.md §9).

---

## 3. Architecture

### Codebases touched

iOS only. Files:
- `ios/WePark/WePark/Views/MapViewRepresentable.swift`
- `ios/WePark/WePark/ContentView.swift`
- `ios/WePark/WeParkTests/` (test updates per option)

PWA: no changes. Backend: no changes.

### Current camera data flow (the problem)

```
Drive Mode entry:
  handleDriveModeAndCamera(true)
    → coordinatorActions.setDriveTrackingMode?(true)
       → mapView.userTrackingMode = .follow   [MapKit begins async zoom-to-default]
    → handleDriveCameraChange(true)
       → coordinatorActions.applyDrivePitch?(true, preDrivePitch)
          → applyDriveCameraState(active:true, …)
             → setCamera(pitch=30°, altitude=621m, animated:true)  [our last writer]

  Then asynchronously:
    .follow acquires user location → MapKit zoom-to-default → regionDidChangeAnimated fires
      → pendingDriveCameraReapply is armed → re-apply our setCamera (one-shot)

  Then on EVERY subsequent location update:
    .follow handler → MapKit re-asserts its preferred altitude → regionDidChangeAnimated fires
      → flag is already cleared (one-shot) → no re-apply → our altitude is GONE
      → visible zoom-out every ~1 Hz
```

### Option C: Camera Zoom Range Clamp

`MKMapView.CameraZoomRange` constrains ALL camera changes — including programmatic ones from `.follow`. By setting `maxCenterCoordinateDistance` to a value just above our target (e.g., 900m), MapKit's `.follow` re-assert cannot zoom out past the ceiling. Our `setCamera` at ~621m is within range (always allowed). The user's pinch cannot zoom out past 900m while driving (acceptable per the UX tradeoff discussion in §6.1).

```
Drive Mode entry:
  → coordinatorActions.setZoomRange?(enter: true)
     → mapView.setCameraZoomRange(
         MKMapView.CameraZoomRange(
           minCenterCoordinateDistance: 200,   // can't zoom tighter than ~200m
           maxCenterCoordinateDistance: 900    // can't zoom wider than ~900m
         ),
         animated: false
       )

  .follow re-assert on location update:
     → MapKit clamps altitude to ≤900m → stays near our 621m target
     → NO visible zoom-out

Drive Mode exit:
  → coordinatorActions.setZoomRange?(enter: false)
     → mapView.setCameraZoomRange(nil, animated: false)  // remove clamp
```

The `pendingDriveCameraReapply` flag may become redundant if the clamp prevents the initial entry zoom-out. The spec recommends KEEPING it for the initial entry correction (belt-and-suspenders: the first acquisition may still push altitude before the follow-settle, and a one-shot correction is harmless). If Kevin's on-device experiment confirms zero bounces, a follow-up cleanup PR can remove the reapply machinery.

### Option A: Custom Follow Camera

Remove `.follow`. On each GPS location update, issue a single animated `setCamera` with all four degrees of freedom set explicitly.

```
Drive Mode entry:
  handleDriveModeAndCamera(true)
    → userTrackingMode = .none (no .follow at all)
    → handleDriveCameraChange(true)  (unchanged: pitch=30°, altitude=621m, style, puck)
    → currentDriveAltitude = altitudeForSpan(driveModeCameraSpan)  // ~621m

Per location update (~1 Hz):
  handleLocationUpdate()
    → guard driveModeActive && !followPaused else { return }
    → coordinatorActions.setDriveCamera?(coord, driveHeading, currentDriveAltitude)
       → camera.centerCoordinate = coord
       → camera.heading = driveHeading ?? 0
       → camera.pitch = driveModePitch  // 30°
       → camera.centerCoordinateDistance = currentDriveAltitude
       → mapView.setCamera(camera, animated: true)
         [using the existing driveAnimationDuration = 0.3s pattern]

User pan during Drive Mode:
  regionWillChangeAnimated:
    → isUserInteracting = true (existing FT-5 gesture flag)
  → ContentView sees isUserInteracting: shows Recenter button (followPaused = true)

User pinch during Drive Mode (OQ-3 / OQ-4 dependent):
  → regionDidChangeAnimated: user-adjusted zoom → update currentDriveAltitude
  → next GPS tick: new setCamera uses currentDriveAltitude (not re-imposing entry altitude)
  → Recenter button NOT shown for pinch (OQ-4 recommendation)

Recenter button tap:
  → followPaused = false
  → currentDriveAltitude = altitudeForSpan(driveModeCameraSpan)  // reset to FT-8 default
  → Recenter button hides

Drive Mode exit:
  handleDriveModeAndCamera(false)
    → handleDriveCameraChange(false)  (unchanged: restore pre-drive pitch + zoom + style)
    → followPaused = false
    → currentDriveAltitude reset
```

**Why per-tick `setCamera` is safe (no #31 risk):** The #31 regression was caused by `setCamera` inside `updateUIView`, which raced SwiftUI's mount cycle. The per-tick `setCamera` in Option A is called from `handleLocationUpdate()`, which is triggered by `.onChange(of: locationService.locationUpdateCount)` — OUTSIDE `updateUIView`. This is identical to the existing pattern for all camera mutations since W8.5c-polish PR-3. The #31 invariant is maintained.

**Heading coexistence in Option A:** In the current architecture, `syncDriveHeading` is called from `updateUIView` and calls `setCamera(animated:true)` to update heading separately. In Option A, the per-tick `setCamera` already includes the heading — `syncDriveHeading` becomes redundant on the location-update path. However, `syncDriveHeading` also fires on heading-only updates (when position doesn't change). The correct Option A design is: on a heading-only update (no location update), `syncDriveHeading` still fires and still calls `setCamera(heading:)` — this is a no-op when `.follow` is gone because there is no tracking mode to protect. The two calls will occasionally overlap at 1 Hz; MapKit's cancel-and-restart animation behavior handles this correctly (same as today).

**Alternatively**, Option A can simplify `syncDriveHeading` to be absorbed into the per-tick `setCamera`. This is a refactor decision for @ios-engineer; the spec permits either approach as long as heading-only updates still work.

### New / changed symbols

**Option C — MapViewRepresentable.swift:**

| Symbol | Change |
|---|---|
| `CoordinatorActions.setZoomRange: ((Bool) -> Void)?` | NEW — called from `.onChange(of: driveModeActive)` in ContentView with `true` on entry, `false` on exit. NOT called from `updateUIView`. |
| `makeUIView` | Wire `coordinatorActions.setZoomRange` closure → calls `mapView.setCameraZoomRange(...)`. |

**Option C — ContentView.swift:**

| Symbol | Change |
|---|---|
| `handleDriveModeAndCamera(_:)` | Add `coordinatorActions.setZoomRange?(active)` call. Place BEFORE `coordinatorActions.setDriveTrackingMode?(true)` on entry and AFTER `coordinatorActions.setDriveTrackingMode?(false)` on exit, so the clamp is in place before `.follow` can re-assert. |

**Option A — MapViewRepresentable.swift:**

| Symbol | Change |
|---|---|
| `CoordinatorActions.setDriveTrackingMode` | REMOVED |
| `CoordinatorActions.pendingDriveCameraReapply` | REMOVED |
| `CoordinatorActions.pendingReapplyPriorPitch` | REMOVED |
| `CoordinatorActions.setDriveCamera: ((CLLocationCoordinate2D, Double?, Double) -> Void)?` | NEW — called from `.onChange(of: locationService.locationUpdateCount)` when `driveModeActive && !followPaused`. |
| `mapView(_:didChange:animated:)` delegate callback | REMOVED — no `.follow` to break. |
| `regionDidChangeAnimated` — `pendingDriveCameraReapply` block | REMOVED |

**Option A — ContentView.swift:**

| Symbol | Change |
|---|---|
| `@State followPaused: Bool` | NEW — replaces `driveTrackingModeNone`. |
| `@State currentDriveAltitude: CLLocationDistance` | NEW — tracks user-adjusted or entry altitude. |
| `handleTrackingModeChanged(_:)` | REMOVED — no tracking mode changes to handle. |
| `handleLocationUpdate()` | ADD: drive-camera setCamera call when `driveModeActive && !followPaused`. |
| `recenterDriveMode()` | SIMPLIFY: set `followPaused = false`, reset `currentDriveAltitude`, call `coordinatorActions.applyDrivePitch?(true, preDrivePitch)`. No `setDriveTrackingMode` call. |
| `handleDriveModeAndCamera(_:)` | Remove `coordinatorActions.setDriveTrackingMode?(...)` calls. |

**What gets DELETED if Option A ships (full inventory):**

- `CoordinatorActions.setDriveTrackingMode: ((Bool) -> Void)?` (MapViewRepresentable)
- `CoordinatorActions.pendingDriveCameraReapply: Bool` (MapViewRepresentable)
- `CoordinatorActions.pendingReapplyPriorPitch: CGFloat` (MapViewRepresentable)
- The entire `pendingDriveCameraReapply` block in `regionDidChangeAnimated` (~25 lines, MapViewRepresentable ~1540–1562)
- `mapView(_:didChange:animated:)` delegate callback (~15 lines, MapViewRepresentable ~1594–1604)
- `handleTrackingModeChanged(_:)` (ContentView ~line 2142)
- `@State driveTrackingModeNone: Bool` (ContentView)
- The `coordinatorActions.setDriveTrackingMode?(true/false)` calls in `handleDriveModeAndCamera` (ContentView ~lines 2088, 2126)
- The `coordinatorActions.pendingDriveCameraReapply = true/false` lines (ContentView ~lines 2107, 2121)
- The `DispatchQueue.main.asyncAfter(deadline: .now() + 6.0)` timeout backstop (ContentView ~lines 2113–2116)
- All comments referencing the TF2-8 armed-flag design (becomes stale)

Note: `isUserInteracting` is KEPT in Option A. It was already needed for FT-5 (browse mode pan suppression) and is now reused as the user-gesture signal for the `followPaused` state machine.

### Tables / RPCs / new files

None for either option. Pure client-side camera change.

---

## 4. Work Streams

Both options are iOS-only single-codebase changes. No parallel agent execution needed.

| Stream | Agent | When | Notes |
|---|---|---|---|
| C-A: Apply zoom range clamp | @ios-engineer | After Kevin's OQ-1/OQ-2 approval | ~30 min |
| C-QA: On-device experiment + live-UI smoke | @qa-verifier (smoke) + Kevin (on-device) | After C-A | Kevin's result is the go/no-go for Option A |
| A-A: Custom follow camera + follow-paused state machine | @ios-engineer | If C fails or Kevin skips C | ~2–3 sessions |
| A-B: Test rewrite (remove TF2-8 tests, add custom-follow tests) | @ios-engineer | Part of same PR as A-A | |
| A-QA: Live-UI smoke + drive-mode code review | @qa-verifier | After A-A + A-B | Mandatory sim screenshot gate |
| A-Drive: Kevin on-device real-device drive test | Kevin | After A-QA passes | Irreducible gate for moving-GPS camera behavior |

**Sequencing:** C-A → Kevin experiment (go/no-go) → either done (C held) or A-A → A-B → A-QA → A-Drive.

**If Kevin chooses to skip Option C entirely:** Start at A-A directly.

---

## 5. Option C: Experiment Protocol

Kevin runs this before any further engineering. The experiment takes ~10 minutes with the TestFlight build.

**What to observe (each item is a pass/fail question):**

1. **Entry zoom settles tight:**  
   Enter Cruise Mode or Destination Drive Mode while the phone is showing GPS movement (driving or walking, even slow movement counts — the location must be updating). Wait 5–10 seconds after entry. Does the camera stay at the tight ~1-block zoom without bouncing out to the city-wide view? The clamp should prevent MapKit from zooming past 900m, so any re-assert above that is blocked.

2. **No visible ping-pong:**  
   On each location update (~1 Hz), is the camera stable (no visible zoom-in/zoom-out oscillation)? Previously two bounces were visible; with the clamp, `.follow` can still animate within the clamped range (200m–900m), but it cannot zoom out past 900m. There may still be small altitude adjustments within the range — these are acceptable as long as they are not jarring.

3. **Pinch zoom behavior:**  
   While in Drive Mode, try pinching out (zooming out). The camera should stop zooming out at or before ~900m (the max clamp). If you pinch in further (zooming in), that works freely (the min clamp of 200m is below our target). Is the cap at ~900m acceptable while driving, or does it feel too restrictive?

4. **Recenter behavior:**  
   Pan away from your location (showing the Recenter button). Tap Recenter. Does the camera snap back to the tight ~621m zoom? (It should — `applyDrivePitch` explicitly sets `centerCoordinateDistance` to our target, which is within the clamped range.)

5. **Exit behavior:**  
   End Drive Mode. Does the map return to normal (no zoom clamp, free to zoom anywhere)? Try pinching out wide after exiting — it should work without limit.

**Pass criteria:**  
All five items pass → Option C ships; TF2-11 closes with a ~5-line fix.

**Fail criteria:**  
Item 1 fails (zoom still bounces to wide) → the clamp does not prevent `.follow`'s internal re-assert; proceed to Option A.  
Item 2 fails (visible jitter within clamped range) → per-tick animation within the 200–900m range is jarring; proceed to Option A.  
Items 3–5 are UX calibration — any concerns go back to Kevin's OQ-2 answer.

---

## 6. Analysis

### 6.1 Option C: Does `setCameraZoomRange` actually constrain `.follow`'s programmatic zooms?

Per Apple's documentation for `MKMapView.setCameraZoomRange(_:animated:)`: "Restricts the camera zoom range of the map view. Setting a camera zoom range constrains the camera's `centerCoordinateDistance` property to the range you specify, preventing both programmatic and user-initiated zooming beyond the specified range." The phrase "both programmatic and user-initiated" is the key claim — it should constrain `.follow`'s internal camera updates. However, the iOS SDK docs are sometimes imprecise about whether "programmatic" includes MapKit's own internal tracking-mode updates vs. app-code `setCamera` calls. **This is why the on-device experiment is required.** If MapKit exempts its own `userTrackingMode` camera updates from the zoom range (treating them as internal, not "programmatic app code"), Option C fails silently and we proceed to A.

**If Option C works:** The `pendingDriveCameraReapply` machinery (armed flag, `regionDidChangeAnimated` hook, 6s backstop) may become redundant. However, the spec recommends keeping it for the initial entry correction because the first `.follow` acquisition may still push altitude briefly before the clamp engages. A follow-up cleanup PR can remove it once Kevin confirms zero bounces with the clamp alone.

**Interaction with `syncDriveHeading`'s `setCamera` calls:** Our `setCamera` calls set `centerCoordinateDistance = ~621m`, which is within the 200–900m clamped range. The clamp does not affect our calls. No regression.

**Interaction with Recenter:** `applyDrivePitch` sets `centerCoordinateDistance` to `altitudeForSpan(driveModeCameraSpan)` (~621m). Within range. No regression.

### 6.2 Option A: Is per-tick `setCamera` smooth enough?

The existing `syncDriveHeading` already issues `setCamera(animated: true)` on every heading update (~1 Hz or faster). The pattern is proven — it is the production heading-up rotation that has been shipping since W8.5c. Adding `centerCoordinate` and `pitch` to the same call does not change the frequency or the animation duration (still `driveAnimationDuration = 0.3s`). The heading animation was already smooth on-device (confirmed in TF2-6 Kevin smoke). A per-tick `setCamera` that combines all four properties (center + heading + pitch + altitude) in one call is strictly better than the current two-call approach (`.follow` for center + `setCamera` for heading) because it eliminates the interaction between two parallel animation sources.

**Will MapKit retarget in-flight animations?** Yes — `setCamera(animated: true)` while a previous animation is in flight cancels the previous one and starts fresh. At 1 Hz location updates and 0.3s duration, each animation completes with 0.7s to spare. This is the same logic as FT-7 (`docs/ft7-drive-mode-smoothness-heading-spec.md`).

**The shortest-arc heading logic:** Currently `syncDriveHeading` uses `shortestArcDelta` and the `lastAppliedHeading` dead-band to prevent unnecessary camera updates. In Option A, the per-tick `setCamera` should reuse the same dead-band (`lastAppliedHeading`, 2° threshold). If the heading has not changed by more than 2°, skip the per-tick `setCamera` for heading — but still apply it when the GPS coordinate changes, since center-coordinate updates are always meaningful. The exact dead-band logic is an implementation decision for @ios-engineer; the spec requires that spurious zero-delta camera calls are suppressed.

### 6.3 `#31` safety for Option A

The #31 regression occurred because `setCamera` was called inside `updateUIView`. The per-tick `setCamera` in Option A fires from `handleLocationUpdate()` which is called from `.onChange(of: locationService.locationUpdateCount)`. This is the same safe pattern as `applyDrivePitch` (called from `.onChange(of: driveModeActive)`). No mutation inside `updateUIView`. #31 invariant maintained.

The @ios-engineer MUST include the following invariant comment in the PR, as required since the post-#31 norm:
> "No camera mutation (`setCamera`, `setRegion`, `userTrackingMode =`) happens inside `updateUIView`. All camera mutations are driven from `.onChange` handlers in ContentView or from MapKit delegate callbacks."

### 6.4 Option A: The `followPaused` state machine (replaces `driveTrackingModeNone`)

The current `driveTrackingModeNone` flag is set by `handleTrackingModeChanged(.none)` when MapKit breaks `.follow` on user pan. In Option A there is no `.follow` to break, so there is no tracking-mode delegate callback to rely on. The replacement signal is `isUserInteracting` — the existing FT-5 gesture flag that is set in `regionWillChangeAnimated` when an active gesture recognizer is detected, and cleared in `regionDidChangeAnimated`.

State machine:

```
State: followPaused (Bool, default false)

followPaused = false  (following):
  - GPS updates → per-tick setCamera fires (center + heading + pitch + altitude)
  - Recenter button: hidden
  - User pan gesture:
    regionWillChangeAnimated: isUserInteracting = true
    → followPaused = true
    → Recenter button: shown

followPaused = true  (paused):
  - GPS updates → per-tick setCamera SKIPPED (guard followPaused)
  - Recenter button: shown
  - Recenter tap:
    → followPaused = false
    → currentDriveAltitude = altitudeForSpan(driveModeCameraSpan)  // reset to FT-8
    → coordinatorActions.applyDrivePitch?(true, preDrivePitch)  // re-apply pitch + zoom explicitly
    → Recenter button: hidden

Drive Mode exit:
  → followPaused = false (always clear on exit)
```

Note: `isUserInteracting` already clears itself in `regionDidChangeAnimated` (after the map settles). The `followPaused` flag should NOT be automatically cleared when `isUserInteracting` clears — a user who pans away should stay in pause mode until they explicitly tap Recenter. This is a behavior change from the current system where tracking-mode breaks on pan, which is symmetrical. The `followPaused` flag must be managed independently of `isUserInteracting`.

### 6.5 Option A: User-adjusted altitude (`currentDriveAltitude`, OQ-3)

Current behavior: `applyDriveCameraState` sets `centerCoordinateDistance` to `altitudeForSpan(driveModeCameraSpan)` (~621m) on every Drive Mode entry and Recenter. The user cannot persistently adjust zoom during Drive Mode without it being reset.

Recommended Option A behavior (pending OQ-3 Kevin decision): introduce `@State currentDriveAltitude: CLLocationDistance` initialized to `altitudeForSpan(driveModeCameraSpan)` on Drive Mode entry. When the user pinches to zoom during Drive Mode (while NOT in `followPaused` mode — per OQ-4, pinch does not pause follow), the `regionDidChangeAnimated` callback reads `mapView.camera.centerCoordinateDistance` and updates `currentDriveAltitude`. The next GPS tick fires `setCamera` with the updated `currentDriveAltitude`. Tapping Recenter resets `currentDriveAltitude` to the FT-8 default.

This matches Waze and Apple Maps behavior: user pinch adjusts zoom and follow continues at the new zoom; Recenter is the explicit "go back to default" action.

If Kevin prefers re-imposing the FT-8 altitude on every tick (no user-adjustable zoom in Drive Mode), set `currentDriveAltitude` to a constant and never update it from gestures. This is simpler but less Waze-like.

---

## 7. Acceptance Criteria

### Option C

- [ ] **C-AC-1.** `makeUIView` wires `coordinatorActions.setZoomRange` closure that calls `mapView.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 200, maxCenterCoordinateDistance: <Kevin-confirmed value>), animated: false)` on entry and `mapView.setCameraZoomRange(nil, animated: false)` on exit. Verified by code review.
- [ ] **C-AC-2.** The `setZoomRange` closure is called from `handleDriveModeAndCamera(_:)` via `.onChange(of: driveModeActive)` — NOT from `updateUIView`. Verified by grep: `setCameraZoomRange` does not appear inside `updateUIView`.
- [ ] **C-AC-3.** `altitudeForSpan(driveModeCameraSpan)` (~621m) is within the clamped range (`minCenterCoordinateDistance` ≤ 621 ≤ `maxCenterCoordinateDistance`). Verified by reading the constants.
- [ ] **C-AC-4 (live-UI smoke).** Fresh app launch in Simulator: toolbar, ASP banner, Park Until pill all visible. Screenshot artifact in QA report. #31 regression check.
- [ ] **C-AC-5 (live-UI smoke).** Enter Drive Mode in Simulator: "End Drive" pill, "Park here" button, drive overlay all visible. Screenshot artifact in QA report.
- [ ] **C-AC-6 (Kevin on-device — irreducible gate).** Enter Drive Mode with GPS motion. Camera settles at the tight zoom and stays. No visible bounce to wide city view. All five experiment-protocol observations pass (§5). Kevin documents result in the field testing log.
- [ ] **C-AC-7.** `xcodebuild test` passes at or above current baseline (516/0 per build 10). No net test count decrease without explicit replacement.

### Option A (additional to C-AC-4, C-AC-5 which carry over)

- [ ] **A-AC-1.** `userTrackingMode` is NOT set to `.follow` anywhere in the Drive Mode path. Verified by: `grep "userTrackingMode.*follow" MapViewRepresentable.swift ContentView.swift` returns zero results in Drive Mode code paths (only in comments documenting the old architecture).
- [ ] **A-AC-2.** All removed symbols are gone: `CoordinatorActions.setDriveTrackingMode`, `CoordinatorActions.pendingDriveCameraReapply`, `CoordinatorActions.pendingReapplyPriorPitch`, `mapView(_:didChange:animated:)` Drive Mode delegate callback, `handleTrackingModeChanged`, `driveTrackingModeNone`. Verified by grep.
- [ ] **A-AC-3.** `handleLocationUpdate()` in ContentView contains a guard that fires per-tick `setCamera` ONLY when `driveModeActive && !followPaused`. Verified by code review.
- [ ] **A-AC-4.** Per-tick `setCamera` is called from a `.onChange(of: locationService.locationUpdateCount)` path — NOT from `updateUIView`. Verified by grep: `setDriveCamera` (or equivalent) closure is populated in `makeUIView`, not `updateUIView`.
- [ ] **A-AC-5 (follow-paused — pan).** Live-UI smoke: enter Drive Mode in Simulator, pan the map. Recenter button appears. Per-tick camera updates are paused (map stays at panned position). Screenshot artifact required.
- [ ] **A-AC-6 (follow-paused — recenter).** Tap Recenter. Map snaps to simulated GPS position. Recenter button disappears. Camera is at 30° pitch + FT-8 altitude. Screenshot artifact required.
- [ ] **A-AC-7 (altitude stability — sim).** In Simulator with `simctl location start` providing moving GPS (straight-line vector), observe the map following the simulated position for 10+ seconds. No zoom-out bounces. Screenshot at 10s showing tight zoom. This is the in-simulator stand-in for the full on-device test.
- [ ] **A-AC-8 (pitch preserved between ticks).** Each per-tick `setCamera` call uses `driveModePitch` (30°). Camera does NOT reset to 0° pitch between updates. Verified by code review: the Coordinator's `setDriveCamera` closure sets `camera.pitch = driveModePitch` on every call.
- [ ] **A-AC-9 (heading preserved).** `syncDriveHeading` (or the per-tick heading update in the combined `setCamera` call) still fires based on GPS course. Heading-up rotation still works. Verified by code review: the EMA course / `selectDriveHeadingSource` logic is preserved in `LocationService`; the heading is passed to the `setDriveCamera` closure.
- [ ] **A-AC-10 (#31 regression check).** Confirmed in A-AC-4 (live-UI smoke shows overlays intact). The #31 invariant comment is present in the PR diff.
- [ ] **A-AC-11 (test suite).** `xcodebuild test` passes. Net count ≥ current baseline minus deleted TF2-8 / tracking-mode tests plus new custom-follow tests. @ios-engineer documents the exact delta in the PR.
- [ ] **A-AC-12 (Kevin on-device — irreducible gate).** Kevin drives at least 2 blocks in Destination or Cruise mode. Camera follows car position smoothly. No zoom-out bounce. Heading rotates to course. Recenter button appears on pan; disappears on tap. Kevin documents in field testing log.

---

## 8. Open Decisions (Summary)

| ID | Question | Who | Blocks |
|---|---|---|---|
| OQ-1 | Try Option C first, or go straight to Option A? | Kevin | Engineering start |
| OQ-2 | Acceptable `maxCenterCoordinateDistance` for Option C clamp? Spec recommends 900m. | Kevin | C-A build |
| OQ-3 | Preserve user-adjusted altitude in Option A per-tick follow (Waze model)? | Kevin | A-A implementation detail |
| OQ-4 | Does user pinch trigger `followPaused` + Recenter (Option A)? Spec recommends pinch does NOT pause. | Kevin | A-A implementation detail |

---

## 9. Effort Estimates

**Option C:**  
~30 minutes of engineering. One new `CoordinatorActions` closure, two calls to `setCameraZoomRange` in one new method, one call site in `handleDriveModeAndCamera`. One or two new unit tests (verify the closure is wired, verify the call sequence). The primary time cost is Kevin's on-device experiment.

**Option A:**  
~2 sessions of engineering. Session 1: remove `setDriveTrackingMode` / `pendingDriveCameraReapply` / `mapView(_:didChange:animated:)` machinery; add `currentDriveAltitude` and `followPaused` state; add `setDriveCamera` closure and per-tick call in `handleLocationUpdate`; wire the `isUserInteracting` → `followPaused` flow. Session 2: test rewrite (remove ~15 TF2-8 tracking-mode tests; add ~10–15 new custom-follow tests covering altitude stability, follow-paused state machine, OQ-3 altitude preservation, pitch preservation); QA pass; sim smoke.

Kevin's on-device drive test is required for both options and is outside engineering time.

---

## 10. Related Specs and Docs

- `docs/map-rebuild-native-mapkit-spec.md` — Phase 2 spec that introduced `.follow` (now confirmed to be the root cause of TF2-11). Phase 2 is the code TF2-11 replaces or patches.
- `docs/field-testing-log.md` — TF2-11 field finding (line 37); TF2-6 (line ~88) and TF2-8 (line ~65) prior fix rounds.
- `docs/qa/tf2-8-9-qa.md` — QA report confirming the TF2-8 one-shot design (now proven insufficient).
- `docs/qa/tf2-6-camera-qa.md` — QA report for TF2-6 entry-order fix.
- `docs/w8.5c-polish-pr3-spec.md` — W8.5c-polish PR-3 spec introducing the `CoordinatorActions` `.onChange`-driven camera pattern that Option A extends.
- `docs/w8.5c-polish-pr2-spec.md` — PR-2 spec for `applyDriveCameraState` (the combined setCamera pattern Option A reuses for the per-tick call).
- `docs/qa/w8.5c-polish-pass-1-2026-05-25.md` — The #31 regression QA report (the failure mode this spec's #31 invariant prevents).
- `docs/ft7-drive-mode-smoothness-heading-spec.md` — GPS course / EMA heading design (preserved in both options).

---

## 11. Out-of-Scope Follow-Ups

**Cleanup PR if C ships:** If Option C works, the `pendingDriveCameraReapply` machinery (armed flag, `regionDidChangeAnimated` hook, 6s backstop timeout, TF2-8 comments in `handleDriveModeAndCamera`) can be removed in a subsequent housekeeping PR. Defer until Kevin's on-device confirmation proves zero bounces — belt-and-suspenders during the initial C validation period.

**Stale comments if A ships:** Several comments in `MapViewRepresentable.swift` and `ContentView.swift` reference the TF2-8 armed-flag design, the `pendingDriveCameraReapply` behavior, and the Phase 2 tracking-mode rationale. All become stale if Option A ships. Bundle the comment cleanup with the Option A PR rather than a separate pass.

**Dead-band for per-tick altitude in Option A:** Currently `syncDriveHeading` uses a 2° dead-band to suppress spurious heading-only camera calls. Option A's per-tick `setCamera` might benefit from a similar altitude dead-band (skip if `currentDriveAltitude` is within X% of the current altitude). Defer to on-device calibration after A ships — it is not required for correctness.

**Heading-only updates in Option A:** When `LocationService` fires a heading update without a position update, `syncDriveHeading` currently fires a `setCamera(heading:)` call. In Option A this is preserved (heading-only update → heading-only `setCamera`). A future cleanup could absorb heading-only updates into the per-tick `setCamera` for a single camera update path. Not in scope for TF2-11.
