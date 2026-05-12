# iOS Rendering Architecture Decision — MapPolyline at 40k-segment density

**Status:** Decision binding as of 2026-05-11. Supersedes the implicit W2 assumption that SwiftUI `MapPolyline` scales to ~40k segments.
**Owner:** Tech Lead (this doc). @ios-engineer owns implementation. Kevin approves before code starts.
**Affected specs:** `docs/ios-mvp-spec.md` §3.7, §5 W2, §7 R1; `docs/design/ios-mvp-palette.md` §4.
**Branch in flight:** `ios/w4-block-detail` (PR #16, commit `f2595f1`).

---

## Decisions Kevin must confirm before code starts

Two items require a yes/no before @ios-engineer is dispatched:

**D1.** The recommendation below (Option 1) requires replacing all `MapPolyline` usage in `ContentView.swift` with a `UIViewRepresentable`-wrapped `MKMapView`. The W3/W4 SwiftUI logic (`ParkingRulesEngine`, `TileLoader`, `BlockDetailView`, all Models) is kept intact. The iOS Engineer estimates this as ~2 engineer sessions of rendering-layer work plus 1 QA session. **Is that time investment acceptable given the TestFlight timeline?**

**D2.** The W4 sheet and tap mechanism (`MapReader` + haversine + `BlockDetailView`) was built for the SwiftUI `Map` container. Under Option 1, tap handling moves to `MKMapView.delegate` + a `UITapGestureRecognizer` with hit-testing against rendered `MKMultiPolyline` paths. The haversine search from W4 (`handleMapTap`, `findClosestSegment`) transfers with minimal changes. **Should @ios-engineer carry the W4 branch forward with a rendering swap, or close PR #16 and start from a fresh branch off `main`?** The recommendation below says: carry forward (the W4 SwiftUI sheet + engine wiring is salvageable; only the rendering layer changes).

---

## 1. Recommendation

**Option 1 — UIKit `MKMapView` bridged via `UIViewRepresentable`, rendering 5 `MKMultiPolyline` overlays grouped by current parking state, plus 1 selected-block highlight overlay.**

This is a binding decision. The phrase "consider evaluating" does not appear in this document.

The rendering layer changes. Everything else stays. `ParkingRulesEngine`, `TileLoader`, all Model types, `ASPSuspensionService`, `BlockDetailView`, the haversine tap search, and the `ParkPinService` (W5) contract are unaffected. The visual output — 5 severity colors, dynamic state updates every 60 seconds — is identical to the W3/W4 design. `docs/design/ios-mvp-palette.md` Option B (color encodes current state) remains fully intact.

---

## 2. Rationale

### Why the current approach broke

SwiftUI's `MapPolyline` inside `@MapContentBuilder` is lowered by MapKit's internal VectorKit engine into discrete Metal GPU resources. Based on the Xcode log from `f2595f1`:

```
Exceeded Metal Buffer threshold of 50000 with a count of 1262055 resources
```

The math: 40,664 segments × approximately 30 Metal resources each (geometry buffer, stroke shader, bounding overlay, etc.) = 1.22M resources. Apple's VectorKit hard-limits sessions at 50,000. The pruner had not fired in 4.6 hours, allowing unbounded accumulation. Process RSS reached 19.92 GB. Load time to first render exceeded 30 minutes.

This is not a zoom-gating failure, not a cache-size failure, and not a W4 regression. The W4 Annotation overlay that fix-pass-1 (`f2595f1`) already dropped was an aggravator (additional `UIHostingController` allocation per segment), but the root cause is that each individual `MapPolyline` is a distinct Metal resource group, and 40k distinct overlays exceeds VectorKit's design envelope by roughly 25x.

The zoom-threshold gating (`polylineHideSpanThreshold = 0.1`) limits *which* tiles are loaded, but once the user navigates at street-level zoom across Manhattan, the LRU cache limit of 50 tiles means up to ~2,000 segments are rendered at any time. That is still approximately 60,000 Metal resources — above the 50,000 threshold, just barely.

### Why not Option 2 (zoom gating only / status quo)

Option 2 (cap rendering to `latitudeDelta < 0.02`, approximately 2km viewport) would reduce the visible segment count to roughly 300–500 per viewport. That is under the Metal threshold in steady-state. It has three disqualifying problems:

1. **Product regression.** The entire value proposition of WePark is "I open the app and see where I can park across the neighborhood." A user zoomed out to see three blocks can't get city-scale guidance. The app becomes functionally the same as tapping each block one-by-one. Kevin has not approved this concession.

2. **Not actually solved.** A user at zoom 15 who pans aggressively across lower Manhattan for 60+ minutes will still accumulate Metal resources because MapKit does not reliably recycle GPU resources for overlays that have left the viewport — the pruner interval of ~4.6 hours proves it. Option 2 slows the accumulation but does not fix it.

3. **No path to Drive Mode.** Phase 5b (Drive Mode port) requires rendering a contiguous colored street corridor while the user moves through Manhattan. That use case requires zoom 16–18 on a moving viewport, which is the densest possible rendering scenario. Solving only the current problem with a threshold leaves Phase 5b with the same failure.

### Why not Option 3 (pre-rendered raster tiles)

Option 3 abandons Option B dynamic state color. Baking current-state color into PNG tiles at build time would require one tile set per hour of week (7 days × 24 hours = 168 bake passes per zoom level). At zoom levels 14–18 that's 168 × 5 = 840 tile bake operations, plus CDN hosting. The product decision locking Option B (dynamic state color) is in `docs/ios-mvp-spec.md` §3.7 and `docs/design/ios-mvp-palette.md` §1. Reverting to static-category color is a product regression that requires Kevin's explicit approval; this document does not recommend it.

### Why Option 1 works at this density

`MKMultiPolyline` is a single `MKOverlay` object that bundles arbitrarily many coordinate sequences. MapKit renders all sequences in a `MKMultiPolylineRenderer` as a single Metal draw call. From Apple's MapKit API documentation and WWDC session patterns: the resource count is independent of the number of child sequences — one `MKMultiPolyline` = one resource group, regardless of whether it contains 5 polylines or 5,000.

WePark needs 6 overlays total:
- 5 state groups: `freeComfortably`, `freeButRestrictionSoon`, `meteredActive`, `restrictedNow`, `unknown`
- 1 selected-block highlight (a thin dedicated overlay so the selected segment gets `lineWidth: 6` and a different color without touching the state-grouped overlays)

6 overlays = 6 Metal resource groups. Under the 50,000 threshold by a factor of 8,000.

### The PWA comparison

The PWA (`index.html`:3408) uses Leaflet with one `L.polyline` per segment. Leaflet is Canvas 2D, not Metal GPU. Canvas composites polylines by painting pixel rows at render time; there is no per-polyline GPU resource allocation. This is why Leaflet scales to 40k segments without issue — it does not have MapKit's resource model. Porting Leaflet's approach to iOS is not possible with MapKit's API; `MKMultiPolyline` is the closest MapKit analog because it collapses many geometry descriptions into one GPU object.

### iOS 17 API availability

`MKMultiPolyline` was introduced in iOS 13. `MKMultiPolylineRenderer` was introduced in iOS 13. Both are fully available on the iOS 17 deployment target. The `UIViewRepresentable` pattern (`makeUIView` + `updateUIView` + `Coordinator` as `MKMapViewDelegate`) is the documented pattern for MapKit on iOS 17 when using features that the SwiftUI `Map` builder does not expose. Apple's own MapKit documentation for performance at high overlay density recommends `MKMultiPolyline` explicitly.

One renderer limitation to plan around: a single `MKMultiPolylineRenderer` can only have one `strokeColor`. This is why the 5-group pattern is required. When a segment changes state (e.g., a metered block at 9am transitions from free to active), it is removed from the `freeComfortably` group and added to the `meteredActive` group. This recomputation happens on the existing 60-second timer cadence already established in W3. The cost is a single array partition over loaded segments (O(n) where n is loaded segments, approximately 500–2,000 at street-level zoom) plus two `MKMapView.removeOverlay` / `addOverlay` calls. This is negligible.

### Does a fourth option exist?

A possible fourth option is Metal-direct tile rendering (render colored polylines as a custom `CATiledLayer` or `MTKView` overlay below the MapKit tiles). This is what fully custom map SDKs like Mapbox iOS do internally. It would give maximum control over GPU resource lifecycle. The cost is 4–6 weeks of rendering engine work, far outside the MVP timeline. It is the right answer for Phase 5c Drive Mode (continuous animated route rendering), not for the current goal of "colored static parking blocks." Documenting it here for Phase 5b/5c planning but not recommending it for W2–W4.

---

## 3. Work-stream plan

### What changes and what stays

| Layer | Action | Owner |
|---|---|---|
| `ContentView.swift` — `Map { }` + `@MapContentBuilder` + `MapPolyline` | Replace with `UIViewRepresentable` `MapViewRepresentable` wrapping `MKMapView`. Remove `MapReader`. | @ios-engineer |
| Overlay state grouping | New method on `ParkingRulesEngine` or a new `OverlayGrouper` helper: partitions loaded segments by current state → 5 coordinate arrays → 5 `MKMultiPolyline` objects. Recomputed on 60s tick + camera settle. | @ios-engineer |
| `MKMapViewDelegate` — `Coordinator` | `mapView(_:rendererFor:)` returns `MKMultiPolylineRenderer` with `strokeColor` matching the state group's `ParkingColors` value. `lineWidth` per group (4 for meteredActive, 3 for others). | @ios-engineer |
| Tap handling | `UITapGestureRecognizer` added to `MKMapView`. On tap: call `ParkingRulesEngine.findClosestSegment` (the W4 haversine search transfers). On match: set `selectedSegmentID`, update selected-block overlay. On miss: clear selection. | @ios-engineer |
| Selected-block highlight | A 6th `MKPolyline` overlay (single segment, `lineWidth: 6`, `strokeColor: ParkingColors` for that segment's state). Replaced on each new selection. | @ios-engineer |
| `BlockDetailView`, `ParkingRulesEngine`, `TileLoader`, all Models | No changes. These do not depend on the rendering layer. | — |
| `ASPSuspensionService`, `ParkPinService`, `NotificationScheduler` | No changes. | — |
| Unit tests (43 passing) | No changes. All tests are against pure-logic modules. | — |
| `docs/design/ios-mvp-palette.md` §4 | Text update only (see §4 of this doc). | Kevin / Tech Lead |
| `docs/ios-mvp-spec.md` §3.7, §7 R1 | Text update only (see §4 of this doc). | Kevin / Tech Lead |

### Does this require redoing W2/W3/W4 from scratch?

No. The rendering layer is a swap, not a rewrite.

- **W2** (`TileLoader`, `Segment`, `ParkingRule`, `Category`) is unchanged. The tile JSON parsing, coordinate ordering, LRU cache, and the observable `segments` array are all rendering-agnostic.
- **W3** (`ParkingRulesEngine`, `ASPSuspensionService`, `ParkingColors`, all `CurrentState` logic) is unchanged. The 5 current-state enum cases map directly to the 5 `MKMultiPolyline` groups. No interface change needed.
- **W4** (`BlockDetailView`, `handleMapTap`, `findClosestSegment`, `selectedSegmentID`, sheet mechanics) is mostly preserved. The haversine tap search does not depend on the rendering layer at all — it operates on `tileLoader.segments` (the data model array) and a coordinate, both unchanged. What changes: the `MapReader` wrapper is removed (not needed in UIKit), and `onTapGesture` on the `Map` container is replaced with a `UITapGestureRecognizer` that calls the same `handleMapTap` logic.

### Is PR #16 salvageable?

Yes. Close PR #16 only as a procedural matter — the branch `ios/w4-block-detail` contains the working W4 sheet + tap mechanism, and `@ios-engineer` should base the rendering-swap work off that branch (or a new branch branched from it), not from `main`. The fix-pass-1 commit (`f2595f1`) already dropped the Annotation memory aggravator. The remaining work is replacing `ContentView`'s `Map { }` rendering with `UIViewRepresentable`, which is a contained change.

If Kevin prefers a cleaner PR history: close #16, open a new `ios/rendering-refactor` branch from `main` that first lands the rendering swap (W2 rendering), then cherry-picks the W4 sheet changes on top. This gives two focused PRs instead of one large one. Either approach is valid. The recommendation is to carry #16 forward — the existing code review context is useful.

### Are W5/W6/W7/W8 affected?

- **W5 (pin drop):** `ParkPinService` + `ParkPinSheet` are UI-layer concerns sitting above the map. No change needed. The "Park here" button in `BlockDetailView` connects to `ParkPinService`, which is rendering-agnostic.
- **W6 (notifications):** No change. `NotificationScheduler` has no map dependency.
- **W7 (ASP banner):** No change. `ASPBanner` is a SwiftUI view overlay pinned to the top; it does not interact with the map rendering layer.
- **W8 (TestFlight):** The rendering swap is a prerequisite — W8 cannot ship until the Metal-resource budget is under control. This is not a new blocker (the app as of `f2595f1` would be killed by jetsam on a real device within seconds). W8 is already blocked on Apple Developer Program enrollment; the rendering fix happens in parallel.

### Effort estimate

| Stream | Effort | Notes |
|---|---|---|
| `MapViewRepresentable` (UIKit bridge) + 5-group `MKMultiPolyline` render + `Coordinator` delegate | 1 engineer session | Standard pattern; no novel API. The Coordinator + `mapView(_:rendererFor:)` is ~100 lines. |
| Tap handling migration (UITapGestureRecognizer + haversine transfer) | 0.5 sessions | The haversine search is already written. Only the gesture entry point changes. |
| 60s color-recompute integration (repartition segments → rebuild `MKMultiPolyline` arrays → `removeOverlay` / `addOverlay`) | 0.5 sessions | Timer cadence is already established in W3. The partition step is a single `Dictionary(grouping:)` call. |
| QA pass (memory verification + FPS + tap regression + AC-W4 re-run) | 1 session | Must include VectorKit assertion check and RSS measurement per §5. |

**Total: approximately 3 engineer sessions.** This delays the W5 start by 3 sessions relative to the original plan of shipping W4 as-is. Given that W4 as-is would be killed by jetsam on a real device, this is the actual W4 cost — not an addition to it.

### Parallelization

There is no parallel work to split here. The rendering refactor is a single-author change to `ContentView.swift` and the new `MapViewRepresentable.swift`. `@backend-data` and `@pwa-maintainer` are not affected. `@designer` review of the visual output is appropriate after the refactor is in the simulator, but does not block the engineering work.

---

## 4. Replacement text for spec docs

These are draft replacements to be applied to `docs/ios-mvp-spec.md` and `docs/design/ios-mvp-palette.md` when Kevin is ready. The Tech Lead does not edit those files directly; Kevin lands the changes via PR after confirming D1 and D2 above.

### Replacement for `docs/ios-mvp-spec.md` §3.7 (rendering decisions, second half of the decision block)

Replace the paragraph beginning "**Implementation note for W3**" and the `MapPolyline` usage pseudocode that follows, with:

---

**Rendering layer decision (updated 2026-05-11):** SwiftUI `MapPolyline` inside `@MapContentBuilder` is disqualified at WePark's tile density. Profiling at commit `f2595f1` on an iPhone 17 Pro simulator showed VectorKit accumulating 1,262,055 Metal GPU resources against a hard threshold of 50,000, producing 19.92 GB RSS and a 30-minute time-to-first-render. Each `MapPolyline` is a distinct Metal resource group; 40,664 segments × ~30 resources each exceeds the threshold by 25×.

**Adopted approach: UIKit `MKMapView` via `UIViewRepresentable`, 6 `MKMultiPolyline` overlays.**

`MKMultiPolyline` groups arbitrarily many coordinate sequences into a single `MKOverlay` rendered by a single `MKMultiPolylineRenderer` — one Metal resource group, independent of child sequence count. WePark uses 6 overlays:

1. `freeComfortably` — `ParkingColors.freeComfortably` (green), `lineWidth: 3`
2. `freeButRestrictionSoon` — `ParkingColors.restrictionComingSoon` (orange), `lineWidth: 3`
3. `meteredActive` — `ParkingColors.meteredActive` (amber-yellow), `lineWidth: 4`
4. `restrictedNow` — `ParkingColors.restricted` (red), `lineWidth: 3`
5. `unknown` — `ParkingColors.unknown` (gray 0.35 opacity), `lineWidth: 3`
6. `selectedBlock` — `MKPolyline` (single segment), `lineWidth: 6`, color = state color of selected segment

On the 60-second timer tick (already established in W3), `ParkingRulesEngine` partitions `tileLoader.segments` by `currentState(for: segment, at: now)`, rebuilds the 5 `MKMultiPolyline` arrays, and calls `MKMapView.removeOverlay` / `addOverlay` for any group whose segment set changed. This is O(n) over loaded segments (~500–2,000 at street-level zoom) and negligible on the main thread.

**Option B (color encodes current state) is fully preserved.** The 5 state groups are the same 5 cases in `CurrentState`; the `ParkingColors` enum values are unchanged. The visual output is identical to the W3/W4 design intent.

**Tap handling** uses a `UITapGestureRecognizer` on `MKMapView`, with the W4 haversine point-to-segment search (`findClosestSegment`, 20m threshold) transferred without changes. On a match, the selected-block overlay (group 6) is updated and `selectedSegmentID` is set — the `BlockDetailView` sheet presents via a SwiftUI `@Binding` passed into the `UIViewRepresentable` wrapper.

**API availability:** `MKMultiPolyline` and `MKMultiPolylineRenderer` are available since iOS 13. No iOS 18-only APIs are used.

---

### Replacement for `docs/ios-mvp-spec.md` §7 R1 (stress test, the one that was never run)

Replace the R1 bullet with:

---

**R1. MapKit polyline density — RESOLVED by architecture decision 2026-05-11.** See `docs/ios-rendering-architecture-decision.md` for full analysis. The SwiftUI `MapPolyline` / `@MapContentBuilder` approach is disqualified. The adopted solution is UIKit `MKMapView` + `MKMultiPolyline` (6 overlays total). The stress test criterion that should have been specified from W2 is now the W2-rendering-refactor acceptance criterion in §5 of the rendering architecture decision doc.

The R1 stress test specified here for the original W2 approach is superseded. The equivalent test for the `MKMultiPolyline` approach is: 5 minutes of panning Manhattan at zoom 12–18, simulator RSS under 500 MB, no VectorKit assertion in console (see rendering architecture decision §5).

---

### Replacement for `docs/design/ios-mvp-palette.md` §4 (block visualization)

Replace §4.1 "Default: line-on-line polylines" with:

---

### 4.1 Rendering layer — UIKit MKMapView + MKMultiPolyline (updated 2026-05-11)

The W2 implementation used SwiftUI `MapPolyline` inside `@MapContentBuilder`. That approach is disqualified at WePark's segment density. See `docs/ios-rendering-architecture-decision.md` for the full post-mortem. The visual spec below is unchanged; only the implementation layer changed.

Colored polylines are rendered via `MKMultiPolyline` overlays grouped by current parking state. The visual appearance — line-on-line colored block faces at `lineWidth: 3–4`, `lineCap: .round`, `lineJoin: .round` — is identical to the original spec. The 5 state groups plus 1 selected-block highlight produce 6 Metal resource groups total, far under VectorKit's 50,000 limit.

Line style is unchanged from the original specification:
- `lineWidth: 3` for all groups except `meteredActive` (`lineWidth: 4` per §2.3).
- `lineCap: .round`, `lineJoin: .round`.
- Selected block: `lineWidth: 6`, color = that segment's state color.

---

Replace §4.2 "Alternative visualizations (escalation path)" with:

---

### 4.2 Alternative visualizations

The alternatives documented here (zoom gating, opacity wash, block-center dots) remain available if the `MKMultiPolyline` approach produces unexpected visual or performance issues. However, the `MKMultiPolyline` refactor is expected to resolve all previously-observed performance problems with margin. Do not implement these alternatives preemptively. The escalation criterion is: VectorKit assertions in console OR measured FPS below 30fps at Manhattan zoom 14–15 after the refactor ships.

Alternative A (zoom-threshold gating) is already implemented in the codebase (`polylineHideSpanThreshold = 0.1`) and will be retained in the `UIViewRepresentable` wrapper unchanged.

---

## 5. Verification criterion

The following criteria are required before the rendering refactor PR merges. These are the criteria that should have been specified in W2 day one.

| Criterion | Pass condition | How to measure |
|---|---|---|
| **VectorKit Metal resource count** | No "Exceeded Metal Buffer threshold of 50000" assertion in Xcode console after 5 minutes of panning Manhattan zoom 12–18 | Run in iPhone 17 Pro simulator. Monitor Xcode console. Zero pruner assertions = pass. |
| **Simulator RSS under load** | Peak RSS under 500 MB after 5 minutes of panning at zoom 12–18 | Debug navigator → Memory gauge in Xcode. |
| **Real-device RSS** | Peak RSS under 150 MB on a real iPhone (iPhone 12 or later) after 5 minutes of panning | Instruments → Allocations template, or Xcode Device → Memory gauge. This is a should-pass criterion; if it exceeds 150 MB on real hardware, escalate to @ios-engineer before proceeding to W5. |
| **Frame rate** | ≥30fps sustained, ≥45fps target at zoom 14–15 over Manhattan with all visible tiles loaded | Instruments → Core Animation FPS template on real device. Simulator FPS is not predictive. |
| **Tap accuracy** | Tapping a polyline opens the correct segment's sheet within 200ms. Tapping 20m+ from any polyline dismisses the sheet. | Manual: 10 taps on real device. |
| **Color correctness** | Each of the 5 state groups renders in the correct `ParkingColors` color. Selected block renders at `lineWidth: 6` in the correct color. | Visual verification: compare against `docs/design/ios-mvp-palette.md` §2.1 table. |
| **State recompute on 60s tick** | Color groups update at the clock boundary (e.g., a metered block transitions from `meteredActive` to `freeComfortably` at 7pm). | Set device clock to 6:58pm, park the app for 2 minutes, verify the metered blocks' colors change. |
| **W3 regression test** | `xcodebuild test` reports 43 passed, 0 failed | Run on a machine with adequate RAM (16 GB, minimal swap). |
| **No VoiceOver regression** | In-sheet VoiceOver accessibility is intact: safety label is first focusable element, ✕ button reads "Close block details", rule rows combine to single elements. | VoiceOver on real device. |

The RSS thresholds (500 MB simulator, 150 MB real device) are derived from iOS jetsam behavior: foreground apps on modern iPhones are typically killed at 200–400 MB RSS depending on device class and system memory pressure. 150 MB leaves 50–250 MB headroom for future features (W5 pin, W6 notifications, W7 banner, Phase 5b Drive Mode overhead). The 500 MB simulator threshold is looser because the simulator does not use jetsam; it is a canary for "the allocation pattern is under control," not a hard limit.

---

## 6. What is explicitly deferred by this decision

- **VoiceOver map-navigation of individual polylines.** The `MKMultiPolyline` approach groups all segments by state, so individual segment identity is invisible to UIKit's accessibility layer. `MKMapView` has `MKAnnotation` objects (native, much lighter than `UIHostingController`) that can be used at reduced density for VoiceOver navigation — this is a post-MVP follow-up per the note already in the W4 fix-pass-1 PR description.
- **Phase 5b Drive Mode rendering.** The `MKMultiPolyline` approach works for static parking-block visualization. Drive Mode requires continuous overlay animation (route polyline, side-of-street highlight moving with the car). That is a separate rendering design problem and explicitly deferred to the Phase 5b spec.
- **Dark Mode custom tuning for `MKMultiPolylineRenderer` stroke colors.** The `ParkingColors` values are specified as SwiftUI `Color` values in `ParkingColors.swift`. `MKMultiPolylineRenderer.strokeColor` takes `UIColor`. The `UIViewRepresentable` Coordinator must resolve `Color` → `UIColor` via `UIColor(color)` (available since iOS 14, well within the iOS 17 target). Dark Mode adaptation via system semantic colors (`Color.red`, `.orange`, `.green`) works through this path. The amber-yellow custom value does not adapt (intentionally per palette doc §5.2). No change needed.
