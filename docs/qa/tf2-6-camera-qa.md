# TF2-6 — Cruise Camera Fix — QA Report

**Reviewed:** `ios/tf2-6-cruise-camera` @ `02d5e16` vs TF2-6 (field-testing-log).
**Verdict:** PASS-WITH-NOTES (no blockers). **Tests: 480/0** (479-line grep figure = parallelization artifact; new test confirmed passing).

## Verified
- Entry order swapped: tracking (.follow) FIRST, pitch+zoom LAST (final writer) — matches the proven recenterDriveMode order. Exit order unchanged + reasoned sound (.follow only moves center, not pitch/altitude).
- Adversarial (make-or-break): programmatic .follow engagement does NOT emit a transient .none → no spurious Recenter button on entry. handleTrackingModeChanged sequencing sound; second safety layer via the synchronous driveTrackingModeNone=false.
- Buildings off in drive: new `CoordinatorActions.setShowsBuildings` (entry=false, exit=true), wired in makeUIView, called from .onChange — NOT in updateUIView (#31 ✓). (MKStandardMapConfiguration lacks showsBuildings on iOS 17 → MKMapView property, per spec fallback.)
- Pitch 45°→30° (Apple/Waze parity, tunable). Test updates legitimate (Test 10 rewritten ==30; Test 9 floor 25).
- No PWA/pbxproj/Info.plist/token changes.

## Findings
- NIT: Test 10 doc comment says "buildings visible" (inverted — feature hides them). Comment-only → tech-debt batch.

## Kevin's irreducible gate
On-device cruise entry with GPS motion: camera must end TIGHT (zoomed in), buildings flat, pitch 30°.
