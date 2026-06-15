# TF2-11 Option A — Custom Follow Camera — QA Report

**Reviewed:** `ios/tf2-11-option-a` @ `6c6ed71` vs docs/tf2-11-drive-camera-ownership-spec.md (Option A).
**Verdict:** PASS WITH NOTES (no blockers) → merged via PR #62 (squash 9500d2e), build 12.
**Tests:** 514/0 (QA-measured; the FT10Tests header arithmetic claiming 525 is off — nit #2 below).

## Make-or-break adversarial traces — both PASS
- **Heading NOT double-set:** per-tick `setDriveCamera(coord, nil, altitude)` passes nil heading; closure only writes heading when non-nil; `syncDriveHeading` retains exclusive course-EMA heading ownership. No fight.
- **No pinch feedback loop:** programmatic per-tick setCamera fires regionWillChange with NO active gesture recognizer → wasUserInteracting=false → onDrivePinchZoomed NOT triggered → currentDriveAltitude not corrupted. Loop cannot occur.

## Verified
- No `userTrackingMode = .follow` anywhere in Drive Mode (A-AC-1).
- Deletion inventory complete: setDriveTrackingMode, pendingDriveCameraReapply/PriorPitch, setZoomRange, min/maxDriveZoomDistance, onTrackingModeChanged, driveTrackingModeNone, handleTrackingModeChanged, didChange tracking delegate, 6s timeout — all gone, no dangling refs.
- Per-tick guard `!followPaused && currentDriveAltitude>0`; pitch 30° each tick; pause via pan-gesture detection → Recenter; pinch altitude capture (OQ-3, Waze-style zoom persistence).
- #31-safe (no camera mutation in updateUIView; syncDriveHeading the pre-vetted exception). Overlay chain renders. No PWA/backend/pbxproj/token/Calendar.current.

## Notes (non-blocking → tech-debt batch)
1. `onDrivePinchZoomed` doc comment says `!followPaused` but code fires regardless (intentional — altitude capture even when paused). Doc-only.
2. FT10Tests header test-count arithmetic wrong (says 525; actual 514). Comment-only.
3. Pre-existing stale `isUserInteracting` doc comment references deleted `shouldSyncDriveRegion`.
- Inherent: at 1Hz a GPS tick mid-pinch can retarget altitude (known per-tick tradeoff; ~0.7s window usually lets pinch settle).

## Irreducible gate (Kevin, build 12, on-device drive)
Smooth follow / stays-tight / heading-up / Recenter-on-pan / pinch persists — the sim can't move GPS.
