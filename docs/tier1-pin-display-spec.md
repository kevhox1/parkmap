# Tier 1 Pin Display — iOS Spec

**Status:** Ready for @ios-engineer. Date: 2026-06-02.
**Owner:** @ios-engineer (implementation). @tech-lead (this spec). @qa-verifier (acceptance).
**Scope:** TF1 only. Tier 1 pins (open_data, session/durable lifespan). Read-only. No user reporting, no reactions, no decay visuals.
**Depends on:**
- `docs/typed-pin-schema-spec.md` §10 — `CommunityPin` model (MERGED, PR #36, 280/0 tests).
- `docs/tier1-open-data-ingest-spec.md` — defines exactly which pins exist: `filming` and `asp_suspended_today`. `special_event` is conditionally in scope (see OQ-2 below).
- `supabase/02-pins-schema.sql` — QA-clean, NOT yet applied to production. iOS can build + unit-test against fixture pins before prod apply; end-to-end verification requires the schema live.
**Anchor docs:** `docs/community-1.0-buildplan.md` §3 (Tier 1 build order) and §6 (parallel work streams). `docs/community-1.0-direction.md` §6.2 (display surfaces).
**Supersedes:** nothing (first display spec for community pins).

---

## Open Questions for Kevin — Resolve Before Engineer Starts

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-1 | **asp_today integration path: data source or side-by-side?** | **(a) Replace** `ASPSuspensionService`'s bundle-JSON data source with Supabase `asp_suspended_today` pins as the authoritative signal — `ASPBanner` reads from `CommunityPinService` instead of the bundled `asp-2026.json`. **(b) Supplement** — keep `asp-2026.json` as primary; if a Supabase `asp_suspended_today` pin exists for today, treat it as a confirmation but defer to the bundle. **(c) Side-by-side / defer** — `ASPBanner` continues reading `asp-2026.json`; the `asp_suspended_today` pin is silently fetched but drives no UI change in TF1. Full reconciliation is TF2. | **(b) Supplement for TF1.** The bundle-backed `ASPSuspensionService` is robust, offline-capable, and already QA'd through W7. Replacing it (option a) risks a regression in the banner — a surface Kevin smokes every session. Option b adds Supabase as a secondary signal: if a pin is found for today and the bundle says "not suspended," the pin wins (handles the snow-emergency case where the bundle can't self-update). If the pin is absent but the bundle says "suspended," the bundle wins (handles the case where ingest hasn't run yet). This keeps `ASPBanner` data-source-stable and adds live-update capability without rewriting the service. Full data-source migration (option a) deferred to TF2 once the ingest pipeline is battle-tested. See §4 for the integration design. |
| OQ-2 | **`special_event` in TF1 or deferred?** | **(a) Include** — the schema supports it; if @backend-data seeds at least one `special_event` pin before TF1, the display layer should render it. The display code is identical to `filming` (map marker, tap → detail, same lifespan). **(b) Defer** — `special_event` seeding from NYC 311 requires an API key and is flagged TF2 in `tier1-open-data-ingest-spec.md` §7. No seed = no display needed. | **(a) Include the display code, but treat it as zero-cost.** Because `special_event` and `filming` share the same display path (map marker, tap → detail, identical session lifespan, no decay), the engineer implements one code path for both and dispatches on `pin_type` only for the icon. If no `special_event` seeds exist at TF1 launch, zero markers appear — no risk. The code is written; it lights up when data arrives. Costs ≈ one extra `switch` case. |
| OQ-3 | **Fetch trigger granularity: on every region-change or debounced?** | **(a) Debounced region-change** — fire the Supabase fetch 800ms after the last `onRegionChanged` callback (same debounce idiom the tile loader uses). Matches existing panning UX; fetches a new bounding box when the user pans to a new area. **(b) Zone-scoped only** — fetch all pins for the current `zone_id` once on launch; no panning re-fetch. Cheaper on Supabase, but citywide `filming` pins have no `zone_id` and would never load. **(c) Fixed radius + refresh on significant move** — fetch pins within ~2km of map center; refresh only when the center moves more than 500m. | **(a) Debounced region-change, 800ms.** Consistent with the tile loader pattern. Bounding-box filter (not zone filter) is required because `filming` pins may have null `zone_id` (see ingest spec §3.4). 800ms debounce absorbs pan inertia. Realtime subscription supplements the poll — it catches ingest-job upserts without needing a re-fetch. |
| OQ-4 | **Marker clustering at low zoom?** | **(a) No clustering** — individual `MKAnnotation` per pin; at wide zoom many pins may overlap. Acceptable for TF1 with low pin density. **(b) `MKClusterAnnotation`** — standard MapKit clustering; group overlapping pins at low zoom. More code, but prevents visual clutter if many film permits exist on the same day. | **(a) No clustering for TF1.** At Tier 1 scale (typically <20 active film permits on any given day citywide, 0–1 ASP pins) clustering adds complexity without user benefit. Deferred to TF2 if density warrants. |

---

## 1. Problem and User Story

**Problem:** The iOS app (W1–W8.5d) delivers a complete solo-user experience — parking rules, Drive Mode, parked-car reminders. But the static rules don't tell a user "there's a film shoot on this block today, don't bother." That delta is available right now from NYC open data. Tier 1 pins are the bridge between the static map and reality-as-it-is-today.

**User story (filming pin):**
> A driver approaches a block on a Tuesday morning. The map shows the block as free (green overlay). But there's a film shoot. Normally she'd waste 5 minutes looking for a spot that doesn't exist. Instead, a camera icon on the map — visible before she turns onto the block — says "Filming — no parking." She reroutes before she even gets there.

**User story (ASP suspended today):**
> It's Memorial Day. The user opens the app and the top banner is red: "ASP Suspended — Memorial Day." She doesn't need to Google it, call 311, or remember. She already knows from the banner she's had since W7 — except now the banner's signal can come from a live Supabase pin, not just a hardcoded file.

**Why now:** The `CommunityPin` model is merged (PR #36). The schema spec is QA-clean and pending prod apply. The ingest spec is written. The display spec is the last piece before @backend-data and @ios-engineer can begin simultaneous work.

---

## 2. Scope

### In Scope (TF1)

- **Fetch path:** PostgREST bounding-box query for `filming`, `asp_suspended_today`, and `special_event` pins, filtered to `source = 'open_data'` and not-expired.
- **Realtime subscription:** live pin updates via Supabase Realtime on the `pins` table (supplement to the poll).
- **`filming` and `special_event` → map markers:** `MKAnnotation`-backed markers with per-type icons; tap → pin detail sheet. No decay visual (session lifespan, no partial fade).
- **`asp_suspended_today` → ASPBanner integration:** Supabase pin supplements (does not replace) the existing W7 `ASPBanner` + `ASPSuspensionService`. See §4.
- **Read-only display only.** No user reporting, no votes, no reactions from the map. The `votes` table and `confirm_count`/`dispute_count` columns exist in the schema but are not surfaced in TF1 UI.
- **Fixture-only build gate:** @ios-engineer builds and unit-tests against fixture `CommunityPin` JSON (no DB dependency). End-to-end map verification requires prod schema apply.
- **Live-UI smoke gate (mandatory):** any PR touching the map overlay layer or `ContentView` must capture a sim screenshot and `Read` it before merge. See AC-D10.

### Out of Scope (Explicitly TF2/TF3/Never)

- **User reporting UI** — Tier 2. No "Report a problem" or pin-creation flow.
- **Reactions / votes / "Still there?"** — Tier 2/3. `votes` table and `confirm_count`/`dispute_count` are in the schema; TF1 display shows confirm_count as a badge only if Kevin decides (currently deferred).
- **Decay visuals / opacity fading** — Tier 3. Session-lifespan pins do not decay; ephemeral pins (`enforcement_active`, `sweeper_passed`) are not in TF1 scope.
- **Ephemeral pin types** (`enforcement_active`, `sweeper_passed`, `broken_meter`, `open_spot`) — Tier 3.
- **Crowd-sourced pin types** (`sign_correction`, `block_note`) — Tier 2.
- **`construction` pins** — TF2 (per OQ-4 in buildplan; DOT data quality TBD).
- **Drive Mode route callout for community pins** ("Filming 2 blocks ahead" voice/chip) — separate spec, post-TF1.
- **Push notification for pins near parked car** — separate spec, post-TF1.
- **Marker clustering** — TF2 if density warrants (OQ-4 above).
- **Confirm-count badge** — deferred pending Kevin's product decision; not in base TF1 scope.
- **`parked_car` pins** — W5 local-only; not community-visible. Not touched.
- **PWA changes** — PWA is in maintenance mode. The PWA has its own PostgREST contract at `typed-pin-schema-spec.md §11`; this spec is iOS-only.

---

## 3. Architecture

### 3.1 Codebases Touched

| Codebase | Touch? | Notes |
|---|---|---|
| `ios/WePark/WePark/` | Yes | New files + ContentView extension |
| `ios/WePark/WeParkTests/` | Yes | Fixture-based unit tests |
| `supabase/` | Read-only | No new migrations; reads `pins_with_author` view |
| `index.html` (PWA) | No | PWA maintenance mode; no changes |
| `docs/` | This spec | Only this file is added |

### 3.2 New Files

```
ios/WePark/WePark/Services/CommunityPinService.swift   — fetch + Realtime subscription
ios/WePark/WePark/Views/PinMarkerAnnotation.swift       — MKAnnotationView subclass for film/event markers
ios/WePark/WePark/Views/PinDetailSheet.swift            — tap-to-detail sheet for map markers
ios/WePark/WeParkTests/CommunityPinServiceTests.swift   — fixture-driven unit tests
```

### 3.3 Modified Files

```
ios/WePark/WePark/ContentView.swift    — wire CommunityPinService, add pin overlay layer, extend ActiveSheet
ios/WePark/WePark/Services/ASPSuspensionService.swift  — add Supabase-pin supplement (§4)
```

`MapViewRepresentable.swift` is touched **only** to add `MKAnnotation` items for filming/special_event pins. The overlay payload type does NOT change structure. No `setRegion` calls are added. No mutation inside `updateUIView`. See §5 (invariants).

### 3.4 Data Flow

```
[Supabase: pins_with_author view]
        |
        | PostgREST GET (bounding box, source=open_data, not-expired)
        | + Realtime SUBSCRIBE (pins table, INSERT/UPDATE events)
        v
[CommunityPinService.swift]
  - @Observable, owns [CommunityPin] array
  - Debounced fetch on bounding-box change (800ms)
  - Realtime subscription supplements fetch
  - Client-side expiry filter: pin.expiresAt == nil || pin.expiresAt > Date()
        |
        | filming / special_event pins
        v                                       asp_suspended_today pin
[ContentView.swift]                                     |
  - .onChange(of: pinService.visiblePins)               v
  - pushes MKAnnotation array to          [ASPSuspensionService supplement]
    MapViewRepresentable via               - if pin found for today AND
    new annotationPayload binding            bundle says "not suspended":
        |                                    override to .todaySuspended
        v                                  - if pin absent: bundle primary
[MapViewRepresentable.swift]
  - mapView(_:viewFor:) returns PinMarkerAnnotation
  - Tap: mapView(_:didSelect:) → activeSheet = .pinDetail(pin)
        |
        v
[PinDetailSheet.swift]
  - Shown via ActiveSheet.pinDetail(CommunityPin)
  - Displays: type icon + label, address/block, permit details (meta),
    expires_at countdown, confirm_count (hidden in TF1, scaffolded)
```

### 3.5 Supabase Client

`CommunityPinService` uses the Supabase Swift SDK (anonymous key, no auth required for `filming`/`asp_suspended_today`/`special_event` reads per RLS policy `pins_select_public`). The anon key is stored in `Config.xcconfig` under a new key `SUPABASE_ANON_KEY` (same gitignore pattern as `MAPBOX_ACCESS_TOKEN`; `Config.xcconfig.example` documents the key name). The Supabase project URL is stored as `SUPABASE_URL`. Both bridge to `Info.plist` and are read via `Bundle.main` at runtime — never hardcoded.

**Note:** If the Supabase Swift SDK is not yet a package dependency, @ios-engineer adds it via Swift Package Manager (`https://github.com/supabase-community/supabase-swift`, minimum version 2.x). This is a one-time Xcode setup — no `project.pbxproj` changes committed to the spec; engineer documents the SPM addition in the PR description.

---

## 4. ASP Today → W7 ASPBanner Integration

This is the highest-leverage integration decision in this spec. Here is the full design for OQ-1 option (b), the recommended path.

### 4.1 Current data flow (W7, as shipped)

```
asp-2026.json (bundle) → ASPSuspensionService.init() → suspensionsByDate dict
                                                              ↓
ContentView.bannerState = aspService.suspensionState(at: .nowET)
                                                              ↓
ASPBanner(state: bannerState)  ← .safeAreaInset(edge: .top)
```

`ASPSuspensionService` is a `final class`, not `@Observable`. It is read synchronously. The `bannerState` is a `@State var` on `ContentView`, refreshed on `.onAppear` and `scenePhase → .active`.

### 4.2 Integration design (supplement path)

`CommunityPinService` is `@Observable`. When its `visiblePins` array updates, `ContentView` re-evaluates the banner state by calling a new helper:

```swift
// Sketch — @ios-engineer implements
func resolvedBannerState(
    bundleState: SuspensionBannerState,
    aspPins: [CommunityPin]
) -> SuspensionBannerState {
    // The bundle is authoritative unless a live Supabase pin overrides it.
    // A pin overrides only in the "today-suspended" direction:
    // - Pin says suspended + bundle says not suspended → trust the pin (snow emergency / late addition)
    // - Pin says suspended + bundle also says suspended → bundle wins (same info, no change)
    // - Pin absent → bundle state as-is (no regression from W7 behavior)
    let todayStr = Date.nowET.toETDateString()
    let liveSuspension = aspPins.first(where: {
        $0.pinType == .aspSuspendedToday &&
        ($0.meta?.aspSuspendedTodayMeta?.suspensionDate == todayStr) == true &&
        ($0.expiresAt == nil || $0.expiresAt! > Date())
    })
    if let pin = liveSuspension, case .aspInEffect = bundleState {
        let reason = pin.meta?.aspSuspendedTodayMeta?.reason ?? "NYC Emergency Suspension"
        return .todaySuspended(reason: reason)
    }
    return bundleState
}
```

The `ContentView.bannerState` `@State` var is replaced with a computed property (or refreshed via `.onChange(of: pinService.visiblePins)`) that calls `resolvedBannerState(bundleState:aspPins:)`. `ASPSuspensionService` itself is NOT modified — it continues to be the primary source.

### 4.3 What this does NOT do

- Does NOT remove `asp-2026.json` from the bundle. The bundle calendar is the offline fallback.
- Does NOT make `ASPBanner` require a network connection.
- Does NOT change `ASPSuspensionService`'s public API.
- Does NOT add a `tomorrowSuspended` Supabase override (only `todaySuspended` — the pin schema has a single-day `suspension_date` field; "tomorrow" requires the bundle to have that date or a separate pin seeded for tomorrow, which is handled naturally by the ingest job seeding future dates).
- Does NOT render `asp_suspended_today` as a map marker. It is a zone/citywide state. Per `community-1.0-direction.md §6.2`: "Top banner — reserved for zone-wide deltas only (ASP-today, snow emergency)." The lat/lng on the ASP pin row (city centroid, per ingest spec §4.3) is intentionally ignored.

### 4.4 Reconciliation with `ASP_SUSPENSIONS_2026` in `index.html`

Per `tier1-open-data-ingest-spec.md §2`:
- The hardcoded `ASP_SUSPENSIONS_2026` in `index.html` is NOT touched by this spec. PWA maintenance mode.
- The Supabase `asp_suspended_today` pins and the iOS bundle `asp-2026.json` should contain identical dates (both sourced from the NYC DOT PDF). If they diverge, the priority rule in §4.2 above applies for iOS. The PWA has no live-Supabase path for ASP state and is unaffected.
- The 2027 calendar update (December 2026) requires updating BOTH `index.html`'s `ASP_SUSPENSIONS_2026` constant AND the ingest seed script, per ingest spec §4.5.

---

## 5. Map Marker Rendering — Architectural Invariants

This section is the critical risk zone. The W8.5c-polish revert (PR #31, 2026-05-26) was caused by overlay-layer mutations that broke the `.safeAreaInset` chain. The Changelog 2026-05-26 entry and the PR-3 + PR-2 re-landing established the rules. This spec's implementation MUST follow them without deviation.

### 5.1 The invariants (source: HANDOFF.md Changelog 2026-05-26 through 2026-05-30)

**I-1: Camera/overlay mutations go in `.onChange`, never inside `updateUIView`.**
`MapViewRepresentable.updateUIView` is called by SwiftUI during view updates. Mutating UIKit state here races SwiftUI's mount cycle. The PR #31 regression dropped the entire toolbar + ASP banner + Park Until pill — all overlay elements above `MapViewRepresentable`. `updateUIView` must remain a pure "push current state to UIView" function; all behavioral changes live in `.onChange` modifiers on the SwiftUI side.

**I-2: No `setRegion` call on any Drive Mode active path.**
`setRegion` resets the camera to top-down (pitch 0, heading 0), clobbering tilt. PR-3 (`adebdc2`) fixed the latent W8.5c bug where `if driveHeading == nil { mapView.setRegion(...) }` fired during Drive Mode (the sim always has nil heading). The `shouldSyncRegionToBinding(driveModeActive:)` pure function gates the region-sync. This spec adds no new `setRegion` calls anywhere.

**I-3: No `headlessWindow` guard in production code.**
The reverted PR #31 introduced a `headlessWindow` production guard to satisfy tests that instantiate bare `MKMapView()`. The pattern is banned per `.claude/agents/ios-engineer.md` norm (added 2026-05-26). Tests that need `MKMapView` use proper window fixtures.

**I-4: `RegionSyncGuardTests` must pass before merge.**
Two tests (`RegionSyncGuardTests`) verify the `shouldSyncRegionToBinding` pure function. They pass through W8.5d (243/0) without touching `MapViewRepresentable.swift`. Any change to that file requires re-verifying both tests. This spec's changes to `MapViewRepresentable` are narrow: adding `MKAnnotation` items via the `annotationPayload` binding only.

### 5.2 How map markers mount safely

`MapViewRepresentable` already accepts an `overlayPayload` binding (the `MKMultiPolyline` groups). This spec adds a parallel `annotationPayload` binding of type `[CommunityPin]` (or a wrapper struct):

```swift
// Sketch — @ios-engineer implements
// In MapViewRepresentable (new binding, added via existing CoordinatorActions pattern):
var communityPins: [CommunityPin]   // bound from ContentView

// In Coordinator.mapView(_:viewFor:):
if let pinAnnotation = annotation as? CommunityPinAnnotation {
    let view = mapView.dequeueReusableAnnotationView(
        withIdentifier: PinMarkerAnnotation.reuseIdentifier,
        for: pinAnnotation
    ) as? PinMarkerAnnotation ?? PinMarkerAnnotation(annotation: pinAnnotation)
    view.configure(for: pinAnnotation.pin)
    return view
}
```

`ContentView` pushes updates via `.onChange(of: pinService.visiblePins)` — NOT inside `updateUIView`:

```swift
// Sketch — ContentView (.onChange, OUTSIDE updateUIView)
.onChange(of: pinService.visiblePins) { _, newPins in
    // Filter to map-marker types only (filming + special_event)
    // asp_suspended_today is handled via ASPBanner, not a map marker
    communityPins = newPins.filter { [.filming, .specialEvent].contains($0.pinType) }
}
```

The `communityPins` state var is passed to `MapViewRepresentable` as a binding. `updateUIView` reads it and calls `mapView.addAnnotations` / `mapView.removeAnnotations` as a diff — but the DECISION to push the new array is made outside `updateUIView` in the `.onChange` handler, not inside it.

**The architectural contract: `.onChange` owns the timing; `updateUIView` owns the mechanical sync.**

### 5.3 No `userTrackingMode` changes

The directional puck is already implemented (PR-2). This spec does NOT touch `userTrackingMode` or `mapView.setUserTrackingMode`. Adding `MKAnnotation` items does not conflict with the puck mechanism.

---

## 6. Fetch Path — PostgREST Query Specification

`CommunityPinService` issues this GET against the `pins_with_author` view (from `typed-pin-schema-spec.md §11`):

```
GET /rest/v1/pins_with_author
  ?pin_type=in.(filming,asp_suspended_today,special_event)
  &source=eq.open_data
  &resolved_at=is.null
  &or=(expires_at.is.null,expires_at.gt.<ISO-8601-now>)
  &lat=gte.<sw_lat>&lat=lte.<ne_lat>
  &lng=gte.<sw_lng>&lng=lte.<ne_lng>
  &select=id,pin_type,source,lifespan,lat,lng,segment_id,zone_id,expires_at,confirm_count,dispute_count,meta,notes,author_username
  &apikey=<anon-key>
```

Replace `<ISO-8601-now>` with `ISO8601DateFormatter().string(from: Date())` at call time (client-side expiry filter per schema spec §8 — PostgREST does not support `now()` in filter parameters cleanly).

Replace `<sw_lat>`, `<ne_lat>`, `<sw_lng>`, `<ne_lng>` with the current `MKCoordinateRegion`'s bounding box, computed from `region.center` and `region.span`.

### 6.1 Fetch trigger

The `onRegionChanged` callback in `ContentView` (line 377 of `ContentView.swift` per grep output) already fires when the user pans. `CommunityPinService` receives the new `MKCoordinateRegion` and debounces:

```swift
// Sketch — CommunityPinService
private var fetchTask: Task<Void, Never>?

func onRegionChanged(_ region: MKCoordinateRegion) {
    fetchTask?.cancel()
    fetchTask = Task {
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        await fetchPins(for: region)
    }
}
```

The 800ms debounce is consistent with how panning feels on `TileLoader` (the tile-loader fetch cadence is tied to the same `onRegionChanged` callback).

### 6.2 Realtime subscription

Subscribe to the `pins` table for INSERT and UPDATE events on `source = 'open_data'`. The subscription supplements the poll — it handles the case where the ingest job upserts a new film permit while the user has the app open:

```swift
// Sketch — CommunityPinService (in startRealtime())
supabase.realtimeV2.channel("public:pins:open_data")
    .on(.postgresChanges, filter: .init(
        event: .all,
        schema: "public",
        table: "pins",
        filter: "source=eq.open_data"
    )) { [weak self] payload in
        // Merge the new/updated pin into visiblePins; apply client-side expiry filter.
        self?.mergeRealtimeChange(payload)
    }
    .subscribe()
```

On a Realtime INSERT or UPDATE event for a pin within the current bounding box, merge the decoded `CommunityPin` into `visiblePins`. On an UPDATE that sets `resolved_at` to non-null, remove the pin from `visiblePins`.

Realtime reconnect: test that `visiblePins` count does not decrease after a WebSocket drop + reconnect (AC-D5).

### 6.3 When NOT to fetch

- While `driveModeActive == true` and the map is in heading-up follow mode: region changes from location updates (not user pans) fire `onRegionChanged` continuously. The debounce absorbs this, but `CommunityPinService.onRegionChanged` should additionally guard: if `driveModeActive` AND the region delta is small (center moved < 200m from the last fetch center), skip the refetch. This avoids hammering Supabase during active navigation.
- While the app is backgrounded: standard `URLSession` / Task cancellation handles this naturally.

---

## 7. Pin Markers — Visual Spec

### 7.1 Icon and label per type

| `pin_type` | SF Symbol | Marker color | Callout label |
|---|---|---|---|
| `filming` | `video.fill` | `Color.purple` (system purple — distinct from parking overlays) | "Filming" |
| `special_event` | `star.fill` | `Color.orange` (distinct from amber-yellow metered overlay) | "Special Event" |

Both use `MKAnnotationView` (not `MKMarkerAnnotationView`'s default red teardrop, which conflicts with parking-restriction red). The marker is a circle with the SF symbol inside, rendered with `UIGraphicsImageRenderer`. Size: 32×32 pt for the image, 44×44 pt touch target (HIG minimum).

### 7.2 `PinMarkerAnnotation` (`MKAnnotationView` subclass)

New file: `ios/WePark/WePark/Views/PinMarkerAnnotation.swift`. Implements:
- `configure(for pin: CommunityPin)` — sets image, title, subtitle.
- `reuseIdentifier` static constant.
- Title: from `meta` — `FilmingMeta.productionName` if non-nil, else "Filming". For `specialEvent`: `SpecialEventMeta.eventName`.
- Subtitle: `expires_at` formatted as "Until HH:mm" if within the current day, else "Until <date>" — uses `Calendar.easternTime` (W3 convention, no `Calendar.current`).
- `canShowCallout = true` with a right-side disclosure indicator.

### 7.3 `CommunityPinAnnotation` (`MKAnnotation` conformance)

A lightweight struct wrapping `CommunityPin` and conforming to `MKAnnotation`:

```swift
// Sketch
final class CommunityPinAnnotation: NSObject, MKAnnotation {
    let pin: CommunityPin
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng) }
    var title: String? { pin.displayTitle }
    var subtitle: String? { pin.displaySubtitle }
    init(pin: CommunityPin) { self.pin = pin }
}
```

`displayTitle` and `displaySubtitle` are computed properties on `CommunityPin` (extension in `PinMarkerAnnotation.swift` or a new `CommunityPin+Display.swift` extension — engineer's choice). They do not live in `CommunityPin.swift` itself (keep the model pure data).

### 7.4 Tap → detail

`mapView(_:didSelect:)` in the Coordinator handles the tap. When the selected annotation is a `CommunityPinAnnotation`:

```swift
// Sketch — Coordinator
func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
    guard let pinAnnotation = view.annotation as? CommunityPinAnnotation else { return }
    DispatchQueue.main.async {
        self.activeSheetBinding.wrappedValue = .pinDetail(pinAnnotation.pin)
    }
}
```

`ActiveSheet.pinDetail(CommunityPin)` is a new case added to the `ActiveSheet` enum in `ContentView.swift`. The `DispatchQueue.main.async` wrapper follows the existing pattern at `MapViewRepresentable.swift` (per W5.1 fix — UIKit→SwiftUI callback wrapping).

---

## 8. Pin Detail Sheet

New file: `ios/WePark/WePark/Views/PinDetailSheet.swift`.

Content per type:

**filming:**
```
[video.fill icon]  Filming
[purple badge]     Open Data — NYC Film Permits
Production:  <productionName or "Unknown Production">
Block:       <derived from lat/lng reverse geocode or segment street name if segmentId is set>
Until:       <expires_at formatted in ET>
[NYC Film Office link if filmOfficeUrl non-nil]
```

**special_event:**
```
[star.fill icon]   Special Event
[orange badge]     Open Data
Event:       <eventName>
Type:        <eventType human-readable>
Until:       <expires_at formatted in ET>
```

**TF1 read-only note:** No "Report an issue" button, no vote/confirm UI, no "Still there?" prompt. The sheet is purely informational. A comment-anchor row is scaffolded but hidden (`#if DEBUG` at most) for TF1.

**Confirm count (deferred):** `confirm_count` is fetched but not displayed in the base TF1 sheet. A `// TODO: TF2 — display confirm_count badge` comment marks the hook.

**No auth required.** This sheet presents for anonymous users; no Supabase auth is needed to view it.

---

## 9. `CommunityPinService` Design

New file: `ios/WePark/WePark/Services/CommunityPinService.swift`.

```swift
// Interface sketch — @ios-engineer implements
@MainActor
@Observable
final class CommunityPinService {

    // Published state — ContentView observes this
    private(set) var visiblePins: [CommunityPin] = []
    private(set) var isLoading: Bool = false
    private(set) var fetchError: Error? = nil

    // Injected for testability
    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let nowProvider: () -> Date    // injectable for tests; default: { Date() }

    init(supabaseURL: URL, supabaseAnonKey: String, nowProvider: @escaping () -> Date = { Date() })

    // Called from ContentView.onRegionChanged callback — debounces internally
    func onRegionChanged(_ region: MKCoordinateRegion)

    // Called once at app launch
    func startRealtime()

    // Internal
    private func fetchPins(for region: MKCoordinateRegion) async
    private func mergeRealtimeChange(_ payload: RealtimeChangePayload)
    private func clientSideFilter(_ pins: [CommunityPin]) -> [CommunityPin]
    // clientSideFilter: removes pins where expiresAt != nil && expiresAt <= nowProvider()
    //                   and removes pins where resolvedAt != nil
}
```

`@MainActor` on the class ensures `visiblePins` mutations don't race with SwiftUI reads. `nowProvider` is injectable so tests can freeze time for expiry assertions.

**Supabase Swift SDK vs. raw URLSession:** Engineer's choice for TF1 — either the `supabase-swift` package or raw `URLSession` + `Codable`. Raw URLSession is simpler to set up (no SPM dependency management) and `CommunityPin` already implements `Codable`. Recommend raw URLSession for TF1; the `supabase-swift` SDK adds value for Tier 2/3 realtime subscription management. Document the choice in the PR.

---

## 10. Work Streams

These streams are designed for **parallel execution**. @backend-data (ingest + schema apply) and @ios-engineer (fixture-driven build) are file-disjoint until the prod schema is live.

| Stream | Owner | Dependency | Parallel with | Notes |
|---|---|---|---|---|
| **A — Prod schema apply** | @backend-data | Kevin approval, schema QA already done | Stream B | `supabase/02-pins-schema.sql` + `02b-pins-ingest-indexes.sql`. One-time SQL Editor apply. |
| **B — Fixture-driven iOS build** | @ios-engineer | CommunityPin model merged (done) | Stream A | Build `CommunityPinService` + `PinMarkerAnnotation` + `PinDetailSheet` + `ContentView` wiring against fixture JSON. All unit tests must pass before any live DB dependency. |
| **C — ASP supplement integration** | @ios-engineer | Stream B | Serializes after B (modifies same files) | Wire `resolvedBannerState(bundleState:aspPins:)` helper into `ContentView.bannerState` logic. Unit-test with fixture asp_suspended_today pins. |
| **D — End-to-end smoke** | @ios-engineer + Kevin | Stream A live (prod schema), Stream B complete | — | Build + launch + sim screenshot (mandatory live-UI smoke gate, AC-D10). Kevin's drive-test confirms filming marker appearance in a real NYC context. |
| **E — Ingest job + seeds** | @backend-data | Stream A | Stream B | Film permit fetch + ASP seed per `tier1-open-data-ingest-spec.md`. Parallel with B — the iOS display code doesn't need real seeds to build. |

Stream B can and should begin immediately — the `CommunityPin` model is merged, and fixture JSON (from `typed-pin-schema-spec.md §4.3`) is sufficient for all display-layer unit tests.

---

## 11. Acceptance Criteria

All ACs must be verified by @qa-verifier independently. @qa-verifier is not the same agent that built the feature.

### Fetch + Service (verified by unit tests against fixtures)

- [ ] **AC-D1.** `CommunityPinService.clientSideFilter` removes pins where `expiresAt` is non-nil and `expiresAt <= now`. Verified with a fixture pin whose `expiresAt` is 1 second in the past.
- [ ] **AC-D2.** `CommunityPinService.clientSideFilter` retains pins where `expiresAt` is nil (durable pins have no expiry).
- [ ] **AC-D3.** `CommunityPinService.clientSideFilter` retains pins where `expiresAt` is 1 hour in the future.
- [ ] **AC-D4.** `CommunityPinService.clientSideFilter` removes pins where `resolvedAt` is non-nil (resolved pins are hidden).
- [ ] **AC-D5.** (End-to-end, requires prod schema) `visiblePins` count does not decrease after a simulated Realtime WebSocket reconnect. Verified by observing the Realtime subscription re-subscribes and re-fetches.
- [ ] **AC-D6.** The PostgREST query includes `source=eq.open_data` — a crowd-sourced `filming` pin (if one were injected by a test) would not appear in `visiblePins`. Verified by inspecting the URLRequest in a test.
- [ ] **AC-D7.** `onRegionChanged` with two calls 200ms apart fires only ONE fetch (debounce absorbs the first). Verified with a mocked URLSession call counter.
- [ ] **AC-D8.** `asp_suspended_today` pins are NOT passed to the map marker layer (only `filming` and `special_event` reach `communityPins` state var in ContentView). Verified by unit test.

### ASP Integration (verified by unit tests)

- [ ] **AC-D9a.** `resolvedBannerState(bundleState: .aspInEffect, aspPins: [fixture asp pin for today])` returns `.todaySuspended(reason:)`. The `reason` string comes from `pin.meta.aspSuspendedTodayMeta.reason`.
- [ ] **AC-D9b.** `resolvedBannerState(bundleState: .todaySuspended(reason: "Memorial Day"), aspPins: [fixture asp pin for today])` returns `.todaySuspended(reason: "Memorial Day")` (bundle wins, no regression).
- [ ] **AC-D9c.** `resolvedBannerState(bundleState: .aspInEffect, aspPins: [])` returns `.aspInEffect` (empty pin array = no override = W7 behavior preserved).
- [ ] **AC-D9d.** `resolvedBannerState` with an asp pin whose `expiresAt` is in the past returns `.aspInEffect` (expired pin does not override bundle).

### Live-UI Smoke Gate (MANDATORY before merge — AC-D10)

- [ ] **AC-D10.** Engineer builds + launches the app in Simulator. Captures a screenshot via `xcrun simctl io booted screenshot /tmp/community-pin-display-smoke.png`. Reads the screenshot using the Read tool (multimodal). Screenshot confirms: (a) the ASP banner still renders at the top, (b) the toolbar layer (gear / find-me / find-car / clock / Drive button) is visible, (c) no overlay elements have been dropped. This check must pass BEFORE the PR is opened. @qa-verifier repeats the same check independently.

**Rationale:** PR #31 (2026-05-26) merged with all tests passing (210/0) but silently dropped the entire toolbar + ASP banner + Park Until pill in the live app. The only way to catch this class of regression is to build, launch, and look. This gate is mandatory for any PR that touches `ContentView.swift` or `MapViewRepresentable.swift`.

### Map Markers (end-to-end, requires prod schema + at least one seeded pin)

- [ ] **AC-D11.** A `filming` pin seeded in the DB (or injected via a test fixture wired through the live `CommunityPinService`) appears as a purple `video.fill` marker on the map at the correct lat/lng.
- [ ] **AC-D12.** Tapping the marker opens `PinDetailSheet` with the production name and expiry time. Presented as a sheet via `ActiveSheet.pinDetail`.
- [ ] **AC-D13.** A `filming` pin whose `expires_at` is in the past does NOT appear on the map (client-side filter).
- [ ] **AC-D14.** Panning the map to a region with no pins shows zero community markers (bounding box filter works).
- [ ] **AC-D15.** No community pin marker interferes with tapping a parking segment polyline. Tapping a polyline segment still opens `BlockDetailSheet` normally.

### Architecture Invariants (verified by code review + existing tests)

- [ ] **AC-D16.** `MapViewRepresentable.updateUIView` contains no new camera-mutation calls, no new `setRegion` calls, and no `headlessWindow` guards. Code-reviewed by @qa-verifier.
- [ ] **AC-D17.** All `MKAnnotation` mutations from community pins happen inside a `.onChange(of: communityPins)` modifier in `ContentView`, not inside `updateUIView`.
- [ ] **AC-D18.** `RegionSyncGuardTests` (2 tests) pass unchanged after any modification to `MapViewRepresentable.swift`.
- [ ] **AC-D19.** No `Calendar.current` usage in `CommunityPinService.swift`, `PinMarkerAnnotation.swift`, or `PinDetailSheet.swift`. All time formatting uses `Calendar.easternTime`.
- [ ] **AC-D20.** `CommunityPin.swift` is NOT modified by this spec's implementation. The model is frozen at PR #36; display extensions live in separate files.

### Security / RLS (end-to-end, requires prod schema)

- [ ] **AC-D21.** An unauthenticated fetch (anon key, no Bearer token) returns `filming` and `asp_suspended_today` pins successfully. Verified by inspecting the URLRequest — no `Authorization: Bearer <user-jwt>` header; only `apikey: <anon-key>`.
- [ ] **AC-D22.** The anon key is NOT committed to any source file. It lives in `Config.xcconfig` (gitignored). `Config.xcconfig.example` documents the `SUPABASE_ANON_KEY` and `SUPABASE_URL` key names.

---

## 12. Out-of-Scope Follow-ups

**Drive Mode community pin callout.** When Drive Mode is active and the route passes within 100m of a `filming` pin, a voice/chip callout ("Filming ahead — check your route") would close the loop between the map marker and the in-car experience. This is a separate spec (no code today; a `// TODO: Drive Mode community callout` comment in `DrivingContextService.swift` or `DriveModeBottomCard.swift` marks the seam). Tier 1.5 / post-TF1.

**Push notification for pins near parked car.** When a new `filming` pin is inserted within 50m of the user's parked car, a local push notification fires. The `CommunityPinService`'s Realtime subscription is the trigger point. Requires `NotificationScheduler` extension. Post-TF1.

**Confirm-count badge on map marker.** A small badge on the `PinMarkerAnnotation` showing `confirmCount` when > 0. Not displayed in TF1; the `confirm_count` field is fetched and available in the `CommunityPin` struct. A `// TODO: TF2 — display confirm_count badge on PinMarkerAnnotation` comment marks the hook.

**Supabase Swift SDK adoption.** For TF1, raw `URLSession` is sufficient. For Tier 2/3 (authenticated writes, vote RPCs, more complex Realtime filters), the `supabase-swift` package adds value. Evaluate at Tier 2 spec time.

**Marker clustering.** Deferred to TF2. At Tier 1 density (<20 active film permits on any day) clustering adds complexity without benefit. The `MKAnnotation` approach chosen here is compatible with `MKClusterAnnotation` — add `clusteringIdentifier` to `CommunityPinAnnotation` in a TF2 follow-up.

**`construction` pins.** DOT data quality audit required before display. Deferred to TF2 per buildplan OQ-4.

**`special_event` seeding.** NYC 311 events API requires an API key and is deferred to TF2 per `tier1-open-data-ingest-spec.md §7`. The display code ships in TF1 (OQ-2 recommendation above); the seeds follow when the ingest pipeline supports it.

**2027 ASP calendar.** The bundle `asp-2026.json` will need updating in December 2026 / January 2027. The Supabase ingest seed script also needs updating. Both are operational procedures, not code changes. Tracked in HANDOFF.md backlog.
