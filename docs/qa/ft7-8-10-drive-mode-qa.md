# FT-7/8/10 — Drive Mode Camera & Interaction — QA Report

**Reviewed:** branch `ios/ft7-drive-mode-camera` @ `cb8abad` vs spec `docs/ft7-drive-mode-smoothness-heading-spec.md`
**Verdict:** PASS-WITH-NOTES (no blockers) → merged to main via PR #49 (squash `5704d2a`)
**Tests:** 426 / 0 (sim iPhone 17 Pro F0820726-15F4-4FA3-8602-A5D7B479A277), +31 new.

## Result
All ACs across FT-7 (course heading + animation), FT-8 (0.003° zoom), FT-10 (follow-pause gate) verified.
Architecture invariants hold: no `setRegion` on Drive Mode active path; RegionSyncGuardTests 4/4;
FT-5 `isUserInteracting` kept separate from FT-10 `driveFollowEnabled`; no new camera mutation racing
`updateUIView` (#31-safe); animated programmatic `setCamera` does not falsely pause follow (no active
gesture recognizer). Live-UI smoke: app builds, launches, overlay chain (ASP banner, toolbar) intact.

## Findings (all non-blocking, deferred as post-TF2 cleanup → tracked as FT-7-followup)
- **Significant #1:** `selectDriveHeadingSource` pure function is defined + unit-tested but NOT called
  in production — both `didUpdateHeading`/`didUpdateLocations` implement equivalent logic inline.
  Behavior is correct; the risk is a future divergence between the tested helper and the real path.
  Fix: wire the helper in as the canonical path (or document it as a spec artifact).
- **Nit #2:** stale `~0.005°` / `2,000m` comments in `DriveZoomStyleTests.swift` header (lines 19/22/29/30)
  — update to 0.003° / ~621m.
- **Nit #3:** `didUpdateHeading` stopped-in-Drive-Mode path passes magnetometer to `stabilizedHeading`
  (frozen by the speed gate, net result correct) instead of returning nil like the helper's Branch 2.
- **Nit #1 (resolved before merge):** branch had reverted the FT-9 field-log entry; restored to main's
  version in commit `c96773f`.

## Deferred to Kevin on-device (TF2)
Smoothness feel, real-mount arrow accuracy (course vs compass), tighter-zoom feel, pinch/pan + Re-center
while driving, no-snap-back while follow paused.
