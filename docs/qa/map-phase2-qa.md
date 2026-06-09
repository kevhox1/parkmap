# Map Rebuild Phase 2 — Native Drive-Mode Follow — QA Report

**Reviewed:** branch `ios/map-phase2-drivefollow` @ `9220379` vs `docs/map-rebuild-native-mapkit-spec.md` Phase 2.
**Verdict:** PASS WITH NOTES (no blocking/significant findings) → merged via PR #55 (squash), build 1.0(6).
**Tests:** 446 / 0 (independently verified; Phase 1 baseline 435, net +11).

## Result
- P2-AC-1/2: Drive Mode entry/exit set `userTrackingMode = .follow`/`.none` via CoordinatorActions outside updateUIView. ✓
- P2-AC-3: removed symbols confirmed gone — `syncDriveRegion`, `shouldSyncDriveRegion`, `driveFollowEnabled`, `onDrivePanDetected`, `recenterDriveMap`, `handleDrivePanDetected`. ✓
- P2-AC-5 (heading orthogonality, the crux): `.follow` + manual `setCamera(heading:)` from GPS course are orthogonal per MapKit semantics (setCamera does not reset tracking mode). `.followWithHeading` absent from codebase (would reintroduce FT-7 compass bug). ✓
- P2-AC-6/7/8: pan → `mapView(_:didChange mode:)` → `onTrackingModeChanged` → `driveTrackingModeNone` → Recenter button; Recenter re-engages `.follow` + restores 45° pitch + FT-8 zoom. Guarded on driveModeActive. ✓
- P2-AC-9 (#31): updateUIView is camera-free (no setCamera/setRegion/userTrackingMode= except the pre-vetted syncDriveHeading). Overlay chain renders in smoke. ✓
- P2-AC-11: 446/0; FT10Tests rewritten to the tracking-mode state machine (substantive, no hollow/masking). ✓
- P2-AC-10: native `.follow` requires real GPS → **Kevin's on-device drive-test is the irreducible gate.**

## Findings (all minor, comment-only → tech-debt batch)
1. `isUserInteracting` doc comment still names deleted `shouldSyncDriveRegion`/`syncDriveRegion` (now used by syncDriveHeading).
2. `syncDriveHeading` comments name deleted `onDrivePanDetected`/`driveFollowEnabled`.
- Suggested: document the GPS-auth-gating invariant on `handleTrackingModeChanged` (why headless `.follow`-drop can't happen in prod).

## Notes
- Headless limitation: `.follow` on a bare MKMapView w/o GPS auth drops to `.none` immediately (MapKit docs). Production-safe because Drive Mode entry is gated on location auth. Tests assert wiring/state-machine, not headless follow-stays-on (no bogus green).
