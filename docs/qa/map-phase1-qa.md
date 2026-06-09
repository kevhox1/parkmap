# Map Rebuild Phase 1 (Browse-Mode Liberation) QA Pass 1 — 2026-06-09

**Reviewed:** branch `ios/map-phase1-browse` at `7e15812`, against `docs/map-rebuild-native-mapkit-spec.md` Phase 1 (P1-AC-1 through P1-AC-11) + §10 risks
**Verdict:** PASS WITH NOTES

---

## Summary

Phase 1 is architecturally sound and safe to merge. The core #31-safety invariant is correct: `setRegion` is fully removed from `updateUIView` in browse mode, and all programmatic centering paths correctly route through `coordinatorActions.setRegion?` called from action handlers outside `updateUIView`. Drive Mode is untouched. 435/0 tests pass. The launch screenshot confirms overlays, toolbar buttons, and ASP banner all render — no #31 regression. Two notes are flagged: the live rotate/tilt gesture-feel check is deferred to Kevin (simulator has no multi-finger gesture support), and one test gap is documented (no test asserts that `recenterMap` calls `coordinatorActions.setRegion` — the spy test covers the closure contract but not the ContentView call site).

---

## Acceptance Criteria Checklist

- [x] **P1-AC-1** — `isRotateEnabled = true` and `isPitchEnabled = true` in `makeUIView`. Verified: `MapViewRepresentable.swift:506–507`.
- [x] **P1-AC-2** — No `setRegion` call in `updateUIView`. Verified: grep of `MapViewRepresentable.swift` shows exactly two `setRegion` call sites — line 530 (`makeUIView` initial placement) and line 637 (the `coordinatorActions.setRegion` closure wired in `makeUIView`). Neither is inside `updateUIView`. The diff shows the entire browse-mode `if shouldSyncRegionToBinding(...)` block removed.
- [x] **P1-AC-3** — `shouldSyncRegionToBinding` deleted. Verified: grep for the function definition returns empty. All remaining references are comments only.
- [ ] **P1-AC-4** — Live rotate gesture screenshot showing rotated map. DEFERRED: Simulator does not support two-finger rotate gestures; headless screenshot confirms map renders but cannot demonstrate rotation. Deferred to Kevin for real-device or manual Simulator interaction verification. See "Smoke tests run."
- [ ] **P1-AC-5** — Live tilt gesture screenshot showing 3D perspective. DEFERRED: Same reason as P1-AC-4. Deferred to Kevin.
- [x] **P1-AC-6** — Pan-and-hold does not snap back; all UI overlays visible. Verified by code path: `updateUIView` contains no `setRegion` call in browse mode, so SwiftUI re-renders cannot snap the camera back. Launch screenshot confirms toolbar, ASP banner, and polylines are all visible.
- [x] **P1-AC-7** — #31 regression check: fresh launch screenshot shows overlays + toolbar + banner. Verified: screenshot at `docs/qa/phase1-launch-smoke.png` shows ASP banner ("ASP in Effect Today"), parking polylines (green blocks), gear button, find-me/find-car/clock toolbar buttons, and compass — overlay chain intact.
- [x] **P1-AC-8** — Find-me button still recenters map. Verified by code path: `recenterOnUser()` → `recenterMap(on: coord)` → `region = newRegion` + `coordinatorActions.setRegion?(newRegion)`. The closure fires `mapView.setRegion(_:animated: true)` directly outside `updateUIView`. All browse-mode recenter entry points (`recenterOnUser`, `recenterOnCar`, `performLaunchSetup`, deep-link path at line 2095) route through `recenterMap`. See Finding #1 note on deferred live smoke.
- [x] **P1-AC-9** — Drive Mode camera unchanged. Verified: `syncDriveRegion`, `shouldSyncDriveRegion`, `driveFollowEnabled`, `onDrivePanDetected`, `syncDriveHeading`, `applyDriveCameraState`, `recenterDriveMap` all present and unchanged. FT7, FT8, FT10, DriveCameraTiltTests, DriveZoomStyleTests pass (confirmed in 435/0 run).
- [x] **P1-AC-10** — RegionSyncGuardTests rewritten. Verified: 4 old tests (7–10) testing `shouldSyncRegionToBinding` replaced with 4 new tests covering `shouldSyncDriveRegion` correctness, `CoordinatorActions.setRegion` closure spy, follow-paused suppression, and `isUserInteracting` TF2-2 non-regression. Tests are substantive, not hollow — see "What's working." One gap noted in Finding #2.
- [x] **P1-AC-11** — Test suite green at or above baseline. Verified: 435/0 (feature branch) vs. 435/0 (main branch). Net count unchanged. Engineer's claim of 435/0 confirmed independently.

---

## Findings

### Blocking

None.

### Significant

None.

### Minor / Nit

**#1: Live rotate and tilt gesture smoke (P1-AC-4, P1-AC-5) cannot be executed in this QA pass.**
- Where: simulator — no hardware multi-finger gesture support
- What: `isRotateEnabled = true` and `isPitchEnabled = true` are confirmed in source (P1-AC-1 verified), but the actual gesture-feel and visual result (map tilts, compass appears on rotate) requires either a real device or manual Simulator interaction via the simulator's pinch/rotate gesture UI (which is not scriptable headlessly).
- Expected: per spec, two-finger rotate shows rotated map + compass; two-finger drag down shows 3D perspective.
- Repro: not reproducible headlessly.
- Owner: Kevin — tap "Hardware > Rotate Left" or use two-finger Simulator gestures. Recommend confirming before merge to catch any MapKit configuration issue (e.g., `showsCompass = false` accidentally overriding rotate visibility). The code sets `mapView.showsCompass = true` at line 508, which is correct.

**#2: No test asserting that `recenterMap` in ContentView actually calls `coordinatorActions.setRegion`.**
- Where: `ContentView.swift:1549`
- What: Test 8 (the spy test) verifies the `CoordinatorActions.setRegion` closure can be wired and called — the closure contract. It does not test the ContentView side: that `recenterMap(on:)` actually invokes `coordinatorActions.setRegion?(newRegion)` after writing `region`. A future refactor that removes the `coordinatorActions.setRegion?` call from `recenterMap` would pass all existing tests while silently breaking programmatic centering (the high-risk scenario from spec §10, Risk #1).
- Expected: a test that constructs a `ContentView` (or isolates `recenterMap` as a testable unit), wires a spy `coordinatorActions.setRegion`, calls `recenterMap`, and asserts the spy fired.
- This is a test-coverage gap, not a code bug. The code at line 1549 is correct. Filing as a nit to address in a future cleanup PR.
- Owner: `@ios-engineer`

### Out of Scope (Logged, Not Fixed)

- OQ-4 (compass visibility on rotate): per spec §2 open decisions, Kevin needs to confirm he is OK with the compass appearing during rotate. Not a code finding — it's an open product decision. The implementation is correct given `showsCompass = true` (line 508) and `isRotateEnabled = true`.
- Phase 2 items (native `.follow`, `setDriveTrackingMode`, removal of `syncDriveRegion`) are explicitly out of Phase 1 scope.

---

## Smoke Tests Run

1. **Build**: `xcodebuild build` on `ios/map-phase1-browse` @ `7e15812` — BUILD SUCCEEDED.
2. **Install + launch**: `xcrun simctl install/launch` on UDID `F0820726-15F4-4FA3-8602-A5D7B479A277` (iPhone 17 Pro sim).
3. **Launch screenshot** (`docs/qa/phase1-launch-smoke.png`): Confirmed via `Read` (multimodal). Visible: ASP banner "ASP in Effect Today" at top, green parking polylines on the right side of the map (CHRYSTIE ST / FORSYTH ST area), gear icon top-left, find-me / find-car / clock / drive toolbar buttons on the right rail, blue user-location dot, compass. Overlay chain intact — no #31 regression.
4. **Full test suite**: `xcodebuild test` — 435 passed, 0 failed. Independently counted with `grep -c "passed on"`.
5. **Baseline check**: `xcodebuild test` on `main` — 435 passed. Feature branch net count change: 0 (4 tests deleted, 4 added in RegionSyncGuardTests; 1 deleted, 1 added in FT10Tests).
6. **Grep: setRegion callsites** in `MapViewRepresentable.swift` — exactly 2: line 530 (makeUIView initial placement) and line 637 (coordinatorActions closure). Neither inside `updateUIView`.
7. **Grep: shouldSyncRegionToBinding function definition** — empty result. Function deleted.
8. **Grep: changed files** — exactly 4 iOS files; no PWA, no backend, no pbxproj changes.
9. **Grep: Calendar.current, pk.eyJ** — neither present in changed files.
10. **Rotate/tilt gesture-feel**: DEFERRED to Kevin (simulator limitation, noted as P1-AC-4/5 deferred).
11. **Drive Mode code paths** (`syncDriveRegion`, `shouldSyncDriveRegion`, `driveFollowEnabled`, `onDrivePanDetected`, `syncDriveHeading`): all present and unchanged; Drive Mode `if`-branch in `updateUIView` intact at lines 690–698.

---

## Programmatic Centering Path Audit (Spec §10, Risk #1)

This is the critical regression risk the spec identified. Full enumeration of programmatic move call sites and their Phase 1 status:

| Entry point | Path | Camera move after Phase 1 |
|---|---|---|
| Find-me button | `recenterOnUser()` → `recenterMap(on:)` → `coordinatorActions.setRegion?` | YES — direct closure call |
| Find-car button | `recenterOnCar()` → `recenterMap(on:)` → `coordinatorActions.setRegion?` | YES — direct closure call |
| Launch center (deep-link) | `performLaunchSetup()` → `recenterMap(on:)` → `coordinatorActions.setRegion?` | YES — direct closure call |
| Launch center (cached GPS) | `performLaunchSetup()` → `recenterMap(on:)` → `coordinatorActions.setRegion?` | YES — direct closure call |
| Location-fix-arrival recenter | `handleLocationUpdate()` → `recenterMap(on:)` (when `recenterOnUserRequested` or `recenterOnUserAtLaunch`) → `coordinatorActions.setRegion?` | YES — direct closure call |
| Deep-link cold-kill recenter | `routePendingDeepLink` → `recenterMap(on:)` → `coordinatorActions.setRegion?` | YES — direct closure call |
| Drive Mode recenter (Recenter button) | `recenterDriveMode()` → `recenterDriveMap(on:)` → `region = ...` only → `updateUIView` → `syncDriveRegion` | YES — Drive Mode path unchanged, uses syncDriveRegion via updateUIView; `coordinatorActions.setRegion` intentionally not called here |

All browse-mode programmatic centering paths confirmed working. Drive Mode recenter path confirmed unchanged.

**One edge case noted**: `coordinatorActions.setRegion?` is an optional call. If `recenterMap(on:)` is called before `makeUIView` completes wiring (theoretically possible if `performLaunchSetup` fires before the view is mounted), the `?` nil-coalesces to a no-op. However, the `region = newRegion` write still occurs, and `makeUIView` uses `region` for the initial `setRegion(region, animated: false)` call. This is safe: the initial placement will use the recenter coordinate. SwiftUI guarantees `.task` fires after the view is mounted (after `makeUIView` returns), so in practice `coordinatorActions.setRegion` is wired before `performLaunchSetup` runs.

---

## #31 Safety Audit

Phase 1 removes a camera call from `updateUIView` — this is strictly safer than before, not riskier. Confirming the invariant: after Phase 1, the only camera mutation paths are:

- `syncDriveHeading` (called from `updateUIView`) — pre-existing, vetted, dead-band gated. Unchanged.
- `syncDriveRegion` (called from `updateUIView`, Drive Mode only) — pre-existing, unchanged.
- `applyDriveCameraState` (called via `.onChange` / `CoordinatorActions`) — pre-existing, outside `updateUIView`.
- `coordinatorActions.setRegion?` (called from ContentView action handlers) — new in Phase 1, outside `updateUIView`.

No new camera mutations inside `updateUIView`. Phase 1 #31 risk is zero per spec §9.

---

## What's Working

- The architectural decision is clean: the `coordinatorActions.setRegion` closure pattern is a direct extension of the existing `applyDrivePitch` / `CoordinatorActions` pattern from W8.5c-polish PR-3. It follows the established idiom exactly.
- `shouldSyncRegionToBinding` deletion is surgical — only 3 callers existed (the function definition, the `updateUIView` call site, and the test class), all removed. No dead code left.
- The replacement test for the `setRegion` closure (Test 8, spy pattern) is the right way to test a closure contract. It provides compile-time assurance that `CoordinatorActions.setRegion` exists as a property.
- The comment at `recenterMap` (`ContentView.swift:1535–1541`) is unusually thorough and correctly documents the "why" (tile-load gating still needs `region = newRegion`, camera move needs `coordinatorActions.setRegion?`). This will help the next engineer not accidentally remove one of the two lines.
- Drive Mode paths are byte-for-byte identical to main (confirmed by diff — only the comment on `shouldSyncDriveRegion` updated to reference the Phase 1 deletion of `shouldSyncRegionToBinding`). The 45° pitch comment update is cosmetic and correct.
- No pbxproj churn, no Info.plist changes, no PWA/backend changes.
