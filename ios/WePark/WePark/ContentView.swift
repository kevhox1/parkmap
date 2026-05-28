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

    var id: String {
        switch self {
        case .blockDetail(let seg):       return "blockDetail-\(seg.id)"
        case .parkConfirm(let intent):    return "parkConfirm-\(intent.id)"
        case .parkedCarDetail(let car):   return "parkedCarDetail-\(car.id)"
        case .notificationRationale:      return "notificationRationale"
        case .settings:                   return "settings"
        case .parkUntil:                  return "parkUntil"
        }
    }
}

struct ContentView: View {

    // MARK: - W6: AppDelegate reference for notification deep-link routing

    /// Injected from WeParkApp. ContentView reads `appDelegate.pendingDeepLinkCarID`
    /// (W6.1 fix: @Published buffer, replaces the former PassthroughSubject) to open
    /// ParkedCarDetailView when the user taps a delivered notification.
    @ObservedObject var appDelegate: AppDelegate

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

    /// True when the user has manually panned the map away from their GPS position.
    /// Cleared when the Recenter button is tapped or on each follow-mode location update.
    @State private var driveFollowEnabled: Bool = true

    /// S-1 fix (spec §7 R-3, AC-DM.23): controls the one-time background-limitation alert.
    /// Set to true on the first-ever Drive Mode start if the gate key is not yet set.
    /// The gate itself is evaluated via BackgroundNoteGate; this bool drives the .alert.
    @State private var showDriveModeBackgroundNote: Bool = false

    // MARK: - Bundle version strings (passed into SettingsView)

    private let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private let buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

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

    /// W8.5c-polish PR-1 (Feature B): Extra top padding for the End Drive pill when the ASP
    /// banner is visible, so the pill clears the banner and doesn't obscure its text.
    /// The ASP banner is approximately 44pt tall (subheadline font + 12pt vertical padding × 2).
    /// Always non-zero: all three SuspensionBannerState cases render a visible banner.
    private var endDrivePillTopPadding: CGFloat {
        paddingForBannerState(bannerState)
    }

    private var selectedSegment: Segment? {
        guard let id = selectedSegmentID else { return nil }
        return tileLoader.segments.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Bottom layer: map + safe-area-inset banner.
            ZStack(alignment: .topTrailing) {
                MapViewRepresentable(
                    region: $region,
                    selectedSegmentID: $selectedSegmentID,
                    onTap: { coordinate in
                        handleMapTap(at: coordinate)
                    },
                    onLongPress: { coordinate in
                        handleLongPress(at: coordinate)
                    },
                    onRegionChanged: { newRegion in
                        region = newRegion
                        tileLoader.loadTiles(forRegion: newRegion)
                    },
                    onCarPinTapped: {
                        openParkedCarDetail()
                    },
                    carPin: parkPinService.parkedCar,
                    overlayPayload: overlayPayload,
                    activeRoute: activeRoute,
                    destinationCoordinate: driveDestinationCoordinate,
                    driveHeading: locationService.driveHeading,
                    onDrivePanDetected: {
                        // W8.5c: User panned map manually → disable follow mode.
                        if driveModeActive {
                            driveFollowEnabled = false
                        }
                    }
                )
                // Map fills the full screen including safe area.
                .ignoresSafeArea()
                // W7: ASP banner pushed above the map content, not overlapping it.
                .safeAreaInset(edge: .top) {
                    ASPBanner(state: bannerState)
                }
                // W7.5: Filter-active pill pushed below the map content when Park Until is active.
                // W8.5c: Drive Mode bottom card sits below the Park Until pill when both active.
                .safeAreaInset(edge: .bottom) {
                    bottomSafeAreaContent
                }

                // W5.1: Recenter buttons — top-right, below status bar and compass rose.
                // padding(.top, 100) gives clearance for both the ~44pt status bar and
                // the ~40pt ASP banner added in W7.
                recenterButtonStack
                    .padding(.top, 100)
                    .padding(.trailing, 12)
            }

            // W7: Gear button — top-left, at the same vertical offset as the recenter buttons.
            VStack {
                Button { activeSheet = .settings } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Open settings")
                Spacer()
            }
            .padding(.top, 100)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            // W8.5b/c: Drive Mode overlays — shown when Drive Mode is active.
            if driveModeActive {
                driveModeOverlayLayer
            }

            // W7: Toast host — highest z-order layer. Positioned at the very top via VStack + Spacer.
            // Renders above the ASP banner (spec §3.E: toast overlays banner briefly — acceptable
            // because toast is transient 3s, banner is persistent).
            // Top padding reads `proxy.safeAreaInsets.top` so the toast clears the status bar /
            // dynamic island on notched devices (QA pass-1 #2). GeometryReader is scoped to just
            // this slot so it does not affect any other layer.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ToastHostView()
                        .padding(.top, proxy.safeAreaInsets.top)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            await performLaunchSetup()
        }
        .onAppear {
            lastEvaluatedAt = .now
            bannerState = aspService.suspensionState(at: .nowET)
        }
        // W7: Refresh banner state when app returns to foreground (handles midnight rollover).
        // W6.1: Also replay any buffered notification deep-link on foreground transition.
        //       This covers the cold-kill scenario: the delegate may have fired and set
        //       pendingDeepLinkCarID while the view hierarchy was still settling. By the
        //       time scenePhase reaches .active, .onChange(of: pendingDeepLinkCarID) will
        //       have already fired if the value changed after the modifier was attached.
        //       The second call here is a belt-and-suspenders guard for the case where the
        //       value was already non-nil when the modifier first attached (value didn't
        //       "change" — it was set before onChange was registered). Clearing after routing
        //       ensures this path is idempotent across foreground cycles.
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        // W7: Keep UserDefaults in sync with @State notificationsMuted whenever it changes.
        .onChange(of: notificationsMuted) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: AppConstants.notificationsMutedKey)
            if newValue {
                // Muted: cancel any pending notification for the current pin.
                if let car = parkPinService.parkedCar {
                    NotificationScheduler.shared.cancelAll(for: car)
                }
            }
        }
        // W8.5c: Drive Mode active layer lifecycle — start/stop continuous location + voice.
        .onChange(of: driveModeActive) { _, active in
            handleDriveModeChange(active)
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { _ in
            lastEvaluatedAt = .now
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // Rebuild overlays when segments change (tile load completes).
        .onChange(of: tileLoader.segments.count) { _, _ in
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // Rebuild selected-block highlight when selection changes.
        .onChange(of: selectedSegmentID) { _, _ in
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // W5.1/W8.5c: Recenter + Drive Mode update on every location fix.
        .onChange(of: locationService.locationUpdateCount) { _, _ in
            handleLocationUpdate()
        }
        // W6: First pin ever → show rationale sheet (once per install).
        // Guard: belt-and-suspenders check on the UserDefaults flag in case
        // `firstPinDropped` semantics ever drift from `hasEverParkedKey`.
        .onReceive(parkPinService.firstPinDropped) {
            if !UserDefaults.standard.bool(forKey: AppConstants.notificationRationaleShownKey) {
                activeSheet = .notificationRationale
            }
        }
        // W6: Every pin drop (including replacements).
        //
        // Cancels old notifications, schedules new ones.
        // `previousCarID` is set by confirmPinDrop() BEFORE save() is called, so it holds
        // the old car's UUID at this point. After scheduling, we don't need to update it here —
        // the next confirmPinDrop() call will set it before the next save().
        //
        // W7.5 pass-2: No longer presents the ParkUntil sheet or clears the filter here.
        // The Park Until filter is now filter-first (toolbar button → see all matching blocks →
        // choose where to park). The filter is independent of pin lifecycle — it persists across
        // pin drops and is cleared only via X-on-pill, stale-target auto-clear, or "I left".
        .onReceive(parkPinService.pinDropped) { newCar in
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
        // W6.1 fix: Notification tap deep-link → open ParkedCarDetailView (AC-W6.11, OQ-W6-3).
        //
        // Previously used .onReceive(appDelegate.notificationDeepLinkSubject) with a
        // PassthroughSubject. That dropped events when the subscriber hadn't attached yet
        // (cold-kill / background-wake race: the delegate fires before SwiftUI finishes
        // mounting the view hierarchy).
        //
        // Fix: AppDelegate buffers the carID in @Published pendingDeepLinkCarID. Two paths
        // route a buffered carID to routePendingDeepLink:
        //   (a) .onChange(of: pendingDeepLinkCarID) — covers foreground and background-wake:
        //       fires when the delegate writes the property after this modifier is attached.
        //   (b) .onChange(of: scenePhase) { .active } (above) — covers cold-kill: catches a
        //       buffered value that was set BEFORE this view's .onChange modifier attached.
        //       iOS 17's .onChange(of:) does NOT fire on initial value, so the scenePhase
        //       handler is the only mechanism for that case.
        // After routing, the buffered ID is cleared to nil so the sheet does not re-present
        // on subsequent foreground transitions (idempotency, AC criterion 4).
        .onChange(of: appDelegate.pendingDeepLinkCarID) { _, carID in
            routePendingDeepLink(carID)
        }
        // W5.1 fix-pass Bug 2: Single enum-driven sheet.
        // All sheet cases are handled here; only one can be active at a time.
        // SwiftUI presents/dismisses based on activeSheet becoming non-nil / nil.
        // onDismiss clears selectedSegmentID when the block detail was showing,
        // so the overlay highlight is removed after the sheet animates away.
        // Sheet content extracted into sheetContent(_:) to reduce type-checker
        // complexity in body (W8.5c-polish PR-1 fix).
        .sheet(item: $activeSheet, onDismiss: {
            // If the block-detail sheet was dismissed (by swipe-down), clear the selection.
            // For parkConfirm / parkedCarDetail dismissal the selection is already nil.
            if selectedSegmentID != nil {
                selectedSegmentID = nil
            }
        }) { sheet in
            sheetContent(sheet)
        }
        // W8.5b: Full-screen destination search cover (OQ-2: Option C).
        // Separate from .sheet(item:) — can coexist in SwiftUI but Drive button
        // guard ensures only one is presented at a time.
        .fullScreenCover(isPresented: $showDriveModeDestination) {
            driveModeDestinationCover
        }
        // S-1 fix (spec §7 R-3, AC-DM.23): one-time background-limitation alert.
        // Shown on the first-ever Drive Mode start. BackgroundNoteGate (Constants.swift)
        // gates on UserDefaults key wepark_dm_bg_note_shown and marks it true before this
        // alert fires, so it shows exactly once across the lifetime of the install.
        .alert("Keep WePark in Front", isPresented: $showDriveModeBackgroundNote) {
            Button("Got It", role: .cancel) {}
        } message: {
            Text("Parking commentary will pause if you background WePark during your drive. Keep the app in front for continuous guidance.")
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
                // W8.5b: Route ready — enter Drive Mode.
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
            BlockDetailView(
                segment: segment,
                engine: engine,
                onDismiss: { dismissBlockDetail() },
                onParkHere: {
                    // W5: Path B — segment already known; use midpoint as coordinate.
                    initiatePathBPinDrop(from: segment)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

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
                }
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
        }
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

    // MARK: - W7.5 / W8.5c: Bottom safe-area content

    /// Content pushed into the bottom safe area via .safeAreaInset(edge: .bottom).
    /// Contains the Drive Mode bottom card and the Park Until filter pill.
    ///
    /// Extracted into its own @ViewBuilder property to reduce type-checker complexity
    /// in ContentView.body (W8.5c-polish PR-1 fix for "unable to type-check" error).
    @ViewBuilder
    private var bottomSafeAreaContent: some View {
        VStack(spacing: 0) {
            // W8.5c: Drive Mode bottom card (AC-W85c.25).
            if driveModeActive {
                DriveModeBottomCard(
                    context: drivingContext,
                    voiceService: drivingVoice,
                    destinationDistance: driveModeDistanceMeters
                )
            }
            // W7.5: Park Until pill.
            if parkUntilMode, let target = parkUntilTarget {
                ParkUntilPill(targetDate: target) {
                    clearParkUntilFilter()
                }
            }
        }
    }

    // MARK: - W5.1: Recenter button stack

    /// Two vertically-stacked recenter buttons, shown in the top-right of the map.
    /// "Find me" is always shown. "Find my car" is shown only when a pin exists.
    @ViewBuilder
    private var recenterButtonStack: some View {
        VStack(spacing: 8) {
            // "Find me" — recenter on user's current GPS location.
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

            // "Find my car" — shown only when a parked-car pin exists.
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

            // W7.5 pass-2: Park Until filter — standalone trigger (filter-first UX).
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

            // W8.5b: Drive Mode entry button (OQ-1: 4th top-right toolbar button).
            // Guard: only present destination search when no sheet is active (spec §7 Risk 2).
            Button {
                guard activeSheet == nil else { return }
                showDriveModeDestination = true
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(driveModeActive ? Color.blue : Color.accentColor)
            }
            .accessibilityLabel(driveModeActive ? "Drive Mode active — tap to change destination" : "Start Drive Mode — search for a destination")
            .accessibilityHint("Opens the destination search screen.")
        }
    }

    // MARK: - W8.5b/c: Drive Mode overlay layer

    /// Full-screen overlay layer visible during Drive Mode.
    /// Contains the "End Drive" pill (top-left) and the floating Recenter pill (bottom-center).
    ///
    /// Extracted into its own @ViewBuilder property to avoid hitting the Swift compiler's
    /// type-check complexity limit for large SwiftUI view bodies (W8.5c-polish PR-1 lesson:
    /// the inline version with .padding(.top, endDrivePillTopPadding) triggered
    /// "unable to type-check expression in reasonable time" at the ContentView body level).
    @ViewBuilder
    private var driveModeOverlayLayer: some View {
        VStack {
            // "End Drive" pill — top-left area, below the gear button.
            // W8.5c-polish PR-1 (Feature B): extra top padding clears the ASP banner
            // when the banner is visible (see endDrivePillTopPadding computed property).
            HStack {
                Button {
                    endDriveMode()
                } label: {
                    Label("End Drive", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("End Drive Mode")
                .padding(.leading, 12)
                Spacer()
            }
            .padding(.top, endDrivePillTopPadding)
            Spacer()
            // W8.5c: Recenter pill — OQ-2: floating above the bottom card,
            // only visible when follow mode is paused (AC-W85c.15).
            if !driveFollowEnabled {
                Button {
                    recenterDriveMode()
                } label: {
                    Label("Recenter", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Recenter map on my location")
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - W8.5b/c: End Drive Mode

    /// Clears all Drive Mode state (route polyline, destination pin, driveModeActive).
    /// MapViewRepresentable reacts to activeRoute=nil and destinationCoordinate=nil by
    /// removing the corresponding overlays and annotations automatically.
    /// W8.5c: Also stops continuous location + voice (via onChange(of: driveModeActive)).
    private func endDriveMode() {
        driveModeActive = false
        activeRoute = nil
        driveDestinationCoordinate = nil
        driveModeDistanceMeters = nil  // W8.5c-polish PR-1: clear distance indicator.
        // W8.5c context state cleared via onChange(of: driveModeActive).
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

    // MARK: - W8.5c: Recenter in Drive Mode

    /// Snaps the map camera back to the user's current GPS position during Drive Mode.
    /// Mirrors recenterDriveMode() from index.html:5800–5807.
    private func recenterDriveMode() {
        driveFollowEnabled = true
        if let loc = locationService.userLocation {
            recenterDriveMap(on: loc)
        }
    }

    /// Recenters the map during Drive Mode (drive zoom, no span change).
    private func recenterDriveMap(on coordinate: CLLocationCoordinate2D) {
        region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: AppConstants.drivingZoomMeters,
            longitudinalMeters: AppConstants.drivingZoomMeters
        )
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
    private func recenterMap(on coordinate: CLLocationCoordinate2D) {
        region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
    }

    // MARK: - Drive Mode lifecycle handler

    /// Handles Drive Mode entry and exit lifecycle.
    ///
    /// Extracted from `.onChange(of: driveModeActive)` to reduce type-checker complexity
    /// in ContentView.body (W8.5c-polish PR-1 fix).
    private func handleDriveModeChange(_ active: Bool) {
        if active {
            // Entering Drive Mode.
            locationService.startDriveMode()
            driveFollowEnabled = true
            // Create DrivingContextService and wire the voice service.
            let service = DrivingContextService(voice: drivingVoice)
            drivingContextService = service
            drivingContext = nil
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
            drivingContextService = nil
            drivingContext = nil
            driveFollowEnabled = true
            // Deactivate audio session.
            AudioSessionManager.shared.deactivateDriveSession()
        }
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
        // W8.5c: Drive Mode follow-mode + context update.
        if driveModeActive {
            // Follow-mode: recenter map on user when follow is enabled.
            if driveFollowEnabled {
                recenterDriveMap(on: coord)
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

        // W7: Initialize banner state.
        bannerState = aspService.suspensionState(at: .nowET)

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

    // MARK: - W5: Long-press handling

    private func handleLongPress(at coordinate: CLLocationCoordinate2D) {
        // Clear any current selection and dismiss any open sheet before opening ParkConfirmView.
        selectedSegmentID = nil
        activeSheet = nil

        // Run candidate-segment detection (Path A).
        let candidates = findCandidateSegments(
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            radius: pinDropRadiusMeters,
            max: 4
        )

        let detected = candidates.first?.segment
        let detectedDistance = candidates.first?.distanceMeters
        let alternatives = Array(candidates.dropFirst())

        let intent = PinDropIntent(
            pinLat: coordinate.latitude,
            pinLng: coordinate.longitude,
            detectedSegment: detected,
            detectedSegmentDistance: detectedDistance,
            alternativeCandidates: alternatives
        )
        activeSheet = .parkConfirm(intent)
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

// MARK: - Banner Padding

/// Returns the top padding (in points) that the End Drive pill needs to clear the ASP banner.
///
/// All three `SuspensionBannerState` cases render a visible banner (~44pt tall), so this
/// function always returns a non-zero value. The invariant: **if a banner is visible, the
/// pill must clear it.**
///
/// Extracted as an `internal` pure function so tests can assert the invariant directly
/// without instantiating a full `ContentView`.
func paddingForBannerState(_ state: SuspensionBannerState) -> CGFloat {
    // The ASP banner is approximately 44pt tall (subheadline font + 12pt vertical padding × 2).
    // All three states (.aspInEffect, .todaySuspended, .tomorrowSuspended) show a visible banner.
    switch state {
    case .aspInEffect, .todaySuspended, .tomorrowSuspended:
        return 44
    }
}

#Preview {
    ContentView(appDelegate: AppDelegate())
}
