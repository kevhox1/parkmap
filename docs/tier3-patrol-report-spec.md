# Tier 3 Sub-PR #2 — Patrol Report UI (W8.5f)

**Status:** Ready for dispatch after Kevin resolves the OQ table below. Date: 2026-06-05.
**Owner:** @ios-engineer (implementation). @tech-lead (this spec). @qa-verifier (acceptance).
**W8.5 slot:** W8.5f.
**Unblocked by:** sub-PR #1 merged (anonymous auth + `SupabaseAuthService` + `CommunityPinService.insertCrowdPin` + `upsertVote` + `callExtendPinExpiry` — these methods exist in `ios/WePark/WePark/Services/CommunityPinService.swift`).
**Parallel with:** sub-PR #3 (decay display layer, W8.5g) — disjoint files; both can run simultaneously after this PR merges.
**Anchor docs:**
- `docs/tier3-patrol-mode-buildplan.md` — sequence and OQ approvals (OQ-T3-1 through OQ-T3-5, all Kevin-decided).
- `docs/tier3-auth-and-reactions-spec.md` — the sub-PR #1 services this spec calls.
- `docs/community-1.0-direction.md §4, §6` — pin taxonomy, enforcement framing decision.
- `docs/typed-pin-schema-spec.md §4.3` — exact `EnforcementActiveMeta` / `SweeperPassedMeta` shapes.
- `docs/tier1-pin-display-spec.md §5` — architectural invariants (I-1 through I-4); this spec must not break them.
- `docs/cruise-mode-spec.md §5, §8` — `DriveModeStyle.patrol` reservation, `enterCruiseMode()` pattern.
- `ios/WePark/WePark/ContentView.swift` lines 150–175 — `DriveModeStyle` enum with `.patrol` already declared; line 1727 — `handleLongPress(at:)` current implementation.
- `ios/WePark/WePark/Views/MapViewRepresentable.swift` line 1300 — `handleLongPress` gesture recognizer.

---

## Open Questions for Kevin — Resolve Before Engineering Starts

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-R1 | **Long-press reconciliation approach: action sheet vs. mode-aware routing?** | **(a) Mode-aware routing:** When `driveModeStyle == .patrol`, long-press goes straight to the patrol report sheet. When `driveModeStyle` is `.inactive` / `.destination` / `.cruise`, long-press goes to `ParkConfirmView` as today. No action sheet, no disambiguation UI — the current mode determines the gesture intent. **(b) Always-on action sheet:** Long-press always presents a 3-button action sheet ("Park my car here" / "Report enforcement/sweeper" / "Cancel") regardless of mode. Works anywhere on the map, not just in patrol mode. **(c) Always-on action sheet, but only when patrol mode is NOT active:** Long-press in patrol mode goes directly to the report sheet (fast path). Outside patrol mode, long-press goes directly to ParkConfirmView as today. Action sheet is never shown. | **(a) Mode-aware routing.** The action sheet (option b) is a friction point on the park-my-car flow — the W5 long-press-to-park flow is the highest-frequency gesture in the app, and adding a disambiguation tap to it on every use is a poor trade for a feature that is only relevant when the user is actively looking for patrol mode. Mode-aware routing preserves zero extra taps for the majority case. The user opts into patrol mode explicitly before they report; the mode change is the intent signal. Consistent with how Cruise Mode works (the entry mode governs behavior, not a per-gesture picker). Option (c) is reasonable but still breaks the all-outside-patrol-mode case. Recommend (a). |
| OQ-R2 | **Sub_tag picker: optional picker in the report sheet or default to nil?** | **(a) Optional picker in the report sheet:** After choosing "Enforcement active," the user sees a secondary row with three pills: "Parking agent" / "Cleaning truck" / "Tow truck" (or "Skip"). Default selection is none (sub_tag = nil). **(b) Default nil, no picker in TF1:** The report sheet does NOT show sub_tag. All `enforcement_active` reports write `sub_tag: nil`. A sub_tag picker can be added in a TF2 polish pass. **(c) Cleaning-truck-first, one-tap:** The picker defaults to "Cleaning truck" (selected) because `community-1.0-direction.md §6` says "cleaning-truck use leads." User taps once to confirm or changes to a different sub_tag. | **(a) Optional picker.** The sub_tag is architecturally present in `EnforcementActiveMeta` and it is the compliance-framing lever — a "Cleaning truck" pin reads completely differently from a "Parking agent" pin to a user who needs to decide whether to move their car. The picker is a two-second addition to the report sheet that materially affects the signal quality. Implement it as a horizontal pill row (three options + no-selection default "Not sure"). Cleaning truck is listed first per the §6 framing note. The picker is optional — the user can submit without selecting a sub_tag. |
| OQ-R3 | **Default expiry for `enforcement_active` and `sweeper_passed`: confirm 30 minutes?** | `typed-pin-schema-spec.md §8` says `ephemeral` defaults to `now() + 30 minutes`. `tier3-auth-and-reactions-spec.md §3.9` sketch uses 30 minutes. Is 30 minutes the right default for both types, or should `sweeper_passed` be shorter (sweeper-passed info ages faster — once the truck passes a block it's valid for less time than an enforcement agent who may stay for an hour)? **(a) 30 min for both.** Consistent, simple, already in the spec and schema. **(b) 30 min for `enforcement_active`, 15 min for `sweeper_passed`.** Sweeper information has a shorter real-world relevance window. | **(a) 30 min for both.** Consistency and simplicity for TF1. The "Still there?" confirm mechanic already handles early removal via disputes. Sweeper-passed information is useful for the full 30 minutes (anyone circling the block in the next 30 minutes benefits from knowing the sweeper already passed). The 02e auto-resolve trigger and the "Gone" dispute path handle early invalidation. Differentiated TTLs add code complexity for marginal signal gain. |
| OQ-R4 | **`enforcement_active` marker icon: SF Symbol choice?** | The existing Tier 1 map markers use `video.fill` (filming) and `star.fill` (special event). `enforcement_active` needs a distinct icon that reads as "heads up, government presence" without being an officer cartoon. Options: **(a) `exclamationmark.triangle.fill`** — generic warning, widely understood. **(b) `car.rear.road.lane.dashed`** — evokes parking context. **(c) `eyes.inverse`** — evokes "being watched," unusual. **(d) `shield.fill`** — civic/authority, clean. | **Defer to @designer with a recommendation of `(d) shield.fill`** for `enforcement_active` and `(a) exclamationmark.triangle.fill` for `sweeper_passed` (or `truck.box.fill` / `snowplow.fill` if available on iOS 17 min target). The compliance framing (`community-1.0-direction.md §6`) favors a neutral civic icon over a warning icon; `shield.fill` is the most neutral authority indicator in SF Symbols. @designer should verify these read well at 32×32pt on `.mutedStandard` map style before engineering starts. Engineer uses `shield.fill` as a placeholder if @designer review is not available before dispatch. |
| OQ-R5 | **`sweeper_passed` vs. "sweeper coming soon": one type or a `direction` flag?** | `typed-pin-schema-spec.md §4.3` already defines `SweeperPassedMeta.direction: 'passed' \| 'coming_soon' \| null`. The question is whether the TF1 report UI exposes both values or only `passed`. **(a) Report sheet offers both "Sweeper passed" and "Coming soon" as separate report options.** They write the same `pin_type = 'sweeper_passed'` but with different `direction` values in meta. **(b) Report sheet offers only "Sweeper passed" (direction = 'passed'). "Coming soon" is deferred to TF2.** Rationale: "passed" is the high-value signal (the block is now safe). "Coming soon" is lower value (users should know from the schedule); also harder to time correctly. | **(a) Both, but "Sweeper passed" listed first.** The schema supports both; the UI is one additional row in the report sheet. "Coming soon" is a real signal — if a user sees the sweeper about to turn onto a block, that warning is extremely high value for anyone parked there. Both map to the same write path (`insertCrowdPin` with `SweeperPassedMeta`). The display label for `direction == 'coming_soon'` is "Sweeper approaching" (present tense, immediate). The report sheet label is "Sweeper approaching" so reporters choose based on what they actually see, not after-the-fact. |

---

## 1. Problem and User Story

**Problem:** The sub-PR #1 write path exists (`CommunityPinService.insertCrowdPin`, `SupabaseAuthService`) and the Tier 1 display layer renders community pins on the map. But there is no UI surface that lets a user create a Tier 3 pin. A person who sees a parking enforcement agent or a street sweeper has no way to report it. The data path is built; the report surface is the missing piece.

The secondary problem is a gesture conflict: W5 already owns the long-press gesture (`MapViewRepresentable.swift:1300` — `UILongPressGestureRecognizer` at 0.4s, calls `ContentView.handleLongPress(at:)` which goes to `ParkConfirmView`). This spec must specify exactly how patrol report entry coexists with the W5 park-my-car gesture without breaking either.

**User story (enforcement report):**
> A driver cruising for parking on Mott St in SOHO sees a uniformed enforcement officer writing tickets on the block ahead. She is already in patrol mode ("Find Parking"). She long-presses on the map at the block. The patrol report sheet comes up immediately — no disambiguation. She taps "Enforcement active," taps "Cleaning truck" as the sub_tag, and taps "Report." A shield pin appears instantly on every other WePark user's map. She stays in patrol mode; the map remains head-up. Two taps and 3 seconds.

**User story (sweeper report):**
> A resident on Spring St watches the sweeping truck finish its pass and turn the corner. She long-presses the block. Report sheet. "Sweeper passed." "Report." Pin drops instantly — everyone parked on the block sees it within 5 seconds and knows they do not need to rush back.

**Why now:** The write path (sub-PR #1) and the display layer (Tier 1) are both live. Without the report UI, the entire Tier 3 loop is dark. This sub-PR is the moment the loop closes.

---

## 2. Scope

### 2.1 In Scope (sub-PR #2)

- **Patrol mode entry:** `driveModeStyle = .patrol` at entry — reuses the Cruise Mode camera/overlay stack (heading-up, auto-zoom, `.mutedStandard`, directional puck, voice, `DriveModeBottomCard`) exactly as specified in `docs/cruise-mode-spec.md §5.1`. Patrol mode = Cruise Mode + community reporting capability. The only additions over Cruise Mode are: (1) long-press routes to the patrol report sheet instead of `ParkConfirmView`, and (2) `PinMarkerAnnotation` gains the time-since badge (see §5).
- **Patrol mode entry button:** A third entry in the `driveEntryButton` SwiftUI `Menu` in `ContentView.swift`: "Report enforcement / sweeper" or similar label (see §4 for exact label and icon options). This activates `driveModeStyle = .patrol` and `driveModeActive = true`. The existing "Drive to a destination" and "Find Parking nearby" entries remain unchanged. Guard: `guard activeSheet == nil else { return }` before activating, identical to Cruise Mode entry.
- **Long-press mode-aware routing:** When `driveModeStyle == .patrol`, `handleLongPress(at:)` in `ContentView.swift` goes to `ActiveSheet.patrolReport(coord: CLLocationCoordinate2D)` instead of `ActiveSheet.parkConfirm(PinDropIntent)`. When any other `driveModeStyle`, long-press behavior is identical to today (W5 `ParkConfirmView` flow). No action sheet, no disambiguation UI.
- **`PatrolReportSheet.swift` — the report entry UI:** New file. Presented as a `sheet(item:)` via `ActiveSheet.patrolReport(coord: CLLocationCoordinate2D)`. Content:
  - Two primary row buttons (44pt HIG minimum): "Enforcement active" and "Sweeper passed / approaching" (plus "Sweeper approaching" sub-option per OQ-R5 approved resolution).
  - When "Enforcement active" is selected, a secondary sub_tag picker row appears: "Cleaning truck" / "Parking agent" / "Tow truck" / "Not sure" pills (per OQ-R2 approved resolution). "Cleaning truck" listed first.
  - Single "Report" CTA button. "Cancel" or swipe-to-dismiss.
  - Copy is neutral / compliance per `community-1.0-direction.md §6`: "Enforcement active on this block — heads up" (NOT "Avoid tickets"). "Sweeper passed — block is clear." No "evade" language.
  - The coordinate is captured from the long-press point. No secondary map-position input.
  - On "Report" tap: calls `CommunityPinService.insertCrowdPin(...)` with the mapped args (see §6). Shows a brief loading state. On success: dismisses the sheet, stays in patrol mode. On error: shows an inline error string with a "Try again" affordance; does NOT exit patrol mode.
- **New `ActiveSheet` case:** `case patrolReport(coord: CLLocationCoordinate2D)` added to the `ActiveSheet` enum in `ContentView.swift`. `id` is `"patrolReport-\(coord.latitude)-\(coord.longitude)"`.
- **Marker + time-since badge:** `enforcement_active` and `sweeper_passed` pins already render via the Tier 1 display layer (`CommunityPinService.visiblePins` → `.onChange` → `MapViewRepresentable` annotation mounting). This sub-PR adds the time-since badge to `PinMarkerAnnotation.configure(for:)`: a `UILabel` in the callout subtitle showing "Xm ago" (pure function, described in §5). The sub-PR #3 spec (decay display layer) handles additional decay visuals; this spec owns only the badge wired to the existing callout.
- **Tap → PinDetailSheet wiring:** Tier 3 pins (`enforcement_active`, `sweeper_passed`) already reach `onCommunityPinTapped` → `ActiveSheet.pinDetail(pin)` via the Tier 1 display layer. The existing `PinDetailSheet.swift` + `ReactionsRow` (from sub-PR #1) render for these pins unchanged. No new wiring needed — confirm it works end-to-end in AC-R13.
- **Mandatory live-UI smoke gate:** This PR touches `ContentView.swift` and adds a new `PatrolReportSheet.swift`. The toolbar layer / ASP banner / Park-Until pill regression check from `docs/tier1-pin-display-spec.md §5` (AC-D10) is mandatory. See §7.

### 2.2 Out of Scope (explicitly deferred)

- **`broken_meter` and `open_spot` report types.** Kevin decision T3-1: first cut = `enforcement_active` + `sweeper_passed` only. `broken_meter` can be added as a third row in `PatrolReportSheet` in a fast-follow. `open_spot` is sub-PR #4 (requires schema migration).
- **Decay visual beyond the time-since badge.** Opacity fade, confirm-count badge, expires-at countdown, and all other decay visuals are sub-PR #3 (W8.5g).
- **Push notification for pins near parked car.** Sub-PR #5 (W8.5i). The seam exists in `CommunityPinService`'s Realtime subscription + `ParkPinService.currentCar.coordinate`; nothing is scaffolded here.
- **Drive Mode community callout** ("Enforcement 2 blocks ahead"). Sub-PR #6 (W8.5i). `DrivingContextService` and `DriveModeBottomCard` are NOT touched by this spec.
- **`CruiseVoicePolicy` modifications.** Patrol mode reuses Cruise Mode's `CruiseVoicePolicy` unchanged. No new voice policy for patrol mode in this PR.
- **Beachhead zone enforcement.** A SOHO/LES `zone_id` guard on `insertCrowdPin` is NOT in this PR. Kevin owns the distribution go/no-go (sticker program); the code path is not zone-gated for TF1. The RLS policy (`pins_insert_crowd`) enforces only `auth.uid()` and `source == 'crowd'` — it does not enforce zone membership. Add server-side zone validation in sub-PR #4 when `open_spot` ships (per `docs/tier3-auth-and-reactions-spec.md §8` note 4).
- **PWA changes.** PWA is in maintenance mode.
- **Any modification to `CruiseVoicePolicy.swift`, `DrivingContextService.swift`, or `FinalApproachService.swift`.** Patrol mode reuses these services exactly.

---

## 3. Architecture

### 3.1 Codebases Touched

| Codebase | Touch? | Notes |
|---|---|---|
| `ios/WePark/WePark/` | Yes | New `PatrolReportSheet.swift`; modified `ContentView.swift`, `PinMarkerAnnotation.swift` |
| `ios/WePark/WeParkTests/` | Yes | New tests for `PatrolReportSheet` + pure functions + mode routing |
| `supabase/` | No | All DB infra is live from sub-PR #1 |
| `index.html` (PWA) | No | Maintenance mode |
| `docs/` | This spec | Only this file |

### 3.2 New Files

```
ios/WePark/WePark/Views/PatrolReportSheet.swift
    — The report entry UI sheet.
    — Presented via ActiveSheet.patrolReport(coord: CLLocationCoordinate2D).
    — Calls CommunityPinService.insertCrowdPin via the mapping in §6.
    — @ios-engineer implements; interface sketch in §3.4.

ios/WePark/WeParkTests/PatrolReportTests.swift
    — Unit tests for the report sheet + mode routing + pure functions.
    — @ios-engineer implements; AC table in §7 drives the test inventory.
```

### 3.3 Modified Files

```
ios/WePark/WePark/ContentView.swift
    — Add ActiveSheet.patrolReport(coord: CLLocationCoordinate2D) case.
    — Add "Report enforcement / sweeper" entry to driveEntryButton Menu (new third item).
    — Add enterPatrolMode() method (mirrors enterCruiseMode() pattern).
    — Modify handleLongPress(at:): when driveModeStyle == .patrol, present
      .patrolReport(coord:) instead of .parkConfirm(PinDropIntent). All other
      driveModeStyle values fall through to existing W5 logic unchanged.
    — Add sheetContent case for .patrolReport — presents PatrolReportSheet.

ios/WePark/WePark/Views/PinMarkerAnnotation.swift
    — In configure(for pin:): when pin.pinType is .enforcementActive or .sweeperPassed,
      set the callout subtitle to the time-since badge string via timeSinceBadge(pin:now:)
      pure function (§5).
    — Add timeSinceBadge(pin: CommunityPin, now: Date) -> String pure function (or
      in a CommunityPin+Display.swift extension per the Tier 1 display spec §7.3 pattern).
```

### 3.4 `PatrolReportSheet` Interface Sketch

```swift
// ios/WePark/WePark/Views/PatrolReportSheet.swift
// @ios-engineer implements; sketch only.

struct PatrolReportSheet: View {

    let coordinate: CLLocationCoordinate2D
    let pinService: CommunityPinService
    let authService: SupabaseAuthService

    // Callback to dismiss the sheet on success.
    let onDismiss: () -> Void

    // Internal state
    @State private var selectedType: PatrolReportType? = nil
    @State private var selectedSubTag: EnforcementActiveMeta.SubTag? = nil
    @State private var sweeperDirection: SweeperDirection = .passed
    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    enum PatrolReportType {
        case enforcementActive
        case sweeperPassed      // direction stored separately in sweeperDirection
        case sweeperApproaching // maps to SweeperDirection.comingSoon
    }

    enum SweeperDirection {
        case passed      // maps to SweeperPassedMeta.direction = "passed"
        case comingSoon  // maps to SweeperPassedMeta.direction = "coming_soon"
    }

    var body: some View {
        // Report type selection rows (two primary options + sweeper sub-option).
        // Sub_tag picker row: appears when selectedType == .enforcementActive.
        // "Report" CTA: disabled if selectedType == nil.
        // Error display inline below the CTA.
        // Compliance copy: no "avoid tickets" language.
    }

    private func submitReport() async {
        guard let type = selectedType else { return }
        isSubmitting = true
        submitError = nil
        do {
            let (pinType, meta) = reportArgs(type: type, subTag: selectedSubTag, direction: sweeperDirection)
            try await pinService.insertCrowdPin(
                type: pinType,
                meta: meta,
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                segmentId: nil,   // TF1: no segment detection from the patrol flow
                zoneId: nil,      // TF1: no zone enforcement at insert time
                notes: nil
            )
            onDismiss()
        } catch {
            submitError = "Couldn't submit. Check your connection and try again."
        }
        isSubmitting = false
    }
}
```

### 3.5 Data Flow: Patrol Report → Pin on Map

```
[User long-presses map while driveModeStyle == .patrol]
        │
        ▼ ContentView.handleLongPress(at: coordinate)
        │   guard driveModeStyle == .patrol
        │   activeSheet = .patrolReport(coord: coordinate)
        ▼
[PatrolReportSheet presented]
        │  User selects: "Enforcement active" + sub_tag "Cleaning truck"
        │  Taps "Report"
        ▼
[PatrolReportSheet.submitReport()]
        │   CommunityPinService.insertCrowdPin(
        │       type: .enforcementActive,
        │       meta: .enforcementActive(EnforcementActiveMeta(subTag: .cleaningTruck)),
        │       lat: coordinate.latitude, lng: coordinate.longitude,
        │       segmentId: nil, zoneId: nil, notes: nil
        │   )
        │   → POST /rest/v1/pins with Authorization: Bearer <anon-jwt>
        │   → RLS: pins_insert_crowd passes (auth.uid() = author_id, source = 'crowd')
        │   → Supabase sets expires_at = now() + 30 min (default ephemeral)
        ▼
[Supabase Realtime: INSERT event broadcast to all subscribers]
        │
        ▼
[All clients' CommunityPinService.mergeRealtimeChange(pin:)]
        │   pin passes clientSideFilter (not expired, not resolved)
        │   visiblePins updated
        ▼
[ContentView .onChange(of: pinService.visiblePins) → handleVisiblePinsChange]
        │   newPins includes .enforcementActive and .sweeperPassed types
        │   communityPins updated → passed to MapViewRepresentable
        ▼
[MapViewRepresentable: MKAnnotation added for the new pin]
        │   PinMarkerAnnotation.configure(for: pin) sets shield icon + "Xm ago" subtitle
        ▼
[Pin visible on map for ALL users within 5 seconds]
```

---

## 4. Patrol Mode Entry

### 4.1 Entry Point: Third Menu Item in `driveEntryButton`

The existing `driveEntryButton` is a native SwiftUI `Menu` in `ContentView.swift` (lines 1122–1145) with two items: "Drive to a destination" and "Find Parking nearby." This spec adds a third item:

```swift
// Sketch — add inside the Menu { } block in driveEntryButton:
Button {
    enterPatrolMode()
} label: {
    Label("Report enforcement / sweeper", systemImage: "shield.fill")
}
```

**Label text (OQ-R4 placeholder — @designer to confirm):** "Report enforcement / sweeper." This is the label in the native system dropdown. Keep it under 35 characters; the system truncates long labels.

**`enterPatrolMode()` method** mirrors `enterCruiseMode()` exactly, with one difference: `driveModeStyle = .patrol`:

```swift
// Sketch — ContentView.swift
private func enterPatrolMode() {
    guard activeSheet == nil else { return }
    driveModeStyle = .patrol
    // activeRoute stays nil (no route — same as cruise mode)
    // driveDestinationCoordinate stays nil
    driveModeActive = true  // triggers handleDriveModeAndCamera — camera/voice stack fires
    drivingContextService.setCruiseMode(true)  // patrol voice policy = cruise policy
    // No arrivalPromptFired reset needed (patrol mode has no FinalApproachService)
}
```

**Guard behavior inherited from Cruise Mode:** The Menu is hidden while `driveModeActive == true` (existing guard at ContentView.swift line 1093). Patrol mode entry is impossible while already driving.

### 4.2 Long-Press Routing

The existing `handleLongPress(at:)` in `ContentView.swift` (line 1727) currently runs unconditionally to `ParkConfirmView`. The modification is a two-branch guard at the top:

```swift
// Sketch — ContentView.swift handleLongPress(at:) modification
private func handleLongPress(at coordinate: CLLocationCoordinate2D) {
    selectedSegmentID = nil
    activeSheet = nil

    // Patrol mode: route long-press to the patrol report sheet.
    if driveModeStyle == .patrol {
        activeSheet = .patrolReport(coord: coordinate)
        return
    }

    // All other modes: existing W5 ParkConfirmView flow — NO CHANGE.
    let candidates = findCandidateSegments(...)
    // ... existing logic unchanged ...
    activeSheet = .parkConfirm(intent)
}
```

**The W5 flow is completely untouched for all non-patrol modes.** The guard adds exactly two lines at the top of the function and an early return. `handleLongPress` itself is not renamed or restructured.

### 4.3 Exit: "End Patrol"

The existing "End Drive" / "End Cruise" pill exits patrol mode cleanly via `endDriveMode()` (unchanged). The pill label shows "End Patrol" when `driveModeStyle == .patrol` (extend the existing `driveModeStyle == .cruise ? "End Cruise" : "End Drive"` ternary at ContentView.swift line 1175 to a `switch`):

```swift
// Sketch
switch driveModeStyle {
case .patrol:     "End Patrol"
case .cruise:     "End Cruise"
default:          "End Drive"
}
```

`endDriveMode()` is NOT modified. All teardown (camera restore, voice stop, wake lock, etc.) is unchanged.

---

## 5. Time-Since Badge (Pure Function, T3-3 Decision)

The time-since badge is the only decay visual in this sub-PR. The badge appears in the MKAnnotation callout subtitle when a Tier 3 pin is tapped on the map. It is a pure function of pin age — no timer loop, no periodic redraw. The value is computed lazily at the moment the callout appears.

**Function signature:**

```swift
// Added to PinMarkerAnnotation.swift or CommunityPin+Display.swift.
// @ios-engineer implements; this is NOT production code.
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

**Integration in `PinMarkerAnnotation.configure(for:)`:**

```swift
// Sketch — inside configure(for pin: CommunityPin):
switch pin.pinType {
case .enforcementActive, .sweeperPassed:
    // subtitle shows time-since badge at callout display time
    let badge = PinMarkerAnnotation.timeSinceBadge(pin: pin, now: Date())
    annotation.subtitle = badge  // or set the CommunityPinAnnotation.subtitle computed property
default:
    // existing Tier 1 subtitle logic (expires_at formatted as "Until HH:mm")
    break
}
```

`now: Date` is injected in the signature to keep the function testable (no `Date()` call inside the function body). In the live callout path, the caller passes `Date()`. In tests, the caller passes a fixed fixture date.

**No timer loop.** The badge is stale by definition (it is a snapshot of `createdAt` relative to callout-open time). This is correct behavior: the badge is a trust signal, not a live clock. Sub-PR #3 owns any live-updating decay UI.

**No `Calendar.current` usage.** Time arithmetic uses `Date.timeIntervalSince(_:)` only — seconds as `Double`. No calendar, no timezone. This is consistent with the W3 convention; enforcement timing is already in UTC (`expires_at` is a timestamptz). `timeSinceBadge` returns a human-readable English string; it does not need ET-localization (it is relative to "now," not to a clock time).

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
- `lifespan`, `source`, and `expires_at` are set inside `CommunityPinService.insertCrowdPin` (from the sub-PR #1 sketch at `tier3-auth-and-reactions-spec.md §3.9`). `PatrolReportSheet` does not pass these; it passes only `type:`, `meta:`, `lat:`, `lng:`, `segmentId:nil`, `zoneId:nil`, `notes:nil`.
- `author_id` is set from `authService.currentUserId` inside `insertCrowdPin` — the sheet does not touch auth.
- `SweeperPassedMeta.direction` in the schema is `'passed' | 'coming_soon' | null` (`typed-pin-schema-spec.md §4.3`). The iOS `SweeperPassedMeta` struct's `direction` field must be a `String?` or a typed enum with those raw values. Confirm the existing struct in `Models/CommunityPin.swift` — if `SweeperPassedMeta` only has `direction: String?`, the write path serializes the string directly.

---

## 7. Work Streams

Two streams within sub-PR #2. Disjoint file sets; can run simultaneously but share the same PR branch.

| Stream | Owner | Files | Dependencies | Notes |
|---|---|---|---|---|
| **A — Patrol mode entry + long-press routing** | @ios-engineer | `ContentView.swift` (ActiveSheet case + menu item + handleLongPress guard + enterPatrolMode) | Kevin OQ-R1 answer | No interaction with CommunityPinService directly |
| **B — PatrolReportSheet + badge** | @ios-engineer | `PatrolReportSheet.swift` (new), `PinMarkerAnnotation.swift` (time-since badge), `PatrolReportTests.swift` (new) | Kevin OQ-R2, OQ-R3, OQ-R4, OQ-R5 + Stream A (needs the ActiveSheet case to compile) | Calls `insertCrowdPin` from sub-PR #1 |

Stream B logically serializes after Stream A (it needs the `patrolReport` `ActiveSheet` case to compile the `sheetContent` switch), but an engineer can stub the case and develop in parallel. A single engineer should do both in sequence: A then B.

---

## 8. Acceptance Criteria

All ACs verified by @qa-verifier independently. @qa-verifier is not the same agent that built the feature.

### Patrol Mode Entry + Long-Press Routing

- [ ] **AC-R1.** Tapping "Report enforcement / sweeper" in the `driveEntryButton` Menu sets `driveModeStyle == .patrol` and `driveModeActive == true`. The camera, heading-up rotation, auto-zoom, `.mutedStandard` map style, directional puck, and `DriveModeBottomCard` all activate (same as Cruise Mode entry). Verified by code inspection that `enterPatrolMode()` calls the same `handleDriveModeAndCamera` path as `enterCruiseMode()`.
- [ ] **AC-R2.** While `driveModeStyle == .patrol`, long-pressing the map presents `ActiveSheet.patrolReport(coord:)`. `ParkConfirmView` is NOT presented. Verified by a unit test that mocks `handleLongPress(at:)` with `driveModeStyle == .patrol` and asserts `activeSheet == .patrolReport(...)`.
- [ ] **AC-R3.** While `driveModeStyle == .inactive` (normal map mode), long-pressing the map presents `ActiveSheet.parkConfirm(PinDropIntent)`. The W5 flow is unaffected. Verified by an identical test with `driveModeStyle == .inactive`.
- [ ] **AC-R4.** While `driveModeStyle == .cruise`, long-pressing the map presents `ActiveSheet.parkConfirm(PinDropIntent)` (W5 flow), not `.patrolReport`. Cruise Mode behavior is unchanged.
- [ ] **AC-R5.** `endDriveMode()` exits patrol mode cleanly: `driveModeActive` becomes `false`, `driveModeStyle` becomes `.inactive`, camera restores, `DriveModeBottomCard` disappears. Verified by code review that `endDriveMode()` is unchanged and sets `driveModeStyle = .inactive`.
- [ ] **AC-R6.** The "End Patrol" / "End Cruise" / "End Drive" pill label correctly reflects `driveModeStyle`. Verified by a unit test or code review of the `switch driveModeStyle` label expression.
- [ ] **AC-R7.** The `driveEntryButton` Menu is hidden (not rendered) while `driveModeActive == true`. The existing guard at ContentView.swift line 1093 covers this for patrol mode entry. Verified by code review.
- [ ] **AC-R8.** The `driveModeStyle` guard at the top of `handleLongPress(at:)` adds exactly two new lines (the guard check + early return). The existing W5 logic below the guard is unchanged line-for-line. Verified by `git diff` inspection.

### Report Sheet — Content and Behavior

- [ ] **AC-R9.** `PatrolReportSheet` presents two primary type rows: "Enforcement active" and "Sweeper passed." Tapping "Enforcement active" reveals the sub_tag picker row (per OQ-R2 resolved). Verified by UI test or code review.
- [ ] **AC-R10.** The sub_tag picker has four options: "Cleaning truck" (listed first), "Parking agent," "Tow truck," "Not sure." Default selection is none (sub_tag = nil). Selecting "Not sure" writes `sub_tag: nil`. Verified by code review of the picker state binding.
- [ ] **AC-R11.** "Sweeper passed" and "Sweeper approaching" are both available (per OQ-R5 resolved). Selecting "Sweeper approaching" sets `SweeperPassedMeta.direction = "coming_soon"` in the insert payload. Verified by request-body inspection in a unit test.
- [ ] **AC-R12.** The "Report" CTA is disabled (`.disabled(true)`) when no primary type is selected. It is enabled as soon as any primary type row is tapped (sub_tag is optional, does not gate the CTA). Verified by a unit test asserting `isReportEnabled` state.
- [ ] **AC-R13 (copy compliance).** The report sheet contains no text matching the strings "avoid," "ticket," "fine," "evasion," or "dodge." Verified by `grep -ri "avoid\|ticket\|fine\|evasion\|dodge" PatrolReportSheet.swift` returning zero results (or equivalent code review).

### Write Path — `insertCrowdPin` Call

- [ ] **AC-R14.** Submitting "Enforcement active" + "Cleaning truck" calls `insertCrowdPin(type: .enforcementActive, meta: .enforcementActive(EnforcementActiveMeta(subTag: .cleaningTruck)), lat:, lng:, segmentId: nil, zoneId: nil, notes: nil)`. Verified by a mock `CommunityPinService` in a unit test that captures the args.
- [ ] **AC-R15.** Submitting "Sweeper passed" calls `insertCrowdPin(type: .sweeperPassed, meta: .sweeperPassed(SweeperPassedMeta(direction: "passed")), ...)`. Verified similarly.
- [ ] **AC-R16.** Submitting "Sweeper approaching" calls `insertCrowdPin(type: .sweeperPassed, meta: .sweeperPassed(SweeperPassedMeta(direction: "coming_soon")), ...)`. Verified similarly.
- [ ] **AC-R17.** While the insert is in-flight (`isSubmitting == true`), the "Report" button shows a `ProgressView` and is disabled to prevent double-submit. Verified by code review.
- [ ] **AC-R18.** On insert success, the sheet dismisses. On insert error, an inline error string appears and the sheet stays open (user can retry without losing their selection). Verified by unit tests with a mock that throws on one call and succeeds on the second.
- [ ] **AC-R19.** The inserted pin payload includes the coordinate from the long-press point (not the user's GPS location). Verified by injecting a specific `CLLocationCoordinate2D` and asserting `lat`/`lng` args match in the mock.
- [ ] **AC-R20 (end-to-end).** An `enforcement_active` pin inserted via the report sheet appears on a second client's map within 5 seconds (Realtime delivery). Verified manually by Kevin (two simultaneous simulator sessions or Kevin + a test device).

### Time-Since Badge

- [ ] **AC-R21.** `timeSinceBadge(pin:now:)` returns `"Just now"` when `now - pin.createdAt < 60s`. Verified by a unit test.
- [ ] **AC-R22.** `timeSinceBadge(pin:now:)` returns `"5m ago"` when `now - pin.createdAt == 300s`. Verified by a unit test.
- [ ] **AC-R23.** `timeSinceBadge(pin:now:)` returns `"1h ago"` when `now - pin.createdAt == 3600s`. Verified by a unit test.
- [ ] **AC-R24.** `timeSinceBadge(pin:now:)` contains no `Calendar.current` or `Calendar.easternTime` usage. Pure `timeIntervalSince` arithmetic only. Verified by `grep -n "Calendar" PinMarkerAnnotation.swift` returning zero results in the new function.
- [ ] **AC-R25.** Tapping an `enforcement_active` pin on the map opens `PinDetailSheet` with the `ReactionsRow` ("Still there?" + "Gone" + confirm-count). The wiring is unchanged from sub-PR #1. Verified end-to-end: insert a pin via the report sheet, tap it on the map, confirm both reaction buttons appear.

### Architecture Invariants

- [ ] **AC-R26.** No new `setRegion` calls anywhere in the PR diff. `RegionSyncGuardTests` (2 tests) pass unchanged. Verified by running the test suite.
- [ ] **AC-R27.** No mutation of UIKit state inside `MapViewRepresentable.updateUIView`. All annotation updates triggered by `.onChange(of: communityPins)`. Verified by code review of `updateUIView` body.
- [ ] **AC-R28.** No `headlessWindow` guard in any new or modified production code. Verified by `grep -rn "headlessWindow" ios/WePark/WePark/` returning zero results.
- [ ] **AC-R29.** `CommunityPin.swift` is NOT modified. The frozen model contract from PR #36 holds. Verified by `git diff HEAD -- ios/WePark/WePark/Models/CommunityPin.swift` showing no changes.
- [ ] **AC-R30.** `CruiseVoicePolicy.swift` and `DrivingContextService.swift` are NOT modified. Patrol mode reuses cruise voice behavior unchanged. Verified by `git diff` inspection.

### Live-UI Smoke Gate (MANDATORY)

- [ ] **AC-R31.** Before the PR is opened: engineer builds and launches the app in Simulator, captures a screenshot via `xcrun simctl io booted screenshot /tmp/tier3-patrol-report-smoke.png`, reads the screenshot using the Read tool (multimodal). Screenshot confirms: (a) the ASP banner renders at the top, (b) the toolbar cluster (gear / find-me / find-car / clock / drive-entry button) is fully visible, (c) no overlay elements are dropped, (d) `DriveModeBottomCard` is not visible in the idle state. This gate is MANDATORY before the PR is opened. @qa-verifier repeats the check independently.

---

## 9. Open Decisions — What Needs @designer Input

The following design details are intentionally left to a `@designer` review pass. Engineering can start with placeholder values; these should be resolved before Kevin's manual smoke:

1. **Icon for `enforcement_active` marker.** Placeholder: `shield.fill` (blue). `@designer` to confirm this reads as "civic authority" rather than "police" — the framing avoids cop-cartoons per `community-1.0-direction.md §6`.
2. **Icon for `sweeper_passed` marker.** Placeholder: `exclamationmark.triangle.fill` (orange) or `truck.box.fill` if available on iOS 17 minimum target. `@designer` to confirm and check iOS 17 symbol availability.
3. **Icon for "Report enforcement / sweeper" menu item.** Placeholder: `shield.fill`. May differ from the map marker icon.
4. **Sub_tag picker visual treatment.** Horizontal pill row or vertical list? HIG-minimum 44pt tap targets required either way.
5. **Time-since badge position.** Callout subtitle (current spec) or a small overlaid label on the `MKAnnotationView` itself? The subtitle approach is lower risk (no custom annotation view layer); the overlaid label is more visible at a glance. `@designer` to decide; engineering defaults to the subtitle approach.

---

## 10. Out-of-Scope Follow-Ups

**Decay display layer.** Sub-PR #3 (W8.5g). Opacity fade, confirm-count badge on the map marker, `expires_at` countdown in the callout, and all other decay visuals beyond the time-since badge. The `timeSinceBadge` pure function in this spec is the only decay signal in sub-PR #2. Sub-PR #3 extends the marker display without touching `PatrolReportSheet.swift` or the long-press routing.

**`broken_meter` reporting.** One additional row in `PatrolReportSheet` and one new case in the type-to-meta mapping table (§6). Can be added in a standalone fast-follow PR after sub-PR #2 merges. Does not require a schema migration (`.brokenMeter` already exists in the `pin_type` enum; `BrokenMeterMeta.meterId: String?` already in `CommunityPin.swift`).

**Patrol mode vs. Cruise Mode voice distinction.** The current spec routes patrol mode through `setCruiseMode(true)` on `DrivingContextService`, meaning patrol mode uses `CruiseVoicePolicy` (announces only when at least one side is free/metered). This is correct for TF1. A future spec could distinguish patrol-mode voice with a different cadence (e.g., always-on commentary while reporting, or a "reporting" audio confirmation tone after a successful insert). Not in this cut.

**SOHO/LES beachhead zone filter.** A server-side `zone_id` validation check in `insertCrowdPin` that rejects reports outside the SOHO/LES bounding box. Deferred to sub-PR #4 per `docs/tier3-auth-and-reactions-spec.md §8` note 4 and `docs/tier3-patrol-mode-buildplan.md §7`. The iOS call in `PatrolReportSheet.submitReport()` passes `zoneId: nil`; the RLS does not enforce zone membership. Add the zone guard in sub-PR #4 when `open_spot` ships with its mandatory SOHO/LES enforcement.

**`open_spot` reporting in the patrol flow.** After sub-PR #4 lands the schema migration (`ALTER TYPE public.pin_type ADD VALUE 'open_spot'`) and the iOS `PinType.openSpot` enum case, `PatrolReportSheet` gets a third primary row: "Open spot" with an ultra-short 3-minute TTL. Requires the claim mechanic spec in sub-PR #4 before engineering.

**Patrol mode "Find Parking" sweep routing.** Patrol mode's camera stack is Cruise Mode (free-roam, user drives where they want). A guided greedy-graph sweep (`generateParkingRoute` port from PWA) that routes the user through unvisited blocks is a distinct feature. Out of scope per `docs/cruise-mode-spec.md §2.2`. Spec target: `docs/patrol-sweep-routing-spec.md` post-TF1.

**Drive Mode community callout.** When `driveModeStyle == .patrol` and an `enforcement_active` pin is within 200m of the user's location, a chip on `DriveModeBottomCard` fires: "Enforcement 2 blocks ahead." This is sub-PR #6 (`docs/tier3-drive-callout-spec.md`). `DriveModeBottomCard.swift` is NOT touched by this sub-PR.

**Relevance-gated push.** "Enforcement near your car on [block] — consider moving it." This is sub-PR #5 (`docs/tier3-push-alerts-spec.md`). `NotificationScheduler.swift` is NOT touched by this sub-PR.
