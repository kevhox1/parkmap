# W5 — Pin Drop + Persistence

**Status:** Decisions locked 2026-05-11. Spec ready for `@ios-engineer`.
**Owner:** @ios-engineer (build), Tech Lead (spec).
**Depends on:** W4 (block detail sheet, "Park here" stub), W4.5 (6h threshold).
**Blocks:** W6 (notification rationale on first pin drop), W7.5 ("Park Until X" prompt hook).
**Spec reference:** `docs/ios-mvp-spec.md` §2.1 ("Park here flow"), §3.4 (notification/location permission timing), §4.1 (architecture diagram), §6 AC-7 / AC-8; `docs/w4-block-detail-spec.md` §3.3 (the disabled "Park here →" stub), §3.1 (long-press reserved).

---

## Open Questions for Kevin (read before dispatch)

**OQ-W5-1: "Wrong street?" alternatives — port or defer?**
The PWA shows up to 3 alternative nearby blocks when the auto-detected block might be wrong (corners and intersections). This requires a `findCandidateSegments`-equivalent haversine multi-search and a sheet section with tappable block alternatives. It is a real UX win at corners but adds one non-trivial UI surface.
- **Recommendation: Port it.** The PWA code is tight (≈20 lines of segment scanning), the iOS haversine search is already written for W4 tap-target detection, and the failure mode without it — the user parks on 1st Ave but the app silently binds to the 34th St cross segment — is bad enough that omitting it would generate support noise.
- If you want to defer and ship a simpler "take the closest segment, always" flow, say so and I will mark this deferred. It shaves roughly half an `@ios-engineer` session.

**OQ-W5-2: Side-of-street confirmation — required or auto-detect?**
The PWA always prompts for side (N/S/E/W). The detected segment already has `side` on it; the iOS engine can use it directly without a prompt.
- **Recommendation: Auto-detect (use the closest segment's `side` field, skip the prompt).** Rationale in §5. If you prefer the PWA-literal prompt, say so; it is a straightforward UI addition but contradicts the "fewest taps to parked" iOS native ethos.

Both OQs affect §4 (architecture) and §8 (AC count). The spec is written with the recommendations (port "Wrong street?", skip side prompt). If either answer changes, redline the affected sections before dispatch.

---

## 1. Problem & User Story

W4 gives the user a readable block detail sheet on tap. But "reading" is not the daily job — *remembering* is. The user parks, locks the car, and needs the app to hold onto "where I am and when I have to move" until they come back. Today the "Park here →" button in `BlockDetailView` is a disabled stub with "Coming next" underneath. W5 wires it.

**User story (primary — via block tap):**
> I'm parked on Bowery between Hester and Grand. I tap the block, the sheet slides up showing "Free until Thu 9:30am". I tap "Park here". The sheet dismisses, a car pin appears on the map at the exact spot I tapped, and the next time I open the app the pin is still there. I tap the pin and see "Bowery — North side · Free until Thu 9:30am · parked 3h ago." I tap "I left" and the pin clears.

**User story (secondary — via long-press):**
> I'm looking at the map and I long-press my block. A confirmation sheet appears showing the detected block and the current parking rules. I tap "Park here" and the pin drops.

**User story (no nearby data):**
> I long-press on a block near Hudson River with no tile data. The sheet shows "No parking data nearby — your pin was saved at this location." The pin still drops; there are just no rules to show.

---

## 2. Scope

### 2.1 In scope

- `ParkedCar` model (`Models/ParkedCar.swift`) with exact fields defined in §4.
- `ParkPinService` (`Services/ParkPinService.swift`) — `UserDefaults`-backed single-pin persistence. Codable blob under a single key. Read on app launch, write on pin drop, delete on clear.
- **Long-press gesture** on the map (via `UILongPressGestureRecognizer` added to `MKMapView` in the existing `MapViewRepresentable` Coordinator). Fires `onLongPress(CLLocationCoordinate2D)` closure up to `ContentView`.
- **"Park here →" button** in `BlockDetailView` — remove `.disabled(true)` and "Coming next" caption. Wire the button action to a new `onParkHere: (() -> Void)?` closure parameter passed from `ContentView`. When tapped, initiates a pin drop using the sheet's segment as the detected segment and the segment midpoint as the lat/lng.
- **Pin confirmation sheet** (`Views/ParkConfirmView.swift` — new file). A `.sheet(item:)` presenting:
  - Detected block display (street, from/to, side label).
  - "Wrong street?" alternatives list (if OQ-W5-1 recommendation accepted — port from PWA).
  - "Park here" confirm button and "Cancel" button.
  - Safety label for the detected segment (so the user knows the rules before confirming).
- **Car pin annotation** on the map. `MKAnnotationView` with `MKPointAnnotation` subclass `CarPinAnnotation`. Visual spec: §5 (marker design).
- **Pin tap** — tapping the car pin opens a `ParkedCarDetailView` sheet (new file, §3.3).
- **"I left" clear flow** — button inside `ParkedCarDetailView`. Removes the pin and clears `UserDefaults`.
- **Silent-replace behavior** — dropping a new pin when one exists silently replaces (details in §4.4 — this is the locked decision).
- **Persistence across launches** — pin survives kill + relaunch.
- **Z-order** — car pin annotation renders above all 6 `MKMultiPolyline` overlays and the selected-block highlight overlay.
- **W6 hook** — `ParkPinService` publishes a `firstPinDropped` Combine `PassthroughSubject<Void, Never>` (or equivalent async/await mechanism). W6 subscribes to schedule the notification rationale flow. Full spec in §6.1.
- **W7.5 hook** — `ParkPinService` publishes a `pinDropped(ParkedCar)` event that W7.5 can observe to present the "Parking until when?" prompt. Full spec in §6.2.
- **No-nearby-data graceful fallback** — if the haversine search finds no segment within 35m of the long-press coordinate, the pin still drops; `detectedSegmentID` is `nil`; the confirm sheet and pin detail view show "No parking data at this location."
- **Outside-tile-grid graceful fallback** (e.g., Brooklyn long-press) — same as no-nearby-data: pin drops with nil segment. The app is silently accurate about what it knows.

### 2.2 Out of scope (DO NOT BUILD)

- **Notification scheduling** — W6. W5 emits the hook; W6 consumes it.
- **ASP banner** — W7.
- **"Parking until when?" prompt UI** — W7.5. W5 emits the hook; W7.5 consumes it.
- **Side-of-street confirmation prompt** — deferred per OQ-W5-2 recommendation. Auto-detect from `segment.side`.
- **Pin drag-to-reposition** — the PWA supports this (the Leaflet marker is `draggable: true` and calls `openParkModalForPin` on `dragend`). On iOS, `MKAnnotationView`'s `isDraggable` is available but it complicates the UX significantly (drag implies side/segment re-detection). Deferred post-MVP.
- **Smart Move recommendations** — post-MVP.
- **Multi-pin / history** — single pin only, always. Post-MVP.
- **Address-search pin drop** — post-MVP.
- **Threat tracker reports tied to the parked spot** — post-MVP.
- **Street-mode manual entry** (the PWA has a "street name + cross streets" text-form alternative to pin mode). The iOS native flow always uses coordinate-based detection. No manual text entry in MVP.

---

## 3. User-Facing Feature Design

### 3.1 Long-press entry point

A `UILongPressGestureRecognizer` is added to the `MKMapView` in `MapViewRepresentable.Coordinator.makeUIView`. Minimum press duration: **0.4 seconds** (iOS default is 0.5s; 0.4s feels more responsive on a small phone and is above the 0.3s accidental-tap-hold threshold). When the recognizer fires at `.began` state:

1. Convert the touch point to `CLLocationCoordinate2D` via `mapView.convert(_:toCoordinateFrom:)`.
2. Call the `onLongPress(CLLocationCoordinate2D)` closure (new closure parameter on `MapViewRepresentable`, parallel to the existing `onTap` closure).
3. `ContentView` receives the coordinate, runs segment detection (§4.2), and presents `ParkConfirmView` as a `.sheet(item:)`.

**Coexistence with tap gesture:** The existing `UITapGestureRecognizer` handles single-taps. Long-press does not interfere because `UIGestureRecognizer.require(toFail:)` is not needed — iOS disambiguates tap vs. long-press by gesture duration natively. No changes to the existing tap handler are needed.

**Coexistence with open block-detail sheet:** If a `BlockDetailView` sheet is open when the user long-presses, the long-press fires normally. `ContentView` dismisses the block detail sheet and presents `ParkConfirmView` instead. This is handled by the SwiftUI sheet binding — only one `.sheet(item:)` is presented at a time.

### 3.2 "Park here →" button entry point (in BlockDetailView)

`BlockDetailView` gains a new optional closure parameter:

```
let onParkHere: (() -> Void)?
```

When `onParkHere` is non-nil, the button is enabled and the "Coming next" caption is removed. When `onParkHere` is nil (e.g., in the Xcode `#Preview`), it stays disabled with the caption — so the preview behavior does not regress.

`ContentView` passes a non-nil `onParkHere` closure. The closure:
1. Computes the segment midpoint (`segment.midpoint` — already on the `Segment` model at `Segment.swift:72`).
2. Calls the same pin-drop flow as the long-press path, passing the midpoint as the coordinate and the already-known segment as the detected segment (bypassing haversine search — §4.2 path B).
3. Dismisses `BlockDetailView` and presents `ParkConfirmView`.

### 3.3 ParkConfirmView (new sheet)

Style: `.sheet(item:)` binding tied to a `PinDropIntent` struct (defined in §4.3). Detents: `.medium` (default). Non-dismissible by swipe (`.interactiveDismissDisabled(true)`) to prevent accidental cancel. Dismiss paths: "Park here" button or "Cancel" button only.

Content (top to bottom):

1. **Sheet title** — `"Park my car"`, `.title2.bold()`.

2. **Detected block** — shows the auto-detected segment:
   - `"<StreetName> — <SideLabel>"` (same format as `BlockDetailView`'s header)
   - `"between <from> and <to>"`
   - If `detectedSegment` is nil: `"No parking data at this location"` in `.secondary` style.

3. **"Wrong street?" alternatives** (only shown if OQ-W5-1 answer = port):
   - Section header: `"Wrong street? Nearby blocks:"`, `.caption`, `.secondary`
   - One button per alternative candidate from `findCandidateSegments(lat, lng, radius: 35, max: 4)` minus the auto-detected one.
   - Button label: `"<StreetName> (<dist>m)"` — e.g., `"1st Avenue (28m)"`.
   - Tapping a button re-assigns `detectedSegment` to that candidate and re-renders the detected block and safety label. The pin lat/lng does not change.
   - Maximum 3 alternatives shown (4 candidates minus the top-1 auto-detected = max 3 alternatives).

4. **Safety label** — `engine.safetyLabel(for: detectedSegment, at: .now).text` if segment is non-nil. Font `.headline`. Omit if no segment.

5. **Action row** — two buttons side by side:
   - `"Cancel"` — `.buttonStyle(.bordered)`, dismisses the sheet without saving.
   - `"Park here"` — `.buttonStyle(.borderedProminent)`, confirms the drop, saves via `ParkPinService`, dismisses. 44pt minimum height on both.

**Accessibility:** `"Park here"` button has `.accessibilityLabel("Confirm parking at \(streetName)")`. "Cancel" has `.accessibilityLabel("Cancel parking here")`.

### 3.4 ParkedCarDetailView (new sheet)

Triggered by tapping the car pin annotation on the map. The tap fires through the existing `UITapGestureRecognizer` path — the Coordinator's `handleTap` method (currently in `MapViewRepresentable`) should check if the tapped coordinate is within ~30pt of the car pin annotation's rendered position before running the haversine segment search. If it matches the car pin, fire an `onCarPinTapped` closure instead of `onTap`.

Style: `.sheet(item:)` tied to the current `ParkedCar`. Detents: `.medium` (default), `.large`. `.presentationDragIndicator(.visible)`.

Content (top to bottom):

1. **Color band** — same 6pt band as `BlockDetailView`, using `engine.currentStateColor(for: detectedSegment, at: .now)`. Gray if no segment.

2. **Car pin header** — `"My Car"`, `.title2.bold()`. Below it: the block label from `ParkedCar.street` + side + from/to. If no segment: `"Location saved (no parking data)"`.

3. **Safety label** — `engine.safetyLabel(for: detectedSegment, at: .now).text` if non-nil. Font `.title.bold()`. This is the first focusable accessibility element (same VoiceOver discipline as `BlockDetailView`).

4. **Parked-at timestamp** — `"Parked \(relativeTimeString(from: parkedCar.parkedAt))"` — e.g., `"Parked 3h ago"`. `.subheadline`, `.secondary`.

5. **Rules list** — same `RuleRow` component as `BlockDetailView` (extract `RuleRow` to a shared file or keep it in `BlockDetailView.swift` and make it `internal` rather than `private` so `ParkedCarDetailView` can reuse it). Omit if no segment.

6. **"I left" button** — `.buttonStyle(.bordered)`. Tint `.red`. Label: `"I left — clear pin"`. Minimum 44pt height. On tap: calls `ParkPinService.clearPin()`, dismisses the sheet. `.accessibilityLabel("I left. Clear my parked car pin.")`.

7. **✕ close button** — same style as `BlockDetailView` (`.xmark.circle.fill`, top-right, 44pt).

**Where does this button live?** The design decision is to put "I left" inside the detail sheet, not on a persistent banner. Rationale: a persistent "You're parked" banner at the top of the map (like a navigation banner) would eat screen real estate while the user is just browsing blocks before they park. W7 (ASP banner) will already occupy the top stripe. The pin itself is the persistent "I'm parked" indicator; the detail sheet is the management surface. Users will discover the sheet by tapping the pin, which is the natural gesture (same as tapping any block).

---

## 4. Architecture

### 4.1 New files

| File | Role |
|---|---|
| `Models/ParkedCar.swift` | Codable model for the stored pin state |
| `Services/ParkPinService.swift` | UserDefaults read/write, event hooks |
| `Views/ParkConfirmView.swift` | Pin-drop confirmation sheet |
| `Views/ParkedCarDetailView.swift` | Parked-car management sheet (tap the pin) |

Modified files:
- `Views/BlockDetailView.swift` — add `onParkHere: (() -> Void)?` parameter; wire button; remove disabled + caption when non-nil.
- `Views/MapViewRepresentable.swift` — add `UILongPressGestureRecognizer` in Coordinator; add `onLongPress: (CLLocationCoordinate2D) -> Void` closure parameter; add `CarPinAnnotation` + `MKAnnotationView` rendering; add `onCarPinTapped: () -> Void` closure; add `carPin: ParkedCar?` input to drive annotation add/remove.
- `ContentView.swift` — wire all new closures; manage `@State var parkedCar: ParkedCar?`; add `.sheet(item:)` for `ParkConfirmView` and `ParkedCarDetailView`.

### 4.2 Segment detection paths

**Path A — long-press coordinate:**
1. Run `findCandidateSegments(lat, lng, radius: 35, max: 4)` — same haversine point-to-segment geometry already used in W4's tap handler. Returns `[CandidateSegment]` sorted by distance, deduplicated by unique block (same PWA `street|from|to` key logic at `index.html:5105`).
2. `detectedSegment` = `candidates.first?.segment ?? nil`.
3. `alternativeCandidates` = `candidates.dropFirst()` filtered to unique streets (same PWA logic: exclude candidates on the same street+from+to as the auto-detected one, at `index.html:4935`).
4. Pass all of this into `PinDropIntent` (§4.3) which drives `ParkConfirmView`.

**Path B — "Park here →" button from BlockDetailView:**
1. The segment is already known (the tapped segment from W4 flow).
2. `detectedSegment` = the sheet's `segment`.
3. `alternativeCandidates` = empty (skip the haversine multi-search — the user explicitly selected this block).
4. `pinLat/pinLng` = `segment.midpoint` (lat/lng of the coordinate midpoint of the segment's polyline — already computed at `Segment.swift:72`).

**`findCandidateSegments` port notes:**
The function is already partially present in W4's haversine tap-handler code. The W5 version needs to (a) search a 35m radius instead of the tap's minimum-distance search, (b) group by block key (`street|from|to`), and (c) return up to 4 results sorted by distance. This is the same algorithm as `index.html:5096-5111`. Extract it as a method on `ParkingRulesEngine` or as a free function in a new `Services/SegmentSearch.swift` — engineer's call, but it must be reusable for both W4 tap detection and W5 candidate search.

### 4.3 PinDropIntent (intermediate state struct)

A value type (not persisted) that carries the in-flight intent between `ContentView` and `ParkConfirmView`:

```
struct PinDropIntent: Identifiable {
    let id = UUID()
    let pinLat: Double
    let pinLng: Double
    var detectedSegment: Segment?
    var alternativeCandidates: [CandidateSegment]   // empty for Path B
}
```

`CandidateSegment` is a small struct: `segment: Segment, distanceMeters: Double`. This is the value-type equivalent of the JS `{ seg, distM }` objects in `findCandidateSegments`.

`ContentView` holds `@State var pinDropIntent: PinDropIntent?`. When non-nil, `ParkConfirmView` is presented. On confirm or cancel, it is set back to nil.

### 4.4 ParkedCar model

```
// Models/ParkedCar.swift

struct ParkedCar: Codable, Identifiable {
    var id: UUID                   // stable identity for SwiftUI .sheet(item:) binding
    let latitude: Double           // exact tap coordinate — no snapping
    let longitude: Double
    let detectedSegmentID: String? // segment.id for rules re-lookup at detail-view time
    let detectedSide: String?      // "N" | "S" | "E" | "W" — from segment.side
    let street: String?            // cached for display without re-lookup
    let fromStreet: String?        // cached for "between X and Y" subtitle
    let toStreet: String?
    let parkedAt: Date             // wall-clock ET timestamp of pin drop
}
```

**No snap:** `latitude`/`longitude` are stored as the raw tap coordinate from the long-press (Path A) or the segment midpoint (Path B — see §3.2 rationale). The `detectedSegmentID` is used for rules lookup in `ParkedCarDetailView` but never used to reposition the visual pin. This matches the PWA behavior documented at `index.html:5047-5052` ("Keep the marker exactly where the user tapped. The detected segment is used for parking-rules lookup, but the visual pin should not jump away from the spot the user picked.").

**Segment re-lookup:** `ParkedCarDetailView` resolves `detectedSegmentID` at sheet-open time by searching `TileLoader.loadedSegments` for a matching `segment.id`. If the tile containing that segment has been evicted from the LRU cache, the re-lookup may return nil — fallback to "No parking data" state. This is acceptable and documented in AC-W5.9.

**Persistence:** `ParkPinService` encodes the `ParkedCar` to JSON via `JSONEncoder()` and stores it at `UserDefaults.standard.set(_:forKey: "wepark_parked_car")`. On app launch, `ParkPinService.load()` decodes and publishes the stored value if present.

**Single-pin model — silent replace:** When the user drops a new pin while one exists, the existing pin is silently replaced. No confirmation alert. Rationale: the PWA does silent-replace (`addCarMarker` at `index.html:4596` calls `map.removeLayer(carMarker)` before adding the new one, with no confirmation). The iOS native interaction is already intentional (long-press + confirm sheet is 2 deliberate steps); a third "are you sure you want to replace?" dialog would be gratuitously annoying. The old pin is gone when the user taps "Park here" in `ParkConfirmView`.

### 4.5 ParkPinService API sketch (non-binding — implementation is engineer's domain)

```
// Services/ParkPinService.swift

@Observable
final class ParkPinService {

    // MARK: Published state
    private(set) var parkedCar: ParkedCar?

    // MARK: W6 hook — first-pin event
    // W6 subscribes to this to present the notification rationale sheet.
    // Emits exactly once: when the user drops a pin and no previous pin has ever existed
    // (i.e., the UserDefaults key "wepark_has_ever_parked" is absent).
    let firstPinDropped = PassthroughSubject<Void, Never>()

    // MARK: W7.5 hook — every pin drop event
    // W7.5 subscribes to this to prompt "Parking until when?"
    // Emits on every pin drop (including replacements).
    let pinDropped = PassthroughSubject<ParkedCar, Never>()

    // MARK: Lifecycle
    func load()                        // call once at app launch; reads UserDefaults
    func save(_ car: ParkedCar)        // atomic encode + UserDefaults write; emits hooks
    func clearPin()                    // deletes UserDefaults key; sets parkedCar = nil

    // MARK: Private
    private let defaults = UserDefaults.standard
    private let storageKey = "wepark_parked_car"
    private let hasEverParkedKey = "wepark_has_ever_parked"  // Bool flag for W6 first-pin logic
}
```

**`@Observable` macro** (iOS 17+): `parkedCar` propagates to `ContentView` and `MapViewRepresentable` reactively without manual `@Published` wiring.

**`hasEverParkedKey` semantics:** Set to `true` on the first successful `save()`. Never cleared, even when the user clears the pin with "I left." This ensures the first-pin notification rationale (W6) fires exactly once per app install, not once per parking session.

### 4.6 ContentView wiring changes

`ContentView` gains:

1. `@State var pinDropIntent: PinDropIntent?` — drives `ParkConfirmView` sheet.
2. `@State var showingParkedCarDetail: Bool = false` — drives `ParkedCarDetailView` sheet (or use `@State var parkedCarDetailItem: ParkedCar?` for `.sheet(item:)` binding — engineer's choice, but `item:` is preferable for consistency).
3. `@StateObject var parkPinService = ParkPinService()` (or inject as an environment object — engineer's choice).
4. On app appear: call `parkPinService.load()`.
5. Pass `carPin: parkPinService.parkedCar` into `MapViewRepresentable`.
6. Pass `onLongPress: { coord in ... }` into `MapViewRepresentable`.
7. Pass `onCarPinTapped: { showingParkedCarDetail = true }` into `MapViewRepresentable`.
8. Pass `onParkHere: { ... }` into `BlockDetailView` (non-nil, enables the button).

---

## 5. Decisions (locked)

### 5.1 Marker visual design

**SF Symbol: `mappin.circle.fill`**

Decision rationale:
- `mappin.circle.fill` is the most semantically precise symbol in SF Symbols — a pin inside a circle, strongly associated with "parked location."
- `car.fill` is also available but reads as "vehicle in motion" on an iOS map rather than "location of car" — semantically imprecise.
- `parkingsign.brakesignal` is parking-themed but too complex at small sizes and is associated with parking signs/rules, not the user's car.
- `mappin.and.ellipse` is a reasonable second choice but the ellipse implies a zone, not a point.

**Rendering:**
- SF Symbol rendered as `UIImage(systemName: "mappin.circle.fill")` in the `MKAnnotationView`.
- Symbol configuration: `.symbolRenderingMode(.palette)` with foreground `UIColor.white` and secondary `UIColor.systemBlue`. The blue circle + white pin is visually distinct from all 5 parking-state polyline colors (red, orange, amber-yellow, green, gray) and reads as "user's object" without conflicting with Apple Maps' own blue location dot.
- Tint point size: 36pt (via `UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)`). At this size the annotation is clearly visible above the polyline overlays without dominating the map at normal zoom.
- Drop shadow: add `layer.shadowColor = UIColor.black.cgColor`, `shadowOpacity = 0.3`, `shadowOffset = CGSize(width: 0, height: 2)`, `shadowRadius = 3` to the annotation view's layer.

**Anchor point:** tip at coordinate. `centerOffset` = `CGPoint(x: 0, y: -18)` to shift the annotation view so its bottom tip aligns with the stored lat/lng. This is standard iOS `MKAnnotationView` behavior (`centerOffset` moves the view so the pin tip lands on the coordinate).

**Labels:** No floating street-name label above the pin. The block label is in `ParkedCarDetailView` (accessible by tapping the pin). A floating label would compete with block tap targets and the ASP banner.

**Z-order vs overlays:** `MKAnnotationView` renders in a dedicated annotations pane that is already above all `MKOverlay` renderers in `MKMapView`'s layer stack. No manual `zPosition` override needed. Confirmed by Apple's `MKMapView` rendering order documentation: overlays → annotations (overlays are beneath by default).

### 5.2 Side-of-street detection

**Decision: auto-detect from `segment.side`, no prompt.**

The detected segment (closest segment by haversine distance) already carries a `side` field ("N", "S", "E", "W"). This is stored in `ParkedCar.detectedSide` directly. No side-picker UI is shown.

Rationale:
- The user already performed a spatial selection (long-press at their car's location or tap on the block they're parked on). The closest-segment search retrieves the face of the street their car is actually on — not the opposite face — because they tapped near their car.
- The PWA prompts for side because it also supports a "street name lookup" mode where the user types an address and has no coordinate-based disambiguation. That mode is not being ported to iOS (§2.2 out-of-scope: "Street-mode manual entry"). With coordinate-based input only, auto-detection is accurate.
- Removing the prompt saves 2 taps per park session. For a daily-active feature this matters.
- If the user somehow gets the wrong side (corner case at intersections), the "Wrong street?" alternatives flow (§3.3 / OQ-W5-1) surfaces the correct alternative block, which implicitly corrects the side too.

### 5.3 Replace behavior

**Decision: silent replace** (no confirmation alert when an existing pin is present).

Rationale: the confirm sheet (`ParkConfirmView`) already has a "Park here" confirmation step — the user must explicitly tap "Park here" to save. That is the "are you sure" gate. Adding a second layer ("a pin already exists — replace?") would make re-parking a 4-tap flow instead of a 2-tap flow. The PWA silently replaces (`addCarMarker` removes the old marker before adding the new one without any guard, `index.html:4596`). Follow the PWA.

### 5.4 Pin persistence model

**Decision: `UserDefaults` with a single `Codable` blob.**

One encoded `ParkedCar` JSON blob at key `"wepark_parked_car"`. Encode/decode on every save/load. Survives app kill + relaunch (standard `UserDefaults` behavior). Cleared on `clearPin()`. Reset on app uninstall.

There is no "session expiry" — a pin dropped last week is still there next week until the user clears it. This matches the PWA (`localStorage.setItem('parkmap_parked_block', ...)` — no TTL). Users who forget to clear the pin will see a stale pin; the safety label will still be accurate because it's recomputed from current time at view time.

---

## 6. Downstream Hooks (W6 and W7.5)

### 6.1 W6 Hook — First-Pin Notification Rationale

W6's job is to present the notification rationale sheet and request `UNUserNotificationCenter` permission the first time a user parks their car. W5 defines the hook; W6 consumes it.

**Hook definition** (in `ParkPinService`):

```
let firstPinDropped = PassthroughSubject<Void, Never>()
```

**Emission logic:** In `ParkPinService.save(_:)`, before writing to `UserDefaults`:
1. Check `defaults.bool(forKey: hasEverParkedKey)`.
2. If `false` (first ever save): emit `firstPinDropped.send()`, then set `hasEverParkedKey = true`.
3. If `true`: do not emit.

**W6 consumption:** W6 subscribes to `firstPinDropped` in `ContentView` (or a dedicated coordinator) via `.onReceive(parkPinService.firstPinDropped) { ... }` — same pattern as SwiftUI Combine integration. W6 shows its rationale sheet from this subscription.

**Invariant this creates for W6:** W6 must NOT ask for permission at app launch or at any other time. The only trigger is `firstPinDropped`. This matches `docs/ios-mvp-spec.md` §3.4 decision.

### 6.2 W7.5 Hook — "Parking Until When?" Prompt

W7.5's "Park Until X" filter (see `docs/ios-color-threshold-spec.md` §8) is best surfaced immediately after pin drop, when the user's parking intent is active. W5 defines the hook; W7.5 builds the UI.

**Hook definition** (in `ParkPinService`):

```
let pinDropped = PassthroughSubject<ParkedCar, Never>()
```

**Emission logic:** In `ParkPinService.save(_:)`, after writing to `UserDefaults`: emit `pinDropped.send(car)`. Emits on every pin drop including replacements.

**W7.5 consumption:** W7.5 subscribes to `pinDropped` and, after a brief delay (≈ 1 second, to let the pin-drop animation settle), presents a prompt: "Parking until when?" with a time picker. The filter then activates from the user's selection.

**W5's responsibility ends at the emission.** W5 does not build the "Parking until when?" prompt, the time picker, or the filter logic. Those are W7.5. W5 just guarantees the event fires.

---

## 7. Work Streams

W5 is a single-engineer stream. There is no parallelism opportunity within W5 because all pieces converge on `ContentView`. However, W5 and W7 (ASP banner) can run in parallel since they touch different files.

| Stream | Owner | Dependency | Notes |
|---|---|---|---|
| **W5** (this spec) | @ios-engineer | W4 + W4.5 merged | Single stream, ~2-3 sessions |
| **W6** (notifications) | @ios-engineer | W5 merged | Consumes `firstPinDropped` hook; spec not yet written |
| **W7** (ASP banner) | @ios-engineer | W3 (already merged) | Parallel with W5; touches `ASPSuspensionService` which is already live |
| **W7.5** ("Park Until X") | @ios-engineer | W5 + W6 + W7 merged | Consumes `pinDropped` hook; spec to be written after W5-W7 ship |

**W5 internal build order (single engineer):**
1. `ParkedCar.swift` + `ParkPinService.swift` (data layer — no UI dependency).
2. `ParkConfirmView.swift` (can be built and previewed with static `PinDropIntent`).
3. `MapViewRepresentable.swift` changes: long-press gesture + `CarPinAnnotation` rendering + `onCarPinTapped`.
4. `BlockDetailView.swift` changes: `onParkHere` parameter + button re-enable.
5. `ParkedCarDetailView.swift`.
6. `ContentView.swift` wiring (last — ties everything together).

---

## 8. Acceptance Criteria

- [ ] **AC-W5.1 — Long-press drops pin.** Long-press on any map location (>0.4s) opens `ParkConfirmView`. Tapping "Park here" drops a `mappin.circle.fill` annotation at the exact tapped coordinate. Tapping "Cancel" leaves no pin.
- [ ] **AC-W5.2 — "Park here" button wired.** Tapping an active block → sheet opens → "Park here →" button is enabled (not greyed out, no "Coming next" caption). Tapping it opens `ParkConfirmView` pre-populated with the tapped segment. No regression to W4 AC-W4.5 behavior.
- [ ] **AC-W5.3 — No snap.** The dropped pin visual coordinate is the exact `pinLat`/`pinLng` stored in `ParkedCar`, not the segment's polyline coordinate. Verify by dropping a pin away from a polyline (e.g., mid-block in a wide street): the pin stays where tapped, not dragged to the nearest polyline.
- [ ] **AC-W5.4 — Segment detected correctly.** After pin drop, tapping the car pin opens `ParkedCarDetailView` showing the correct street name, side, and safety label for the nearest block. Run on at least 5 blocks including one at a corner intersection.
- [ ] **AC-W5.5 — "Wrong street?" alternatives (if OQ-W5-1 = port).** Long-press at a corner where 2+ streets are within 35m: `ParkConfirmView` shows the detected block AND at least one alternative button. Tapping the alternative updates the detected block display and safety label. The pin lat/lng does not change.
- [ ] **AC-W5.6 — Persistence across launches.** Drop a pin, kill the app (swipe up in app switcher), relaunch. The pin appears at the same lat/lng immediately on map load.
- [ ] **AC-W5.7 — "I left" clears pin.** Tap the pin → `ParkedCarDetailView` → "I left — clear pin." Pin disappears from map. Kill + relaunch: no pin appears. `UserDefaults` key is absent.
- [ ] **AC-W5.8 — Silent replace.** Drop a pin, then drop another pin at a different location. No confirmation alert. The new pin appears; the old pin is gone. Only one pin exists at any time.
- [ ] **AC-W5.9 — Segment re-lookup graceful degradation.** Drop a pin, pan far away (evicting tile from LRU cache), tap the pin. `ParkedCarDetailView` opens. If segment lookup fails (tile evicted), shows "No parking data at this location" gracefully — no crash, no blank sheet.
- [ ] **AC-W5.10 — No-nearby-data fallback.** Long-press in the Hudson River (no segments within 35m). `ParkConfirmView` opens showing "No parking data at this location." Tapping "Park here" saves the pin at the tapped coordinate with nil `detectedSegmentID`. `ParkedCarDetailView` shows the fallback message, not a crash.
- [ ] **AC-W5.11 — Outside tile grid.** Long-press in Brooklyn. Same fallback as AC-W5.10.
- [ ] **AC-W5.12 — Pin renders above polylines.** Car pin annotation is visually above all colored polyline overlays and the selected-block highlight. Verified by zooming to a colored block and dropping a pin directly on top of it.
- [ ] **AC-W5.13 — Accessibility.** VoiceOver: (a) car pin annotation has `.accessibilityLabel("My parked car. Tap for parking details.")`. (b) `ParkConfirmView`'s "Park here" button reads `"Confirm parking at <street>"`. (c) `ParkedCarDetailView`'s first focusable element is the safety label (same discipline as `BlockDetailView`). (d) "I left" button reads `"I left. Clear my parked car pin."`.
- [ ] **AC-W5.14 — W6 hook fires on first pin.** Drop a pin for the first time (clean install / `UserDefaults` cleared). `firstPinDropped` event is emitted exactly once. Drop a second pin: no second emission. Verify with a `print`/`Console.app` trace in W5 scope — full W6 integration is tested in W6.
- [ ] **AC-W5.15 — W7.5 hook fires on every pin.** Drop a pin (first or replacement): `pinDropped(car)` is emitted. Verify with a trace. Full integration is tested in W7.5.
- [ ] **AC-W5.16 — No W4 regression.** Tap a polyline → `BlockDetailView` opens as before. Long-press does not trigger a block detail sheet (it triggers `ParkConfirmView`). Swipe-down, ✕, and tap-outside dismissal paths on `BlockDetailView` all still work. `xcodebuild test` reports **45 passed, 0 failed** (the W4.5 test baseline).
- [ ] **AC-W5.17 — Long-press + open sheet coexistence.** With `BlockDetailView` open, perform a long-press on the map. `BlockDetailView` closes; `ParkConfirmView` opens. No orphaned sheets, no double-presentation.
- [ ] **AC-W5.18 — Memory.** Drop a pin, open and close `ParkedCarDetailView` 10 times. No `MKAnnotationView` memory leak (verify RSS does not grow monotonically in Instruments Allocations).

---

## 9. QA Pass Requirements

Beyond AC-W5.1 through AC-W5.18, the `@qa-verifier` must independently verify:

- No `Calendar.current` use anywhere added in W5.
- No `import SwiftUI` in `Models/ParkedCar.swift` or `Services/ParkPinService.swift`.
- `ParkPinService.save` is NOT called from a background thread (must be main-thread — `UserDefaults` writes from background threads can produce intermittent data loss on iOS).
- `hasEverParkedKey` is never cleared by `clearPin()`. Verify the clear implementation touches only `wepark_parked_car`, not `wepark_has_ever_parked`.
- `PinDropIntent.id` is a fresh `UUID()` on every long-press and every "Park here →" tap — no reuse that would prevent SwiftUI from re-presenting the sheet on rapid successive taps.
- The `mappin.circle.fill` symbol renders correctly in both Light and Dark Mode.
- AC-W5.3 (no snap) is verified by comparing the stored `parkedCar.latitude` / `parkedCar.longitude` values from `UserDefaults` against the tap coordinate logged at press time — they must match exactly, not just visually.

---

## 10. Open Decisions (non-binding — defer to Kevin)

**D-W5-1: Should the "I left" button ALSO be accessible from a small persistent banner on the map (rather than only from inside the pin detail sheet)?**

A persistent banner below the ASP banner (e.g., a thin strip: "Parked on Bowery N · Move by Thu 9:30am · [I left]") would make the clear action one tap instead of two (tap pin → tap "I left"). This is valuable if the app's daily pattern is "open → see status → close" rather than "open → tap pin → read rules → close." Recommendation: defer to v1.1 based on TestFlight usage patterns. W7 (ASP banner) will define the top-stripe layout; any parked-car banner must compose with it cleanly.

**D-W5-2: Should `ParkConfirmView` show a mini-map (snapshot of the tile map centered on the pin coordinate)?**

A `MKMapSnapshotter`-generated image of the surrounding few blocks would give the user a visual confirmation of where the pin is dropping. This is good UX but adds complexity and a potential render delay (~200–400ms for the snapshot). Recommendation: defer. The sheet's detected block text ("Bowery — North side, between Hester and Grand") is sufficient for v1.0.

---

## 11. Out of Scope Follow-Ups (punted with rationale)

**Pin dragging.** The PWA supports `dragend` on the car marker which reopens the park modal. On iOS, `MKAnnotationView.isDraggable = true` is available but the UX is awkward (how do you distinguish a tap-to-details from a drag-begin?). The confirm-on-drag-end flow also introduces a second "what street is this?" lookup mid-drag. Defer post-MVP.

**"Street mode" manual entry.** The PWA has a text-input path (type the street name, pick cross streets, pick side) for users who can't locate themselves on the map. iOS native users always have a coordinate from long-press or block tap, making manual entry redundant for MVP. Post-MVP if customer support requests it.

**Notification scheduling** — W6.

**ASP suspension banner** — W7.

**"Parking until when?" prompt** — W7.5.

**Smart Move** ("move tonight to Elizabeth St, skip tomorrow's ASP") — post-MVP. The engine is already capable of this; it needs a dedicated recommendation surface.

---

## 12. Sizing

**`@ios-engineer`:** 2–3 sessions.

Effort breakdown:
- `ParkedCar.swift` + `ParkPinService.swift` (Codable + UserDefaults + Combine hooks): ~30 min.
- `ParkConfirmView.swift` (including "Wrong street?" alternatives if OQ-W5-1 = port): ~60–90 min.
- `MapViewRepresentable.swift` changes (long-press gesture + `CarPinAnnotation` + tap disambiguation): ~60 min.
- `BlockDetailView.swift` changes (onParkHere parameter + button enable): ~15 min.
- `ParkedCarDetailView.swift` (safety label + rules list + "I left" button): ~45–60 min.
- `ContentView.swift` wiring: ~30 min.
- Testing + AC verification self-pass: ~30–45 min.

Total estimate: 5–6 hours of active engineering = 2 solid sessions. Third session is buffer for the `MapViewRepresentable` tap disambiguation (distinguishing car-pin tap from map-area tap is the trickiest coordination point).

**`@qa-verifier`:** 1 session.
- AC-W5.1 through AC-W5.18 verification.
- §9 extra QA checks.
- Memory leak check in Instruments (AC-W5.18).

Estimated calendar time: one day engineering + one day QA, parallelizable with W7 (ASP banner, separate files).

---

## 13. PR Conventions

- Branch: `ios/w5-pin-drop`
- Title: `feat(ios): W5 — pin drop + persistence (#NN)`
- Squash-merge via `gh pr merge --squash --delete-branch`
- `@qa-verifier` files `docs/qa/w5-pass-1-<date>.md`
- Open follow-ups documented in PR description per `.claude/TEAM.md`
