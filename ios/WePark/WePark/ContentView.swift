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
//  FT-20 Stream C additions (browse-mode bottom sheet — the sheet goes LIVE, replacing the
//  toolbar chrome piecemeal — docs/ft20-bottom-sheet-navigation-spec.md §6/§9):
//    - `ft20BrowseSheetEnabled` flipped `true`; `activeSheet`'s default is `.browseNav`, not
//      `nil` — the sheet is browse mode's persistent cold-launch rest state (§4.1).
//    - `gearButtonOverlay` (gear + Parking 101 "?" buttons) and `driveEntryButton` (the
//      combined Drive/Cruise `Menu`) DELETED — absorbed into the sheet's medium-detent
//      action list. `driveModeDestinationCover`/`showDriveModeDestination`
//      (`DriveModeDestinationView`'s `.fullScreenCover`) DELETED along with
//      `Views/DriveModeDestinationView.swift` itself — `BrowseSearchAreaView` (Stream B) is
//      now the only search entry point. `SearchCompleterDelegate`/`SearchTimeoutError`
//      relocated to `Services/SearchCompleterDelegate.swift` (§0c).
//    - Park Until's toolbar button needed no relocation — it already lived in
//      `recenterButtonStack` alongside Find me / Find my car (OQ-2's "third floating
//      control" ruling); deleting `driveEntryButton` (the stack's 4th button) is what
//      leaves it as the natural 3rd/last button in a now-3-button stack.
//    - Drive Mode boundary (§6, AC-28/AC-29a): `browseSheetBoundaryTarget(_:)` — a pure
//      decision function — plus its call site in `handleDriveModeAndCamera` force-hide the
//      sheet on entry and restore it to `.browseNav` at PEEK on exit, batched into the SAME
//      `.onChange(of: driveModeActive)` transaction that also drives the Bottom Dock's
//      appearance/disappearance (no separate render pass, no overlap frame).
//    - FT-15 block-select boundary (§5.1, design-review S4): `cancelBlockSelectMode()` now
//      restores `.browseNav` on exit (previously left `activeSheet` untouched — AC-25 gap).
//      `blockSelectEntryGuardUntil` + `blockSelectTapShouldBeIgnored(now:guardUntil:)` guard
//      the first ~0.35s after block-select entry against a fast tap landing during the
//      three-overlapping-animations window (confirmationDialog dismiss, sheet force-hide,
//      `blockSelectBar` appear) — see `enterBlockSelectMode()`'s doc comment.
//    - QA §0d C1/C2 fixes (`docs/qa/ft20-stream-b-pr86.md`): measuring `searchField` alone
//      (`.onGeometryChange` as of PR #87 round 5 — see `BrowseNavigationSheet.swift`'s
//      removed-`PreferenceKey` doc comment) rather than the whole `searchArea` slot, so a
//      `List` mounted inside it at `.large` can never corrupt the peek/medium detent math;
//      `BrowseSearchAreaView` auto-expands to `.large` when an error arrives so it's never
//      invisible behind a collapsed sheet.
//
//  Build 19 additions (iCloud parked-car sync — docs/icloud-parked-car-sync-spec.md §3.5):
//    - .onReceive(parkPinService.remoteCarChanged): a THIRD, distinct publisher from
//      firstPinDropped/pinDropped, fired only by ParkPinService.applyRemoteChange() when a
//      remote (or migrated-legacy) car envelope wins the last-write-wins comparison.
//    - handleRemoteCarChanged(newCar:oldCarID:): schedules/cancels notifications via the new
//      NotificationScheduler.cancelAll(forUUID:) / cancelAllThenSchedule(...), dismisses a
//      now-stale .parkedCarDetail sheet, clears an orphaned Park Until filter — but
//      DELIBERATELY never sets activeSheet to .notificationRationale or .parkUntil, and never
//      touches hasEverParkedKey. A remote arrival must not look like a local pin drop to the
//      UI layer — see the spec's §3.5 trace for why piping it through the existing
//      pinDropped path would have been the wrong (and two-device-only-visible) bug.
//    - previousCarID bookkeeping generalized: also updated by handleRemoteCarChanged (not
//      just confirmPinDrop) so a SUBSEQUENT local drop always computes its "old ID" against
//      current reality, whether the last change was local or remote.
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
    ///
    /// Community 2.0 Phase 2a (build 20 S6): confirmCandidates added so ReportSheet's new
    /// "confirm the street" step can render without its own tile-data access — precomputed at
    /// each entry site via `CandidateSegmentSearch.confirmStreetCandidates(for:in:)` (empty
    /// when `segment` is nil, same OD-1 graceful-degradation rule).
    ///
    /// QA STOP-AND-INSTRUMENT (PR #95, 2026-08-28): coordinateSource added ONLY so
    /// `ReportSheet`'s `#if DEBUG` diagnostics footer can show, explicitly rather than
    /// inferred, whether `coord` is the resting long-press point or the in-drive current-GPS
    /// reading — set literally at each of the two call sites below, never derived/guessed.
    case reportPin(
        coord: CLLocationCoordinate2D,
        streetName: String?,
        segment: Segment? = nil,
        confirmCandidates: [Segment] = [],
        coordinateSource: String = "unknown"
    )
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
    /// Community 2.0 Phase 2b (build 20 S7, QA pass 1 fix — PR #96 Finding #2): the identity
    /// sheet ("Say hi to the crew") for the SPOT-POST contribution path
    /// (`submitSpotPlacement()`'s gate). Routed through the single `ActiveSheet` presenter
    /// rather than a second, independent `.sheet(isPresented:)` modifier — this codebase's
    /// W5.1 decision was explicitly single-sheet-only via this enum (HANDOFF documents the
    /// runtime warning a second concurrent `.sheet` used to trigger), and QA flagged a
    /// second modifier chained onto `ContentView`'s own view tree as the same *class* of
    /// pattern even though the intended flows don't overlap. No payload — the pending
    /// contribution to resume on save/skip lives in `pendingIdentityAction` (a separate
    /// `@State`, set in the SAME synchronous transaction as this case). The report-submit
    /// path's OWN identity sheet (nested inside `ReportSheet.swift`'s already-presented
    /// content — a standard, safe "sheet-from-a-sheet," not this pattern) is UNCHANGED by
    /// this fix; QA explicitly called that one "not at risk."
    case identityPrompt
    /// FT-20 Stream A: browse mode's persistent bottom-sheet rest state (spec §4.1, Option
    /// A). Unlike every other case above, this one is designed to NOT be transient — under
    /// the end-state sheet model, dismissing any other case returns `activeSheet` to
    /// `.browseNav`, not `nil` (see the `.sheet(item:)` `onDismiss` closure and each case's
    /// own dismiss target below). `nil` is reserved for the two states where the sheet must
    /// be fully hidden: Drive Mode active, or FT-15 block-select mode active (spec §5/§6 —
    /// wired by Stream C).
    ///
    /// That end-state behavior is gated behind `ft20BrowseSheetEnabled` (see its doc comment
    /// near `dismissTargetOutsideBrowseNav`) until Stream C lands the safety net this rest
    /// state depends on. While the gate is `false`, this case is defined but genuinely
    /// unreachable — every dismiss resolves to `nil`, same as before this case existed.
    case browseNav

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
        case .reportPin(let coord, _, _, _, _): return "reportPin-\(coord.latitude)-\(coord.longitude)"
        case .signCheckConfirm(let intent): return "signCheckConfirm-\(intent.id)"
        case .parkingGuide:               return "parkingGuide"
        case .blockRestrictionReport(let segments):
            return "blockRestrictionReport-" + segments.map(\.id).joined(separator: ",")
        case .identityPrompt:              return "identityPrompt"
        case .browseNav:                  return "browseNav"
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

    /// supabase-swift Stream B: injected from `WeParkApp` (one shared `RealtimeClientV2` for
    /// the app's lifetime — spec §3.4). Used at init time to build `pinService`'s Realtime
    /// channel via `supabaseClients.makeRealtimePinChannel()`, which returns the
    /// `RealtimePinSubscribing` protocol type — this file never needs `import Realtime`.
    let supabaseClients: SupabaseClients

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
    ///
    /// FT-20 Stream C: browse mode's cold-launch rest state is `.browseNav`, not `nil` —
    /// per spec §4.1/§7 AC-1/AC-3, the sheet is always visible at one of its three detents
    /// while browsing (peek by default). `nil` is reserved for the two states where the
    /// sheet must be fully hidden: Drive Mode active, or FT-15 block-select mode active
    /// (spec §5/§6 — both wired below, see `browseSheetBoundaryTarget` and
    /// `enterBlockSelectMode`).
    ///
    /// History: Streams A/B shipped this defaulting to `nil` behind `ft20BrowseSheetEnabled
    /// == false` (see that gate's doc comment) specifically because mounting `.browseNav` at
    /// cold launch without the Drive-Mode/block-select force-hide wiring already in place
    /// would have traded one bug (QA Finding #1's trapped sheet) for another (the browse
    /// sheet fighting Drive Mode's Bottom Dock on the very first launch). Both are wired
    /// now, in this same change, so the default flips safely.
    @State private var activeSheet: ActiveSheet? = .browseNav

    /// FT-20 Stream A (spec §4.1, design-review finding B1/B2): the two CUSTOM
    /// `.presentationDetents` heights for `.browseNav`, measured from the sheet's own
    /// rendered content by `BrowseNavigationSheet` and reported back up here. Defaults are
    /// plausible starting points only (see `BrowseSheetDetentMath`) — the real values are
    /// set on first layout and whenever the measured content changes (Dynamic Type, etc.).
    /// NEVER system `.medium` — see `BrowseSheetDetentMath`'s doc comment.
    @State private var browseSheetPeekHeight: CGFloat = BrowseSheetDetentMath.minimumPeekHeight
    @State private var browseSheetMediumHeight: CGFloat = 260

    /// Current detent selection for `.browseNav`, tracked semantically (not as a raw
    /// `PresentationDetent`) — see `BrowseSheetDetentKind`'s doc comment for why: the two
    /// `.height(_:)` detents' actual values change whenever `BrowseSheetDetentMath`
    /// re-measures, which would invalidate a stored raw `PresentationDetent`. Stream B's
    /// search-tap-to-expand behavior (spec §3.3) sets this to `.large` once it lands.
    @State private var browseSheetDetentKind: BrowseSheetDetentKind = .peek

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

    /// Controls visibility of `ParkingGuidePromptBanner`, rendered via
    /// `parkingGuideBannerOverlay` (floating above the browse sheet's peek — Kevin's
    /// live-smoke Ruling 2, spec §0e). Set to true once at launch (in
    /// `performLaunchSetup`) if `ParkingGuidePromptGate` says it hasn't been shown yet. Set
    /// back to false — and the gate marked shown — on tap-to-open, X-dismiss, or the
    /// banner's own ~8s auto-hide timer.
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

    /// FT-20 Stream C / design-review S4: the wall-clock deadline before which a
    /// block-select tap is ignored, set on every `enterBlockSelectMode()` call. Guards
    /// against a fast first tap landing during the ~3-animation settling window (the
    /// resting `.confirmationDialog` dismissing, the browse sheet force-hiding, `blockSelectBar`
    /// appearing) that all fire from the same synchronous entry action. `nil` outside
    /// block-select mode (or once the guard has served its purpose — cleared on exit).
    /// See `blockSelectTapShouldBeIgnored(now:guardUntil:)` for the pure comparison logic.
    @State private var blockSelectEntryGuardUntil: Date? = nil

    // MARK: - Community 2.0 Phase 2b (build 20 S7): spot placement mode

    /// True while the "Spot open" map-tap placement flow is active — mirrors
    /// `blockSelectModeActive`'s shape (a mutually-exclusive, map-tap-intercepting mode
    /// entered from a sheet action, force-hiding `activeSheet` for its duration). Entered
    /// via `enterSpotPlacementMode()` (called from `ReportSheet`'s "Spot open" grid tile,
    /// `onRequestSpotPlacement`), exited via `cancelSpotPlacementMode()` (Cancel tap on
    /// either the hint banner or the confirm card) or `submitSpotPlacement()`'s success path.
    @State private var spotPlacementActive: Bool = false

    /// The current snapped draft position, or nil before the first tap (or right after
    /// `enterSpotPlacementMode()`). Non-nil drives the confirm card
    /// (`spotPlacementConfirmOverlay`) and the map's dashed draft-pin annotation
    /// (`MapViewRepresentable.draftSpotCoordinate`). Replaced (not appended) on every
    /// subsequent tap while still in placement mode — "tap elsewhere to move the pin"
    /// (`design/prototype.html:102`).
    @State private var spotPlacementDraft: SpotPlacementDraft? = nil

    /// True while `submitSpotPlacement()`'s network write is in flight — drives the confirm
    /// card's "Post it" button spinner.
    @State private var spotPlacementSubmitting: Bool = false

    /// Community 2.0 Phase 2b: holds the "resume this contribution" closure while the
    /// identity sheet (`ActiveSheet.identityPrompt`) is up for the SPOT-POST path (the
    /// report-submit path has its own, entirely local copy of this pattern inside
    /// `ReportSheet.swift` — see that file's header for why the two don't share one
    /// instance: `SpotPlacementConfirmCard`'s "Post it" button lives in a `ContentView` map
    /// overlay, not inside a sheet, so it needs its own gate at this layer). Set in the same
    /// synchronous transaction as `activeSheet = .identityPrompt`
    /// (`submitSpotPlacement()`'s gate); cleared by `IdentitySheet`'s `onSave`/`onSkip`
    /// (`sheetContent(_:)`'s `.identityPrompt` case) or by the top-level `.sheet(item:)`
    /// `onDismiss` closure's swipe-to-dismiss guard — see that closure's own comment (QA
    /// pass 1, PR #96, Finding #2: this used to be a second, independent
    /// `.sheet(isPresented:)` modifier; routed through the single `ActiveSheet` presenter
    /// now, matching this codebase's W5.1 single-sheet decision).
    @State private var pendingIdentityAction: (() -> Void)? = nil

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

    /// Community 2.0 Phase 1 (S4): zone-chat read path for the crew feed
    /// (`Views/CrewFeedSection.swift`). Mirrors `pinService`'s own "can't reference a sibling
    /// stored property in a default expression" constraint — initialized in `init` below,
    /// sharing the app's one `RealtimeClientV2` via `supabaseClients.makeRealtimeZoneMessageChannel()`
    /// (same reasoning as `pinService`'s own `makeRealtimePinChannel()` call). Instantiated
    /// unconditionally (cheap — no network call happens until `setSelectedZone`/`startRealtime`
    /// are invoked, both gated behind `AppConstants.communityEnabled` at their call sites)
    /// rather than adding an `Optional` here purely for the flag, matching `pinService`'s own
    /// precedent of existing dark-shipped since Tier 1.
    @State private var zoneMessageService: ZoneMessageService

    // MARK: - Community 2.0 Phase 4b (S12): push registration + confirm-prompt card

    /// APNs registration + `device_push_tokens` upload (spec §2.9, `Services/PushRegistrationService.swift`).
    /// Mirrors `pinService`'s own "can't reference a sibling stored property in a default
    /// expression" constraint — initialized in `init` below (needs `authService`).
    /// Everything this service does is internally flag-gated on `AppConstants.communityEnabled`
    /// — instantiated unconditionally here (cheap, no network call at init) same as
    /// `zoneMessageService`'s own precedent.
    @State private var pushRegistrationService: PushRegistrationService

    /// The currently-showing WP5 in-app "did it pass?" confirm-prompt card's pin, or `nil` if
    /// none is showing. Set by `updateConfirmPromptCandidate(from:)` (called from
    /// `handleVisiblePinsChange`); cleared by either button on `ConfirmPromptCard`
    /// (`handleConfirmPromptConfirm`/`handleConfirmPromptDismiss`). At most one card shows at
    /// a time by construction (`updateConfirmPromptCandidate` early-returns while this is
    /// non-nil).
    @State private var confirmPromptPin: CommunityPin? = nil

    /// Cross-path dedupe store shared with `AppDelegate`'s background silent-push handler
    /// (`WeParkApp.swift`) via the SAME UserDefaults key — see
    /// `CommunityPushDedupeStore`'s own doc comment. A plain `let` (not `@State`): this type
    /// is a stateless wrapper over UserDefaults, not SwiftUI-observed state itself.
    private let confirmPushDedupeStore = CommunityPushDedupeStore()

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

    /// Initializes ContentView with the shared AppDelegate, SupabaseAuthService, and
    /// SupabaseClients.
    ///
    /// The explicit init is required because `pinService` (a `@State` property) depends on
    /// `authService` and `supabaseClients`, and Swift stored properties cannot reference
    /// sibling stored properties in their default expressions. Wrapping `State` manually lets
    /// us pass both into `CommunityPinService.init(authService:realtimeChannel:)` at init time.
    ///
    /// All other `@State` properties retain their inline default-expression initializers;
    /// those do not depend on injected values.
    init(appDelegate: AppDelegate, authService: SupabaseAuthService, supabaseClients: SupabaseClients) {
        self.appDelegate = appDelegate
        self.authService = authService
        self.supabaseClients = supabaseClients
        // CommunityPinService reads SUPABASE_URL + SUPABASE_ANON_KEY from Bundle.main,
        // attaches the shared authService for authenticated writes, and shares the app's one
        // RealtimeClientV2 via supabaseClients.makeRealtimePinChannel() (supabase-swift
        // Stream B, spec §3.4) instead of standing up a second, standalone socket.
        self._pinService = State(initialValue: CommunityPinService(
            authService: authService,
            realtimeChannel: supabaseClients.makeRealtimePinChannel()
        ))
        // Community 2.0 Phase 1 (S4) — see `zoneMessageService`'s own doc comment.
        // S13b (build 20, hero-gap-inventory WP3): `authService` added — required by
        // `ZoneMessageService.sendMessage`, the block-chatter/zone-compose write path this
        // session adds. Every pre-S13b caller of this service was read-only and unaffected.
        self._zoneMessageService = State(initialValue: ZoneMessageService(
            authService: authService,
            realtimeChannel: supabaseClients.makeRealtimeZoneMessageChannel()
        ))
        // Community 2.0 Phase 4b (S12) — see `pushRegistrationService`'s own doc comment.
        // Reads SUPABASE_URL/SUPABASE_ANON_KEY from Bundle.main via its convenience init,
        // same as pinService above.
        self._pushRegistrationService = State(initialValue: PushRegistrationService(
            authService: authService
        ))
    }

    // MARK: - Constants

    // Note: the overlay zoom-hide threshold formerly declared here as a private constant
    // moved to `AppConstants.polylineHideSpanThreshold` (2026-08-23). It no longer drives
    // `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` (that coupling was reversed
    // 2026-08-23, PR #89 on-device follow-up — the camera ceiling now derives from
    // `AppConstants.manhattanCoverageBounds` instead). See both constants' own doc comments
    // for the full three-layer relationship and the reversal writeup.

    /// Tap hit threshold in meters (matches W4 behavior).
    private let tapHitThresholdMeters: Double = 20.0

    /// W5: Radius for candidate-segment search (matches PWA findCandidateSegments).
    private let pinDropRadiusMeters: Double = 35.0

    /// FT-20 Stream C / design-review S4: how long a block-select tap is ignored after
    /// `enterBlockSelectMode()`, giving the three overlapping dismiss/appear animations
    /// (confirmationDialog, browse sheet, `blockSelectBar`) time to visually settle before
    /// the map starts accepting the precision multi-tap sequence block-select depends on.
    /// 0.35s is a reasoned starting point (comfortably longer than a standard ~0.3s sheet
    /// dismiss animation), not a measured value — this machine has no simulator to time the
    /// actual animation. Kevin's live smoke (PR checklist: "immediate fast tap on a
    /// blockface" right after entering block-select) is what confirms or corrects it.
    private static let blockSelectEntrySettlingDuration: TimeInterval = 0.35

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
            .onReceive(parkPinService.remoteCarChanged) { newCar, oldCarID in
                handleRemoteCarChanged(newCar: newCar, oldCarID: oldCarID)
            }
            .onChange(of: appDelegate.pendingDeepLinkCarID) { _, carID in routePendingDeepLink(carID) }
            // Community 2.0 Phase 4b (S12): forward a captured APNs device token to
            // PushRegistrationService, then clear the buffer (idempotency — same shape as
            // pendingDeepLinkCarID's own onChange handler, W6.1 precedent).
            .onChange(of: appDelegate.pendingDeviceToken) { _, token in
                guard let token else { return }
                pushRegistrationService.didReceiveDeviceToken(token)
                appDelegate.pendingDeviceToken = nil
            }
            // Community 2.0 Phase 4b (S12): the parked car's persisted state changed (parked,
            // cleared, replaced, or a remote-synced edit) — recompute the push zone_id.
            // currentUpdatedAt (Date?, Equatable) is used as the trigger rather than
            // parkPinService.parkedCar itself (ParkedCar is not Equatable, same
            // "observe an Equatable derived scalar" idiom this file already uses for
            // pinService.visiblePinsGeneration).
            .onChange(of: parkPinService.currentUpdatedAt) { _, _ in
                updatePushZoneFromParkedCarOrLocation()
            }
            .sheet(item: $activeSheet, onDismiss: {
                // Community 2.0 Phase 4a QA round 1 fix (PR #98, Finding #2): resync this
                // cache from UserDefaults on ANY sheet dismiss — closes a lost-update window
                // where `ParkedCarDetailView`'s My Car offset chips (which read/write the
                // SAME `ReminderOffsets` UserDefaults blob directly, bypassing this cache —
                // see that file's header) could be silently overwritten by a later,
                // unrelated `SettingsView` edit still holding this stale copy (`SettingsView`
                // writes back its FULL bound struct on every toggle). Cheap (a 5-bool JSON
                // decode) and unconditional — mirrors the existing `scenePhase == .active`
                // resync's own precedent, just on one more trigger. No scheduling-semantics
                // change: `NotificationScheduler.schedule`/`cancelAllThenSchedule` already
                // re-read `ReminderOffsets.load(from: .standard)` fresh on every call, never
                // this cached copy — this line only keeps `SettingsView`'s DISPLAY (and its
                // own write-back) honest. Flag-off is unaffected: nothing writes this
                // UserDefaults key while `AppConstants.communityEnabled == false` (My Car's
                // chip row never mounts), so this is a pure no-op re-read of whatever was
                // already there.
                reminderOffsets = ReminderOffsets.load(from: .standard)
                if selectedSegmentID != nil { selectedSegmentID = nil }
                // FT-15/TF2-15 Stream B2: clears the block-select highlight overlay on
                // ANY dismiss path (Submit success, Cancel button inside the sheet, OR a
                // swipe-to-dismiss that never calls the sheet's own onDismiss closure) —
                // same catch-all role selectedSegmentID plays above.
                if !selectedBlockKeys.isEmpty { selectedBlockKeys = [] }
                // Community 2.0 Phase 2b (build 20 S7, QA pass 1 fix — PR #96 Finding #2):
                // a still-non-nil `pendingIdentityAction` here means `.identityPrompt` went
                // away WITHOUT either `onSave` or `onSkip` running (both clear it before
                // returning) — i.e. an interactive swipe-to-dismiss, or any other non-button
                // dismissal. Treat that as "cancel the whole spot-placement attempt," same
                // as tapping Cancel on the confirm card: clear the deferred action (the
                // underlying report/spot-open must NOT post) and fully exit placement mode.
                // `cancelSpotPlacementMode()` itself sets `activeSheet` to
                // `dismissTargetOutsideBrowseNav` (`.browseNav` here), so the `== nil` guard
                // below correctly skips re-assigning it a second time.
                if pendingIdentityAction != nil {
                    pendingIdentityAction = nil
                    cancelSpotPlacementMode()
                }
                // FT-20 Stream A: `.browseNav` is browse mode's persistent rest state, not
                // "nothing" — restore it here as a backstop for any dismiss path that
                // doesn't already route through `dismissTargetOutsideBrowseNav` above (an
                // interactive swipe-to-dismiss, which sets `activeSheet` to `nil` directly
                // via SwiftUI's own binding before this closure runs; or a case with no
                // explicit dismiss closure of its own, e.g. `.settings`, which only ever
                // has this catch-all to fall back on).
                //
                // Guarded on `activeSheet == nil`: when a case's own dismiss handler has
                // already reassigned `activeSheet` to a NEW non-nil case (e.g.
                // `.signCheckConfirm`'s `onConfirm` → `.parkConfirm`, `.blockDetail` →
                // `.pinDetail` via `onOpenRestriction`), this closure must NOT clobber that
                // transition — it only fires for a genuine "nothing is showing anymore"
                // dismissal.
                //
                // Also guarded on `ft20BrowseSheetEnabled` (see its doc comment near
                // `dismissTargetOutsideBrowseNav` below) — this is the SECOND of the two
                // places in the file that can assign `.browseNav` as a dismiss target. Kept
                // even though the gate is permanently `true` now: it's the same defensive
                // shape as `dismissTargetOutsideBrowseNav`'s own guard, and costs nothing.
                //
                // Community 2.0 Phase 2b (build 20 S7, QA pass 1 fix — PR #96 Finding #2):
                // also guarded on `!spotPlacementActive` — without it, dismissing
                // `.identityPrompt` via `onSave`/`onSkip` (which set `activeSheet = nil`
                // themselves, ALSO triggering this same onDismiss closure) would restore
                // `.browseNav` immediately, before `submitSpotPlacement()`'s deferred
                // `proceed()` Task has had a chance to resolve — showing the browse sheet
                // AND the still-active confirm-card map overlay at once for a beat. Spot
                // placement mode already force-hides the sheet on entry
                // (`enterSpotPlacementMode()`'s `activeSheet = nil`) for exactly this
                // "nothing else should compete with placement mode's own chrome" reason —
                // this guard just extends that same rule across the identity-prompt detour.
                if Self.ft20BrowseSheetEnabled, activeSheet == nil, !driveModeActive,
                   !blockSelectModeActive, !spotPlacementActive {
                    activeSheet = .browseNav
                }
            }) { sheet in sheetContent(sheet) }
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
                    // Community 2.0 Phase 2a (build 20 S6): precompute "confirm the street"
                    // candidates alongside the existing single-segment lookup above — empty
                    // when off-segment (OD-1), same as reportSegment itself.
                    let confirmCandidates = reportSegment.map {
                        CandidateSegmentSearch.confirmStreetCandidates(for: $0, in: tileLoader.segments)
                    } ?? []
                    activeSheet = .reportPin(
                        coord: coord,
                        streetName: nil,
                        segment: reportSegment,
                        confirmCandidates: confirmCandidates,
                        // QA STOP-AND-INSTRUMENT (PR #95): `coord` here is `pendingLongPressCoord`
                        // — the actual long-press map coordinate captured fresh in
                        // `handleLongPress(at:)` at the moment of the press, not current GPS and
                        // not stale (consumed once, then cleared above). Labeled explicitly so
                        // the #if DEBUG diagnostics footer never has to guess.
                        coordinateSource: "long-press (resting)"
                    )
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

    // MARK: - FT-20 Stream C activation gate

    /// **FLIPPED TO `true` BY STREAM C**, in the same change that lands every piece of the
    /// safety net this rest state depends on — per QA docs/qa/ft20-stream-a-pr85.md Finding
    /// #1 (blocking), landing the flip WITHOUT all three of the following would regress to
    /// an inescapable, half-built sheet:
    ///   1. Mount `.browseNav` as browse mode's cold-launch rest state — `activeSheet`'s
    ///      `@State` default is `.browseNav`, not `nil` (see its own doc comment above).
    ///   2. The Drive-Mode boundary (spec §6, AC-28/AC-29a, design-review S3): force-hide
    ///      `.browseNav` the instant `driveModeActive` flips `true`; restore it to
    ///      `.browseNav` at PEEK the instant it flips back to `false` — both from the same
    ///      synchronous `.onChange(of: driveModeActive)` funnel
    ///      (`browseSheetBoundaryTarget(driveModeBecameActive:)`, called from
    ///      `handleDriveModeAndCamera`) that also drives the Bottom Dock's appearance, so
    ///      the two land in the SAME SwiftUI render pass — no frame shows both.
    ///   3. The FT-15 block-select boundary (spec §5.1, AC-23–27, design-review S4):
    ///      `enterBlockSelectMode()`'s pre-existing unconditional `activeSheet = nil`
    ///      force-hide is kept as-is (Streams A/B correctly left it alone); `cancelBlockSelectMode()`
    ///      now restores `.browseNav` on exit (previously left `activeSheet` untouched —
    ///      AC-25 was unimplemented until this change), and `blockSelectEntryGuardUntil`
    ///      guards the first fast tap against the three-animation entry race (design-review
    ///      S4) — see `enterBlockSelectMode()`'s doc comment.
    ///
    /// There are exactly two places in this file that can ever assign
    /// `activeSheet = .browseNav` as a DISMISS target (as opposed to a force-restore at a
    /// mode boundary, which is separate, deliberate code):
    ///   1. `dismissTargetOutsideBrowseNav`, immediately below — every one of the 14 existing
    ///      sheet-case dismiss closures, plus `dismissBlockDetail()`, reads this.
    ///   2. The `.sheet(item: $activeSheet, onDismiss:)` backstop in `body` above, which
    ///      otherwise assigns `.browseNav` for cases with no dismiss closure of their own
    ///      (`.settings`) and for interactive swipe-dismiss.
    /// (Verified exhaustive via `grep -n "= \.browseNav" ContentView.swift` at the time this
    /// gate was still `false` — no third dismiss-target site; the Drive-Mode/block-select
    /// boundary assignments added by this change are force-RESTORE sites, a different kind
    /// of write, not a third dismiss target.)
    private static let ft20BrowseSheetEnabled = true

    // MARK: - FT-20 Stream A: sheet-case dismiss target

    /// The correct dismiss target for any `ActiveSheet` case OTHER than `.browseNav`
    /// itself: `.browseNav` so browse mode's persistent sheet reappears, or `nil` if a
    /// mode that hides it entirely — Drive Mode, or FT-15 block-select — is active. Spec
    /// §4.1's mechanical "rest state" change: every one of the ~12 existing cases' dismiss
    /// closures below reads this instead of hardcoding `nil` (`activeSheet` is no longer a
    /// transient concept once `.browseNav` exists — see the `ActiveSheet` enum's doc
    /// comment on that case).
    ///
    /// NOT used by `enterBlockSelectMode()`'s own `activeSheet = nil` (that one is a
    /// deliberate FORCE-hide on block-select *entry*, unconditionally `nil` by design —
    /// spec §5.1) — this property is for sheets DISMISSING back to browse mode's rest
    /// state, not for the FT-15/Drive-Mode boundary's force-hide transitions, which are
    /// Stream C's wiring.
    ///
    /// Gated on `ft20BrowseSheetEnabled` (above) — while `false`, always resolves to `nil`,
    /// so this behaves exactly as it did before this PR's dismiss-target sweep.
    private var dismissTargetOutsideBrowseNav: ActiveSheet? {
        guard Self.ft20BrowseSheetEnabled else { return nil }
        return (driveModeActive || blockSelectModeActive) ? nil : .browseNav
    }

    /// True when no sheet is blocking a NEW sheet/mode-entry presentation — i.e.
    /// `activeSheet` is either genuinely empty, or is `.browseNav`, browse mode's
    /// persistent rest state. Guards that used to read `activeSheet == nil` to mean "no
    /// sheet is open" (e.g. `enterCruiseMode()`'s entry guard) need this instead now that
    /// `.browseNav` exists and is non-nil while browse mode is at rest — a bare `== nil`
    /// check would incorrectly treat "the browse sheet is showing its own action list,
    /// which the user just tapped a row in" as "a sheet is blocking this."
    private var noBlockingSheetPresented: Bool {
        switch activeSheet {
        case nil, .browseNav: return true
        default: return false
        }
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
                    activeSheet = dismissTargetOutsideBrowseNav
                    confirmPinDrop(result: result)
                },
                onCancel: {
                    activeSheet = dismissTargetOutsideBrowseNav
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
                    activeSheet = dismissTargetOutsideBrowseNav
                },
                onClearPin: {
                    activeSheet = dismissTargetOutsideBrowseNav
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
                    activeSheet = dismissTargetOutsideBrowseNav
                },
                onPermissionGranted: {
                    // Community 2.0 Phase 4b (S12): reuse this EXISTING permission-granted
                    // moment to trigger APNs registration — no new prompt is ever added by
                    // this call. Fires regardless of whether a car is currently parked
                    // (unlike the ASP-reminder scheduling below, which needs one) — see
                    // `PushRegistrationService.requestRegistrationIfEnabled`'s doc comment.
                    if AppConstants.communityEnabled {
                        pushRegistrationService.requestRegistrationIfEnabled()
                    }
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
                    activeSheet = dismissTargetOutsideBrowseNav
                    parkUntilTarget = targetDate
                    parkUntilMode = true
                    rebuildOverlays(at: .nowET)
                    let timeStr = ParkUntilSheet.formatTime(targetDate)
                    ToastService.shared.show(message: "Showing blocks free until \(timeStr)")
                },
                onSkip: {
                    activeSheet = dismissTargetOutsideBrowseNav
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

        case .reportPin(let coord, let streetName, let seg, let confirmCandidates, let coordinateSource):
            // Tier 3 sub-PR #2: Universal community report sheet.
            // Coordinate source depends on entry path:
            //   - Resting: coord = long-press point on map; streetName = nil
            //   - In-drive: coord = user GPS at moment of tap; streetName = drivingContext?.street
            // Bug #4: streetName passed through so ReportSheet shows "Reporting on <street>".
            // FT-11: seg passed through so ReportSheet shows the direction picker.
            //
            // Community 2.0 Phase 2a (build 20 S6):
            //   - confirmCandidates passed through for the new "confirm the street" step.
            //   - onRequestStreetClosure wires the sheet's new "Street closure" tile to the
            //     SAME existing hand-off `enterBlockSelectMode()` already uses from the
            //     resting long-press dialog's "Report closure" button — zero new code in
            //     `BlockRestrictionReportSheet.swift` (AC-P2.3). `enterBlockSelectMode()`
            //     force-hides `activeSheet` itself, which is what dismisses this sheet.
            //
            // Community 2.0 Phase 2b (build 20 S7): onRequestSpotPlacement wires the grid's
            // "Spot open" tile to `enterSpotPlacementMode()` — same shape as
            // onRequestStreetClosure above, a different hand-off destination.
            //
            // QA STOP-AND-INSTRUMENT (PR #95): coordinateSource/pinDropRadiusMeters passed
            // through to ReportSheet's #if DEBUG diagnostics footer only — no production
            // behavior reads either.
            ReportSheet(
                coordinate: coord,
                pinService: pinService,
                onDismiss: { activeSheet = dismissTargetOutsideBrowseNav },
                streetName: streetName,
                segment: seg,
                confirmCandidates: confirmCandidates,
                onRequestStreetClosure: { enterBlockSelectMode() },
                onRequestSpotPlacement: { enterSpotPlacementMode() },
                coordinateSource: coordinateSource,
                candidateSearchRadiusMeters: pinDropRadiusMeters
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
                    // Always presented while driveModeActive == true, so this always
                    // resolves to nil today — using the shared helper anyway keeps every
                    // case's dismiss target expressed the same way (spec §4.1).
                    activeSheet = dismissTargetOutsideBrowseNav
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
                    // driveModeActive is still true at this instant (endDriveMode() below
                    // is what flips it) — dismissTargetOutsideBrowseNav resolves to nil
                    // here either way; it's immediately reassigned to `.parkUntil` below.
                    activeSheet = dismissTargetOutsideBrowseNav
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
                    // driveModeActive == true here, so this resolves to nil, not .browseNav —
                    // the sheet stays hidden throughout Drive Mode either way (spec §6).
                    activeSheet = dismissTargetOutsideBrowseNav
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
                            Button("Done") { activeSheet = dismissTargetOutsideBrowseNav }
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
                onDismiss: { activeSheet = dismissTargetOutsideBrowseNav }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .identityPrompt:
            // Community 2.0 Phase 2b (build 20 S7, QA pass 1 fix): the SPOT-POST identity
            // gate, now routed through the single `ActiveSheet` presenter instead of a
            // second `.sheet` modifier — see the case's own doc comment for why.
            //
            // onSave/onSkip both dismiss THIS sheet by setting `activeSheet = nil` — the
            // SAME force-hidden value spot-placement mode was already in before the
            // identity gate interrupted it (`enterSpotPlacementMode()` sets `activeSheet =
            // nil`) — then invoke `action` (the deferred `submitSpotPlacement()` closure),
            // which owns the eventual `activeSheet` transition itself: `.browseNav` on a
            // successful post, or nil (placement mode resumes, confirm card still visible,
            // user can retry "Post it") if the network call fails. Deliberately NOT
            // `dismissTargetOutsideBrowseNav` here — that would jump straight to
            // `.browseNav` regardless of whether the underlying post actually succeeded.
            //
            // Username is REQUIRED (non-optional) — `IdentitySheet.resolvedUsername(rawHandle:)`
            // guarantees a non-empty value even when the pre-filled handle is cleared (QA
            // pass 1, PR #96, Finding #1: `profiles.username` is `NOT NULL` with no
            // `DEFAULT`, and PostgREST's upsert validates that on the constructed INSERT row
            // BEFORE conflict resolution — an omitted/empty username 400s on every call, not
            // only a first-ever write). The failure path is surfaced via a DEBUG print
            // rather than `try?`-swallowed — the underlying report/spot-open still posts on
            // its own independent network call either way, so a failed profile save is
            // never fatal to the user's actual contribution, but it shouldn't be silently
            // invisible to a developer either.
            IdentitySheet(
                onSave: { username, avatar in
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    activeSheet = nil
                    Task {
                        do {
                            try await pinService.upsertProfile(username: username, avatar: avatar)
                        } catch {
                            #if DEBUG
                            print("[ContentView] upsertProfile failed: \(error)")
                            #endif
                        }
                    }
                    action?()
                },
                onSkip: {
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    activeSheet = nil
                    action?()
                }
            )
            .presentationDetents([.medium])

        case .browseNav:
            browseNavigationSheetContent

        }
    }

    // MARK: - FT-20 Stream A: browse-mode sheet content

    /// `.browseNav`'s content + presentation config.
    ///
    /// ⚠️ Per spec §4.1 / design-review finding B1: the middle detent is a CUSTOM measured
    /// height (`browseSheetMediumHeight`), never system `.medium` — every one of the other
    /// 11 `.presentationDetents` call sites above uses `.medium`/`[.medium, .large]`; this
    /// is the one deliberate exception. See `BrowseSheetDetentMath`'s doc comment.
    ///
    /// `searchArea` is `BrowseSearchAreaView` (§4.3) — the sheet's real search/place
    /// content. Its own trailing-edge gear now owns Settings (§0f Ruling 1) — this call
    /// site is the only place `onSettingsTapped` is wired, straight into
    /// `BrowseSearchAreaView`'s initializer, not through `BrowseNavigationSheet`'s own
    /// action content anymore. Row actions call through to the same functions/case-
    /// assignments the deleted `gearButtonOverlay`/`driveEntryButton` used to (no new
    /// entry-path logic, only new UI leading into it, spec §3.1).
    ///
    /// `onRouteReady` (spec §0c item 3): this is now the ONLY copy of the
    /// "route ready → enter Destination Mode" sequence — the old
    /// `driveModeDestinationCover`'s duplicate closure body (byte-for-byte identical, per
    /// Stream B QA) was deleted along with the cover itself. `driveModeStyle = .destination`
    /// is still set BEFORE `driveModeActive = true` (CM-3: so `handleDriveModeChange` reads
    /// the correct style when it fires via `.onChange(of: driveModeActive)`).
    ///
    /// `.presentationBackground(.regularMaterial)` (§0f "still open" finding): this was
    /// simply MISSING before — `.browseNav` was the only 1 of this file's 12 `ActiveSheet`
    /// cases without it (11 others set `.regularMaterial` or `.ultraThickMaterial`,
    /// `ContentView.swift`'s other `.presentationBackground` call sites), leaving it on the
    /// plain opaque system sheet background instead of the app-wide material convention
    /// (spec §8/AC-32). Combined with the search field's own dark fill, that's the root
    /// cause of Kevin's "dark field on the sheet's dark blurred material, barely visible" —
    /// see `BrowseSearchAreaView.searchField`'s doc comment for the field-fill half of the
    /// fix.
    ///
    /// `detentKind: browseSheetDetentKind` (PR #87 round 4): plumbs the current detent
    /// selection into `BrowseNavigationSheet` so it can conditionally MOUNT (not just hide)
    /// its action column only when `detentKind.showsActionContent` — see
    /// `BrowseNavigationSheet.body`'s doc comment for the full root-cause writeup of why
    /// three prior peek-height-arithmetic-only fixes never killed the "peek reveals the
    /// action content" bug.
    @ViewBuilder
    private var browseNavigationSheetContent: some View {
        BrowseNavigationSheet(
            // PR #87 round 5: `searchArea` is now a BUILDER closure — `BrowseNavigationSheet`
            // hands it `onSearchFieldHeightChange`, its own `handleSearchFieldHeightChange`,
            // so `BrowseSearchAreaView.searchField` can report its live-measured height
            // straight back up via `.onGeometryChange`, replacing a `PreferenceKey` that
            // Kevin's on-device `#if DEBUG` readout showed never delivered a real value —
            // see `BrowseNavigationSheet.swift`'s removed-`PreferenceKey` doc comment.
            searchArea: { onSearchFieldHeightChange in
                BrowseSearchAreaView(
                    currentRegion: region,
                    segments: tileLoader.segments,
                    userLocation: locationService.userLocation,
                    locationService: locationService,
                    detentKind: $browseSheetDetentKind,
                    onRouteReady: { route, destination in
                        driveModeStyle = .destination
                        activeRoute = route
                        driveDestinationCoordinate = destination
                        driveModeActive = true
                    },
                    onSearchFieldHeightChange: onSearchFieldHeightChange,
                    onSettingsTapped: { activeSheet = .settings }
                )
            },
            detentKind: browseSheetDetentKind,
            onCruiseTapped: { enterCruiseMode() },
            onParkingGuideTapped: { activeSheet = .parkingGuide },
            onPeekHeightChange: { browseSheetPeekHeight = $0 },
            onMediumHeightChange: { browseSheetMediumHeight = $0 },
            // Community 2.0 Phase 1 (S4; QA pass 1 PR #94 Finding #2 fix): `BrowseNavigationSheet`
            // itself now gates the MOUNT on `AppConstants.communityEnabled` (not just this
            // closure's content — see that file's `crewFeed` doc comment for why "the closure
            // resolves to EmptyView" wasn't sufficient by itself). The `if` here is kept as a
            // second, redundant-but-harmless line of defense, not the authoritative gate.
            crewFeed: {
                if AppConstants.communityEnabled {
                    CrewFeedSection(
                        pinService: pinService,
                        zoneMessageService: zoneMessageService,
                        authService: authService
                    )
                }
            }
        )
        .presentationDetents(
            [.height(browseSheetPeekHeight), .height(browseSheetMediumHeight), .large],
            selection: browseSheetDetentSelectionBinding(
                kind: $browseSheetDetentKind,
                peekHeight: browseSheetPeekHeight,
                mediumHeight: browseSheetMediumHeight
            )
        )
        .presentationBackgroundInteraction(.enabled(upThrough: .height(browseSheetMediumHeight)))
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible)
        // Corner-radius fix (Kevin, on-device): ".browseNav" was the only one of this file's
        // 12 ActiveSheet cases with no explicit .presentationCornerRadius at all — see
        // browseSheetOuterCornerRadius's doc comment for the derivation.
        .presentationCornerRadius(Self.browseSheetOuterCornerRadius)
        // Apple Maps' sheet is never fully dismissible, only collapsible (spec §4.1) — the
        // rest state is always at least a peek, never "nothing."
        .interactiveDismissDisabled(true)
    }

    /// Corner-radius fix (Kevin, on-device smoke): *"Change the corner radius on the text
    /// bar to match the search box."* The browse sheet's outer container had NO explicit
    /// `.presentationCornerRadius` set at all — unlike every other one of this file's 12
    /// `ActiveSheet` cases, all of which set `20` (e.g. `pinDetailSheetContent`,
    /// `blockDetailSheetContent`) — so it fell back to the system default, which read as a
    /// visibly different, uncoordinated radius sitting right above
    /// `BrowseSearchAreaView.searchField`'s own `RoundedRectangle(cornerRadius: 10)` fill
    /// (`BrowseSearchAreaView.swift`).
    ///
    /// Nesting geometry: a rounded rect nested inside another rounded rect does NOT look
    /// right when the two radii are numerically EQUAL — the inner corner reads as "too
    /// round" because it has less room to curve into before hitting the padding. The
    /// visually-correct relationship is `outerRadius = innerRadius + padding`.
    ///
    /// This holds the search field's own already-tuned `cornerRadius: 10` fixed as the
    /// reference — Kevin's literal ask is to match the OUTER to the search box, not the
    /// other way around, and `searchField` was never called out as looking wrong on its
    /// own, only the mismatch was — and derives the outer sheet radius from it using
    /// `searchField`'s own `.padding(.horizontal, 16)` (the distance from the search
    /// field's rounded-rect edge to the sheet's edge; `BrowseNavigationSheet.body` applies
    /// no further horizontal inset above it, so 16 is the true edge-to-edge gap):
    ///
    ///     outerRadius = innerRadius (10) + horizontalPadding (16) = 26
    ///
    /// [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK] — this machine has no simulator. Kevin/
    /// QA: eyeball that the two corners now nest concentrically (not "too round" / "too
    /// square" relative to each other) before sign-off; this is a visual judgment call the
    /// formula above gets close to but can't fully replace a real screen for.
    private static let browseSheetOuterCornerRadius: CGFloat = 26

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
            onDismiss: { activeSheet = dismissTargetOutsideBrowseNav },
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
            onOpenRestriction: { pin in activeSheet = .pinDetail(pin) },
            // S13b (build 20, hero-gap-inventory WP3): required for the "BLOCK CHATTER"
            // section's read (fetchMessages(segmentId:)) and write (sendMessage) paths —
            // a mechanical wiring addition, not a new identity-routing concern (this view is
            // itself a `.sheet(item:)`-presented context, so its identity-gate interception is
            // handled locally, same as ParkedCarDetailView — no ContentView change needed for
            // that part). Declared after `onOpenRestriction` to match
            // `BlockDetailView`'s own property declaration order (Swift's synthesized
            // memberwise initializer requires call-site arguments in that same order).
            zoneMessageService: zoneMessageService
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
        guard region.span.latitudeDelta <= AppConstants.polylineHideSpanThreshold else {
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
                // FT-18: the browse-mode toolbar (Find me / Find my car / Park Until) and
                // the isolated Drive Mode "End" control share this top-trailing corner but
                // are mutually exclusive — exactly one renders at a time, matching Proposal
                // 1's "top of screen reduced to banner + End control" during Drive Mode
                // (Kevin's ruling #1).
                //
                // FT-15/TF2-15 QA fix (comment updated by FT-20 Stream C): `recenterButtonStack`
                // is ALSO hidden during block-select mode. Historically this was the sole UI
                // path to both Drive Mode entry points; FT-20 moved those into the browse
                // sheet (already force-hidden during block-select — `enterBlockSelectMode()`'s
                // `activeSheet = nil`), so this is now belt-and-suspenders decluttering for a
                // focused task rather than the only thing preventing a Drive-Mode-entry tap.
                // `handleDriveModeAndCamera` additionally force-clears block-select state on
                // every Drive Mode entry as a self-healing backstop — see that function's doc
                // comment for why both together, not either alone.
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
            // FT-20 Stream C: the gear + Parking 101 "?" buttons that used to float here
            // (`gearButtonOverlay`) are deleted — both are absorbed into the browse sheet's
            // medium-detent action list (Settings / Parking 101 rows,
            // `BrowseNavigationSheet.actionList`). `gearButtonVisible`/
            // `parkingGuideButtonVisible` are left defined + tested (dead but harmless —
            // no call site left) rather than deleted, to avoid unrelated test-file churn.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ToastHostView().padding(.top, proxy.safeAreaInsets.top)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            // FT-20 Stream C / Kevin's live-smoke Ruling 2 (spec §0e) — see
            // `parkingGuideBannerOverlay`'s own doc comment.
            parkingGuideBannerOverlay
            // Community 2.0 Phase 2b (build 20 S7): spot-placement mode's two floating
            // layers — same "VStack + Spacer() pinning content to one edge, inside this
            // outer ZStack(alignment: .top)" pattern as `parkingGuideBannerOverlay`/
            // `ToastHostView` just above, not a new positioning mechanism.
            spotPlacementHintOverlay
            spotPlacementConfirmOverlay
            // Community 2.0 Phase 4b (S12) WP5 rider: the in-app "did it pass?" confirm-prompt
            // card — same floating-overlay pattern as the two lines just above, not a new
            // positioning mechanism. See `confirmPromptOverlay`'s own doc comment for why this
            // is an overlay (not a modal `.sheet(item:)` through ActiveSheet).
            confirmPromptOverlay
        }
    }

    /// The blue "Tap the curb where the spot is / Cancel" pill — visible while placement
    /// mode is active and no draft has been placed yet. Positioned to clear both the status
    /// bar and the ASP banner, matching `recenterButtonStack`'s own `.padding(.top, 100)`
    /// convention for "float below the ASP banner" (`design/screenshots/10-spot-placement.png`).
    @ViewBuilder
    private var spotPlacementHintOverlay: some View {
        if spotPlacementActive && spotPlacementDraft == nil {
            VStack(spacing: 0) {
                SpotPlacementHintBanner(onCancel: cancelSpotPlacementMode)
                    .padding(.top, 100)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The "Spot open — {street} (side)" confirm card — visible once a draft position
    /// exists. Floats above the browse sheet's peek, same offset convention
    /// `parkingGuideBannerOverlay` already uses (`browseSheetPeekHeight + 12`).
    @ViewBuilder
    private var spotPlacementConfirmOverlay: some View {
        if spotPlacementActive, let draft = spotPlacementDraft {
            VStack(spacing: 0) {
                Spacer()
                SpotPlacementConfirmCard(
                    title: SpotPlacementCopy.confirmTitle(segment: draft.segment),
                    subtitle: SpotPlacementCopy.confirmSubtitle(
                        segment: draft.segment,
                        positionFraction: draft.positionFraction
                    ),
                    onPost: submitSpotPlacement,
                    onCancel: cancelSpotPlacementMode,
                    isSubmitting: spotPlacementSubmitting
                )
                .padding(.horizontal, 16)
                .padding(.bottom, browseSheetPeekHeight + 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Community 2.0 Phase 4b (S12) WP5 rider: the in-app "🧹 Sweeper reported on your
    /// block — did it pass?" confirm-prompt card (`Views/ConfirmPromptCard.swift`,
    /// `design/prototype.html:104-113`).
    ///
    /// Presentation choice: a floating overlay (same "VStack + Spacer(), pinned above the
    /// browse sheet's peek height" convention `spotPlacementConfirmOverlay`/
    /// `parkingGuideBannerOverlay` already use), NOT a modal `.sheet(item:)` through the
    /// `ActiveSheet` enum. The gap inventory's own framing describes this as reusing
    /// "the same LAYER as ArrivalPromptSheet's presentation pattern" — read here as "one
    /// state-machine-driven presentation slot, no stacked/competing chrome," not literally
    /// ArrivalPromptSheet's modal-sheet mechanism: a proactive card the user might be
    /// mid-task around (browsing the map, mid report flow) is closer to this file's existing
    /// floating-card family than to a blocking modal. Flagged in the PR description as a
    /// judgment call, not silently decided.
    @ViewBuilder
    private var confirmPromptOverlay: some View {
        if AppConstants.communityEnabled, let pin = confirmPromptPin {
            VStack(spacing: 0) {
                Spacer()
                ConfirmPromptCard(
                    pin: pin,
                    onConfirm: { handleConfirmPromptConfirm(pin) },
                    onDismiss: { handleConfirmPromptDismiss() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, browseSheetPeekHeight + 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// FT-12's "New to parking?" first-launch prompt, floating ABOVE the browse sheet's
    /// peek as its own card — Kevin's live-smoke Ruling 2 (spec §0e, 2026-08-21).
    ///
    /// This banner predates FT-20's sheet: it used to live inside `bottomSafeAreaContent`,
    /// a `.safeAreaInset(edge: .bottom)` attached directly to `mapRepresentable`
    /// (`mapZStack`, above). That inset is part of the SAME presentation layer as the map —
    /// it renders BEHIND the modally-presented `.browseNav` sheet, which is a separate
    /// `.sheet(item:)` presentation on top of everything in `mapLayerWithEvents`. Once the
    /// sheet occupies the bottom of the screen continuously in browse mode (even at peek —
    /// AC-1/AC-2, it's never fully dismissible), a banner placed in `bottomSafeAreaContent`
    /// is invisible: it's drawn underneath the sheet's own card, not above it. The banner's
    /// own visibility gate (`!driveModeActive && !parkUntilMode && !blockSelectModeActive`)
    /// predates the sheet entirely and knows nothing about it — moving the banner's
    /// POSITION is the fix, not its gating logic, which is unchanged here.
    ///
    /// The fix: render it as its own floating layer, offset up from the true bottom of the
    /// screen by `browseSheetPeekHeight` (+ a small gap) — the SAME measured value that
    /// drives `.browseNav`'s own `.presentationDetents`, not a hardcoded pixel offset, so
    /// this stays correct under Dynamic Type (a larger search field measures a taller
    /// `browseSheetPeekHeight`, and the banner rises to clear it automatically).
    ///
    /// Layout pattern mirrors the existing `ToastHostView` overlay just above (a `VStack`
    /// with a `Spacer()` pinning content to one edge within `mapZStack`'s outer
    /// `ZStack(alignment: .top)`) rather than inventing a new positioning mechanism.
    @ViewBuilder
    private var parkingGuideBannerOverlay: some View {
        if showParkingGuideBanner && !driveModeActive && !parkUntilMode && !blockSelectModeActive {
            VStack(spacing: 0) {
                Spacer()
                ParkingGuidePromptBanner(
                    onOpenGuide: { dismissParkingGuideBanner(openGuide: true) },
                    onDismiss: { dismissParkingGuideBanner(openGuide: false) }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, browseSheetPeekHeight + 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Community 2.0 Phase 2b (build 20 S7): dashed draft-pin annotation for the
            // "Spot open" placement flow — nil outside placement mode / before the first
            // tap. Driven straight from `@State`, same "optional coordinate in → add/remove
            // annotation, mechanical sync only" contract as `destinationCoordinate` above
            // (see `MapViewRepresentable.updateUIView`'s own architecture-invariant comment).
            // NB: argument order must match the memberwise init (declaration order) —
            // draftSpotCoordinate is declared directly after destinationCoordinate.
            draftSpotCoordinate: spotPlacementDraft?.coordinate,
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
    /// `ParkingGuidePromptBanner` used to be a 5th row here. Kevin's live-smoke Ruling 2
    /// (spec §0e) moved it to `parkingGuideBannerOverlay`, a separate floating layer above
    /// the browse sheet's peek — see that property's doc comment. Its VISIBILITY gating
    /// (mutually exclusive with the four rows below) is unchanged, only its position.
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
            // FT-12's "New to parking?" banner used to render here too. Kevin's live-smoke
            // Ruling 2 (spec §0e, 2026-08-21) moved it OUT of this safe-area-inset stack —
            // see `parkingGuideBannerOverlay`'s doc comment for why (it's a separate
            // `.sheet` presentation layer problem, not a `bottomSafeAreaContent` layout
            // problem) and where it lives now.
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

    // MARK: - W5.1 / Kevin 2026-06-04: Recenter + Park Until button stack

    /// Three vertically-stacked toolbar buttons in the top-right, visible only outside Drive
    /// Mode (FT-18: gated `if !driveModeActive` at the call site in `mapZStack` — none of
    /// these actions are available mid-drive; `endDriveControl` owns this corner instead).
    ///
    /// Button order (top to bottom):
    ///   1. "Find me"        — location.fill, always shown
    ///   2. "Find my car"    — car.fill, only when a pin exists
    ///   3. Park Until       — clock.fill, always shown (OQ-2: "a third floating map
    ///                         control beside Locate and Find-my-car" — its own filter
    ///                         behavior, framing, and toolbar position are all unchanged by
    ///                         FT-20; it's simply the last button once the 4th one is gone).
    ///
    /// FT-20 Stream C: the former 4th button — the combined Drive/Cruise entry `Menu`
    /// (`driveEntryButton`) — is DELETED. Its two former options are now reached via search
    /// (`BrowseSearchAreaView`'s place state → Go, destination path) and the sheet's
    /// primary "Find a Spot" button (`enterCruiseMode()`, no destination path — labeled
    /// "Cruise" until spec §0f Ruling 2 renamed it) — no menu, per Kevin's terminology
    /// ruling (spec §3.1, superseded on naming by §0f). This is a net reduction from FOUR buttons to
    /// THREE (design-review "what's working": Locate/Find-my-car/Park Until were already
    /// the only three that needed to stay outside the sheet — decision 5).
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
        }
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
                // Community 2.0 Phase 2a (build 20 S6): same "confirm the street" candidate
                // precompute as the resting long-press path above.
                let confirmCandidates = driveSegment.map {
                    CandidateSegmentSearch.confirmStreetCandidates(for: $0, in: tileLoader.segments)
                } ?? []
                activeSheet = .reportPin(
                    coord: loc,
                    streetName: drivingContext?.street,
                    segment: driveSegment,
                    confirmCandidates: confirmCandidates,
                    // QA STOP-AND-INSTRUMENT (PR #95): `loc` here is `locationService.userLocation`
                    // — live current GPS at the moment of the tap, per the guard above.
                    coordinateSource: "current GPS (in-drive)"
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
            //
            // FT-20 Stream A fix (QA docs/qa/ft20-stream-a-pr85.md Finding #2): this used to
            // guard on `activeSheet == nil`, which stops being equivalent to "no blocking
            // sheet is open" once `ft20BrowseSheetEnabled` flips true (`.browseNav` is
            // non-nil while browse mode is at rest). This is the more serious of the two
            // stale guards Finding #2 identified: "Park here" is a safety-relevant action
            // (recording where the driver parked), and a bare `== nil` check would have
            // silently no-op'd it — no error, no feedback — the first time this fires after
            // an ordinary sheet dismiss. `noBlockingSheetPresented` treats `.browseNav` the
            // same as `nil`, same fix already applied to `enterCruiseMode()`.
            Button {
                guard noBlockingSheetPresented else { return }
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
    /// Guard: only enters when no *blocking* sheet is active (same guard as destination
    /// mode entry). Applied inside the function so it holds regardless of call site.
    ///
    /// FT-20 Stream A fix: this used to guard on `activeSheet == nil`, which was correct
    /// when "no sheet is open" and "activeSheet is nil" meant the same thing. They no
    /// longer do — `.browseNav`'s medium-detent list is this function's own new call site
    /// (the "Cruise" row), so `activeSheet` is `.browseNav` (non-nil) at the exact moment a
    /// user taps it. A bare `== nil` check would silently no-op every tap, failing AC-18.
    /// `noBlockingSheetPresented` treats `.browseNav` the same as `nil` here; any other
    /// case (a real modal actually blocking entry, e.g. `ParkConfirmView`) still guards out.
    private func enterCruiseMode() {
        guard noBlockingSheetPresented else { return }
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
    ///
    /// zoom-out-limit-tighten (2026-08-23): guards against recentering onto a coordinate with
    /// no parking data (a non-NYC device, or an Apple reviewer in Cupertino). This action
    /// simply does not move the camera when the fix is out of coverage; it reuses the
    /// existing out-of-coverage toast (`BrowseSearchAreaView`'s "Limited parking data outside
    /// Manhattan", shown there for the analogous out-of-coverage-destination routing case)
    /// rather than inventing a second pattern. The camera stays wherever it already was — a
    /// place with data — so "no data AND can't get back" is structurally unreachable via this
    /// button.
    ///
    /// Independent of, and unaffected by, the zoom-out ceiling's later widening (PR #89
    /// on-device follow-up, `MapViewRepresentable.maxZoomOutCenterCoordinateDistance`): this
    /// guard is about WHERE the camera centers (a coordinate with data vs. without), not how
    /// far it can zoom out from wherever it lands. Even at the wider ~41.5km ceiling,
    /// recentering onto an out-of-coverage fix would still show the user a location with no
    /// parking overlays and, likely, no idea where relative to Manhattan they are — this
    /// guard stays regardless of the camera ceiling's value.
    private func recenterOnUser() {
        if let loc = locationService.userLocation {
            guard AppConstants.isInManhattanCoverage(loc) else {
                ToastService.shared.show(message: "Limited parking data outside Manhattan")
                // Still refresh the fix in the background — harmless, and picks up a fresher
                // position (e.g. the user has since moved back into coverage) for next tap.
                locationService.requestAndFetchLocation()
                return
            }
            // We have a cached fix, in coverage — recenter immediately.
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
        // Map markers: Tier 1 display types + Tier 3 ephemeral crowd pins (sub-PR #2) +
        // Community 2.0 Phase 1 (S4) crowd pins, gated — see `Self.mapMarkerTypes(communityEnabled:)`.
        // asp_suspended_today drives the banner supplement below, not a map marker.
        let mapMarkerTypes = Self.mapMarkerTypes(communityEnabled: AppConstants.communityEnabled)
        communityPins = newPins.filter { mapMarkerTypes.contains($0.pinType) }

        // ASP banner supplement (spec §4.2 / AC-D9a through AC-D9d).
        // resolvedBannerState() returns .todaySuspended if a live Supabase pin
        // overrides the bundle state, otherwise returns bundle state unchanged.
        let bundleState = aspService.suspensionState(at: .nowET)
        bannerState = resolvedBannerState(bundleState: bundleState, aspPins: newPins)

        // Community 2.0 Phase 4b (S12) WP5 rider — see `updateConfirmPromptCandidate`'s own
        // doc comment. Every `visiblePins` change (fetch, poll, or realtime) is a candidate
        // check, not just a live realtime INSERT — the dedupe store already prevents a
        // re-prompt for a pin the user has already seen either way, so this also correctly
        // catches a matching pin the user missed while the app was backgrounded and only
        // learns about on the next foreground fetch. Flagged in the PR description.
        if AppConstants.communityEnabled {
            updateConfirmPromptCandidate(from: newPins)
        }
    }

    /// Community 2.0 Phase 4b (S12) WP5 rider: sets `confirmPromptPin` to the first eligible
    /// `sweeper_passed` match, if any, using the SAME shared pure predicate
    /// (`CommunityPushRelevance.firstUnseenSweeperPassedMatch`,
    /// `Services/PushRegistrationService.swift`) the background silent-push handler uses.
    ///
    /// One card at a time by construction: no-ops while a card is already showing. Marks the
    /// match as seen in `confirmPushDedupeStore` IMMEDIATELY (not after the user acts on it) —
    /// per spec, a pin that surfaces the card must never re-prompt again regardless of what
    /// the user does with it (confirm, dismiss, or the app being backgrounded mid-card).
    ///
    /// PR #101 QA pass 1 (Finding #5, minor) asked whether mark-seen should move to AFTER the
    /// surface attempt succeeds, same as the background push path's fix (`WeParkApp.swift`).
    /// Deliberately NOT changed here: unlike `UNUserNotificationCenter.add(request:)` (a real
    /// async operation with a genuine failure mode), setting `confirmPromptPin = match` on the
    /// line immediately below is a synchronous SwiftUI `@State` assignment that cannot fail —
    /// there is no "surface attempt" with its own error path to defer past. Marking seen here,
    /// at the same call site that unconditionally sets `confirmPromptPin` right after, is
    /// already equivalent to "mark seen once the surface attempt succeeds" for this specific
    /// (non-fallible) surface.
    private func updateConfirmPromptCandidate(from pins: [CommunityPin]) {
        guard confirmPromptPin == nil else { return }
        guard let match = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: pins,
            parkedCarSegmentId: parkPinService.parkedCar?.detectedSegmentID,
            seenPinIds: confirmPushDedupeStore.seenIds()
        ) else { return }
        confirmPushDedupeStore.markSeen(match.id)
        confirmPromptPin = match
    }

    /// "Confirm — it passed" tap: the same `upsertVote(.confirm)` + `callExtendPinExpiry` pair
    /// `PinDetailSheet.ReactionsRow.handleStillHere` already uses for every other ephemeral
    /// crowd pin's "Still there?" action — no new write path, just a new trigger surface.
    /// Best-effort: a failed write still dismisses the card (the dedupe mark already happened
    /// in `updateConfirmPromptCandidate`, so it would not re-prompt anyway).
    private func handleConfirmPromptConfirm(_ pin: CommunityPin) {
        Task {
            do {
                try await pinService.upsertVote(pinId: pin.id, vote: .confirm)
                try await pinService.callExtendPinExpiry(pinId: pin.id)
            } catch {
                // Best-effort — see doc comment above.
            }
            confirmPromptPin = nil
        }
    }

    /// "Didn't see it" tap: dismiss only, no vote, no re-prompt (dedupe already recorded when
    /// the card was shown).
    private func handleConfirmPromptDismiss() {
        confirmPromptPin = nil
    }

    // MARK: - Community 2.0 Phase 4b (S12): push token zone derivation

    /// Recomputes the `zone_id` this device's push-token upload uses, per spec §2.9's privacy
    /// design — the ONLY location signal ever uploaded is a coarse zone id, never lat/lng or
    /// segment_id.
    ///
    /// Priority: the parked car's zone (if a car is parked) beats the current-location zone —
    /// a parked user's relevant zone is where the CAR is, not where the phone happens to be
    /// right now (they may have walked away). No car parked → fall back to current location.
    /// Neither resolves → `nil` (skip upload; `PushRegistrationService.updateZone(nil)` is a
    /// deliberate, documented no-op — "a token without a zone receives nothing by design").
    ///
    /// Called from `performLaunchSetup()`, `.onChange(of: parkPinService.currentUpdatedAt)`,
    /// `handleLocationUpdate()`, and `handleScenePhaseChange`'s `.active` branch (PR #101 QA
    /// pass 1 fix, Finding #2 — this fourth call site was claimed in the original PR
    /// description but not actually wired) — every signal that could change either input.
    private func updatePushZoneFromParkedCarOrLocation() {
        guard AppConstants.communityEnabled else { return }
        let zoneId: String?
        if let car = parkPinService.parkedCar {
            zoneId = CommunityZoneBounds.zoneId(forLat: car.latitude, lng: car.longitude)
        } else if let loc = locationService.userLocation {
            zoneId = CommunityZoneBounds.zoneId(forLat: loc.latitude, lng: loc.longitude)
        } else {
            zoneId = nil
        }
        pushRegistrationService.updateZone(zoneId)
    }

    /// Which `PinType`s become a map marker (`communityPins`, feeding
    /// `MapViewRepresentable`'s `syncCommunityPinAnnotations`).
    ///   - filming + special_event: Tier 1 open-data markers (AC-D8).
    ///   - enforcement_active + sweeper_passed: Tier 3 crowd ephemeral markers (spec §2.1).
    ///   - open_spot + leaving_soon: Community 2.0 Phase 1 (spec §2.1/§6), gated on
    ///     `communityEnabled` via `AppConstants.communityPhase1PinTypes(enabled:)` — the
    ///     single source of truth also used by `CommunityPinService`'s Channel 2 fetch and
    ///     `RealtimeMergeGate.mergeablePinTypes`.
    ///
    /// S4 QA pass 1, PR #94 Finding #1 (BLOCKING): this allow-list used to include
    /// `.openSpot`/`.leavingSoon` unconditionally — a SEPARATE gate from
    /// `RealtimeMergeGate.mergeablePinTypes` that was never actually checked against the
    /// flag, so any `open_spot`/`leaving_soon` row in `visiblePins` (Phase 0's migration is
    /// already live in production) would render as a map marker to every user regardless of
    /// `communityEnabled`. Extracted as a `nonisolated static` pure function (this file's own
    /// established pattern for testable decision logic, e.g. `browseSheetBoundaryTarget`) so
    /// both flag states are directly unit-testable without a live `ContentView` instance.
    nonisolated static func mapMarkerTypes(communityEnabled: Bool) -> Set<PinType> {
        let base: Set<PinType> = [.filming, .specialEvent, .enforcementActive, .sweeperPassed]
        return base.union(AppConstants.communityPhase1PinTypes(enabled: communityEnabled))
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
        // zoom-out-limit-tighten: same out-of-coverage guard as the immediate-fix branch in
        // recenterOnUser() above — this is the deferred completion of the same button tap
        // when no cached fix was available yet.
        if recenterOnUserRequested {
            recenterOnUserRequested = false
            if AppConstants.isInManhattanCoverage(coord) {
                recenterMap(on: coord)
            } else {
                ToastService.shared.show(message: "Limited parking data outside Manhattan")
            }
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
        // Community 2.0 Phase 4b (S12): a fresh location fix can change the current-location
        // zone fallback (`updatePushZoneFromParkedCarOrLocation`'s own doc comment) — only
        // matters when no car is parked (the parked car's zone always wins when one exists),
        // but the function itself already encodes that priority, so this call is unconditional.
        updatePushZoneFromParkedCarOrLocation()
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

        // supabase-swift Stream B: establishes the real WebSocket Realtime subscription on
        // public.pins (spec §5.1). Stays connected through Drive Mode (spec §7).
        pinService.startRealtime()

        // Community 2.0 Phase 1 (S4): mirrors pinService's own Realtime lifecycle, gated
        // behind the dark-ship flag so this is a genuine no-op (no socket opened) while
        // AppConstants.communityEnabled == false.
        if AppConstants.communityEnabled {
            zoneMessageService.startRealtime()
        }

        // Community 2.0 Phase 4b (S12): defensive re-registration in case notification
        // permission was already granted in a PRIOR session (requestRegistrationIfEnabled
        // only READS current authorization status — no new prompt), plus the initial zone_id
        // derivation from whatever parked-car/location state load() above just established.
        // Both internally no-op while AppConstants.communityEnabled == false.
        pushRegistrationService.requestRegistrationIfEnabled()
        updatePushZoneFromParkedCarOrLocation()

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
    ///
    /// supabase-swift Stream B (spec §5.3) adds exactly ONE new branch here — `.background` —
    /// per the standing "one scenePhase branch only, no camera/overlay surface" constraint for
    /// this file (FT-20's bottom-sheet redesign lands here next). The existing `.active`
    /// branch below is extended with two calls at the end, not restructured.
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .background {
            // iOS suspends/kills background socket activity for an app with no
            // background-execution entitlement anyway; disconnecting explicitly avoids the
            // Realtime socket dying in an ambiguous half-open state.
            pinService.disconnectRealtime()
            if AppConstants.communityEnabled {
                zoneMessageService.disconnectRealtime()
            }
            return
        }
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
        // supabase-swift Stream B (spec §5.3): reconnect the Realtime socket, plus a one-shot
        // catch-up re-fetch of the last-known viewport (belt-and-suspenders alongside the
        // reconnect for whatever changed on public.pins while backgrounded).
        pinService.reconnectRealtime()
        Task { await pinService.refetchCurrentRegion() }
        // Community 2.0 Phase 1 (S4): same reconnect treatment, same flag gate as launch.
        if AppConstants.communityEnabled {
            zoneMessageService.reconnectRealtime()
        }
        // Badge fix: the icon badge means "a reminder is waiting" (NotificationScheduler
        // sets content.badge = 1 on every scheduled ASP reminder). Once the user opens the
        // app they've seen whatever fired, so clear it here — standard behavior, what every
        // other app does. Nothing previously cleared it: the badge belongs to the install
        // (not the build), so the first reminder that ever fired stamped a permanent "1" on
        // the icon that survived every subsequent launch/build.
        NotificationScheduler.shared.clearBadge()
        // Community 2.0 Phase 4b (S12): re-attempt the token upload on foreground (a no-op if
        // token/environment/zone haven't changed since the last successful upload — spec
        // "re-upsert... on app foreground if changed"). Also a defensive re-registration check
        // in case permission was granted while backgrounded (e.g. via a system Settings toggle).
        //
        // PR #101 QA pass 1 fix (Finding #2): `updatePushZoneFromParkedCarOrLocation()` MUST
        // run here too, and BEFORE `handleAppForeground()` — without it, foregrounding after
        // being backgrounded across a zone boundary re-attempts the upload using the STALE
        // `currentZoneId` still held from before backgrounding (`handleAppForeground()` only
        // re-POSTs with whatever zone is already known; it does not recompute it). The other
        // three call sites (launch, parked-car change, location update) don't cover this path:
        // a foreground transition with no fresh GPS fix yet and no parked-car change relies on
        // this explicit call, not a side effect of something else.
        if AppConstants.communityEnabled {
            pushRegistrationService.requestRegistrationIfEnabled()
            updatePushZoneFromParkedCarOrLocation()
            pushRegistrationService.handleAppForeground()
        }
    }

    // MARK: - Dismiss helpers

    /// Dismisses the BlockDetailView sheet and clears the selection highlight.
    /// Also the fallback target for a map tap that misses every segment (`handleMapTap`) —
    /// FT-20 Stream A: this is `.blockDetail`'s dismiss target, so it returns to
    /// `.browseNav` (not `nil`) outside Drive Mode / block-select, same as every other
    /// sheet case's dismiss (spec §4.1).
    private func dismissBlockDetail() {
        activeSheet = dismissTargetOutsideBrowseNav
        selectedSegmentID = nil
    }

    // MARK: - Tap handling (unchanged from W4 — only gesture source changed)

    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        // Community 2.0 Phase 2b (build 20 S7): in spot-placement mode, a tap snaps to the
        // nearest curb instead of opening BlockDetailView. Checked FIRST — same reasoning as
        // the block-select check below (spot placement and block-select are mutually
        // exclusive by construction: block-select is entered from the resting long-press
        // dialog, spot placement from inside the report sheet's grid; neither entry path can
        // fire while the other mode's map-tap-intercepting state is active).
        if spotPlacementActive {
            handleSpotPlacementTap(at: coordinate)
            return
        }

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
    ///
    /// FT-20 Stream C: `activeSheet = nil` here is left as a literal `nil`, NOT
    /// `dismissTargetOutsideBrowseNav` — this is FT-15/§5.1's deliberate FORCE-hide on
    /// block-select entry (peek would still sit over the precision multi-tap area block-
    /// select needs), not an ordinary sheet dismiss back to browse mode's rest state.
    /// Streams A and B correctly left this alone (a force-hide, not a dismiss); Stream C
    /// decision: keep it exactly as-is. The restore-to-`.browseNav` half of this boundary
    /// (AC-25) is `cancelBlockSelectMode()`, below.
    ///
    /// Design-review S4 / spec §5's binding AC: entering block-select overlaps THREE
    /// presentation animations fired from this SAME synchronous button action (the
    /// resting-menu `.confirmationDialog` dismissing, this force-hide of the browse sheet,
    /// `blockSelectBar` appearing via `blockSelectModeActive = true` below) — all three
    /// state changes ARE already sequenced together (same function call, same SwiftUI
    /// transaction), so there is no ordering race between them. The remaining risk is pure
    /// wall-clock animation-settling time: the very next user action is a precision
    /// multi-tap sequence on the map, so a fast first tap landing before the outgoing
    /// chrome has visually cleared could hit residual chrome instead of the map.
    /// `blockSelectEntryGuardUntil` (below) guards exactly that window —
    /// `handleBlockSelectTap` ignores taps until it elapses. Kevin's live smoke (PR
    /// checklist) is what confirms the actual on-screen settling time this duration models.
    private func enterBlockSelectMode() {
        selectedSegmentID = nil
        activeSheet = nil
        selectedBlockKeys = []
        bothCurbsOn = true
        blockSelectModeActive = true
        blockSelectEntryGuardUntil = Date().addingTimeInterval(Self.blockSelectEntrySettlingDuration)
    }

    /// Exits block-select mode without submitting anything (floating bar's Cancel button).
    ///
    /// FT-20 Stream C / AC-25: restores the sheet to `.browseNav` — previously this left
    /// `activeSheet` untouched (still `nil` from `enterBlockSelectMode()`'s force-hide),
    /// which meant Cancel silently left the user with no sheet at all until their next
    /// dismiss-driven restore. `dismissTargetOutsideBrowseNav` resolves to `.browseNav` here
    /// (block-select just flipped false, Drive Mode is never active concurrently) and
    /// reuses whatever `browseSheetDetentKind` was already set to — AC-25's "at whatever
    /// detent it was at before block-select was entered" holds for free, since nothing in
    /// block-select mode touches that state.
    private func cancelBlockSelectMode() {
        blockSelectModeActive = false
        selectedBlockKeys = []
        blockSelectEntryGuardUntil = nil
        activeSheet = dismissTargetOutsideBrowseNav
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
        blockSelectEntryGuardUntil = nil
        activeSheet = .blockRestrictionReport(segments: segments)
    }

    /// FT-15/TF2-15 §4.2 step 3: finds the closest loaded segment to `coordinate` (same
    /// haversine-distance search + `tapHitThresholdMeters` gate as `handleMapTap`'s
    /// normal-mode block-detail lookup) and toggles its blockface into/out of the
    /// selection. A tap that misses every segment (beyond the hit threshold) is a no-op —
    /// no accidental selection from an imprecise tap.
    ///
    /// FT-20 Stream C / design-review S4: also ignores taps arriving inside the entry
    /// settling window (`blockSelectEntryGuardUntil`) — see `enterBlockSelectMode()`'s doc
    /// comment for why.
    private func handleBlockSelectTap(at coordinate: CLLocationCoordinate2D) {
        guard !blockSelectTapShouldBeIgnored(now: .now, guardUntil: blockSelectEntryGuardUntil) else { return }
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

    // MARK: - Community 2.0 Phase 2b (build 20 S7): Spot placement mode

    /// Entered via `ReportSheet`'s "Spot open" grid tile (`onRequestSpotPlacement`).
    /// Dismisses the report sheet and starts intercepting map taps — same force-hide shape
    /// as `enterBlockSelectMode()`'s `activeSheet = nil` (a deliberate hide, not an ordinary
    /// sheet dismiss back to `.browseNav`, since the whole point is a clear map for tapping).
    private func enterSpotPlacementMode() {
        activeSheet = nil
        spotPlacementDraft = nil
        spotPlacementActive = true
    }

    /// Exits placement mode without posting anything (hint banner's or confirm card's
    /// Cancel). Restores the sheet to `.browseNav` — same reasoning as
    /// `cancelBlockSelectMode()`.
    private func cancelSpotPlacementMode() {
        spotPlacementActive = false
        spotPlacementDraft = nil
        activeSheet = dismissTargetOutsideBrowseNav
    }

    /// A tap while in placement mode: snap to the nearest segment + position fraction
    /// (`CandidateSegmentSearch.nearestSegmentSnap`, the W5 haversine search extended to
    /// return a fraction along the segment) within `pinDropRadiusMeters`. Within radius →
    /// replaces `spotPlacementDraft` (never appends — "tap elsewhere to move the pin",
    /// `design/prototype.html:102`). Outside radius (or no segment loaded within it) →
    /// the "Tap closer to a curb" toast (`design/prototype.html:821`), draft unchanged.
    private func handleSpotPlacementTap(at coordinate: CLLocationCoordinate2D) {
        guard let snap = CandidateSegmentSearch.nearestSegmentSnap(
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            in: tileLoader.segments,
            radius: pinDropRadiusMeters
        ) else {
            ToastService.shared.show(message: SpotPlacementCopy.tapCloserToastMessage)
            return
        }
        spotPlacementDraft = SpotPlacementDraft(
            segment: snap.segment,
            positionFraction: snap.positionFraction,
            coordinate: snap.snappedCoordinate
        )
    }

    /// "Post it" on the confirm card. Identity-gated (spec §3 Phase 2: "every contribution
    /// path... spot post") the SAME way `ReportSheet.submitReport()` gates its own path —
    /// see `pendingIdentityAction`'s doc comment for why this is a separate instance rather
    /// than a shared one. On success: exits placement mode and restores `.browseNav` (the
    /// pin appears via `insertCrowdPin`'s existing optimistic `mergeRealtimeChange` — no
    /// extra state needed here for that).
    ///
    /// Community 2.0 Phase 2b (build 20 S7, QA pass 1 fix — PR #96 Finding #2): when the
    /// identity gate fires, `activeSheet` is set to `.identityPrompt` in the SAME
    /// synchronous transaction as `pendingIdentityAction` — routes through the single
    /// `ActiveSheet` presenter instead of a second, independent `.sheet` modifier. Safe to
    /// do unconditionally here: `enterSpotPlacementMode()` guarantees `activeSheet == nil`
    /// for the entire duration of placement mode up to this point (the confirm card is a
    /// map overlay, not a sheet), so this is always a clean nil → `.identityPrompt`
    /// transition, never a collision with another already-presented sheet.
    private func submitSpotPlacement() {
        guard let draft = spotPlacementDraft else { return }

        let proceed: () -> Void = {
            Task {
                spotPlacementSubmitting = true
                do {
                    try await pinService.insertCrowdPin(
                        type: .openSpot,
                        meta: nil,
                        lat: draft.coordinate.latitude,
                        lng: draft.coordinate.longitude,
                        segmentId: draft.segment.id,
                        zoneId: nil,
                        notes: nil,
                        positionFraction: draft.positionFraction
                    )
                    spotPlacementActive = false
                    spotPlacementDraft = nil
                    activeSheet = dismissTargetOutsideBrowseNav
                } catch {
                    ToastService.shared.show(message: "Couldn't post. Check your connection and try again.")
                }
                spotPlacementSubmitting = false
            }
        }

        if CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: AppConstants.communityEnabled,
            identitySheetShouldShow: CommunityIdentityGate().shouldShow()
        ) {
            pendingIdentityAction = proceed
            activeSheet = .identityPrompt
        } else {
            proceed()
        }
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
    ///
    /// Kept in sync with `CandidateSegmentSearch.oppositeSideCandidate(of:in:)` (Community
    /// 2.0 Phase 2a, build 20 S6) — an intentional, independently-tested duplicate of this
    /// exact predicate, kept separate to avoid a Services→View dependency. Update both if
    /// this matching rule ever changes (QA pass 1, PR #95 Finding #4).
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
        // FT-20 Stream A: the guard above guarantees driveModeActive/blockSelectModeActive
        // are both false here, so dismissTargetOutsideBrowseNav always resolves to
        // `.browseNav` — using the shared helper (not a literal `nil`) so the browse sheet
        // correctly reappears if the user cancels the confirmationDialog below, rather than
        // leaving the map with no chrome at all (`.browseNav` is browse mode's persistent
        // rest state now, not "nothing" — spec §4.1).
        selectedSegmentID = nil
        activeSheet = dismissTargetOutsideBrowseNav

        // Capture coordinate and show the confirmationDialog.
        // The dialog's action handlers (in body) build the PinDropIntent or reportPin sheet.
        pendingLongPressCoord = coordinate
        showRestingActionMenu = true
    }

    // MARK: - W5: "Park here →" Path B (from BlockDetailView)

    private func initiatePathBPinDrop(from segment: Segment) {
        // Clear selection and dismiss BlockDetailView before presenting ParkConfirmView.
        // FT-20 Stream A: uses the shared dismiss-target helper (not a literal `nil`) so
        // that if `midpoint` below is unexpectedly nil (malformed segment — the guard right
        // after this returns early), the browse sheet still reappears instead of leaving
        // `activeSheet` at `nil` forever.
        selectedSegmentID = nil
        activeSheet = dismissTargetOutsideBrowseNav

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
        // FT-20 Stream C (spec §6, AC-28/AC-29a, design-review S3): apply the browse-sheet
        // Drive Mode boundary FIRST, in this SAME synchronous handler — this is the single
        // funnel every Drive Mode entry/exit path runs through (`.onChange(of:
        // driveModeActive)`), so batching the sheet's hide/restore into the same call that
        // also flips `driveModeActive`-dependent chrome (the Bottom Dock's rows in
        // `bottomSafeAreaContent`, all gated on `driveModeActive` reads) guarantees both land
        // in the SAME SwiftUI render pass. AC-28/AC-29a's "no frame shows both" holds because
        // there is no intermediate render where one has updated and the other hasn't — see
        // `browseSheetBoundaryTarget`'s doc comment.
        switch browseSheetBoundaryTarget(driveModeBecameActive: active) {
        case .hidden:
            activeSheet = nil
        case .browseNavAtPeek:
            // Detent resets to peek unconditionally (AC-29a's "not wherever it was left"),
            // even in the guarded-out branch below — so IF the browse sheet does eventually
            // reappear (once whatever claimed activeSheet in its place dismisses), it's
            // already at peek.
            browseSheetDetentKind = .peek
            // Guard: only claim `activeSheet` if nothing else in this SAME transaction
            // already has. W8.5d's arrival-prompt "Park Here" flow calls `endDriveMode()`
            // then immediately sets `activeSheet = .parkUntil` in the SAME closure,
            // synchronously — SwiftUI batches every state write within one synchronous
            // scope into a single transaction and fires `.onChange` once afterward, so by
            // the time THIS handler runs, `activeSheet` already holds `.parkUntil`. That
            // deliberate auto-fire must win, not get silently overwritten back to
            // `.browseNav`. Same "don't clobber an already-reassigned sheet" guard the
            // top-level `.sheet(item:, onDismiss:)` backstop already uses for the identical
            // reason (see that closure's own comment in `body`).
            if activeSheet == nil {
                activeSheet = .browseNav
            }
        }

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
            //
            // Note: if this branch fires, `cancelBlockSelectMode()` redundantly re-applies
            // `activeSheet = nil` (it resolves the same way while `driveModeActive == true`)
            // — harmless, and keeps `cancelBlockSelectMode()`'s own AC-25 restore-to-
            // `.browseNav` logic correct for its OTHER caller (the Cancel button, where
            // Drive Mode is never active) without needing a special case here.
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

    // MARK: - Build 19: Remote car-changed event handler

    /// Handles the `parkPinService.remoteCarChanged` Combine event — a car that arrived (or
    /// was cleared) via iCloud sync from another device, or via the one-time legacy
    /// migration. Distinct from `handlePinDropped(_:)` on purpose (spec §3.5): this path
    /// must never look like a local pin drop to the sheet layer.
    ///
    /// - `newCar` non-nil: schedules/cancels notifications on THIS device per its own
    ///   mute/permission/per-pin-opt-in state (`NotificationScheduler.schedule()` already
    ///   fails closed per-device — see spec §3.5's "why scheduling still happens on the
    ///   receiving device" note).
    /// - `newCar` nil (remote clear): cancels this device's pending reminders for the old
    ///   car via the UUID directly, since `parkPinService.parkedCar` is already nil by the
    ///   time this fires.
    ///
    /// Deliberately does NOT set `activeSheet` to `.notificationRationale` or `.parkUntil`,
    /// and does NOT touch `hasEverParkedKey` — those are local-drop-only, by design.
    private func handleRemoteCarChanged(newCar: ParkedCar?, oldCarID: UUID?) {
        if let newCar {
            NotificationScheduler.shared.cancelAllThenSchedule(
                for: newCar,
                oldCarID: oldCarID,
                loadedSegments: tileLoader.segments,
                engine: engine
            )
        } else if let oldCarID {
            NotificationScheduler.shared.cancelAll(forUUID: oldCarID)
        }

        // Keep previousCarID correct across BOTH local and remote paths — a subsequent
        // local drop must compute its own "old ID" against current reality.
        previousCarID = newCar?.id

        // Spec §3.3.1: a remote change that replaces/clears the car currently shown in
        // ParkedCarDetailView leaves that sheet showing stale data (SwiftUI doesn't re-diff
        // an already-captured associated value) — dismiss it rather than live-refresh (§0.3).
        if case .parkedCarDetail(let shown) = activeSheet, shown.id == oldCarID {
            activeSheet = dismissTargetOutsideBrowseNav
        }

        // Mirror the existing onClearPin cleanup when the referenced car is gone remotely —
        // no orphan Park Until filter for a car that no longer exists.
        if newCar == nil, parkUntilMode {
            parkUntilMode = false
            parkUntilTarget = nil
            rebuildOverlays(at: .nowET)
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
    ///
    /// This is the multi-candidate version of the haversine point-to-segment search
    /// already used in handleMapTap. W5 spec §4.2 path A.
    ///
    /// Community 2.0 Phase 2a (build 20 S6): the actual algorithm now lives in
    /// `CandidateSegmentSearch.findCandidateSegments(lat:lng:in:radius:max:)` (extracted so
    /// `ReportSheet`'s new "confirm the street" step can reuse the same W5 pattern instead of
    /// reinventing it — spec §3 Phase 2). This wrapper exists only so every existing
    /// `findCandidateSegments(lat:lng:radius:max:)` call site in this file keeps reading
    /// `tileLoader.segments` implicitly, unchanged.
    private func findCandidateSegments(
        lat: Double,
        lng: Double,
        radius: Double,
        max maxResults: Int
    ) -> [CandidateSegment] {
        CandidateSegmentSearch.findCandidateSegments(
            lat: lat, lng: lng, in: tileLoader.segments, radius: radius, max: maxResults
        )
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

/// Returns whether `recenterButtonStack` (Find me / Find my car / Park Until — FT-20 Stream
/// C moved the Drive/Cruise entry points that used to live here into the browse sheet)
/// should render.
///
/// QA pass-1 finding (predates FT-20): an earlier revision gated this on `!driveModeActive`
/// alone. That correctly hid the stack once Drive Mode was already active, but did nothing
/// to stop the REVERSE transition — nothing prevented tapping the then-present Drive-entry
/// button while block-select mode was active, producing a stacked/competing Bottom Dock and
/// map taps hijacked into block selection while "driving." Hiding the stack whenever EITHER
/// flag is true closed that gap structurally. The Drive-entry button itself is gone now
/// (FT-20), but the mutual-exclusion rule stays — this is still the right visibility rule
/// for a floating toolbar during a focused block-select task, independent of what used to
/// motivate it.
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

// MARK: - FT-20 Stream C / design-review S4: block-select entry tap-settling guard

/// Pure comparison backing `handleBlockSelectTap`'s settling-window guard (see
/// `enterBlockSelectMode()`'s doc comment for the full "three overlapping animations"
/// reasoning). `guardUntil` is `nil` whenever block-select mode hasn't just been entered
/// (or the guard has already been cleared on exit) — in that case nothing is ignored.
///
/// Extracted as a pure function — `Date` comparison, no SwiftUI/view dependency — so the
/// boundary logic is unit-testable without a live view hierarchy, same discipline as
/// `recenterButtonStackVisible` / `shouldClearBlockSelectOnDriveModeEntry`.
func blockSelectTapShouldBeIgnored(now: Date, guardUntil: Date?) -> Bool {
    guard let guardUntil else { return false }
    return now < guardUntil
}

// MARK: - FT-20 Stream C: Drive Mode boundary (spec §6, AC-28/AC-29a, design-review S3)

/// What the browse sheet should become the instant `driveModeActive` flips, in either
/// direction. A pure decision enum — not `ActiveSheet` itself, which isn't `Equatable`
/// (several cases carry non-Equatable associated payloads like `Segment`/`CLLocationCoordinate2D`)
/// — so this boundary rule is unit-testable without constructing a live view hierarchy,
/// same discipline as `recenterButtonStackVisible` / `shouldClearBlockSelectOnDriveModeEntry`.
enum BrowseSheetDriveBoundaryTarget: Equatable {
    /// AC-28: force-hide unconditionally on Drive Mode ENTRY — the same "hide, don't peek"
    /// precedent FT-15's block-select boundary already established (§5.1); FT-18's Bottom
    /// Dock owns the bottom safe area for the whole Drive Mode session.
    case hidden
    /// AC-29a: restore to `.browseNav` at PEEK on Drive Mode EXIT — not wherever the sheet
    /// was left (spec §6: "a completed drive session, stale search state").
    case browseNavAtPeek
}

/// Returns the target for `driveModeActive`'s new value. Trivial as a ternary, but named
/// and extracted for the same reason `shouldClearBlockSelectOnDriveModeEntry` is: it's the
/// one place this specific product decision (hide on entry / peek on exit, not "wherever it
/// was") lives, independently testable and independently readable from the call site that
/// applies it.
func browseSheetBoundaryTarget(driveModeBecameActive: Bool) -> BrowseSheetDriveBoundaryTarget {
    driveModeBecameActive ? .hidden : .browseNavAtPeek
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
    let clients = SupabaseClients()
    ContentView(appDelegate: AppDelegate(), authService: clients.makeAuthService(), supabaseClients: clients)
}
