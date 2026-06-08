# FT-11 — Travel-Direction Indicator on Enforcement-Agent and Street-Sweeper Reports

**Status:** Post-TF2 — spec ready, engineering not started.
**Owner:** @ios-engineer (all Swift/SwiftUI). @backend-data (tile-pipeline change — see §4).
**QA:** @qa-verifier (independent, after engineering merges).
**Parallel with:** Any TF2 streams on disjoint files.
**Depends on:** FT-11 tile field (`oneway_toward`) must ship from @backend-data before iOS can implement the sweeper auto-derive path. The two-arrow picker for enforcement and two-way-sweeper is independent and can ship without the tile change.

---

## Open Decisions — Kevin Must Confirm Before Engineering Starts

| # | Question | Impact |
|---|---|---|
| OD-1 | **Picker required or optional for off-segment reports?** When `segmentId` is nil (long-press off any segment), the spec recommends hiding the picker entirely and omitting `heading_toward` from meta. Alternative: show the picker but disable segment-bearing visualization (arrows still oriented but without real bearing context). Spec recommends hide/omit. | Affects ReportSheet logic and AC-11. |
| OD-2 | **Marker arrow style.** The spec recommends a thin chevron (`chevron.forward` rotated to bearing) overlaid on the existing circle marker. Alternative: rotate the entire marker image (easier but visually odd for a circle). Recommendation: a separate overlay sublayer is cleaner. Kevin to confirm before @designer reviews the marker spec. | Affects PinMarkerAnnotation implementation scope. |
| OD-3 | **Backward-compat pins with `heading_toward` absent.** Spec says: render current marker unchanged (no arrow). Kevin to confirm this is acceptable — no "unknown direction" affordance for old pins. | Affects AC-17. |

---

## 1. Problem and User Story

**Problem:** Enforcement agents and street sweepers travel in a specific direction on a block. A report that says "sweeper is on Spring St between Wooster and Greene" is useful but imprecise — the sweeper may have just reached the Wooster end (heading toward Greene, just started) or the Greene end (heading away, almost done). A neighbor parked at the Greene end needs to know whether to move NOW or has another 3–4 minutes. Without direction, the pin under-delivers on the community-safety promise.

**Why now (post-TF2):** TF1 is on TestFlight. TF2 will incorporate supabase-swift real-time websockets and likely several polish items. FT-11 is a self-contained feature with a small backend-data tile change and a focused iOS UI addition. It is not urgent enough to hold up TF2 but is the right next community reporting enhancement after the write path stabilizes with real users.

**User story (enforcement):**
> Kevin is on West 3rd St and spots a parking agent writing tickets at the 6th Ave end of the block, working his way toward MacDougal. He long-presses and taps "Report enforcement or sweeper." He picks "Enforcement active." Below the sub-tag picker, two arrow buttons appear: one pointing toward "6 AVENUE" (the `from` cross-street) and one pointing toward "MACDOUGAL STREET" (the `to` cross-street). Each arrow is visually aligned with the actual block bearing. He taps the MacDougal arrow. The pin drops. On the map, the marker shows a small directional chevron pointing toward MacDougal. A neighbor on the MacDougal end knows the agent is heading their way and moves their car.

**User story (sweeper — one-way street):**
> A user on a one-way block of Thompson St (southbound) taps Report after seeing the sweeper truck. She picks "Street sweeper." No arrow picker appears — the app auto-fills the direction from the street's one-way data, pointing in the legal travel direction. The pin drops with the arrow pre-set. Zero extra taps.

**User story (sweeper — two-way street):**
> Same flow on a two-way block like West 4th St. Because the sweeper can travel either direction, the two-arrow picker appears just as it does for enforcement. User picks one, pins drops, marker shows the arrow.

---

## 2. Scope

### 2.1 In Scope

- `meta.direction` encoding on `enforcement_active` and `sweeper_passed` pins: `{"heading_toward": "from" | "to"}`.
- ReportSheet UI additions:
  - Two-arrow picker for `enforcement_active` (always shown when `segmentId` is non-nil).
  - Two-arrow picker for `sweeper_passed` when the segment's street is NOT one-way.
  - Auto-derive (no picker) for `sweeper_passed` when the segment's street IS one-way.
  - Picker hidden, direction omitted, when `segmentId` is nil.
- `CommunityPinService.insertCrowdPin` wire-through: pass the chosen/derived direction as part of `meta`.
- `PinMarkerAnnotation` marker arrow overlay: rotate a directional chevron to the segment bearing toward the stored endpoint.
- `EnforcementActiveMeta` and `SweeperPassedMeta` struct additions: `headingToward: HeadingToward?` field (`"from"` or `"to"`).
- Tile pipeline (`build/preprocess.js`): add `oneway` string field and `oneway_toward` string field (`"from"` or `"to"`) to each segment in tile output. `@backend-data` owns this.
- `Segment.swift`: add `oneway: String?` and `onewayToward: String?` decoded fields.
- Bearing utility: `SegmentBearing` free function (or extension on `Segment`) computing the bearing from `line[0]` to `line.last` and the reverse, so the arrow UI can orient arrows correctly at report time, and the marker can orient the chevron at display time.
- Unit tests: bearing computation, direction derivation, one-way auto-derive, `buildMeta` extension, backward-compat (no `headingToward`).
- Smoke gate: report an enforcement pin → pick a direction → marker shows arrow; report sweeper on a known one-way block → arrow auto-points.

### 2.2 Out of Scope

- Direction on any pin type other than `enforcement_active` and `sweeper_passed`.
- Backend schema change — `meta` column is already `jsonb`; adding `heading_toward` to the JSON needs no migration. The `@backend-data` work is tile pipeline only, not Supabase.
- PWA: `index.html` is in maintenance mode. The PWA already renders these pins without a direction arrow; FT-11 is iOS-only.
- UI for displaying direction on `PinDetailSheet.swift` (the tap-to-view detail). The arrow on the map marker is sufficient for v1. A text label ("Heading toward MacDougal") in the detail sheet is a follow-up.
- Historical backfill of existing pins' `heading_toward`. Legacy pins simply render without an arrow.
- Cross-pollination (tracker reports auto-posted to zone chat) — that is Phase 2d scope.

---

## 3. Investigation Summary

### 3.1 `osm_oneway.json` Structure

**Shape confirmed from `index.html:1803–1848`:**

```
{
  "Spring Street": [
    { "polyline": [[lat,lng], [lat,lng], ...], "oneway": "yes" | "reverse" | "no" },
    ...
  ],
  ...
}
```

The file is a dictionary keyed by **OSM title-case street name** (e.g., `"Spring Street"`, `"6th Avenue"`). Values are arrays of OSM `way` objects — each way has a `polyline` array of `[lat, lng]` pairs and a `oneway` field.

- `oneway = "yes"` — legal travel is forward along the polyline (polyline index 0 → last).
- `oneway = "reverse"` — legal travel is backward along the polyline (last → 0).
- `oneway = "no"` (or absent) — two-way.

**Keying mismatch with tile segments:** Tile segment IDs use NYC-normalized uppercase names (e.g., `"SPRING STREET"`). The `osm_oneway.json` keys are OSM title-case. The `osmName()` function in `build/preprocess.js` handles this translation at tile-build time. That same translation must run at tile-build time to embed the oneway data — see §4.

**Is `osm_oneway.json` sufficient for iOS to determine one-way status?** Not directly — the iOS app does not load `osm_oneway.json`. The file is currently used only by the PWA's `loadStreetGraph()` (route planning). iOS receives its data entirely through the bundled tile JSON files. Therefore:

- iOS cannot call into `osm_oneway.json` at runtime.
- `@backend-data` must embed the one-way answer into each tile segment during the build, as two new fields: `oneway` (bool: is the street one-way?) and `oneway_toward` (string: `"from"` or `"to"`, indicating which endpoint legal travel heads toward). See §4.

**Does `line` ordering imply direction?** The `line` polyline in tile segments is extracted by `extractPolylineBetween(streetOsmName, ptFrom, ptTo)`, where `ptFrom` is the intersection with the `from` cross-street and `ptTo` is the intersection with the `to` cross-street. The ordering is therefore consistent: `line[0]` is near the `from` end, `line.last` is near the `to` end. This ordering is load-bearing for the bearing computation (§5.1). However, the `line` ordering alone does not tell iOS whether the street is one-way or which direction is legal — that still requires the `oneway_toward` field from the tile.

### 3.2 Tile Segment Shape — No Existing One-Way Fields

Confirmed by reading `ios/WePark/WePark/Models/Segment.swift` and `tiles/tile_0_3.json`: the current tile shape has no `oneway` field. `preprocess.js` does not currently embed any OSM one-way data in the output JSON. The `osm_oneway.json` data is loaded by the PWA separately at runtime. This confirms @backend-data work is required.

### 3.3 iOS Segment Model

`Segment.swift` (at `ios/WePark/WePark/Models/Segment.swift`) is `Codable, Identifiable`. Fields: `id`, `street`, `fromStreet` (decoded from JSON key `"from"`), `to`, `side`, `line: [[Double]]`, `rules: [ParkingRule]`, `dominantCategory: Category?`. The model uses explicit `CodingKeys`. Adding two new optional fields (`oneway: Bool?`, `onewayToward: String?`) requires adding two cases to `CodingKeys` and two stored properties decoded with `decodeIfPresent`. Backward-compatible with all existing tiles (absent = nil = unknown).

### 3.4 Report Flow — Where Direction Plugs In

**ReportSheet** (`ios/WePark/WePark/Views/ReportSheet.swift`) currently:
- Is presented via `ActiveSheet.reportPin(coord:)`.
- Receives `coordinate: CLLocationCoordinate2D` and `pinService: CommunityPinService`.
- Currently calls `pinService.insertCrowdPin(type:meta:lat:lng:segmentId:zoneId:notes:)` with `segmentId: nil` (hard-coded nil at line 376).
- The `buildMeta(type:subTag:sweeperDirection:)` static function produces the `[String: Any]?` dict.

**Two gaps to close for FT-11:**
1. `ReportSheet` needs to receive the resolved `Segment?` (not just the coordinate) so it can show the picker with actual cross-street labels and compute the bearing for arrow orientation. Currently only the coordinate is injected; the segment is resolved separately by the tap-handler in `ContentView`. The segment can be passed as an additional init parameter.
2. `buildMeta` must be extended to incorporate the chosen or derived `heading_toward` value.

**`insertCrowdPin` already accepts `segmentId: String?`** — it just needs to be passed through from the resolved segment. The `meta: [String: Any]?` dict already accepts arbitrary keys. Adding `"heading_toward": "from"` or `"heading_toward": "to"` requires no service-layer change.

### 3.5 Meta Structs

`EnforcementActiveMeta` (in `CommunityPin.swift`) currently has only `subTag: SubTag?`. `SweeperPassedMeta` has only `direction: Direction?` (passed/coming_soon). Both need a new optional field `headingToward: HeadingToward?` where `HeadingToward` is a new two-case enum: `case from = "from"` and `case to_ = "to"` (note: `to` is a Swift keyword, so use `case toward_to = "to"` or `case toEnd = "to"` — engineer to choose non-conflicting name; raw value must be `"to"`). The `buildMeta` function in `ReportSheet.swift` builds a raw `[String: Any]` dictionary, so it passes `"heading_toward": "from"/"to"` as a string key — the struct's `Codable` conformance handles roundtrip on the read path.

### 3.6 Marker Rendering

`PinMarkerAnnotation.swift` (`ios/WePark/WePark/Views/PinMarkerAnnotation.swift`) renders `enforcement_active` and `sweeper_passed` markers as filled circles with SF Symbol overlays (person.badge.clock.fill in teal, truck.box.fill in cyan). The `configure(for:)` method sets the `image` property from `markerImage(for:)` which uses `UIGraphicsImageRenderer`. There is no rotation or directional overlay currently.

The bearing-based arrow must be added as a rendered directional chevron baked into the marker image — the cleanest approach given the UIKit annotation view system (transforms on `MKAnnotationView` can be used too, but baking into the image at configure-time is simpler and avoids needing the segment bearing to be stored on the annotation view). The annotation view `configure(for:)` needs the resolved `Segment` (for bearing computation) in addition to the `CommunityPin`.

**Critical:** `CommunityPinAnnotation` (also in `PinMarkerAnnotation.swift`) wraps a `CommunityPin` but does not carry a `Segment` reference. For bearing computation at display time, the annotation needs to carry either the `Segment` itself or the pre-computed bearing. Since segments are available from `TileLoader` in `ContentView`, the cleanest path is: compute the bearing when building the `CommunityPinAnnotation` (in the same loop that adds annotations to the map), store it on the annotation, and pass it through to `configure(for:bearing:)`.

### 3.7 Bearing Math

`LocationService.swift` has a `private func bearingFromTo(lat1:lng1:lat2:lng2:) -> Double` (lines 303–310). This is `private` and tied to `LocationService`. A new `SegmentBearing` free function or `Segment` extension should expose:

```
// Pseudocode (not production code — for @ios-engineer reference)
func bearing(segment: Segment, toward: HeadingToward) -> Double {
    let coords = segment.coordinates
    guard coords.count >= 2 else { return 0 }
    switch toward {
    case .from:
        // Direction from line.last toward line.first
        return bearingFromTo(line.last, line.first)
    case .to:
        // Direction from line.first toward line.last
        return bearingFromTo(line.first, line.last)
    }
}
```

The same `bearingFromTo` formula (atan2 of sin/cos components) already exists in `LocationService` and as a JavaScript port in `index.html:6572`. The iOS engineer should extract it into a standalone internal utility (not on `LocationService` which is a live GPS service — wrong conceptual home).

---

## 4. Backend-Data Work — Required Before iOS Sweeper Auto-Derive

**Backend-data tile change is REQUIRED.** iOS cannot determine one-way status from existing tile data. @backend-data must modify `build/preprocess.js` to embed two new fields per segment.

### 4.1 New Fields on Each Tile Segment

| Field | Type | Values | When absent |
|---|---|---|---|
| `oneway` | boolean | `true` = one-way, `false` = two-way | missing/false = treat as two-way |
| `oneway_toward` | string | `"from"` or `"to"` | absent when `oneway = false` |

`oneway_toward` encodes which endpoint of the segment the legal one-way travel heads toward, in terms of the segment's own `from`/`to` cross-street names.

**Example:** A segment on Spring St from `"from": "WOOSTER STREET"` to `"to": "GREENE STREET"`, one-way westbound (toward Wooster). `oneway = true`, `oneway_toward = "from"`.

### 4.2 Derivation Logic in `preprocess.js`

For each tile segment, after the block geometry is built:

1. Look up the segment's street in `osm_oneway.json` using `osmName(block.street)`.
2. If the street has no entry or all its ways have `oneway = "no"`, emit `oneway: false` (no `oneway_toward`).
3. If any way covers the segment's block span and has `oneway = "yes"` or `"reverse"`:
   - Identify which way covers the block (closest waypoint match — same logic as the existing `closestPointOnStreet` call).
   - `oneway = "yes"` means travel goes polyline-forward, i.e., from lower index to higher index. The `line` in the tile is built from `ptFrom` (the `from`-cross-street intersection) to `ptTo` (the `to`-cross-street intersection) via `extractPolylineBetween`. If the OSM way's polyline direction matches that ordering (ptFrom is near OSM polyline index 0), then `oneway_toward = "to"`. If it is reversed (`oneway = "yes"` but the way runs ptTo → ptFrom), then `oneway_toward = "from"`.
   - `oneway = "reverse"` flips the above.
   - Alignment check: compute the dot product of the segment line direction vector (from ptFrom to ptTo) versus the OSM way direction vector (from way.polyline[0] to way.polyline.last). If dot > 0: same direction, `oneway = "yes"` → `oneway_toward = "to"`. If dot < 0: reversed, `oneway = "yes"` → `oneway_toward = "from"`.

**Note on `osm_oneway.json` coverage gaps:** Not every Manhattan street in the tile set has an entry in `osm_oneway.json`. Streets with no OSM entry should be treated as two-way (show the picker). The iOS app is defensive: if `oneway` is absent or false, always show the picker.

### 4.3 Files Modified by @backend-data

- `build/preprocess.js`: the `allSegments.push(...)` call at line 826 and line 795 — add `oneway` and `oneway_toward` fields.
- Both tile output paths must be updated: `tiles/` (PWA) and `ios/WePark/WePark/Resources/tiles/` (iOS). `preprocess.js` already syncs both via the §7b block — the sync is automatic.
- `tiles/index.json` does not need changing.

### 4.4 Work Stream: @backend-data

This is a self-contained, parallel work stream. It does NOT touch any Swift files. Output: regenerated tile files in both output paths. Validation: spot-check 3–5 known one-way Manhattan streets (e.g., Spring St westbound, Thompson St southbound, Bleecker St eastbound in the Village) in the output tiles and confirm `oneway: true` + `oneway_toward` correct.

**@ios-engineer can start the two-arrow picker UI and marker rendering without waiting for the tile change**, since the sweeper auto-derive path is gated by `segment.oneway == true` — if the field is absent, the code falls back to showing the picker. The tile change is needed only to activate auto-derive in production.

---

## 5. Architecture

### 5.1 Data Flow

```
[Tile JSON] → Segment.oneway / Segment.onewayToward (new fields, decoded optional)
                                    |
                                    v
[ReportSheet] receives Segment? at init time
    ├── segment nil           → hide picker, omit heading_toward from meta
    ├── enforcementActive     → always show two-arrow picker (if segment non-nil)
    └── sweeper
          ├── segment.oneway == true  → auto-derive heading_toward from oneway_toward
          └── segment.oneway != true  → show two-arrow picker

[buildMeta extended] → meta dict includes "heading_toward": "from" | "to" (or absent)
                                    |
                                    v
[insertCrowdPin]  meta: ["sub_tag": ..., "heading_toward": "from"]
                  segmentId: segment.id  (NOW WIRED — was nil before)
                                    |
                                    v
[Supabase pins table]  meta JSONB = {"sub_tag": "parking_agent", "heading_toward": "from"}
                                    |
                                    v
[CommunityPin decode]  EnforcementActiveMeta.headingToward = .from
                                    |
                                    v
[CommunityPinAnnotation init]  bearing = SegmentBearing.bearing(segment, toward: .from)
                                    |
                                    v
[PinMarkerAnnotation.configure(for:bearing:)]  renders chevron rotated to bearing
```

### 5.2 Files Touched by @ios-engineer

| File | Change |
|---|---|
| `ios/WePark/WePark/Models/Segment.swift` | Add `oneway: Bool?`, `onewayToward: String?` fields + CodingKeys |
| `ios/WePark/WePark/Models/CommunityPin.swift` | Add `HeadingToward` enum; add `headingToward: HeadingToward?` to `EnforcementActiveMeta` and `SweeperPassedMeta`; update `CodingKeys` + `decode` |
| `ios/WePark/WePark/Services/SegmentBearing.swift` (NEW) | Free function `bearing(segment:toward:) -> Double` extracting the atan2 formula; internal visibility |
| `ios/WePark/WePark/Views/ReportSheet.swift` | New `segment: Segment?` init parameter; `HeadingTowardPicker` view; extend `buildMeta`; wire `segmentId` through `insertCrowdPin` |
| `ios/WePark/WePark/Views/PinMarkerAnnotation.swift` | `configure(for:bearing:)` adds directional chevron when bearing non-nil; `CommunityPinAnnotation` gains `bearing: Double?` stored property |
| `ios/WePark/WePark/Views/ContentView.swift` | Pass resolved `Segment?` when presenting `ActiveSheet.reportPin`; compute and pass bearing when building `CommunityPinAnnotation` in overlay rebuild |
| `ios/WePark/WeParkTests/FT11DirectionTests.swift` (NEW) | Unit tests (see §6) |

### 5.3 Files NOT Touched by @ios-engineer

- `MapViewRepresentable.swift` — the overlay rebuild loop adds community pin annotations; the only change needed is passing a `bearing` argument to `CommunityPinAnnotation.init`, which is a one-line addition in the annotation-building loop. If this loop is in `ContentView.swift`, the file is ContentView. If it's in MapViewRepresentable's coordinator, add it there. No architectural change to MapViewRepresentable.
- `CommunityPinService.swift` — `insertCrowdPin` signature is unchanged. Meta dict and segmentId are already accepted; callers just need to populate them.
- `TileLoader.swift` — no change; new Segment fields decode automatically via `decodeIfPresent`.
- `ParkingRulesEngine.swift`, `LocationService.swift`, `NotificationScheduler.swift` — none touched.

---

## 6. Work Streams

**Stream A — @backend-data (tile pipeline):** Parallel, independent. No Swift.
- Modify `build/preprocess.js` to embed `oneway` + `oneway_toward` per segment.
- Regenerate both tile paths.
- Validation: manual spot-check of 5 known one-way blocks.
- Estimated: 1 session.

**Stream B1 — @ios-engineer (model layer):** Depends on nothing. Can start immediately.
- Add `oneway`, `onewayToward` to `Segment.swift`.
- Add `HeadingToward` enum and `headingToward` field to `EnforcementActiveMeta`, `SweeperPassedMeta` in `CommunityPin.swift`.
- Create `Services/SegmentBearing.swift` with the bearing utility.
- Unit tests for bearing computation + backward-compat decoding.

**Stream B2 — @ios-engineer (ReportSheet UI):** Depends on B1 (needs `HeadingToward` enum and `Segment.onewayToward`). Parallel with B3.
- Add `segment: Segment?` parameter to `ReportSheet`.
- Build `HeadingTowardPicker` sub-view: two `Button`s shaped as pill/capsule, each labeled with the cross-street name (`segment.fromStreet` / `segment.to`), each overlaid with an `Image(systemName: "arrow.forward")` rotated by the segment bearing toward that endpoint. Tapping one sets `@State var selectedHeadingToward: HeadingToward?`.
- Show/hide logic: shown for `enforcementActive` when `segment != nil`; shown for `sweeper` when `segment != nil && segment.oneway != true`; hidden otherwise.
- Auto-derive for one-way sweeper: if `segment.oneway == true`, set `selectedHeadingToward` from `segment.onewayToward` without showing the picker.
- Extend `buildMeta(type:subTag:sweeperDirection:headingToward:)` with the new parameter.
- Wire `segmentId: segment?.id` in the `insertCrowdPin` call.

**Stream B3 — @ios-engineer (marker rendering):** Depends on B1 (needs `HeadingToward` on meta structs). Parallel with B2.
- Add `bearing: Double?` to `CommunityPinAnnotation`.
- Extend `configure(for:bearing:)` on `PinMarkerAnnotation`: when `bearing` is non-nil, render a directional chevron overlaid on the circle using `UIGraphicsImageRenderer`. The chevron is a small `UIImage(systemName: "chevron.forward")` (or similar) drawn into the same renderer context, rotated to the bearing using `CGContext.rotate(by:)`. When `bearing` is nil (legacy pin, off-segment pin): render current marker unchanged — full backward-compatibility.
- In the annotation-building loop (ContentView or MapViewRepresentable coordinator): look up the `Segment` for the pin's `segmentId`; if found and pin has `headingToward`, compute the bearing and pass it to `CommunityPinAnnotation.init`.

**Stream B4 — @ios-engineer (ReportSheet presenter):** Depends on B2. Short.
- In `ContentView`, when presenting `ActiveSheet.reportPin(coord:)` from a long-press: the long-press handler already resolves the segment via haversine search (W5 pattern). Pass the resolved `Segment?` through to the `ReportSheet` init.
- In Drive Mode "Report" button path: `drivingContext?.street` is resolved; use `DrivingContextService`'s nearest segment to pass `Segment?`.

All B-streams are @ios-engineer-owned. B1 → B2, B3 in parallel → B4. Stream A (@backend-data) is fully independent and can merge separately.

---

## 7. Acceptance Criteria

Numbered, testable. @qa-verifier verifies each.

**Model / encoding:**

1. `Segment.oneway: Bool?` decodes as `true` from a tile JSON segment with `"oneway": true`.
2. `Segment.onewayToward: String?` decodes as `"from"` from a tile JSON segment with `"oneway_toward": "from"`.
3. `Segment.oneway` and `Segment.onewayToward` both decode as `nil` when absent — backward-compatible with all existing tiles.
4. `HeadingToward` enum has exactly two cases: `case from` (raw `"from"`) and one case for the `"to"` endpoint (raw value `"to"`).
5. `EnforcementActiveMeta.headingToward` decodes as `.from` from `{"sub_tag": "parking_agent", "heading_toward": "from"}`.
6. `SweeperPassedMeta.headingToward` decodes as `.from` and the `direction` field still decodes correctly (no regression).
7. Round-trip encode → decode of `EnforcementActiveMeta` with `headingToward = .from` preserves the value.
8. A `CommunityPin` decoded without `heading_toward` in meta decodes without error; `headingToward` is `nil`.

**Bearing utility:**

9. `SegmentBearing.bearing(segment:toward:.to)` returns the bearing from `segment.line[0]` toward `segment.line.last` using the atan2 formula (verified against a hand-computed bearing for a test segment with known lat/lng endpoints).
10. `SegmentBearing.bearing(segment:toward:.from)` returns the reverse bearing (180° ± floating-point tolerance from the `.to` result on the same straight segment; tolerance ±0.5°).
11. A segment with fewer than 2 coordinates returns a defined fallback (0.0 or nil) without crashing.

**One-way auto-derive:**

12. In ReportSheet, when `selectedType == .sweeper` and `segment.oneway == true` and `segment.onewayToward == "from"`: `selectedHeadingToward` is set to `.from` and the picker is NOT shown.
13. In ReportSheet, when `selectedType == .sweeper` and `segment.oneway == true` and `segment.onewayToward == "to"`: `selectedHeadingToward` is set to `.to` and the picker is NOT shown.
14. In ReportSheet, when `selectedType == .sweeper` and `segment.oneway == false` (or nil): the two-arrow picker IS shown.

**Picker UI — enforcement:**

15. In ReportSheet, when `selectedType == .enforcementActive` and `segment` is non-nil: the two-arrow picker is shown with labels equal to `segment.fromStreet` and `segment.to`.
16. In ReportSheet, when `selectedType == .enforcementActive` and `segment` is nil: no picker is shown.
17. Tapping the `fromStreet` arrow sets `selectedHeadingToward = .from`; tapping the `to` arrow sets it to `.to`. Both arrows have accessibility labels matching their cross-street name.

**Meta wire-through:**

18. `ReportSheet.buildMeta(type:.enforcementActive, subTag:.parkingAgent, sweeperDirection:.passed, headingToward:.from)` returns a meta dict containing `"heading_toward": "from"` and `"sub_tag": "parking_agent"`.
19. `ReportSheet.buildMeta(type:.sweeper, ..., headingToward:.to)` returns `"heading_toward": "to"` and `"direction": "passed"` (existing key preserved).
20. `ReportSheet.buildMeta(..., headingToward: nil)` does NOT include a `"heading_toward"` key in the dict.
21. When `segment` is non-nil and a direction is chosen, `insertCrowdPin` is called with `segmentId: segment.id` (not nil).

**Marker rendering:**

22. `PinMarkerAnnotation.configure(for:bearing:nil)` renders a marker image identical to the current marker (no chevron overlay) — backward-compat regression test.
23. `PinMarkerAnnotation.configure(for:bearing:45.0)` renders a marker image that is visually distinct from the no-bearing case (chevron is present).
24. The chevron overlay is visible and readable at 32×32pt and does not obscure the SF Symbol.

**Tile pipeline (@backend-data):**

25. After pipeline regeneration, a manually identified one-way block (e.g., Spring St westbound between Wooster and Greene) has `"oneway": true` and `"oneway_toward"` set to the correct endpoint in the tile JSON.
26. After regeneration, a manually identified two-way block has `"oneway": false` or the fields absent.
27. Both `tiles/tile_*.json` (PWA path) and `ios/WePark/WePark/Resources/tiles/tile_*.json` (iOS path) contain the new fields — confirmed by grepping one known one-way segment in both directories.

**Live-UI smoke gate:**

28. Report an enforcement-active pin with a segment resolved (long-press on a named block) → direction picker shows two arrows with correct cross-street labels → tap one → Report → pin appears on map with a directional chevron pointing the chosen way. Confirm by inspecting the meta in Supabase `pins` table: `meta.heading_toward` matches the tapped direction.
29. Report a sweeper-passed pin on a known one-way block → no direction picker appears → Report → pin appears on map with the auto-derived directional chevron. Confirm `meta.heading_toward` is set and matches the one-way direction.
30. Report any pin type via long-press off any segment (no segment resolved) → no direction picker appears → Report succeeds without `heading_toward` in meta.
31. Tap an existing legacy pin (no `heading_toward` in meta) → marker renders without a directional chevron; no crash.

---

## 8. Unit Tests

**`FT11DirectionTests.swift` (new file) — minimum inventory:**

| Test | What it proves | AC |
|---|---|---|
| `testSegmentDecoding_oneway_true` | `Segment.oneway` decodes from tile JSON | AC-1 |
| `testSegmentDecoding_onewayToward_from` | `Segment.onewayToward` decodes | AC-2 |
| `testSegmentDecoding_legacyTile_noOnewayFields` | Nil-safe backward-compat | AC-3 |
| `testHeadingToward_rawValues` | `"from"` / `"to"` raw values correct | AC-4 |
| `testEnforcementMetaDecode_withHeadingToward` | Meta decode round-trip | AC-5, AC-7 |
| `testSweeperMetaDecode_withHeadingToward` | No regression on `direction` field | AC-6 |
| `testMetaDecode_missingHeadingToward_isNil` | Backward-compat decode | AC-8 |
| `testBearing_toward_to` | atan2 result matches hand-computed value | AC-9 |
| `testBearing_toward_from_isReverse` | Reverse bearing ±0.5° | AC-10 |
| `testBearing_degenerateSegment_nocrash` | < 2 coords does not crash | AC-11 |
| `testAutoDerive_oneway_from_hidesPickerSetFromDir` | Sweeper + one-way from → auto-set | AC-12 |
| `testAutoDerive_oneway_to_hidesPickerSetToDir` | Sweeper + one-way to → auto-set | AC-13 |
| `testAutoDerive_twoWay_showsPicker` | Two-way sweeper → picker shown | AC-14 |
| `testBuildMeta_enforcement_withHeadingToward` | meta dict has heading_toward key | AC-18 |
| `testBuildMeta_sweeper_withHeadingToward` | meta dict has both direction + heading_toward | AC-19 |
| `testBuildMeta_headingToward_nil_noKey` | nil heading_toward omitted from dict | AC-20 |

Baseline test count before FT-11: 377 (confirmed in HANDOFF.md, 2026-06-06 entry). FT-11 adds a minimum of 16 new tests.

---

## 9. Open Decisions (see top of doc)

OD-1, OD-2, OD-3 above. All three are low-stakes decisions with clear recommended answers; they primarily confirm the spec's defaults before @ios-engineer starts.

---

## 10. Out-of-Scope Follow-Ups

- **Direction label in `PinDetailSheet`:** "Heading toward MacDougal St" text in the tap-to-view detail sheet. Useful but not MVP for this feature — the map arrow is sufficient for situational awareness. Defer to FT-11 polish.
- **PWA direction display:** The PWA is in maintenance mode. Enforcement/sweeper pins will continue to render without a direction arrow on the PWA. The `heading_toward` key in meta is harmless — the PWA ignores it.
- **Confidence decay on directionless legacy pins:** If a pin is old enough that the sweeper has obviously passed the block regardless of direction, the pin's time-since badge already communicates age. No special handling needed.
- **Direction on `brokenMeter` or `blockNote` pin types:** Not meaningful for these types. Out of scope.
- **Accessibility: VoiceOver announcement of direction arrow.** The `configure(for:bearing:)` method sets `accessibilityLabel`. Adding "heading toward [cross-street]" to that label is a small polish item deferred to FT-11 polish.
