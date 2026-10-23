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
    /// Community 2.0 S13a (WP1, build 20): the "?" map-key button's legend
    /// (`Views/MapKeyLegendView.swift`, `design/screenshots/02-map-key.png`). No payload —
    /// the view's content is static data. Presented at `.medium` detent, no explicit dismiss
    /// closure of its own (same shape as `.settings`) — relies on the `.sheet(item:)`
    /// `onDismiss` catch-all to restore `.browseNav`. See `MapKeyLegendView.swift`'s header
    /// for why a sheet (not a floating popover) is the correct native mapping here.
    case mapKeyLegend
    /// Regulars network S7 LIVE-GATE FIX (`docs/qa/pr115-regulars-s7-livegate.md`): the
    /// invite-redemption confirm sheet (`RegularInviteRedemptionView`), presented when
    /// `wepark://invite/<uuid>` is opened. Payload: the parsed invite token
    /// (`RegularsInviteLink.resolveRedemptionToken(from:)`, `.onOpenURL` in `body` below).
    ///
    /// **Root cause this case fixes:** the original S7 build attached this sheet as a SECOND,
    /// independent `.sheet(isPresented:)` modifier directly on `ContentView(...)` from
    /// `WeParkApp.swift`. Live on-device testing (flag-on) confirmed it never presented, in
    /// any app state, including the map's plain rest state — because `.browseNav` already
    /// occupies THIS file's one `.sheet(item: $activeSheet)` host at all times at rest (FT-20
    /// Stream A made `.browseNav` the persistent default, not "nothing"), and SwiftUI only
    /// supports a single `.sheet` host presenting from one view hierarchy at a time (this
    /// file's own W5.1-era header comment: "SwiftUI only supports a single .sheet() host per
    /// view"). This is the EXACT same *class* of bug PR #96 found and fixed for
    /// `.identityPrompt` (see that case's own doc comment) — a second, independently-toggled
    /// `.sheet` modifier chained onto `ContentView`'s own view tree, even though the two flows
    /// don't overlap in time. Routing through this single presenter, exactly like
    /// `.identityPrompt`/`.mapKeyLegend`, is the fix.
    ///
    /// No per-case dismiss target needed: `RegularInviteRedemptionView`'s own "Close"/"Done"
    /// buttons call the SwiftUI environment `dismiss()` action, which SwiftUI resolves by
    /// setting `activeSheet` back to `nil` on this binding automatically (same mechanism an
    /// interactive swipe-to-dismiss uses) — the `.sheet(item:)` `onDismiss` catch-all then
    /// restores `.browseNav` from there, identical to `.settings`/`.mapKeyLegend`'s own
    /// no-explicit-transition posture.
    ///
    /// Presents reliably from ANY app state by design, not just the map's rest state: this
    /// case is assigned UNCONDITIONALLY by `routeRegularsInviteRedemption(_:)` (no `guard
    /// activeSheet == nil`/`== .browseNav` check) — the exact same "just overwrite whatever's
    /// showing" contract `routePendingDeepLink(_:)` (the notification-tap deep link) already
    /// uses for `.parkedCarDetail`. Opening an invite link is just as deliberate a user action
    /// as tapping a notification; whatever was open (browse sheet at any detent, block detail,
    /// My Car) is preempted, not silently dropped.
    case regularsInviteRedemption(token: UUID)
    /// Addendum 3 A3.4 (`docs/design/goal-first-ambient-design.md`, flag-on only): the "More"
    /// sheet opened by the ambient rail's ellipsis button — the single door to Report, the map
    /// key, the full-palette toggle, Find my car, and the Park Until clock. No payload. A row
    /// tap SWAPS `activeSheet` to its destination (never stacks sheets); Done and
    /// swipe-dismiss resolve through `dismissTargetOutsideBrowseNav` / the `.sheet(item:)`
    /// `onDismiss` catch-all back to the rest state (`driveModeDefaultRestStateSheet()`).
    case moreMenu

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
        case .mapKeyLegend:               return "mapKeyLegend"
        case .regularsInviteRedemption(let token): return "regularsInviteRedemption-\(token.uuidString)"
        case .moreMenu:                   return "moreMenu"
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

    // MARK: - Regulars network (S7, docs/regulars-network-spec.md §3.1)

    /// Injected from `WeParkApp` — SAME instance `WeParkApp` also uses for its own
    /// `.onOpenURL` invite-redemption sheet (mirrors `authService`'s own AC-A5 singleton
    /// invariant: `RegularsService` is built once, wrapping that one shared `authService`, not
    /// re-constructed per consumer). Threaded straight through to `SettingsView` →
    /// `RegularsSettingsView` at the `.settings` sheet case below; `ContentView` itself never
    /// calls anything on it directly. Zero live effect while
    /// `AppConstants.regularsEnabled == false` (today's shipped default) — the row that would
    /// ever present `RegularsSettingsView` is itself gated on that flag (`SettingsView.swift`).
    let regularsService: RegularsService

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - State

    /// Current map region — kept in @State so ContentView owns the camera.
    /// Passed to MapViewRepresentable as a Binding; updated by the regionChanged callback.
    ///
    /// Part A fix 2 (`docs/design/goal-first-ambient-design.md` Addendum 2's predecessor
    /// diagnosis): the literal span used to be hardcoded here regardless of the flag — see
    /// `initialLaunchRegion(driveModeDefaultEnabled:)`'s doc comment for why that was a bug.
    @State private var region: MKCoordinateRegion = ContentView.initialLaunchRegion()

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
    ///
    /// DM-1 (`docs/drive-mode-default-spec.md` §0.4/§3.3): while
    /// `AppConstants.driveModeDefaultEnabled == false` (today's shipped default), this is
    /// unchanged — `.browseNav`, byte-identical to pre-DM-1 behavior (spec AC-1). Once flipped
    /// `true`, cold launch is genuinely sheet-free (`nil`) — see
    /// `driveModeDefaultRestStateSheet(driveModeDefaultEnabled:)` below, the shared pure
    /// function this and `dismissTargetOutsideBrowseNav` both read, so the two rest-state
    /// sites can never drift apart (spec §0.4: "Both the initial `@State` and this rest-state
    /// target must flip together, or this ships half-converted").
    @State private var activeSheet: ActiveSheet? = driveModeDefaultRestStateSheet()

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

    /// §0.8.4: whether the CURRENT `parkUntilTarget`'s `isFree()` evaluation (in
    /// `rebuildOverlays`) should ignore metered payment. Default `false` preserves the
    /// power-user `ParkUntilSheet`'s existing strict semantics byte-for-byte (§0.8.9's
    /// "unmodified" guarantee) — only the goal-driven recompute block below ever sets this
    /// `true` (Free Overnight / Park & Forget, §0.8.4), and only while
    /// `AppConstants.driveModeDefaultEnabled && !fullPaletteMode`. Explicitly reset to
    /// `false` by `clearParkUntilFilter()` and the custom `ParkUntilSheet.onConfirm` handler
    /// so a prior goal selection's `true` can never silently leak into a later custom-time
    /// filter (the one real correctness trap this flag introduces — see those two call
    /// sites' own comments).
    @State private var parkUntilIgnoresMeteredPayment: Bool = false

    // MARK: - DM-2: Goal-first ambient dock state (docs/drive-mode-default-spec.md §0.8)

    /// The goal currently shown as "selected" on the ambient dock (§0.8.1). Always holds a
    /// concrete value — "no goal selected" isn't a state this dock represents, matching
    /// `fullPaletteMode`'s orthogonal on/off semantics below. Defaults to `.freeOvernight`
    /// so a flag-on cold launch is already pre-selected (AC-21) with zero extra wiring: the
    /// very first `rebuildOverlays()` call (segment load, 60s tick, whatever fires first)
    /// reads this default and renders the filtered answer immediately.
    ///
    /// Only READ by `rebuildOverlays`/the dock itself while
    /// `AppConstants.driveModeDefaultEnabled && !fullPaletteMode` — while the flag is off, or
    /// the user has toggled to full-palette, this value just sits here unread (harmless;
    /// AC-2's "no goal-filtered overlay render anywhere" holds because the READER is gated,
    /// not because this default is somehow flag-aware itself).
    @State private var selectedGoal: ParkingGoal = .freeOvernight

    /// True once the user has toggled OUT of goal-first (§0.8.8) — functionally identical to
    /// today's `clearParkUntilFilter()` plus "don't let the goal-recompute block in
    /// `rebuildOverlays` touch `parkUntilMode`/`parkUntilTarget` anymore," so the power-user
    /// `ParkUntilSheet` path (§0.8.9) stays the sole owner of the filter while this is `true`.
    /// Always `false` while `AppConstants.driveModeDefaultEnabled == false` (nothing ever
    /// flips it — the toggle row only exists on the ambient dock, itself flag-gated).
    @State private var fullPaletteMode: Bool = false

    /// Non-nil only when `selectedGoal == .parkAndForget` and the viewport-wide ladder walk
    /// (`resolveParkAndForgetViewport`, §0.8.9/§0.8.10) had to step down from the top rung, or
    /// came up empty even at the bottom rung. Drives `GoalSelectorView`'s empty-map-guard
    /// banner. `nil` for every other goal, and for Park & Forget whenever the top rung clears
    /// cleanly in the current viewport.
    @State private var parkAndForgetGuardState: ParkAndForgetViewportResolution? = nil

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

    // MARK: - A3.6 ambient driving look state (flag-on only; SEAM: self-contained block)

    /// Which zoom step the ambient driving look was last applied at (`AmbientDrivingLook`,
    /// A3.6.1 accuracy guard). Only ever read/written while `AppConstants.driveModeDefaultEnabled`.
    @State private var ambientLookStep: AmbientDrivingLook.ZoomStep = .wide

    /// True once the USER has panned/pinched the map since the look was last applied
    /// (`coordinatorActions.onAmbientUserAdjusted`). Stops auto-tightening from fighting them.
    @State private var ambientLookUserAdjusted = false

    /// Screen-space "user's dot is outside the central 50% of the map" (Recenter, A3.2) -
    /// correct under the look's pitch. `nil` until measured; the rail falls back to the
    /// region-based test while nil. Refreshed from `handleRegionChanged` /
    /// `handleLocationUpdate`, never from a view body.
    @State private var ambientUserDotOffCenter: Bool? = nil

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

    // MARK: - DM-3: First-launch location priming card

    /// DM-3 (`docs/drive-mode-default-spec.md` §0.2): controls visibility of
    /// `LocationPrimingCard` via `locationPrimingCardOverlay`. Set once at launch
    /// (`performLaunchSetup`) via the pure `locationPrimingCardShouldShow(...)` — true only
    /// when `driveModeDefaultEnabled`, `LocationPrimingCardGate` has never fired, AND
    /// `locationService.authorizationStatus == .notDetermined`. Set back to false — and the
    /// gate marked shown — by `dismissLocationPrimingCard(allowed:)` on EITHER "Allow" or
    /// "Not now" (both count as "shown", mirroring `BackgroundNoteGate`'s own contract).
    @State private var showLocationPrimingCard: Bool = false

    /// DM-3 (`docs/drive-mode-default-spec.md` §0.2): drives the denied/restricted-state
    /// alert fired from `enterCruiseMode()`'s auth-request fix. Same name as
    /// `BrowseSearchAreaView.showLocationDeniedAlert` (a different view, same pattern) —
    /// `BrowseSearchAreaView.handleGoTap()`'s existing switch over
    /// `.notDetermined`/`.denied`/`.restricted`/authorized is the precedent
    /// `cruiseEntryAuthAction(for:)` below mirrors for Cruise's own entry point, which had no
    /// equivalent gate before this fix.
    @State private var showLocationDeniedAlert: Bool = false

    /// DM-2 fast-follow (`docs/qa/pr131-dm3-priming-authfix.md` 🟡 Finding #1): true from the
    /// moment `enterCruiseMode()`'s `.requestFirst` branch fires the real system prompt until
    /// `locationService.isAuthorized` changes — mirrors `BrowseSearchAreaView
    /// .isRequestingAuth` exactly, closing the gap that PR's QA flagged (the Cruise-entry fix
    /// shipped WITHOUT the `.onChange`-driven auto-continue destination-mode Drive already
    /// has, despite a code comment that incorrectly claimed parity). See the
    /// `.onChange(of: locationService.isAuthorized)` handler in `body` below.
    @State private var isRequestingCruiseEntryAuth: Bool = false

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
    /// Held while the popup is visible; cleared on any action selection or cancel.
    ///
    /// Open item #17 (2026-09-11): now drives TWO mutually-exclusive presentations
    /// depending on `AppConstants.communityEnabled` (see `longPressPresentationMode(
    /// communityEnabled:)`):
    ///   - flag OFF: the legacy three-button `showRestingActionMenu` confirmationDialog
    ///     below — unchanged, byte-identical behavior (it remains the ONLY report entry
    ///     point for flag-off users).
    ///   - flag ON: `longPressParkConfirmOverlay`'s slimmed park-confirm card (reporting
    ///     now has its own dedicated entry, the S13a Report pill + grid).
    @State private var pendingLongPressCoord: CLLocationCoordinate2D? = nil

    /// True while the resting long-press confirmationDialog is presented.
    /// The dialog has three actions: "Park my car here", "Report enforcement or
    /// sweeper", and (FT-15/TF2-15) "Report closure (film shoot / construction)."
    ///
    /// Open item #17: only ever set `true` when `AppConstants.communityEnabled == false`
    /// (see `handleLongPress(at:)`) — flag-on long-presses drive `longPressParkConfirmOverlay`
    /// via `pendingLongPressCoord` instead, never this dialog.
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

    // MARK: - A3 curb-pin placement state (flag-gated; SEAM: self-contained block)
    //
    // Stream A3 of docs/longpress-universal-plant-spec.md "Amendment - fixed-center pin with live
    // curb snap". Every value below is nil / false / 0 for the whole lifetime of a flag-off
    // build: only `beginCurbPlacement(...)` ever writes `curbPlacement`, and it is reachable
    // only through `CurbPlacementPolicy.routing(...)` returning `.placement`, which needs
    // `AppConstants.curbPinPlacementEnabled`.

    /// The live placement session (intent, seed, latest snap outcome), or nil = mode off. THE
    /// single source of truth: `curbPlacementActive` is derived from it, the card renders from it,
    /// and `.onChange(of: curbPlacement != nil)` drives the camera seams from it.
    @State private var curbPlacement: CurbPlacementSession? = nil

    /// The snap index the map layer resolves against. Built lazily on entry and rebuilt when
    /// `tileLoader.segments.count` changes, OFF the main actor, guarded by
    /// `curbPlacementIndexGeneration` (a stale build is discarded). Dropped on exit.
    @State private var curbPlacementIndex: CurbSnapIndex? = nil
    @State private var curbPlacementIndexGeneration: Int = 0
    /// True while a build is in flight (so a "no curb" outcome reads "Loading curbs..." instead
    /// of a false empty state when new tiles just arrived - spec A13).
    @State private var curbPlacementIndexBuilding: Bool = false
    /// Bumped each time a freshly built index is installed; `.onChange` of it schedules the
    /// `refreshPlacement()` that must run AFTER the swap has rendered (A2 doc comment).
    @State private var curbPlacementIndexVersion: Int = 0
    /// The placement locate button asked for a fix and none was cached yet; the fix, when it
    /// arrives, moves the pin (single-shot `requestAndFetchLocation()` only - never the drive
    /// posture).
    @State private var curbPlacementLocatePending: Bool = false
    /// The card's last measured height (card top to physical screen bottom). Re-applied to the
    /// map layer's bottom margin right after `beginPlacement` (the card mounts before the
    /// controller exists, so the first measurement would otherwise be dropped).
    @State private var curbPlacementCardHeight: CGFloat = 0

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

    /// Community 2.0 S14: the fetch-at-launch zone list — see `Services/ZoneStore.swift`'s own
    /// header for why `performLaunchSetup()`'s call to `loadZonesIfNeeded()` must run
    /// UNCONDITIONALLY (not gated on `AppConstants.communityEnabled`, unlike
    /// `zoneMessageService.startRealtime()` immediately below it). Constructed in `init` below
    /// (not an inline default) so the SAME instance can be threaded into `pinService`'s
    /// `zoneStore:` parameter — `resolveHomeZoneId`/`updatePushZoneFromParkedCarOrLocation`/
    /// `mapRepresentable`/`CrewFeedSection`/`BlockDetailView` all read this one shared instance
    /// directly, never a copy.
    @State private var zoneStore: ZoneStore

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
    /// `zoneStore` is ALSO constructed explicitly here (Community 2.0 S14) — not because it has
    /// any injected-value dependency of its own, but because `pinService` above needs the SAME
    /// instance passed into its own `zoneStore:` parameter, and a plain inline default on
    /// `zoneStore`'s own declaration would construct a second, independent instance instead.
    ///
    /// All other `@State` properties retain their inline default-expression initializers;
    /// those do not depend on injected values.
    init(
        appDelegate: AppDelegate,
        authService: SupabaseAuthService,
        supabaseClients: SupabaseClients,
        regularsService: RegularsService
    ) {
        self.appDelegate = appDelegate
        self.authService = authService
        self.supabaseClients = supabaseClients
        self.regularsService = regularsService
        // Community 2.0 S14: constructed BEFORE pinService below so the same instance can be
        // threaded into pinService's own zoneStore: parameter — see this property's own doc
        // comment for why one shared instance (not each service defaulting its own) matters.
        let zoneStore = ZoneStore()
        self._zoneStore = State(initialValue: zoneStore)
        // CommunityPinService reads SUPABASE_URL + SUPABASE_ANON_KEY from Bundle.main,
        // attaches the shared authService for authenticated writes, and shares the app's one
        // RealtimeClientV2 via supabaseClients.makeRealtimePinChannel() (supabase-swift
        // Stream B, spec §3.4) instead of standing up a second, standalone socket.
        self._pinService = State(initialValue: CommunityPinService(
            authService: authService,
            realtimeChannel: supabaseClients.makeRealtimePinChannel(),
            zoneStore: zoneStore
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

    /// Addendum 2 (`docs/design/goal-first-ambient-design.md` A2.1) neutralized the
    /// dock-aware branch PR #134 added here: Report pill / "?" now have PERMANENT homes
    /// (the dock's own top row, the rail's last circle — see `communityMapChromeOverlay`'s
    /// new third gate and `GoalSelectorView`'s new `reportPill` slot) instead of floating
    /// alone with a hand-maintained clearance number chasing the dock's height. This
    /// property is back to the single, flag-INDEPENDENT legacy clearance —
    /// `browseSheetPeekHeight + 12` — the one case `communityMapChromeOverlay` still renders
    /// this chrome in at all.
    private var communityMapChromeBottomPaddingValue: CGFloat {
        communityMapChromeBottomPadding(browseSheetPeekHeight: browseSheetPeekHeight)
    }

    private var selectedSegment: Segment? {
        guard let id = selectedSegmentID else { return nil }
        return tileLoader.segments.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        mapLayerWithPlacementEvents
            .onReceive(parkPinService.pinDropped) { newCar in handlePinDropped(newCar) }
            .onReceive(parkPinService.remoteCarChanged) { newCar, oldCarID in
                handleRemoteCarChanged(newCar: newCar, oldCarID: oldCarID)
            }
            .onChange(of: appDelegate.pendingDeepLinkCarID) { _, carID in routePendingDeepLink(carID) }
            // S7 LIVE-GATE FIX (docs/qa/pr115-regulars-s7-livegate.md): moved here from
            // `WeParkApp.swift` — `.onOpenURL` must be attached where the resulting sheet is
            // actually presented (this file's one `.sheet(item: $activeSheet)` host), not on a
            // second, independent `.sheet` modifier wrapping `ContentView` from outside. See
            // `ActiveSheet.regularsInviteRedemption`'s own doc comment for the full root-cause
            // writeup.
            .onOpenURL { url in routeRegularsInviteRedemption(url) }
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
                // DM-2 (`docs/drive-mode-default-spec.md` §0.4, QA pass 1 on PR #130 — the
                // "two more literal `.browseNav` restore sites" finding): routes through the
                // SAME `driveModeDefaultRestStateSheet()` the initial `@State` and
                // `dismissTargetOutsideBrowseNav` already read, instead of hardcoding
                // `.browseNav`. Flag off: identical to before (`.browseNav`). Flag on: `nil`
                // — a swipe-to-dismiss (now legal on `.browseNav` itself, see
                // `browseNavigationSheetContent`'s `.interactiveDismissDisabled` rework) or any
                // other no-explicit-dismiss-closure case lands on the genuinely sheet-free
                // ambient home screen (AC-6), not back into `.browseNav`.
                //
                // A3 (curb-pin placement): also guarded on `curbPlacement == nil`. Entering the
                // mode sets `activeSheet = nil` (dismissing whatever sheet launched it), and that
                // dismissal's `onDismiss` must NOT re-present a rest-state sheet mid-mode (AC-A21).
                // Always true flag-off, so this is byte-identical there.
                if CurbPlacementPolicy.sheetDismissRestoresRestState(
                    browseSheetEnabled: Self.ft20BrowseSheetEnabled,
                    activeSheetIsNil: activeSheet == nil,
                    driveModeActive: driveModeActive,
                    blockSelectModeActive: blockSelectModeActive,
                    spotPlacementActive: spotPlacementActive,
                    placementActive: curbPlacement != nil
                ) {
                    activeSheet = driveModeDefaultRestStateSheet()
                }
            }) { sheet in sheetContent(sheet) }
            .alert("Keep WePark in Front", isPresented: $showDriveModeBackgroundNote) {
                Button("Got It", role: .cancel) {}
            } message: {
                Text("Parking commentary will pause if you background WePark during your drive. Keep the app in front for continuous guidance.")
            }
            // DM-3 (`docs/drive-mode-default-spec.md` §0.2, AC-11b): fired from
            // `enterCruiseMode()` when `locationService.authorizationStatus` is
            // `.denied`/`.restricted` — surfaces the denied-state copy + a real Settings
            // deep link (`openLocationSettingsForCruiseEntry()`), rather than
            // `BrowseSearchAreaView`'s own "Location Required" precedent (OK-only, no deep
            // link) — the spec explicitly asks for a tap-through to Settings here.
            .alert("Location Access Needed", isPresented: $showLocationDeniedAlert) {
                Button("Open Settings") { openLocationSettingsForCruiseEntry() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("WePark needs location access to show parking near you. Enable it in Settings.")
            }
            // DM-2 fast-follow (`docs/qa/pr131-dm3-priming-authfix.md` 🟡 Finding #1): once
            // the system permission prompt resolves, auto-continue straight into
            // `enterCruiseMode()`'s escalation — verbatim shape of `BrowseSearchAreaView
            // .handleGoTap()`'s own `.onChange(of: locationService.isAuthorized)` handler.
            // Gated on `isRequestingCruiseEntryAuth` (only ever set `true` by
            // `enterCruiseMode()`'s `.requestFirst` branch, immediately above) so this NEVER
            // fires for any other reason authorization might change.
            .onChange(of: locationService.isAuthorized) { _, isAuthorized in
                guard isRequestingCruiseEntryAuth else { return }
                isRequestingCruiseEntryAuth = false
                if isAuthorized {
                    enterCruiseMode()
                } else {
                    let status = locationService.authorizationStatus
                    if status == .denied || status == .restricted {
                        showLocationDeniedAlert = true
                    }
                }
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
                    // Open item #17: shared with the flag-on park-confirm card's "Park
                    // here" button — see `confirmLongPressPark(at:)`'s own doc comment.
                    confirmLongPressPark(at: coord)
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
    ///
    /// DM-1 (`docs/drive-mode-default-spec.md` §0.4): when Drive Mode/block-select aren't
    /// forcing a hide, the actual rest-state target now routes through
    /// `driveModeDefaultRestStateSheet(driveModeDefaultEnabled:)` instead of hardcoding
    /// `.browseNav` — `AppConstants.driveModeDefaultEnabled == false` resolves that function
    /// to `.browseNav`, unchanged (spec AC-1); `true` resolves it to `nil`, so dismissing any
    /// sheet lands on the ambient home screen rather than snapping back into `.browseNav`
    /// (spec §0.4: "Both the initial `@State` and this rest-state target must flip together").
    private var dismissTargetOutsideBrowseNav: ActiveSheet? {
        guard Self.ft20BrowseSheetEnabled else { return nil }
        guard !(driveModeActive || blockSelectModeActive) else { return nil }
        return driveModeDefaultRestStateSheet()
    }

    /// True when no sheet is blocking a NEW sheet/mode-entry presentation — i.e.
    /// `activeSheet` is either genuinely empty, or is `.browseNav`, browse mode's
    /// persistent rest state. Guards that used to read `activeSheet == nil` to mean "no
    /// sheet is open" (e.g. `enterCruiseMode()`'s entry guard) need this instead now that
    /// `.browseNav` exists and is non-nil while browse mode is at rest — a bare `== nil`
    /// check would incorrectly treat "the browse sheet is showing its own action list,
    /// which the user just tapped a row in" as "a sheet is blocking this."
    ///
    /// DM-1 note (`docs/drive-mode-default-spec.md` §0.4's "nice simplification" suggestion,
    /// verified rather than assumed): the `.browseNav` special-case here is NOT deleted by
    /// DM-1, under either flag state. `enterCruiseMode()`'s only call site today is
    /// `BrowseNavigationSheet`'s "Find a Spot" button (`onCruiseTapped`) — i.e. the tap that
    /// triggers it happens WHILE `activeSheet == .browseNav` is the presented sheet, flag on
    /// or off, because DM-2 (not this stream) is what moves that trigger out to a standalone
    /// ambient-screen affordance per spec §0.8.7. Dropping the `.browseNav` case here before
    /// DM-2 lands would make this guard — and the identical guard on the "Park here" button,
    /// below — silently no-op on every tap.
    ///
    /// DM-2 RE-EVALUATION (verified, not assumed, per the above note's own instruction): the
    /// demoted "Start Driving" affordance now DOES exist outside `.browseNav` (the ambient
    /// goal dock's own row, `GoalSelectorView.startDrivingRow`, visible only while
    /// `activeSheet == nil`) — but `BrowseNavigationSheet`'s own "Find a Spot" button is
    /// STILL reachable, in BOTH flag states, via the persistent Search icon
    /// (`presentBrowseNavSearch()`) presenting `.browseNav` at `.medium`. A tap on "Find a
    /// Spot" from inside that sheet still fires `enterCruiseMode()` while `activeSheet ==
    /// .browseNav`, so the `.browseNav` case here must stay — simplifying it away (as the
    /// DM-1 note speculated might become possible) would silently break that one remaining
    /// call path. Conclusion: no logic change; this is a verified "must stay," not a
    /// drive-by simplification.
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
                // PR #106 QA Finding #2 fix: reuse the SAME `ASPSuspensionService` instance
                // already held here (`@State private var aspService`, line ~488, built for
                // the W7 top banner) rather than letting the sheet default-construct its own
                // second copy — avoids a redundant `asp-2026.json` bundle parse on every My
                // Car sheet presentation.
                // NB: `ParkedCarDetailView.init` is hand-written (not memberwise), but Swift
                // still requires labeled arguments in the init's DECLARED parameter order —
                // aspService is declared directly after scheduler (which this call site
                // omits, using its own `.shared` default).
                aspService: aspService,
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
                    // Community 2.0 S13c garage-savings stat (§3 Option A): accrue this
                    // completed session's duration BEFORE the pin (and its `parkedAt`) is
                    // gone — `car` here is the closure's captured value, unaffected by
                    // `clearPin()` clearing `parkPinService.parkedCar` below.
                    if AppConstants.communityEnabled {
                        GarageSavingsService().recordSessionEnded(parkedAt: car.parkedAt)
                    }
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
            // S7 (docs/regulars-network-spec.md §3.1): regularsService threaded through for the
            // gated "Regulars" row → RegularsSettingsView. See this property's own doc comment.
            SettingsView(
                notificationsMuted: $notificationsMuted,
                offsets: $reminderOffsets,
                regularsService: regularsService,
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
                    // DM-2 (§0.8.9): this power-user path is reachable only from
                    // full-palette mode, but reset explicitly anyway rather than relying
                    // on that invariant — a stale `true` left over from a PRIOR goal
                    // selection must never silently leak into this custom-time filter's
                    // own `isFree()` call. Today's strict, already-shipped semantics.
                    parkUntilIgnoresMeteredPayment = false
                    parkAndForgetGuardState = nil
                    rebuildOverlays(at: .nowET)
                    // QA pass 1 fix (🟡 #2, `activeGoalForParkUntilPill`'s own doc comment
                    // names this closure's OTHER entry point — `ArrivalPromptSheet.onParkHere`
                    // — as a known third reachable-while-goal-first path): the
                    // `rebuildOverlays(at:)` call directly above can, in that one state
                    // (flag on, goal-first, not full-palette), have just silently overwritten
                    // `parkUntilTarget` BACK to the active goal's own value via the DM-2
                    // recompute block — `targetDate` (what the user just picked) and
                    // `parkUntilTarget` (what's now ACTUALLY showing) can disagree. The map/
                    // pill display is never wrong either way (it always reads the live
                    // `parkUntilTarget`) — but the toast, if it described `targetDate`
                    // unconditionally, would lie about what took effect. Deriving the toast
                    // from the SAME `activeGoalForParkUntilPill`/`goalPillContent` source of
                    // truth the pill itself uses — rather than suppressing the toast outright
                    // — was the smaller, safer fix: zero change to this sheet's reachability
                    // or to any other entry point's behavior, purely a copy correction for the
                    // one state where the generic phrasing would otherwise be false.
                    let message = ContentView.parkUntilConfirmToastMessage(
                        activeGoal: ContentView.activeGoalForParkUntilPill(
                            selectedGoal: selectedGoal,
                            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
                            fullPaletteMode: fullPaletteMode
                        ),
                        pickedTargetDate: targetDate,
                        resolvedTarget: parkUntilTarget ?? targetDate,
                        now: .nowET
                    )
                    ToastService.shared.show(message: message)
                },
                onSkip: {
                    activeSheet = dismissTargetOutsideBrowseNav
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)

        case .mapKeyLegend:
            // Community 2.0 S13a (WP1): the "?" map-key button's legend content — see
            // `Views/MapKeyLegendView.swift`'s own header for the CURB COLORS verbatim-copy
            // rule and the LIVE PINS shipped-marker-treatment rule. No dismiss closure of
            // its own (same shape as `.settings` above) — the `.sheet(item:)` `onDismiss`
            // catch-all restores `.browseNav`.
            MapKeyLegendView()
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

        case .regularsInviteRedemption(let token):
            // S7 LIVE-GATE FIX — see this case's own doc comment on `ActiveSheet` for the
            // root-cause writeup. No dismiss closure of its own (same shape as `.settings`/
            // `.mapKeyLegend` above) — `RegularInviteRedemptionView`'s own `dismiss()` calls
            // resolve to `activeSheet = nil` automatically, and the `.sheet(item:)` `onDismiss`
            // catch-all restores `.browseNav` from there.
            RegularInviteRedemptionView(token: token, service: regularsService)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(20)

        case .moreMenu:
            moreMenuSheetContent

        case .browseNav:
            browseNavigationSheetContent

        }
    }

    // MARK: - Addendum 3 A3.4: More sheet

    /// The More sheet's content + presentation config (`Views/MoreMenuSheet.swift` is pure
    /// presentation; every action lives here). Rows come from `moreMenuVisibleRows(...)`, the
    /// single pure source of truth for which rows show. Each row tap SWAPS `activeSheet` to
    /// its destination (or dismisses to the rest state for the two in-place actions) — it
    /// never stacks a second sheet on top of this one.
    @ViewBuilder
    private var moreMenuSheetContent: some View {
        MoreMenuSheet(
            rows: moreMenuVisibleRows(
                communityEnabled: AppConstants.communityEnabled,
                hasParkedCar: parkPinService.parkedCar != nil,
                fullPaletteMode: fullPaletteMode
            ),
            fullPaletteMode: fullPaletteMode,
            onSelect: { row in handleMoreMenuSelection(row) },
            onToggleFullPalette: {
                // Addendum 3 A3.4: dismiss after flipping so the user sees the result at once.
                activeSheet = dismissTargetOutsideBrowseNav
                toggleFullPaletteMode()
            },
            onDone: { activeSheet = dismissTargetOutsideBrowseNav }
        )
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(20)
    }

    /// Addendum 3 A3.4: the action table for a More-sheet row. Report / map key / Park Until
    /// SWAP `activeSheet` straight to the existing destination (the same assignments the old
    /// Report pill, "?" button, and clock icon made); Find my car dismisses first, then runs
    /// the old rail button's `recenterOnCar()`. The "Show all parking rules" row is a `Toggle`
    /// handled by `onToggleFullPalette` above, so it is a no-op here.
    private func handleMoreMenuSelection(_ row: MoreMenuRow) {
        switch row {
        case .report:
            handleReportPillTap()
        case .mapKey:
            activeSheet = .mapKeyLegend
        case .showAllRules:
            break
        case .findMyCar:
            activeSheet = dismissTargetOutsideBrowseNav
            recenterOnCar()
        case .parkUntil:
            activeSheet = .parkUntil
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
            // Bug B fix (Kevin's Mac gate on PR #110, 2026-09-14): `searchArea`'s builder
            // closure now takes a second callback, `onDestinationSelectedChange` — forwarded
            // straight into `BrowseSearchAreaView`'s own new init param of the same name. See
            // `BrowseNavigationSheet.destinationSelected`'s doc comment for the full
            // root-cause writeup (the "Go" / "Find a Spot" overlap this closes).
            searchArea: { onSearchFieldHeightChange, onDestinationSelectedChange in
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
                    onSettingsTapped: { activeSheet = .settings },
                    onDestinationSelectedChange: onDestinationSelectedChange
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
                        authService: authService,
                        // PR #105 Mac-gate fix: `parkPinService`/`locationService` are passed
                        // as REFERENCES (not a derived `homeZoneId` value) so
                        // `CrewFeedSection` can read them directly in its own body, the same
                        // pattern `pinService`/`zoneMessageService` above already use. A
                        // plain `homeZoneId: communityHomeZoneId` value here only refreshed
                        // when THIS closure's enclosing `BrowseNavigationSheet` happened to
                        // re-render — tapping a zone chip (CrewFeedSection's own local
                        // `@State`) never triggered that, so the away-note never updated to
                        // match the zone the user was actually viewing. See
                        // `CrewFeedSection.swift`'s header comment for the full root cause.
                        parkPinService: parkPinService,
                        locationService: locationService,
                        zoneStore: zoneStore
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
        // Flag off: Apple Maps' sheet is never fully dismissible, only collapsible (spec
        // §4.1) — the rest state is always at least a peek, never "nothing." Byte-identical
        // to pre-DM-2 behavior (AC-8).
        //
        // DM-2 (`docs/drive-mode-default-spec.md` §0.4's last bullet, §2.1 item 4): flag on,
        // `.browseNav` is no longer the permanent rest state (that's the whole point of this
        // spec) — it's a normal, dismissible, on-demand sheet reached via the persistent
        // Search icon (AC-7's "Dismissing it returns to the ambient home screen"). Swipe-to-
        // dismiss now sets `activeSheet = nil` directly via SwiftUI's own binding, caught by
        // the `.sheet(item:, onDismiss:)` backstop above, which (post-DM-2) restores
        // `driveModeDefaultRestStateSheet()` — `nil` while the flag is on, so this correctly
        // lands on the ambient screen rather than snapping back open.
        .interactiveDismissDisabled(!AppConstants.driveModeDefaultEnabled)
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
            zoneMessageService: zoneMessageService,
            // Community 2.0 S14: required by `BlockDetailLogic.resolvedZoneId(forSegmentMidpoint:zones:)`
            // (the "BLOCK CHATTER" compose bar's zone derivation). Declared last to match
            // `BlockDetailView`'s own property declaration order, same convention as
            // `zoneMessageService` immediately above.
            zoneStore: zoneStore,
            // DM-2 (design doc §3.1): "Good through <day>" overrides the normal safety-label
            // TEXT only — never a new color, never a new overlay bucket. `nil` (the default)
            // whenever no goal is active, flag off, full-palette mode, or this segment isn't
            // in the active goal's matching bucket — `BlockDetailView` falls back to its
            // existing `engine.safetyLabel(...)` text in every one of those cases, so this is
            // additive and flag-off byte-identical. Declared very last to match
            // `BlockDetailView`'s own property declaration order (memberwise-init order).
            goalGoodThroughLabel: goalGoodThroughLabel(for: segment),
            // Addendum 3 (A3.4 verify-item): "report this block" is the most natural moment
            // for the action and the backstop that keeps Report discoverable now that the
            // floating pill is gone flag-on. `nil` (no button) flag-off or community-off.
            // Declared last to match `BlockDetailView`'s property declaration order.
            onReportBlock: blockDetailReportAction(for: segment)
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(20)
    }

    /// Addendum 3 (A3.4): the block-detail sheet's "Report a problem on this block" action.
    /// Gated flag-on AND `communityEnabled` (the same community gate Report is shown under
    /// everywhere else) — `nil` otherwise, so flag-off block detail is byte-identical.
    private func blockDetailReportAction(for segment: Segment) -> (() -> Void)? {
        guard AppConstants.driveModeDefaultEnabled, AppConstants.communityEnabled else { return nil }
        return { reportBlock(segment) }
    }

    /// Swaps the block-detail sheet for `ReportSheet`, pre-seeded with THIS block (its
    /// midpoint, as the segment and the confirm-the-street candidates), mirroring
    /// `handleReportPillTap()`'s `.reportPin` payload but with the tapped block instead of a
    /// GPS-nearest guess. Clears the selection first, same as `initiatePathBPinDrop(from:)`,
    /// so the block-highlight does not linger once the sheet is swapped.
    private func reportBlock(_ segment: Segment) {
        guard let coord = segment.midpoint ?? segment.coordinates.first else { return }
        let confirmCandidates = CandidateSegmentSearch.confirmStreetCandidates(
            for: segment,
            in: tileLoader.segments
        )
        selectedSegmentID = nil
        activeSheet = .reportPin(
            coord: coord,
            streetName: nil,
            segment: segment,
            confirmCandidates: confirmCandidates,
            coordinateSource: "block detail"
        )
    }

    /// DM-2 (design doc §3.1, "Good through <day>" per-segment ranking label — §0.8.3a). Not
    /// listed in `docs/drive-mode-default-spec.md` §3.3's original file table (which predates
    /// the design doc's own explicit placement instruction) — flagged in this PR's
    /// description as a one-property, additive addition to `BlockDetailView.swift`, required
    /// to implement the design doc faithfully rather than silently skip the label it specs.
    ///
    /// Non-nil only when ALL of: the flag is on, the user hasn't toggled to full-palette, and
    /// `segment` is in `selectedGoal`'s matching (green) bucket right now. Composes
    /// `ParkingGoals.match`/`goodThroughLabel` directly — no new engine surface, a pure label
    /// lookup over the already-shipped DM-2e functions.
    ///
    /// Defensive floor (design doc §3.1: "Never render 'Good through today'"): if the
    /// ladder/checkpoint ever resolves to a same-day result (shouldn't happen given every
    /// goal's 2-day-or-wider floor, but defensively), this falls back to "Good through
    /// tomorrow" rather than a same-day-sounding label that reads like it's already expired.
    private func goalGoodThroughLabel(for segment: Segment) -> String? {
        guard AppConstants.driveModeDefaultEnabled, !fullPaletteMode else { return nil }
        let now: Date = .nowET
        let result = ParkingGoals.match(segment: segment, goal: selectedGoal, from: now, engine: engine)
        guard result.matches else { return nil }
        guard let label = ParkingGoals.goodThroughLabel(
            for: segment, goal: selectedGoal, from: now, engine: engine
        ) else {
            return nil
        }
        return label == "Good through Today" ? "Good through tomorrow" : label
    }

    // MARK: - DM-2 Addendum 2 (A2.2): escalated-Cruise goal-identity pill content

    /// The `GoalParkUntilPill` content — icon, short name, trailing clause — for a goal's
    /// already-resolved GLOBAL `target` (`parkUntilTarget`, set by `rebuildOverlays`'s DM-2
    /// recompute block every rebuild). This is NOT `goalGoodThroughLabel(for:)` above — that
    /// function ranks one SPECIFIC `Segment` for the block-detail sheet; this one summarizes
    /// the filter's global state for the escalated-Cruise pill, so it takes a target date, not
    /// a segment. `nonisolated static` + Foundation-only inputs (no `self`, no engine) so it's
    /// directly unit-testable and so `GoalParkUntilPill` itself can stay pure presentation
    /// (`Views/GoalSelectorView.swift`'s own "never touches ParkingGoals/ParkingRulesEngine
    /// directly" convention) — this is the one place in the DM-2 Addendum-2 stream that calls
    /// `ParkingGoals.relativeDayLabel`/`ParkUntilSheet.formatTime` to build that content.
    ///
    /// Per-goal trailing clause (Addendum 2, A2.2's table):
    ///   - `.freeOvernight` / `.parkAndForget`: "Good through <day>" via
    ///     `ParkingGoals.relativeDayLabel(for:from:)` — the SAME §3.1 three-tier formatter
    ///     `goalGoodThroughLabel(for:)` above uses, never a re-implementation. Defensive floor:
    ///     never renders "Good through Today" (falls back to "Good through tomorrow"), mirroring
    ///     `goalGoodThroughLabel(for:)`'s own guard.
    ///   - `.freeFewHours`: "until <time>" via `ParkUntilSheet.formatTime(_:)` UNCHANGED — that
    ///     sheet's own existing clock-time formatter, not a fourth date formatter.
    nonisolated static func goalPillContent(
        for goal: ParkingGoal,
        target: Date,
        now: Date
    ) -> (icon: String, shortName: String, trailingClause: String) {
        let icon: String
        let shortName: String
        switch goal {
        case .freeOvernight:  icon = "moon.stars.fill";          shortName = "Overnight"
        case .freeFewHours:   icon = "hourglass";                shortName = "A Few Hours"
        case .parkAndForget:  icon = "parkingsign.circle.fill";  shortName = "Park & Forget"
        }

        let trailingClause: String
        switch goal {
        case .freeOvernight, .parkAndForget:
            let label = "Good through \(ParkingGoals.relativeDayLabel(for: target, from: now))"
            trailingClause = label == "Good through Today" ? "Good through tomorrow" : label
        case .freeFewHours:
            trailingClause = "until \(ParkUntilSheet.formatTime(target))"
        }
        return (icon, shortName, trailingClause)
    }

    /// Whether the CURRENT `ParkUntilPill` slot content should be the named `GoalParkUntilPill`
    /// (non-nil result) or today's generic `ParkUntilPill` (nil) — Addendum 2, A2.2. Extracted
    /// as a `nonisolated static` pure function (rather than left as the inline ternary at the
    /// `bottomSafeAreaContent` call site) so this decision is directly unit-testable, same
    /// "extract the decision" convention `goalSelectorDockVisible`/`goalTileRowVisible`/
    /// `parkUntilClockButtonVisible` already use in this file.
    ///
    /// **Provably correct with ZERO new stored state** (the addendum's own framing, not a
    /// silent simplification of this PR's own dispatch, which separately suggested adding a
    /// small piece of tracking state — flagged explicitly in this PR's description):
    /// whenever `driveModeDefaultEnabled && !fullPaletteMode`, `rebuildOverlays`'s DM-2
    /// recompute block runs on EVERY SINGLE call (Part A fix 4 made it unconditional, above
    /// the zoom guard) and unconditionally overwrites `parkUntilTarget` FROM `selectedGoal` —
    /// so in exactly the states where this function returns non-nil, `selectedGoal` is
    /// guaranteed fresh, and `parkUntilTarget`'s VALUE can never actually diverge from the
    /// goal's own computed target by the time anything reads it.
    ///
    /// **Known third entry point (QA pass 1, 🟡 #2) — `ArrivalPromptSheet`'s `onParkHere`
    /// closure.** The power-user `ParkUntilSheet` clock icon is unreachable in that same state
    /// via `parkUntilClockButtonVisible` — but `onParkHere` (the destination-mode Drive
    /// "Park Here" arrival flow, W8.5d Option B, pre-existing and untouched by this PR) ALSO
    /// sets `activeSheet = .parkUntil` directly, with no flag/`fullPaletteMode` gate at all,
    /// auto-firing the exact same `ParkUntilSheet`. This is reachable while flag-on AND
    /// goal-first (the user drives via Search → a destination, not "Start Driving," which
    /// stays a `.cruise`-only, goal-first-locked path). So `ParkUntilSheet`'s `onConfirm` CAN
    /// run while this function would return non-nil. It does NOT break this function's
    /// correctness, because `onConfirm` calls `rebuildOverlays(at:)` in the same synchronous
    /// closure right after setting `parkUntilTarget` — the DM-2 recompute block described
    /// above immediately overwrites whatever `onConfirm` just set, back to the active goal's
    /// own value, before anything else reads it. The `ParkUntilPill` slot's DISPLAYED state is
    /// therefore never wrong. What WAS wrong (fixed by this same QA pass, see `onConfirm`'s own
    /// comment below): the toast `onConfirm` fires describes the just-picked custom time, not
    /// the goal value that's actually now showing — a cosmetic lie, not a state bug.
    nonisolated static func activeGoalForParkUntilPill(
        selectedGoal: ParkingGoal,
        driveModeDefaultEnabled: Bool,
        fullPaletteMode: Bool
    ) -> ParkingGoal? {
        (driveModeDefaultEnabled && !fullPaletteMode) ? selectedGoal : nil
    }

    /// QA pass 1 fix (🟡 #2): the toast message for `ParkUntilSheet`'s `onConfirm` closure —
    /// extracted so the "derive from the same `activeGoalForParkUntilPill` source of truth the
    /// pill uses" fix is directly unit-testable without a live `ContentView`/sheet.
    ///
    /// `activeGoal` is `ContentView.activeGoalForParkUntilPill(...)`'s result at the SAME
    /// moment the toast fires — non-nil exactly in the one state
    /// (`activeGoalForParkUntilPill`'s own doc comment) where `onConfirm`'s preceding
    /// `rebuildOverlays(at:)` call can have silently overwritten `parkUntilTarget` back to the
    /// goal's own value, making `pickedTargetDate` (what the user just chose) and
    /// `resolvedTarget` (what's now actually live) disagree. When `activeGoal == nil`
    /// (flag off, or full-palette mode — the normal, intended use of this sheet), this returns
    /// EXACTLY today's pre-QA-pass-1 toast text, byte-identical, since `pickedTargetDate` and
    /// `resolvedTarget` can never diverge in that state.
    nonisolated static func parkUntilConfirmToastMessage(
        activeGoal: ParkingGoal?,
        pickedTargetDate: Date,
        resolvedTarget: Date,
        now: Date
    ) -> String {
        guard let activeGoal else {
            return "Showing blocks free until \(ParkUntilSheet.formatTime(pickedTargetDate))"
        }
        let content = goalPillContent(for: activeGoal, target: resolvedTarget, now: now)
        return "Showing \(content.shortName) blocks — \(content.trailingClause)"
    }

    /// QA pass 1 fix (🟡 #1): whether `handleRegionChanged`'s new `rebuildOverlays(at:)` call
    /// (Part A fix 3) should fire for a given region-change event. Extracted as a
    /// `nonisolated static` pure function — same "extract the decision" convention this file's
    /// other gates use — purely so the gate itself is directly unit-tested, not left as an
    /// inline `if` with no regression guard.
    ///
    /// `false` during Drive Mode: `handleRegionChanged` also fires continuously off Drive
    /// Mode's own ~1Hz camera-follow loop (`handleLocationUpdate()`'s per-GPS-tick
    /// `setDriveCamera` → `MKMapView.setCamera` → `regionDidChangeAnimated` →
    /// `handleRegionChanged`), a completely different cadence than the "settled gesture in
    /// browse mode" case Part A fix 3 actually targets. Gating here restores Drive Mode's PRIOR
    /// repaint economics exactly (its own existing triggers — entry rebuild, `tileLoader
    /// .segments.count` changes as new tiles stream in — are untouched) while leaving the fix
    /// for the real bug (browse-mode stale repaint after a pinch past the hide threshold) fully
    /// intact in every other state, flag on or off.
    nonisolated static func shouldRebuildOverlaysOnRegionChange(driveModeActive: Bool) -> Bool {
        !driveModeActive
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
        // DM-2 (`docs/drive-mode-default-spec.md` §0.8.6/§0.8.9): when the goal-first
        // ambient dock owns the filter (flag on, not toggled to full-palette), (re)resolve
        // the active goal's target FRESH on every single rebuild — Free Overnight/Few
        // Hours' one checkpoint drifts as `now` advances across the 60s timer tick; Park &
        // Forget's viewport-dependent ladder rung can drift as the loaded segment set
        // changes (new tiles, pan/zoom). This keeps `parkUntilTarget`/
        // `parkUntilIgnoresMeteredPayment` in lockstep with whichever goal is selected
        // WITHOUT changing the binary `isFree()` classification loop below AT ALL — §0.8.6's
        // byte-identical-reuse promise. Skipped entirely while `fullPaletteMode` is true or
        // the flag is off: in both of those states, `parkUntilTarget`/`parkUntilMode` are
        // whatever the power-user `ParkUntilSheet` (§0.8.9) or `clearParkUntilFilter()` last
        // set, and this block must not touch them.
        //
        // §0.8.9's per-segment-vs-global nuance, resolved here: Park & Forget's MATCHING
        // bucket uses ONE global `parkUntilTarget` (the highest rung the viewport
        // collectively clears, from `resolveParkAndForgetViewport` below) applied uniformly
        // to every segment via the SAME single-target `isFree()` loop every other goal
        // uses — never a per-segment ladder inside the overlay itself. The per-segment
        // ladder walk (`ParkingGoals.match`/`goodThroughLabel`) only ever powers the
        // "Good through <day>" ranking LABEL in the block-detail sheet, a label concern
        // layered on top of this already-decided green bucket, never a second overlay color.
        //
        // **Part A fix 4** (`docs/design/goal-first-ambient-design.md` Addendum 2's
        // predecessor diagnosis): this block used to sit AFTER the zoom-threshold guard
        // below, which meant `parkUntilMode`/`parkUntilTarget`/`parkAndForgetGuardState`
        // never even got evaluated while the camera span was zoomed out past
        // `polylineHideSpanThreshold` — a flag-on cold launch with the (pre-fix-2) wide
        // default span landed `parkUntilMode == false` at rest, so the goal-first dock's own
        // "which goal is active" state (and the §0.8.10 empty-map-guard banner, which reads
        // `parkAndForgetGuardState`) were simply never true at launch, no matter which goal
        // was pre-selected. Moving this block ABOVE the guard means it runs on every single
        // `rebuildOverlays` call regardless of zoom — the guard below now controls ONLY the
        // rendered polyline PAYLOAD, never the goal/filter state itself. Flag off: this block
        // is a no-op in both positions (guarded on `AppConstants.driveModeDefaultEnabled`), so
        // this reordering is byte-identical for flag-off builds.
        if AppConstants.driveModeDefaultEnabled, !fullPaletteMode {
            parkUntilIgnoresMeteredPayment = ParkingGoals.ignoresMeteredPayment(for: selectedGoal)
            switch selectedGoal {
            case .freeOvernight, .freeFewHours:
                parkUntilTarget = ParkingGoals.target(for: selectedGoal, from: now)
                parkAndForgetGuardState = nil
            case .parkAndForget:
                let resolution = resolveParkAndForgetViewport(
                    segments: tileLoader.segments,
                    from: now,
                    engine: engine
                )
                parkAndForgetGuardState = resolution
                switch resolution {
                case .resolved(let offsetDays, _):
                    parkUntilTarget = now.startOfDayET(offsetDays: offsetDays)
                case .empty:
                    // §0.8.10 true-empty: still render the bottom (easiest) rung's target so
                    // the map shows an honest all-red result for every segment — the explicit
                    // empty-map-guard banner (not a silent all-red map) is what keeps this
                    // from reading as broken, not a fabricated green anywhere.
                    parkUntilTarget = now.startOfDayET(
                        offsetDays: ParkingGoals.parkAndForgetLadderOffsetDays.last ?? 2
                    )
                }
            }
            parkUntilMode = true
        }

        // Zoom-threshold gating: if zoomed out, clear all overlays. Runs AFTER the DM-2
        // goal-recompute block above (Part A fix 4) — this guard controls only the rendered
        // polyline payload now, never `parkUntilMode`/`parkUntilTarget`/
        // `parkAndForgetGuardState`, which must stay truthful even while the map is zoomed
        // out too far to draw any polylines at all.
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
                if engine.isFree(
                    segment: segment, from: now, until: target,
                    ignoringMeteredPayment: parkUntilIgnoresMeteredPayment
                ) {
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
                    selectedState = engine.isFree(
                        segment: seg, from: now, until: target,
                        ignoringMeteredPayment: parkUntilIgnoresMeteredPayment
                    ) ? .freeComfortably : .restrictedNow
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
                    blockSelectModeActive: blockSelectModeActive,
                    curbPlacementActive: curbPlacement != nil
                ) {
                    recenterButtonStack
                        .padding(.top, 100)
                        // Addendum 3 A3.2: flag-on rail uses a 16pt trailing margin; flag off
                        // keeps the pre-DM-2 12pt.
                        .padding(.trailing, AppConstants.driveModeDefaultEnabled ? 16 : 12)
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
            // Open item #17 (2026-09-11): flag-on resting long-press park confirmation.
            // Same floating-overlay pattern as the cards just above — see
            // `longPressParkConfirmOverlay`'s own doc comment.
            longPressParkConfirmOverlay
            // Community 2.0 S13a (WP1): the persistent Report pill + "?" map-key button.
            // See `communityMapChromeOverlay`'s own doc comment.
            communityMapChromeOverlay
            // DM-3 (`docs/drive-mode-default-spec.md` §0.2): the one-shot first-launch
            // location-priming card — same floating-overlay pattern as the cards above, not
            // a new positioning mechanism. See `locationPrimingCardOverlay`'s own doc
            // comment for its gating.
            locationPrimingCardOverlay
            // A3 (curb-pin placement): the placement card + Cancel + locate + first-use hint.
            // Renders nothing unless a session is live (never, flag-off).
            curbPlacementOverlay
        }
    }

    /// The blue "Tap the curb where the spot is / Cancel" pill — visible while placement
    /// mode is active and no draft has been placed yet. Positioned to clear both the status
    /// bar and the ASP banner, matching `recenterButtonStack`'s own `.padding(.top, 100)`
    /// convention for "float below the ASP banner" (`design/screenshots/10-spot-placement.png`).
    ///
    /// PR #110 Bug A hardening (Kevin's Mac gate, 2026-09-14): added `&& !driveModeActive`.
    /// `spotPlacementActive` is normally only reachable from `ReportSheet`'s "Spot open"
    /// tile, and the in-drive Report button (`driveActionRow`) DOES open `ReportSheet` while
    /// driving — so `enterSpotPlacementMode()` firing mid-drive was a real, if narrow, path
    /// that this gate never excluded (unlike `communityMapChromeOverlay`/
    /// `parkingGuideBannerOverlay`, which already both exclude `driveModeActive`). This is a
    /// conditional-rendering exclusion (removes the node from the tree), matching this same
    /// file's own "hidden ≠ gone" convention elsewhere, not an opacity/`.hidden()` one — see
    /// `communityMapChromeVisible`'s doc comment for why that distinction matters. Not
    /// confirmed as Kevin's exact PR #110 repro (a plain destination search → Go never
    /// touches spot-placement state), but the same latent-gap CLASS his report named.
    @ViewBuilder
    private var spotPlacementHintOverlay: some View {
        if spotPlacementActive && spotPlacementDraft == nil && !driveModeActive {
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
    ///
    /// PR #110 Bug A hardening — see `spotPlacementHintOverlay`'s own doc comment for the
    /// full reasoning (same `spotPlacementActive` source, same `!driveModeActive` addition).
    @ViewBuilder
    private var spotPlacementConfirmOverlay: some View {
        if spotPlacementActive, let draft = spotPlacementDraft, !driveModeActive {
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
    /// PR #110 Bug A hardening (Kevin's Mac gate, 2026-09-14): added `&& !driveModeActive`.
    /// `confirmPromptPin` is set by the push/local-notification-driven "did it pass?" flow
    /// (WP5 rider) — genuinely reachable at ANY time, including mid-drive, and this gate
    /// never excluded that case before (unlike `communityMapChromeOverlay`/
    /// `parkingGuideBannerOverlay`, which already both exclude `driveModeActive`). Same
    /// conditional-rendering (not opacity) fix shape as `spotPlacementHintOverlay`'s own
    /// doc comment describes.
    @ViewBuilder
    private var confirmPromptOverlay: some View {
        if AppConstants.communityEnabled, let pin = confirmPromptPin, !driveModeActive {
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

    /// Open item #17 (2026-09-11): the slimmed, flag-on resting long-press park-confirm
    /// card (`Views/LongPressParkConfirmCard.swift`) — replaces the legacy three-button
    /// confirmationDialog for `communityEnabled == true` (reporting has its own dedicated
    /// entry now, the S13a Report pill + grid; see `longPressPresentationMode(
    /// communityEnabled:)`). Flag-off is entirely unaffected — this property renders nothing
    /// and `showRestingActionMenu`'s confirmationDialog (in `body`) is the only popup that
    /// can ever appear.
    ///
    /// Driven directly off `pendingLongPressCoord` (no separate presentation flag) — same
    /// "one piece of state, not a redundant bool" shape `spotPlacementDraft`/`confirmPromptPin`
    /// already use for their own overlays above. Same "VStack + Spacer(), floats above the
    /// `.browseNav` sheet" positioning convention as `spotPlacementConfirmOverlay`/
    /// `confirmPromptOverlay` — not a new mechanism.
    /// PR #110 Bug A hardening (Kevin's Mac gate, 2026-09-14): added `&& !driveModeActive`,
    /// belt-and-braces — `handleLongPress(at:)` already guards `!driveModeActive` before
    /// ever setting `pendingLongPressCoord`, so this exclusion cannot currently change
    /// observed behavior, but every OTHER floating overlay in this file that predates a
    /// `driveModeActive` check states its own exclusion explicitly at the gate rather than
    /// relying solely on an upstream setter's guard (see `communityMapChromeOverlay`'s own
    /// "already force-hide... belt-and-suspenders" precedent) — consistent with that
    /// convention, and one fewer place a future change to `handleLongPress` could silently
    /// reopen this exact overlay-during-drive class of bug.
    @ViewBuilder
    private var longPressParkConfirmOverlay: some View {
        if AppConstants.communityEnabled, let coord = pendingLongPressCoord, !driveModeActive {
            VStack(spacing: 0) {
                Spacer()
                LongPressParkConfirmCard(
                    onConfirm: {
                        pendingLongPressCoord = nil
                        confirmLongPressPark(at: coord)
                    },
                    onCancel: {
                        pendingLongPressCoord = nil
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, browseSheetPeekHeight + 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Community 2.0 S13a (WP1): pure decision for whether `communityMapChromeOverlay` (the
    /// persistent Report pill + "?" map-key button) should render — extracted as a
    /// `nonisolated static` function so both the flag state and every mode-exclusion gate
    /// are directly unit-testable without a live `ContentView` instance, same pattern as
    /// `mapMarkerTypes(communityEnabled:)`/`recenterButtonStackVisible`.
    ///
    /// Open item #17 follow-up (2026-09-11, Kevin's live smoke of `b500c95a`): added
    /// `longPressParkConfirmActive` — the pill/"?" button were drawing over the corners of
    /// `longPressParkConfirmCard` ("Park here" partially covered by the Report pill, Cancel
    /// by the "?" button). Same exclusion shape as `spotPlacementActive`: a focused task's
    /// own floating chrome (the park-confirm card) shouldn't compete with this persistent
    /// row, and it hides/returns exactly when the card does, since both read off the same
    /// `pendingLongPressCoord != nil` condition at the call site below.
    ///
    /// A3 (curb-pin placement): trailing `curbPlacementActive` (default `false` = byte-identical
    /// to before) hides the pill and "?" for the duration of the mode.
    nonisolated static func communityMapChromeVisible(
        communityEnabled: Bool,
        driveModeActive: Bool,
        blockSelectModeActive: Bool,
        spotPlacementActive: Bool,
        longPressParkConfirmActive: Bool,
        curbPlacementActive: Bool = false
    ) -> Bool {
        communityEnabled && !driveModeActive && !blockSelectModeActive && !spotPlacementActive
            && !longPressParkConfirmActive && !curbPlacementActive
    }

    /// Addendum 3 (A3.4): whether the FLOATING Report pill + "?" layer
    /// (`communityMapChromeOverlay`) renders. Flag off: exactly `chromeVisible` (the unchanged
    /// `communityMapChromeVisible` result). Flag on: never — both controls live in the More
    /// sheet instead. A `nonisolated static` pure function, same pattern as
    /// `communityMapChromeVisible`, so both halves of that claim are directly unit-testable.
    nonisolated static func communityMapFloatingChromeVisible(
        chromeVisible: Bool,
        driveModeDefaultEnabled: Bool
    ) -> Bool {
        chromeVisible && !driveModeDefaultEnabled
    }

    /// Community 2.0 S13a (WP1, build 20): the persistent Report pill (bottom-left) + "?"
    /// map-key button (bottom-right) — `design/screenshots/01-home-collapsed.png`,
    /// `design/prototype.html:76-83`, gap-inventory work package WP1.
    ///
    /// Flag-gated behind `AppConstants.communityEnabled` (spec's own "flag-off = zero new
    /// chrome, byte-identical map" requirement) — with the flag off this property renders
    /// nothing, same posture as every other Community 2.0 UI surface in this file
    /// (`confirmPromptOverlay`, `spotPlacementHintOverlay`, etc.).
    ///
    /// Also hidden during Drive Mode (which has its OWN Report button, `driveActionRow`,
    /// gated `driveModeActive`), block-select mode, and spot-placement mode — all three
    /// already force-hide `activeSheet` and own their own floating chrome for their
    /// duration; layering a second, competing Report/legend affordance over a focused task
    /// would clutter it, the same reasoning `parkingGuideBannerOverlay`'s gate documents.
    ///
    /// Positioned as its own floating row — same "VStack + Spacer(), padded to clear
    /// whatever's below it" convention `spotPlacementConfirmOverlay`/`confirmPromptOverlay`/
    /// `parkingGuideBannerOverlay` above already use — rather than a `bottomSafeAreaContent`
    /// row: this is BROWSE mode's persistent chrome, not a Drive-Mode Bottom-Dock row, and
    /// (like those three floating cards) must float ABOVE the modally-presented `.browseNav`
    /// sheet, which a `.safeAreaInset` row cannot do (see `parkingGuideBannerOverlay`'s own
    /// doc comment for why `.safeAreaInset` content renders BEHIND the sheet).
    ///
    /// Addendum 2 (A2.1): PR #134's DM-2 ambient-dock fix (a dock-aware clearance chasing the
    /// goal dock's height from a sibling presentation layer) is superseded here, not just
    /// patched again. Root cause of the ORIGINAL overlap bug stands as documented — the
    /// goal-first dock lives in a different presentation layer
    /// (`mapRepresentable`'s own `.safeAreaInset`) that this floating overlay has no
    /// structural visibility into — but the fix is now to give Report pill and "?" PERMANENT
    /// homes instead of computing a clearance number for them at all: Report moves into
    /// `GoalSelectorView`'s own top row (rides the dock's real height for free), "?" moves
    /// into `recenterButtonStack`'s rail (a completely different floating layer with no
    /// height-tracking problem). Both moves are flag-gated — see the third condition below.
    ///
    /// Addendum 3 (A3.4) supersedes those two homes: Report and "?" both now live in the More
    /// sheet (`MoreMenuSheet`) flag-on, so this floating layer is suppressed outright flag-on
    /// (`communityMapFloatingChromeVisible`) and renders exactly as before flag-off.
    @ViewBuilder
    private var communityMapChromeOverlay: some View {
        // Addendum 3 (A3.4, flag-on only): suppress BOTH pieces entirely whenever
        // `driveModeDefaultEnabled` — Report and "?" now live in the More sheet
        // (`MoreMenuSheet`, rows 1 and 2), so this floating layer must not render them over
        // the goal dock OR over any sheet (Addendum 2's dock-visibility gate let them
        // reappear whenever a sheet was up, because `goalSelectorDockVisible` goes false
        // then). The decision is the pure `communityMapFloatingChromeVisible` below. Flag off:
        // reduces to exactly `communityMapChromeVisible(...)` unchanged — byte-identical to
        // pre-Addendum-2 flag-off behavior.
        if Self.communityMapFloatingChromeVisible(
            chromeVisible: Self.communityMapChromeVisible(
                communityEnabled: AppConstants.communityEnabled,
                driveModeActive: driveModeActive,
                blockSelectModeActive: blockSelectModeActive,
                spotPlacementActive: spotPlacementActive,
                longPressParkConfirmActive: pendingLongPressCoord != nil,
                curbPlacementActive: curbPlacement != nil
            ),
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled
        ) {
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    reportPillButton
                    Spacer()
                    mapKeyButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, communityMapChromeBottomPaddingValue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// DM-3 (`docs/drive-mode-default-spec.md` §0.2): the one-shot, dismissible first-launch
    /// `LocationPrimingCard` — NOT a blocking alert, floats above the map so it's always
    /// dismissible and never competes with a system permission dialog for modality.
    ///
    /// Gated on `driveModeDefaultEnabled` (this card is part of the ambient/goal-first
    /// experience — it has no reason to render while the FT-20 browse sheet is still the
    /// default, AC-2's "no priming card render anywhere" while the flag is off) AND
    /// `showLocationPrimingCard` (set once at launch by `locationPrimingCardShouldShow(...)`,
    /// cleared by `dismissLocationPrimingCard(allowed:)`). Also excluded during Drive Mode,
    /// block-select, and spot-placement — same "don't layer a first-launch card over a
    /// focused task" reasoning `communityMapChromeOverlay`'s own gate documents above.
    ///
    /// Positioned below the status bar/ASP banner — same `.padding(.top, 100)` convention
    /// `spotPlacementHintOverlay` already uses to clear that same chrome, rather than
    /// inventing a new offset.
    @ViewBuilder
    private var locationPrimingCardOverlay: some View {
        if AppConstants.driveModeDefaultEnabled && showLocationPrimingCard
            && !driveModeActive && !blockSelectModeActive && !spotPlacementActive
            && curbPlacement == nil {
            VStack(spacing: 0) {
                LocationPrimingCard(
                    onAllow: { dismissLocationPrimingCard(allowed: true) },
                    onNotNow: { dismissLocationPrimingCard(allowed: false) }
                )
                .padding(.top, 100)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The persistent Report pill (`design/prototype.html:76-79`: flag icon + "Report",
    /// orange text) — ported to this codebase's own chrome idiom (`.regularMaterial`
    /// capsule, matching `driveActionRow`'s existing Report button treatment) rather than
    /// the prototype's raw `rgba(33,36,44,0.96)` pill fill (gap inventory WP1: "following
    /// the codebase's own chrome idioms... not raw rgba").
    ///
    /// Tap → `handleReportPillTap()`. LONG-PRESS BEHAVIOR IS UNCHANGED — this pill is
    /// additive, a second discoverable entry point alongside the existing resting
    /// long-press `.confirmationDialog`'s "Report enforcement or sweeper" action, not a
    /// replacement for it (gap-inventory Judgment Call #3: a driver who doesn't already
    /// know the long-press gesture exists has no other way to discover reporting at all).
    private var reportPillButton: some View {
        Button {
            handleReportPillTap()
        } label: {
            Label("Report", systemImage: "flag.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(Color.orange)
        }
        .accessibilityLabel("Report enforcement, sweeper, or an open spot")
        .accessibilityHint("Opens the report form at your current location.")
    }

    /// The "?" map-key button (`design/prototype.html:81-83`) — presents
    /// `MapKeyLegendView` via `ActiveSheet.mapKeyLegend`. Sized/styled to match
    /// `recenterButtonStack`'s existing 44×44pt `.regularMaterial` circle family, not the
    /// prototype's 40×40pt raw-rgba circle (same "codebase idiom, not pixel port" bias as
    /// `reportPillButton` above).
    private var mapKeyButton: some View {
        Button {
            activeSheet = .mapKeyLegend
        } label: {
            Text("?")
                .font(.system(size: 17, weight: .bold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Map key")
        .accessibilityHint("Shows what the map colors and pins mean.")
    }

    /// Community 2.0 S13a (WP1): the Report pill's tap handler.
    ///
    /// Coordinate source, in priority order — documented per this file's existing
    /// `coordinateSource` diagnostic convention (`ActiveSheet.reportPin`'s own doc comment,
    /// QA STOP-AND-INSTRUMENT PR #95):
    ///   1. Current GPS (`locationService.userLocation`) — reuses the EXACT same "current
    ///      GPS" semantics `driveActionRow`'s in-drive Report button already established
    ///      (`coordinateSource: "current GPS (in-drive)"`), just from browse mode instead
    ///      of Drive Mode.
    ///   2. Map center (`region.center`) — fallback when no GPS fix exists yet, using the
    ///      resting long-press dialog's own "best-effort coordinate, off-segment reports
    ///      degrade gracefully" semantics (OD-1) — `ReportSheet` already handles a
    ///      candidate search that comes up empty.
    private func handleReportPillTap() {
        // A3 (curb-pin placement), spec A.7 + A-2: flag-on, the pill lands in placement first
        // (seed = GPS, else the map centre - the chain below) and reaches the chooser via
        // "Next". Flag-off (or a blocked entry) `curbPlacementRouting` is `.legacy` and the
        // original body runs untouched.
        if startCurbPlacementIfRouted(
            entry: .reportPill,
            seed: locationService.userLocation ?? region.center
        ) { return }
        let hasGPSFix = locationService.userLocation != nil
        let coord = locationService.userLocation ?? region.center
        let reportSegment = findCandidateSegments(
            lat: coord.latitude,
            lng: coord.longitude,
            radius: pinDropRadiusMeters,
            max: 1
        ).first?.segment
        let confirmCandidates = reportSegment.map {
            CandidateSegmentSearch.confirmStreetCandidates(for: $0, in: tileLoader.segments)
        } ?? []
        activeSheet = .reportPin(
            coord: coord,
            streetName: nil,
            segment: reportSegment,
            confirmCandidates: confirmCandidates,
            coordinateSource: hasGPSFix ? "current GPS (map chrome)" : "map center (map chrome, no GPS fix)"
        )
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
        if showParkingGuideBanner && !driveModeActive && !parkUntilMode && !blockSelectModeActive
            && curbPlacement == nil {
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

    /// A3: `mapLayerWithEvents` + the placement mode's three observers (third group, kept apart
    /// from the two above for the same type-checker-budget reason they were split). All three
    /// values are constant (`false` / `0`) for the whole life of a flag-off build, so these
    /// modifiers never fire there.
    @ViewBuilder
    private var mapLayerWithPlacementEvents: some View {
        mapLayerWithEvents
            .onChange(of: curbPlacement != nil) { _, active in handleCurbPlacementActiveChange(active) }
            .onChange(of: curbPlacementIndexVersion) { _, _ in scheduleCurbPlacementRefresh() }
            .onChange(of: curbPlacementHasConflictingSheet) { _, conflicting in
                if conflicting { endCurbPlacementForConflictingSheet() }
            }
    }

    // MARK: - Map representable callbacks (extracted for type-checker budget)

    /// Forwards region changes to TileLoader and CommunityPinService.
    ///
    /// **Part A fix 3** (`docs/design/goal-first-ambient-design.md` Addendum 2's predecessor
    /// diagnosis, flag-INDEPENDENT): previously this handler never called `rebuildOverlays`
    /// directly — a region change only repainted the overlays as a SIDE EFFECT of
    /// `tileLoader.loadTiles(forRegion:)` changing `tileLoader.segments.count`, which drives
    /// `handleSegmentsChanged()` via `.onChange(of: tileLoader.segments.count)`. A pinch-out
    /// past `polylineHideSpanThreshold` and back to the exact same street-level span (no net
    /// segment-count change, e.g. re-entering a fully-loaded area) left the overlay payload
    /// stale — either the empty "hidden" payload from the zoomed-out moment, or a payload
    /// computed against the PRIOR `region.span`, neither of which `handleSegmentsChanged`
    /// would ever correct since segment count never changed. Adding the explicit call here
    /// closes that staleness gap directly off the real trigger (region change), rather than
    /// relying on tile-load as a proxy for it.
    ///
    /// **QA pass 1 fix (🟡 #1): gated `!driveModeActive`.** This handler ALSO fires during
    /// Drive Mode: `handleLocationUpdate()`'s per-GPS-tick `coordinatorActions.setDriveCamera`
    /// (Option A custom follow, ~1Hz) calls `MKMapView.setCamera(animated:)`, which fires
    /// `regionDidChangeAnimated` → async `onRegionChanged` → THIS handler, once per GPS fix,
    /// continuously, for the entire drive — a completely different cadence than the
    /// "once-per-settled-gesture" browse-mode case this fix actually targets. Pre-fix, Drive
    /// Mode repainted overlays only via `DriveModeBottomCard`'s own cadence (entry rebuild +
    /// `tileLoader.segments.count` changes as new tiles stream in) — NOT once per camera tick.
    /// QA traced that this new call, unguarded, would roughly DOUBLE the per-tick main-thread
    /// cost of the single highest-stakes interaction in the app (active driving), stacking on
    /// top of `tileLoader.loadTiles(forRegion:)`'s own pre-existing unconditional per-tick
    /// `rebuildSegments` call on the very next line. The staleness bug this fix targets is a
    /// BROWSE-mode bug (a user pinching the resting map, not actively driving) — gating on
    /// `!driveModeActive` restores Drive Mode's prior repaint economics EXACTLY (its own
    /// existing triggers are untouched by this file) while leaving the actual fix, for the
    /// actual bug, fully intact.
    ///
    /// **Flag-off risk considered (browse mode):** `MKMapViewDelegate.regionDidChangeAnimated`
    /// fires once per settled gesture (per `MapViewRepresentable`'s own `regionDidChangeAnimated`
    /// doc comment — "fires only after the deceleration animation completes," not per-frame
    /// during an active pan/pinch), the SAME cadence `tileLoader.loadTiles(forRegion:)` on the
    /// very next line already runs at, unconditionally, today, flag on or off, in BOTH browse
    /// and (pre-this-fix) Drive Mode. Outside Drive Mode, adding one more
    /// O(n)-over-loaded-segments call (`rebuildOverlays`, same cost class
    /// `handleSegmentsChanged`/`handleSelectionChanged`/the 60s timer tick already pay on every
    /// call) at that settled-gesture cadence is not a new order-of-magnitude cost — no
    /// additional debounce is introduced here because none already guarded the parallel
    /// `loadTiles` call on this same callback.
    private func handleRegionChanged(_ newRegion: MKCoordinateRegion) {
        region = newRegion
        tileLoader.loadTiles(forRegion: newRegion)
        // Community 1.0 / Tier 1: debounced fetch for community pins (800ms debounce).
        pinService.onRegionChanged(newRegion)
        if ContentView.shouldRebuildOverlaysOnRegionChange(driveModeActive: driveModeActive) {
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // A3.6: re-measure the user's dot in screen space now that the camera has settled
        // (the ambient Recenter button reads it). No-op flag-off / while driving.
        refreshAmbientUserDotOffCenter()
    }

    /// Forwards community pin taps to the sheet presentation.
    private func handleCommunityPinTapped(_ pin: CommunityPin) {
        activeSheet = .pinDetail(pin)
    }

    // MARK: - Community 2.0 S13c Fix #1: zone-boundary home-zone derivation

    /// The user's OWN zone — the zone id whose boundary box + "YOUR SQUARE · {ZONE}" label
    /// render on the map (`design/screenshots/03-your-square.png`). Corrected per
    /// `docs/design/community-2.0-final-parity-audit.md` §2 item 1 (Kevin's ruling): the
    /// zone containing the user's PARKED CAR if one is parked, else the zone containing the
    /// DEVICE'S CURRENT LOCATION. NEVER the map viewport center — that was the exact bug the
    /// audit pinned in the prior version of this function (a user panning to SoHo while
    /// their car sits in Nolita, or simply browsing with no car parked, got a false "this is
    /// yours" label for whatever happened to be on screen). `nil` when neither resolves to a
    /// zone in the fetched `zoneStore.zones` list — no box and no label render in that case
    /// (both are gated off the same non-nil check, see
    /// `MapViewRepresentable.syncZoneBoundaries`).
    ///
    /// "Parked car beats current-location" mirrors the priority
    /// `updatePushZoneFromParkedCarOrLocation` already uses for the push zone_id (spec
    /// §2.9) — the two derivations are now fully consistent (both read
    /// `locationService.userLocation`, not the viewport) rather than diverging as before.
    private var communityHomeZoneId: String? {
        guard AppConstants.communityEnabled else { return nil }
        return Self.resolveHomeZoneId(
            parkedCarLat: parkPinService.parkedCar?.latitude,
            parkedCarLng: parkPinService.parkedCar?.longitude,
            deviceLocationLat: locationService.userLocation?.latitude,
            deviceLocationLng: locationService.userLocation?.longitude,
            zones: zoneStore.zones
        )
    }

    /// Pure priority derivation extracted from `communityHomeZoneId` so the "parked car
    /// beats device location" rule is directly unit-testable without a live `ContentView`
    /// instance (`parkPinService`/`locationService` are both hard to construct headlessly) —
    /// same "extract the decision, not just the data lookup" pattern as
    /// `communityMapChromeVisible` above.
    ///
    /// S13c Fix #1: `viewportCenterLat/Lng` parameters are GONE — the map viewport must never
    /// be a signal for "whose zone is this." Replaced with `deviceLocationLat/Lng` (the
    /// device's actual current-location fix, e.g. `LocationService.userLocation`).
    ///
    /// Community 2.0 S14: gained an explicit `zones: [Zone]` parameter — the live-fetched
    /// `ZoneStore.zones` list — replacing the compiled zone-bounds table this function used to
    /// read implicitly.
    nonisolated static func resolveHomeZoneId(
        parkedCarLat: Double?,
        parkedCarLng: Double?,
        deviceLocationLat: Double?,
        deviceLocationLng: Double?,
        zones: [Zone]
    ) -> String? {
        if let lat = parkedCarLat, let lng = parkedCarLng {
            return ZoneGeometry.zoneId(forLat: lat, lng: lng, in: zones)
        }
        if let lat = deviceLocationLat, let lng = deviceLocationLng {
            return ZoneGeometry.zoneId(forLat: lat, lng: lng, in: zones)
        }
        return nil
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
            // Open item #17 residual (2026-09-11): tentative "car will go here" marker at
            // the long-press point while the flag-on `LongPressParkConfirmCard` is up.
            // `pendingParkPinCoordinate` is the pure gate that keeps this `nil` for flag-off
            // builds even though `pendingLongPressCoord` is also set by the legacy
            // three-button-dialog long-press flow those users still see — see that
            // function's own doc comment.
            // NB: argument order must match the memberwise init (declaration order) —
            // pendingParkCoordinate is declared directly after draftSpotCoordinate.
            pendingParkCoordinate: Self.pendingParkPinCoordinate(
                communityEnabled: AppConstants.communityEnabled,
                pendingLongPressCoord: pendingLongPressCoord
            ),
            // Community 2.0 S13a/S13c: dashed zone-boundary overlay — flag-gated
            // explicitly here (not just inside `communityHomeZoneId`) so a flag-off build
            // never even asks `MapViewRepresentable` to build the boundary polygon
            // (spec's own "flag-off = zero new chrome, byte-identical map" requirement).
            // S13c Fix #1: added `&& !driveModeActive` — this overlay must hide during
            // Drive Mode (minimal chrome while driving), matching the sibling
            // `communityMapChromeVisible` gate two properties above, which already excludes
            // Drive Mode.
            // NB: argument order must match the memberwise init (declaration order) — both
            // are declared directly after `pendingParkCoordinate`, same convention as its own
            // comment above.
            showZoneBoundaries: AppConstants.communityEnabled && !driveModeActive,
            // Community 2.0 S14: resolves the whole `Zone` object once here (was a plain
            // `homeZoneId: String?`) — `MapViewRepresentable` no longer has any
            // `ZoneStore`/`ZoneGeometry` dependency of its own.
            homeZone: communityHomeZoneId.flatMap { id in zoneStore.zones.first { $0.id == id } },
            communityPins: communityPins,
            onCommunityPinTapped: handleCommunityPinTapped(_:),
            segments: tileLoader.segments,  // FT-11: for directional chevron bearing computation
            // FT-15/TF2-15 Stream B2: multi-segment block-select highlight (§4.2 step 3).
            blockSelectKeys: selectedBlockKeys,
            driveHeading: effectiveDriveHeading,  // TF2-16: course, or street-snap at low confidence
            driveModeActive: driveModeActive,
            onDrivePanDetected: handleDrivePanDetected,
            onDrivePinchZoomed: handleDrivePinchZoomed(_:),
            coordinatorActions: coordinatorActions,
            // A3 (curb-pin placement): the three seam inputs A2 declared AFTER
            // `coordinatorActions` (NB: declaration order). `curbPlacementIndex` is nil
            // whenever no session is live (always, flag-off); the callbacks are never invoked
            // without a session.
            placementIndex: curbPlacementIndex,
            onPlacementOutcome: handleCurbPlacementOutcome(_:),
            placementSeverity: curbPlacementSeverity(for:)
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
        // DM-2 (`docs/drive-mode-default-spec.md` §0.8.7, design doc §2.1/§6 flag #4):
        // computed once per render so the goal-dock row AND the ParkUntilPill-suppression
        // check below can never disagree about whether the dock/tile row is showing.
        let goalDockVisible = goalSelectorDockVisible(
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            activeSheetIsNil: activeSheet == nil,
            driveModeActive: driveModeActive,
            blockSelectModeActive: blockSelectModeActive,
            spotPlacementActive: spotPlacementActive,
            curbPlacementActive: curbPlacement != nil
        )
        let goalTilesVisible = goalTileRowVisible(
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            activeSheetIsNil: activeSheet == nil,
            fullPaletteMode: fullPaletteMode,
            driveModeActive: driveModeActive,
            blockSelectModeActive: blockSelectModeActive,
            spotPlacementActive: spotPlacementActive,
            curbPlacementActive: curbPlacement != nil
        )
        // Addendum 2 (A2.2): whether the CURRENT Park Until filter came from a goal tap —
        // see `activeGoalForParkUntilPill`'s own doc comment for why this needs ZERO new
        // stored state (a deliberate, disclosed deviation from this PR's own dispatch, which
        // separately suggested adding tracking state — flagged in this PR's description; the
        // addendum itself, the binding spec for this part, derives it this way).
        let activeGoal = ContentView.activeGoalForParkUntilPill(
            selectedGoal: selectedGoal,
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            fullPaletteMode: fullPaletteMode
        )
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
            // DM-2 (§0.8, design doc §2.1): the ambient goal-first dock — mutually
            // exclusive with every row above/below by construction (`goalSelectorDockVisible`
            // already excludes Drive Mode/block-select/spot-placement/any-sheet-presented).
            // Ambient-only (§0.8.7) — never rebuilt inside the escalated Cruise session.
            if goalDockVisible {
                GoalSelectorView(
                    selectedGoal: selectedGoal,
                    fullPaletteMode: fullPaletteMode,
                    emptyMapGuardKind: emptyMapGuardKind,
                    onSelectGoal: { goal in selectGoal(goal) },
                    // Addendum 3 (A3.3): the Report pill + full-palette toggle row is gone from
                    // the dock (both live in the More sheet now). In full-palette mode the
                    // dock's "Pick a parking goal" row calls this — `toggleFullPaletteMode()`'s
                    // turn-OFF branch (re-applies `selectedGoal`, brings the tiles back).
                    onReturnToGoals: { toggleFullPaletteMode() },
                    onStartDriving: { enterCruiseMode() }
                )
            }
            // W7.5 row 3: Park Until pill — carried over from browsing if already active;
            // cannot be entered mid-drive (recenterButtonStack, its only entry point, is
            // hidden while driveModeActive == true).
            //
            // DM-2 (design doc §6 flag #1 — the "legacy ParkUntilPill double-render bug"):
            // suppressed whenever the goal-first dock's own tile row is showing
            // (`goalTilesVisible`) — once Overnight is pre-selected by default,
            // `parkUntilMode` is true at rest 100% of the time, and without this guard the
            // old pill would render simultaneously with the new dock, duplicating "a filter
            // is active" in two different UI languages at once. Reappears in its existing,
            // unchanged form once the user toggles to full-palette AND sets a target via the
            // power-user `ParkUntilSheet` (§0.8.9) — its original job, untouched. Flag off:
            // `goalTilesVisible` is always `false`, so this is byte-identical to pre-DM-2
            // behavior.
            //
            // Addendum 2 (A2.2): while escalated (Drive Mode active, so `goalTilesVisible`
            // is false even though the flag is on), this slot now upgrades to the
            // goal-identity `GoalParkUntilPill` whenever `activeGoal != nil` — i.e. whenever
            // the live filter came from a goal tap, not a manual `ParkUntilSheet` pick.
            // `activeGoal == nil` (flag off, or full-palette mode) renders TODAY'S generic
            // `ParkUntilPill`, completely unchanged. Same ✕ → `clearParkUntilFilter()`, no
            // gating, no confirm, in both branches.
            //
            // A3 (curb-pin placement): hidden for the duration of the mode - the card is a map
            // overlay and this pill (inside the bottom safe-area inset) would sit behind/under it.
            if parkUntilMode, let target = parkUntilTarget, !goalTilesVisible, curbPlacement == nil {
                if let activeGoal {
                    let content = ContentView.goalPillContent(for: activeGoal, target: target, now: lastEvaluatedAt)
                    GoalParkUntilPill(
                        icon: content.icon,
                        shortName: content.shortName,
                        trailingClause: content.trailingClause
                    ) {
                        clearParkUntilFilter()
                    }
                } else {
                    ParkUntilPill(targetDate: target) {
                        clearParkUntilFilter()
                    }
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

    /// DM-2: maps `parkAndForgetGuardState` (`ParkAndForgetViewportResolution?`) to the
    /// presentation-layer `EmptyMapGuardKind?` `GoalSelectorView` consumes — `nil` unless the
    /// active goal is Park & Forget AND the ladder had to step down or came up empty
    /// (§0.8.10). Kept as a tiny mapping step (rather than handing the resolution type
    /// straight to the view) so `GoalSelectorView` never needs to import/know about
    /// `ParkingGoals`'s ladder offsets at all — pure presentation, per that file's own header.
    private var emptyMapGuardKind: EmptyMapGuardKind? {
        switch parkAndForgetGuardState {
        case .resolved(_, let steppedDown):
            return steppedDown ? .steppedDown : nil
        case .empty:
            return .empty
        case nil:
            return nil
        }
    }

    /// DM-2: applies a tapped goal tile — sets `selectedGoal` and re-runs the EXISTING
    /// `rebuildOverlays()` path (§0.8.6). No sheet, no confirm (AC-22); never touches
    /// `driveModeActive` (AC-30).
    private func selectGoal(_ goal: ParkingGoal) {
        selectedGoal = goal
        rebuildOverlays(at: .nowET)
    }

    /// DM-2 (§0.8.8): flips `fullPaletteMode`. Turning it ON is functionally identical to
    /// today's already-shipped `clearParkUntilFilter()` (AC-27) — same function, called
    /// directly, so the toast/state-clear behavior can never drift from that existing path.
    /// Turning it OFF re-applies `selectedGoal` via the normal `rebuildOverlays()` path
    /// (the goal-recompute block at the top of `rebuildOverlays` picks it straight back up).
    private func toggleFullPaletteMode() {
        if fullPaletteMode {
            fullPaletteMode = false
            rebuildOverlays(at: .nowET)
        } else {
            fullPaletteMode = true
            clearParkUntilFilter()
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
    ///   2. Search            — magnifyingglass, shown only while
    ///                         `AppConstants.driveModeDefaultEnabled` (DM-2, §0.4/§0.4a's
    ///                         Job B mitigation, design doc §2.6: "the stack's 2nd button —
    ///                         after 'Find me,' before the conditional 'Find my car'").
    ///                         Presents `.browseNav` at `.medium`. AC-2: absent entirely
    ///                         while the flag is off (`.browseNav` is still the persistent
    ///                         default sheet in that state — no mitigation needed).
    ///   3. "Find my car"    — car.fill, only when a pin exists
    ///   4. Park Until       — clock.fill, shown unless the goal-first dock owns the filter
    ///                         (DM-2, §0.8.9/design doc §2.6 — `parkUntilClockButtonVisible`).
    ///                         When visible, its own filter behavior/framing/toolbar position
    ///                         are all unchanged by FT-20 or DM-2.
    ///   5. "?" map key       — Addendum 2 (A2.1 item 1): joins this rail as its LAST circle,
    ///                         flag-on ONLY (`AppConstants.driveModeDefaultEnabled`). Flag
    ///                         off: absent here, unchanged — the "?" stays exactly where it
    ///                         is today, `communityMapChromeOverlay`'s bottom-right corner.
    ///
    /// FT-20 Stream C: the former 4th button — the combined Drive/Cruise entry `Menu`
    /// (`driveEntryButton`) — is DELETED. Its two former options are now reached via search
    /// (`BrowseSearchAreaView`'s place state → Go, destination path) and the sheet's
    /// primary "Find a Spot" button (`enterCruiseMode()`, no destination path — labeled
    /// "Cruise" until spec §0f Ruling 2 renamed it) — no menu, per Kevin's terminology
    /// ruling (spec §3.1, superseded on naming by §0f).
    ///
    /// **Addendum 3 (A3.2, minimal ambient screen):** the flag-ON rail is now a completely
    /// different, smaller stack — `ambientRail` (Search + More + a conditional Recenter, 56pt
    /// circles). The old Find me / Find my car / clock circles and Addendum 2's "?" circle are
    /// NOT part of it (Find my car, the clock, and "?" moved into the More sheet). Flag OFF:
    /// `legacyRecenterButtonStack`, the pre-DM-2 rail verbatim (buttons 1, 3, 4 above — the flag-on-
    /// only Search and "?" buttons were deleted from it, since it only ever renders flag-off).
    @ViewBuilder
    private var recenterButtonStack: some View {
        if AppConstants.driveModeDefaultEnabled {
            ambientRail
        } else {
            legacyRecenterButtonStack
        }
    }

    // MARK: - Addendum 3 A3.2: ambient rail (flag-on only)

    /// Whether the ambient rail's conditional Recenter circle shows right now — a thin wrapper
    /// over the pure `ambientRecenterButtonVisible(...)` decision (where the rule is documented
    /// and unit-tested) feeding it the live auth status, user fix, and visible map region.
    private var ambientRecenterVisible: Bool {
        ambientRecenterButtonVisible(
            authorizationStatus: locationService.authorizationStatus,
            userLocation: locationService.userLocation,
            visibleRegion: region,
            userDotOutsideCentralHalfOnScreen: ambientUserDotOffCenter
        )
    }

    /// One 56pt `.regularMaterial` rail circle (Addendum 3 A3.2). Icon scales with Dynamic
    /// Type (`.title3.weight(.semibold)`) while the circle stays 56pt; `.primary` foreground.
    private func railCircleButton(
        systemImage: String,
        accessibilityLabel label: String,
        accessibilityHint hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(.regularMaterial, in: Circle())
                .foregroundStyle(.primary)
        }
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    /// Addendum 3 A3.2: top-right rail, fixed order so nothing shifts when another appears —
    /// Search, More, then Recenter ONLY after the user pans away (or while location
    /// authorization is undecided). Recenter is last so its appearance never moves Search or
    /// More; `.transition(.opacity)`, no haptic. Icon size capped at `.xxxLarge` on this rail.
    @ViewBuilder
    private var ambientRail: some View {
        VStack(spacing: 12) {
            // 1. Search — presents `.browseNav` at `.medium` (unchanged from §2.6).
            railCircleButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: "Search",
                accessibilityHint: "Find a street or place"
            ) {
                presentBrowseNavSearch()
            }
            // 2. More — the single door to Report, the map key, the palette toggle, Find my
            //    car, and the Park Until clock (`MoreMenuSheet`).
            railCircleButton(
                systemImage: "ellipsis",
                accessibilityLabel: "More",
                accessibilityHint: "Report, what the colors mean, and more"
            ) {
                activeSheet = .moreMenu
            }
            // 3. Recenter — conditional, last. `location` (outline) is correct here: it only
            //    shows when the map is NOT following the user (or auth is undecided), so the
            //    "following" `location.fill` state the spec mentions can't occur on this button.
            if ambientRecenterVisible {
                railCircleButton(
                    systemImage: "location",
                    accessibilityLabel: "Show my location",
                    accessibilityHint: "Moves the map to show your current GPS position."
                ) {
                    recenterOnUser()
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: ambientRecenterVisible)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - Flag-off rail (pre-DM-2, unchanged)

    @ViewBuilder
    private var legacyRecenterButtonStack: some View {
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

            // (DM-2's flag-on-only Search button is now `ambientRail`'s first circle; flag off
            // never rendered it — `.browseNav` is the persistent default sheet there.)

            // Button 3: "Find my car" — shown only when a parked-car pin exists.
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

            // Button 4: Park Until filter — standalone trigger (filter-first UX).
            // DM-2 (§0.8.9, design doc §2.6): hidden while the goal-first dock owns the
            // filter — "not reachable directly from the goal-first home screen" is made
            // literal here. Reappears once the user toggles to full-palette mode, or
            // always when the flag is off (byte-identical to pre-DM-2 behavior).
            if parkUntilClockButtonVisible(
                driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
                fullPaletteMode: fullPaletteMode
            ) {
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
            // (Addendum 3: the flag-on-only "?" circle Addendum 2 added here is deleted — the
            // map key is now More-sheet row 2. Flag off never rendered it.)
        }
    }

    /// DM-2 (§0.4a's Job B mitigation): presents `.browseNav` at its `.medium` detent — the
    /// Search icon's tap action. Setting `browseSheetDetentKind` and `activeSheet` together,
    /// in the same synchronous transaction, means the sheet mounts ALREADY at medium rather
    /// than animating up from peek (same idiom `handleDriveModeAndCamera` already uses to
    /// force `browseSheetDetentKind = .peek` before restoring `.browseNav`).
    private func presentBrowseNavSearch() {
        browseSheetDetentKind = .medium
        activeSheet = .browseNav
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
    ///
    /// DM-3 (`docs/drive-mode-default-spec.md` §0.2 — "a real gap this spec must fix, not
    /// just work around"): before this fix, this function had NO authorization check at
    /// all — a tap while `.notDetermined` fell straight through into
    /// `driveModeActive = true`, which `handleDriveModeChange(true)` → `startDriveMode()`
    /// turns into a silent no-op (that function calls `startUpdatingLocation()` directly,
    /// never `requestWhenInUseAuthorization()`): no system prompt, no error, no visible
    /// cause. `cruiseEntryAuthAction(for:)` below closes that gap, flag-independent (this
    /// function's only call site today is reachable whether `driveModeDefaultEnabled` is on
    /// or off — see `noBlockingSheetPresented`'s own doc comment) — never widening when the
    /// escalation itself fires, only gating entry on an authorization check that was
    /// previously entirely absent.
    private func enterCruiseMode() {
        guard noBlockingSheetPresented else { return }
        switch cruiseEntryAuthAction(for: locationService.authorizationStatus) {
        case .requestFirst:
            // Fires the real system permission prompt instead of silently escalating into
            // a continuous-GPS session with no permission. `requestAndFetchLocation()`'s
            // own delegate callback resolves authorization asynchronously.
            //
            // DM-2 fast-follow (`docs/qa/pr131-dm3-priming-authfix.md` 🟡 Finding #1,
            // corrected): this tap DOES auto-continue into escalation once authorization
            // resolves — `isRequestingCruiseEntryAuth = true` here, read by the
            // `.onChange(of: locationService.isAuthorized)` handler in `body`, which calls
            // this function again once `isAuthorized` flips. This is now the SAME one-tap
            // shape `BrowseSearchAreaView.handleGoTap()` already uses for destination-mode
            // Drive's own `.notDetermined` branch (the PR #131 comment this replaces
            // claimed that parity prematurely — this fix is what actually delivers it).
            isRequestingCruiseEntryAuth = true
            locationService.requestAndFetchLocation()
            return
        case .showDeniedAlert:
            showLocationDeniedAlert = true
            return
        case .proceed:
            break
        }
        driveModeStyle = .cruise
        // activeRoute stays nil — no route polyline in Cruise Mode (AC-CM.14).
        // driveDestinationCoordinate stays nil — no destination pin (AC-CM.14).
        driveModeDistanceMeters = nil  // clear any stale value from a prior destination session.
        driveModeActive = true
        // setCruiseMode(true) is called inside handleDriveModeChange(true) below,
        // triggered by the .onChange(of: driveModeActive) observer.
    }

    // MARK: - DM-3: Cruise-entry denied-state Settings deep link

    /// Opens iOS Settings for this app — fired from the "Open Settings" button on
    /// `enterCruiseMode()`'s denied-state alert (spec §0.2 AC-11b). Same shape as
    /// `NotificationRationaleView.openSettings()`; duplicated rather than shared because
    /// that function is `private` to a different view file and this is a two-line call.
    private func openLocationSettingsForCruiseEntry() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - DM-3: Location-priming card dismissal

    /// Dismisses `LocationPrimingCard` and marks its one-shot gate shown — both "Allow" and
    /// "Not now" count as shown (spec §0.2: "shown once, never again, regardless of the
    /// user's choice"). `allowed == true` additionally fires the real system prompt via
    /// `requestAndFetchLocation()`; `allowed == false` has zero other side effects.
    ///
    /// **Part A fix 1** (`docs/design/goal-first-ambient-design.md` Addendum 2's predecessor
    /// diagnosis): before this fix, a granted permission here never recentered the camera —
    /// `requestAndFetchLocation()` was fired with neither `recenterOnUserRequested` nor
    /// `recenterOnUserAtLaunch` set, so `handleLocationUpdate()`'s two recenter branches both
    /// no-op when the fix eventually arrives. `recenterOnUserAtLaunch` (not
    /// `recenterOnUserRequested`) is the correct flag here, not an arbitrary pick: this is a
    /// launch-time, best-effort recenter — same "silently stay on the fallback center if out
    /// of coverage, no toast" posture `performLaunchSetup`'s own Priority 2b branch already
    /// uses for the identical "authorized, no cached fix yet" case — not a user-initiated
    /// button tap, which is what `recenterOnUserRequested`'s toast-on-out-of-coverage behavior
    /// is for.
    private func dismissLocationPrimingCard(allowed: Bool) {
        guard showLocationPrimingCard else { return }
        LocationPrimingCardGate().markShown()
        showLocationPrimingCard = false
        if allowed {
            recenterOnUserAtLaunch = true
            locationService.requestAndFetchLocation()
        }
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
            recenterMap(on: loc, usingUserFix: true)
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

    /// The launch-default `region`'s value — `nonisolated static` so the `@State` initializer
    /// above can call it (property initializers can't reference `self` or other instance
    /// state) and so this is directly unit-testable without a live `ContentView` instance,
    /// same pattern as `communityMapChromeVisible`/`resolveHomeZoneId`.
    ///
    /// **Part A fix 2** (`docs/design/goal-first-ambient-design.md` Addendum 2's predecessor
    /// diagnosis): before this fix, the launch default was ALWAYS the wide `0.07°/0.05°` span
    /// — comfortably ABOVE `AppConstants.polylineHideSpanThreshold` (0.04°), so
    /// `rebuildOverlays`'s zoom-threshold guard assigned an EMPTY overlay payload at every
    /// cold launch, flag on or off, until some other event (auto-center, Find-me, Drive-entry)
    /// narrowed the camera. Flag-off relies on exactly that — the FT-20 browse sheet's own
    /// auto-center path reliably fires shortly after launch. Flag-on ambient mode has NO
    /// guaranteed narrowing event with no location fix (see fix 1, `dismissLocationPrimingCard`),
    /// so the map could rest indefinitely on a wide span with zero curb colors, reading as a
    /// broken/empty map — the actual bug Kevin's 2026-10-20/21 smoke reported.
    ///
    /// **Fix, flag-gated:** while `driveModeDefaultEnabled`, start at the SAME street-level
    /// span `recenterMap(on:)` already uses for GPS-based recentering
    /// (`AppConstants.streetLevelRecenterMeters`, 400m) — comfortably inside the hide
    /// threshold at any latitude in `AppConstants.manhattanCoverageBounds` (at 40.7831°N,
    /// 400m ≈ 0.0036° latitude / 0.0048° longitude, both well under 0.04°), so a cold launch
    /// with no location fix yet still paints curb colors around `manhattanCenter` immediately,
    /// AND stops flooding `TileLoader`'s 200-tile LRU with a viewport-sized tile set at launch
    /// (a secondary contributor the diagnosis also named). **Flag off: byte-identical** to the
    /// pre-fix `0.07°/0.05°` span — see `ViewportPolishTests`/the guard test for this function
    /// for the pinned literal values.
    nonisolated static func initialLaunchRegion(
        driveModeDefaultEnabled: Bool = AppConstants.driveModeDefaultEnabled
    ) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: AppConstants.manhattanCenter.latitude,
            longitude: AppConstants.manhattanCenter.longitude
        )
        guard driveModeDefaultEnabled else {
            return MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
            )
        }
        return MKCoordinateRegion(
            center: center,
            latitudinalMeters: AppConstants.streetLevelRecenterMeters,
            longitudinalMeters: AppConstants.streetLevelRecenterMeters
        )
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
    ///
    /// **A3.6 (flag-on, resting posture):** `setRegion` would FLATTEN the ambient driving look
    /// (it resets pitch), so while `ambientDrivingLookInEffect` the recenter is applied as the
    /// look itself - same pitch/heading/distance, centered on `coordinate` - via
    /// `applyAmbientDrivingLook`. `usingUserFix` says the coordinate IS the user's GPS dot, so
    /// the accuracy guard (A3.6.1) picks the zoom step from the latest fix; for any other target
    /// (the parked car, a deep link) accuracy is irrelevant and the look opens tight. `region`
    /// is still written for tile loading either way. Flag off / driving: unchanged `setRegion`.
    private func recenterMap(on coordinate: CLLocationCoordinate2D, usingUserFix: Bool = false) {
        // A3 (curb-pin placement), PR #140 QA P2-1: THE funnel for every recenter (launch
        // auto-center, Find me, parked-car, deep link). While a placement session is live the
        // camera belongs to it - flag-off `setRegion` below would flatten/clobber the placement
        // camera. The DEFERRAL of the flag-driven callers lives in `handleLocationUpdate`
        // (their pending flags are NOT cleared while a session is live); this guard is the
        // backstop for any other caller. Always false flag-off.
        if curbPlacement != nil { return }
        let newRegion = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: AppConstants.streetLevelRecenterMeters,
            longitudinalMeters: AppConstants.streetLevelRecenterMeters
        )
        region = newRegion
        if ambientDrivingLookInEffect {
            applyAmbientDrivingLook(
                center: coordinate,
                step: usingUserFix
                    ? AmbientDrivingLook.zoomStep(forHorizontalAccuracy: locationService.userHorizontalAccuracy)
                    : .tight,
                animated: true
            )
        } else {
            coordinatorActions.setRegion?(newRegion)
        }
    }

    // MARK: - A3.6 ambient driving look (flag-on only; SEAM: self-contained block)
    //
    // Addendum 3 A3.6 / Kevin's Option A: flag-on, the resting map OPENS looking like drive
    // mode - Cruise's pitch and distance, north-up, muted, standard blue dot - on the cheap
    // location posture. It is a camera + style posture ONLY: `driveModeActive` stays false, and
    // nothing here calls `startDriveMode()`, touches the wake lock, starts continuous GPS, or
    // speaks (AC-13). The expensive posture still engages only via `enterCruiseMode()`.
    //
    // #31 invariant: every camera mutation below goes through `coordinatorActions` and is
    // called from `.task` / `.onChange`-driven handlers (`performLaunchSetup`,
    // `handleLocationUpdate`, `handleDriveCameraChange`, the recenter actions) - NEVER from
    // `updateUIView` or a view body. Pure decisions live in `AmbientDrivingLook`.

    /// Flag on AND not in an escalated drive session (thin wrapper over the tested pure gate).
    private var ambientDrivingLookInEffect: Bool {
        AmbientDrivingLook.isInEffect(
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            driveModeActive: driveModeActive
        )
    }

    /// Applies the look in ONE `setCamera` (see `CoordinatorActions.setAmbientDrivingLook`):
    /// Cruise pitch, heading 0, and the distance for `step`. `center == nil` keeps the camera's
    /// current center. Records the step and clears "user adjusted" (an explicit apply - launch,
    /// Recenter, exit - IS the look being re-asserted).
    private func applyAmbientDrivingLook(
        center: CLLocationCoordinate2D?,
        step: AmbientDrivingLook.ZoomStep,
        animated: Bool
    ) {
        ambientLookStep = step
        ambientLookUserAdjusted = false
        let span = AmbientDrivingLook.span(for: step, cruiseSpan: MapViewRepresentable.driveModeCameraSpan)
        coordinatorActions.setAmbientDrivingLook?(
            center,
            MapViewRepresentable.driveModePitch,
            AmbientDrivingLook.heading,
            MapViewRepresentable.altitudeForSpan(span),
            animated
        )
    }

    /// Cold-launch entry point (from `performLaunchSetup`): muted style, no 3D buildings (same
    /// rationale as Cruise - they occlude the curb lines at this pitch; also keeps entering
    /// Cruise from popping them), then the look itself, non-animated so there is no launch
    /// swoop. The zoom step comes from the latest fix's accuracy (nil at a true cold launch =
    /// `.wide`; `handleLocationUpdate` tightens it when a good fix arrives). Flag off: no-op.
    private func startAmbientDrivingLook() {
        guard AppConstants.driveModeDefaultEnabled else { return }
        coordinatorActions.onAmbientUserAdjusted = {
            self.ambientLookUserAdjusted = true
        }
        coordinatorActions.applyDriveMapStyle?(true, nil)
        coordinatorActions.setShowsBuildings?(false)
        applyAmbientDrivingLook(
            center: nil,
            step: AmbientDrivingLook.zoomStep(forHorizontalAccuracy: locationService.userHorizontalAccuracy),
            animated: false
        )
    }

    /// Drive exit (flag-on): back to the ambient look, centered where the camera already is.
    /// Reuses the existing style / buildings / puck closures with the AMBIENT values (muted,
    /// buildings off) instead of restoring the entry-time snapshot, then one `setCamera`.
    /// `refreshUserLocationPuck` re-queries `viewFor`, which now (driveModeActive == false)
    /// returns the plain ambient dot.
    private func restoreAmbientDrivingLookAfterDrive() {
        coordinatorActions.applyDriveMapStyle?(true, nil)
        coordinatorActions.setShowsBuildings?(false)
        coordinatorActions.refreshUserLocationPuck?(false)
        applyAmbientDrivingLook(center: nil, step: AmbientDrivingLook.exitZoomStep(), animated: true)
    }

    /// Per-fix hook (from `handleLocationUpdate`): tighten a wide look when a better fix has
    /// arrived and the user has not touched the map; otherwise re-measure the Recenter test.
    /// `cameraMoveInFlight` = a recenter this tick is about to move the camera, so measuring
    /// now would read the pre-move camera and flash Recenter; `handleRegionChanged` measures
    /// once it settles.
    private func handleAmbientLookLocationUpdate(cameraMoveInFlight: Bool) {
        guard ambientDrivingLookInEffect else { return }
        // A3 (curb-pin placement), PR #140 QA #2: auto-tighten issues `setAmbientDrivingLook`
        // (pitch 30 + re-centre on the fix), which would hijack the placement camera. Skipped
        // while a session is live; nothing is lost - `ambientLookStep` is unchanged, so the next
        // fix after the session re-evaluates. Always nil flag-off.
        guard curbPlacement == nil else { return }
        var cameraMoving = cameraMoveInFlight
        if AmbientDrivingLook.shouldTighten(
            currentStep: ambientLookStep,
            userAdjusted: ambientLookUserAdjusted,
            newAccuracy: locationService.userHorizontalAccuracy
        ) {
            // Center on the improved fix (QA #2) - not the stale first-fix center.
            let fix = locationService.userLocation
            applyAmbientDrivingLook(
                center: AmbientDrivingLook.tightenCenter(
                    fix: fix,
                    fixInCoverage: fix.map { AppConstants.isInManhattanCoverage($0) } ?? false
                ),
                step: .tight,
                animated: true
            )
            cameraMoving = true
        }
        if !cameraMoving {
            refreshAmbientUserDotOffCenter()
        }
    }

    /// Re-measures whether the user's dot is outside the central 50% of the map IN SCREEN
    /// SPACE (correct under pitch - see `AmbientDrivingLook.userDotOutsideCentralHalf`). Pure
    /// read of MapKit state; writes `@State` only when the value changes. Called from
    /// non-render handlers only. No-op flag-off / while driving.
    private func refreshAmbientUserDotOffCenter() {
        guard ambientDrivingLookInEffect else { return }
        let measured: Bool?
        if let coord = locationService.userLocation {
            measured = coordinatorActions.userDotOutsideCentralHalf?(coord)
        } else {
            measured = nil
        }
        if measured != ambientUserDotOffCenter {
            ambientUserDotOffCenter = measured
        }
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
            zoneId = ZoneGeometry.zoneId(forLat: car.latitude, lng: car.longitude, in: zoneStore.zones)
        } else if let loc = locationService.userLocation {
            zoneId = ZoneGeometry.zoneId(forLat: loc.latitude, lng: loc.longitude, in: zoneStore.zones)
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
        // A3.6.3 (flag-on): leaving drive returns to the ambient driving look (the "prior"
        // state IS the look), not the camera/style captured at entry. Flag-off falls through
        // to today's restore, untouched.
        if !active,
           AmbientDrivingLook.restoresAmbientLookOnDriveExit(
               driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled
           ) {
            restoreAmbientDrivingLookAfterDrive()
            return
        }
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
        // A3.6: captured BEFORE the recenter branches below clear these flags - if either was
        // set, a recenter camera move is about to start this tick (see the ambient hook below).
        let ambientRecenterPending = recenterOnUserRequested || recenterOnUserAtLaunch
        // A3 (curb-pin placement), PR #140 QA P2-1 (b): while a session is live both pending
        // recenter flags are DEFERRED - left set, not cleared - so the recenter still happens
        // once the session ends (`endCurbPlacement` re-queues a fix). Gating only the
        // `recenterMap` call would lose it for good, because the flags are cleared first. With no
        // session the plan consumes exactly what is pending: the original behavior.
        let placementPlan = CurbPlacementPolicy.recenterPlan(
            requestedPending: recenterOnUserRequested,
            atLaunchPending: recenterOnUserAtLaunch,
            placementActive: curbPlacement != nil
        )
        // The placement locate button's deferred fix (no cached fix when it was tapped).
        consumeCurbPlacementLocateFix(coord)
        // W5.1: Recenter on user location if requested.
        // zoom-out-limit-tighten: same out-of-coverage guard as the immediate-fix branch in
        // recenterOnUser() above — this is the deferred completion of the same button tap
        // when no cached fix was available yet.
        if recenterOnUserRequested && placementPlan.consumeRequested {
            recenterOnUserRequested = false
            if AppConstants.isInManhattanCoverage(coord) {
                recenterMap(on: coord, usingUserFix: true)
            } else {
                ToastService.shared.show(message: "Limited parking data outside Manhattan")
            }
        }
        // Viewport-polish Priority 2b: auto-center at launch if in coverage.
        if recenterOnUserAtLaunch && placementPlan.consumeAtLaunch {
            recenterOnUserAtLaunch = false
            if AppConstants.isInManhattanCoverage(coord) {
                recenterMap(on: coord, usingUserFix: true)
            }
        }
        // A3.6 ambient driving look (flag-on, resting posture only): tighten a wide look when a
        // better fix arrives, and refresh the screen-space Recenter measurement. No-op flag-off
        // and while driving.
        handleAmbientLookLocationUpdate(cameraMoveInFlight: ambientRecenterPending)
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

        // DM-3 (`docs/drive-mode-default-spec.md` §0.2, AC-9): show the one-shot
        // location-priming card at most once per install, and only while location
        // authorization is still undecided — `locationService`'s own `init()` has already
        // read the real `CLLocationManager.authorizationStatus` by this point (it's
        // populated synchronously in `LocationService.init()`, not fetched here).
        showLocationPrimingCard = locationPrimingCardShouldShow(
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            gateShouldShow: LocationPrimingCardGate().shouldShow(),
            authorizationStatus: locationService.authorizationStatus
        )

        // Community 2.0 S14: fetches (or refreshes from cache) the zones table.
        // ⚠️ UNCONDITIONAL — deliberately NOT gated behind `AppConstants.communityEnabled`,
        // unlike `zoneMessageService.startRealtime()` two lines below. See `ZoneStore.swift`'s
        // header for why: `CommunityPinService.insertCrowdPin`'s write-time zone stamping
        // (`resolveZoneId`) runs today, in production, for every crowd report any external
        // user submits, flag on or off — gating this fetch would silently regress that
        // already-shipping write path back to zero zone coverage for flag-off users.
        // Fire-and-forget (not awaited): a slow/offline network must never delay the rest of
        // launch setup below (tile loading, camera centering) — mirrors this function's
        // existing fire-and-forget precedent for `tileLoader.loadTiles(forRegion:)`/
        // `locationService.requestAndFetchLocation()` further down.
        Task { await zoneStore.loadZonesIfNeeded() }

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

        // A3.6: flag-on, open with the driving look (tilted/zoomed/muted/north-up) BEFORE the
        // launch recenter below so that recenter (which now applies the look too) lands on it.
        // No-op flag-off.
        startAmbientDrivingLook()

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
                    recenterMap(on: cachedLoc, usingUserFix: true)
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
        // A3 (curb-pin placement), PR #140 QA #4 / (d) "scene changes": if the SwiftUI state and
        // the map layer disagree about whether a session is live, reconcile through
        // `endPlacement`. No-op when both agree (always, flag-off).
        healStuckCurbPlacement()
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

    // MARK: - A3: Curb-pin placement mode (flag: AppConstants.curbPinPlacementEnabled)
    //
    // Stream A3 of docs/longpress-universal-plant-spec.md "Amendment - fixed-center pin with live
    // curb snap". The map layer (reticle, highlight, display link, camera) is Stream A2
    // (`CurbPlacementController`, reached ONLY through `coordinatorActions`); the snap engine is
    // Stream A1 (`CurbSnapIndex`). THIS block is the SwiftUI side: the `curbPlacement` session,
    // the three entry rewires, the card, and the two commit handoffs.
    //
    // Invariants:
    //   - Placement is a RESTING-posture mode. This block never reads `driveModeStyle`, never
    //     WRITES `driveModeActive`, and never touches `LocationService`'s drive posture; the
    //     locate button uses the existing single-shot `requestAndFetchLocation()`.
    //   - Every camera mutation goes through `coordinatorActions` from an `.onChange` / button
    //     handler / main-queue hop - NEVER from `updateUIView` (#31).
    //   - EVERY way out of the mode routes through `endCurbPlacement(...)`, which calls
    //     `endPlacement` (PR #140 QA #4: a stuck session leaves the map ignoring taps).
    //   - Card placement decision (QA P2-2): the card is a MAP OVERLAY (`curbPlacementOverlay`,
    //     design section 3 / spec A.4), NOT part of the bottom `.safeAreaInset` dock. The dock's
    //     rows are hidden for the duration of the mode, so the inset is empty and A2's
    //     `setPlacementBottomInset` is the SINGLE owner of lifting the Apple logo / Legal link
    //     above the card. Putting the card in the safe-area inset instead would resize the map's
    //     safe area every time the card's content changes, an unverified re-centring hazard for
    //     the tip/ghost maths. Mac smoke: confirm MapKit does not shift the camera when the
    //     margin changes.

    /// Routes an entry point through the pure policy (flag + mode exclusions).
    private func curbPlacementRouting(for entry: CurbPlacementEntry) -> CurbPlacementEntryRouting {
        CurbPlacementPolicy.routing(
            for: entry,
            flagEnabled: AppConstants.curbPinPlacementEnabled,
            driveModeActive: driveModeActive,
            blockSelectModeActive: blockSelectModeActive,
            spotPlacementActive: spotPlacementActive,
            placementActive: curbPlacement != nil
        )
    }

    /// The report pill / Path B shape: enter placement when routed there and a seed exists,
    /// otherwise report `false` so the caller runs its unmodified legacy body.
    private func startCurbPlacementIfRouted(
        entry: CurbPlacementEntry,
        seed: CLLocationCoordinate2D?,
        incumbentBlockfaceKey: String? = nil
    ) -> Bool {
        switch curbPlacementRouting(for: entry) {
        case .placement:
            guard let seed else { return false }
            beginCurbPlacement(entry: entry, seed: seed, incumbentBlockfaceKey: incumbentBlockfaceKey)
            return true
        case .legacy, .ignore:
            return false
        }
    }

    /// Enters the mode (spec A.3 "Entry"): clears the block selection, dismisses whatever sheet
    /// launched it, and publishes the session. The camera itself is begun from
    /// `.onChange(of: curbPlacement != nil)` (`handleCurbPlacementActiveChange`), outside any
    /// view update. `curbPlacement` is written BEFORE `activeSheet = nil` so the sheet's
    /// `onDismiss` catch-all already sees a live session and does not restore the rest state.
    private func beginCurbPlacement(
        entry: CurbPlacementEntry,
        seed: CLLocationCoordinate2D,
        incumbentBlockfaceKey: String? = nil
    ) {
        let hintGate = CurbPlacementHintGate()
        let showsHint = hintGate.shouldShow()
        if showsHint { hintGate.markShown() }

        if selectedSegmentID != nil { selectedSegmentID = nil }
        curbPlacementCardHeight = 0
        curbPlacement = CurbPlacementSession(
            entry: entry,
            seed: seed,
            incumbentBlockfaceKey: incumbentBlockfaceKey,
            showsHint: showsHint
        )
        if activeSheet != nil { activeSheet = nil }
    }

    /// `.onChange(of: curbPlacement != nil)`: begins the map layer on entry; on a nil-ing that did
    /// not go through `endCurbPlacement` (it always does today) it is the safety net that still
    /// ends the map layer, so taps can never stay disabled.
    private func handleCurbPlacementActiveChange(_ active: Bool) {
        if active {
            guard let session = curbPlacement else { return }
            startCurbPlacementIndexBuild()
            coordinatorActions.beginPlacement(
                seed: session.seed,
                incumbentBlockfaceKey: session.incumbentBlockfaceKey,
                animated: session.animatedEntry
            )
            // The map view is not ready (no controller was created): abort rather than leave a
            // card up over a map that is not in the mode.
            guard coordinatorActions.isPlacementActive else {
                endCurbPlacement(restore: true)
                activeSheet = driveModeDefaultRestStateSheet()
                return
            }
            applyCurbPlacementBottomInset(curbPlacementCardHeight)
        } else {
            // Safety net: the session went away without going through endCurbPlacement - end
            // the map layer so taps can never stay disabled.
            switch CurbPlacementPolicy.healAction(sessionPresent: false, mapLayerActive: coordinatorActions.isPlacementActive) {
            case .endMapLayer:
                coordinatorActions.endPlacement(restore: true)
            case .none, .dropSession:
                break
            }
        }
    }

    /// Every exit funnels here (Cancel, commit, report, Drive entry, abort, conflicting sheet,
    /// scene heal). Camera first, through the A2 seam; then all SwiftUI-side session state; then
    /// the ambient-look and deferred-recenter bookkeeping (state only - NEVER a camera move: A2's
    /// `endPlacement` already restores / centres, and `applyAmbientDrivingLook` would issue a
    /// competing `setCamera`, PR #140 QA P2-1 (c)). Callers that leave the map set `activeSheet`
    /// themselves AFTER this returns.
    ///
    /// - Parameter restore: true = Cancel (exact prior camera); false = commit / hand off to the
    ///   report sheet (stay street-level on the placed point).
    private func endCurbPlacement(restore: Bool) {
        if coordinatorActions.isPlacementActive {
            coordinatorActions.endPlacement(restore: restore)
        }
        curbPlacementIndexGeneration += 1
        curbPlacementIndexBuilding = false
        curbPlacementIndex = nil
        curbPlacementLocatePending = false
        curbPlacementCardHeight = 0

        let adjusted = CurbPlacementPolicy.ambientUserAdjustedAfterExit(
            restored: restore,
            ambientLookInEffect: ambientDrivingLookInEffect,
            currentUserAdjusted: ambientLookUserAdjusted
        )
        if adjusted != ambientLookUserAdjusted { ambientLookUserAdjusted = adjusted }

        curbPlacement = nil

        // A deferred recenter (see `handleLocationUpdate`) has no fix scheduled to complete it:
        // ask for one single-shot fix so it is re-queued rather than waiting for an unrelated one.
        if CurbPlacementPolicy.shouldRequeueRecenterOnExit(
            requestedPending: recenterOnUserRequested,
            atLaunchPending: recenterOnUserAtLaunch
        ) {
            locationService.requestAndFetchLocation()
        }
    }

    /// Top-left Cancel: back to the exact prior camera and the rest-state sheet (NOT a literal
    /// `.browseNav` - DM-1's QA found that bug class twice).
    private func cancelCurbPlacement() {
        endCurbPlacement(restore: true)
        activeSheet = driveModeDefaultRestStateSheet()
    }

    /// Another sheet was presented over a live session (deep link, invite link, ...). Map
    /// interaction exists only here, never under a sheet: end the session, leave the new sheet.
    private var curbPlacementHasConflictingSheet: Bool {
        CurbPlacementPolicy.sheetConflicts(placementActive: curbPlacement != nil, activeSheetPresent: activeSheet != nil)
    }

    private func endCurbPlacementForConflictingSheet() {
        endCurbPlacement(restore: true)
    }

    /// Reconciles SwiftUI state with the map layer (scene becoming active). Both directions
    /// route through `endPlacement` / `endCurbPlacement`.
    private func healStuckCurbPlacement() {
        switch CurbPlacementPolicy.healAction(
            sessionPresent: curbPlacement != nil,
            mapLayerActive: coordinatorActions.isPlacementActive
        ) {
        case .none:
            break
        case .endMapLayer:
            coordinatorActions.endPlacement(restore: true)
        case .dropSession:
            endCurbPlacement(restore: true)
            activeSheet = driveModeDefaultRestStateSheet()
        }
    }

    // MARK: A3: snap index (lazy, off-main, generation-guarded)

    /// Builds the index for the CURRENT `tileLoader.segments` on a detached task. A newer build
    /// (or an exit) bumps `curbPlacementIndexGeneration`, so a stale result is discarded.
    private func startCurbPlacementIndexBuild() {
        curbPlacementIndexGeneration += 1
        let generation = curbPlacementIndexGeneration
        let segments = tileLoader.segments
        curbPlacementIndexBuilding = true
        Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) {
                CurbSnapIndex(segments: segments)
            }.value
            guard generation == curbPlacementIndexGeneration, curbPlacement != nil else { return }
            curbPlacementIndex = built
            curbPlacementIndexBuilding = false
            curbPlacementIndexVersion += 1
        }
    }

    /// `handleSegmentsChanged` hook: rebuild while a session is live.
    private func rebuildCurbPlacementIndexIfLive() {
        guard curbPlacement != nil else { return }
        startCurbPlacementIndexBuild()
    }

    /// `.onChange(of: curbPlacementIndexVersion)`: the swap has been published; re-resolve once
    /// AFTER it has rendered into the representable (A2 doc comment: the controller reads
    /// `placementIndex` off the representable, which only updates in `updateUIView`). Hopping a
    /// run-loop turn out of this `.onChange` pass keeps it out of the same pass that assigned
    /// the index. UNVERIFIED on device: Mac smoke "index race" (begin before tiles load).
    private func scheduleCurbPlacementRefresh() {
        guard curbPlacement != nil else { return }
        DispatchQueue.main.async {
            guard curbPlacement != nil else { return }
            coordinatorActions.refreshPlacement()
        }
    }

    /// The severity a segment is painted with right now (the highlight CORE colour).
    private func curbPlacementSeverity(for segment: Segment) -> CurrentState {
        engine.currentState(for: segment, at: .nowET)
    }

    // MARK: A3: outcomes, card and handoffs

    /// `onPlacementOutcome` (main queue; fires only on a blockface / outcome-kind change and on
    /// settle - never per frame, A23). One state write per call.
    private func handleCurbPlacementOutcome(_ outcome: CurbSnapOutcome) {
        guard var session = curbPlacement else { return }
        var opposite = false
        var needsNearestProbe = false
        switch outcome {
        case .snapped(let result):
            opposite = CandidateSegmentSearch.oppositeSideCandidate(of: result.segment, in: tileLoader.segments) != nil
            session.nearestCurb = nil
        case .noCurbInRange:
            needsNearestProbe = true
        }
        session.outcome = outcome
        session.oppositeSideLoaded = opposite
        curbPlacement = session
        if needsNearestProbe {
            // `handleRegionChanged` (which refreshes `region`) is hopped to the main queue by the
            // map layer right after the settle that produced this outcome; hop behind it so the
            // pin estimate below reads the settled region.
            DispatchQueue.main.async { updateCurbPlacementNearestCurb() }
        }
    }

    /// Spec A.3 "No curb in range": the nearest curb within 100 m, once per settle (wide-config
    /// recipe from `CurbSnapIndex.resolve`'s doc comment).
    private func updateCurbPlacementNearestCurb() {
        guard var session = curbPlacement, let index = curbPlacementIndex, let outcome = session.outcome else { return }
        switch outcome {
        case .snapped:
            return
        case .noCurbInRange:
            break
        }
        let pin = estimatedCurbPlacementPin()
        let probe = index.resolve(
            pin,
            incumbent: nil,
            metersPerPoint: 0.28,
            config: CurbSnapConfig(acquireRadius: CurbPlacementPolicy.nearestCurbProbeMeters,
                                   releaseRadius: CurbPlacementPolicy.nearestCurbProbeMeters)
        )
        session.nearestCurb = CurbPlacementPolicy.nearestCurb(from: pin, probe: probe)
        curbPlacement = session
    }

    /// DEVIATION (reported): A2 exposes no pin-coordinate seam, so where no snapped curb supplies
    /// a coordinate (the "No curb here" save, the nearest-curb chip) the pin is estimated from
    /// the map `region`. Exact for the mode's north-up flat camera; see
    /// `CurbPlacementPolicy.estimatedPinCoordinate`.
    private func estimatedCurbPlacementPin() -> CLLocationCoordinate2D {
        CurbPlacementPolicy.estimatedPinCoordinate(
            regionCenter: region.center,
            regionLatitudeDelta: region.span.latitudeDelta,
            tipHeightFraction: Double(CurbPlacementMapPolicy.tipHeightFraction)
        )
    }

    private func performCurbPlacementPrimary(_ action: CurbPlacementPrimaryAction) {
        guard let session = curbPlacement else { return }
        switch action {
        case .parkHere, .saveCarHere:
            commitCurbPlacementPark(session)
        case .next:
            openCurbPlacementReport(session)
        }
    }

    /// "Park here" / "Save car here": the EXISTING commit path. `ParkConfirmView` is skipped
    /// flag-on; `confirmPinDrop(result:)` is the only writer (A15), reminders default ON (the
    /// arrival path's precedent: toggle later in `ParkedCarDetailView`). The rest-state sheet is
    /// assigned BEFORE the save so a first-ever drop's `.notificationRationale` (set by
    /// `handleFirstPinDropped`) is not overwritten.
    private func commitCurbPlacementPark(_ session: CurbPlacementSession) {
        let target = CurbPlacementPolicy.parkTarget(
            outcome: session.outcome,
            fallbackPin: estimatedCurbPlacementPin()
        )
        endCurbPlacement(restore: false)
        activeSheet = driveModeDefaultRestStateSheet()
        let intent = PinDropIntent(
            pinLat: target.latitude,
            pinLng: target.longitude,
            detectedSegment: target.segment,
            detectedSegmentDistance: target.distanceMeters,
            alternativeCandidates: []
        )
        confirmPinDrop(result: PinConfirmResult(intent: intent, notifyOnRestriction: true))
    }

    /// "Next" (pill) and the quiet "Report something here" link (long-press): leave the mode,
    /// then open the existing chooser at the SNAPPED coordinate (fixed before the sheet exists -
    /// base spec 3.3 invariant). The street-closure tile keeps its unchanged
    /// `streetClosureHandoff`.
    private func openCurbPlacementReport(_ session: CurbPlacementSession) {
        let target = CurbPlacementPolicy.reportTarget(
            outcome: session.outcome,
            entry: session.entry,
            fallbackPin: estimatedCurbPlacementPin()
        )
        endCurbPlacement(restore: false)
        let candidates = target.segment.map {
            CandidateSegmentSearch.confirmStreetCandidates(for: $0, in: tileLoader.segments)
        } ?? []
        activeSheet = .reportPin(
            coord: target.coordinate,
            streetName: nil,
            segment: target.segment,
            confirmCandidates: candidates,
            coordinateSource: target.coordinateSource
        )
    }

    // MARK: A3: locate / chip / VoiceOver

    /// The card's locate button: the existing single-shot fix, never the drive posture. A cached
    /// fix moves the pin immediately; otherwise the fix, when it arrives, does
    /// (`consumeCurbPlacementLocateFix`). Mirrors `recenterOnUser()`'s coverage guard.
    private func locateInCurbPlacement() {
        guard curbPlacement != nil else { return }
        if let fix = locationService.userLocation {
            focusCurbPlacement(onFix: fix)
        } else {
            curbPlacementLocatePending = true
        }
        locationService.requestAndFetchLocation()
    }

    /// `handleLocationUpdate` hook: completes a locate request that had no cached fix.
    private func consumeCurbPlacementLocateFix(_ fix: CLLocationCoordinate2D) {
        guard curbPlacementLocatePending else { return }
        curbPlacementLocatePending = false
        guard curbPlacement != nil else { return }
        focusCurbPlacement(onFix: fix)
    }

    private func focusCurbPlacement(onFix fix: CLLocationCoordinate2D) {
        guard AppConstants.isInManhattanCoverage(fix) else {
            ToastService.shared.show(message: "Limited parking data outside Manhattan")
            return
        }
        coordinatorActions.focusPlacement(on: fix)
    }

    /// Lifts the Apple logo / Legal link above the card (design Finding 7). Called when the
    /// card's measured height changes - NEVER from inside a SwiftUI update (QA P2-5): it mutates
    /// UIKit layout state, so it hops one run-loop turn.
    private func applyCurbPlacementBottomInset(_ height: CGFloat) {
        guard height > 0 else { return }
        DispatchQueue.main.async {
            guard curbPlacement != nil, coordinatorActions.isPlacementActive else { return }
            coordinatorActions.setPlacementBottomInset(height)
        }
    }

    @ViewBuilder
    private var curbPlacementOverlay: some View {
        if let session = curbPlacement, !driveModeActive {
            let usesMetric = Locale.current.measurementSystem == .metric
            let model = CurbPlacementCardModel.make(
                outcome: session.outcome,
                intent: session.intent,
                communityEnabled: AppConstants.communityEnabled,
                engine: engine,
                now: .nowET,
                tilesLoaded: !tileLoader.segments.isEmpty,
                indexRefreshing: curbPlacementIndexBuilding,
                oppositeSideLoaded: session.oppositeSideLoaded,
                nearestCurb: session.nearestCurb,
                usesMetricSystem: usesMetric
            )
            CurbPlacementOverlay(
                model: model,
                showsHint: session.showsHint,
                usesMetricSystem: usesMetric,
                topPadding: paddingForBannerState(bannerState),
                tipFraction: CurbPlacementMapPolicy.tipHeightFraction,
                onPrimary: { action in performCurbPlacementPrimary(action) },
                onSecondary: {
                    // Read the LIVE session (the outcome may have settled since this body ran).
                    if let live = curbPlacement { openCurbPlacementReport(live) }
                },
                onCancel: { cancelCurbPlacement() },
                onLocate: { locateInCurbPlacement() },
                onNearestCurb: { curb in coordinatorActions.focusPlacement(on: curb.coordinate) },
                onCycleCurb: { coordinatorActions.cyclePlacementCurb() },
                onCardHeightChange: { height in
                    curbPlacementCardHeight = height
                    applyCurbPlacementBottomInset(height)
                }
            )
        }
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

    /// Open item #17 (2026-09-11): which UI a resting long-press should drive, purely as a
    /// function of the community flag. Extracted as a `nonisolated static` pure decision —
    /// same "extract the decision, not just the data lookup" pattern as
    /// `communityMapChromeVisible`/`resolveHomeZoneId` above — so the flag fork is directly
    /// unit-testable without a live `ContentView` instance.
    ///
    /// `.legacyThreeButtonDialog`: flag OFF. The confirmationDialog with all three actions
    /// ("Park my car here" / "Report enforcement or sweeper" / "Report closure") — byte-
    /// identical to pre-#17 behavior. This is still the ONLY report entry point for flag-off
    /// users, so it is never slimmed or removed.
    ///
    /// `.parkConfirmCard`: flag ON. Reporting has its own dedicated entry (S13a Report pill
    /// + grid), so the long-press popup slims to a single-purpose park confirmation —
    /// `longPressParkConfirmOverlay`.
    enum LongPressPresentation: Equatable {
        case legacyThreeButtonDialog
        case parkConfirmCard
    }

    nonisolated static func longPressPresentationMode(communityEnabled: Bool) -> LongPressPresentation {
        communityEnabled ? .parkConfirmCard : .legacyThreeButtonDialog
    }

    /// Open item #17b (2026-09-12) root-cause fix: pure id-comparison deciding whether
    /// `handleLongPress(at:)` should actually write `activeSheet`, rather than
    /// unconditionally reassigning it (even to its own current value) on every long-press.
    /// `ActiveSheet` is `Identifiable` but not `Equatable` — comparing by `.id` is the only
    /// cheap way to detect "this would be a no-op write" without giving every case a
    /// `Segment`/`PinDropIntent`-driven `Equatable` conformance just for this one check.
    /// See `handleLongPress(at:)`'s doc comment for the full mechanism this guards against.
    nonisolated static func shouldReassignActiveSheet(current: ActiveSheet?, target: ActiveSheet?) -> Bool {
        current?.id != target?.id
    }

    /// Open item #17 residual (2026-09-11): pure gate for the coordinate handed to
    /// `MapViewRepresentable.pendingParkCoordinate` — the tentative "car will go here" marker
    /// must NEVER render for flag-off builds, regardless of `pendingLongPressCoord`'s state,
    /// because `pendingLongPressCoord` is also set (unconditionally) by the legacy
    /// three-button-dialog long-press flow that flag-off users still see
    /// (`handleLongPress(at:)`). Extracted as a pure, unit-testable function — same
    /// "extract the flag gate, test the decision" pattern as
    /// `longPressPresentationMode(communityEnabled:)` above.
    nonisolated static func pendingParkPinCoordinate(
        communityEnabled: Bool,
        pendingLongPressCoord: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        communityEnabled ? pendingLongPressCoord : nil
    }

    /// Handles a long-press gesture on the map.
    ///
    /// Behavior is context-dependent:
    ///   - `driveModeActive == true`: long-press is suppressed (no-op). The in-drive
    ///     Report button is the driving-safe entry path. Suppressing the gesture avoids
    ///     accidental park-pin drops while maneuvering (spec §4.1).
    ///   - `driveModeActive == false`: captures the coordinate and shows the resting
    ///     popup — `longPressPresentationMode(communityEnabled:)` decides which one (see
    ///     its own doc comment). Candidate-segment detection is deferred until the user
    ///     picks "Park" — no wasted work if they cancel or (flag-off only) pick "Report"
    ///     (spec §4.1 note).
    ///
    /// Open item #17b (2026-09-12) root cause: the legacy flag-off path drives
    /// `.confirmationDialog(isPresented: $showRestingActionMenu)` — a SEPARATE presentation
    /// `Bool` from `pendingLongPressCoord`. This function used to write
    /// `selectedSegmentID`/`activeSheet` UNCONDITIONALLY on every call, even on the (by far
    /// most common) resting long-press where both were already at their target value
    /// (`nil` / `.browseNav`). `ActiveSheet` is `Identifiable` but NOT `Equatable`, so
    /// SwiftUI cannot short-circuit a same-value reassignment — every write, no-op or not,
    /// invalidates `mapLayerWithEvents`, the SAME view both `.sheet(item: $activeSheet)`
    /// AND `.confirmationDialog(isPresented: $showRestingActionMenu)` are attached to.
    /// Landing that invalidation in the SAME transaction as `showRestingActionMenu = true`
    /// races the dialog's own UIKit `present(_:animated:)` call against the sheet
    /// modifier's re-evaluation — the alert controller's presentation request silently
    /// drops, reproducing the exact "presents then instantly vanishes" symptom the S13c
    /// `.ended`-vs-`.began` fix already solved for TOUCH timing, but from a completely
    /// different mechanism (concurrent `@State` writes, not the finger still being down).
    /// The SECOND long-press works because `selectedSegmentID`/`activeSheet` are already at
    /// their target values from the first attempt, so that retry's only actual state change
    /// is `showRestingActionMenu = true` — no competing sibling write, dialog presents
    /// cleanly. The flag-on card path never hits this: `pendingLongPressCoord != nil` drives
    /// a plain `if` in the view body (`longPressParkConfirmOverlay`), a conditional render,
    /// not a UIKit presentation-controller transition — nothing to race.
    ///
    /// Fix: only write `selectedSegmentID`/`activeSheet` when they would actually change,
    /// mirroring the guard idiom the `.sheet(item:)` `onDismiss` closure above already uses
    /// for `selectedSegmentID` (`if selectedSegmentID != nil { selectedSegmentID = nil }`)
    /// for this identical reason. `shouldReassignActiveSheet(current:target:)` is the pure,
    /// unit-testable id-comparison this reuses (`ActiveSheet.id` exists precisely because
    /// the type isn't `Equatable`). Applies to BOTH presentation paths — the card path was
    /// never broken by this, but the guard is unconditional plumbing, not flag-gated, so it
    /// stays correct after the flag flip too.
    private func handleLongPress(at coordinate: CLLocationCoordinate2D) {
        // While driving, long-press is intentionally a no-op (spec §4.1).
        // FT-15/TF2-15: also a no-op while block-select mode is active — a long-press
        // mid-selection (e.g. "Park my car here") would be a confusing second exclusive
        // interaction mode layered on top of the first. The user exits block-select via
        // the floating bar's Cancel/Continue before any other long-press action is available.
        guard !driveModeActive, !blockSelectModeActive else { return }

        // A3 (curb-pin placement), spec A.7: flag-on, a resting long-press enters placement
        // centred on the pressed point (intent `.plant`) - and a long-press during spot
        // placement / an already-live session is a no-op (A22). Flag-off `.legacy` falls
        // straight through to the unmodified code below.
        switch curbPlacementRouting(for: .longPress) {
        case .placement:
            beginCurbPlacement(entry: .longPress, seed: coordinate)
            return
        case .ignore:
            return
        case .legacy:
            break
        }

        // Clear any current selection and dismiss any open sheet before showing the popup —
        // but ONLY if either is not already at its target value (open item #17b — see this
        // function's doc comment above for why an unconditional write here raced the
        // confirmationDialog's own presentation).
        // FT-20 Stream A: the guard above guarantees driveModeActive/blockSelectModeActive
        // are both false here, so dismissTargetOutsideBrowseNav always resolves to
        // `.browseNav` — using the shared helper (not a literal `nil`) so the browse sheet
        // correctly reappears once the popup is dismissed, rather than leaving the map with
        // no chrome at all (`.browseNav` is browse mode's persistent rest state now, not
        // "nothing" — spec §4.1).
        if selectedSegmentID != nil {
            selectedSegmentID = nil
        }
        let targetSheet = dismissTargetOutsideBrowseNav
        if Self.shouldReassignActiveSheet(current: activeSheet, target: targetSheet) {
            activeSheet = targetSheet
        }

        // Capture the coordinate unconditionally — both presentations read it.
        pendingLongPressCoord = coordinate

        // Open item #17: flag-off keeps the legacy confirmationDialog (below, in `body`),
        // byte-identical to before this change. Flag-on shows nothing here —
        // `longPressParkConfirmOverlay` renders directly off `pendingLongPressCoord` once
        // `AppConstants.communityEnabled` is true, no separate presentation flag needed.
        switch Self.longPressPresentationMode(communityEnabled: AppConstants.communityEnabled) {
        case .legacyThreeButtonDialog:
            showRestingActionMenu = true
        case .parkConfirmCard:
            break
        }
    }

    /// Shared "Park my car here" / "Park here" logic — the W5 candidate-segment lookup +
    /// `PinDropIntent` construction, used by BOTH the flag-off confirmationDialog's "Park my
    /// car here" button (`body`) and the flag-on `longPressParkConfirmOverlay` card's "Park
    /// here" button, so both presentations stay behaviorally identical for this action.
    /// Extracted by open item #17; not a behavior change for the flag-off caller — same
    /// statements, same order, just named and shared instead of duplicated inline.
    private func confirmLongPressPark(at coord: CLLocationCoordinate2D) {
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

    // MARK: - W5: "Park here →" Path B (from BlockDetailView)

    private func initiatePathBPinDrop(from segment: Segment) {
        // A3 (curb-pin placement), spec A.7: flag-on, "Park here ->" enters placement at the
        // block's midpoint with THAT blockface as the incumbent (intent `.parkBlock`). The
        // arrival prompt and the in-drive "Park here" are different code paths and are not
        // touched (AC-A28). Flag-off / blocked: `.legacy`, the original body below.
        if startCurbPlacementIfRouted(
            entry: .pathB,
            seed: segment.midpoint ?? segment.coordinates.first,
            incumbentBlockfaceKey: segment.blockfaceKey
        ) { return }
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
    ///   4. rebuildOverlays(at:) — force the curb-line renderers to refresh at Drive-Mode
    ///      width (open item #19 QA Finding #1, see below).
    ///
    /// EXIT order:
    ///   1. handleDriveCameraChange(false) — restore pre-drive pitch + zoom + style.
    ///   2. handleDriveModeChange(false) — stop location services, clear context, clear followPaused.
    ///   3. rebuildOverlays(at:) — restore browse-width curb lines immediately.
    ///
    /// Open item #19 QA Finding #1 (PR #107 pass 1, `docs/qa/pr107-polish.md`): `mapView(_:
    /// rendererFor:)` reads `parent.driveModeActive` to pick browse vs. Drive-Mode width, but
    /// MapKit only invokes that delegate method once PER OVERLAY OBJECT and caches the
    /// resulting renderer — so merely flipping `driveModeActive` does nothing to lines whose
    /// `TaggedMultiPolyline` objects already exist. `applyOverlayPayload` (`MapViewRepresentable
    /// .swift`) is the ONLY code path that actually forces a re-query: it unconditionally
    /// `removeOverlay`s the old 5 groups and `addOverlay`s brand-NEW `TaggedMultiPolyline`
    /// instances, which MapKit has never seen before and must call `rendererFor:` on fresh.
    /// `rebuildOverlays(at:)` is what triggers that (via `overlayGeneration`/`overlayPayload`,
    /// diffed in `updateUIView`) — the SAME path the 60s timer tick already uses, reused
    /// here rather than duplicated. This mirrors the codebase's own established pattern for
    /// this exact problem: `refreshUserLocationPuck` (called from `handleDriveCameraChange`
    /// below) forces MapKit to re-query `mapView(_:viewFor:)` for the SAME reason — a
    /// `driveModeActive`-dependent delegate branch needs an explicit invalidation to actually
    /// re-fire, reading the flag alone isn't enough. No new pure logic to extract/test here —
    /// this is UIKit delegate-caching plumbing (which method gets re-invoked when), not a
    /// decision with inputs/outputs; `rebuildOverlays(at:)` itself is already exercised by
    /// existing tests via its callers' effects (`overlayGeneration` incrementing).
    ///
    /// Architecture: all calls fire from `.onChange(of: driveModeActive)` — OUTSIDE `updateUIView`.
    /// No camera mutation or `userTrackingMode =` assignment inside `updateUIView`. #31 invariant maintained.
    ///
    /// Architecture invariant: no camera mutation (setCamera, setRegion, userTrackingMode =)
    /// happens inside updateUIView. All camera mutations are driven from .onChange handlers
    /// in ContentView or from MapKit delegate callbacks.
    private func handleDriveModeAndCamera(_ active: Bool) {
        // A3 (curb-pin placement), PR #140 QA #4 / (d): Drive Mode entry tears a live placement
        // session down THROUGH `endPlacement` (the entry guard makes this unreachable through the
        // UI; this is the self-healing backstop, same role as the block-select clear below). A
        // stuck session would leave the map ignoring taps. Never true flag-off.
        if active && curbPlacement != nil {
            endCurbPlacement(restore: true)
        }
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
            // deliberate auto-fire must win, not get silently overwritten back to the rest
            // state. Same "don't clobber an already-reassigned sheet" guard the top-level
            // `.sheet(item:, onDismiss:)` backstop already uses for the identical reason
            // (see that closure's own comment in `body`).
            //
            // DM-2 (`docs/drive-mode-default-spec.md` §0.4, QA pass 1 on PR #130 — the
            // "two more literal `.browseNav` restore sites" finding, second of two): routes
            // through `driveModeDefaultRestStateSheet()` instead of hardcoding `.browseNav`,
            // same fix as the `.sheet(item:, onDismiss:)` backstop above. Flag off:
            // unchanged (`.browseNav`). Flag on: exiting Drive Mode lands on the genuinely
            // sheet-free ambient home screen (AC-6), not back into `.browseNav` — even
            // though this case is literally named `.browseNavAtPeek` (kept as-is; renaming
            // it would be a drive-by refactor of `browseSheetBoundaryTarget`'s enum, not
            // required by any AC).
            if activeSheet == nil {
                activeSheet = driveModeDefaultRestStateSheet()
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

        // Open item #19 QA Finding #1: force the curb-line overlays to rebuild on EVERY
        // toggle direction, so `mapView(_:rendererFor:)` is re-invoked against fresh
        // overlay objects and picks up the correct browse/Drive-Mode width immediately —
        // see this function's own doc comment above for the full mechanism. Reuses
        // `lastEvaluatedAt` rather than re-stamping `.now`, matching `handleSegmentsChanged`/
        // `handleSelectionChanged`'s existing convention (only the 60s timer tick itself
        // advances `lastEvaluatedAt`) — this rebuild is about the WIDTH, not about
        // re-evaluating which segments are currently free/restricted.
        rebuildOverlays(at: lastEvaluatedAt)
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
        // A3: new tiles arrived mid-session - rebuild the snap index (off-main, generation
        // token). No-op unless a session is live (always, flag-off).
        rebuildCurbPlacementIndexIfLive()
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
    /// Called from the filter-active pill's "x" button, the skip handler, and — DM-2 (§0.8.8,
    /// AC-27) — `toggleFullPaletteMode()`'s "turn full-palette ON" branch, for which this
    /// function's existing behavior IS the spec'd behavior verbatim ("functionally identical
    /// to today's already-shipped clearParkUntilFilter()").
    private func clearParkUntilFilter() {
        parkUntilMode = false
        parkUntilTarget = nil
        // DM-2: reset both goal-driven fields so a stale value can never leak into whatever
        // sets `parkUntilMode`/`parkUntilTarget` next (the custom `ParkUntilSheet`, or a
        // later goal re-selection, which overwrites them fresh anyway).
        parkUntilIgnoresMeteredPayment = false
        parkAndForgetGuardState = nil
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

    // MARK: - S7 LIVE-GATE FIX: route a wepark://invite/<uuid> deep link

    /// `.onOpenURL`'s entry point (moved here from `WeParkApp.swift` — see
    /// `ActiveSheet.regularsInviteRedemption`'s own doc comment for the full root-cause
    /// writeup of why the sheet has to be presented from THIS file, through the single
    /// `.sheet(item: $activeSheet)` host, rather than a second independent `.sheet` modifier).
    ///
    /// `RegularsInviteLink.resolveRedemptionToken(from:)` is the ENTIRE gate: it folds in
    /// `AppConstants.regularsEnabled` (defaults to the real flag; `false` today) and strict
    /// URL validation (wrong scheme/host, non-UUID token, extra path segments) in one call — a
    /// malformed/foreign URL, or ANY url at all while the flag is off, resolves to `nil` and
    /// this function does nothing (no `activeSheet` mutation, no state touched at all).
    ///
    /// Deliberately UNCONDITIONAL once a valid token resolves — no `guard activeSheet ==
    /// nil`/`== .browseNav` check, matching `routePendingDeepLink(_:)`'s own precedent for
    /// `.parkedCarDetail` immediately above. Opening an invite link is exactly as deliberate a
    /// user action as tapping a notification; whatever sheet was already showing (browse sheet
    /// at any detent, block detail, My Car, anything) is preempted, not silently dropped —
    /// this is what makes the redemption sheet present reliably from every app state, not just
    /// the map's rest state.
    ///
    /// - Parameter url: The URL passed to `.onOpenURL` (Camera-app QR scan, a tapped
    ///   share-link, AirDrop, etc. — anything that can open this app via its registered
    ///   `wepark://` scheme, `Info.plist`'s `CFBundleURLTypes`).
    private func routeRegularsInviteRedemption(_ url: URL) {
        guard let token = RegularsInviteLink.resolveRedemptionToken(from: url) else { return }
        activeSheet = .regularsInviteRedemption(token: token)
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
///
/// A3 (curb-pin placement): trailing `curbPlacementActive` (default `false` = byte-identical to
/// before) hides the rail for the duration of the mode.
func recenterButtonStackVisible(
    driveModeActive: Bool,
    blockSelectModeActive: Bool,
    curbPlacementActive: Bool = false
) -> Bool {
    !driveModeActive && !blockSelectModeActive && !curbPlacementActive
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

// MARK: - DM-1: Drive-mode-default rest-state sheet target

/// The rest-state `ActiveSheet` target when neither Drive Mode nor FT-15 block-select is
/// forcing a hide — i.e. what `activeSheet` defaults to at cold launch, and what
/// `dismissTargetOutsideBrowseNav` resolves to once those two force-hide cases are ruled
/// out. Both call sites read this SAME function so they can never drift apart (spec §0.4:
/// "Both the initial `@State` and this rest-state target must flip together, or this ships
/// half-converted").
///
/// `driveModeDefaultEnabled == false` (today's shipped default): `.browseNav`,
/// byte-identical to pre-DM-1 behavior (`docs/drive-mode-default-spec.md` §5 AC-1).
/// `== true`: `nil` — the ambient home screen's genuinely sheet-free rest state (§0.4).
///
/// Extracted as a pure function — `ActiveSheet` isn't `Equatable` (several cases carry
/// non-Equatable associated payloads), so tests pattern-match the `.browseNav` case or
/// `XCTAssertNil` directly rather than `==` — same discipline as `browseSheetBoundaryTarget`
/// above. This is a dark-ship guard today (`DriveModeDefaultFlagTests`); at flip time its
/// `true`-branch assertion becomes the launched-world assertion per the PR #109 playbook
/// (`docs/community-2.0-roadmap.md`'s "4 dark-ship guard tests transformed into
/// launched-world assertions").
///
/// `nonisolated` explicitly: this file compiles under `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, which would otherwise implicitly main-actor-isolate this top-level func; the
/// guard tests in `DriveModeDefaultFlagTests` call it synchronously from plain (non-async,
/// non-`@MainActor`) XCTestCase methods, so it needs to stay callable off the main actor —
/// same reasoning as `AppConstants`'s own `nonisolated static func` flag-gating helpers
/// (`communityPhase1PinTypes`, `regularsSettingsRowVisible`, etc., `Services/Constants.swift`).
nonisolated func driveModeDefaultRestStateSheet(
    driveModeDefaultEnabled: Bool = AppConstants.driveModeDefaultEnabled
) -> ActiveSheet? {
    driveModeDefaultEnabled ? nil : .browseNav
}

// MARK: - DM-3: Location-priming card gating

/// Whether to show `LocationPrimingCard` on the ambient home screen's first-ever render
/// (`docs/drive-mode-default-spec.md` §0.2, AC-9). True only when all three hold:
///   1. `driveModeDefaultEnabled` — the card is part of the ambient/goal-first experience;
///      it has no reason to render while the FT-20 browse sheet is still the default (AC-2).
///   2. `gateShouldShow` — the one-shot `LocationPrimingCardGate` has never fired on this
///      device. Injected as a plain `Bool` (not the gate itself) so this function stays pure
///      and `UserDefaults`-free — same shape as `driveModeDefaultRestStateSheet` above and
///      `AppConstants`'s `nonisolated static func` flag-gating helpers
///      (`communityPhase1PinTypes`, `regularsSettingsRowVisible`, etc.).
///   3. `authorizationStatus == .notDetermined` — an already-authorized or already-denied
///      user has nothing left to be "primed" for; the card only ever targets the undecided
///      case (spec §0.2: "shown only when `locationService.authorizationStatus ==
///      .notDetermined`").
///
/// `nonisolated` for the same reason `driveModeDefaultRestStateSheet` is: this file compiles
/// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and `DM3PrimingAuthTests` calls this
/// synchronously from plain (non-async, non-`@MainActor`) XCTestCase methods.
nonisolated func locationPrimingCardShouldShow(
    driveModeDefaultEnabled: Bool,
    gateShouldShow: Bool,
    authorizationStatus: CLAuthorizationStatus
) -> Bool {
    driveModeDefaultEnabled && gateShouldShow && authorizationStatus == .notDetermined
}

// MARK: - DM-3: Cruise-entry authorization routing

/// The action `enterCruiseMode()` must take for a given authorization status, evaluated
/// BEFORE any `driveModeActive = true` escalation (`docs/drive-mode-default-spec.md` §0.2,
/// AC-11). Mirrors `BrowseSearchAreaView.handleGoTap()`'s existing switch over the same three
/// outcomes for destination-mode Drive's own auth gate (`BrowseSearchAreaView.swift:651-664`)
/// — Cruise entry had no equivalent gate at all before this fix (the exact gap §0.2
/// describes: tapping while `.notDetermined` silently did nothing — no prompt, no error, no
/// visible cause).
enum CruiseEntryAuthAction: Equatable {
    /// Already authorized — proceed into the escalation exactly as today (regression guard).
    case proceed
    /// `.notDetermined` — fire the real system prompt first; do NOT escalate this tap.
    case requestFirst
    /// `.denied`/`.restricted` — surface the denied-state alert; do NOT escalate.
    case showDeniedAlert
}

/// `nonisolated` for the same reason `driveModeDefaultRestStateSheet`/
/// `locationPrimingCardShouldShow` above are.
nonisolated func cruiseEntryAuthAction(for status: CLAuthorizationStatus) -> CruiseEntryAuthAction {
    switch status {
    case .notDetermined:
        return .requestFirst
    case .denied, .restricted:
        return .showDeniedAlert
    case .authorizedWhenInUse, .authorizedAlways:
        return .proceed
    @unknown default:
        // Matches `BrowseSearchAreaView.handleGoTap()`'s own `@unknown default` precedent:
        // treat an unrecognized future case as the authorized path rather than blocking entry.
        return .proceed
    }
}

// MARK: - DM-2: Goal-first ambient dock visibility

/// Whether the ambient goal-first dock (full-palette toggle + "Start Driving" + goal tiles,
/// `GoalSelectorView`) mounts at ALL (`docs/drive-mode-default-spec.md` §0.8.7, design doc
/// §2.1/§6 flag #4) — independent of which of its own rows end up rendering. Ambient-only:
/// excludes Drive Mode, FT-15 block-select, and spot-placement mode, the SAME exclusion list
/// `recenterButtonStackVisible`/`communityMapChromeVisible` already use. Also excludes any
/// OTHER sheet being presented (`activeSheetIsNil`) — the dock lives inside
/// `bottomSafeAreaContent`, a `.safeAreaInset` that renders BEHIND a modally-presented sheet
/// (see `communityMapChromeOverlay`'s own doc comment on that same z-order fact); hiding the
/// dock whenever ANY sheet is up (including `.browseNav`, reachable via the persistent
/// Search icon) avoids it being spatially obscured by, or tap-colliding with, that sheet's
/// own background-interactive region at peek/medium — the exact "collide with the FT-20
/// detent machinery" risk the dispatch for this stream calls out by name.
///
/// `nonisolated` for the same sync-XCTest reason every other pure decision function in this
/// file is (`recenterButtonStackVisible`, `communityMapChromeVisible`, etc.).
///
/// A3 (curb-pin placement): trailing `curbPlacementActive` (default `false` = byte-identical to
/// before). The mode sets `activeSheet = nil`, so without this the dock would mount under the
/// placement card (DM-2 goal-first screen included).
nonisolated func goalSelectorDockVisible(
    driveModeDefaultEnabled: Bool,
    activeSheetIsNil: Bool,
    driveModeActive: Bool,
    blockSelectModeActive: Bool,
    spotPlacementActive: Bool,
    curbPlacementActive: Bool = false
) -> Bool {
    driveModeDefaultEnabled && activeSheetIsNil && !driveModeActive
        && !blockSelectModeActive && !spotPlacementActive && !curbPlacementActive
}

/// Whether the goal-TILE row specifically is showing (design doc §2.2/§2.4) — the dock
/// container is mounted (`goalSelectorDockVisible`) AND the user hasn't toggled to
/// full-palette. This is ALSO exactly the condition under which the legacy `ParkUntilPill`
/// row must be suppressed (design doc §6 flag #1 — the double-render bug: once Overnight is
/// pre-selected by default, `parkUntilMode` is true at rest 100% of the time, so the old pill
/// would otherwise render simultaneously with the new goal-tile dock, duplicating "a filter
/// is active" in two different UI languages at once).
nonisolated func goalTileRowVisible(
    driveModeDefaultEnabled: Bool,
    activeSheetIsNil: Bool,
    fullPaletteMode: Bool,
    driveModeActive: Bool,
    blockSelectModeActive: Bool,
    spotPlacementActive: Bool,
    curbPlacementActive: Bool = false
) -> Bool {
    goalSelectorDockVisible(
        driveModeDefaultEnabled: driveModeDefaultEnabled,
        activeSheetIsNil: activeSheetIsNil,
        driveModeActive: driveModeActive,
        blockSelectModeActive: blockSelectModeActive,
        spotPlacementActive: spotPlacementActive,
        curbPlacementActive: curbPlacementActive
    ) && !fullPaletteMode
}

/// Whether `recenterButtonStack`'s power-user clock-icon button (§0.8.9) should render.
/// Hidden while the goal-first dock owns the filter (`driveModeDefaultEnabled &&
/// !fullPaletteMode`) — design doc §2.6's "Concrete gating note for the clock-icon button":
/// §0.8.9 says that sheet "is not reachable directly from the goal-first home screen," and
/// this is the literal code edit that makes that true. Visible in every other combination:
/// flag off (today's shipped behavior, unchanged), or flag on + the user has toggled to
/// full-palette mode (§0.8.9's power-user path reappears exactly as described).
nonisolated func parkUntilClockButtonVisible(
    driveModeDefaultEnabled: Bool,
    fullPaletteMode: Bool
) -> Bool {
    !driveModeDefaultEnabled || fullPaletteMode
}

// MARK: - Addendum 3: ambient rail Recenter visibility (A3.2)

/// Whether the flag-on ambient rail's third, conditional circle (Recenter) shows right now
/// (`docs/design/goal-first-ambient-design.md` Addendum 3 A3.2, flag-on UI only — the caller
/// is `ContentView.ambientRail`). It appears "when needed, not before":
///   - `.notDetermined`: always — it is the route to the system permission prompt
///     (`recenterOnUser()` -> `requestAndFetchLocation()`).
///   - authorized (`.authorizedWhenInUse`/`.authorizedAlways`): only when there IS a fix and
///     the user's dot lies OUTSIDE the central 50% of the visible map (i.e. more than a
///     quarter of the visible span away from the region center on either axis) — the user has
///     panned away. No fix yet: hidden (there is no dot to return to; a fix arriving later
///     re-evaluates this on the next render).
///   - `.denied`/`.restricted`: hidden — recentering cannot work, and Start Driving already
///     routes denied users to the Location Settings alert.
/// **A3.6 (tilted ambient driving look):** `userDotOutsideCentralHalfOnScreen` is the same
/// "outside the central 50%" question answered in SCREEN space by
/// `AmbientDrivingLook.userDotOutsideCentralHalf` (via `MKMapView.convert`). When non-nil it
/// replaces the lat/lng region test for the authorized-with-fix case, because a pitched or
/// rotated camera's `region` bounding box is skewed (its center drifts toward the far edge and
/// its span over-reports the near field). nil keeps the region test exactly as before, so
/// flag-off and all pre-A3.6 callers are unchanged. Auth gating is never overridden.
/// Pure so the rule is directly unit-testable; `nonisolated` for the same sync-XCTest reason
/// every other pure decision function in this file is.
nonisolated func ambientRecenterButtonVisible(
    authorizationStatus: CLAuthorizationStatus,
    userLocation: CLLocationCoordinate2D?,
    visibleRegion: MKCoordinateRegion,
    userDotOutsideCentralHalfOnScreen: Bool? = nil
) -> Bool {
    switch authorizationStatus {
    case .notDetermined:
        return true
    case .authorizedWhenInUse, .authorizedAlways:
        guard let user = userLocation else { return false }
        // A3.6: under the tilted ambient driving look the lat/lng bounding box below is the
        // wrong yardstick (its center and span are skewed by pitch), so when the caller has
        // measured the dot in SCREEN space (`AmbientDrivingLook.userDotOutsideCentralHalf`),
        // that measurement wins. nil (not yet measured / flag off) keeps the region test, so
        // flag-off and every pre-A3.6 caller behave exactly as before.
        if let onScreen = userDotOutsideCentralHalfOnScreen {
            return onScreen
        }
        let latOffset = abs(user.latitude - visibleRegion.center.latitude)
        let lngOffset = abs(user.longitude - visibleRegion.center.longitude)
        let insideCentralHalf = latOffset <= visibleRegion.span.latitudeDelta * 0.25
            && lngOffset <= visibleRegion.span.longitudeDelta * 0.25
        return !insideCentralHalf
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

// MARK: - DM-2: Park & Forget viewport resolution (§0.8.9/§0.8.10)

/// Result of resolving Park & Forget's single GLOBAL rung from the viewport's currently
/// loaded segments. `offsetDays` is always one of `ParkingGoals.parkAndForgetLadderOffsetDays`
/// (8, 4, or 2) — the COLOR BUCKET's own target, unaffected by this fix (QA pass 1 on PR
/// #133 confirmed the monotonic top-down "first rung anyone clears" walk is sound and
/// should stay as-is). `steppedDown == true` means the "showing the best available" banner
/// (§0.8.10) must show — see `resolveParkAndForgetViewport`'s doc comment for how this is
/// now computed (density-aware, not purely positional). `.empty` is the true worst case:
/// even the bottom (easiest) rung has zero matches anywhere in the viewport.
enum ParkAndForgetViewportResolution: Equatable {
    case resolved(offsetDays: Int, steppedDown: Bool)
    case empty

    /// §0.8.10 fast-follow (QA pass 1 on PR #133, Finding #1 — promoted to FIX-THEN-MERGE
    /// by the orchestrator, since §0.8.10 names this banner "not optional polish, it's the
    /// guardrail"): the minimum fraction of the viewport's BOTTOM-rung (easiest) match
    /// count the PICKED rung must also clear before the banner is suppressed. Below this,
    /// the banner fires even when the picked rung is technically the TOP rung — without
    /// this, a single lonely metered-only/unregulated segment (§0.8.2's own cited 9.2% of
    /// parkable curb, present in nearly every real viewport) could silently "clear the top
    /// rung" and suppress the banner for an otherwise almost-entirely-red map, exactly the
    /// "reads as broken" failure mode §0.8.10 calls this amendment's single biggest new
    /// risk.
    ///
    /// Tunable, not derived — 0.25 is a starting knob (QA's own suggested ballpark), not
    /// backed by tile-data analysis the way the ladder's own `offsetDays` rungs are.
    /// Revisit with real usage data once this ships live. Exposed as
    /// `resolveParkAndForgetViewport`'s own defaulted parameter (not hardcoded inline) so
    /// tests can probe the boundary directly.
    ///
    /// Namespaced as a `static let` on this enum (matching `ParkingGoals`'s own convention
    /// for its tunable constants, e.g. `freeOvernightOffsetDays`) rather than a bare
    /// top-level constant — this file has no existing precedent for a module-scope `let`
    /// under its `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting, so this avoids
    /// introducing an untested isolation shape.
    nonisolated static let defaultBannerDensityThreshold: Double = 0.25
}

/// Walks `ladderOffsetDays` top rung (widest/hardest) first, returning the FIRST rung at
/// which AT LEAST ONE loaded segment clears (§0.8.9: "the date of the highest rung the
/// overall viewport's segments collectively clear") — this picks the COLOR BUCKET's target,
/// unchanged by the Finding #1 fix below. This is monotonic by construction — a segment
/// that clears the 8-day window necessarily also clears the narrower 4-day and 2-day
/// sub-windows starting at the same `from` (the move-forcing predicate only ever accumulates
/// restrictions as the window widens, never sheds them) — so match-counts are
/// non-decreasing as the rung narrows, and this simple top-down "does ANYONE clear this rung
/// yet" walk is a valid simplification of "highest rung collectively cleared."
///
/// **`steppedDown` (the BANNER trigger, §0.8.10) is density-aware, not purely positional**
/// (QA pass 1 on PR #133, Finding #1 fix): fires whenever EITHER (a) the picked rung
/// literally isn't the top rung (unchanged, pre-existing, QA-confirmed-correct — a real
/// step-down always shows the banner), OR (b) the picked rung IS the top rung but the
/// fraction of the viewport clearing it, relative to the bottom (easiest) rung's own match
/// count, falls below `bannerDensityThreshold` — i.e. "technically someone clears the top
/// rung, but almost nobody else does" no longer silently suppresses the banner. Every
/// rung's match COUNT is computed up front (not just a boolean) specifically to make this
/// density comparison possible.
///
/// `ignoringMeteredPayment: true` always — Park & Forget shares Free Overnight's
/// metered-tolerant predicate (§0.8.4) regardless of caller, same as
/// `ParkingGoals.ignoresMeteredPayment(for: .parkAndForget)`.
///
/// `nonisolated` — same sync-XCTest reason as every other pure function in this file;
/// `segments`/`engine` are passed in explicitly so this is directly testable with a small
/// synthetic segment array, no live `ContentView`/`TileLoader` needed.
nonisolated func resolveParkAndForgetViewport(
    segments: [Segment],
    from: Date,
    engine: ParkingRulesEngine,
    ladderOffsetDays: [Int] = ParkingGoals.parkAndForgetLadderOffsetDays,
    bannerDensityThreshold: Double = ParkAndForgetViewportResolution.defaultBannerDensityThreshold
) -> ParkAndForgetViewportResolution {
    // Match COUNT at every rung (not just "did anyone clear it") — the input the density
    // check below needs. `ladderOffsetDays` is ordered widest-first, so `counts[0]` is the
    // top rung's count and `counts.last` is the bottom (easiest) rung's count.
    let counts: [Int] = ladderOffsetDays.map { offsetDays in
        let until = from.startOfDayET(offsetDays: offsetDays)
        return segments.reduce(0) { total, segment in
            guard segment.coordinates.count >= 2 else { return total }
            let clears = engine.isFree(
                segment: segment, from: from, until: until, ignoringMeteredPayment: true
            )
            return clears ? total + 1 : total
        }
    }

    guard let pickedIndex = counts.firstIndex(where: { $0 > 0 }) else {
        return .empty
    }

    let bottomCount = counts[counts.count - 1]
    let pickedCount = counts[pickedIndex]
    // Monotonicity guarantees bottomCount >= pickedCount, so density is always in [0, 1].
    let density = bottomCount > 0 ? Double(pickedCount) / Double(bottomCount) : 0

    let steppedDown = pickedIndex > 0 || density < bannerDensityThreshold
    return .resolved(offsetDays: ladderOffsetDays[pickedIndex], steppedDown: steppedDown)
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

// MARK: - Community chrome clearance (reverted to flag-independent legacy value, Addendum 2)

/// Returns the bottom padding (in points) the persistent Report pill / "?" map-key button
/// (`communityMapChromeOverlay`) need to clear the FT-20 browse sheet's peek detent.
///
/// **Addendum 2 history** (`docs/design/goal-first-ambient-design.md` A2.1): PR #134 added a
/// SECOND branch here (`goalDockVisible: true` → a hardcoded 326pt sum of the goal-first
/// dock's own component heights) to stop this chrome drawing over the dock's tile row.
/// Addendum 2 neutralizes that branch entirely, not by tuning its number again, but by
/// removing the NEED for it: Report pill and "?" now have permanent homes inside layout
/// containers that track their own height (`GoalSelectorView`'s own top row; `recenterButtonStack`'s
/// rail) instead of floating alone and chasing a sibling's height from the outside.
/// `communityMapChromeOverlay` no longer renders this chrome AT ALL while the goal dock is
/// visible (see that property's own third gate), so the dock-aware branch was dead code the
/// moment that gate landed — removed here rather than left as an unreachable `if`.
///
/// This is now the ORIGINAL, pre-PR-#134, flag-independent clearance — kept as a named pure
/// function (not inlined) for the same reason `recenterPillBottomPadding` stays a named
/// function post-refactor: directly testable without a live `ContentView`.
func communityMapChromeBottomPadding(browseSheetPeekHeight: CGFloat) -> CGFloat {
    browseSheetPeekHeight + 12
}

#Preview {
    let clients = SupabaseClients()
    let previewAuthService = clients.makeAuthService()
    ContentView(
        appDelegate: AppDelegate(),
        authService: previewAuthService,
        supabaseClients: clients,
        regularsService: RegularsService(authService: previewAuthService)
    )
}
