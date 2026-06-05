# Tier 3 Sub-PR #2 — Universal Report Entry (W8.5f)

**Status:** Revised 2026-06-05 — Kevin's product decision: NO separate Patrol mode. Reporting is universal; two context-appropriate affordances replace the prior mode-gated design.
**Supersedes:** the prior spec body in this file (same filename preserved for link stability). The old model (Patrol mode entry as a third drive-menu item + long-press = report in patrol mode) is REMOVED.
**Owner:** @ios-engineer (implementation). @tech-lead (this spec). @qa-verifier (acceptance).
**W8.5 slot:** W8.5f.
**Unblocked by:** sub-PR #1 merged (anonymous auth + `SupabaseAuthService` + `CommunityPinService.insertCrowdPin` + `upsertVote` + `callExtendPinExpiry` live in `ios/WePark/WePark/Services/CommunityPinService.swift`).
**Parallel with:** sub-PR #3 (decay display layer, W8.5g) — disjoint files; both can run simultaneously after this PR merges.

**Anchor docs:**
- `docs/tier3-patrol-mode-buildplan.md` — overall sequence; OQ-T3-1 through OQ-T3-5 Kevin-decided.
- `docs/tier3-auth-and-reactions-spec.md` — sub-PR #1 services this spec calls.
- `docs/community-1.0-direction.md §4, §6` — pin taxonomy, enforcement framing.
- `docs/typed-pin-schema-spec.md §4.3` — exact `EnforcementActiveMeta` / `SweeperPassedMeta` shapes.
- `docs/tier1-pin-display-spec.md §5` — architectural invariants (I-1 through I-4); this spec must not break them.
- `docs/cruise-mode-spec.md §5` — `enterCruiseMode()` pattern; Find Parking / Cruise Mode is UNCHANGED by this spec.
- `ios/WePark/WePark/ContentView.swift` lines 150–175 — `DriveModeStyle` enum (`.patrol` case currently declared here — disposition decided in §4.4).
- `ios/WePark/WePark/ContentView.swift` line 1727 — `handleLongPress(at:)` current implementation.
- `ios/WePark/WePark/ContentView.swift` lines 1122–1145 — `driveEntryButton` (two items; stays two items — NO third item added).

---

## Open Questions for Kevin — Resolve Before Engineering Starts

These are NEW decisions introduced by the universal-reporting reframe. Previously-decided OQs (R2 sub_tag, R3 expiry, R4 icons, R5 sweeper direction) are CARRIED FORWARD unchanged — do not re-ask.

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-NR1 | **In-drive Report button: placement and label.** Where in the drive overlay (`driveModeOverlayLayer`) does the one-tap Report button live? | **(a) Inline with "End Drive/Cruise" pill — to the right of it** (same HStack row, same visual weight as the CM-3 mute toggle). Matches the existing mute-toggle pattern exactly; no new layout layer needed. **(b) Bottom-right of the overlay**, floating above `DriveModeBottomCard`. Easier thumb reach while driving; clear separation from the exit control. **(c) Top-right**, mirroring the recenter pill position (bottom-center) but in the opposite corner. | **(a) Inline with the End pill** — it follows the established CM-3 mute-toggle pattern (same HStack, same material pill). This avoids adding a new layout layer and is the lowest-risk placement for the #31-class regression concern (no new `.overlay` stacks). If thumb-reach is a concern after Kevin's smoke, it can be moved in a polish pass. Label: `"Report"` with SF Symbol `flag.fill`. |
| OQ-NR2 | **Resting long-press menu: `confirmationDialog` or `.contextMenu`?** The resting (non-driving) long-press currently goes directly to `ParkConfirmView`. With universal reporting it needs a two-option disambiguation. | **(a) `confirmationDialog`** — SwiftUI bottom action sheet with large tap targets; appears over the map; good for two-finger reach; anchored to screen bottom. No coordinate-specific positioning. **(b) `.contextMenu` on the map overlay** — shows a small popover near the long-press point. Coordinate-positioned (visually connected to the tap point) but harder to implement on `UIViewRepresentable`. Smaller tap targets. **(c) `confirmationDialog` triggered from the existing `handleLongPress` function**, with the block coordinate captured before the dialog appears. The coordinate is passed to whichever action the user picks. | **(a) `confirmationDialog`**. Large tap targets, native iOS look, trivial to implement via a `@State var showRestingActionMenu: Bool` + `.confirmationDialog(...)` modifier. The coordinate is stored in a `@State var pendingLongPressCoord: CLLocationCoordinate2D?` while the dialog is visible. Option (b) on `UIViewRepresentable` is fragile. |
| OQ-NR3 | **Disposition of `DriveModeStyle.patrol`.** The `.patrol` case at `ContentView.swift:174` is now unused — there is no patrol mode entry path. | **(a) Remove the `.patrol` case.** Cleaner enum; `switch` exhaustiveness catches any stale reference. **(b) Keep it as a reserved/tombstoned case with an updated comment** — "reserved, not yet active; a future Tier 3 reporting-mode variant could activate this." | **(a) Remove `.patrol`**. There is no planned feature that would use it under the new universal-reporting model. The doc comment in the enum already explains the original intent; keeping a dead case creates confusion for future engineers. If a true "dedicated reporting mode" is ever specced it will be a fresh decision with a fresh enum case. Removing it triggers exhaustive `switch` compilation — any remaining reference becomes a compile error, which is the right guardrail. |

---

## 1. Problem and User Story

**Problem — the old design:** The prior spec gated reporting behind a dedicated "Patrol mode" entered from the drive-entry menu. This created two issues: (1) reporters not in patrol mode had no reporting path at all, and (2) the menu gained a third entry for a different category of action ("Report enforcement/sweeper" alongside navigation actions) — a confusing mix of intent.

**Decision — universal reporting, two affordances:** Reporting is available in every context. The gesture and UI differ by context: a menu on long-press while browsing the map (safe, no rush), and a one-tap Report button in the drive overlay while driving (safe for in-car use, no map-picking while moving).

**What does NOT change:** Cruise Mode / "Find Parking" is already shipped. The drive-entry menu stays exactly as it is ("Drive to a destination" + "Find Parking nearby"). The sub-PR #1 write path, reactions, and the Tier 1 pin display layer (pins show in all contexts) are all unchanged. This spec only adds two new UI surfaces that call `insertCrowdPin`.

---

**User story (resting — browsing the map):**
> A resident on Spring St watches the sweeping truck finish its pass and turn the corner. She long-presses the block she is standing on. A bottom action sheet appears: "Park my car here" and "Report enforcement or sweeper." She taps "Report enforcement or sweeper." The report sheet slides up. She taps "Sweeper passed" and taps "Report." Pin drops instantly — everyone parked on the block sees it within 5 seconds.

**User story (in Find Parking / Cruise Mode):**
> A driver circling Mott St in SOHO in Find Parking mode sees a uniformed enforcement officer ahead on the block. She taps the "Report" button in the drive overlay. A compact picker slides up: "Enforcement active" or "Sweeper." She taps "Enforcement active," the sub_tag picker shows — she taps "Cleaning truck" — she taps "Report." The pin drops at her current GPS. Two taps, 3 seconds. She never touched the map.

**User story (in destination Drive Mode):**
> Same as Find Parking — the "Report" button is present and behaves identically in destination Drive Mode. Pin drops at current GPS.

**Why now:** The sub-PR #1 write path is live. Without the report UI, the entire Tier 3 loop is dark. This sub-PR closes the loop.

---

## 2. Scope

### 2.1 In Scope (sub-PR #2)

- **Resting long-press → action menu (non-driving).** When `driveModeActive == false`, a long-press on the map presents a `confirmationDialog` with two actions: "Park my car here" and "Report enforcement or sweeper." Tapping "Park my car here" proceeds to `ParkConfirmView` exactly as today (W5 flow, no behavior change beyond one extra tap). Tapping "Report enforcement or sweeper" presents `ReportSheet`. The block coordinate from the long-press is passed to whichever action fires.
- **In-drive Report button (destination-mode AND Find Parking / Cruise Mode).** A "Report" button added to `driveModeOverlayLayer` when `driveModeActive == true`. Placement: inline with the End pill HStack (same row, same pattern as the CM-3 mute toggle). On tap: presents `ReportSheet` with the coordinate source set to current GPS (`locationService.userLocation`) — no map-picking while driving.
- **`ReportSheet.swift` — the report entry UI (replaces `PatrolReportSheet.swift`).** A single shared sheet for both entry paths. The coordinate is injected at presentation time (long-press coordinate for resting entry; current GPS for in-drive entry). Content: two primary rows ("Enforcement active," "Sweeper passed / approaching"), sub_tag picker for enforcement (per OQ-R2 already decided), sweeper direction toggle (per OQ-R5 already decided), "Report" CTA. Neutral copy per §6 framing.
- **New `ActiveSheet` cases:** `case reportPin(coord: CLLocationCoordinate2D)` added to the `ActiveSheet` enum. The `id` is `"reportPin-\(coord.latitude)-\(coord.longitude)"`. Resting long-press and in-drive Report button both resolve to this same case.
- **Resting action menu state:** `@State private var pendingLongPressCoord: CLLocationCoordinate2D?` holds the tapped coordinate while the `confirmationDialog` is visible. Set in `handleLongPress(at:)` when not driving; cleared on dismiss or action selection.
- **In-drive Report button guard:** the button renders only when `driveModeActive == true`. The long-press action menu renders only when `driveModeActive == false`. These two paths are mutually exclusive by the `driveModeActive` flag.
- **Marker + time-since badge:** `enforcement_active` and `sweeper_passed` pins already render via the Tier 1 display layer. This sub-PR adds the time-since badge to `PinMarkerAnnotation.configure(for:)`: a `UILabel` in the callout subtitle showing "Xm ago" (pure function, §5). Sub-PR #3 owns additional decay visuals.
- **Tap → `PinDetailSheet` wiring:** already works via Tier 1's `onCommunityPinTapped` → `ActiveSheet.pinDetail(pin)` path. Verify end-to-end in AC-R13.
- **`DriveModeStyle.patrol` removal:** the `.patrol` case in the `DriveModeStyle` enum at `ContentView.swift:174` is REMOVED (per OQ-NR3). See §4.4.
- **Mandatory live-UI smoke gate:** any PR touching `ContentView.swift` and adding `ReportSheet.swift` requires the smoke gate per §8.

### 2.2 Out of Scope (explicitly deferred)

- **NO third drive-menu item.** The `driveEntryButton` `Menu` stays exactly as shipped: "Drive to a destination" + "Find Parking nearby." Nothing is added.
- **NO Patrol mode entry.** `driveModeStyle = .patrol` is never set. The `.patrol` enum case is removed.
- **`broken_meter` and `open_spot` report types.** First cut = `enforcement_active` + `sweeper_passed` only (Kevin decision T3-1). `broken_meter` is a one-row addition to `ReportSheet` in a fast-follow; `open_spot` is sub-PR #4 (requires schema migration).
- **Decay visuals beyond the time-since badge.** Sub-PR #3 (W8.5g): opacity fade, confirm-count on the marker, `expires_at` countdown.
- **Push notification for pins near parked car.** Sub-PR #5 (W8.5i).
- **Drive Mode community callout** ("Enforcement 2 blocks ahead"). Sub-PR #6 (W8.5i). `DrivingContextService` and `DriveModeBottomCard` are NOT touched.
- **`CruiseVoicePolicy` modifications.** Unchanged.
- **Beachhead zone enforcement.** No `zone_id` guard on `insertCrowdPin` in this PR.
- **PWA changes.** PWA is in maintenance mode.

---

## 3. Architecture

### 3.1 Codebases Touched

| Codebase | Touch? | Notes |
|---|---|---|
| `ios/WePark/WePark/` | Yes | New `ReportSheet.swift`; modified `ContentView.swift`, `PinMarkerAnnotation.swift` |
| `ios/WePark/WeParkTests/` | Yes | New tests for `ReportSheet` + pure functions + resting menu routing |
| `supabase/` | No | All DB infra is live from sub-PR #1 |
| `index.html` (PWA) | No | Maintenance mode |
| `docs/` | This spec | Only this file |

### 3.2 New Files

```
ios/WePark/WePark/Views/ReportSheet.swift
    — The report entry UI sheet (both entry paths converge here).
    — Presented via ActiveSheet.reportPin(coord: CLLocationCoordinate2D).
    — Calls CommunityPinService.insertCrowdPin via the mapping in §6.
    — @ios-engineer implements; interface sketch in §3.4.

ios/WePark/WeParkTests/ReportSheetTests.swift
    — Unit tests for the report sheet + write-path args + pure functions.
    — @ios-engineer implements; AC table in §8 drives the test inventory.
```

### 3.3 Modified Files

```
ios/WePark/WePark/ContentView.swift
    — Remove ActiveSheet.patrolReport case (was never shipped; remove the reservation).
    — Add ActiveSheet.reportPin(coord: CLLocationCoordinate2D) case.
    — Add @State var pendingLongPressCoord: CLLocationCoordinate2D?
    — Modify handleLongPress(at:): when driveModeActive == false, set
      pendingLongPressCoord = coordinate and trigger the confirmationDialog
      instead of going directly to .parkConfirm. When driveModeActive == true,
      long-press does NOTHING (in-drive long-press is intentionally suppressed;
      the Report button is the driving-safe path).
    — Add .confirmationDialog(..., isPresented: $showRestingActionMenu) on the
      map layer. Two actions: "Park my car here" → proceeds to .parkConfirm(intent);
      "Report enforcement or sweeper" → activeSheet = .reportPin(coord: pendingLongPressCoord).
    — Add "Report" button to driveModeOverlayLayer HStack (inline with End pill, per OQ-NR1
      resolved). Visible only when driveModeActive == true. On tap:
      guard let loc = locationService.userLocation else { return }
      activeSheet = .reportPin(coord: loc.coordinate)
    — Add sheetContent case for .reportPin — presents ReportSheet.
    — Remove DriveModeStyle.patrol case (per OQ-NR3 resolved).
    — No change to driveEntryButton (stays two items).
    — No change to enterCruiseMode() or endDriveMode().

ios/WePark/WePark/Views/PinMarkerAnnotation.swift
    — In configure(for pin:): when pin.pinType is .enforcementActive or .sweeperPassed,
      set callout subtitle to timeSinceBadge(pin:now:) pure function (§5).
    — Add timeSinceBadge(pin: CommunityPin, now: Date) -> String pure function.
```

### 3.4 `ReportSheet` Interface Sketch

```swift
// ios/WePark/WePark/Views/ReportSheet.swift
// @ios-engineer implements; sketch only. Not production code.

struct ReportSheet: View {

    // The coordinate at which the pin will be dropped.
    // Resting path: the long-press coordinate on the map.
    // In-drive path: the user's current GPS at the moment Report was tapped.
    let coordinate: CLLocationCoordinate2D
    let pinService: CommunityPinService
    let authService: SupabaseAuthService
    let onDismiss: () -> Void

    @State private var selectedType: ReportType? = nil
    @State private var selectedSubTag: EnforcementSubTag? = nil  // nil = "Not sure"
    @State private var sweeperDirection: SweeperDirection = .passed
    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    enum ReportType {
        case enforcementActive
        case sweeperPassed      // direction stored in sweeperDirection
    }

    enum SweeperDirection {
        case passed         // SweeperPassedMeta.direction = "passed"
        case comingSoon     // SweeperPassedMeta.direction = "coming_soon"
    }

    enum EnforcementSubTag {
        case cleaningTruck  // listed first per community-1.0-direction.md §6
        case parkingAgent
        case towTruck
        // nil maps to sub_tag = nil ("Not sure" / no selection)
    }

    var body: some View {
        // Primary type selection rows (two 44pt-minimum tap targets).
        // Sub_tag picker row: appears when selectedType == .enforcementActive.
        //   Pills: "Cleaning truck" (first), "Parking agent", "Tow truck", "Not sure".
        //   Default: none selected (sub_tag = nil).
        // Sweeper direction toggle: appears when selectedType == .sweeperPassed.
        //   Segmented or pill: "Sweeper passed" | "Sweeper approaching".
        // "Report" CTA: disabled when selectedType == nil.
        // Inline error display below CTA.
        // Compliance copy: no "avoid / ticket / fine / evasion / dodge" language.
    }

    private func submitReport() async {
        guard let type = selectedType else { return }
        isSubmitting = true
        submitError = nil
        do {
            let (pinType, meta) = buildMeta(type: type)
            try await pinService.insertCrowdPin(
                type: pinType,
                meta: meta,
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                segmentId: nil,
                zoneId: nil,
                notes: nil
            )
            onDismiss()
        } catch {
            submitError = "Couldn't submit. Check your connection and try again."
        }
        isSubmitting = false
    }

    private func buildMeta(type: ReportType) -> (PinType, PinMeta?) {
        switch type {
        case .enforcementActive:
            return (.enforcementActive, .enforcementActive(EnforcementActiveMeta(subTag: selectedSubTag?.rawValue)))
        case .sweeperPassed:
            let direction = sweeperDirection == .passed ? "passed" : "coming_soon"
            return (.sweeperPassed, .sweeperPassed(SweeperPassedMeta(direction: direction)))
        }
    }
}
```

### 3.5 Data Flow: Resting Report → Pin on Map

```
[User long-presses map while driveModeActive == false]
        │
        ▼ ContentView.handleLongPress(at: coordinate)
        │   driveModeActive == false:
        │   pendingLongPressCoord = coordinate
        │   showRestingActionMenu = true
        ▼
[confirmationDialog presents]
        │
        ├─ "Park my car here" → existing W5 flow (ParkConfirmView) — NO CHANGE
        │
        └─ "Report enforcement or sweeper"
                │  activeSheet = .reportPin(coord: pendingLongPressCoord!)
                ▼
[ReportSheet presented]
        │  User selects type + optional sub_tag
        │  Taps "Report"
        ▼
[ReportSheet.submitReport()]
        │   CommunityPinService.insertCrowdPin(type:meta:lat:lng:segmentId:nil:zoneId:nil:notes:nil)
        │   → POST /rest/v1/pins  Authorization: Bearer <anon-jwt>
        │   → RLS pins_insert_crowd passes
        │   → Supabase sets expires_at = now() + 30 min
        ▼
[Realtime INSERT → all clients' visiblePins → .onChange → MKAnnotation added]
```

### 3.6 Data Flow: In-Drive Report → Pin at Current GPS

```
[User taps "Report" button in driveModeOverlayLayer while driveModeActive == true]
        │
        ▼ guard let loc = locationService.userLocation else { return }
        │   activeSheet = .reportPin(coord: loc.coordinate)
        ▼
[ReportSheet presented — same sheet, same flow]
        │
        │   coordinate == user's GPS at time of tap (NOT a map tap point)
        │   No segment detection, no map-picking, no gesture on the live map
        ▼
[submitReport() → insertCrowdPin → Realtime → all maps updated]
```

---

## 4. ContentView Modifications Detail

### 4.1 `handleLongPress(at:)` — Revised Logic

The current implementation at `ContentView.swift:1727` goes directly to `ParkConfirmView` unconditionally. The revision adds a two-branch top guard:

```swift
// Sketch — ContentView.swift handleLongPress(at:) modification
private func handleLongPress(at coordinate: CLLocationCoordinate2D) {
    selectedSegmentID = nil
    activeSheet = nil

    // While driving, long-press does nothing — the Report button in the overlay
    // is the driving-safe entry path. Suppressing the gesture avoids accidental
    // park-pin drops while maneuvering.
    guard !driveModeActive else { return }

    // Resting: capture coordinate and show the action menu.
    pendingLongPressCoord = coordinate
    showRestingActionMenu = true
    // The confirmationDialog fires from the .confirmationDialog modifier wired
    // to showRestingActionMenu. Action handlers are in the confirmationDialog body.
    // "Park my car here" proceeds to the existing W5 .parkConfirm flow.
    // "Report enforcement or sweeper" sets activeSheet = .reportPin(coord:).
}
```

The W5 segment detection logic (`findCandidateSegments` + `PinDropIntent` construction) moves into the "Park my car here" action handler inside the `confirmationDialog`. It is not called before the menu appears — no wasted work if the user picks "Report."

### 4.2 `confirmationDialog` — Action Sheet

```swift
// Sketch — .confirmationDialog modifier on the map layer or ContentView body
.confirmationDialog(
    "What do you want to do?",
    isPresented: $showRestingActionMenu,
    titleVisibility: .visible
) {
    Button("Park my car here") {
        guard let coord = pendingLongPressCoord else { return }
        // Run the W5 candidate detection and present ParkConfirmView.
        let candidates = findCandidateSegments(lat: coord.latitude, lng: coord.longitude, ...)
        let intent = PinDropIntent(pinLat: coord.latitude, pinLng: coord.longitude, ...)
        activeSheet = .parkConfirm(intent)
        pendingLongPressCoord = nil
    }
    Button("Report enforcement or sweeper") {
        guard let coord = pendingLongPressCoord else { return }
        activeSheet = .reportPin(coord: coord)
        pendingLongPressCoord = nil
    }
    Button("Cancel", role: .cancel) {
        pendingLongPressCoord = nil
    }
}
```

### 4.3 In-Drive Report Button — `driveModeOverlayLayer`

The existing `driveModeOverlayLayer` `HStack` at `ContentView.swift:1170–1205` contains: the End pill (left) + the CM-3 mute toggle (when `.cruise`) + `Spacer()`. The Report button is inserted between the mute toggle position and the Spacer:

```swift
// Sketch — inside driveModeOverlayLayer HStack, after the mute toggle block:
if driveModeActive {
    Button {
        guard let loc = locationService.userLocation else { return }
        activeSheet = .reportPin(coord: loc.coordinate)
    } label: {
        Image(systemName: "flag.fill")
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Color.orange)
    }
    .accessibilityLabel("Report enforcement or sweeper")
    .accessibilityHint("Drops a pin at your current location. Takes two taps: report type, then Report.")
}
```

The `guard let loc = locationService.userLocation` means the button silently no-ops if GPS is not yet available. This is the correct behavior (if location is unavailable we cannot drop a pinned report). Consider whether to show a brief toast ("Location unavailable — try again") — leave to engineer's discretion, not an AC requirement.

The button is always rendered when `driveModeActive == true`, regardless of whether `driveModeStyle` is `.destination` or `.cruise`. The mute toggle (`.cruise` only) and this button can coexist in the same HStack.

### 4.4 `DriveModeStyle.patrol` Removal

The `.patrol` case at `ContentView.swift:163–175` is REMOVED. The removal:

1. Delete the case declaration.
2. Update the doc comment above `DriveModeStyle` to remove the patrol-mode convergence note (lines 158–162 referencing `tier3-patrol-mode-buildplan.md sub-PR #2`).
3. The existing `switch driveModeStyle` in `driveModeOverlayLayer` at line 1175 (`driveModeStyle == .cruise ? "End Cruise" : "End Drive"`) is a ternary, not a `switch` — no exhaustiveness issue there. Search the codebase for any `case .patrol` references and remove them.
4. If there are any `// TODO: patrol` comments in `ContentView.swift`, remove them.

This is a compile-forced cleanup: after removing the case, any stale `.patrol` reference becomes a compiler error, making the removal auditable.

---

## 5. Time-Since Badge (Pure Function, T3-3 Decision)

No change from the prior spec. This section is unchanged.

The badge appears in the `MKAnnotation` callout subtitle when a Tier 3 pin is tapped. It is a pure function of pin age, computed lazily at callout-open time. No timer loop; no periodic redraw.

**Function signature:**

```swift
// Added to PinMarkerAnnotation.swift or CommunityPin+Display.swift.
// @ios-engineer implements.
static func timeSinceBadge(pin: CommunityPin, now: Date) -> String {
    let ageSeconds = now.timeIntervalSince(pin.createdAt)
    let minutes = Int(ageSeconds / 60)
    switch minutes {
    case 0:          return "Just now"
    case 1..<60:     return "\(minutes)m ago"
    case 60..<120:   return "1h ago"
    default:         return "\(minutes / 60)h ago"
    }
}
```

`now: Date` is injected for testability. In the live callout, caller passes `Date()`. In tests, pass a fixed fixture.

No `Calendar.current` usage. Pure `timeIntervalSince` arithmetic only, consistent with the W3 convention.

---

## 6. Type-to-Meta Mapping (Report Sheet → `insertCrowdPin` Args)

This is the write-call contract. The engineer must implement these mappings exactly.

| User selection | `type` arg | `meta` arg | `lifespan` | `source` | `expires_at` |
|---|---|---|---|---|---|
| "Enforcement active" (no sub_tag) | `.enforcementActive` | `.enforcementActive(EnforcementActiveMeta(subTag: nil))` | `"ephemeral"` | `"crowd"` | `now + 30 min` |
| "Enforcement active" + "Cleaning truck" | `.enforcementActive` | `.enforcementActive(EnforcementActiveMeta(subTag: .cleaningTruck))` | `"ephemeral"` | `"crowd"` | `now + 30 min` |
| "Enforcement active" + "Parking agent" | `.enforcementActive` | `.enforcementActive(EnforcementActiveMeta(subTag: .parkingAgent))` | `"ephemeral"` | `"crowd"` | `now + 30 min` |
| "Enforcement active" + "Tow truck" | `.enforcementActive` | `.enforcementActive(EnforcementActiveMeta(subTag: .towTruck))` | `"ephemeral"` | `"crowd"` | `now + 30 min` |
| "Sweeper passed" | `.sweeperPassed` | `.sweeperPassed(SweeperPassedMeta(direction: "passed"))` | `"ephemeral"` | `"crowd"` | `now + 30 min` |
| "Sweeper approaching" | `.sweeperPassed` | `.sweeperPassed(SweeperPassedMeta(direction: "coming_soon"))` | `"ephemeral"` | `"crowd"` | `now + 30 min` |

Notes:
- `lifespan`, `source`, and `expires_at` are set inside `CommunityPinService.insertCrowdPin` (from `tier3-auth-and-reactions-spec.md §3.9`). `ReportSheet` passes only `type:`, `meta:`, `lat:`, `lng:`, `segmentId:nil`, `zoneId:nil`, `notes:nil`.
- `author_id` is set from `authService.currentUserId` inside `insertCrowdPin`.
- **Resting path:** `lat`/`lng` come from the long-press coordinate on the map — the block the user tapped.
- **In-drive path:** `lat`/`lng` come from `locationService.userLocation.coordinate` at the moment the user tapped the Report button. No segment detection; `segmentId` is nil for both paths.

---

## 7. Work Streams

Two streams within sub-PR #2. Disjoint file sets; can run simultaneously but share the same PR branch. A single engineer should do both in sequence (Stream A first because Stream B needs the `reportPin` `ActiveSheet` case to compile).

| Stream | Owner | Files | Dependencies | Notes |
|---|---|---|---|---|
| **A — ContentView wiring** | @ios-engineer | `ContentView.swift` (`ActiveSheet.reportPin` case + `pendingLongPressCoord` state + `showRestingActionMenu` state + modified `handleLongPress` + `confirmationDialog` modifier + Report button in `driveModeOverlayLayer` + `DriveModeStyle.patrol` removal) | Kevin OQ-NR1, OQ-NR2, OQ-NR3 answers | No direct interaction with `CommunityPinService`; coordinates the two entry paths |
| **B — ReportSheet + badge** | @ios-engineer | `ReportSheet.swift` (new), `PinMarkerAnnotation.swift` (time-since badge), `ReportSheetTests.swift` (new) | Stream A (needs `ActiveSheet.reportPin` to compile the `sheetContent` switch) | Calls `insertCrowdPin` from sub-PR #1 |

---

## 8. Acceptance Criteria

All ACs verified by @qa-verifier independently. @qa-verifier is not the same agent that built the feature.

### Resting Long-Press → Action Menu

- [ ] **AC-R1.** While `driveModeActive == false`, long-pressing the map presents a `confirmationDialog` (not `ParkConfirmView` directly). The dialog has exactly two action buttons: "Park my car here" and "Report enforcement or sweeper." Verified by a unit test mocking `handleLongPress(at:)` with `driveModeActive == false` and asserting `showRestingActionMenu == true`.
- [ ] **AC-R2.** Tapping "Park my car here" in the dialog presents `ActiveSheet.parkConfirm(PinDropIntent)`. The `PinDropIntent` is built from the coordinate of the original long-press (not a different coordinate). Verified by unit test asserting `activeSheet == .parkConfirm(...)` with matching `pinLat`/`pinLng`.
- [ ] **AC-R3.** Tapping "Report enforcement or sweeper" in the dialog presents `ActiveSheet.reportPin(coord:)` with the coordinate of the original long-press. Verified by unit test asserting `activeSheet == .reportPin(coord: <expected>)`.
- [ ] **AC-R4.** Tapping "Cancel" dismisses the dialog. `activeSheet` remains nil. `pendingLongPressCoord` is cleared to nil. Verified by code review.
- [ ] **AC-R5.** While `driveModeActive == true`, long-pressing the map does NOTHING. `showRestingActionMenu` is not set, `activeSheet` is not changed. Verified by a unit test with `driveModeActive == true` asserting both state vars are unchanged after `handleLongPress(at:)`.
- [ ] **AC-R6.** The W5 `ParkConfirmView` behavior is functionally unchanged for the resting path. The only difference is one extra tap (action menu → "Park my car here" → `ParkConfirmView`). The `PinDropIntent` construction (haversine segment detection, "Wrong street?" alternatives) is identical to the prior implementation. Verified by `git diff` inspection showing the detection logic moved into the "Park my car here" handler, not rewritten.

### In-Drive Report Button

- [ ] **AC-R7.** While `driveModeActive == true`, the Report button (`flag.fill`, orange) is visible in the drive overlay HStack. Verified by code review confirming the button renders in `driveModeOverlayLayer` when `driveModeActive == true`.
- [ ] **AC-R8.** Tapping the Report button presents `ActiveSheet.reportPin(coord:)` with `coord == locationService.userLocation.coordinate` at the moment of tap. Verified by a unit test that sets a mock location and asserts the coordinate in the presented sheet matches.
- [ ] **AC-R9.** While `driveModeActive == false` (resting map), the Report button is NOT rendered. Verified by code review of the `if driveModeActive` guard wrapping the button.
- [ ] **AC-R10.** The Report button renders in BOTH `driveModeStyle == .destination` and `driveModeStyle == .cruise`. The `driveModeActive` guard is the only gate — there is no `driveModeStyle` gate. Verified by code review.
- [ ] **AC-R11.** If `locationService.userLocation == nil` (GPS not yet available), tapping the Report button is a no-op (silent guard). The `activeSheet` is not changed. No crash. Verified by unit test with `userLocation = nil`.
- [ ] **AC-R12.** The End Drive/Cruise pill label is unchanged: `.cruise ? "End Cruise" : "End Drive"`. No "End Patrol" case. Verified by code review of the ternary / label expression.

### Report Sheet — Content and Behavior

- [ ] **AC-R13.** `ReportSheet` presents two primary type rows: "Enforcement active" and "Sweeper passed." Verified by UI test or code review.
- [ ] **AC-R14.** Tapping "Enforcement active" reveals the sub_tag picker row. The picker has four options: "Cleaning truck" (listed first), "Parking agent", "Tow truck", "Not sure." Default selection is none (sub_tag = nil). Verified by code review of the picker state binding.
- [ ] **AC-R15.** "Sweeper passed" and "Sweeper approaching" are both available (per OQ-R5). Selecting "Sweeper approaching" sets `SweeperPassedMeta.direction = "coming_soon"` in the insert payload. Verified by request-body inspection in a unit test.
- [ ] **AC-R16.** The "Report" CTA is disabled when no primary type is selected. It is enabled as soon as any primary type is tapped. Sub_tag is optional and does not gate the CTA. Verified by a unit test asserting `isReportEnabled` state.
- [ ] **AC-R17 (copy compliance).** The report sheet contains no text matching "avoid," "ticket," "fine," "evasion," or "dodge." Verified by `grep -ri "avoid\|ticket\|fine\|evasion\|dodge" ReportSheet.swift` returning zero results.

### Write Path — `insertCrowdPin` Call

- [ ] **AC-R18.** Submitting "Enforcement active" + "Cleaning truck" (resting path, long-press coord) calls `insertCrowdPin(type: .enforcementActive, meta: .enforcementActive(EnforcementActiveMeta(subTag: .cleaningTruck)), lat: <long-press-lat>, lng: <long-press-lng>, segmentId: nil, zoneId: nil, notes: nil)`. Verified by a mock `CommunityPinService` capturing args.
- [ ] **AC-R19.** Submitting "Enforcement active" (in-drive path, GPS coord) calls `insertCrowdPin` with `lat`/`lng` from `locationService.userLocation.coordinate`, NOT from a map tap point. Verified by a unit test injecting a distinct mock GPS location and asserting the args match.
- [ ] **AC-R20.** Submitting "Sweeper passed" calls `insertCrowdPin(type: .sweeperPassed, meta: .sweeperPassed(SweeperPassedMeta(direction: "passed")), ...)`. Verified similarly.
- [ ] **AC-R21.** Submitting "Sweeper approaching" calls `insertCrowdPin(..., meta: .sweeperPassed(SweeperPassedMeta(direction: "coming_soon")), ...)`. Verified similarly.
- [ ] **AC-R22.** While the insert is in-flight (`isSubmitting == true`), the "Report" button shows a `ProgressView` and is disabled to prevent double-submit. Verified by code review.
- [ ] **AC-R23.** On insert success, the sheet dismisses. On insert error, an inline error string appears and the sheet stays open (user can retry without losing their selection). Verified by unit tests with a mock that throws once and succeeds on retry.
- [ ] **AC-R24 (end-to-end).** An `enforcement_active` pin inserted via the Report sheet appears on a second client's map within 5 seconds (Realtime delivery). Verified manually by Kevin (two simultaneous simulator sessions or two devices).

### Time-Since Badge

- [ ] **AC-R25.** `timeSinceBadge(pin:now:)` returns `"Just now"` when `now - pin.createdAt < 60s`. Unit test.
- [ ] **AC-R26.** `timeSinceBadge(pin:now:)` returns `"5m ago"` when `now - pin.createdAt == 300s`. Unit test.
- [ ] **AC-R27.** `timeSinceBadge(pin:now:)` returns `"1h ago"` when `now - pin.createdAt == 3600s`. Unit test.
- [ ] **AC-R28.** `timeSinceBadge` contains no `Calendar.current` or `Calendar.easternTime` usage. Pure `timeIntervalSince` arithmetic only. Verified by `grep -n "Calendar" PinMarkerAnnotation.swift` returning zero new results.
- [ ] **AC-R29.** Tapping an `enforcement_active` pin on the map opens `PinDetailSheet` with the `ReactionsRow` ("Still there?" + "Gone" + confirm-count). Wiring is unchanged from sub-PR #1. Verified end-to-end: insert pin via the report sheet, tap it, confirm both reaction buttons appear.

### `DriveModeStyle.patrol` Removal

- [ ] **AC-R30.** `DriveModeStyle.patrol` case does NOT exist in the merged PR. Verified by `grep -rn "case patrol" ios/WePark/WePark/` returning zero results.
- [ ] **AC-R31.** `grep -rn "\.patrol" ios/WePark/WePark/` returns zero results. No stale reference to the removed case. Verified as part of the PR diff.
- [ ] **AC-R32.** The `driveModeStyle == .cruise ? "End Cruise" : "End Drive"` ternary in `driveModeOverlayLayer` (or its equivalent expression) produces correct labels for `.inactive`, `.destination`, and `.cruise`. There is NO "End Patrol" label path. Verified by code review.

### Architecture Invariants

- [ ] **AC-R33.** No new `setRegion` calls anywhere in the PR diff. `RegionSyncGuardTests` (2 tests) pass unchanged.
- [ ] **AC-R34.** No mutation of UIKit state inside `MapViewRepresentable.updateUIView`. All annotation updates triggered by `.onChange(of: communityPins)`.
- [ ] **AC-R35.** No `headlessWindow` guard in any new or modified production code. Verified by `grep -rn "headlessWindow" ios/WePark/WePark/` returning zero results.
- [ ] **AC-R36.** `CommunityPin.swift` is NOT modified. Frozen model contract from PR #36 holds.
- [ ] **AC-R37.** `CruiseVoicePolicy.swift`, `DrivingContextService.swift`, `FinalApproachService.swift` are NOT modified.
- [ ] **AC-R38.** `driveEntryButton` Menu in `ContentView.swift` still has exactly TWO items: "Drive to a destination" and "Find Parking nearby." No third item. Verified by `grep -A 20 "private var driveEntryButton"` showing the Menu block.

### Live-UI Smoke Gate (MANDATORY)

- [ ] **AC-R39.** Before the PR is opened: engineer builds and launches the app in Simulator, captures a screenshot via `xcrun simctl io booted screenshot /tmp/tier3-universal-report-smoke.png`, reads the screenshot using the Read tool (multimodal). Screenshot confirms: (a) ASP banner renders at the top, (b) toolbar cluster (gear / find-me / find-car / clock / drive-entry button) is fully visible, (c) no overlay elements are dropped, (d) `DriveModeBottomCard` is NOT visible in the idle (non-driving) state, (e) the long-press action menu can be triggered and presents the two-option dialog. This gate is MANDATORY before the PR is opened. @qa-verifier repeats independently.
- [ ] **AC-R40.** With `driveModeActive == true` (Cruise Mode entered): the Report button (`flag.fill`, orange) is visible in the overlay HStack alongside the "End Cruise" pill. Screenshot confirms the button renders without dropping other overlay elements. Verified by engineer before PR open.

---

## 9. Open Decisions — `@designer` Input

These are deferred design details. Engineering uses placeholder values; resolve before Kevin's manual smoke.

1. **Icon for `enforcement_active` marker.** Placeholder: `shield.fill` (blue). `@designer` to confirm this reads as "civic authority" per `community-1.0-direction.md §6` (no cop cartoons).
2. **Icon for `sweeper_passed` marker.** Placeholder: `exclamationmark.triangle.fill` (orange) or `truck.box.fill` if available on iOS 17 min target. `@designer` to confirm and check iOS 17 symbol availability.
3. **Report button icon.** Placeholder: `flag.fill` (orange). This icon appears in the in-drive overlay. `@designer` to confirm legibility and orange-on-material contrast at drive speed.
4. **Sub_tag picker visual treatment.** Horizontal pill row or vertical list? HIG-minimum 44pt tap targets required either way.
5. **Time-since badge position.** Callout subtitle (current spec) or a small overlaid label on `MKAnnotationView` itself? Subtitle approach is lower risk; `@designer` to decide. Engineering defaults to subtitle.

---

## 10. Out-of-Scope Follow-Ups

**Decay display layer.** Sub-PR #3 (W8.5g). Opacity fade, confirm-count badge on the marker, `expires_at` countdown in the callout. The `timeSinceBadge` pure function in this spec is the only decay signal in sub-PR #2.

**`broken_meter` reporting.** One additional primary row in `ReportSheet` and one new mapping in the §6 table. Can be added in a standalone fast-follow PR after sub-PR #2 merges. No schema migration needed (`.brokenMeter` already exists in the `pin_type` enum). `BrokenMeterMeta` is durable-lifespan, not ephemeral — the `insertCrowdPin` TTL logic will need a `case .brokenMeter: return nil` in the `expiresAt` switch.

**`open_spot` reporting.** Sub-PR #4. Requires `ALTER TYPE public.pin_type ADD VALUE 'open_spot'` DDL migration, iOS `PinType.openSpot` enum case, 3-minute TTL, and a claim mechanic. This report type may or may not appear in `ReportSheet` — that is sub-PR #4's spec decision.

**Drive Mode community callout.** When an `enforcement_active` pin is within 200m of the user's location during Drive Mode, a chip on `DriveModeBottomCard` fires: "Enforcement 2 blocks ahead." Sub-PR #6 (`docs/tier3-drive-callout-spec.md`). `DriveModeBottomCard.swift` is NOT touched by this sub-PR.

**Relevance-gated push.** "Enforcement near your car on [block]." Sub-PR #5 (`docs/tier3-push-alerts-spec.md`). `NotificationScheduler.swift` is NOT touched.

**SOHO/LES beachhead zone filter.** A server-side `zone_id` validation on `insertCrowdPin` rejecting reports outside SOHO/LES. Deferred to sub-PR #4 per `docs/tier3-auth-and-reactions-spec.md §8` note 4. iOS passes `zoneId: nil` in this PR.

**Patrol-mode route sweep.** A greedy-graph guided sweep routing the user through unvisited blocks is out of scope indefinitely under the new universal-reporting model. If Kevin ever wants a dedicated "report patrol" mode it will be a new spec, not a resurrection of the removed `.patrol` enum case.
