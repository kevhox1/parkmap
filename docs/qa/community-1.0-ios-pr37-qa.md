# Community 1.0 Tier 1 Pin Display — QA Pass 1 — 2026-06-02

**Reviewed:** branch `ios/tier1-pin-display` at `ea698b0`, against `docs/tier1-pin-display-spec.md`
**Verdict:** PASS WITH NITS

## Summary

PR #37 adds the read-only Tier 1 community pin display layer (filming/special_event markers, ASP banner supplement) and modifies `ContentView.swift` and `MapViewRepresentable.swift`. The Drive Mode regression risk (the primary concern) is verified clean: exactly one `.onChange(of: driveModeActive)` handler exists in the modifier chain, the `setRegion` path is correctly gated by `shouldSyncRegionToBinding(driveModeActive:)`, no `headlessWindow` guard is present, and `RegionSyncGuardTests` (2/2) pass. Build succeeds, 300 tests pass with 0 failures. The live-UI smoke confirms ASP banner and full toolbar layer render intact. Community pin markers cannot be verified to render visually in the sandbox (no live DB, no programmatic inject path from outside the app), which is documented below as a non-blocking known limitation per the spec's own deferred AC-D11 posture.

---

## Acceptance criteria checklist

### Fetch + Service

- [x] **AC-D1** — `clientSideFilter` removes pins where `expiresAt <= now`. Verified: `CommunityPinServiceFilterTests.testClientSideFilter_expiredPin_removed` passes.
- [x] **AC-D2** — `clientSideFilter` retains nil-expiry pins. Verified: `testClientSideFilter_nilExpiry_retained` passes.
- [x] **AC-D3** — `clientSideFilter` retains future-expiry pins. Verified: `testClientSideFilter_futureExpiry_retained` passes.
- [x] **AC-D4** — `clientSideFilter` removes resolved pins. Verified: `testClientSideFilter_resolvedPin_removed` passes.
- [ ] **AC-D5** — Realtime reconnect — deferred (requires prod schema apply). `startRealtime()` is a stub. Marked TODO in source.
- [x] **AC-D6** — Request includes `source=eq.open_data`. Verified: `testFetchRequest_includesOpenDataSourceFilter` confirms the query item; `testBuildRequest_noAuthorizationHeader` confirms no Bearer token; `testBuildRequest_apiKeyHeader_present` confirms `apikey` header. Note: the inventory comment says test #19 is `testBuildRequest_containsExpectedQueryItems` but that test function does not exist in the file (20 tests, not 21 — see Finding #1).
- [x] **AC-D7** — Two rapid region changes fire only one fetch. Verified: `testDebounce_twoRapidCalls_firesOneFetch` passes.
- [x] **AC-D8** — `asp_suspended_today` excluded from map marker array. Verified: `testMapMarkerFilter_aspSuspendedToday_excluded` passes; `handleVisiblePinsChange` in `ContentView.swift` explicitly filters to `[.filming, .specialEvent]`.

### ASP Integration

- [x] **AC-D9a** — `resolvedBannerState(.aspInEffect, aspPins:[today-pin])` returns `.todaySuspended`. Verified: `testResolvedBannerState_aspPinToday_bundleInEffect_returnsSuspended` passes.
- [x] **AC-D9b** — `resolvedBannerState(.todaySuspended, ...)` returns bundle state unchanged. Verified: `testResolvedBannerState_bundleAlreadySuspended_noOverride` passes.
- [x] **AC-D9c** — `resolvedBannerState(.aspInEffect, aspPins:[])` returns `.aspInEffect`. Verified: `testResolvedBannerState_noPins_returnsBundle` passes.
- [x] **AC-D9d** — Expired asp pin does NOT override bundle. Verified: `testResolvedBannerState_expiredPin_noOverride` passes.

### Live-UI Smoke Gate

- [x] **AC-D10** — QA built, installed, launched on iPhone 17 Pro sim (UDID F0820726-15F4-4FA3-8602-A5D7B479A277). Screenshot captured at `/tmp/qa-pr37-smoke-launch.png` and read visually. Confirmed: (a) green "ASP in Effect Today" banner renders at top; (b) gear button (top-left), find-me/find-car/clock/Drive buttons (right side) all visible; (c) no overlay layer elements dropped. The #31 regression class did not recur. No community pin markers appear at wide zoom — correct behavior (requires close zoom + live seeded pins; no live DB available).

### Map Markers (end-to-end — requires prod schema)

- [ ] **AC-D11** — Filming marker renders on map. Deferred — requires prod schema apply + seeded pin. See Finding #2 (smoke gate limitation).
- [ ] **AC-D12–D15** — End-to-end marker/tap/filter behavior. Deferred — requires live DB.

### Architecture Invariants

- [x] **AC-D16** — `MapViewRepresentable.updateUIView` contains no new camera-mutation calls, no new `setRegion` calls, no `headlessWindow` guards. Verified by code review: `updateUIView` calls only `syncCarPin`, `syncRoutePolyline`, `syncDestinationPin`, `syncCommunityPinAnnotations`, `syncDriveHeading`, and the `shouldSyncRegionToBinding`-guarded `setRegion` path — all identical to pre-PR state except for the addition of `syncCommunityPinAnnotations`. No camera calls added.
- [x] **AC-D17** — All `MKAnnotation` mutations from community pins happen in `.onChange(of: pinService.visiblePinsGeneration)` -> `handleVisiblePinsChange` -> updates `communityPins` state var -> `MapViewRepresentable.updateUIView` calls `syncCommunityPinAnnotations` for mechanical sync only. The decision is made in `.onChange`, not inside `updateUIView`. Invariant I-1 preserved.
- [x] **AC-D18** — `RegionSyncGuardTests` (2 tests) pass: `testRegionSync_driveModeActive_returnsFalse` and `testRegionSync_driveModeInactive_returnsTrue` both pass on this branch.
- [x] **AC-D19** — No `Calendar.current` in `CommunityPinService.swift`, `PinMarkerAnnotation.swift`, or `PinDetailSheet.swift`. All time formatting uses `Calendar.easternTime`. Verified by grep — all occurrences are in comments only.
- [x] **AC-D20** — `CommunityPin.swift` NOT modified. Verified: `git diff main -- ios/WePark/WePark/Models/CommunityPin.swift` is empty.

### Security / RLS

- [ ] **AC-D21** — Unauthenticated fetch returns pins. Deferred — requires prod schema apply. Code review confirms no `Authorization: Bearer` header is added; only `apikey` header sent. Test `testBuildRequest_noAuthorizationHeader` verifies this at the request-construction level.
- [x] **AC-D22** — Anon key NOT committed to source. `Info.plist` uses `$(SUPABASE_ANON_KEY)` xcconfig substitution (placeholder). Built bundle resolves to `placeholder-anon-key-not-real` (the value from the local Config.xcconfig placeholder). No literal Supabase anon key (eyJ...) in any committed file. Mapbox `pk.eyJ` grep is zero.

---

## Findings

### Blocking

None.

### Significant

None.

### Minor / nit

**#1: Test inventory comment claims 21 new tests; actual count is 20**
- Where: `ios/WePark/WeParkTests/CommunityPinServiceTests.swift`, header comment + PR description
- What: The test inventory header says "21 tests" and the PR description says "280 + 21 = 301/0 (total)". The actual file contains 20 `func test` methods. The missing test is inventory item #19: `testBuildRequest_containsExpectedQueryItems`. The actual total is 300/0 (280 pre-existing + 20 new), not 301/0.
- Expected: Comment inventory matches the actual implemented test count.
- Impact: Purely documentation. AC-D6 coverage is adequate — `testFetchRequest_includesOpenDataSourceFilter` covers the `source=eq.open_data` filter. The missing test would have verified the complete set of URL query items exhaustively.
- Owner: `@ios-engineer`

**#2: Community pin marker visual render not independently verified in sim smoke**
- Where: Smoke gate (AC-D10/AC-D11), `CommunityPinService.inject(fixtures:)`
- What: The QA smoke confirmed overlay layer integrity (toolbar, ASP banner — #31 regression class). However, community pin markers (`filming`/`special_event`) could not be visually verified because: (a) the app uses placeholder Supabase config (`https:` URL, placeholder anon key) so no live pins are fetched, and (b) the `inject(fixtures:)` API on `CommunityPinService` has no entry point accessible from outside the app binary at runtime in the sandbox — there is no URL scheme, CLI flag, or debug UserDefaults key to trigger fixture injection post-launch. This is consistent with the spec's own deferred posture for AC-D11 (requires prod schema + seeded pin). Kevin's manual smoke or a future debug-build launch argument is required to independently confirm marker rendering in the live app.
- Expected: At minimum a debug-build injection mechanism (URL scheme or `--CommunityPinFixtures` launch argument) documented for future QA passes, OR Kevin confirms via manual smoke that markers render when panning to a location with a seeded pin after prod schema apply.
- Impact: Marker rendering path is unit-tested (`syncCommunityPinAnnotations` diff logic reviewed), but live rendering is unconfirmed by QA.
- Owner: `@ios-engineer`

**#3: Detail sheet requires two taps (callout disclosure) vs spec sketch's one tap**
- Where: `ios/WePark/WePark/Views/MapViewRepresentable.swift`, `Coordinator.calloutAccessoryControlTapped`; spec `docs/tier1-pin-display-spec.md` §7.4
- What: Spec §7.4 sketches `mapView(_:didSelect:)` as the tap handler implying one tap opens the sheet. The implementation uses `canShowCallout = true` + `rightCalloutAccessoryView = UIButton(type: .detailDisclosure)` + `calloutAccessoryControlTapped`. This requires two taps: first tap reveals the callout (title/subtitle visible), second tap on the disclosure chevron opens `PinDetailSheet`.
- Expected: The spec sketch implies one-tap-to-sheet. The engineer shipped two-tap-to-sheet without documenting the deviation.
- Impact: Minor UX change. The callout-first approach is idiomatic MapKit and arguably better UX (users can see the callout title/subtitle before committing to the full sheet). Not a regression risk. Not a blocker.
- Owner: `@ios-engineer` — acknowledge deviation in HANDOFF.md or next PR description.

### Out of scope (logged, not fixed)

**Swift 6 warnings in `CommunityPinServiceTests.swift`:** Two `main actor-isolated conformance` warnings (`CommunityPin: Decodable`, `SuspensionBannerState: Equatable`) are warnings in Swift 5 mode (not errors). Will become errors in Swift 6 mode. Flagged for the Swift 6 migration pass. Documented in PR description.

**`resolvedBannerState` uses `Date()` (not an injectable `nowProvider`):** The free function uses `let now = Date()` rather than an injectable time provider. This means the expiry check in the ASP banner supplement cannot be frozen in tests. Currently mitigated — the AC-D9d test uses `kPast` for `expiresAt` which is always past `Date()` when tests run. However, an expiry-at-exact-boundary test (to second precision) cannot be written without this. Deferred — all AC-D9* tests pass and the functional risk is low.

---

## Smoke tests run

1. **Build (build-for-testing):** `xcodebuild build-for-testing` on `ios/tier1-pin-display` branch, iPhone 17 Pro sim (F0820726-15F4-4FA3-8602-A5D7B479A277, iOS 26.4/iphonesimulator26.5 SDK). Exit code 0. `** TEST BUILD SUCCEEDED **`.

2. **Test run (test-without-building):** `xcodebuild test-without-building`. Exit code 0. `** TEST EXECUTE SUCCEEDED **`. 300 tests passed, 0 failures. `RegionSyncGuardTests` (2/2) confirmed passing.

3. **Secrets check:**
   - `grep -r "pk.eyJ" ios/` — zero hits. No Mapbox token committed.
   - `Info.plist` — `$(SUPABASE_ANON_KEY)` xcconfig substitution only; built bundle resolves to `placeholder-anon-key-not-real`. No literal Supabase JWT committed.

4. **Built Info.plist inspection:** `PlistBuddy -c "Print :SUPABASE_URL"` returns `https:` (placeholder URL stem). `PlistBuddy -c "Print :SUPABASE_ANON_KEY"` returns `placeholder-anon-key-not-real`. Confirms the xcconfig bridge is wired correctly (same pattern as W8.5a Mapbox token).

5. **Live-UI smoke:** Installed and launched on iPhone 17 Pro sim. Screenshot `/tmp/qa-pr37-smoke-launch.png` captured and read via multimodal Read tool. Confirmed: green "ASP in Effect Today" banner (top), gear button (top-left), find-me / find-car / clock / Drive toolbar buttons (right side) all visible. No #31 regression. No community pin markers visible at wide Manhattan zoom — expected behavior.

6. **Diff scope verification:** `git diff main --name-only` produces exactly 8 expected files (Config.xcconfig.example, Info.plist, ContentView.swift, CommunityPinService.swift, MapViewRepresentable.swift, PinDetailSheet.swift, PinMarkerAnnotation.swift, CommunityPinServiceTests.swift). No unexpected files. `ASPSuspensionService.swift` confirmed unmodified.

---

## Drive Mode regression verification (CRITICAL — #31 class)

**ContentView.swift — merged `.onChange(of: driveModeActive)` handler:**

Exactly ONE `.onChange(of: driveModeActive)` handler in the modifier chain (line 802), calling `handleDriveModeAndCamera(_:)`. This function delegates to `handleDriveModeChange(_:)` (lifecycle) then `handleDriveCameraChange(_:)` (camera/style/puck) in the same order as the prior two-handler form. No behavioral difference. The new `pinService.setDriveModeActive(active)` call is in `handleDriveModeChange` — not a camera call, not a regression risk.

**MapViewRepresentable.swift — updateUIView path:**

`syncCommunityPinAnnotations` is the only new call in `updateUIView`. It calls only `mapView.addAnnotation`/`mapView.removeAnnotation` — confirmed no `setCamera`, `setRegion`, or other camera-state-resetting calls inside this method. The `shouldSyncRegionToBinding(driveModeActive:)` guard is intact and unchanged. No `headlessWindow` guard anywhere in the file.

**Verdict on Drive Mode regression risk: CLEAN.**

---

## ASP supplement additive-only verification

`resolvedBannerState(bundleState:aspPins:)` can only move state in the "more suspended" direction:

- `.todaySuspended` (early exit) → returns unchanged
- `.tomorrowSuspended` → the override condition is `case .aspInEffect = bundleState`; `.tomorrowSuspended` does not match, so the override never fires → returns unchanged
- `.aspInEffect` + live pin for today → returns `.todaySuspended` (the only upgrade path)

No path from suspended to not-suspended. Additive-only confirmed.

`ASPSuspensionService` public API: not modified (empty diff confirmed).

---

## What's working

- **Drive Mode regression: CLEAN.** The merged `.onChange(of: driveModeActive)` handler and body refactor preserve all #31-era invariants. The invariant documentation in code comments is thorough.
- **Annotation sync architecture:** `syncCommunityPinAnnotations` implements a clean UUID-keyed diff (O(n+m)) safe to call in `updateUIView` because it only calls `addAnnotation`/`removeAnnotation`. The decision/mechanism separation per spec §5.2 is correctly implemented.
- **`visiblePinsGeneration` counter pattern:** Clever workaround for `CommunityPin` not being `Equatable` (AC-D20 freeze). Gives SwiftUI an `Int` to observe without requiring `CommunityPin: Equatable`. Acceptable for TF1 low-density pins.
- **Secrets hygiene:** xcconfig substitution pattern correctly applied to both Supabase keys. No literals in any committed file.
- **`resolvedBannerState` pure-function design:** Extracted as `internal` free function so tests call it directly without mocking. All four AC-D9* tests pass. Additive-only logic verified.
- **`PinMarkerAnnotation` rendering:** UIGraphicsImageRenderer-based circular marker with SF Symbol correctly sized (32pt image, 44pt touch target). No force-unwraps in the rendering path.
- **Drive Mode guard in `CommunityPinService`:** `setDriveModeActive` + `lastFetchCenter` correctly implements the spec §6.3 "skip if center moved < 200m during Drive Mode" guard.
