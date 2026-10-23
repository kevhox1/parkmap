# QA — PR #140 (A2 curb-pin map layer), Pass 1

*Delivered inline by @qa-verifier (its harness blocked writing the file); landed by the orchestrator on its behalf, 2026-10-23. Static review only — no Swift toolchain, no build, no tests run, no live-UI smoke.*

Reviewed `feat/a2-curb-pin-map-layer` @ `d6beddee` against `docs/longpress-universal-plant-spec.md` (amendment) and `docs/design/curb-pin-placement-design.md` (authoritative).

**Verdict: FIX-THEN-MERGE** (no blockers; gated on Kevin's Mac compile + live smoke).

## Summary
The `MapViewRepresentable.swift` diff is minimal and inert with no session (`+121`, all marked). The controller isolates everything else, with clean camera discipline: no `updateUIView` camera/overlay mutation beyond the existing payload-rebuild pattern, no `setRegion`, no `userTrackingMode`. Gaps are cross-stream: placement pans feed PR #138's ambient "user adjusted" state, exit bypasses `applyAmbientDrivingLook`, and there is no safety net for a session that is never ended. The 400 m ceiling arithmetic is confirmed.

## Verified (static)
- **Flag-off / `placementIndex == nil` byte-identical** by hunk-by-hunk diff. Hooks `placementController?.regionWillChange()/regionDidChange()` are first statements, return nothing, never short-circuit — PR #138 user-adjust detection and FT-17a gesture logic still run unchanged.
- **Overlay re-insert:** `reinsertHighlight()` is last in `applyOverlayPayload`; no-ops on nil controller/overlay; runs after route/block-select re-inserts so the highlight ends on top; remove-then-add so it never duplicates.
- **Renderer branch:** `PlacementHighlightOverlay` is an `NSObject` MKOverlay (not an MKPolyline); the `as?` check sits after all existing branches — cannot intercept existing classes.
- **Camera discipline:** one animated `setCamera` on entry and exit; zoom range widened before the exit move; flag-on exit uses `driveModePitch` + `AmbientDrivingLook.heading` passed in (no duplicated numbers).
- **Display link:** weak proxy handles the target-retains-self trap; `.common` mode; paused at creation; invalidated in `end()` and `deinit`.
- **No per-frame SwiftUI writes:** outcome gating on a signature string (`"snapped|"+blockfaceKey` / `"noCurb"`), not `CurbSnapResult ==`; `onPlacementOutcome` via `DispatchQueue.main.async`.
- **Tip at 40% of `bounds.height`**: single `tipPoint` shared by reticle, resolver, nudge, entry centring.
- **Policy tests** assert real values with boundaries.
- **Compile classes 2/3/5/6 clean on static scan** (arg order, memberwise order, `nonisolated` policy with no `==` on nested enums, no bare `Category`); no SwiftUI import in the policy file; no `Calendar.current`; synchronized groups register the new files.

## Findings

### 🔴 Blocking — none.

### 🟡 Significant
1. **Entry spec inconsistency confirmed; zoom floor also off-spec.** `altitudeForSpan`: `altitude = (visibleHeight/2)/tan(15°) = 1.866 × visibleHeight`. For 110 m width on 390×844 → height 238.0 m → altitude ≈ **444 m**. The 400 m ceiling clamps to 99 m width / 0.254 m/pt; floor 0.55×400 = 220 m → 54.5 m wide at **0.140 m/pt**, violating design Finding 1 (≥ 0.15 m/pt, ghost reach ≤ 160 pt; reach = 24/0.140 ≈ 171 pt). With a ~600 m ceiling: entry 444 m (0.282 m/pt, matches spec "0.28"), floor 244 m (60.5 m wide, 0.155 m/pt, reach ≈ 155 pt ✓). Pinch-out limit at 600 m = 0.381 m/pt → 24 m ≈ 63 pt (> 40 pt target ✓), but entry sits at 74% of the ceiling → only 1.35× pinch-out headroom; **same constant is both entry clamp and zoom-out cap — consider decoupling**. ~900 m is looser than needed (at 800 m the 0.6× highlight-shrink branch (≈790 m) becomes reachable; at 600 m it is dead code, harmless). Tests to update: `testEntryDistance_clampsToTheCeiling`, `testEntryDistance_degenerateInputFallsBackToTheCeiling`, `testZoomRange_floorIs055xEntryDistance_ceilingIs400`, `testSpecInconsistency_...` (intentional tripwire), constant doc comment.
2. **PR #138 ambient-look state not coherent across a session.** (a) A real user pan/pinch during placement, flag-on, fires `onAmbientUserAdjusted` (regionDidChangeAnimated ~l.3064) → `ambientLookUserAdjusted = true` → ambient auto-tightening permanently stops. (b) `CurbPlacementController.end` sets the camera directly, never via `applyAmbientDrivingLook`, so `ambientLookStep`/`ambientLookUserAdjusted` are stale after exit. (c) While a session is live, `handleAmbientLookLocationUpdate` (ContentView ~l.4419) can issue `setAmbientDrivingLook` (pitch 30, re-centre on fix) if the look is `.wide` and unadjusted, and `recenterOnUserAtLaunch` (~l.4774) can also move the camera — either hijacks the placement camera. Fix: add `placementController == nil` to the condition guarding `onAmbientUserAdjusted` (A2); A3 gates the location-update ambient hooks while placement is active and resets/re-asserts ambient state via the existing apply path after exit.
3. **`layoutMargins.bottom` snapshot/restore round-trip unverified** (`snapshotBottomMargin`/`setBottomInset`): if the getter includes the safe-area contribution (`insetsLayoutMarginsFromSafeArea` default on), writing it back on exit can double the bottom margin permanently, lifting the Apple logo/Legal link; unknown whether MapKit shifts its centre when margins change (would break ghost-under-tip). Mac check on a notch device before/after a session.
4. **No safety net for a never-ended session** (`handleTap`/`handleLongPress` guards, `Coordinator.beginPlacement`): taps/long-presses stay no-ops until `endPlacement`; nothing self-heals if A3 drops its state (view rebuild, error path, sheet/scene reset, Coordinator recreation) → a map that ignores taps. `beginPlacement` while live is silently ignored, so an A3 "re-plant at a new seed" would no-op. Suggested: expose `isPlacementActive`; document that every A3 reset path routes through `endPlacement`; make `begin`-while-live replace the session. (CADisplayLink doesn't fire in background — fine.)
5. **Overlay/renderer isolation under MainActor default unverified:** MapKit reads `boundingMapRect`/`coordinate` and calls `draw` off-main; the types inherit MainActor default isolation; no repo precedent for an `MKOverlayRenderer` subclass. `SWIFT_VERSION` 5.0 → probably no runtime trap today; possible override-isolation diagnostic at first compile; latent Swift 6 trap. Mark the overlay's immutable members and `PlacementHighlightRenderer.draw` `nonisolated`; confirm clean build + draw on the Mac.
6. **Paste-on-Mac ContentView patch risky/incomplete:** "on the map ZStack" is ambiguous (modifier chain split into `mapLayerStack`/`mapLayerWithEvents` for the type-checker limit — a 13th `.onChange` + `.overlay` risks "expression too complex"); the index builds only on a `tileLoader.segments.count` change (nil if tiles already loaded); a `.topTrailing` button at 120 pt pad can collide with the rail; doesn't exercise `cyclePlacementCurb`/`refreshPlacement`/`setPlacementBottomInset`. Suggested: build the index inside the Begin button just before `beginPlacement` (`a2SmokeIndex = CurbSnapIndex(segments: tileLoader.segments)`); buttons in a `.bottomLeading` overlay inside `mapZStack`; add Commit / Cycle / Inset(300/0) buttons; print the outcome signature.

### 🟢 Minor
7. Settle can go unemitted if a touch lands during the nudge dwell without moving the map (nudge abandoned, no region callback → `fireSettle()` never emitted; card could be stale).
8. No watchdog for the display link if `regionDidChange` never follows `regionWillChange` (cancelled gesture) — runs at 30 fps until next region event. `preferredFramesPerSecond = 30` valid iOS 17.
9. Pitch/rotate gestures not locked (link tracks pin ground point through rotation; `exitCamera` restores pitch).
10. Highlight draws only the winning `Segment`; `CurbSnapIndex` groups multiple segments under one `blockfaceKey` → partial highlight if data splits a blockface; round caps overshoot each end by 10 pt. Unverified against real data.
11. Any region change that is neither a touch nor a placement nudge (ambient `setCamera`, location recenter) counts as a "user move" → haptic + settle nudge.
12. Flag-off guard tests real but narrow (nil defaults, no subview/overlay from hooks and payload rebuild, inert actions); tap/long-press guards and `rendererFor` ordering covered only by diff reading.
13. Reticle `layoutSubviews` sets `needleView.frame` while possibly transformed (lifted) — only reachable on rotation mid-lift.
14. A3 hazard: controller reads `parent.placementIndex` updated inside `updateUIView`; A3 must call `refreshPlacement()` after the index swap has rendered, not in the same `.onChange` pass.

### 💡 Logged
- The design's "Nearest curb" chip needs a camera API A2 doesn't expose (animate camera so a coordinate lands under the tip; internally `performNudge`, externally only `cyclePlacementCurb`).
- A2 doesn't reject entry while `driveModeActive` — by design (A3 enforces per spec A20); a cheap defensive guard is available.
- VoiceOver two-curb toggle (deviation #6): acceptable to ship dark — `resolve` is pure; `hysteresisMeters` returns -1000 for the forcing config so the other blockface wins within 24 m; with no incumbent it uses a 100 m wide config; `incumbentKey` set only on success; stable after nudge. Replace with `nearbyBlockfaces` (PR #141) when it lands.
- 4-layer stroke order/widths correct on read (20 black, 16 white, 11 black, 8 core, round caps, points via `/zoomScale`, `.aboveRoads`, 12 m inflated rect); legibility unverified.

## Hand-checked numbers
Tip: 340.8 pt on 852, 266.8 on 667. Zoom clamp: entry 444 → 400, floor 220 m (0.140 m/pt). Nudge: 86 pt → 0.292 s; 20 pt → 0.16 s; 2 pt → 0.14 s floor; 500 pt → 0.30 s cap.

## Mac smoke additions (beyond the PR checklist)
After exit, check Apple logo / Legal link position vs pre-session on a notch device; toggle the inset via a temporary button and confirm tip/ghost alignment holds; place the pin on a street, trigger the VoiceOver cycle, confirm it lands on the other curb and settle fires one outcome; flag-on, within seconds of cold launch before GPS settles, start a session and confirm the ambient tighten doesn't yank the camera; pan in a session, exit, check whether ambient tighten stays disabled (finding #2); rotate/tilt mid-session, confirm exit restores pitch/heading; background the app mid-pan, return, confirm session usable and map responsive; Reduce Motion paths (instant entry/nudge/exit, no lift); confirm the nudge actually animates (the `UIView.animate` around `setCenter(animated: false)`; instant jump is an acceptable degradation per deviation #5).
