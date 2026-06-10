# Build-7 Rotation Fixes — QA Report

**Reviewed:** branch `ios/build7-rotation-fixes` @ `96ca15a` vs TF2-3 (field-testing-log) + FT-11 QA Finding #1.
**Verdict:** PASS-WITH-NOTES (no blockers). **Tests: 479/0** (independently verified; +13).

## Fixes verified
- **Fix 1 — puck double-rotation (TF2-3 #1):** `syncDriveHeading` puck target now identity (0 = screen-up); `mapView(_:viewFor:)` puck init now `.identity`; `camera.heading = h` (heading-up) preserved; asset `location.north.fill` points up at rest. ⇒ map rotates heading-up + arrow points up = points toward travel. CORRECT.
- **Fix 2 — speed gate 1.8→0.5 m/s:** course-only preserved (no magnetometer; FT-7 intact); freeze-on-stop below 0.5; boundary tests (0.0/0.49/0.5/0.8) sound.
- **Fix 3 — chevron 90°:** `bearing-90` applied in both PinMarkerAnnotation CGContext + ReportSheet `.rotationEffect`; CGContext offset translation unchanged (correct in post-rotation frame). bearing=0→north, bearing=90→east.
- **#31:** no new camera mutation in updateUIView; syncDriveHeading is the pre-vetted exception; syncCommunityPinAnnotations pure add/remove diff (now `[id:Segment]` dict, no mutation). RegionSyncGuard/FT10/Phase-2 tests pass.

## Findings (none blocking)
- **SIGNIFICANT (acceptable, NOT from build-7): manual map rotation during Drive Mode → transient puck misdirection.** Phase 1 enabled `isRotateEnabled` globally; if the user manually rotates the map while driving, camera.heading diverges from travel heading so the identity puck points screen-up (the rotated direction), not travel — self-corrects on the next ~1Hz `syncDriveHeading`. Build-7 makes this *less* severe than before. PROPER FIX (future): set `isRotateEnabled=false` (± pitch) on Drive Mode entry, restore on exit — the Apple/Waze nav behavior + the FT-10 "no manual rotate in drive" intent. → tracked as TF2-3-followup.
- NIT: a shortestArcDelta 180° test asserts abs(delta)==π (correct, either direction). Comment polish.
- NIT: chevron tests verify the `bearing-90` formula, not the rendering stack (pure-function strategy; visual is Kevin's gate).

## Kevin's irreducible on-device gates
Arrow-up/map-turns-under feel while driving; chevron visual orientation on a live marker; sim overlay-chain screenshot (QA could not read the image this run — build launched clean).
