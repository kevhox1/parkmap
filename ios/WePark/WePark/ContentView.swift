//
//  ContentView.swift
//  WePark
//
//  Rendering architecture: UIKit MKMapView via MapViewRepresentable (UIViewRepresentable).
//  This replaces the SwiftUI Map + MapPolyline approach used in W2–W4.
//
//  Root cause of the replacement (2026-05-11):
//  SwiftUI MapPolyline inside @MapContentBuilder is disqualified at 40,664-segment density.
//  40,664 segments × ~30 Metal resources each = 1.22M GPU resources, 25× over MapKit's
//  50,000-resource VectorKit limit. Process RSS reached 19.92 GB. The VectorKit pruner
//  fired "Exceeded Metal Buffer threshold of 50000 with a count of 1262055 resources".
//
//  Current approach: 6 MKMultiPolyline overlays (5 state groups + 1 selected-block highlight).
//  6 Metal resource groups total. Under the threshold by a factor of 8,000.
//  See: docs/ios-rendering-architecture-decision.md
//
//  What changed vs the W4 + fix-pass-1 branch (f2595f1):
//    - Replaced: Map { polylineContent } + @MapContentBuilder + MapReader
//    - Replaced: SwiftUI onTapGesture → UITapGestureRecognizer in MapViewRepresentable.Coordinator
//    - Kept: ParkingRulesEngine, TileLoader, ASPSuspensionService, all Models
//    - Kept: BlockDetailView, sheet presentation mechanics (.sheet(isPresented:))
//    - Kept: handleMapTap / pointToPolylineDistance / haversine (only gesture source changes)
//    - Kept: 60s timer cadence; now also drives overlay recompute (replaces per-polyline recompute)
//    - Kept: polylineHideSpanThreshold (zoom gating — hides overlays when zoomed out; lowered from 0.1 → 0.04 in viewport-polish)
//    - Raised: maxCachedTiles from 50 → 200 (see TileLoader.swift; per decision doc §3 rationale)
//
//  W4 fix-pass-1 carry-overs still in effect:
//    - No Annotation overlay (VoiceOver map-navigation of individual blocks is post-MVP)
//    - Sheet dismiss via onDismiss closure (not concurrent with animation)
//    - A11y: safety label is first focusable element, ✕ reads "Close block details"
//
//  W5 additions:
//    - ParkPinService: @State var parkPinService (loaded on appear)
//    - Long-press → handleLongPress(at:) → segment detection → ParkConfirmView
//    - "Park here →" button in BlockDetailView wired via onParkHere closure
//    - Car pin annotation in MapViewRepresentable driven by parkPinService.parkedCar
//    - ParkedCarDetailView sheet on car-pin tap
//    - findCandidateSegments: multi-candidate search for "Wrong street?" alternatives
//
//  W5.1 additions (polish pass):
//    - Recenter buttons overlay (top-right): "Find me" (location.fill) + "Find my car" (car.fill)
//    - LocationService: CLLocationManager wrapper for .whenInUse permission + single-shot fix
//    - MKMapView.showsUserLocation = true (blue dot when permission granted)
//    - QA Fix #1: pinDropped.send() moved inside do-catch block in ParkPinService.save()
//    - QA Fix #2: "Wrong street?" alternatives list rebuilt after selection in ParkConfirmView
//
//  Sheet stacking: SwiftUI only supports a single .sheet() host per view.
//  W5.1 fix-pass (Bug 2): Collapsed three separate .sheet(item:) bindings into one
//  enum-driven ActiveSheet binding. One .sheet() modifier, one @State var — SwiftUI
//  handles mutual exclusivity automatically. See ActiveSheet enum below.
//
//  W6 additions:
//    - ActiveSheet.notificationRationale case for the rationale sheet.
//    - @State showNotificationRationale (drives the .sheet for NotificationRationaleView).
//    - .onReceive(parkPinService.firstPinDropped): show rationale on first pin (gated by
//      wepark_notification_rationale_shown UserDefaults flag).
//    - .onReceive(parkPinService.pinDropped): cancel old notifications then schedule new ones.
//      Captures the old car ID BEFORE the new car is received (spec §3.6 replace note).
//    - .onChange(of: appDelegate.pendingDeepLinkCarID): deep-link tap → open ParkedCarDetailView.
//      W6.1 fix: replaced PassthroughSubject + .onReceive with @Published buffer + .onChange so
//      the car ID survives the foreground transition in cold-kill / background-wake scenarios.
//    - NotificationScheduler.shared.cancelAll(for:) called in onClearPin via confirmPinDrop.
//
//  W7 additions:
//    - ActiveSheet.settings case for the gear settings sheet.
//    - @State notificationsMuted: Bool (backed by UserDefaults; bound into SettingsView).
//    - @State bannerState: SuspensionBannerState — refreshed on appear + foreground event.
//    - ASPBanner via .safeAreaInset(edge: .top) on MapViewRepresentable.
//    - Gear button (top-left, same material-pill style as recenter buttons).
//    - ToastHostView embedded as top-most ZStack layer (highest z-order).
//    - confirmPinDrop: now takes PinConfirmResult (includes notifyOnRestriction).
//    - ParkedCarDetailView: now receives parkPinService for toggle write-back.
//    - onUnmute closure: reschedules notification + fires ToastService.shared.show.
//    - @State aspService: ASPSuspensionService instance.
//    - @Environment(\.scenePhase) for foreground-event banner refresh.
//
//  W7.5 additions (pass-1):
//    - ActiveSheet.parkUntil (originally parkUntil(ParkedCar)) — Park Until sheet.
//    - @State parkUntilTarget: Date? and parkUntilMode: Bool — filter state.
//    - ParkUntilPill via .safeAreaInset(edge: .bottom) — filter-active indicator.
//    - rebuildOverlays: binary green/red branch when parkUntilMode is true.
//    - Stale-target guard in .onChange(of: scenePhase) — clears expired filter on foreground.
//    - isFree(segment:from:until:) engine method + ParkUntilTests (20 tests).
//
//  W7.5 pass-2 pivot (filter-first UX):
//    - ActiveSheet.parkUntil changed to no-payload case (car-agnostic).
//    - Standalone clock.fill toolbar button in recenterButtonStack as Park Until trigger.
//    - .onReceive(pinDropped) no longer presents the sheet or clears the filter.
//    - Filter persists across pin drops; cleared only via X-on-pill, stale-target, or "I left".
//    - ParkUntilSheet: `car: ParkedCar` parameter removed.
//    - Skip handler: dismisses sheet only (no filter clear — filter was not set by this sheet).
//
//  W8.5d additions (final approach escalation + arrival prompt):
//    - ActiveSheet.arrivalPrompt(coord: CLLocationCoordinate2D) — new case.
//    - @State finalApproachState: FinalApproachState — tracks .outside/.approaching/.arrived.
//    - @State arrivalPromptFired: Bool — one-shot hysteresis gate (R-3).
//    - .onChange(of: driveModeDistanceMeters) → handleFinalApproachUpdate(_:):
//        computes FinalApproachState, updates DrivingContextService voice gap,
//        fires arrival prompt once per session at <= 50m.
//    - DriveModeBottomCard gains showApproachStrip: finalApproachState == .approaching.
//    - ArrivalPromptSheet: "Park Here" drops W5 pin at user's GPS coordinate (NOT destination).
//    - Drive Mode ends on "Park Here" confirm; "Not Yet" dismisses sheet only (OQ-6).
//    - Reset finalApproachState + arrivalPromptFired on Drive Mode exit.
//
//  Tier 3 sub-PR #2 additions (universal community reporting):
//    - DriveModeStyle.patrol case REMOVED (per OQ-NR3 decision).
//    - ActiveSheet.reportPin(coord: CLLocationCoordinate2D) — new case.
//    - @State pendingLongPressCoord: CLLocationCoordinate2D? — held while dialog is visible.
//    - @State showRestingActionMenu: Bool — triggers the resting long-press confirmationDialog.
//    - handleLongPress(at:) revised: no-op when driveModeActive == true; shows confirmationDialog
//      when driveModeActive == false. W5 segment detection deferred to "Park my car here" action.
//    - .confirmationDialog on body: two actions ("Park my car here" / "Report enforcement or sweeper").
//    - In-drive Report button (flag.fill, orange) in driveModeOverlayLayer HStack (NR1 placement).
//    - handleVisiblePinsChange: includes enforcement_active + sweeper_passed in map marker set.
//
//  FT-18 additions (Drive Mode layout redesign — docs/design/ft18-drive-mode-layout.md):
//    - `driveModeOverlayLayer` REMOVED. Its three pieces now live in two places:
//        - `endDriveControl`: isolated top-trailing "End" pill (own corner, matches Apple
//          Maps — Kevin's ruling #1, safety-motivated: a one-tap session-terminating
//          action must not sit adjacent to Report/Park Here on a moving-car phone mount).
//        - `recenterRow` + `driveActionRow`: moved INTO `bottomSafeAreaContent`'s
//          VStack(spacing: 8) as structural rows above `DriveModeBottomCard`, replacing
//          the old independently-`Spacer()`-positioned floats. `recenterPillBottomPadding`
//          is no longer called from the view (kept + still tested — pure function, cheap
//          to keep) now that stacking order alone provides clearance.
//    - Bug F1 (dead top-right zone / trailing Spacer()) fixed: the old top-leading
//      End/Report/Park Here row and its trailing Spacer() are gone entirely.
//    - Bug F2 (gear button / End pill coordinate collision) fixed: gear button is now
//      gated by `gearButtonVisible(driveModeActive:)`, hidden whenever `endDriveControl`
//      owns the top-trailing corner.
//    - Bug F3 (duplicate mute toggle in Cruise Mode) fixed: the top-row Cruise-only mute
//      button is deleted. `DriveModeBottomCard.muteButton` (unconditional, both styles)
//      is now the only mute control.
//    - Bug F4 (Find me / Find my car using the wrong browse-mode camera pipeline mid-drive)
//      fixed by removal, not by rewiring: `recenterButtonStack` (Find me / Find my car /
//      Park Until entry / combined Drive entry) is now gated `if !driveModeActive` at the
//      call site in `mapZStack`, so none of its buttons can be tapped while driving —
//      `recenterMap(on:)` can no longer fire mid-drive. The combined Drive-entry button's
//      former "resting icon, no action on tap" dead branch is deleted for the same reason
//      (Kevin's ruling #2: "Find my car" removed during Drive Mode, not kept as a mini icon;
//      ruling #3: gear hidden fully).
//
//  FT-15 / TF2-15 Stream B2 additions (block-scoped temporary restriction reports —
//  docs/ft15-tf215-temporary-block-restrictions-spec.md §4.2):
//    - Third confirmationDialog action, "Report closure (film shoot / construction)",
//      alongside the two Tier 3 sub-PR #2 actions above. Entry point placement chosen
//      per the spec's own recommendation (§4.2 step 1) — extends the existing resting
//      long-press dialog rather than adding a toolbar button. Re-evaluated against
//      FT-18's Bottom Dock redesign: unaffected, since this dialog only ever presents
//      when `driveModeActive == false` (FT-18 only restructured Drive-Mode-ACTIVE chrome).
//    - @State blockSelectModeActive / selectedBlockKeys / bothCurbsOn — block-select
//      tap-select mode (§4.2 steps 2–4). `handleMapTap` branches into
//      `handleBlockSelectTap` while active; `handleLongPress` no-ops while active.
//    - `blockSelectBar` — floating bar in `bottomSafeAreaContent`'s VStack (FT-18's
//      "Bottom Dock" structural-row pattern), Cancel/Continue + "Both curbs" toggle.
//    - ActiveSheet.blockRestrictionReport(segments:) — presents
//      `BlockRestrictionReportSheet` on Continue.
//    - `MapViewRepresentable(blockSelectKeys:)` — multi-segment selection highlight
//      overlay (additive; does not replace or recolor the existing 5-state + selectedBlock
//      overlays — OQ-1's marker-only ruling, applied to the render step; the selection
//      highlight required during tap-select is separate new-but-minimal overlay surface).
//    - QA pass-1 fix: `blockSelectModeActive`/`driveModeActive` are now mutually
//      exclusive from BOTH directions (an earlier revision only enforced one). See
//      `blockSelectModeActive`'s doc comment, the `recenterButtonStack` gate in
//      `mapZStack`, and the force-clear in `handleDriveModeAndCamera`.
//

import SwiftUI
import MapKit
import Combine

// MARK: - ActiveSheet

/// Enum-driven single-sheet pattern (Option A).
/// All sheet presentations in ContentView flow through this type.
/// Adding a new sheet in W6/W7/W8 means adding a new case — no structural change needed.
enum ActiveSheet: Identifiable {
    case blockDetail(Segment)
    case parkConfirm(PinDropIntent)
    case parkedCarDetail(ParkedCar)
    /// W6: one-time notification rationale sheet (first pin drop).
    case notificationRationale
    /// W7: global settings sheet.
    case settings
    /// W7.5: "Parking until when?" sheet — triggered via standalone toolbar button.
    /// Pass-2 pivot: car-agnostic; no ParkedCar payload. Filter is independent of pin lifecycle.
    case parkUntil
    /// W8.5d: Arrival prompt sheet — fires once per Drive Mode session when the driver
    /// reaches within `FinalApproachService.arrivalThresholdMeters` of the destination.
    /// Payload: user's GPS coordinate at the moment of arrival detection (NOT the destination).
    /// On "Park Here" confirm → drops W5 pin at this coordinate → W7.5 Park Until fires naturally.
    case arrivalPrompt(coord: CLLocationCoordinate2D)
    /// TF2-7: Sign-check confirmation sheet — pre-step before ParkConfirmView.
    /// Presented when the driver taps "Park here" in the Drive Mode overlay.
    /// On "I checked — Park here" → transitions to ActiveSheet.parkConfirm(intent).
    /// The W8.5d arrival prompt path BYPASSES this sheet (spec §5.4).
    case signCheckConfirm(intent: PinDropIntent)
    /// Community 1.0 / Tier 1: read-only detail sheet for a community pin (filming / special_event).
    /// Presented when the user taps a `CommunityPinAnnotation` on the map.
    case pinDetail(CommunityPin)
    /// Tier 3 sub-PR #2: Universal community report sheet.
    /// Resting entry: coord = long-press coordinate on map; streetName = nil.
    /// In-drive entry: coord = user's GPS at moment of tap; streetName = drivingContext?.street.
    ///
    /// Bug #4: streetName added so the ReportSheet can show "Reporting on <street>"
    /// when opened from the in-drive button. The existing DrivingContextService already
    /// resolves the street name for the DriveModeBottomCard — we reuse that value here
    /// rather than running a second segment search.
    ///
    /// FT-11: segment added so ReportSheet can show the direction picker with real
    /// cross-street labels and block bearing. Nil when the long-press is off-segment (OD-1).
    case reportPin(coord: CLLocationCoordinate2D, streetName: String?, segment: Segment? = nil)
    /// FT-12: Parking 101 guide, opened from the first-launch prompt banner tap.
    /// (Settings' own entry point uses a plain NavigationLink inside its own
    /// NavigationStack, not this case — this case exists only for the banner, which
    /// lives outside any NavigationStack context.)
    case parkingGuide
    /// FT-15/TF2-15 Stream B2: block-scoped restriction report form (camera capture +
    /// type/time/notes). Presented when the user taps Continue on the block-select
    /// floating bar. `segments` is a snapshot of the tapped `Segment`s at the moment
    /// Continue was pressed (one per entry in `selectedBlockKeys`) — the sheet reads
    /// `blockfaceKey`/coordinates verbatim off these, never re-deriving identity from
    /// text (spec §4.1/§4.3).
    case blockRestrictionReport(segments: [Segment])

    var id: String {
        switch self {
        case .blockDetail(let seg):       return "blockDetail-\(seg.id)"
        case .parkConfirm(let intent):    return "parkConfirm-\(intent.id)"
        case .parkedCarDetail(let car):   return "parkedCarDetail-\(car.id)"
        case .notificationRationale:      return "notificationRationale"
        case .settings:                   return "settings"
        case .parkUntil:                  return "parkUntil"
        case .arrivalPrompt(let coord):   return "arrivalPrompt-\(coord.latitude)-\(coord.longitude)"
        case .pinDetail(let pin):         return "pinDetail-\(pin.id)"
        case .reportPin(let coord, _, _): return "reportPin-\(coord.latitude)-\(coord.longitude)"
        case .signCheckConfirm(let intent): return "signCheckConfirm-\(intent.id)"
        case .parkingGuide:               return "parkingGuide"
        case .blockRestrictionReport(let segments):
            return "blockRestrictionReport-" + segments.map(\.id).joined(separator: ",")
        }
    }
}

// MARK: - DriveModeStyle

/// Distinguishes the active Drive Mode variant from the inactive state.
///
/// CM-3: Added to provide an explicit, auditable gate for route-dependent behavior.
/// The nil-based gate (`activeRoute == nil`) is implicit and has caused guard-inversion
/// bugs before (W8.5c-polish QA). A named enum makes the routing gate grep-auditable.
enum DriveModeStyle {
    /// Drive Mode is not active. No camera tilt, no voice, no bottom card.
    case inactive
    /// Destination Mode: user entered an address, route polyline + pin rendered,
    /// FinalApproachService active, arrival prompt possible.
    case destination
    /// Cruise Mode ("Find Parking"): route-less Drive Mode. No route polyline,
    /// no destination pin, no FinalApproachService calls. Voice gated by CruiseVoicePolicy.
    case cruise
}

struct ContentView: View {

    // MARK: - W6: AppDelegate reference for notification deep-link routing

    /// Injected from WeParkApp. ContentView reads `appDelegate.pendingDeepLinkCarID`
    /// (W6.1 fix: @Published buffer, replaces the former PassthroughSubject) to open
    /// ParkedCarDetailView when the user taps a delivered notification.
    @ObservedObject var appDelegate: AppDelegate

    // MARK: - Tier 3 sub-PR #1: Anonymous auth identity

    /// Injected from WeParkApp (AC-A5: single instance per app lifetime).
    ///
    /// Passed into CommunityPinService for authenticated writes (crowd pin insert, votes).
    /// Also passed into PinDetailSheet so the reactions row can compare pin.authorId
    /// against authService.currentUserId for the own-pin guard (A1 decision).
    ///
    /// The @State declaration here is fine — @State on a View stored property creates
    /// a reference-stable box around the existing value; since authService is @Observable,
    /// SwiftUI observes its published properties automatically without @ObservedObject.
    var authService: SupabaseAuthService

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - State

    /// Current map region — kept in @State so ContentView owns the camera.
    /// Passed to MapViewRepresentable as a Binding; updated by the regionChanged callback.
    @State private var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(
            latitude: AppConstants.manhattanCenter.latitude,
            longitude: AppConstants.manhattanCenter.longitude
        ),
        span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
    )

    @State private var tileLoader = TileLoader()
    @State private var engine = ParkingRulesEngine()

    /// Flipped every 60 seconds to drive overlay recompute.
    @State private var lastEvaluatedAt: Date = .now

    /// W4: Selected segment ID. Drives the highlight overlay in MapViewRepresentable.
    /// Kept independent of activeSheet so the highlight stays alive while a sheet is open.
    @State private var selectedSegmentID: String? = nil

    /// W5.1 fix-pass Bug 2: Single enum-driven sheet binding.
    /// Replaces the three separate sheet vars (isSheetPresented/pinDropIntent/parkedCarDetailItem)
    /// that triggered "Currently, only presenting a single sheet is supported" warnings.
    @State private var activeSheet: ActiveSheet? = nil

    /// W5: Single-pin persistence service. Loaded once at app launch.
    @State private var parkPinService = ParkPinService()

    /// W5.1: User location service for the recenter button.
    @State private var locationService = LocationService()

    /// W5.1: Set to true when the user taps "Recenter on my location".
    /// Cleared after the next userLocation update triggers the recenter.
    @State private var recenterOnUserRequested: Bool = false

    /// Viewport-polish: Set to true at launch when auto-center is deferred waiting for a GPS fix.
    /// Mirrors `recenterOnUserRequested` lifecycle but fires from the launch-time auto-center path.
    /// The two flags are independent — a button tap while launch auto-center is still waiting
    /// must not collapse into a single flag (they may arrive in any order).
    /// Both are cleared in `.onChange(of: locationService.locationUpdateCount)`.
    @State private var recenterOnUserAtLaunch: Bool = false

    /// W6: Tracks the UUID of the car that was parked BEFORE the most recent save().
    /// Used by onReceive(pinDropped) to cancel the old car's notifications precisely.
    /// Initialized from parkPinService.parkedCar at load time (in .task).
    @State private var previousCarID: UUID? = nil

    /// Overlay payload passed into MapViewRepresentable.
    /// Rebuilt on every tick or when selectedSegmentID changes.
    @State private var overlayPayload = MapViewRepresentable.OverlayPayload()

    /// Generation counter: incremented each time we rebuild overlays.
    /// MapViewRepresentable.OverlayPayload.== compares only generation,
    /// so the UIView update path fires exactly when we want it to.
    @State private var overlayGeneration: Int = 0

    // MARK: - W7: ASP Banner state

    /// Service is immutable after init — not @Observable by design (see ASPSuspensionService header).
    @State private var aspService = ASPSuspensionService()

    /// Current banner state. Refreshed on appear and when app re-enters foreground.
    @State private var bannerState: SuspensionBannerState = .aspInEffect

    // MARK: - W7: Settings / mute state

    /// Source of truth for the global notifications mute toggle.
    /// Initialized from UserDefaults in .task; SettingsView binds to this via $notificationsMuted.
    /// Writes to UserDefaults are performed inside the SettingsView binding setter (via onUnmute
    /// and the negated binding) so ContentView stays decoupled from the key name.
    @State private var notificationsMuted: Bool = false

    /// FT-6: Source of truth for the multi-preset reminder timing selection.
    /// Initialized from UserDefaults in .task; SettingsView binds to this via $reminderOffsets.
    /// Writes to UserDefaults are performed inside SettingsView's .onChange(of: offsets) via
    /// ReminderOffsets.save, then onOffsetsChange() triggers a reschedule.
    @State private var reminderOffsets: ReminderOffsets = .default

    // MARK: - W7.5: Park Until filter state

    /// The target departure time the user selected in ParkUntilSheet.
    /// Non-nil only while the Park Until filter is active.
    /// In-session only — cleared on app kill and on foreground re-entry if past.
    @State private var parkUntilTarget: Date? = nil

    /// True while the Park Until filter is active.
    /// Drives the binary green/red map rendering branch in rebuildOverlays.
    @State private var parkUntilMode: Bool = false

    // MARK: - W8.5c-polish PR-1: Distance-to-destination state

    /// Distance from the user's current location to driveDestinationCoordinate, in meters.
    /// Recomputed on every location fix while Drive Mode is active.
    /// Nil when Drive Mode is inactive or no destination is set.
    @State private var driveModeDistanceMeters: Double? = nil

    // MARK: - W8.5c-polish PR-3 / PR-2: Drive Mode camera + style state

    /// Camera pitch captured at Drive Mode entry. Restored on exit (OQ-3).
    /// Almost always 0 (users don't manually tilt MKMapView), but stored precisely for correctness.
    @State private var preDrivePitch: CGFloat = 0

    /// Camera `centerCoordinateDistance` captured at Drive Mode entry. Restored on exit.
    /// Typically the user's normal browsing zoom level (~100,000–300,000m for Manhattan).
    @State private var preDriveDistance: CLLocationDistance = 0

    /// Map configuration captured at Drive Mode entry. Restored on exit (OQ-3 / §3.6).
    /// On entry, the map switches to `.muted` for better polyline legibility during driving.
    /// On exit, this restores whatever configuration was active before Drive Mode started.
    @State private var preDriveMapConfiguration: MKMapConfiguration? = nil

    /// Reference-type action box shared with MapViewRepresentable's Coordinator.
    /// Created here, passed to MapViewRepresentable as a stored property. `makeUIView` populates
    /// the closures inside. ContentView calls `coordinatorActions.applyDrivePitch` from the
    /// `.onChange(of: driveModeActive)` camera-pitch handler — OUTSIDE updateUIView.
    ///
    /// Architecture note (AC-10): camera mutation is placed in .onChange rather than in
    /// updateUIView because updateUIView runs synchronously inside SwiftUI's view-update cycle.
    /// Calling setCamera from updateUIView races SwiftUI's still-in-progress mount and silently
    /// dropped the entire .safeAreaInset(...) overlay chain (toolbar, ASP banner, Park Until pill)
    /// in the reverted W8.5c-polish PR #31. .onChange fires after the current view-update cycle
    /// completes, eliminating that race. This is the core architectural fix for #31.
    @State private var coordinatorActions = MapViewRepresentable.CoordinatorActions()

    // MARK: - W8.5b: Drive Mode state

    /// True when Drive Mode is active (route + destination pin on map).
    @State private var driveModeActive: Bool = false

    /// The best-scoring route currently rendered on the map. Nil when Drive Mode inactive.
    @State private var activeRoute: DriveRoute? = nil

    /// Destination coordinate for the route pin. Nil when Drive Mode inactive.
    @State private var driveDestinationCoordinate: CLLocationCoordinate2D? = nil

    /// Controls presentation of the full-screen destination search cover.
    @State private var showDriveModeDestination: Bool = false

    // MARK: - W8.5c: Drive Mode active layer state

    /// Parking commentary service — instantiated once per app session (R-7).
    @State private var drivingVoice = DrivingVoice()

    /// Driving context service — owns block-change detection and voice cue orchestration.
    @State private var drivingContextService: DrivingContextService? = nil

    /// Current driving context (nil when no street data near GPS position).
    @State private var drivingContext: DrivingContext? = nil

    /// Option A: True when the custom Drive Mode follow is paused due to a user map gesture.
    ///
    /// Set to `true` by `onDrivePanDetected` (MapViewRepresentable → ContentView callback,
    /// name kept for diff-minimality) when ANY user gesture — pan OR pinch — is detected
    /// during Drive Mode (FT-5 `isUserInteracting` signal, no longer narrowed to pan-only).
    /// Cleared to `false` on Recenter tap or Drive Mode exit.
    ///
    /// FT-17 (2026-08-12): reversed the original OQ-4 resolution ("pan pauses, pinch does
    /// not") after Kevin's build-15 field report — a pinch that also drifted MapKit's pan
    /// recognizer silently discarded the user's zoom while leaving follow active, so the
    /// camera re-centered/re-zoomed under the user's fingers with no way to reach Recenter.
    /// See `docs/field-testing-log.md` FT-17 and `docs/tf2-11-drive-camera-ownership-spec.md`
    /// OQ-4 (amended).
    ///
    /// When `true` → per-tick `setDriveCamera` is skipped (follow paused); Recenter button shown.
    /// When `false` → per-tick `setDriveCamera` fires on every GPS update (following active).
    ///
    /// Managed independently of `isUserInteracting` (which auto-clears on regionDidChangeAnimated).
    /// `followPaused` stays `true` until the user explicitly taps Recenter — matching Waze/Apple
    /// Maps behavior where a gesture keeps the view locked until the user asks to go back.
    @State private var followPaused: Bool = false

    /// Option A: User-adjustable camera altitude during Drive Mode (meters above ground).
    ///
    /// Initialized to `altitudeForSpan(driveModeCameraSpan)` (~621m) on Drive Mode entry.
    /// Updated by `onDrivePinchZoomed` when the user pinch-zooms during Drive Mode (OQ-3:
    /// preserve user-adjusted altitude — Waze model).
    ///
    /// FT-17 note: since a pinch now also sets `followPaused = true` (see above), the
    /// per-tick `setDriveCamera` that would have honoured this value is skipped until the
    /// user taps Recenter — and Recenter unconditionally resets this to the FT-8 default
    /// (`recenterDriveMode()`, deliberately left unchanged by FT-17 — see PR body). The
    /// `onDrivePinchZoomed` capture is effectively inert today; kept as the seam a future
    /// "Recenter preserves zoom" change would reuse.
    ///
    /// Reset to the FT-8 default on Recenter tap (explicit "go back to default" action).
    /// Reset to 0 and re-initialized on Drive Mode re-entry.
    @State private var currentDriveAltitude: CLLocationDistance = 0

    /// S-1 fix (spec §7 R-3, AC-DM.23): controls the one-time background-limitation alert.
    /// Set to true on the first-ever Drive Mode start if the gate key is not yet set.
    /// The gate itself is evaluated via BackgroundNoteGate; this bool drives the .alert.
    @State private var showDriveModeBackgroundNote: Bool = false

    // MARK: - FT-12: Parking 101 first-launch banner

    /// Controls visibility of `ParkingGuidePromptBanner` in `bottomSafeAreaContent`.
    /// Set to true once at launch (in `performLaunchSetup`) if `ParkingGuidePromptGate`
    /// says it hasn't been shown yet. Set back to false — and the gate marked shown —
    /// on tap-to-open, X-dismiss, or the banner's own ~8s auto-hide timer.
    @State private var showParkingGuideBanner: Bool = false

    // MARK: - TF2-16: Drive Mode heading snap-to-street

    /// Which heading source currently drives the camera/puck: raw GPS course, or the
    /// matched street segment's own travel-direction bearing (low-confidence snap).
    /// Updated per-tick in `handleLocationUpdate()` via `DriveHeadingSnap.nextHeadingSource`.
    /// Reset to `.course` on Drive Mode entry and exit (same reset pattern as `followPaused`
    /// / `currentDriveAltitude`).
    @State private var driveHeadingSource: HeadingSourceKind = .course

    /// The heading value actually fed to `MapViewRepresentable(driveHeading:)`. Equal to
    /// `locationService.driveHeading` when `driveHeadingSource == .course`, or the
    /// street-snap bearing from `DriveHeadingSnap.snappedHeading` when `.streetSnap`.
    /// Reset to `nil` on Drive Mode exit (mirrors `locationService.driveHeading` resetting
    /// to `nil` in `endDriveMode()`).
    @State private var effectiveDriveHeading: Double? = nil

    // MARK: - CM-3: Drive Mode style (destination / cruise / inactive)

    /// Explicit mode discriminant for Drive Mode variants.
    ///
    /// Set at each Drive Mode entry point:
    ///   - Destination Mode entry (DriveModeDestinationView.onRouteReady): `.destination`
    ///   - Cruise Mode entry ("Find Parking" button): `.cruise`
    ///   - Drive Mode exit (endDriveMode): `.inactive`
    ///
    /// Checked in `handleFinalApproachUpdate` to prevent FinalApproachService from
    /// running during Cruise Mode sessions (AC-CM.12, AC-CM.13).
    ///
    /// Also forwarded to `DrivingContextService.setCruiseMode` so the voice policy
    /// switches to `CruiseVoicePolicy` in Cruise Mode.
    @State private var driveModeStyle: DriveModeStyle = .inactive

    // MARK: - W8.5d: Final approach state

    /// Current proximity state relative to the Drive Mode destination.
    /// Recomputed by `handleFinalApproachUpdate` on every `driveModeDistanceMeters` change.
    /// Drives: approaching-strip visibility, voice gap, arrival prompt.
    /// Reset to .outside when Drive Mode exits (in `handleDriveModeChange(false)`).
    @State private var finalApproachState: FinalApproachState = .outside

    /// One-shot gate: true after the arrival prompt has fired in this Drive Mode session.
    /// Prevents re-firing if GPS jitters around the 50m boundary (R-3 hysteresis guard).
    /// Reset to false when Drive Mode exits (in `handleDriveModeChange(false)`).
    /// Per R-4: if `arrivalCoord == nil` at the moment of `.arrived`, this stays false
    /// so a subsequent `.onChange` can retry when GPS recovers.
    @State private var arrivalPromptFired: Bool = false

    // MARK: - Tier 3 sub-PR #2: Resting long-press action menu state

    /// Coordinate captured when the user long-presses the map while not driving.
    /// Held while the confirmationDialog is visible; cleared on any action selection or cancel.
    @State private var pendingLongPressCoord: CLLocationCoordinate2D? = nil

    /// True while the resting long-press confirmationDialog is presented.
    /// The dialog has three actions: "Park my car here", "Report enforcement or
    /// sweeper", and (FT-15/TF2-15) "Report closure (film shoot / construction)."
    @State private var showRestingActionMenu: Bool = false

    // MARK: - FT-15 / TF2-15 Stream B2: Block-scoped report tap-select mode state

    /// True while the map is in block-select mode (§4.2 step 2): tapping a rendered
    /// segment toggles it into/out of `selectedBlockKeys` instead of opening
    /// `BlockDetailView`. Entered via the resting long-press dialog's third action;
    /// exited via the floating bar's Cancel button or by tapping Continue.
    ///
    /// Mutually exclusive with Drive Mode, enforced from BOTH directions (QA pass-1
    /// finding: an earlier revision of this comment claimed mutual exclusion but only
    /// the first of these two was actually true):
    ///   1. Block-select → Drive Mode is blocked: `handleLongPress` only shows the
    ///      confirmationDialog (the sole entry point that sets this `true`) when
    ///      `driveModeActive == false`.
    ///   2. Drive Mode → block-select is blocked/cleared: `recenterButtonStack` — the
    ///      sole UI path to both Drive Mode entry points — is hidden whenever this is
    ///      `true` (see `mapZStack`), AND `handleDriveModeAndCamera` force-clears this
    ///      flag (`cancelBlockSelectMode()`) on every Drive Mode entry as a structural,
    ///      single-funnel backstop, since ALL entry paths (`enterCruiseMode()`,
    ///      destination mode's `onRouteReady`) converge on the one
    ///      `.onChange(of: driveModeActive)` handler.
    /// So this flag and `driveModeActive` are never both `true` at once.
    @State private var blockSelectModeActive: Bool = false

    /// The set of `Segment.blockfaceKey` values currently selected during block-select
    /// mode (§4.2 step 3). Drives the `MapViewRepresentable` multi-segment highlight
    /// overlay directly — kept populated after `blockSelectModeActive` flips back to
    /// `false` on Continue so the highlight stays visible while
    /// `BlockRestrictionReportSheet` is open, then cleared when that sheet dismisses
    /// (success or cancel) via `.sheet(item:)`'s `onDismiss` closure.
    @State private var selectedBlockKeys: Set<String> = []

    /// "Both curbs" toggle (§4.2 step 4). Default ON, matching Kevin's own canonical
    /// case (E 2nd St, 2 blocks × 2 curbs = 4 blockfaces). Reset to `true` every time
    /// block-select mode is (re-)entered.
    @State private var bothCurbsOn: Bool = true

    // MARK: - Community 1.0 / Tier 1: Community pin service + map state

    /// Community pin service. Fetches filming / asp_suspended_today / special_event pins
    /// from Supabase (Tier 1 read) and provides the authenticated write path for crowd
    /// pins + votes (Tier 3 sub-PR #1).
    ///
    /// Initialized with the shared `authService` so all writes use the same anonymous
    /// identity (AC-A5). The convenience init reads SUPABASE_URL + SUPABASE_ANON_KEY
    /// from Bundle.main (Config.xcconfig → Info.plist bridge).
    ///
    /// Note: `pinService` cannot be a `@State` with an inline initializer that captures
    /// `authService` because stored properties can't reference other stored properties in
    /// their default expressions. The service is initialized in the ContentView init (below).
    @State private var pinService: CommunityPinService

    /// Map-marker-only subset of visible community pins (filming + special_event).
    /// `asp_suspended_today` is NOT included here — it drives the ASP banner supplement (spec §4).
    ///
    /// Updated via `.onChange(of: pinService.visiblePinsGeneration)` — NEVER inside `updateUIView`
    /// (invariant I-1 from HANDOFF.md Changelog 2026-05-26 / spec §5.2).
    /// Uses visiblePinsGeneration (Int, Equatable) rather than visiblePins ([CommunityPin])
    /// because CommunityPin is not Equatable — AC-D20 freezes CommunityPin.swift.
    @State private var communityPins: [CommunityPin] = []

    // MARK: - Bundle version strings (passed into SettingsView)

    private let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private let buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    // MARK: - Init

    /// Initializes ContentView with the shared AppDelegate and SupabaseAuthService.
    ///
    /// The explicit init is required because `pinService` (a `@State` property) depends on
    /// `authService`, and Swift stored properties cannot reference sibling stored properties
    /// in their default expressions. Wrapping `State` manually lets us pass `authService`
    /// into `CommunityPinService.init(authService:)` at init time.
    ///
    /// All other `@State` properties retain their inline default-expression initializers;
    /// those do not depend on injected values.
    init(appDelegate: AppDelegate, authService: SupabaseAuthService) {
        self.appDelegate = appDelegate
        self.authService = authService
        // CommunityPinService reads SUPABASE_URL + SUPABASE_ANON_KEY from Bundle.main
        // and attaches the shared authService for authenticated writes.
        self._pinService = State(initialValue: CommunityPinService(authService: authService))
    }

    // MARK: - Constants

    /// Hide all overlays when zoomed out beyond this span (same as W2/W3 behavior).
    /// Viewport-polish: lowered from 0.1 to 0.04 (4,453 m N-S, ~44 Manhattan blocks).
    /// At 0.04° the LRU cap (200 tiles) covers the viewport without eviction patchwork.
    /// Above 0.04° individual block faces are illegible anyway — hiding is correct UX.
    private let polylineHideSpanThreshold: Double = 0.04

    /// Tap hit threshold in meters (matches W4 behavior).
    private let tapHitThresholdMeters: Double = 20.0

    /// W5: Radius for candidate-segment search (matches PWA findCandidateSegments).
    private let pinDropRadiusMeters: Double = 35.0

    // MARK: - Derived

    /// W8.5c-polish PR-1 (Feature B): Extra top padding for the isolated "End" control
    /// (FT-18: `endDriveControl`) when the ASP banner is visible, so it clears the banner
    /// and doesn't obscure its text. The ASP banner is approximately 44pt tall (subheadline
    /// font + 12pt vertical padding × 2). Always non-zero: all three SuspensionBannerState
    /// cases render a visible banner.
    private var endDrivePillTopPadding: CGFloat {
        paddingForBannerState(bannerState)
    }

    private var selectedSegment: Segment? {
        guard let id = selectedSegmentID else { return nil }
        return tileLoader.segments.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        mapLayerWithEvents
            .onReceive(parkPinService.pinDropped) { newCar in handlePinDropped(newCar) }
            .onChange(of: appDelegate.pendingDeepLinkCarID) { _, carID in routePendingDeepLink(carID) }
            .sheet(item: $activeSheet, onDismiss: {
                if selectedSegmentID != nil { selectedSegmentID = nil }
                // FT-15/TF2-15 Stream B2: clears the block-select highlight overlay on
                // ANY dismiss path (Submit success, Cancel button inside the sheet, OR a
                // swipe-to-dismiss that never calls the sheet's own onDismiss closure) —
                // same catch-all role selectedSegmentID plays above.
                if !selectedBlockKeys.isEmpty { selectedBlockKeys = [] }
            }) { sheet in sheetContent(sheet) }
            .fullScreenCover(isPresented: $showDriveModeDestination) { driveModeDestinationCover }
            .alert("Keep WePark in Front", isPresented: $showDriveModeBackgroundNote) {
                Button("Got It", role: .cancel) {}
            } message: {
                Text("Parking commentary will pause if you background WePark during your drive. Keep the app in front for continuous guidance.")
            }
            // Tier 3 sub-PR #2: Resting long-press action menu.
            // Fires when handleLongPress(at:) sets showRestingActionMenu = true
            // (only when driveModeActive == false — in-drive long-press is a no-op).
            .confirmationDialog(
                "What do you want to do?",
                isPresented: $showRestingActionMenu,
                titleVisibility: .visible
            ) {
                Button("Park my car here") {
                    guard let coord = pendingLongPressCoord else {
                        pendingLongPressCoord = nil
                        return
                    }
                    pendingLongPressCoord = nil
                    // Run W5 candidate-segment detection (Path A) — same logic as the old
                    // handleLongPress implementation, moved here per spec §4.1.
                    let candidates = findCandidateSegments(
                        lat: coord.latitude,
                        lng: coord.longitude,
                        radius: pinDropRadiusMeters,
                        max: 4
                    )
                    let detected = candidates.first?.segment
                    let detectedDistance = candidates.first?.distanceMeters
                    let alternatives = Array(candidates.dropFirst())
                    let intent = PinDropIntent(
                        pinLat: coord.latitude,
                        pinLng: coord.longitude,
                        detectedSegment: detected,
                        detectedSegmentDistance: detectedDistance,
                        alternativeCandidates: alternatives
                    )
                    activeSheet = .parkConfirm(intent)
                }
                Button("Report enforcement or sweeper") {
                    guard let coord = pendingLongPressCoord else {
                        pendingLongPressCoord = nil
                        return
                    }
                    pendingLongPressCoord = nil
                    // Resting path: no street context (not in Drive Mode). streetName = nil →
                    // ReportSheet shows "Reporting at current location" fallback.
                    //
                    // FT-11: Resolve the nearest segment (same radius as W5 park-pin search)
                    // so ReportSheet can show the direction picker with real cross-street labels.
                    // Nil when the long-press is off any segment (OD-1: picker hidden).
                    let reportSegment = findCandidateSegments(
                        lat: coord.latitude,
                        lng: coord.longitude,
                        radius: pinDropRadiusMeters,
                        max: 1
                    ).first?.segment
                    activeSheet = .reportPin(coord: coord, streetName: nil, segment: reportSegment)
                }
                // FT-15/TF2-15 §4.2 step 1: third action, added per the spec's own
                // recommendation to extend this existing dialog rather than add a new
                // toolbar button (avoids further crowding the toolbar cluster — FT-13's
                // "?" button already landed there). This dialog is unaffected by FT-18's
                // Bottom Dock redesign: FT-18 only restructured Drive-Mode-ACTIVE chrome
                // (`endDriveControl`, `recenterRow`, `driveActionRow`, gear visibility);
                // this resting long-press dialog only ever presents when
                // `driveModeActive == false` (see `handleLongPress`'s guard), so it never
                // shares screen real estate with any FT-18-restructured element.
                //
                // Unlike the two actions above, this one does NOT need
                // `pendingLongPressCoord` — block-select mode assumes the reporter is
                // standing at/near the affected blocks (spec §4.2 point 6; the map is
                // already centered there), so entering the mode doesn't need the
                // long-press coordinate at all.
                Button("Report closure (film shoot / construction)") {
                    pendingLongPressCoord = nil
                    enterBlockSelectMode()
                }
                Button("Cancel", role: .cancel) {
                    pendingLongPressCoord = nil
                }
            }
    }

    // MARK: - W8.5b: Full-screen destination search cover

    /// Presents `DriveModeDestinationView` as a full-screen cover (OQ-2: Option C).
    /// This modifier is separate from `.sheet(item:)` and can coexist with it,
    /// but the Drive button guard ensures they are never simultaneously presented.
    @ViewBuilder
    private var driveModeDestinationCover: some View {
        DriveModeDestinationView(
            currentRegion: region,
            segments: tileLoader.segments,
            userLocation: locationService.userLocation,
            locationService: locationService,
            onRouteReady: { route, destination in
                // W8.5b: Route ready — enter Destination Mode.
                // CM-3: Set driveModeStyle = .destination BEFORE driveModeActive = true
                // so handleDriveModeChange reads the correct style when it fires.
                driveModeStyle = .destination
                activeRoute = route
                driveDestinationCoordinate = destination
                driveModeActive = true
            }
        )
    }

    // MARK: - Sheet content builder

    /// Builds the sheet content for a given `ActiveSheet` case.
    ///
    /// Extracted from the `.sheet(item:)` modifier closure to reduce type-checker
    /// expression complexity in `ContentView.body` (W8.5c-polish PR-1 fix).
    /// The original inline switch statement was at the edge of the type-checker's
    /// complexity budget; adding new @ViewBuilder properties pushed it over the limit.
    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .blockDetail(let segment):
            blockDetailSheetContent(segment)

        case .parkConfirm(let intent):
            ParkConfirmView(
                intent: intent,
                engine: engine,
                onConfirm: { result in
                    activeSheet = nil
                    confirmPinDrop(result: result)
                },
                onCancel: {
                    activeSheet = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .parkedCarDetail(let car):
            ParkedCarDetailView(
                parkedCar: car,
                engine: engine,
                loadedSegments: tileLoader.segments,
                parkPinService: parkPinService,
                // FT-15/TF2-15 (§9.2): so the sheet can look up an active block-scoped
                // restriction covering wherever this car is parked — "the highest-value
                // consumption point in the whole spec."
                pinService: pinService,
                onDismiss: {
                    activeSheet = nil
                },
                onClearPin: {
                    activeSheet = nil
                    // W6: Cancel notifications before clearing the pin.
                    NotificationScheduler.shared.cancelAll(for: car)
                    parkPinService.clearPin()
                    // W7.5: Clear Park Until filter — no orphan filter for a non-existent car.
                    parkUntilMode = false
                    parkUntilTarget = nil
                    rebuildOverlays(at: .nowET)
                },
                // FT-15/TF2-15 (§9.2): tap-through to PinDetailSheet, same
                // activeSheet-reassignment pattern as blockDetailSheetContent's
                // onOpenRestriction (and .signCheckConfirm's onConfirm precedent).
                onOpenRestriction: { pin in activeSheet = .pinDetail(pin) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .notificationRationale:
            // W6: One-time rationale sheet. interactiveDismissDisabled(true) prevents
            // accidental swipe-away which would skip the permission request entirely.
            NotificationRationaleView(
                onDismiss: {
                    activeSheet = nil
                },
                onPermissionGranted: {
                    // Schedule notifications for the current pin after permission is granted.
                    guard let car = parkPinService.parkedCar else { return }
                    Task { @MainActor in
                        NotificationScheduler.shared.schedule(
                            for: car,
                            loadedSegments: tileLoader.segments,
                            engine: engine
                        )
                    }
                }
            )
            .presentationDetents([.medium])
            .interactiveDismissDisabled(true)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .settings:
            // W7: Global settings sheet.
            SettingsView(
                notificationsMuted: $notificationsMuted,
                offsets: $reminderOffsets,
                onUnmute: {
                    // Reschedule notification for the current pin if it opted in.
                    if let car = parkPinService.parkedCar, car.notifyOnRestriction {
                        NotificationScheduler.shared.schedule(
                            for: car,
                            loadedSegments: tileLoader.segments,
                            engine: engine
                        )
                    }
                    // Show "Reminders re-enabled" toast regardless of whether a pin exists.
                    ToastService.shared.show(message: "Reminders re-enabled")
                },
                onOffsetsChange: {
                    handleReminderOffsetsChange()
                },
                appVersion: appVersion,
                buildNumber: buildNumber
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .parkUntil:
            // W7.5 pass-2: "Parking until when?" sheet — presented via standalone toolbar
            // button (filter-first UX). Car-agnostic; filter persists across pin drops.
            ParkUntilSheet(
                onConfirm: { targetDate in
                    activeSheet = nil
                    parkUntilTarget = targetDate
                    parkUntilMode = true
                    rebuildOverlays(at: .nowET)
                    let timeStr = ParkUntilSheet.formatTime(targetDate)
                    ToastService.shared.show(message: "Showing blocks free until \(timeStr)")
                },
                onSkip: {
                    activeSheet = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .pinDetail(let pin):
            // Community 1.0 / Tier 1: read-only community pin detail sheet.
            // Extracted into pinDetailSheetContent(_:) to reduce type-checker expression
            // complexity in sheetContent(_:) — same pattern as PR-1 @ViewBuilder extractions.
            pinDetailSheetContent(pin)

        case .reportPin(let coord, let streetName, let seg):
            // Tier 3 sub-PR #2: Universal community report sheet.
            // Coordinate source depends on entry path:
            //   - Resting: coord = long-press point on map; streetName = nil
            //   - In-drive: coord = user GPS at moment of tap; streetName = drivingContext?.street
            // Bug #4: streetName passed through so ReportSheet shows "Reporting on <street>".
            // FT-11: seg passed through so ReportSheet shows the direction picker.
            ReportSheet(
                coordinate: coord,
                pinService: pinService,
                onDismiss: { activeSheet = nil },
                streetName: streetName,
                segment: seg
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .signCheckConfirm(let intent):
            // TF2-7: Sign-check confirmation sheet — presented when the driver taps "Park here"
            // in the Drive Mode overlay. Pre-step before ParkConfirmView.
            //
            // TF2-9 fix: [.medium, .large] detents + .ultraThickMaterial background.
            //   - .medium alone can clip the 5-item checklist + title + subtitle + sticky CTAs
            //     on smaller devices or at large dynamic type sizes. .large ensures the user
            //     can always reach all content.
            //   - .ultraThickMaterial replaces .regularMaterial to block the Drive Mode bottom
            //     card and other overlay text from bleeding through the sheet background.
            //     The checklist view adds its own Color(.systemBackground) fill as a second
            //     layer of defence (the material alone may still be slightly translucent at the
            //     fraction boundary of the .medium detent).
            //
            // onConfirm: dismisses this sheet and opens ParkConfirmView with the same intent.
            //   The intent passes through unchanged — no coordinate mutation (spec §5.3).
            // onCancel: dismisses the sheet without proceeding to pin drop (swipe or Cancel).
            SignCheckConfirmView(
                intent: intent,
                onConfirm: { confirmedIntent in
                    activeSheet = .parkConfirm(confirmedIntent)
                },
                onCancel: {
                    activeSheet = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThickMaterial)
            .presentationCornerRadius(20)

        case .arrivalPrompt(let coord):
            // W8.5d: Arrival prompt — fires once per Drive Mode session when driver reaches
            // within FinalApproachService.arrivalThresholdMeters of the destination.
            //
            // "Park Here" confirm path (spec §3.5):
            //   1. Dismiss sheet.
            //   2. Construct ParkedCar at the ARRIVAL coordinate (user's GPS position, NOT destination).
            //   3. parkPinService.save(car) → pinDropped fires → W7.5 Park Until sheet fires naturally.
            //   4. Drive Mode ends (driveModeActive = false → handleDriveModeChange(false)).
            //
            // "Not Yet" dismiss path:
            //   1. Dismiss sheet only. Drive Mode stays active. arrivalPromptFired stays true.
            ArrivalPromptSheet(
                arrivalCoordinate: coord,
                nearestStreet: drivingContext?.street,
                onParkHere: { arrivalCoord in
                    activeSheet = nil
                    // Capture the old car ID BEFORE save() overwrites parkedCar.
                    // onReceive(pinDropped) reads previousCarID to cancel old notifications.
                    previousCarID = parkPinService.parkedCar?.id
                    // Build ParkedCar at the arrival coordinate.
                    // Use drivingContext segment info if available for street/from/to metadata.
                    let car = ParkedCar(
                        id: UUID(),
                        latitude: arrivalCoord.latitude,
                        longitude: arrivalCoord.longitude,
                        detectedSegmentID: nil,  // arrival-path: no tap-segment detection
                        detectedSide: nil,
                        street: drivingContext?.street,
                        fromStreet: drivingContext?.from,
                        toStreet: drivingContext?.to,
                        parkedAt: .nowET,
                        notifyOnRestriction: true  // default on, user can toggle in ParkedCarDetailView
                    )
                    parkPinService.save(car)
                    // End Drive Mode — triggers handleDriveModeChange(false) which resets
                    // finalApproachState + arrivalPromptFired + stops location/voice services.
                    // endDriveMode() does NOT touch activeSheet, so the assignment below is safe.
                    endDriveMode()
                    // W8.5d pass-2 (QA Finding #1, Option B): auto-fire Park Until sheet
                    // immediately after the arrival-confirm commit moment. The user has just
                    // tapped "Park Here" — this is the natural follow-up question.
                    // The W7.5 pivot to standalone-toolbar still stands for the set-destination
                    // anxiety path; the arrival-confirm path explicitly opts back into auto-fire
                    // because the user has already committed to parking.
                    activeSheet = .parkUntil
                },
                onNotYet: {
                    // OQ-6: Drive Mode stays active. arrivalPromptFired stays true (no re-fire).
                    activeSheet = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .parkingGuide:
            // FT-12: opened from the first-launch prompt banner tap. The banner's
            // tap/dismiss handlers already call ParkingGuidePromptGate().markShown()
            // and clear showParkingGuideBanner before this sheet presents.
            NavigationStack {
                ParkingGuideView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { activeSheet = nil }
                        }
                    }
            }
            .presentationDragIndicator(.visible)

        case .blockRestrictionReport(let segments):
            // FT-15/TF2-15 Stream B2: block-scoped restriction report form.
            // onDismiss covers both Submit-success and the sheet's own Cancel button —
            // the .sheet(item:) modifier's onDismiss above additionally clears
            // selectedBlockKeys for the swipe-to-dismiss path this closure can't see.
            BlockRestrictionReportSheet(
                selections: segments,
                pinService: pinService,
                onDismiss: { activeSheet = nil }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)
        }
    }

    // MARK: - Community 1.0 / Tier 1: Pin detail sheet content

    /// Builds the content for `ActiveSheet.pinDetail`.
    ///
    /// Extracted from `sheetContent(_:)` to reduce type-checker expression complexity in
    /// the switch statement — same `@ViewBuilder` extraction pattern used in W8.5c-polish
    /// PR-1 for `driveModeOverlayLayer`, `bottomSafeAreaContent`, and `sheetContent` itself.
    @ViewBuilder
    private func pinDetailSheetContent(_ pin: CommunityPin) -> some View {
        PinDetailSheet(
            pin: pin,
            onDismiss: { activeSheet = nil },
            authService: authService,
            pinService: pinService
        )
        .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)
    }

    // MARK: - FT-15 / TF2-15: Block detail sheet content

    /// Builds the content for `ActiveSheet.blockDetail`.
    ///
    /// Extracted for the same type-checker-complexity reason as `pinDetailSheetContent`.
    /// FT-15/TF2-15 (§9.2) additions: `pinService` (so the sheet can look up an active
    /// block-scoped restriction for this segment) and `onOpenRestriction` (tap-through to
    /// `PinDetailSheet`, reusing the existing `activeSheet = .pinDetail(pin)` transition —
    /// SwiftUI's `.sheet(item:)` handles the dismiss-then-present automatically, same
    /// precedent as `.signCheckConfirm`'s `onConfirm` reassigning `activeSheet` directly).
    @ViewBuilder
    private func blockDetailSheetContent(_ segment: Segment) -> some View {
        BlockDetailView(
            segment: segment,
            engine: engine,
            onDismiss: { dismissBlockDetail() },
            onParkHere: {
                // W5: Path B — segment already known; use midpoint as coordinate.
                initiatePathBPinDrop(from: segment)
            },
            pinService: pinService,
            onOpenRestriction: { pin in activeSheet = .pinDetail(pin) }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(20)
    }

    // MARK: - Overlay rebuild

    /// Partitions loaded segments by current state → 5 MKMultiPolyline coordinate groups
    /// + selected-block highlight coordinates, then bumps the generation to trigger
    /// a MapViewRepresentable update.
    ///
    /// This is O(n) over loaded segments (~500–2,000 at street-level zoom).
    /// Called on:
    ///   - 60s timer tick
    ///   - Segment array change (tile load complete)
    ///   - Selection change
    private func rebuildOverlays(at now: Date) {
        // Zoom-threshold gating: if zoomed out, clear all overlays.
        guard region.span.latitudeDelta <= polylineHideSpanThreshold else {
            overlayGeneration += 1
            overlayPayload = MapViewRepresentable.OverlayPayload(generation: overlayGeneration)
            return
        }

        // W7.5: Park Until mode — classify segments by interval-free status (binary green/red).
        if parkUntilMode, let target = parkUntilTarget {
            // Stale-target guard: if the target has passed, silently clear the filter and
            // fall through to normal 5-state classification.
            guard target > now else {
                parkUntilMode = false
                parkUntilTarget = nil
                // Tail-call to the normal path — note: Swift doesn't TCO, but the rebuildOverlays
                // call below is safe because we cleared the flags before recursing.
                rebuildOverlays(at: now)
                return
            }

            var freeCoords:    [[CLLocationCoordinate2D]] = []
            var notFreeCoords: [[CLLocationCoordinate2D]] = []

            for segment in tileLoader.segments {
                let coords = segment.coordinates
                guard coords.count >= 2 else { continue }
                if segment.id == selectedSegmentID { continue }
                if engine.isFree(segment: segment, from: now, until: target) {
                    freeCoords.append(coords)
                } else {
                    notFreeCoords.append(coords)
                }
            }

            // Selected-block highlight.
            var selectedCoords: [CLLocationCoordinate2D]? = nil
            var selectedState: CurrentState = .unknown
            if let seg = selectedSegment {
                let coords = seg.coordinates
                if coords.count >= 2 {
                    selectedCoords = coords
                    // Color selected block by its Park Until result.
                    selectedState = engine.isFree(segment: seg, from: now, until: target)
                        ? .freeComfortably : .restrictedNow
                }
            }

            overlayGeneration += 1
            overlayPayload = MapViewRepresentable.OverlayPayload(
                freeComfortably:        freeCoords,
                freeButRestrictionSoon: [],
                meteredActive:          [],
                restrictedNow:          notFreeCoords,
                unknown:                [],
                selectedCoords:         selectedCoords,
                selectedState:          selectedState,
                generation:             overlayGeneration
            )
            return
        }

        var freeComfortably:        [[CLLocationCoordinate2D]] = []
        var freeButRestrictionSoon: [[CLLocationCoordinate2D]] = []
        var meteredActive:          [[CLLocationCoordinate2D]] = []
        var restrictedNow:          [[CLLocationCoordinate2D]] = []
        var unknown:                [[CLLocationCoordinate2D]] = []

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            // Skip the selected segment from group overlays — it will be rendered
            // by the selectedBlock overlay at lineWidth:6 instead.
            if segment.id == selectedSegmentID { continue }
            let state = engine.currentState(for: segment, at: now)
            switch state {
            case .freeComfortably:        freeComfortably.append(coords)
            case .freeButRestrictionSoon: freeButRestrictionSoon.append(coords)
            case .meteredActive:          meteredActive.append(coords)
            case .restrictedNow:          restrictedNow.append(coords)
            case .unknown:                unknown.append(coords)
            }
        }

        // Selected-block highlight.
        var selectedCoords: [CLLocationCoordinate2D]? = nil
        var selectedState: CurrentState = .unknown
        if let seg = selectedSegment {
            let coords = seg.coordinates
            if coords.count >= 2 {
                selectedCoords = coords
                selectedState = engine.currentState(for: seg, at: now)
            }
        }

        overlayGeneration += 1
        overlayPayload = MapViewRepresentable.OverlayPayload(
            freeComfortably:        freeComfortably,
            freeButRestrictionSoon: freeButRestrictionSoon,
            meteredActive:          meteredActive,
            restrictedNow:          restrictedNow,
            unknown:                unknown,
            selectedCoords:         selectedCoords,
            selectedState:          selectedState,
            generation:             overlayGeneration
        )
    }

    // MARK: - Map layer stack

    /// The full view hierarchy (ZStack with map + overlays).
    ///
    /// Extracted from `body` so the Swift type-checker treats it as a separate expression
    /// from the modifier chain. The body is simply `mapLayerStack` with all the .task /
    /// .onChange / .sheet modifiers chained on top — two manageable expressions instead of one
    /// giant one that exhausts the compiler's complexity budget.
    /// ZStack of all visual layers (map, gear button, Drive Mode overlays, toast).
    /// Separated from modifier chain for type-checker budget.
    @ViewBuilder
    private var mapZStack: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .topTrailing) {
                mapRepresentable
                    .ignoresSafeArea()
                    .safeAreaInset(edge: .top) { ASPBanner(state: bannerState) }
                    .safeAreaInset(edge: .bottom) { bottomSafeAreaContent }
                // FT-18: the browse-mode toolbar (Find me / Find my car / Park Until entry /
                // combined Drive entry) and the isolated Drive Mode "End" control share this
                // top-trailing corner but are mutually exclusive — exactly one renders at a
                // time, matching Proposal 1's "top of screen reduced to banner + End control"
                // during Drive Mode (Kevin's ruling #1).
                //
                // FT-15/TF2-15 QA fix: `recenterButtonStack` is ALSO hidden during
                // block-select mode — it's the sole UI path to both Drive Mode entry points
                // (`driveEntryButton`'s "Drive to a destination" / "Find Parking nearby"),
                // so hiding it here structurally prevents starting Drive Mode while
                // block-select is active, rather than re-guarding each entry point
                // individually. `handleDriveModeAndCamera` additionally force-clears
                // block-select state on every Drive Mode entry as a self-healing backstop —
                // see that function's doc comment for why both together, not either alone.
                if driveModeActive {
                    endDriveControl
                } else if recenterButtonStackVisible(
                    driveModeActive: driveModeActive,
                    blockSelectModeActive: blockSelectModeActive
                ) {
                    recenterButtonStack
                        .padding(.top, 100)
                        .padding(.trailing, 12)
                }
            }
            // FT-18 ruling #3: gear button hidden entirely during Drive Mode — not needed
            // mid-drive, and resolves F2 (the pre-FT-18 gear button / End Drive pill
            // coordinate collision, both previously at top-leading) by removal.
            if gearButtonVisible(driveModeActive: driveModeActive) {
                gearButtonOverlay
            }
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ToastHostView().padding(.top, proxy.safeAreaInsets.top)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// ZStack + launch/scene modifiers (first 6).
    @ViewBuilder
    private var mapLayerStack: some View {
        mapZStack
            .task { await performLaunchSetup() }
            .onAppear { handleOnAppear() }
            .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }
            .onChange(of: notificationsMuted) { _, newValue in handleNotificationsMutedChange(newValue) }
            .onChange(of: driveModeActive) { _, active in handleDriveModeAndCamera(active) }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in handleTimerTick() }
    }

    /// mapLayerStack + overlay/event modifiers (second 6).
    @ViewBuilder
    private var mapLayerWithEvents: some View {
        mapLayerStack
            .onChange(of: tileLoader.segments.count) { _, _ in handleSegmentsChanged() }
            .onChange(of: selectedSegmentID) { _, _ in handleSelectionChanged() }
            .onChange(of: locationService.locationUpdateCount) { _, _ in handleLocationUpdate() }
            .onChange(of: driveModeDistanceMeters) { _, distance in handleFinalApproachUpdate(distance) }
            // Observe visiblePinsGeneration (Int) rather than visiblePins ([CommunityPin])
            // because CommunityPin is not Equatable — AC-D20 freezes CommunityPin.swift.
            // visiblePinsGeneration increments on every visiblePins assignment.
            .onChange(of: pinService.visiblePinsGeneration) { _, _ in handleVisiblePinsChange(pinService.visiblePins) }
            .onReceive(parkPinService.firstPinDropped) { handleFirstPinDropped() }
    }

    // MARK: - W7: Gear button overlay

    /// Gear button (top-left, same vertical offset as recenter buttons).
    /// Extracted from `body` ZStack to reduce type-checker expression complexity.
    ///
    /// FT-13: also hosts the Parking 101 guide ("?") button, placed immediately to the
    /// gear's right. Same anatomy (44x44, .regularMaterial RoundedRectangle, .secondary
    /// tint) so the pair reads as one utility cluster per the TF2-18 button-anatomy pass.
    @ViewBuilder
    private var gearButtonOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                Button { activeSheet = .settings } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Open settings")

                // FT-13: Parking 101 guide entry point, always reachable from the map
                // toolbar (not just the FT-12 first-launch banner). Hidden during Drive
                // Mode via `parkingGuideButtonVisible(driveModeActive:)`. FT-18: this whole
                // `gearButtonOverlay` is now also gated at its call site by
                // `gearButtonVisible(driveModeActive:)` (same rule) — the inner check stays
                // as an explicit, independently-testable guard rather than relying solely
                // on the outer one, and keeps this view correct if it's ever rendered from
                // a different call site in the future. Mirrors the `paddingForBannerState` /
                // `recenterPillBottomPadding` "extract as a pure function" precedent.
                if parkingGuideButtonVisible(driveModeActive: driveModeActive) {
                    Button { activeSheet = .parkingGuide } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Parking 101 guide")
                }
            }
            Spacer()
        }
        .padding(.top, 100)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Map representable callbacks (extracted for type-checker budget)

    /// Forwards region changes to TileLoader and CommunityPinService.
    private func handleRegionChanged(_ newRegion: MKCoordinateRegion) {
        region = newRegion
        tileLoader.loadTiles(forRegion: newRegion)
        // Community 1.0 / Tier 1: debounced fetch for community pins (800ms debounce).
        pinService.onRegionChanged(newRegion)
    }

    /// Forwards community pin taps to the sheet presentation.
    private func handleCommunityPinTapped(_ pin: CommunityPin) {
        activeSheet = .pinDetail(pin)
    }

    // MARK: - Map representable construction

    /// The MapViewRepresentable with all bindings wired.
    ///
    /// Extracted from `body` to reduce type-checker expression complexity — the 16-parameter
    /// initializer call with inline closures exceeded the Swift compiler's type-check budget.
    /// Same `@ViewBuilder` extraction pattern as `driveModeOverlayLayer` and `bottomSafeAreaContent`
    /// (W8.5c-polish PR-1 lesson).
    ///
    /// Architecture invariant I-1 (HANDOFF.md / spec §5): `communityPins` and
    /// `onCommunityPinTapped` are passed here; their values are driven from
    /// `.onChange(of: pinService.visiblePins)` → `handleVisiblePinsChange` in body.
    /// No annotation mutation happens inside `MapViewRepresentable.updateUIView`.
    @ViewBuilder
    private var mapRepresentable: some View {
        MapViewRepresentable(
            region: $region,
            selectedSegmentID: $selectedSegmentID,
            onTap: handleMapTap(at:),
            onLongPress: handleLongPress(at:),
            onRegionChanged: handleRegionChanged(_:),
            onCarPinTapped: openParkedCarDetail,
            carPin: parkPinService.parkedCar,
            overlayPayload: overlayPayload,
            activeRoute: activeRoute,
            destinationCoordinate: driveDestinationCoordinate,
            communityPins: communityPins,
            onCommunityPinTapped: handleCommunityPinTapped(_:),
            segments: tileLoader.segments,  // FT-11: for directional chevron bearing computation
            // FT-15/TF2-15 Stream B2: multi-segment block-select highlight (§4.2 step 3).
            blockSelectKeys: selectedBlockKeys,
            driveHeading: effectiveDriveHeading,  // TF2-16: course, or street-snap at low confidence
            driveModeActive: driveModeActive,
            onDrivePanDetected: handleDrivePanDetected,
            onDrivePinchZoomed: handleDrivePinchZoomed(_:),
            coordinatorActions: coordinatorActions
        )
    }

    // MARK: - W7.5 / W8.5c / FT-18: Bottom safe-area content ("Bottom Dock")

    /// Content pushed into the bottom safe area via .safeAreaInset(edge: .bottom).
    ///
    /// FT-18 (`docs/design/ft18-drive-mode-layout.md`, Proposal 1 — "Bottom Dock"): this is
    /// now the single bottom-anchored stack for every frequent-action / live-status control
    /// during Drive Mode, not just the card + Park Until pill. Four optional rows are
    /// siblings in one `VStack(spacing: 8)`, in a fixed order that self-resolves for every
    /// combination (S1–S6 in the design doc) without hand-computed clearance math:
    ///   1. `recenterRow`    — only when Drive Mode's follow camera is paused (S4).
    ///   2. `driveActionRow` — Report / Park Here, only during Drive Mode.
    ///   3. `ParkUntilPill`  — only when the filter is active (carried over from browsing;
    ///                         it cannot be entered mid-drive, see `recenterButtonStack`).
    ///   4. `DriveModeBottomCard` — the "ground truth" slab; always the bottom-most element
    ///                         when Drive Mode is active, edge-to-edge (unchanged), the one
    ///                         row NOT given 16pt horizontal margins.
    /// `ParkingGuidePromptBanner` (browse-mode only) stays mutually exclusive with all four,
    /// as before.
    ///
    /// Because every row is now structural (laid out in-flow by the VStack) rather than an
    /// independently `Spacer()`-positioned float, adding/removing a row simply pushes the
    /// rows below it — this is what makes S6 (destination + approaching + paused + Park
    /// Until, the worst-case stack) self-resolving instead of requiring the old hand-computed
    /// `recenterPillBottomPadding` function.
    ///
    /// Extracted into its own @ViewBuilder property to reduce type-checker complexity
    /// in ContentView.body (W8.5c-polish PR-1 fix for "unable to type-check" error).
    @ViewBuilder
    private var bottomSafeAreaContent: some View {
        VStack(spacing: 8) {
            // FT-18 row 1: Recenter — only when the custom Drive Mode follow camera is
            // paused by a user gesture (FT-17: pan OR pinch).
            if driveModeActive && followPaused {
                recenterRow
            }
            // FT-18 row 2: Report / Park Here action row.
            if driveModeActive {
                driveActionRow
            }
            // FT-15/TF2-15 Stream B2: block-select floating bar (§4.2 step 5). Never
            // coexists with any of the driveModeActive-gated rows above — enforced from
            // both directions, see `blockSelectModeActive`'s doc comment (QA pass-1 fix:
            // this used to be a one-directional guard).
            if blockSelectModeActive {
                blockSelectBar
            }
            // W7.5 row 3: Park Until pill — carried over from browsing if already active;
            // cannot be entered mid-drive (recenterButtonStack, its only entry point, is
            // hidden while driveModeActive == true).
            if parkUntilMode, let target = parkUntilTarget {
                ParkUntilPill(targetDate: target) {
                    clearParkUntilFilter()
                }
            }
            // W8.5c row 4: Drive Mode bottom card (AC-W85c.25) — the anchored "ground truth"
            // slab, always last/bottom-most when Drive Mode is active.
            // W8.5d: showApproachStrip wired — true when state is .approaching.
            // The strip lives INSIDE the card (OQ-1: option (b), no new .safeAreaInset layer).
            if driveModeActive {
                DriveModeBottomCard(
                    context: drivingContext,
                    voiceService: drivingVoice,
                    destinationDistance: driveModeDistanceMeters,
                    showApproachStrip: finalApproachState == .approaching
                )
            }
            // FT-12: Parking 101 first-launch prompt banner. Never shown alongside
            // the Drive Mode bottom card or the Park Until pill (AC-7) — both of the
            // guards above already make those branches mutually exclusive with this one.
            // FT-15/TF2-15: also excluded during block-select mode, a deliberate
            // focused task the user is mid-way through.
            if showParkingGuideBanner && !driveModeActive && !parkUntilMode && !blockSelectModeActive {
                ParkingGuidePromptBanner(
                    onOpenGuide: { dismissParkingGuideBanner(openGuide: true) },
                    onDismiss: { dismissParkingGuideBanner(openGuide: false) }
                )
            }
        }
    }

    /// Marks the FT-12 first-launch banner as shown (one-shot gate) and hides it.
    /// Optionally opens `ParkingGuideView` via `ActiveSheet.parkingGuide`.
    private func dismissParkingGuideBanner(openGuide: Bool) {
        guard showParkingGuideBanner else { return }
        ParkingGuidePromptGate().markShown()
        showParkingGuideBanner = false
        if openGuide {
            activeSheet = .parkingGuide
        }
    }

    // MARK: - W5.1 / Kevin 2026-06-04: Recenter + drive-entry button stack

    /// Four vertically-stacked toolbar buttons in the top-right, visible only outside Drive
    /// Mode (FT-18: gated `if !driveModeActive` at the call site in `mapZStack` — none of
    /// these actions are available mid-drive; `endDriveControl` owns this corner instead).
    ///
    /// Button order (top to bottom):
    ///   1. "Find me"        — location.fill, always shown
    ///   2. "Find my car"    — car.fill, only when a pin exists
    ///   3. Park Until       — clock.fill, always shown
    ///   4. Combined Drive   — arrow.triangle.turn.up.right.diamond.fill, replaces the former
    ///                         separate Drive + "Find Parking" buttons (Kevin design decision
    ///                         2026-06-04: one combined entry scales to patrol-mode addition).
    ///
    /// The combined Drive button expands IN PLACE (no full-screen cover) into a compact
    /// two-option picker ("Drive to…" / "Find Parking"). Tapping an option collapses the
    /// picker and activates the selected mode. Tapping elsewhere collapses with no action.
    ///
    /// Invariant compliance: the drive entry uses a native SwiftUI Menu; no camera
    /// mutation happens here. Both entry paths continue to activate via their existing mechanisms:
    ///   - "Drive to a destination" → showDriveModeDestination = true → DriveModeDestinationView.onRouteReady
    ///   - "Find Parking nearby"    → enterCruiseMode() → driveModeActive = true → handleDriveModeAndCamera
    @ViewBuilder
    private var recenterButtonStack: some View {
        VStack(spacing: 8) {
            // Button 1: "Find me" — recenter on user's current GPS location.
            Button {
                recenterOnUser()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Recenter on my location")
            .accessibilityHint("Moves the map to show your current GPS position.")

            // Button 2: "Find my car" — shown only when a parked-car pin exists.
            if parkPinService.parkedCar != nil {
                Button {
                    recenterOnCar()
                } label: {
                    Image(systemName: "car.fill")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Recenter on my parked car")
                .accessibilityHint("Moves the map to show where you parked.")
            }

            // Button 3: Park Until filter — standalone trigger (filter-first UX).
            // Always visible. Tapping while filter is active re-opens the sheet to change the time.
            Button {
                activeSheet = .parkUntil
            } label: {
                Image(systemName: "clock.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(parkUntilMode ? Color.green : Color.accentColor)
            }
            .accessibilityLabel(parkUntilMode ? "Park Until filter active — tap to change time" : "Park Until — filter blocks by departure time")
            .accessibilityHint("Shows only blocks where you can park until a chosen time.")

            // Button 4: Combined Drive/Cruise entry — native SwiftUI Menu.
            //
            // Menu label: single icon button (arrow.triangle.turn.up.right.diamond.fill).
            // Menu items:
            //   - "Drive to a destination" → opens DriveModeDestinationView
            //   - "Find Parking nearby"    → enters Cruise Mode via enterCruiseMode()
            // The system dropdown dismisses on outside tap automatically.
            //
            // FT-18: `recenterButtonStack` itself is now only rendered when Drive Mode is
            // inactive (gated at the call site in `mapZStack`), so this button can no
            // longer render while driving — the former "resting icon, no action on tap"
            // fallback branch (F4: a full 44×44 button that looked tappable and wasn't)
            // is dead code under the new gating and has been removed.
            driveEntryButton
        }
    }

    // MARK: - Combined drive-entry button (native Menu)

    /// The combined Drive/Cruise entry button as a native SwiftUI Menu.
    ///
    /// Extracted into its own @ViewBuilder property to avoid hitting the Swift compiler's
    /// type-check complexity limit for large SwiftUI view bodies.
    ///
    /// The Menu label matches the resting toolbar button style (regularMaterial pill,
    /// accentColor icon). The system presents a native dropdown on tap — labels never
    /// truncate, dismiss on outside tap is automatic, and accessibility is free.
    @ViewBuilder
    private var driveEntryButton: some View {
        Menu {
            Button {
                guard activeSheet == nil else { return }
                showDriveModeDestination = true
            } label: {
                Label("Drive to a destination", systemImage: "arrow.triangle.turn.up.right.diamond")
            }

            Button {
                enterCruiseMode()
            } label: {
                Label("Find Parking nearby", systemImage: "car.front.waves.right.fill")
            }
        } label: {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityLabel("Start Drive Mode")
        .accessibilityHint("Double-tap to choose destination navigation or find parking nearby.")
    }

    // MARK: - FT-18: Isolated "End Drive" control (top-trailing)

    /// Isolated top-trailing "End" control — the sole exception to Proposal 1's "everything
    /// on the bottom" framing (Kevin's ruling #1, `docs/design/ft18-drive-mode-layout.md`).
    ///
    /// Ending Drive Mode is a one-tap, no-confirmation, session-terminating action
    /// (`endDriveMode()` fires immediately, no dialog) — it deliberately does NOT sit in the
    /// bottom action cluster next to Report/Park Here, matching Apple Maps' own turn-by-turn
    /// view, which isolates its End control away from the buttons tapped routinely. Placing a
    /// destructive, unconfirmed action next to frequently-tapped ones on a phone mounted for
    /// one-handed use in a moving car is the layout most likely to produce an accidental tap.
    ///
    /// Visible label is the short "End" (not "End Drive Mode" / "End Cruise Mode") — the full
    /// descriptive string lives only in `accessibilityLabel` for VoiceOver, matching the
    /// spacing/sizing spec's "shorter chrome" instruction. `.frame(minHeight: 44)` stays at
    /// the HIG floor deliberately (not enlarged) — this is a de-emphasized control, not a
    /// primary action.
    @ViewBuilder
    private var endDriveControl: some View {
        Button {
            endDriveMode()
        } label: {
            Label("End", systemImage: "xmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(.red)
        }
        .accessibilityLabel(driveModeStyle == .cruise ? "End Cruise Mode" : "End Drive Mode")
        .padding(.top, endDrivePillTopPadding)
        .padding(.trailing, 12)
    }

    // MARK: - FT-18: Bottom dock — Recenter row

    /// Structural Recenter row — a sibling of `driveActionRow` / `ParkUntilPill` /
    /// `DriveModeBottomCard` inside `bottomSafeAreaContent`'s `VStack(spacing: 8)`, replacing
    /// the pre-FT-18 independently-`Spacer()`-positioned floating pill. Because it's laid out
    /// in-flow, it pushes whatever's below it (the action row / pill / card) down the same way
    /// adding a row to any `VStack` does — no hand-maintained clearance function needed
    /// (`recenterPillBottomPadding` is no longer called here; kept defined + tested as a pure
    /// function, since deleting it would mean touching its test file for a non-required
    /// cleanup — see the spec's "code cleanup that falls out of this, not extra scope" note).
    ///
    /// Visible only when Drive Mode's custom follow camera is paused by a user gesture
    /// (`followPaused == true`; FT-17: pan OR pinch). Compact circular affordance — matches
    /// Apple Maps' own recenter control — rather than a third labeled capsule crammed into
    /// the action row (spec's "explicitly flagged as bad ideas" section).
    @ViewBuilder
    private var recenterRow: some View {
        HStack {
            Spacer()
            Button {
                recenterDriveMode()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Recenter map on my location")
        }
        .padding(.horizontal, 16)
    }

    // MARK: - FT-18: Bottom dock — Report / Park Here action row

    /// Structural action row — Report (secondary) leading, Park Here (primary "I'm done"
    /// action, Kevin's ruling #4) trailing. Visible whenever `driveModeActive == true`
    /// (both `.destination` and `.cruise` styles) as a sibling row inside
    /// `bottomSafeAreaContent`'s `VStack(spacing: 8)`, directly above `DriveModeBottomCard`.
    ///
    /// Button anatomy carried over unchanged from the pre-FT-18 TF2-18 P2-1 pass (capsule +
    /// `Label(icon, text)`); only position and the spacing/sizing spec's generous-padding
    /// bump changed (18pt horizontal / 12pt vertical / 48pt min height / 16pt inter-button
    /// gap, up from 14pt / 10pt / 44pt / 10pt — Kevin's core complaint was spacing, so this
    /// pass errs generous). Park Here also gains the filled `Color.accentColor` "primary CTA"
    /// treatment (matching existing primary-action styling elsewhere in the app) since it's
    /// the session's actual goal action; Report keeps its existing `.regularMaterial` +
    /// `Color.orange` treatment unchanged besides the padding bump.
    @ViewBuilder
    private var driveActionRow: some View {
        HStack(spacing: 16) {
            // Tier 3 sub-PR #2: In-drive Report button. Visible whenever driveModeActive ==
            // true. Tapping drops a pin at the user's CURRENT GPS — no map-picking while
            // driving. If GPS is unavailable, the button silently no-ops (guard let loc).
            //
            // Bug #4 (pre-FT-18): Pass drivingContext?.street so ReportSheet can show
            // "Reporting on <street>" — reuses the name already resolved by
            // DrivingContextService for the DriveModeBottomCard (no new search).
            Button {
                guard let loc = locationService.userLocation else { return }
                // FT-11: Resolve the nearest segment so ReportSheet shows the direction
                // picker. Use the same haversine candidate search as the resting path
                // (pinDropRadiusMeters = 35m). In-drive GPS is live so this is accurate.
                let driveSegment = findCandidateSegments(
                    lat: loc.latitude,
                    lng: loc.longitude,
                    radius: pinDropRadiusMeters,
                    max: 1
                ).first?.segment
                activeSheet = .reportPin(
                    coord: loc,
                    streetName: drivingContext?.street,
                    segment: driveSegment
                )
            } label: {
                Label("Report", systemImage: "flag.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(Color.orange)
            }
            .accessibilityLabel("Report enforcement or sweeper")
            .accessibilityHint("Drops a pin at your current location.")

            // TF2-7: "Park here" button — visible whenever Drive Mode is active.
            // Tapping opens SignCheckConfirmView (pre-step before ParkConfirmView).
            // If GPS is unavailable, the tap is a no-op (same guard as Report button).
            // No speed gate — consistent with the Report button and arrival prompt (OQ-2).
            //
            // Note on activeSheet interaction: if activeSheet is already set (e.g., arrival
            // prompt is showing), this button tap produces a no-op because SwiftUI's single
            // .sheet(item:) host only presents one sheet at a time; the guard below prevents
            // an activeSheet overwrite while another sheet is already open.
            Button {
                guard activeSheet == nil else { return }
                guard let loc = locationService.userLocation else { return }
                let candidates = findCandidateSegments(
                    lat: loc.latitude,
                    lng: loc.longitude,
                    radius: pinDropRadiusMeters,
                    max: 4
                )
                let detected = candidates.first?.segment
                let detectedDistance = candidates.first?.distanceMeters
                let alternatives = Array(candidates.dropFirst())
                let intent = PinDropIntent(
                    pinLat: loc.latitude,
                    pinLng: loc.longitude,
                    detectedSegment: detected,
                    detectedSegmentDistance: detectedDistance,
                    alternativeCandidates: alternatives
                )
                activeSheet = .signCheckConfirm(intent: intent)
            } label: {
                Label("Park here", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Park here")
            .accessibilityHint("Opens a safety checklist before dropping your parked car pin.")
        }
        .padding(.horizontal, 16)
    }

    // MARK: - FT-15 / TF2-15 Stream B2: Block-select floating bar

    /// Floating bottom bar shown during block-select mode (§4.2 step 5): a summary label
    /// ("N blocks selected (M blockfaces)"), the "Both curbs" toggle, and Cancel/Continue
    /// actions. Structural row in `bottomSafeAreaContent`'s VStack, same "Bottom Dock"
    /// pattern FT-18 established for `recenterRow`/`driveActionRow` — this file follows
    /// that structure per the task's explicit instruction to fit into it rather than
    /// re-introduce an independently `Spacer()`-positioned float.
    ///
    /// AC-R3: Continue is disabled with zero blocks selected.
    @ViewBuilder
    private var blockSelectBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(blockSelectSummaryLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("Both curbs", isOn: $bothCurbsOn)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .fixedSize()
            }

            HStack(spacing: 12) {
                Button {
                    cancelBlockSelectMode()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel selecting blocks")

                Button {
                    continueToBlockRestrictionReport()
                } label: {
                    Text("Continue")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBlockKeys.isEmpty)
                .accessibilityLabel("Continue to report form")
                .accessibilityHint(selectedBlockKeys.isEmpty
                    ? "Select at least one block first"
                    : "Opens the closure report form for the selected blocks")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    /// "Tap blocks on the map to select" (empty) or "N blocks selected (M blockfaces)"
    /// (spec §4.2 step 5's own example format, generalized to N/M).
    private var blockSelectSummaryLabel: String {
        guard !selectedBlockKeys.isEmpty else {
            return "Tap blocks on the map to select"
        }
        let blockCount = selectedBlockCount
        let faceCount = selectedBlockKeys.count
        let blockWord = blockCount == 1 ? "block" : "blocks"
        let faceWord = faceCount == 1 ? "blockface" : "blockfaces"
        return "\(blockCount) \(blockWord) selected (\(faceCount) \(faceWord))"
    }

    // MARK: - CM-3: Cruise Mode entry

    /// Enters Cruise Mode ("Find Parking") directly — no destination input, no route fetch.
    ///
    /// Entry sequence (spec §5.1):
    ///   1. Set `driveModeStyle = .cruise`.
    ///   2. `activeRoute` and `driveDestinationCoordinate` remain nil (never set).
    ///   3. `driveModeActive = true` → triggers `handleDriveModeAndCamera(true)` via `.onChange`.
    ///      The existing W8.5c–d path fires unchanged: `locationService.startDriveMode()`,
    ///      heading-up, auto-zoom, `.mutedStandard`, directional puck, wake lock, background note.
    ///   4. `DrivingContextService.setCruiseMode(true)` is called from `handleDriveModeChange`
    ///      (see the `isCruiseMode` guard there).
    ///
    /// Guard: only enters when no sheet is active (same guard as destination mode entry).
    /// Applied inside the function so it holds regardless of call site.
    private func enterCruiseMode() {
        guard activeSheet == nil else { return }
        driveModeStyle = .cruise
        // activeRoute stays nil — no route polyline in Cruise Mode (AC-CM.14).
        // driveDestinationCoordinate stays nil — no destination pin (AC-CM.14).
        driveModeDistanceMeters = nil  // clear any stale value from a prior destination session.
        driveModeActive = true
        // setCruiseMode(true) is called inside handleDriveModeChange(true) below,
        // triggered by the .onChange(of: driveModeActive) observer.
    }

    // MARK: - W8.5b/c: End Drive Mode

    /// Clears all Drive Mode state (route polyline, destination pin, driveModeActive).
    /// MapViewRepresentable reacts to activeRoute=nil and destinationCoordinate=nil by
    /// removing the corresponding overlays and annotations automatically.
    /// W8.5c: Also stops continuous location + voice (via onChange(of: driveModeActive)).
    /// CM-3: Also resets driveModeStyle to .inactive.
    private func endDriveMode() {
        driveModeActive = false
        driveModeStyle = .inactive
        activeRoute = nil
        driveDestinationCoordinate = nil
        driveModeDistanceMeters = nil  // W8.5c-polish PR-1: clear distance indicator.
        // W8.5c context state cleared via onChange(of: driveModeActive).
        // setCruiseMode(false) is called inside handleDriveModeChange(false) below,
        // triggered by the .onChange(of: driveModeActive) observer.
    }

    // MARK: - W8.5c-polish PR-1: Distance-to-destination computation

    /// Recomputes `driveModeDistanceMeters` from the user's current location to the active
    /// destination. Uses `CLLocation.distance(from:)` — NOT a manual haversine approximation
    /// (per spec Feature A requirement). Called on every location fix while Drive Mode is active.
    ///
    /// Extracted from the `.onChange(of: locationService.locationUpdateCount)` closure to
    /// reduce the type-checker complexity budget in ContentView.body.
    private func updateDriveModeDistance(from userLocation: CLLocation) {
        guard let dest = driveDestinationCoordinate else {
            driveModeDistanceMeters = nil
            return
        }
        let destLocation = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        driveModeDistanceMeters = userLocation.distance(from: destLocation)
    }

    // MARK: - W8.5d: Final approach update handler

    /// Handles `driveModeDistanceMeters` changes to drive approach-state transitions.
    ///
    /// Called from `.onChange(of: driveModeDistanceMeters)` — fires on the main thread,
    /// after SwiftUI's view-update cycle, consistent with the PR-3/PR-2 architectural pattern.
    ///
    /// Responsibilities:
    ///   1. Guard: if Drive Mode inactive or no destination, reset state and return.
    ///   2. Compute new `FinalApproachState` from distance.
    ///   3. On state change: update `finalApproachState` + update `DrivingContextService` voice gap.
    ///   4. On `.arrived` transition (first time): fire arrival prompt (one-shot, R-3 hysteresis gate).
    ///
    /// Per R-4 (§6): if GPS fix is nil at moment of `.arrived`, `arrivalPromptFired` stays
    /// false so a subsequent `.onChange` can retry when GPS recovers.
    ///
    /// - Parameter distanceOrNil: The updated distance, or nil when Drive Mode is inactive.
    private func handleFinalApproachUpdate(_ distanceOrNil: Double?) {
        // CM-3 Guard: FinalApproachService only runs in Destination Mode (AC-CM.12, AC-CM.13).
        // In Cruise Mode, `driveModeStyle == .cruise`, so this guard returns early.
        // `finalApproachState` stays `.outside` for the duration of any Cruise Mode session.
        // Belt-and-suspenders: also guards on `driveDestinationCoordinate != nil` below,
        // which is always nil in Cruise Mode. The explicit mode check is the primary gate.
        guard driveModeStyle == .destination else {
            if finalApproachState != .outside {
                finalApproachState = .outside
            }
            return
        }

        // Guard 1: must be in active Drive Mode with a destination set.
        guard driveModeActive, driveDestinationCoordinate != nil else {
            if finalApproachState != .outside {
                finalApproachState = .outside
            }
            return
        }

        // Guard 2: distance must be available.
        guard let distance = distanceOrNil else {
            if finalApproachState != .outside {
                finalApproachState = .outside
            }
            return
        }

        // Step 1: Compute new state.
        let newState = FinalApproachService.finalApproachState(forDistanceMeters: distance)

        // Step 2: On state change, update state + voice gap.
        if newState != finalApproachState {
            finalApproachState = newState
            // Update DrivingContextService voice gap immediately on transition.
            // Service is nil when Drive Mode is inactive (guard above ensures active state).
            drivingContextService?.setVoiceGap(FinalApproachService.voiceGap(for: newState))
        }

        // Step 3: Arrival prompt — one-shot per Drive Mode session (OQ-6, R-3 hysteresis).
        if newState == .arrived && !arrivalPromptFired {
            guard let arrivalCoord = locationService.userLocation else {
                // R-4: GPS loss at arrival — don't fire prompt, don't mark fired.
                // Next .onChange will retry if GPS recovers and distance is still <= 50m.
                return
            }
            // Mark fired before presenting sheet (prevents race if .onChange fires again).
            arrivalPromptFired = true
            activeSheet = .arrivalPrompt(coord: arrivalCoord)
        }
    }

    // MARK: - Option A: Recenter in Drive Mode (A-AC-9)

    /// Resumes the custom follow camera and restores the Drive Mode camera defaults.
    ///
    /// Option A design — no `userTrackingMode = .follow`. The recenter action:
    ///   1. Resets `currentDriveAltitude` to the FT-8 default — so the camera (both the
    ///      immediate application below and any subsequent per-tick `setDriveCamera`) follows
    ///      at the canonical tight zoom, not the user's panned view.
    ///   2. Sets `followPaused = false` — resumes the per-tick `setDriveCamera` in
    ///      `handleLocationUpdate()` for all FUTURE GPS ticks.
    ///   3. Applies the camera change IMMEDIATELY, not waiting for the next GPS tick — see
    ///      FT-17a Defect 1 below.
    ///
    /// Architecture: no `region` write, no `userTrackingMode =`, no `updateUIView` call.
    /// All closures fire outside SwiftUI's view-update cycle — #31 invariant maintained.
    ///
    /// FT-17 (2026-08-12) deliberately did NOT change step 1 (the altitude reset), even
    /// though FT-17 made pinch-to-zoom pause follow the same way pan already did. Kevin's
    /// ask was scoped to "any gesture pauses follow, resumed only by Recenter" — whether
    /// Recenter should also preserve the user's last zoom instead of resetting it is a
    /// separate, deliberately deferred question (see FT-17 PR body).
    ///
    /// FT-17a Defect 1 (2026-08-13): previously step 3 only fired
    /// `coordinatorActions.applyDrivePitch?(true, preDrivePitch)`, which restores pitch and
    /// altitude immediately but does NOT move the camera's center coordinate — centering was
    /// left entirely to the next per-tick `setDriveCamera` call in `handleLocationUpdate()`,
    /// which fires on the next GPS tick (up to ~1s away while actually driving; NEVER on a
    /// static/simulated location with no further ticks). Kevin, testing on a static
    /// simulator location: "the recenter button appears but doesn't work, map stays where it
    /// is." Fix: when a last-known location is available, call `coordinatorActions
    /// .setDriveCamera?(coord, nil, currentDriveAltitude)` immediately instead — the exact
    /// same closure `handleLocationUpdate()` calls per-tick, so there is no new
    /// camera-application code path; it sets center, pitch, AND altitude in one `setCamera`
    /// call, superseding the narrower `applyDrivePitch` call for this purpose. This extends
    /// the existing "apply immediately, don't wait for a fix" precedent (previously only
    /// pitch/altitude) to also cover centering. If no location fix exists yet at all (e.g.
    /// Drive Mode was entered before the first GPS fix arrived), there is nothing to center
    /// on — fall back to the pitch/altitude-only `applyDrivePitch` call (unchanged prior
    /// behavior) so the camera at least un-zooms/un-tilts immediately; centering then
    /// catches up on the first GPS tick via the identical guarded call already in
    /// `handleLocationUpdate()`. This never jumps the camera to (0,0) or crashes.
    private func recenterDriveMode() {
        // Reset altitude to FT-8 default — used by both the immediate application below and
        // any subsequent per-tick follow.
        currentDriveAltitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        // Resume custom follow — future GPS ticks re-center via setDriveCamera.
        followPaused = false

        if let coord = locationService.userLocation {
            // Immediately center + apply pitch/altitude in a single setCamera call — the
            // same closure handleLocationUpdate() calls per-tick (FT-17a Defect 1).
            coordinatorActions.setDriveCamera?(coord, nil, currentDriveAltitude)
        } else {
            // No location fix yet — nothing to center on. Apply pitch/altitude immediately
            // (prior behavior); the first GPS tick will center once a fix arrives.
            coordinatorActions.applyDrivePitch?(true, preDrivePitch)
        }
    }

    // MARK: - W5.1: Recenter actions

    /// Requests user location and recenters when the fix arrives.
    /// If a cached location is available, recenters immediately and also refreshes
    /// the fix so the next tap will have an up-to-date position.
    private func recenterOnUser() {
        if let loc = locationService.userLocation {
            // We have a cached fix — recenter immediately.
            recenterMap(on: loc)
            // Also request a fresh fix in the background for next use.
            locationService.requestAndFetchLocation()
        } else {
            // No fix yet — request one; .onChange(of: locationService.userLocation)
            // will fire when the fix arrives and complete the recenter.
            recenterOnUserRequested = true
            locationService.requestAndFetchLocation()
        }
    }

    /// Recenters the map on the parked car pin.
    private func recenterOnCar() {
        guard let car = parkPinService.parkedCar else { return }
        let coord = CLLocationCoordinate2D(latitude: car.latitude, longitude: car.longitude)
        recenterMap(on: coord)
    }

    /// Animates the map region to center on the given coordinate at street-level zoom.
    /// ~400m span shows the target block plus a few surrounding blocks.
    ///
    /// Phase 1 (map-phase1-browse): `updateUIView` no longer pushes `region` to the map in
    /// browse mode (MapKit owns the camera). Programmatic centering is preserved by calling
    /// `coordinatorActions.setRegion?` directly — this fires `mapView.setRegion(_:animated:true)`
    /// outside `updateUIView`, satisfying the #31 architectural invariant.
    ///
    /// Writing `region` is still required for tile loading (`rebuildOverlays` span gating,
    /// `DriveModeDestinationView.currentRegion`, and the initial `tileLoader.loadTiles` call).
    private func recenterMap(on coordinate: CLLocationCoordinate2D) {
        let newRegion = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
        region = newRegion
        coordinatorActions.setRegion?(newRegion)
    }

    // MARK: - Community 1.0 / Tier 1: visible pins change handler

    /// Handles updates to `pinService.visiblePins`.
    ///
    /// Called from `.onChange(of: pinService.visiblePins)` — fires on the main thread,
    /// after SwiftUI's view-update cycle (invariant I-1 compliance).
    ///
    /// Responsibilities:
    ///   1. Filter to map-marker types (filming + special_event; NOT asp_suspended_today — AC-D8).
    ///      asp_suspended_today is handled via the ASP banner, not a map marker (spec §3 + §4.3).
    ///   2. Update `communityPins` @State → triggers MapViewRepresentable.updateUIView →
    ///      syncCommunityPinAnnotations, which diffs add/remove against the current MKMapView state.
    ///   3. Re-evaluate `bannerState` with the ASP supplement helper (spec §4.2 / AC-D9a–D9d).
    ///
    /// Extracted from `.onChange` closure to reduce type-checker expression complexity in
    /// `ContentView.body` — same pattern as the other `handle*` methods (PR-1 lesson).
    private func handleVisiblePinsChange(_ newPins: [CommunityPin]) {
        // Map markers: Tier 1 display types + Tier 3 ephemeral crowd pins (sub-PR #2).
        // filming + special_event: Tier 1 open-data markers (AC-D8).
        // enforcement_active + sweeper_passed: Tier 3 crowd ephemeral markers (spec §2.1).
        // asp_suspended_today drives the banner supplement below, not a map marker.
        let mapMarkerTypes: Set<PinType> = [.filming, .specialEvent, .enforcementActive, .sweeperPassed]
        communityPins = newPins.filter { mapMarkerTypes.contains($0.pinType) }

        // ASP banner supplement (spec §4.2 / AC-D9a through AC-D9d).
        // resolvedBannerState() returns .todaySuspended if a live Supabase pin
        // overrides the bundle state, otherwise returns bundle state unchanged.
        let bundleState = aspService.suspensionState(at: .nowET)
        bannerState = resolvedBannerState(bundleState: bundleState, aspPins: newPins)
    }

    // MARK: - Drive Mode lifecycle handler

    /// Handles Drive Mode entry and exit lifecycle.
    ///
    /// Extracted from `.onChange(of: driveModeActive)` to reduce type-checker complexity
    /// in ContentView.body (W8.5c-polish PR-1 fix).
    ///
    /// CM-3: On entry, calls `drivingContextService?.setCruiseMode(driveModeStyle == .cruise)`
    /// so the voice policy switches to `CruiseVoicePolicy` when in Cruise Mode.
    /// On exit, calls `setCruiseMode(false)` to reset for the next session.
    private func handleDriveModeChange(_ active: Bool) {
        // Community 1.0 / Tier 1: inform pinService of Drive Mode state change.
        // The service applies the re-fetch guard (spec §6.3): skip if center moved < 200m.
        pinService.setDriveModeActive(active)

        if active {
            // Entering Drive Mode.
            locationService.startDriveMode()
            // Option A: followPaused starts false — follow is active from the first GPS tick.
            followPaused = false
            // TF2-16: reset heading-snap state for the new session.
            driveHeadingSource = .course
            effectiveDriveHeading = nil
            // currentDriveAltitude initialized in handleDriveModeAndCamera (after the entry
            // setCamera has applied so we don't capture the pre-transition altitude here).
            // Create DrivingContextService and wire the voice service.
            let service = DrivingContextService(voice: drivingVoice)
            drivingContextService = service
            drivingContext = nil
            // CM-3: Enable Cruise Mode voice policy when entering in Cruise Mode.
            // setCruiseMode is a no-op when isCruise == false (destination mode default).
            service.setCruiseMode(driveModeStyle == .cruise)
            // Show muted toast if voice is muted from a previous session (OQ-3).
            if drivingVoice.isMuted {
                ToastService.shared.show(message: "Voice muted \u{2014} tap to unmute")
            }
            // S-1 fix (spec §7 R-3, AC-DM.23): on the very first Drive Mode start,
            // show a one-time alert explaining that parking commentary pauses when the
            // app is backgrounded. Alert wins over the muted toast — they cannot both
            // fire at the same time without confusion, and the background note is the
            // more important first-time disclosure.
            let gate = BackgroundNoteGate()
            if gate.shouldShow() {
                gate.markShown()
                showDriveModeBackgroundNote = true
            }
            // Activate audio session for the drive session.
            AudioSessionManager.shared.activateDriveSession()
        } else {
            // Exiting Drive Mode.
            locationService.endDriveMode()
            // CM-3: Reset cruise mode flag for the next session.
            drivingContextService?.setCruiseMode(false)
            drivingContextService = nil
            drivingContext = nil
            // Option A: clear follow state on Drive Mode exit.
            followPaused = false
            currentDriveAltitude = 0
            // TF2-16: reset heading-snap state on exit.
            driveHeadingSource = .course
            effectiveDriveHeading = nil
            // Deactivate audio session.
            AudioSessionManager.shared.deactivateDriveSession()
            // W8.5d: Reset final-approach state for the next session.
            finalApproachState = .outside
            arrivalPromptFired = false
        }
    }

    // MARK: - W8.5c-polish PR-3 / PR-2: Drive Mode camera + style handler

    /// Applies or restores the Drive Mode camera pitch + zoom + map style via the coordinator
    /// action box. All four features (pitch, zoom, style, puck) fire from this single function,
    /// which is called from the SINGLE `.onChange(of: driveModeActive)` handler — NOT from
    /// updateUIView. See §3.1 of the PR-2 spec.
    ///
    /// Called from `.onChange(of: driveModeActive)` in ContentView.body — NOT from updateUIView.
    /// The `.onChange` fires after SwiftUI's current view-update cycle completes, so `setCamera`
    /// inside the coordinator runs with a fully-mounted view hierarchy. This avoids the #31
    /// regression where setCamera inside updateUIView raced SwiftUI's in-progress mount.
    ///
    /// On entry (`active` = true):
    ///   - Captures `preDrivePitch`, `preDriveDistance`, `preDriveMapConfiguration`.
    ///   - Calls `applyDrivePitch(true, preDrivePitch)` → combined pitch+zoom animated setCamera.
    ///   - Calls `applyDriveMapStyle(true, nil)` → `.muted` map configuration.
    ///   - Calls `refreshUserLocationPuck(true)` → directional puck rendered.
    ///
    /// On exit (`active` = false):
    ///   - Calls `applyDrivePitch(false, preDrivePitch)` → restores prior pitch + distance.
    ///   - Calls `applyDriveMapStyle(false, preDriveMapConfiguration)` → restores prior config.
    ///   - Calls `refreshUserLocationPuck(false)` → default blue dot restored.
    private func handleDriveCameraChange(_ active: Bool) {
        if active {
            // Capture current camera state and map style before Drive Mode overwrites them.
            // These values are restored on exit.
            preDrivePitch = coordinatorActions.captureCurrentPitch?() ?? 0
            preDriveDistance = coordinatorActions.captureCurrentDistance?() ?? 0
            preDriveMapConfiguration = coordinatorActions.captureCurrentMapConfiguration?()
        }

        // Apply or restore camera pitch + zoom in a SINGLE setCamera call (spec §3.4).
        //
        // The coordinator's `applyDriveCameraState` method handles both pitch and
        // centerCoordinateDistance in one call. On entry, it also stashes the prior distance
        // in `lastCapturedPriorDistance` for use during the exit path.
        //
        // `preDriveDistance` is stored in ContentView for observability (debugging, future
        // W8.5d use), but the coordinator owns the authoritative restore value.
        coordinatorActions.applyDrivePitch?(active, preDrivePitch)

        // Apply or restore map style (`.muted` on entry, prior config on exit).
        // `preferredConfiguration` does NOT fire `regionDidChangeAnimated` — no feedback risk.
        // (spec §3.6 R-3: preferredConfiguration is a separate MapKit path from setCamera.)
        coordinatorActions.applyDriveMapStyle?(active, preDriveMapConfiguration)

        // TF2-6 (Issue 2a): Toggle 3D building extrusions.
        // `mapView.showsBuildings` is on MKMapView, not MKStandardMapConfiguration — so it
        // cannot be embedded in `targetMapConfiguration`. Toggling it here via CoordinatorActions
        // keeps the mutation outside `updateUIView` (satisfying the #31 architectural invariant).
        //
        // On entry: hide buildings (flat nav map, matching Apple/Waze behaviour). 3D buildings
        //   occlude parking lines and lane markings at the 30° drive pitch, especially in dense
        //   Manhattan blocks. Hiding them gives a clearer view of the road ahead.
        // On exit: restore buildings (browsing the map post-drive, buildings are useful).
        //
        // Kevin: change `false` to `true` below if you prefer buildings visible in Drive Mode.
        coordinatorActions.setShowsBuildings?(!active)

        // Refresh the user-location annotation view so MapKit re-queries `mapView(_:viewFor:)`,
        // which returns the directional puck when `driveModeActive` is true, or nil (restoring
        // the default blue dot) when false. Implemented by briefly toggling `showsUserLocation`.
        coordinatorActions.refreshUserLocationPuck?(active)
    }

    // MARK: - Location update handler

    /// Handles a new location fix: recenter (if requested), Drive Mode follow, context update,
    /// and distance-to-destination update.
    ///
    /// Extracted from `.onChange(of: locationService.locationUpdateCount)` to reduce
    /// type-checker complexity in ContentView.body (W8.5c-polish PR-1 fix).
    private func handleLocationUpdate() {
        guard let coord = locationService.userLocation else { return }
        // W5.1: Recenter on user location if requested.
        if recenterOnUserRequested {
            recenterOnUserRequested = false
            recenterMap(on: coord)
        }
        // Viewport-polish Priority 2b: auto-center at launch if in coverage.
        if recenterOnUserAtLaunch {
            recenterOnUserAtLaunch = false
            if AppConstants.isInManhattanCoverage(coord) {
                recenterMap(on: coord)
            }
        }
        // W8.5c: Drive Mode context update + Option A custom follow.
        if driveModeActive {
            // Option A: Custom follow camera — per-tick setCamera (A-AC-2, A-AC-3).
            // Fires on every GPS update when driveModeActive && !followPaused.
            // Camera composition: center = GPS coord, heading = current camera heading
            // (syncDriveHeading owns heading via course EMA — no double-set here),
            // pitch = driveModePitch (30°), altitude = currentDriveAltitude (user-adjustable).
            // Animation: driveAnimationDuration (0.3s) — MKMapView retargets in-flight animations
            // smoothly; completes with 0.7s spare at 1 Hz GPS.
            // Guard: followPaused == true when user panned — skip centering until Recenter tap.
            if !followPaused, currentDriveAltitude > 0 {
                coordinatorActions.setDriveCamera?(coord, nil, currentDriveAltitude)
            }
            // Context update: compute parking commentary for new position.
            if let service = drivingContextService {
                service.update(
                    coordinate: coord,
                    heading: locationService.driveHeading,
                    segments: tileLoader.segments,
                    engine: engine
                )
                drivingContext = service.currentContext

                // TF2-16: heading-source selection (hysteresis) + street-snap bearing.
                // Runs here — inside the existing .onChange(of: locationUpdateCount)-driven,
                // outside-updateUIView location Option A already uses for setDriveCamera —
                // NOT inside MapViewRepresentable.updateUIView (spec §6.2 / #31 discipline).
                let nextSource = DriveHeadingSnap.nextHeadingSource(
                    current: driveHeadingSource,
                    hasBlockMatch: service.matchedSegment != nil,
                    speed: max(0, locationService.driveSpeed ?? 0),
                    courseAccuracy: locationService.driveCourseAccuracy
                )
                driveHeadingSource = nextSource
                switch nextSource {
                case .course:
                    effectiveDriveHeading = locationService.driveHeading
                case .streetSnap:
                    if let segment = service.matchedSegment {
                        effectiveDriveHeading = DriveHeadingSnap.snappedHeading(
                            segment: segment,
                            lastGoodHeading: locationService.driveHeading
                        )
                    } else {
                        // Defensive fallback — nextHeadingSource only returns .streetSnap
                        // when hasBlockMatch was true, so this branch is unreachable in
                        // practice; kept to avoid a force-unwrap.
                        effectiveDriveHeading = locationService.driveHeading
                    }
                }
            }
            // W8.5c-polish PR-1 (Feature A): update distance to destination.
            let clLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            updateDriveModeDistance(from: clLocation)
        }
    }

    // MARK: - Launch setup

    /// Performs one-time initialization when ContentView appears.
    ///
    /// Called from the `.task {}` modifier in `body`. Extracted into its own method to
    /// reduce the expression complexity of ContentView.body (W8.5c-polish PR-1 fix).
    @MainActor
    private func performLaunchSetup() async {
        // W5: Load persisted car pin on app launch.
        parkPinService.load()

        // W6: Initialize previousCarID from the persisted car so that the first
        // pin replace correctly cancels the pre-existing pin's notifications.
        previousCarID = parkPinService.parkedCar?.id

        // W7: Initialize mute state from UserDefaults.
        notificationsMuted = UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey)

        // FT-6: Initialize reminder offsets from UserDefaults.
        reminderOffsets = ReminderOffsets.load(from: .standard)

        // W7: Initialize banner state.
        bannerState = aspService.suspensionState(at: .nowET)

        // FT-12: Show the Parking 101 first-launch prompt banner at most once per install.
        showParkingGuideBanner = ParkingGuidePromptGate().shouldShow()

        // Community 1.0 / Tier 1: wire Realtime subscription stub (no-op until prod schema live).
        pinService.startRealtime()

        tileLoader.loadTiles(forRegion: region)
        lastEvaluatedAt = .now
        rebuildOverlays(at: lastEvaluatedAt)

        // Viewport-polish: Auto-center camera at launch.
        // Three-priority decision (see viewport-polish-spec.md §5):
        //
        // Priority 1 — deep-link: notification tap has a resolved parked car.
        //   Coverage check does NOT apply — user explicitly parked at that coordinate.
        // Priority 2a — authorized + cached fix in coverage: snap immediately.
        //   Set recenterOnUserAtLaunch = true so a fresher fix re-snaps via .onChange.
        // Priority 2b — authorized + no cached fix: defer via flag + requestLocation().
        //   .onChange fires when the fix arrives; recenters only if in coverage.
        // Priority 3 — fallback: stay on manhattanCenter. No-op.
        //
        // This block does NOT call requestWhenInUseAuthorization() — that is gated behind
        // the "Find me" button tap (W5.1 design). If isAuthorized == false, we skip entirely.
        let pendingID = appDelegate.pendingDeepLinkCarID
        if let carID = pendingID,
           let car = parkPinService.parkedCar,
           car.id == carID {
            // Priority 1: deep-link — center on parked car, no coverage check.
            let coord = CLLocationCoordinate2D(latitude: car.latitude, longitude: car.longitude)
            recenterMap(on: coord)
        } else if locationService.isAuthorized {
            if let cachedLoc = locationService.userLocation {
                if AppConstants.isInManhattanCoverage(cachedLoc) {
                    // Priority 2a: cached fix in coverage — snap immediately.
                    recenterMap(on: cachedLoc)
                    // Allow re-snap if a fresher fix arrives within ~3s.
                    recenterOnUserAtLaunch = true
                }
                // else: cached fix outside coverage → Priority 3 (manhattanCenter stays).
            } else if pendingID == nil {
                // Priority 2b: authorized, no cached fix, no pending deep-link.
                // Defer until fix arrives. requestLocation() has a built-in timeout (~10-15s).
                recenterOnUserAtLaunch = true
                locationService.requestAndFetchLocation()
            }
            // else: pendingID != nil but parkedCar didn't resolve → fall through to Priority 3.
        }
        // Priority 3: permission denied / not determined, or unresolvable deep-link.
        // Camera stays on the manhattanCenter default. No action.
    }

    // MARK: - Scene phase handler

    /// Handles app foreground transitions for banner refresh, mute re-sync, stale-target guard,
    /// and deep-link replay.
    ///
    /// Extracted from the `.onChange(of: scenePhase)` closure to reduce type-checker
    /// expression complexity in ContentView.body (W8.5c-polish PR-1 fix).
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        guard newPhase == .active else { return }
        bannerState = aspService.suspensionState(at: .nowET)
        // Re-sync mute state in case it changed while backgrounded (edge case).
        notificationsMuted = UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey)
        // FT-6: Re-sync reminder offsets on foreground (mirrors mute sync pattern).
        reminderOffsets = ReminderOffsets.load(from: .standard)
        // W7.5: Stale-target guard — clear the Park Until filter if the target has passed.
        // This covers the case where the user backgrounded the app past their departure time.
        if let target = parkUntilTarget, target < .nowET {
            parkUntilMode = false
            parkUntilTarget = nil
            // Rebuild overlays to restore normal 5-state coloring.
            rebuildOverlays(at: .nowET)
        }
        // W6.1: Replay any buffered deep-link that arrived during the foreground transition.
        routePendingDeepLink(appDelegate.pendingDeepLinkCarID)
    }

    // MARK: - Dismiss helpers

    /// Dismisses the BlockDetailView sheet and clears the selection highlight.
    private func dismissBlockDetail() {
        activeSheet = nil
        selectedSegmentID = nil
    }

    // MARK: - Tap handling (unchanged from W4 — only gesture source changed)

    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        // FT-15/TF2-15 §4.2 step 3: in block-select mode, a tap toggles the closest
        // segment's blockfaceKey in/out of the selection instead of opening
        // BlockDetailView. Checked FIRST so none of the normal-mode tap behavior below
        // (banner dismiss, block-detail sheet) fires while selecting.
        if blockSelectModeActive {
            handleBlockSelectTap(at: coordinate)
            return
        }

        // FT-12: a tap anywhere on the map counts as "first interaction" — auto-hide
        // the Parking 101 banner (spec §7 OQ-2) without opening the guide.
        if showParkingGuideBanner {
            dismissParkingGuideBanner(openGuide: false)
        }

        guard !tileLoader.segments.isEmpty else {
            dismissBlockDetail()
            return
        }

        var closestID: String? = nil
        var closestDistance: Double = .infinity

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: coordinate, polyline: coords)
            if dist < closestDistance {
                closestDistance = dist
                closestID = segment.id
            }
        }

        if closestDistance <= tapHitThresholdMeters, let id = closestID,
           let segment = tileLoader.segments.first(where: { $0.id == id }) {
            selectedSegmentID = id
            activeSheet = .blockDetail(segment)
        } else {
            dismissBlockDetail()
        }
    }

    // MARK: - FT-15 / TF2-15 Stream B2: Block-scoped report tap-select mode

    /// Entered via the resting long-press dialog's third action (§4.2 step 1–2).
    /// Clears any current selection/sheet state and resets "Both curbs" to its default.
    private func enterBlockSelectMode() {
        selectedSegmentID = nil
        activeSheet = nil
        selectedBlockKeys = []
        bothCurbsOn = true
        blockSelectModeActive = true
    }

    /// Exits block-select mode without submitting anything (floating bar's Cancel button).
    private func cancelBlockSelectMode() {
        blockSelectModeActive = false
        selectedBlockKeys = []
    }

    /// Floating bar's Continue action (§4.2 step 5). Snapshots the currently-selected
    /// `Segment`s (reading `blockfaceKey` verbatim, per §4.1/§4.3 — no re-derivation from
    /// text) and presents `BlockRestrictionReportSheet`. Exits tap-select interaction
    /// (`blockSelectModeActive = false`) but deliberately leaves `selectedBlockKeys`
    /// populated so the map highlight stays visible while the report sheet is open —
    /// cleared when that sheet dismisses (see the `.sheet(item:)` `onDismiss` closure).
    private func continueToBlockRestrictionReport() {
        guard !selectedBlockKeys.isEmpty else { return }
        let segments = selectedSegmentsForBlockSelect
        blockSelectModeActive = false
        activeSheet = .blockRestrictionReport(segments: segments)
    }

    /// FT-15/TF2-15 §4.2 step 3: finds the closest loaded segment to `coordinate` (same
    /// haversine-distance search + `tapHitThresholdMeters` gate as `handleMapTap`'s
    /// normal-mode block-detail lookup) and toggles its blockface into/out of the
    /// selection. A tap that misses every segment (beyond the hit threshold) is a no-op —
    /// no accidental selection from an imprecise tap.
    private func handleBlockSelectTap(at coordinate: CLLocationCoordinate2D) {
        guard !tileLoader.segments.isEmpty else { return }

        var closestSegment: Segment? = nil
        var closestDistance: Double = .infinity

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: coordinate, polyline: coords)
            if dist < closestDistance {
                closestDistance = dist
                closestSegment = segment
            }
        }

        guard closestDistance <= tapHitThresholdMeters, let segment = closestSegment else { return }
        toggleBlockSelection(segment)
    }

    /// AC-R1/AC-R2: toggles `segment`'s blockfaceKey in/out of `selectedBlockKeys`. When
    /// newly adding a block with "Both curbs" on, also adds the matching opposite-side
    /// segment if one is currently loaded (AC-R2: if none is found, only the tapped side
    /// is added — no crash, no silent no-op, surfaces as a 1-block selection).
    private func toggleBlockSelection(_ segment: Segment) {
        let oppositeKey = bothCurbsOn
            ? ContentView.oppositeSideSegment(of: segment, in: tileLoader.segments)?.blockfaceKey
            : nil
        selectedBlockKeys = ContentView.toggledBlockSelection(
            current: selectedBlockKeys,
            tappedKey: segment.blockfaceKey,
            bothCurbsOn: bothCurbsOn,
            oppositeKey: oppositeKey
        )
    }

    /// Pure toggle-decision function: no SwiftUI/MapViewRepresentable dependency,
    /// directly unit-testable (AC-R1, AC-R2).
    ///
    /// - If `tappedKey` is already selected, it is removed (deselect — the opposite-curb
    ///   segment, if any, is left untouched; "Both curbs" only auto-ADDS on select, per
    ///   spec §4.2 step 4, it does not auto-remove on deselect).
    /// - Otherwise `tappedKey` is added, and `oppositeKey` (if non-nil) is added alongside
    ///   it — `oppositeKey` is expected to already be `nil` when `bothCurbsOn` is `false`
    ///   or when no opposite-side segment is currently loaded (AC-R2), so this function
    ///   doesn't need to re-check `bothCurbsOn` itself.
    static func toggledBlockSelection(
        current: Set<String>,
        tappedKey: String,
        bothCurbsOn: Bool,
        oppositeKey: String?
    ) -> Set<String> {
        var result = current
        if result.contains(tappedKey) {
            result.remove(tappedKey)
        } else {
            result.insert(tappedKey)
            if bothCurbsOn, let oppositeKey {
                result.insert(oppositeKey)
            }
        }
        return result
    }

    /// AC-R2: finds the loaded segment describing the opposite curb of the same physical
    /// block — same street, same UNORDERED from/to pair, a DIFFERENT side. Returns nil if
    /// no such segment is currently loaded (e.g. only one side has tiles loaded at this
    /// zoom/viewport, or the street genuinely has only one curb in the data).
    ///
    /// Pure (no SwiftUI/instance dependency), directly unit-testable.
    static func oppositeSideSegment(of segment: Segment, in segments: [Segment]) -> Segment? {
        let pair: Set<String> = [segment.fromStreet, segment.to]
        return segments.first { candidate in
            candidate.side != segment.side &&
            candidate.street == segment.street &&
            Set([candidate.fromStreet, candidate.to]) == pair
        }
    }

    /// The `Segment`s in `tileLoader.segments` matching `selectedBlockKeys`, in no
    /// particular order. Used both for the floating bar's summary label and as the
    /// Continue-time snapshot passed into `BlockRestrictionReportSheet`.
    private var selectedSegmentsForBlockSelect: [Segment] {
        tileLoader.segments.filter { selectedBlockKeys.contains($0.blockfaceKey) }
    }

    /// Distinct BLOCK count (street + unordered cross-street pair, ignoring side) among
    /// the current selection — distinct from `selectedBlockKeys.count`, which counts
    /// BLOCKFACES (one per curb). Kevin's canonical case is 2 blocks × 2 curbs = 4
    /// blockfaces; the floating bar's summary shows both numbers (spec §4.2 step 5's
    /// own "2 blocks selected" / "(4 blockfaces)" example distinguishes them explicitly).
    private var selectedBlockCount: Int {
        Set(selectedSegmentsForBlockSelect.map { seg -> String in
            let (lo, hi) = seg.fromStreet <= seg.to ? (seg.fromStreet, seg.to) : (seg.to, seg.fromStreet)
            return "\(seg.street)|\(lo)|\(hi)"
        }).count
    }

    // MARK: - W5 / Tier 3 sub-PR #2: Long-press handling

    /// Handles a long-press gesture on the map.
    ///
    /// Behavior is context-dependent:
    ///   - `driveModeActive == true`: long-press is suppressed (no-op). The in-drive
    ///     Report button is the driving-safe entry path. Suppressing the gesture avoids
    ///     accidental park-pin drops while maneuvering (spec §4.1).
    ///   - `driveModeActive == false`: captures the coordinate and shows the
    ///     resting action menu (confirmationDialog). The menu offers two actions:
    ///     "Park my car here" (W5 flow) or "Report enforcement or sweeper" (Tier 3).
    ///     Candidate-segment detection is deferred until the user picks an action —
    ///     no wasted work if they pick "Report" (spec §4.1 note).
    private func handleLongPress(at coordinate: CLLocationCoordinate2D) {
        // While driving, long-press is intentionally a no-op (spec §4.1).
        // FT-15/TF2-15: also a no-op while block-select mode is active — a long-press
        // mid-selection (e.g. "Park my car here") would be a confusing second exclusive
        // interaction mode layered on top of the first. The user exits block-select via
        // the floating bar's Cancel/Continue before any other long-press action is available.
        guard !driveModeActive, !blockSelectModeActive else { return }

        // Clear any current selection and dismiss any open sheet before showing the menu.
        selectedSegmentID = nil
        activeSheet = nil

        // Capture coordinate and show the confirmationDialog.
        // The dialog's action handlers (in body) build the PinDropIntent or reportPin sheet.
        pendingLongPressCoord = coordinate
        showRestingActionMenu = true
    }

    // MARK: - W5: "Park here →" Path B (from BlockDetailView)

    private func initiatePathBPinDrop(from segment: Segment) {
        // Clear selection and dismiss BlockDetailView before presenting ParkConfirmView.
        selectedSegmentID = nil
        activeSheet = nil

        // Path B: segment already known; coordinate is midpoint (spec §3.2).
        // If midpoint is nil (malformed segment), fall back to first coordinate.
        let midpoint = segment.midpoint ?? segment.coordinates.first
        guard let coord = midpoint else { return }

        // No alternative candidates for Path B (user already picked this block).
        // detectedSegmentDistance is nil for Path B — no "Wrong street?" alternatives.
        let intent = PinDropIntent(
            pinLat: coord.latitude,
            pinLng: coord.longitude,
            detectedSegment: segment,
            detectedSegmentDistance: nil,
            alternativeCandidates: []
        )
        activeSheet = .parkConfirm(intent)
    }

    // MARK: - Drive Mode combined handler (extracted for type-checker budget)

    /// Handles Drive Mode entry/exit: lifecycle + camera/style in one call.
    ///
    /// Option A design: no `userTrackingMode = .follow` at any point. Drive Mode position
    /// centering is owned entirely by the per-tick `setDriveCamera` called from
    /// `handleLocationUpdate()` via `.onChange(of: locationService.locationUpdateCount)` —
    /// OUTSIDE `updateUIView`. Nothing fights our camera.
    ///
    /// ENTRY order:
    ///   1. handleDriveModeChange(true) — start location services, create context service.
    ///   2. handleDriveCameraChange(true) — capture pre-drive pitch/zoom/style, apply pitch+zoom.
    ///   3. Initialize currentDriveAltitude — must come AFTER handleDriveCameraChange captures
    ///      the current distance (not needed for the camera call but for the follow default).
    ///
    /// EXIT order:
    ///   1. handleDriveCameraChange(false) — restore pre-drive pitch + zoom + style.
    ///   2. handleDriveModeChange(false) — stop location services, clear context, clear followPaused.
    ///
    /// Architecture: all calls fire from `.onChange(of: driveModeActive)` — OUTSIDE `updateUIView`.
    /// No camera mutation or `userTrackingMode =` assignment inside `updateUIView`. #31 invariant maintained.
    ///
    /// Architecture invariant: no camera mutation (setCamera, setRegion, userTrackingMode =)
    /// happens inside updateUIView. All camera mutations are driven from .onChange handlers
    /// in ContentView or from MapKit delegate callbacks.
    private func handleDriveModeAndCamera(_ active: Bool) {
        if active {
            // FT-15/TF2-15 QA fix: this `.onChange(of: driveModeActive)` handler is the
            // SINGLE funnel every Drive Mode entry path runs through (destination-mode's
            // `onRouteReady` and `enterCruiseMode()` both just set `driveModeActive = true`
            // and let this fire) — so it's the structural place to guarantee
            // `blockSelectModeActive`/`selectedBlockKeys` can never coexist with an active
            // Drive Mode session, rather than re-asserting the guard at each entry site
            // individually (that per-site pattern is exactly what QA's pass-1 finding
            // caught: `recenterButtonStack`'s Drive-entry affordance was the only thing
            // gating entry, and it wasn't gated against block-select mode). The
            // `recenterButtonStack` gate below (`mapZStack`) additionally hides the
            // Drive-entry UI entirely while block-select is active, so in practice this
            // branch is a self-healing safety net, not the only line of defense.
            if shouldClearBlockSelectOnDriveModeEntry(
                active: active,
                blockSelectModeActive: blockSelectModeActive,
                hasSelection: !selectedBlockKeys.isEmpty
            ) {
                cancelBlockSelectMode()
            }
            handleDriveModeChange(true)
            handleDriveCameraChange(true)
            // Initialize currentDriveAltitude to the FT-8 default.
            // This is the altitude the per-tick setDriveCamera will use until the user
            // pinch-zooms (which updates it via onDrivePinchZoomed → handleDrivePinchZoomed).
            currentDriveAltitude = MapViewRepresentable.altitudeForSpan(
                MapViewRepresentable.driveModeCameraSpan
            )
        } else {
            handleDriveCameraChange(false)
            handleDriveModeChange(false)
        }
    }

    // MARK: - Option A: Drive pan / pinch handlers

    /// Called by MapViewRepresentable's `onDrivePanDetected` when the user makes ANY map
    /// gesture — pan OR pinch, per FT-17 — during Drive Mode. Pauses the custom follow so
    /// the per-tick `setDriveCamera` stops fighting the user's view, and shows the Recenter
    /// button.
    ///
    /// FT-17 (2026-08-12): broadened from pan-only to any gesture. See the `followPaused`
    /// property doc comment and `docs/field-testing-log.md` FT-17 for the root-cause trace.
    ///
    /// `followPaused` stays `true` until the user taps Recenter — matching Waze/Apple Maps
    /// behavior where a gesture locks the view until explicitly recentered.
    private func handleDrivePanDetected() {
        guard driveModeActive else { return }
        followPaused = true
    }

    /// Called by MapViewRepresentable's `onDrivePinchZoomed` when a pure pinch (no pan
    /// recognizer concurrently active) settles during Drive Mode.
    ///
    /// Updates `currentDriveAltitude` so a subsequent per-tick `setDriveCamera` would honour
    /// the user's chosen zoom instead of the FT-8 default (OQ-3: Waze model).
    ///
    /// FT-17 note: `onDrivePanDetected` now ALSO fires for this same pinch gesture (see
    /// above), setting `followPaused = true` — so per-tick `setDriveCamera` is already
    /// skipped by the time this altitude lands, and the value gets overwritten the moment
    /// the user taps Recenter (`recenterDriveMode()` resets to the FT-8 default, deliberately
    /// left unchanged — see PR body). This handler is effectively inert today; kept as the
    /// seam a future "Recenter preserves the user's zoom" change would reuse rather than
    /// re-derive from scratch.
    private func handleDrivePinchZoomed(_ newAltitude: CLLocationDistance) {
        guard driveModeActive, newAltitude > 0 else { return }
        currentDriveAltitude = newAltitude
    }

    // MARK: - onAppear handler (extracted for type-checker budget)

    private func handleOnAppear() {
        lastEvaluatedAt = .now
        bannerState = aspService.suspensionState(at: .nowET)
    }

    // MARK: - Timer / overlay rebuild handlers (extracted for type-checker budget)

    private func handleTimerTick() {
        lastEvaluatedAt = .now
        rebuildOverlays(at: lastEvaluatedAt)
    }

    private func handleSegmentsChanged() {
        rebuildOverlays(at: lastEvaluatedAt)
    }

    private func handleSelectionChanged() {
        rebuildOverlays(at: lastEvaluatedAt)
    }

    // MARK: - W7: Notifications muted change handler

    /// Handles changes to the global notifications mute toggle.
    /// Extracted from `.onChange(of: notificationsMuted)` to reduce type-checker complexity.
    private func handleNotificationsMutedChange(_ muted: Bool) {
        UserDefaults.standard.set(muted, forKey: AppConstants.notificationsMutedKey)
        if muted {
            // Muted: cancel any pending notification for the current pin.
            if let car = parkPinService.parkedCar {
                NotificationScheduler.shared.cancelAll(for: car)
            }
        }
    }

    // MARK: - FT-6: Reminder offsets change handler

    /// Called from SettingsView's onOffsetsChange closure when any reminder preset toggle changes.
    ///
    /// Cancels and re-schedules notifications for the current pin so the new preset set takes
    /// effect immediately. Mirrors the existing unmute reschedule path (handleNotificationsMutedChange).
    private func handleReminderOffsetsChange() {
        guard let car = parkPinService.parkedCar,
              car.notifyOnRestriction,
              !notificationsMuted else { return }

        NotificationScheduler.shared.cancelAllThenSchedule(
            for: car,
            oldCarID: car.id,
            loadedSegments: tileLoader.segments,
            engine: engine
        )
    }

    // MARK: - W6: First pin dropped handler

    /// Handles the `parkPinService.firstPinDropped` Combine event.
    /// Shows the notification rationale sheet on the first-ever pin drop.
    /// Extracted from `.onReceive(firstPinDropped)` to reduce type-checker complexity.
    private func handleFirstPinDropped() {
        if !UserDefaults.standard.bool(forKey: AppConstants.notificationRationaleShownKey) {
            activeSheet = .notificationRationale
        }
    }

    // MARK: - W6: Pin-dropped event handler

    /// Handles the `parkPinService.pinDropped` Combine event.
    ///
    /// Cancels old notifications and schedules new ones for the dropped car.
    /// Extracted from `.onReceive(parkPinService.pinDropped)` to reduce type-checker
    /// expression complexity in `ContentView.body` (same PR-1 extraction pattern).
    private func handlePinDropped(_ newCar: ParkedCar) {
        let oldID = previousCarID
        Task { @MainActor in
            // W6: Cancel old + schedule new notifications.
            NotificationScheduler.shared.cancelAllThenSchedule(
                for: newCar,
                oldCarID: oldID,
                loadedSegments: tileLoader.segments,
                engine: engine
            )
        }
    }

    // MARK: - W5: Confirm pin drop (from ParkConfirmView)

    /// W7: Updated to accept PinConfirmResult (wraps intent + notifyOnRestriction).
    private func confirmPinDrop(result: PinConfirmResult) {
        let intent = result.intent

        // W6: Capture the current car ID BEFORE save() overwrites parkedCar.
        // onReceive(pinDropped) will read `previousCarID` and cancel the old notifications.
        // This must happen before save() is called — save() fires pinDropped synchronously
        // from the main thread, which triggers onReceive before this function returns.
        previousCarID = parkPinService.parkedCar?.id

        let car = ParkedCar(
            id: UUID(),
            latitude: intent.pinLat,
            longitude: intent.pinLng,
            detectedSegmentID: intent.detectedSegment?.id,
            detectedSide: intent.detectedSegment?.side,
            street: intent.detectedSegment?.street,
            fromStreet: intent.detectedSegment?.fromStreet,
            toStreet: intent.detectedSegment?.to,
            parkedAt: .nowET,
            notifyOnRestriction: result.notifyOnRestriction
        )
        parkPinService.save(car)
    }

    // MARK: - W5: Open ParkedCarDetailView

    private func openParkedCarDetail() {
        guard let car = parkPinService.parkedCar else { return }
        activeSheet = .parkedCarDetail(car)
    }

    // MARK: - W7.5: Park Until filter helpers

    /// Clears the Park Until filter, rebuilds overlays in normal 5-state mode, and shows a toast.
    /// Called from the filter-active pill's "x" button and from the skip handler.
    private func clearParkUntilFilter() {
        parkUntilMode = false
        parkUntilTarget = nil
        rebuildOverlays(at: .nowET)
        ToastService.shared.show(message: "Park Until filter cleared")
    }

    // MARK: - W6.1: Route buffered notification deep-link

    /// Routes a buffered notification deep-link car ID to ParkedCarDetailView, then clears
    /// the buffer so subsequent foreground transitions do not re-present the sheet.
    ///
    /// Called from:
    ///   - .onChange(of: appDelegate.pendingDeepLinkCarID) — fires when the value changes,
    ///     covering the foreground case (app already running) and the background-wake case
    ///     (value set before or just after the modifier attaches).
    ///   - .onChange(of: scenePhase) when newPhase == .active — belt-and-suspenders guard
    ///     for the cold-kill case where pendingDeepLinkCarID was set before .onChange(of:)
    ///     registered (value did not "change" from the modifier's perspective). By the time
    ///     .active fires, the view is mounted and reading the buffered value is safe.
    ///
    /// Preserves the AC-W6.11 mismatched-carID guard: if the tapped notification's car is no
    /// longer the currently parked car (user cleared or replaced the pin), no sheet presents.
    ///
    /// - Parameter carID: The car ID from `appDelegate.pendingDeepLinkCarID`, or nil to no-op.
    private func routePendingDeepLink(_ carID: UUID?) {
        guard let carID else { return }
        // Always clear the buffer first — prevents idempotency issues even if the guard fails.
        appDelegate.pendingDeepLinkCarID = nil
        // AC-W6.11 / criterion 5: only present if the notification matches the current pin.
        guard let car = parkPinService.parkedCar, car.id == carID else { return }
        // viewport-polish pass-3 fix: also recenter the camera on the parked car. The Priority 1
        // branch in `.task` may not fire on cold-kill because `pendingDeepLinkCarID` is set by
        // the delegate AFTER `.task` evaluates — so the auto-center is missed and the user sees
        // the sheet over a wide-Manhattan default map. This call ensures the camera always
        // follows the deep-link route, whether triggered by `.task` Priority 1 (foreground-wake)
        // or by this helper from `.onChange(of: pendingDeepLinkCarID)` (cold-kill race).
        // Idempotent: if Priority 1 already fired, this recenter targets the same coordinate.
        let coord = CLLocationCoordinate2D(latitude: car.latitude, longitude: car.longitude)
        recenterMap(on: coord)
        activeSheet = .parkedCarDetail(car)
    }

    // MARK: - W5: findCandidateSegments

    /// Finds segments within `radius` meters of the given coordinate, sorted by distance.
    /// Port of findCandidateSegments() at index.html:5096-5111.
    ///
    /// Deduplication: groups by block key (street|from|to) — the same block face may
    /// span multiple segments. Returns the closest segment per unique block key.
    /// Returns up to `max` results.
    ///
    /// This is the multi-candidate version of the haversine point-to-segment search
    /// already used in handleMapTap. W5 spec §4.2 path A.
    private func findCandidateSegments(
        lat: Double,
        lng: Double,
        radius: Double,
        max maxResults: Int
    ) -> [CandidateSegment] {

        let tapCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        // Track closest segment per block key (street|from|to) to deduplicate.
        var bestByBlockKey: [String: (segment: Segment, distance: Double)] = [:]

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: tapCoord, polyline: coords)
            guard dist <= radius else { continue }

            // Block key: same as the PWA's dedup key — street|from|to (case-insensitive).
            // We keep all-caps (as stored in tile data) for consistency.
            let key = "\(segment.street)|\(segment.fromStreet)|\(segment.to)"
            if let existing = bestByBlockKey[key] {
                if dist < existing.distance {
                    bestByBlockKey[key] = (segment, dist)
                }
            } else {
                bestByBlockKey[key] = (segment, dist)
            }
        }

        // Sort by distance, take top `maxResults`.
        return bestByBlockKey.values
            .sorted { $0.distance < $1.distance }
            .prefix(maxResults)
            .map { CandidateSegment(segment: $0.segment, distanceMeters: $0.distance) }
    }

    // MARK: - Geometry helpers (unchanged from W4)

    private func pointToPolylineDistance(from point: CLLocationCoordinate2D,
                                          polyline: [CLLocationCoordinate2D]) -> Double {
        var minDist = Double.infinity
        for i in 0..<(polyline.count - 1) {
            let d = pointToSegmentDistance(point: point, a: polyline[i], b: polyline[i + 1])
            if d < minDist { minDist = d }
        }
        return minDist
    }

    private func pointToSegmentDistance(point: CLLocationCoordinate2D,
                                        a: CLLocationCoordinate2D,
                                        b: CLLocationCoordinate2D) -> Double {
        let metersPerDegLat = 111_320.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let metersPerDegLng = metersPerDegLat * cosLat

        let px = (point.longitude - a.longitude) * metersPerDegLng
        let py = (point.latitude  - a.latitude)  * metersPerDegLat
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude  - a.latitude)  * metersPerDegLat

        let abLenSq = bx * bx + by * by
        if abLenSq == 0 {
            return haversine(from: point, to: a)
        }

        let t = max(0, min(1, (px * bx + py * by) / abLenSq))
        let closestX = t * bx
        let closestY = t * by
        let closestLat = a.latitude  + closestY / metersPerDegLat
        let closestLng = a.longitude + closestX / metersPerDegLng
        let closest = CLLocationCoordinate2D(latitude: closestLat, longitude: closestLng)
        return haversine(from: point, to: closest)
    }

    private func haversine(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

}

// MARK: - Community 1.0 / Tier 1: ASP banner supplement (spec §4.2)

/// Merges the live Supabase `asp_suspended_today` pin signal with the bundle-backed
/// `SuspensionBannerState` from `ASPSuspensionService`.
///
/// Priority rules (spec §4.2, OQ-1 option b):
///   - Bundle state is primary (offline-capable, already QA'd through W7).
///   - A live Supabase pin overrides ONLY in the "suspended" direction:
///       - Pin says suspended + bundle says NOT suspended → trust the pin.
///       - Pin says suspended + bundle says suspended → bundle wins (same info).
///       - Pin absent → bundle state unchanged (W7 behavior preserved, AC-D9c).
///       - Expired pin → does NOT override bundle (AC-D9d).
///
/// - Parameter bundleState: The state from `ASPSuspensionService.suspensionState(at:)`.
/// - Parameter aspPins: All visible community pins (the function filters to aspSuspendedToday type).
/// - Returns: The resolved banner state for display.
///
/// This function does NOT modify `ASPSuspensionService`'s public API (spec §4.3).
///
/// Extracted as `internal` so `CommunityPinServiceTests` can unit-test it directly (AC-D9a–D9d).
func resolvedBannerState(
    bundleState: SuspensionBannerState,
    aspPins: [CommunityPin]
) -> SuspensionBannerState {
    // Already suspended per bundle — bundle wins (no regression from W7 behavior).
    if case .todaySuspended = bundleState {
        return bundleState
    }

    // Look for a live, non-expired asp_suspended_today pin for today (ET).
    let todayStr = Date.nowET.toETDateString()
    let now = Date()
    let liveSuspension = aspPins.first { pin in
        guard pin.pinType == .aspSuspendedToday else { return false }
        // Must not be resolved.
        guard pin.resolvedAt == nil else { return false }
        // Must not be expired.
        if let expiresAt = pin.expiresAt, expiresAt <= now { return false }
        // Must be for today (ET).
        if let meta = pin.meta, case .aspSuspendedToday(let m) = meta {
            return m.suspensionDate == todayStr
        }
        // Pin has no meta (unusual) — still treat as a suspension signal.
        return false
    }

    // If a live pin exists AND bundle says ASP is in effect → pin overrides to suspended.
    if let pin = liveSuspension, case .aspInEffect = bundleState {
        let reason: String
        if let meta = pin.meta, case .aspSuspendedToday(let m) = meta {
            reason = m.reason ?? "NYC Emergency Suspension"
        } else {
            reason = "NYC Emergency Suspension"
        }
        return .todaySuspended(reason: reason)
    }

    // No live pin or bundle handles it → return bundle state unchanged.
    return bundleState
}

// MARK: - Banner Padding

/// Returns the top padding (in points) that the End Drive pill needs to clear the ASP banner.
///
/// All three `SuspensionBannerState` cases render a visible banner (~44pt tall), so this
/// function always returns a non-zero value. The invariant: **if a banner is visible, the
/// pill must clear it.**
///
/// TF2-18 P2-2: raised from `44` to `100` to match `recenterButtonStack`'s existing hardcoded
/// `.padding(.top, 100)` — the two floating toolbar clusters (End Drive/Report/Park Here on
/// the left, Find me/Find car/Park Until/Drive on the right) previously sat at different
/// vertical offsets (44pt vs 100pt), reading as two unrelated toolbars instead of one row of
/// peer controls (review finding P2-2). `100` already accounts for status bar + banner
/// clearance in practice — it's been live and correct for `recenterButtonStack` since W5.1.
/// The `44 > 0` clearance invariant this function exists to guarantee is unaffected by the
/// literal value change; `100 > 44 > 0` still clears the banner with more margin than before.
///
/// Extracted as an `internal` pure function so tests can assert the invariant directly
/// without instantiating a full `ContentView`.
func paddingForBannerState(_ state: SuspensionBannerState) -> CGFloat {
    // All three states (.aspInEffect, .todaySuspended, .tomorrowSuspended) show a visible
    // banner (~44pt tall) — 100pt clears the status bar + banner with room to spare,
    // matching recenterButtonStack's existing offset (TF2-18 P2-2).
    switch state {
    case .aspInEffect, .todaySuspended, .tomorrowSuspended:
        return 100
    }
}

// MARK: - FT-13: Parking 101 guide toolbar button visibility

/// Returns whether the Parking 101 guide ("?") toolbar button should render.
///
/// Hidden while Drive Mode is active — it shares the top-leading corner with the gear
/// button (`gearButtonOverlay`), and FT-18 hides that whole corner during Drive Mode
/// (see `gearButtonVisible(driveModeActive:)`); not needed mid-drive.
///
/// Extracted as an `internal` pure function — same testability rationale as
/// `paddingForBannerState` / `recenterPillBottomPadding` — so the visibility rule is
/// covered without instantiating a full `ContentView`.
func parkingGuideButtonVisible(driveModeActive: Bool) -> Bool {
    !driveModeActive
}

// MARK: - FT-18: Gear (Settings) button toolbar visibility

/// Returns whether the gear (Settings) toolbar button should render.
///
/// Hidden while Drive Mode is active (Kevin's FT-18 ruling #3, fully hidden — not
/// dimmed-but-tappable): not needed mid-drive, and voice control stays reachable via the
/// always-visible mute button in `DriveModeBottomCard`. This also resolves the pre-FT-18 F2
/// bug (the gear button and the End Drive pill previously rendered at the identical
/// top-leading coordinate) — by removal rather than relocation, now that `endDriveControl`
/// lives in the opposite (top-trailing) corner.
///
/// Mirrors `parkingGuideButtonVisible`'s pattern (same gating rule) so the visibility rule
/// is unit-testable independent of view rendering.
func gearButtonVisible(driveModeActive: Bool) -> Bool {
    !driveModeActive
}

// MARK: - FT-15 / TF2-15 Stream B2 QA fix: block-select ↔ Drive Mode mutual exclusion

/// Returns whether `recenterButtonStack` (the sole UI path to both Drive Mode entry
/// points — `driveEntryButton`'s "Drive to a destination" / "Find Parking nearby" menu
/// items) should render.
///
/// QA pass-1 finding: an earlier revision gated this on `!driveModeActive` alone. That
/// correctly hid the stack once Drive Mode was already active, but did nothing to stop
/// the REVERSE transition — nothing prevented tapping the Drive-entry button while
/// block-select mode was active, producing a stacked/competing Bottom Dock and map taps
/// hijacked into block selection while "driving." Hiding the stack whenever EITHER flag
/// is true closes that gap structurally, at the one call site both entry points share,
/// rather than re-guarding each entry point (`enterCruiseMode()`, the destination-mode
/// `onRouteReady` closure) individually.
///
/// Extracted as an `internal` pure function — same testability rationale as
/// `gearButtonVisible` / `parkingGuideButtonVisible` — so this specific state-interaction
/// bug has a regression test that doesn't require instantiating a full `ContentView`.
func recenterButtonStackVisible(driveModeActive: Bool, blockSelectModeActive: Bool) -> Bool {
    !driveModeActive && !blockSelectModeActive
}

/// Returns whether entering Drive Mode (`active == true`) should force-clear block-select
/// state (`blockSelectModeActive` / `selectedBlockKeys`).
///
/// This is the self-healing backstop half of the QA pass-1 fix (paired with
/// `recenterButtonStackVisible` above, which prevents the transition at the UI level in
/// the first place): `handleDriveModeAndCamera` is the single funnel every Drive Mode
/// entry path runs through (`.onChange(of: driveModeActive)` fires identically regardless
/// of which entry point flipped the flag), so clearing block-select state there — guarded
/// by this predicate — guarantees the invariant holds even for a hypothetical future entry
/// path that doesn't route through `recenterButtonStack` at all.
///
/// `hasSelection` covers the case where `blockSelectModeActive` has already flipped back
/// to `false` (Continue was tapped) but `selectedBlockKeys` is still populated to keep the
/// map highlight visible while `BlockRestrictionReportSheet` is open — that highlight
/// should also be cleared if Drive Mode somehow starts during that window, not just the
/// mode flag.
///
/// Extracted as an `internal` pure function for the same reason as
/// `recenterButtonStackVisible`.
func shouldClearBlockSelectOnDriveModeEntry(
    active: Bool,
    blockSelectModeActive: Bool,
    hasSelection: Bool
) -> Bool {
    active && (blockSelectModeActive || hasSelection)
}

// MARK: - TF2-18 P1-3: Recenter pill bottom clearance

/// Returns the bottom padding (in points) the floating "Recenter" pill needs to clear the
/// Drive Mode bottom-card stack, instead of the pre-TF2-18 hardcoded `.padding(.bottom, 8)`
/// (which had zero awareness of the stack's actual height and could render the pill
/// overlapping the card — review finding P1-3).
///
/// Mirrors the `paddingForBannerState` pattern already validated for the top pill
/// (W8.5c-polish PR-1): hardcode the known component heights, verify the sum via live-UI
/// smoke across the real combinations, rather than measuring at runtime with
/// `GeometryReader` (which would risk the exact "mutate layout during the SwiftUI update
/// cycle" class of bug documented in `MapViewRepresentable`'s update-cycle invariant).
///
/// Component heights (approximate, system fonts — verified via smoke, TF2-18 PR):
///   - Base bottom card: ~140pt (TF2-18 P2-5 stacked the Left/Right chips into two full-width
///     rows instead of one side-by-side row, adding ~1 chip-row height vs. the pre-TF2-18 card).
///   - `+ 30pt` when the final-approach strip is showing (`DriveModeBottomCard`'s
///     `showApproachStrip` row).
///   - `+ 58pt` when the `ParkUntilPill` is also showing below the card.
///   - `+ 8pt` clearance gap above whichever element is topmost.
///
/// Extracted as an `internal` pure function so tests can assert all four combinations
/// directly without instantiating a full `ContentView`.
func recenterPillBottomPadding(showApproachStrip: Bool, parkUntilVisible: Bool) -> CGFloat {
    var height: CGFloat = 140
    if showApproachStrip { height += 30 }
    if parkUntilVisible { height += 58 }
    return height + 8
}

#Preview {
    ContentView(appDelegate: AppDelegate(), authService: SupabaseAuthService())
}
