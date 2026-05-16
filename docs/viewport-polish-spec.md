# Viewport Polish — Spec

**Stream:** Viewport Polish (no W-number; slots between W7 and W7.5)
**Status:** Draft — awaiting Kevin confirmation on open decisions below before dispatch. Amended 2026-05-16: deep-link cold-launch auto-center behavior corrected (see §5 W6.1 integration and AC-B4, AC-B-DL1–3).
**Owner:** @ios-engineer
**Estimated effort:** 1 engineer session. One PR.
**Dispatch timing:** After W6.1 merge wraps. Can run in parallel with the W7.5 spec-writing pass.
**Touches:** `ContentView.swift` only. No new files, no new tests required (though one AC verifies simulator smoke).

---

## Open decisions — surface first

**OD-1 (Kevin must answer before code starts):** The auto-center feature requires `LocationService` to call `requestAndFetchLocation()` on app launch for users who have already granted `.whenInUse` permission. Today that call is not made at launch — it fires only on "Find me" button tap. This means the first call to `requestLocation()` at launch will attempt a fresh GPS fix, which may introduce a 0–3 second boot delay before the camera moves. Is that acceptable, or does Kevin prefer an instant snap to the last-known location from `CLLocationManager`? The spec below recommends the fresh-fix path but can be changed to a last-known path (see Part B mechanics).

**OD-2 (Kevin must answer before code starts):** The "user is too far from Manhattan" fallback in Part B needs a distance bound. The spec proposes 25 km from `AppConstants.manhattanCenter` as the fallback trigger. Confirm this is appropriate, or provide a tighter/looser bound. For reference: Newark airport is ~21 km, JFK is ~23 km, Hoboken is ~7 km, Flushing is ~16 km.

---

## 1. Problem and user story

### The symptom

When the user zooms out to see all of Manhattan plus Brooklyn, only roughly half the streets render parking overlays. Lower Manhattan, West Village, and East Village show colored block-faces; Midtown, Upper East Side, and Upper West Side appear as a plain Apple Maps basemap. The app looks broken and half-loaded.

**Observed:** Kevin smoke test, 2026-05-16 simulator run.

### Root cause (traced together)

`TileLoader` caps its LRU segment cache at `maxCachedTiles = 200` (raised from 50 in the W4 rendering-architecture refactor; see `TileLoader.swift:96`). At wide zoom covering Manhattan plus Brooklyn, the visible region intersects 500+ source tiles. As `loadTiles(forRegion:)` iterates and fetches, the LRU evicts older tiles to stay under the cap. `rebuildSegments(forKeys:)` is then called with `currentRegion`'s live tile key set, but some of those keys have already been evicted from cache. The segments for evicted tiles are absent from `segments`, so no polylines render for those tile areas. The user sees whichever 200 tiles happened to survive the LRU — a geographic lottery producing patchwork coverage.

The existing `polylineHideSpanThreshold = 0.1` guard in `rebuildOverlays(at:)` (`ContentView.swift:527`) should prevent overlay rendering at that zoom, but the threshold is too lax — `0.1` degrees of latitude corresponds to roughly 11 km N-S, a span at which users can already see severe LRU-eviction patchwork.

### User story

*As a user who just opened WePark for the first time today, I want the map to:*
1. *Show my immediate neighborhood at a zoom where parking colors are actually legible, not a city-scale overview.*
2. *Hide parking overlays entirely — with a clean Apple Maps basemap — when I zoom out far enough that individual blocks can't be read anyway, rather than showing a patchwork of partial data.*

### Why now

W7 shipped. W8 is blocked on Apple Developer Program enrollment. W7.5 spec is being written in parallel. This fix is a 1-session slot before TestFlight that removes the single most confusing visual artifact a new tester will see.

---

## 2. Scope

### In scope

**Part A — Lower `polylineHideSpanThreshold` from `0.1` to `0.04`.**
One constant change in `ContentView.swift:197`. No other code changes required for Part A.

**Part B — Auto-center to user location on launch.**
Logic added inside the existing `.task { }` modifier in `ContentView.swift:282`. Uses the existing `LocationService` and `recenterMap(on:)` helper. No new services, no new files.

### Out of scope (explicitly deferred)

- **Dynamic tile loading tied to the visible viewport** (load tiles as the user pans in, evict tiles that have left the viewport). This is the correct architectural fix for the LRU-eviction symptom. Deferred until post-W8 once real-device memory data is available. Kevin's call, confirmed in the task brief.
- **Increasing `maxCachedTiles` beyond 200.** Memory tradeoff that needs real-device measurement (W8 hardware access). Not in this PR.
- **Animated camera choreography on launch.** Use `recenterMap(on:)` as-is (`MKCoordinateRegion` with `latitudinalMeters: 400`). Default MapKit animation is fine.
- **Location permission prompt at launch.** Do NOT call `requestWhenInUseAuthorization()` at launch. The W5.1 design is that the first permission prompt fires on the "Find me" button tap. This PR must not regress that behavior. If `isAuthorized == false`, Part B is skipped entirely.
- **Drive Mode location tracking.** `LocationService` is currently "recenter-only" per its header comment (`LocationService.swift:13`). This PR does not expand that contract.

---

## 3. Architecture

### Files touched

| File | Change |
|---|---|
| `ios/WePark/WePark/ContentView.swift` | Part A: change constant on line 197. Part B: add launch auto-center logic in `.task { }`. |

No other files are touched. `LocationService.swift`, `TileLoader.swift`, `MapViewRepresentable.swift`, `AppConstants`, all Models, all Services — unchanged.

### Data flow

No new data flows. Both parts wire into existing infrastructure:

**Part A:** `rebuildOverlays(at:)` already reads `region.span.latitudeDelta` and returns early if it exceeds `polylineHideSpanThreshold` (`ContentView.swift:527`). Changing the constant is the entire change.

**Part B:** `.task { }` in `ContentView.swift:282` already runs the launch sequence (load pin, init mute state, init banner, load tiles, rebuild overlays). The auto-center hook runs at the end of that task, after `tileLoader.loadTiles(forRegion: region)` has been called, using the existing `locationService` instance and `recenterMap(on:)` helper.

### No new tables, RPCs, or files

This is a pure iOS client-side change. Backend is not involved. PWA is not involved.

---

## 4. Part A — `polylineHideSpanThreshold` new value: `0.04`

### The math

`MKCoordinateSpan.latitudeDelta` is the number of degrees of latitude visible north-to-south in the current map viewport.

- 1 degree of latitude = 111,320 m (equatorial approximation; at NYC latitude ~40.7 N, it is 110,900 m — close enough for this threshold).
- `latitudeDelta = 0.1` (current): 0.1 × 111,320 = **11,132 m N-S**, roughly Canal Street to 110th Street. At this zoom, Apple Maps renders streets as thin lines with no name labels; individual block faces are pixel-wide. Parking colors are unreadable, but the threshold was allowing overlay rendering anyway.
- `latitudeDelta = 0.07` (default launch span, `ContentView.swift:131`): 7,793 m N-S. Still wide — roughly Houston Street to 110th Street.
- `latitudeDelta = 0.04` (proposed threshold): 0.04 × 111,320 = **4,453 m N-S**, approximately 44 Manhattan blocks (100m per block). At this zoom, Apple Maps begins rendering street name labels and individual block faces are distinct, colored lines. Parking overlays are legible but you're seeing a large neighborhood chunk. This is the upper boundary of "useful."
- `latitudeDelta = 0.0036` (produced by `recenterMap(on:)` at `latitudinalMeters: 400`): 400 m N-S, approximately 4 Manhattan blocks. Deep street-level zoom. Always well below the threshold — overlays always render after auto-center or recenter.

**Why 0.04 rather than 0.03 or 0.05:**

- `0.03` (3,340 m, ~33 blocks): renders overlays at a slightly tighter neighborhood zoom. The LRU at 200 tiles would still cover this viewport comfortably — at 0.03 degrees the tile count estimate is roughly 15 row tiles × 6 column tiles = ~90 tiles, well under the 200-tile cap. However, tightening to 0.03 hides overlays at a zoom where users are starting to navigate a neighborhood, which is mildly unhelpful. `0.04` is the better UX bound.
- `0.05` (5,566 m, ~56 blocks): renders overlays at a zoom where you can see from roughly 34th Street to the tip of Lower Manhattan at once. At this span the LRU pressure is low (estimate ~180 tiles), but parking colors at 56-block viewport density are hard to act on — too many blocks, and the "patchwork" symptom reappears at wider user zooms. `0.04` is a tighter, cleaner cutoff.
- `0.04` lands at the natural Apple Maps inflection point where street labels appear and individual block geometry becomes visible. "If street names aren't readable, parking colors aren't readable" is the product-legibility principle. At 44 blocks N-S on an iPhone Pro screen, street names render but are small; at 56+ blocks they disappear. `0.04` is the right side of that boundary.

**Tile count at `latitudeDelta = 0.04`:** Approximate tile grid size from `TileLoader.swift` buffer logic: with `buffer = 2` extra tiles in each direction, a `0.04 × 0.03` degree viewport (aspect ratio matching Manhattan's tall-narrow shape) intersects roughly 18 row tiles × 14 column tiles = ~252 nominal cells. After filtering against the sparse Manhattan `tileSet`, actual hits are closer to 100–150 tiles — within the 200-tile LRU cap with headroom. No LRU eviction patchwork at this span.

**Tile count at current default launch span (`0.07`):** Approximately 30 row tiles × 22 col tiles = ~660 nominal cells; post-filter roughly 200–280 tiles. This is right at or above the LRU cap — which explains why the symptom is visible even at the default launch zoom. The threshold fix also helps the launch experience before Part B kicks in.

### The change

```swift
// ContentView.swift line 197 — before
private let polylineHideSpanThreshold: Double = 0.1

// After
private let polylineHideSpanThreshold: Double = 0.04
```

No other changes for Part A.

---

## 5. Part B — Auto-center to user location on launch

### Mechanics

The auto-center logic runs inside the existing `.task { }` block in `ContentView.swift:282`, at the end after all existing initialization. It is purely additive — the existing launch sequence is not reordered.

**Three-priority decision at launch (in order):**

```
// Priority 1: Cold launch from notification tap.
if pendingDeepLinkCarID != nil
   AND parkPinService.parkedCar != nil
   AND parkPinService.parkedCar!.id == pendingDeepLinkCarID
then:
    recenterMap(on: parkPinService.parkedCar!.coordinate)
    // Uses the same ~400m latitudinalMeters span as normal auto-center.
    // The W6.1 routePendingDeepLink path then presents ParkedCarDetailView
    // on top. The map underneath shows the actual block where the car sits.
    // NOTE: the 25 km Manhattan coverage guardrail does NOT apply here.
    // The user explicitly parked at that coordinate; center there unconditionally.

// Priority 2: Normal launch, location authorized, fix available.
else if locationService.isAuthorized == true
   AND locationService.userLocation is available immediately (cached from a previous session)
   AND userLocation is within 25 km of manhattanCenter  ← coverage fallback
then:
    recenterMap(on: locationService.userLocation!)
    // loadTiles(forRegion:) is already called above in .task; it will be called again
    // by the onRegionChanged callback that fires from MapViewRepresentable after the
    // region binding update.

// Priority 2b: Authorized, no cached fix yet — defer via flag.
else if locationService.isAuthorized == true
   AND locationService.userLocation == nil  (no cached fix yet)
   AND pendingDeepLinkCarID == nil
then:
    set @State recenterOnUserAtLaunch = true
    locationService.requestAndFetchLocation()
    // The existing .onChange(of: locationService.locationUpdateCount) observer will
    // fire when the fix arrives. We need a new flag so it knows this is a launch
    // auto-center, not a button-tap recenter.

// Priority 3: Fallback — permission denied, out-of-coverage, or deep-link carID
//             not found in parkPinService (pin was cleared between notification
//             scheduling and launch).
else:
    // Do nothing. Default manhattanCenter region stays.
    // The W6.1 guard (car.id == carID) already blocks sheet presentation when
    // the pin is missing, so no sheet fights the camera here.
```

**Deep-link edge case — carID not resolvable:**

If `pendingDeepLinkCarID != nil` but `parkPinService.parkedCar == nil` (pin was cleared between notification scheduling and app launch), the `if` branch above falls through to Priority 2 / Priority 3 as normal. The W6.1 routing guard (`car.id == carID`) already prevents the sheet from presenting in this case. No special handling needed beyond falling through.

**Two-flag design:**

Today, `recenterOnUserRequested: Bool` is set by the "Find me" button tap and cleared after the first location fix arrives. This PR introduces a second flag `recenterOnUserAtLaunch: Bool` with the same lifecycle. The two flags are independent because the button-tap path may fire while launch auto-center is still waiting for a GPS fix — separate flags prevent the button tap from interfering with the launch auto-center (and vice versa).

Both flags are cleared after the first fix, in the same `.onChange(of: locationService.locationUpdateCount)` observer (already at `ContentView.swift:349`). The observer checks `recenterOnUserRequested || recenterOnUserAtLaunch` and recenters if either is set, then clears both.

**Timeout: no explicit timer needed.**

`CLLocationManager.requestLocation()` has a built-in timeout: if no location is available within ~10–15 seconds, it calls `locationManager(_:didFailWithError:)` with `kCLErrorLocationUnknown`. `LocationService` already swallows that error (`LocationService.swift:107`). The effect: if no fix arrives, `locationUpdateCount` never increments, `recenterOnUserAtLaunch` stays true but never fires, and after a few seconds the user is on the default `manhattanCenter` region. The flag is harmless after that — the next location event (triggered by a "Find me" tap) will fire the recenter, which is also acceptable behavior.

There is no 3-second hard timeout in this implementation. The "reasonable wait" framing in the task brief is satisfied by `requestLocation()`'s own built-in timeout (system-managed). A custom `Task.sleep` timeout would add complexity with no user-observable benefit.

**The coverage fallback (OD-2):**

If the user's location fix is more than `launchAutoCenterMaxDistanceKm = 25.0` km from `AppConstants.manhattanCenter`, skip the auto-center and keep `manhattanCenter` as the default. This covers users in NJ, parts of Brooklyn, Queens, and the Bronx where WePark has no tile data. The constant `launchAutoCenterMaxDistanceKm` is defined as a private `let` in `ContentView`, mirroring the style of `tapHitThresholdMeters` and `pinDropRadiusMeters`.

Distance check uses the same haversine helper already present in `ContentView` (`haversine(from:to:)`). No new dependency.

Approximate distances from `manhattanCenter` (40.7831, -73.9712):
- Hoboken, NJ: ~7 km — within 25 km, but WePark has no NJ tile data. The user sees the basemap with no overlays, which is honest. No confusion beyond "no data here."
- JFK: ~23 km — just inside 25 km bound. Kevin may want to tighten to 20 km (answer OD-2).
- Newark Airport: ~21 km — just inside. Same as above.
- Flushing (Queens): ~16 km — within.
- Yonkers: ~26 km — outside 25 km bound, falls back to manhattanCenter. Correct.

If a user is in Hoboken (within 25 km), auto-center zooms to Hoboken at street level. No overlays render (no tile data there). This is not broken — the basemap is clean and honest. If Kevin finds this confusing, tighten OD-2 to ~15 km (covers Manhattan + near-Brooklyn/Queens only).

### Integration with W5.1 `LocationService`

`LocationService` (`LocationService.swift`) is `@Observable` and exposes:
- `userLocation: CLLocationCoordinate2D?` — nil until first fix
- `locationUpdateCount: Int` — incremented on each fix
- `isAuthorized: Bool` — reflects current CLLocationManager authorization status

The auto-center hook reads `locationService.isAuthorized` synchronously (available at init time from `manager.authorizationStatus`) to decide whether to attempt auto-center. It does NOT call `requestWhenInUseAuthorization()` — that would show a permission dialog at launch, violating the "Find me tap triggers the prompt" design. If `isAuthorized == false`, the entire Part B is skipped.

The hook reads `locationService.userLocation` to check for a cached fix from a previous session. If non-nil and within 25 km, it recenters immediately (no `requestAndFetchLocation()` call needed for the immediate recenter, though a background refresh is optional for next use).

If `userLocation == nil` (first launch with permission already granted but no cached fix), the hook calls `requestAndFetchLocation()` and sets `recenterOnUserAtLaunch = true`. The existing `.onChange(of: locationService.locationUpdateCount)` at `ContentView.swift:349` is extended to handle this flag.

**The hook does NOT subscribe to `locationUpdateCount` inside `.task { }`** using an `await` loop or `AsyncStream`. That approach would require restructuring the task's concurrency model. Instead, it follows the same pattern as the existing "Find me" button: set a flag, call `requestAndFetchLocation()`, let `.onChange(of: locationUpdateCount)` close the loop.

### Integration with W6.1 deep-link

If the app is opened by a notification tap, `AppDelegate` sets `pendingDeepLinkCarID` before `ContentView`'s `.task { }` runs (or shortly after, in the background-wake cold-kill path).

**Previous (incorrect) behavior:** The auto-center block skipped entirely when `pendingDeepLinkCarID != nil`, leaving the camera on the default wide-zoom `manhattanCenter` view. The sheet presented correctly but the map underneath showed nothing useful — no overlays at wide zoom and no camera context for where the car was parked.

**Corrected behavior:** When `pendingDeepLinkCarID != nil` and `parkPinService.parkedCar` resolves to the same car, auto-center fires on `parkedCar.coordinate` at the normal `~400m` span. The `ParkedCarDetailView` sheet then presents on top via the existing `.onChange(of: pendingDeepLinkCarID)` path (or the `.onChange(of: scenePhase)` cold-kill path at `ContentView.swift:314` and `ContentView.swift:394`). The result: both the sheet text and the map below confirm where the car is parked.

The 25 km Manhattan-coverage guardrail is **not applied** to this path. The user explicitly parked at that coordinate; that is their truth regardless of whether WePark has tile data at that location.

If `pendingDeepLinkCarID != nil` but `parkPinService.parkedCar` is nil (pin cleared between notification scheduling and launch), the code falls through to the normal Priority 2 / Priority 3 paths. The W6.1 sheet-routing guard already prevents the sheet from presenting in this case, so there is no camera conflict.

---

## 6. Work streams

There is no parallelization opportunity here. Both parts are single-file changes to `ContentView.swift` by one engineer. The changes are small enough to go in one PR.

| Stream | Owner | Parallel? | Notes |
|---|---|---|---|
| Part A + Part B implementation | @ios-engineer | — | Single session. One PR off `main` (after W6.1 merges). |
| QA pass | @qa-verifier | After PR opens | Smoke scenarios in §7. |

`@backend-data`, `@pwa-maintainer`, and `@designer` are not involved.

---

## 7. Acceptance criteria

### Part A — Zoom-out threshold

- [ ] **AC-A1.** `polylineHideSpanThreshold` is `0.04` in `ContentView.swift`. No other constant changes.
- [ ] **AC-A2.** With the app running in the simulator at street-level zoom (`latitudeDelta ≈ 0.005`), colored polylines render on all streets in the visible tile area.
- [ ] **AC-A3.** Pinch-zoom out to `latitudeDelta ≈ 0.07` (the default launch region). All 5 state-group `MKMultiPolyline` overlays are removed — the map shows the clean Apple Maps basemap with no parking coloring. No patchwork — either all or nothing.
- [ ] **AC-A4.** Pinch-zoom back in to `latitudeDelta ≈ 0.03`. Colored polylines re-render correctly (driven by the existing `rebuildOverlays` on region change path).
- [ ] **AC-A5.** At zoom level exactly straddling the threshold (`latitudeDelta` incrementally crossing `0.04`), the transition between overlays-visible and overlays-hidden is clean (no flicker beyond the normal 60s tick cadence). "Clean" means: zooming out through `0.04` causes overlays to vanish at the next `rebuildOverlays` call, which fires on region change via `.onChange(of: tileLoader.segments.count)` and the timer — not instantly per-frame, which is acceptable.
- [ ] **AC-A6.** The existing 43 + 15 + 12 = 72 unit tests pass: `xcodebuild test` reports 72 passed, 0 failed. Part A does not touch any tested logic.

### Part B — Auto-center on launch

- [ ] **AC-B1 (permission denied / not determined).** Fresh install, location permission not yet granted. App launches → map centers on `manhattanCenter` at default span (`latitudeDelta: 0.07`). No location permission dialog appears at launch. QA method: reset simulator location permission, cold launch.
- [ ] **AC-B2 (authorized, cached fix available).** Permission previously granted, `userLocation` is non-nil at `.task` execution time (previous session provided a fix). App launches → map animates to user's location at the `recenterMap` span (~400m). If the user's location is within 25 km of `manhattanCenter`, overlays load for that area. QA method: grant permission in a prior session, cold launch.
- [ ] **AC-B3 (authorized, no cached fix).** Permission granted but no prior fix (e.g., first launch in airplane-mode-then-restored). App launches → stays on `manhattanCenter` initially → when fix arrives (seconds later), map re-centers to user's location. QA method: grant permission but simulate slow location (simulator location set to "None" initially, then switched to a preset).
- [ ] **AC-B4 (deep-link: sheet presents AND map centers on parked car).** Simulate a notification-tap cold-kill launch: force-quit app, tap a delivered parking notification, app launches cold. The `ParkedCarDetailView` sheet presents correctly. The map camera centers on the parked car's coordinate at the normal `~400m` span — NOT on `manhattanCenter` and NOT on user location. Parking overlays (if any exist for that block) are visible behind the sheet. QA method: follow the W6.1 notification-tap smoke scenario from `docs/qa/w6-pass-1-2026-05-13.md`; add a visual check that the map behind the sheet shows the correct block, not a wide Manhattan overview.
- [ ] **AC-B-DL1 (deep-link: parked car coordinate is outside coverage area).** Park pin is at a location outside the 25 km Manhattan coverage radius (e.g., Yonkers or Newark). Notification-tap cold-kill launch. Map still centers on `parkedCar.coordinate` at `~400m` span — the 25 km guardrail does NOT block this path. Sheet presents on top showing car details. Clean basemap with no overlays behind the sheet (no tile data at that location — honest and correct). QA method: set a pin manually at an out-of-coverage coordinate in the simulator, deliver a test notification, cold-kill launch.
- [ ] **AC-B-DL2 (deep-link: pin cleared before launch).** `pendingDeepLinkCarID != nil` but `parkPinService.parkedCar == nil` (pin was removed between notification scheduling and launch). App falls through to normal Priority 2 / Priority 3 auto-center logic (user location if authorized, else `manhattanCenter`). No sheet presents (W6.1 guard prevents it). No crash. QA method: schedule a notification, manually clear the pin via the UI, then cold-launch from the notification.
- [ ] **AC-B-DL3 (deep-link: camera does not jump after sheet dismiss).** After the `ParkedCarDetailView` sheet is dismissed (swipe down), the map remains centered on the parked car's block. The camera does not snap back to `manhattanCenter` or fire a second auto-center. QA method: dismiss the sheet after AC-B4 scenario, observe camera position holds.
- [ ] **AC-B5 (user outside 25 km).** Set simulator location to Newark Airport (40.6895, -74.1745, ~21 km from `manhattanCenter`) or Yonkers (40.9312, -73.8988, ~26 km). Newark: auto-center should fire (within bound), map zooms to Newark, basemap shows with no overlays (no tile data — correct and honest). Yonkers: auto-center should NOT fire, map stays at `manhattanCenter`. QA method: simulator location preset.
- [ ] **AC-B6 (recenter button unaffected).** After auto-center completes, the "Find me" button (`location.fill`) still works correctly: tapping it recenters to current location. The `recenterOnUserRequested` flag behavior from W5.1 is not regressed. QA method: tap "Find me" after launch auto-center and verify camera moves.
- [ ] **AC-B7 (notification permission not regressed).** First pin drop still shows the `NotificationRationaleView` sheet (W6 behavior). The W6 `firstPinDropped` → rationale sheet flow is not affected. QA method: drop a pin on a fresh install, verify rationale sheet appears.
- [ ] **AC-B8 (unit tests).** 72 unit tests pass. Part B logic is launch-sequencing only (no new business logic), so no new unit tests are required. QA may choose to add a test for the `launchAutoCenterMaxDistanceKm` haversine guard if time allows, but it is not blocking.

### Combined smoke scenario (the bug being fixed)

- [ ] **AC-SMOKE.** Cold launch → auto-center fires → map is at street level → colored polylines cover all visible streets (no patchwork). Zoom out gradually → at `latitudeDelta ≈ 0.04` overlays cleanly disappear, showing plain basemap. Zoom back in → overlays re-render. This scenario should pass on a first-ever launch for a tester in Manhattan.

---

## 8. Edge cases

| Scenario | Behavior | Notes |
|---|---|---|
| User is in Hoboken (within 25 km, no tile data) | Auto-center fires, camera moves to Hoboken at ~400m span. No overlays render — clean basemap, honest about no data. | Expected. No special handling needed. If Kevin wants to tighten the fallback to Manhattan-only, answer OD-2 with a tighter bound (e.g., 15 km). |
| User's location is in Brooklyn (has tile data in some areas) | Auto-center fires if within 25 km. Overlays render for any loaded Brooklyn tiles. | Manhattan tiles only currently. Brooklyn users see basemap. No regression. |
| Authorization status changes mid-session (user goes to Settings, revokes) | `isAuthorized` is updated by `locationManagerDidChangeAuthorization` delegate. Auto-center already ran at launch; no re-launch behavior needed. Find-me button becomes a no-op (existing W5.1 behavior). | No change needed. |
| App is backgrounded during the GPS fix wait | `locationUpdateCount` increments when the fix eventually arrives, `recenterOnUserAtLaunch` fires, map recenters. If the sheet is showing (the user backgrounded then foregrounded on a sheet), recenter still fires but is off-screen and harmless — the camera is updated when the sheet dismisses. | Acceptable edge case. No special handling. |
| Cold-kill notification tap + parked car resolvable | Auto-center fires on `parkedCar.coordinate` at `~400m` span. Sheet presents on top via W6.1 routing. Map shows the actual block behind the sheet. 25 km coverage guardrail does NOT apply. | Covered by AC-B4, AC-B-DL1. |
| Cold-kill notification tap + pin cleared between scheduling and launch | `pendingDeepLinkCarID != nil` but `parkPinService.parkedCar == nil`. Falls through to Priority 2 / Priority 3 (user location or `manhattanCenter`). No sheet presents (W6.1 guard prevents it). | Covered by AC-B-DL2. |
| "Find me" button tapped while `recenterOnUserAtLaunch == true` and still waiting for launch fix | Both `recenterOnUserRequested` and `recenterOnUserAtLaunch` are true. The fix arrives, `.onChange(of: locationUpdateCount)` fires, recenters once, clears both flags. No double recenter. | The `.onChange` observer already clears `recenterOnUserRequested` after acting; extend the same clear to `recenterOnUserAtLaunch`. |

---

## 9. Out-of-scope follow-ups noticed but explicitly punted

**Dynamic tile-fetch on pan.** The correct cure for the LRU patchwork is a viewport-aware tile eviction strategy: load tiles entering the viewport, evict tiles leaving it. This keeps `tileLoader.segments` synchronized to what the user is actually looking at, regardless of how far they pan. Part A's threshold fix is a band-aid that hides the symptom at wide zoom. Post-W8, once real-device memory data is available, a viewport-aware tile-loading redesign should replace the LRU cap entirely. File this as a post-W8 tech debt item in HANDOFF.md.

**`maxCachedTiles` increase.** The LRU cap of 200 tiles is aggressive for the default launch region (`latitudeDelta: 0.07`) — estimated tile count at that span approaches or exceeds 200. Raising the cap to 300–400 would eliminate patchwork at the default zoom without any other changes. However, the memory tradeoff (300 tiles × ~25KB = ~7.5 MB; 400 tiles = ~10 MB) needs real-device Instruments measurement before committing. Defer to a standalone follow-up PR after W8 hardware access.

**VoiceOver map overlay navigation.** Dropped in W4 per the decision doc. Not re-opened by this spec.

**MKMapView `regionDidChangeAnimated` debounce.** Heavy panning can produce a flood of `onRegionChanged` callbacks and `tileLoader.loadTiles` calls. No debounce currently exists; the `currentRegion` stale-region guard in `TileLoader` mitigates the symptom. A 200ms debounce on the region-change callback would reduce tile-load churn. Not in this PR — it's an optimization, not a correctness fix.

---

## References

- `ContentView.swift:197` — `polylineHideSpanThreshold` current value
- `ContentView.swift:131` — `region` initial state (`latitudeDelta: 0.07`)
- `ContentView.swift:282` — `.task { }` launch sequence (Part B hook lands here)
- `ContentView.swift:349` — `.onChange(of: locationService.locationUpdateCount)` (extend for `recenterOnUserAtLaunch`)
- `ContentView.swift:527` — `rebuildOverlays` zoom-threshold guard (reads `polylineHideSpanThreshold`)
- `ContentView.swift:644` — `recenterMap(on:)` helper (Part B calls this)
- `ContentView.swift:889` — `haversine(from:to:)` (used by Part B coverage fallback)
- `LocationService.swift:37` — `isAuthorized` property
- `LocationService.swift:29` — `userLocation` property
- `LocationService.swift:34` — `locationUpdateCount` property
- `LocationService.swift:59` — `requestAndFetchLocation()` API
- `TileLoader.swift:96` — `maxCachedTiles = 200`
- `Constants.swift:11` — `AppConstants.manhattanCenter`
- `docs/ios-rendering-architecture-decision.md` — LRU rationale, MKMultiPolyline architecture
- `docs/qa/w6-pass-1-2026-05-13.md` — W6.1 notification-tap smoke scenario (AC-B4 reference)
