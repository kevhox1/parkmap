//
//  CurbPlacementSession.swift
//  WePark
//
//  Stream A3 of the fixed-center-pin amendment (docs/longpress-universal-plant-spec.md
//  "Amendment - fixed-center pin with live curb snap", sections A.3 / A.6 / A.7) - the PURE half
//  of ContentView's placement mode, so every decision ContentView makes is directly unit-testable
//  with no view, no map and no flag read:
//    - what a placement session IS (`CurbPlacementSession`, intent, entry, seed, latest outcome)
//    - whether an entry point routes to the new mode, the legacy path, or nowhere
//      (`CurbPlacementPolicy.routing`) - the flag-off byte-identity claim lives here
//    - the deferral plan for the recenter / ambient-look camera movers while a session is live
//      (`CurbPlacementPolicy.recenterPlan`; PR #140 QA findings #2, P2-1)
//    - the ambient-look bookkeeping on exit, state only, NEVER a camera move
//      (`CurbPlacementPolicy.ambientUserAdjustedAfterExit`; PR #140 QA P2-1(c))
//    - what the two commit handoffs carry (`parkTarget`, `reportTarget`) - they feed the EXISTING
//      `confirmPinDrop(result:)` and `ActiveSheet.reportPin` paths, nothing new on the wire
//    - the one-shot first-use hint gate (`CurbPlacementHintGate`, `BackgroundNoteGate` convention)
//
//  Invariants (house style, same as `CurbPlacementMapPolicy`):
//    - Pure Foundation / CoreLocation. No SwiftUI, no MapKit, no Calendar.current, no
//      force-unwraps.
//    - `nonisolated` explicit on every value type here (project default actor isolation is
//      MainActor and the tests call these synchronously). No `==` on a project enum inside a
//      `nonisolated` function and no MainActor-constant read inside one (PR #138 QA caught
//      exactly that): the flag, the mode booleans and every constant are passed IN by the
//      caller, and enums are inspected with `switch`.
//    - Placement is a RESTING-posture mode: nothing here reads or writes `driveModeActive` - the
//      entry guard receives it as a plain Bool input and only ever REFUSES on it.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import Foundation
import CoreLocation

// MARK: - Intent / entry

/// What the user is placing the pin FOR (spec A.4). Drives the card's primary label and whether
/// the quiet "Report something here" link exists.
nonisolated enum CurbPlacementIntent: Equatable {
    /// Park the car (reserved: no entry point maps to it today; kept so the card model covers
    /// every intent the spec names).
    case park
    /// Long-press: the dominant action is Park; reporting is the quiet secondary link (A-1).
    case plant
    /// Report pill: the pin only confirms WHERE; the primary is "Next" into the chooser (A-2).
    case report
    /// BlockDetail "Park here ->" (Path B): park on the block the user already picked.
    case parkBlock
}

/// Which entry point opened the session (spec A.7).
nonisolated enum CurbPlacementEntry: Equatable {
    case longPress
    case reportPill
    case pathB

    /// A.7: long-press -> `.plant`, Report pill -> `.report`, Path B -> `.parkBlock`.
    var intent: CurbPlacementIntent {
        switch self {
        case .longPress:  return .plant
        case .reportPill: return .report
        case .pathB:      return .parkBlock
        }
    }

    /// Spec A-2 mitigation: the pill's entry is instant ("the screen is ready on arrival").
    var animatesEntry: Bool {
        switch self {
        case .longPress:  return true
        case .reportPill: return false
        case .pathB:      return true
        }
    }

    /// The `coordinateSource` diagnostic tag the report sheet carries (spec A.6 handoff table:
    /// `"curb-snap placement (<entry>)"`).
    var coordinateSource: String {
        switch self {
        case .longPress:  return "curb-snap placement (long-press)"
        case .reportPill: return "curb-snap placement (report pill)"
        case .pathB:      return "curb-snap placement (block detail)"
        }
    }
}

// MARK: - Nearest-curb hint

/// The "No curb here" state's tappable chip target: the nearest curb within 100 m of the pin.
nonisolated struct CurbPlacementNearestCurb: Equatable {
    let latitude: Double
    let longitude: Double
    /// Metres from the pin to the curb point.
    let distanceMeters: Double
    /// Compass bearing from the pin to the curb point, degrees clockwise from true north, [0, 360).
    let bearingDegrees: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Session

/// The one `@State` value ContentView holds while the mode is live (nil = mode off - the only
/// state flag-off ever sees).
nonisolated struct CurbPlacementSession {
    /// Identity of THIS session, so a delayed callback (the loading timeout, a refresh retry)
    /// can tell it still belongs to the session that scheduled it.
    let id: UUID
    let entry: CurbPlacementEntry
    let seed: CLLocationCoordinate2D
    /// Whether the seed lies inside the Manhattan tile footprint. Outside it there is no parking
    /// data to wait for: the card shows "No parking data here" instead of "Loading curbs..."
    /// (PR #143 QA #2).
    let seedInCoverage: Bool
    /// Path B pre-selects its block's blockface as the incumbent; nil for the other entries.
    let incumbentBlockfaceKey: String?
    /// Whether the first-use hint pill shows this session (decided once, at entry).
    let showsHint: Bool

    /// Set by a one-shot timer after entry: "Loading curbs..." is BOUNDED, never indefinite.
    var loadingExpired: Bool
    /// The latest `onPlacementOutcome`; nil until the first one arrives ("Loading curbs...").
    var outcome: CurbSnapOutcome?
    /// Whether a blockface for the OTHER curb of the snapped block is loaded (feeds the
    /// "Nearest curb with data" footnote). Recomputed per outcome, never per frame.
    var oppositeSideLoaded: Bool
    /// The nearest-curb chip target while in the no-curb state; nil otherwise.
    var nearestCurb: CurbPlacementNearestCurb?

    init(
        entry: CurbPlacementEntry,
        seed: CLLocationCoordinate2D,
        incumbentBlockfaceKey: String? = nil,
        showsHint: Bool = false,
        seedInCoverage: Bool = true
    ) {
        self.id = UUID()
        self.entry = entry
        self.seed = seed
        self.seedInCoverage = seedInCoverage
        self.loadingExpired = false
        self.incumbentBlockfaceKey = incumbentBlockfaceKey
        self.showsHint = showsHint
        self.outcome = nil
        self.oppositeSideLoaded = false
        self.nearestCurb = nil
    }

    var intent: CurbPlacementIntent { entry.intent }
    var animatedEntry: Bool { entry.animatesEntry }
}

// MARK: - Routing / plans

/// Where an entry point goes.
nonisolated enum CurbPlacementEntryRouting: Equatable {
    /// Take the existing (pre-A3) branch, byte-identically.
    case legacy
    /// Enter the placement mode.
    case placement
    /// Do nothing at all (spec A22: a long-press during another exclusive mode is a no-op).
    case ignore
}

/// What `handleLocationUpdate` does with the pending recenter flags and the ambient-look hook
/// while a placement session is live (PR #140 QA finding #2 / P2-1 (a)+(b)).
nonisolated struct CurbPlacementRecenterPlan: Equatable {
    /// Run (and clear) the "Find me" deferred recenter this fix.
    let consumeRequested: Bool
    /// Run (and clear) the launch auto-center this fix.
    let consumeAtLaunch: Bool
}

/// What `healStuckCurbPlacement` / the `.onChange(of: curbPlacement != nil)` safety net does.
/// What the card may say about data availability (QA #2).
nonisolated enum CurbPlacementDataStatus: Equatable {
    /// An index build / first resolve is genuinely in progress (bounded by the timeout).
    case loading
    case ready
    /// Outside coverage, or the viewport has no tiles after the timeout.
    case noData
}

nonisolated enum CurbPlacementHealAction: Equatable {
    case none
    /// No session but the map layer is still in the mode: call `endPlacement`.
    case endMapLayer
    /// A session but no live map layer: end the SwiftUI side too.
    case dropSession
}

nonisolated enum CurbPlacementPolicy {

    // MARK: Entry guard (spec A.3 "Entry")

    /// `!driveModeActive && !blockSelectModeActive && !spotPlacementActive && curbPlacement == nil`.
    /// `driveModeActive` is only ever READ to refuse - this mode never writes it.
    static func entryAllowed(
        driveModeActive: Bool,
        blockSelectModeActive: Bool,
        spotPlacementActive: Bool,
        placementActive: Bool
    ) -> Bool {
        !driveModeActive && !blockSelectModeActive && !spotPlacementActive && !placementActive
    }

    /// Routes an entry point (spec A.7). Flag off is ALWAYS `.legacy` - the byte-identity claim:
    /// the caller then falls through to the unmodified pre-A3 code. Flag on and entry allowed is
    /// `.placement`. Flag on but blocked: a long-press is `.ignore` (A22), the pill and Path B
    /// fall back to `.legacy` (e.g. Path B reached mid-drive keeps today's `ParkConfirmView`).
    static func routing(
        for entry: CurbPlacementEntry,
        flagEnabled: Bool,
        driveModeActive: Bool,
        blockSelectModeActive: Bool,
        spotPlacementActive: Bool,
        placementActive: Bool
    ) -> CurbPlacementEntryRouting {
        guard flagEnabled else { return .legacy }
        let allowed = entryAllowed(
            driveModeActive: driveModeActive,
            blockSelectModeActive: blockSelectModeActive,
            spotPlacementActive: spotPlacementActive,
            placementActive: placementActive
        )
        if allowed { return .placement }
        switch entry {
        case .longPress:           return .ignore
        case .reportPill, .pathB:  return .legacy
        }
    }

    // MARK: Sheet dismissal / teardown (PR #140 QA #4)

    /// The generic `.sheet(onDismiss:)` catch-all's condition (`ContentView.body`), extracted so
    /// its A3 clause is unit-testable. With `placementActive == false` this is EXACTLY the
    /// pre-A3 conjunction (`ft20BrowseSheetEnabled && activeSheet == nil && !driveModeActive &&
    /// !blockSelectModeActive && !spotPlacementActive`): flag-off byte-identical. Mid-mode it is
    /// false, so dismissing the sheet that launched placement never re-presents a rest-state
    /// sheet (AC-A21).
    static func sheetDismissRestoresRestState(
        browseSheetEnabled: Bool,
        activeSheetIsNil: Bool,
        driveModeActive: Bool,
        blockSelectModeActive: Bool,
        spotPlacementActive: Bool,
        placementActive: Bool
    ) -> Bool {
        browseSheetEnabled && activeSheetIsNil && !driveModeActive
            && !blockSelectModeActive && !spotPlacementActive && !placementActive
    }

    /// A sheet presented over a live session: map interaction exists only in the mode, never
    /// under a sheet, so the session ends (the new sheet stays).
    static func sheetConflicts(placementActive: Bool, activeSheetPresent: Bool) -> Bool {
        placementActive && activeSheetPresent
    }

    /// Reconciles SwiftUI state with the map layer. A map layer still in the mode with no session
    /// would ignore every tap forever (QA #4) - end it; a session with no map layer is a card over
    /// a map that is not in the mode - drop it.
    static func healAction(sessionPresent: Bool, mapLayerActive: Bool) -> CurbPlacementHealAction {
        if sessionPresent {
            return mapLayerActive ? .none : .dropSession
        }
        return mapLayerActive ? .endMapLayer : .none
    }

    // MARK: Camera-mover deferral (PR #140 QA #2, P2-1 (a)+(b))

    /// With no session: consume exactly what is pending, ambient look allowed - the pre-A3
    /// behavior. With a live session: consume NOTHING (the pending flags stay set so the recenter
    /// is DEFERRED, not dropped - `handleLocationUpdate` used to clear them before calling
    /// `recenterMap`, so gating only the call would lose the recenter permanently). (The ambient
    /// look's own gate is the `guard curbPlacement == nil` in `handleAmbientLookLocationUpdate`.)
    static func recenterPlan(
        requestedPending: Bool,
        atLaunchPending: Bool,
        placementActive: Bool
    ) -> CurbPlacementRecenterPlan {
        if placementActive {
            return CurbPlacementRecenterPlan(consumeRequested: false, consumeAtLaunch: false)
        }
        return CurbPlacementRecenterPlan(
            consumeRequested: requestedPending,
            consumeAtLaunch: atLaunchPending
        )
    }

    /// On exit, a deferred explicit "Find me" recenter has no GPS fix scheduled to complete it
    /// (resting posture fixes are single-shot), so one fresh single-shot fix is requested to
    /// re-queue it. ONLY the explicit flag: the best-effort launch auto-center is dropped when a
    /// session starts (the user has taken over the map), so it can never yank the camera
    /// after Cancel (PR #143 QA #7). `isAuthorized` makes "this can never prompt" structural
    /// (QA #8).
    static func shouldRequeueRecenterOnExit(requestedPending: Bool, isAuthorized: Bool) -> Bool {
        requestedPending && isAuthorized
    }

    // MARK: Ambient-look bookkeeping on exit (PR #140 QA P2-1 (c))

    /// STATE ONLY - the exit camera is A2's `endPlacement` (exact snapshot on Cancel, pin-centred
    /// on commit); re-asserting the look through `applyAmbientDrivingLook` would issue a competing
    /// `setCamera` that overrides it. Cancel restores the exact pre-session camera, so the flag
    /// is untouched. A commit leaves the camera where the USER put it, so auto-tighten must not
    /// yank it away on the next GPS fix: `userAdjusted` becomes true. `ambientLookStep` is never
    /// changed by a session (A2 stops placement pans feeding `onAmbientUserAdjusted`, and this
    /// mode never calls `applyAmbientDrivingLook`), so it needs no reset.
    static func ambientUserAdjustedAfterExit(
        restored: Bool,
        ambientLookInEffect: Bool,
        currentUserAdjusted: Bool
    ) -> Bool {
        guard ambientLookInEffect else { return currentUserAdjusted }
        return restored ? currentUserAdjusted : true
    }

    // MARK: Nearest-curb chip

    /// Wide-probe radius (spec A.3: "toward the nearest curb within 100 m").
    static let nearestCurbProbeMeters: Double = 100

    /// Compass bearing from `from` to `to`, degrees clockwise from true north in [0, 360).
    static func bearingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * Double.pi / 180
        let lat2 = to.latitude * Double.pi / 180
        let dLng = (to.longitude - from.longitude) * Double.pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        let degrees = atan2(y, x) * 180 / Double.pi
        guard degrees.isFinite else { return 0 }
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The chip target for a wide-config probe result (`CurbSnapIndex.resolve` with
    /// `CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)`, `incumbent: nil`). nil when the
    /// probe found nothing within 100 m.
    static func nearestCurb(from pin: CLLocationCoordinate2D, probe: CurbSnapOutcome) -> CurbPlacementNearestCurb? {
        switch probe {
        case .snapped(let result):
            return CurbPlacementNearestCurb(
                latitude: result.snappedCoordinate.latitude,
                longitude: result.snappedCoordinate.longitude,
                distanceMeters: result.distanceMeters,
                bearingDegrees: bearingDegrees(from: pin, to: result.snappedCoordinate)
            )
        case .noCurbInRange:
            return nil
        }
    }

    // MARK: Loading vs no-data (PR #143 QA #2)

    /// How long "Loading curbs..." may last after entry before the card gives up and tells the
    /// truth. Tiles are bundled and decode locally, so this is a generous bound, not a network wait.
    static let loadingTimeoutSeconds: Double = 3.0

    /// What the card may claim about data availability.
    static func dataStatus(
        seedInCoverage: Bool,
        indexReady: Bool,
        indexBuilding: Bool,
        segmentsEmpty: Bool,
        outcomeReceived: Bool,
        loadingExpired: Bool
    ) -> CurbPlacementDataStatus {
        // Outside the Manhattan footprint there is nothing to wait for.
        if !seedInCoverage { return .noData }
        if loadingExpired { return segmentsEmpty ? .noData : .ready }
        if indexBuilding || !indexReady { return .loading }
        if segmentsEmpty { return .loading }
        if !outcomeReceived { return .loading }
        return .ready
    }

    /// Report-pill seed: the GPS fix only when it is inside coverage (the Recenter button's own
    /// rule - "no data AND can't get back" must be unreachable), else the map centre. Stops the
    /// pill flying the camera to an out-of-coverage fix.
    static func pillSeed(
        userLocation: CLLocationCoordinate2D?,
        userLocationInCoverage: Bool,
        regionCenter: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        if let userLocation, userLocationInCoverage { return userLocation }
        return regionCenter
    }

    // MARK: Index cache + refresh retry (PR #143 QA #4)

    /// Cheap identity for "the loaded segment set": count plus first/last ids. The index is
    /// cached across sessions and reused only when this is unchanged, so a pan to a different
    /// area that happens to load the same NUMBER of segments does not reuse a stale index.
    static func segmentsVersion(count: Int, firstID: String?, lastID: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(count)
        hasher.combine(firstID)
        hasher.combine(lastID)
        return hasher.finalize()
    }

    /// Delays (seconds) of the bounded post-swap refresh retries: the first attempt is the next
    /// run-loop turn (delay 0 = attempt 0), then these. nil = stop.
    static let refreshRetryDelays: [Double] = [0.25, 0.6, 1.2]

    static func refreshRetryDelay(afterAttempt attempt: Int) -> Double? {
        guard attempt >= 0, attempt < refreshRetryDelays.count else { return nil }
        return refreshRetryDelays[attempt]
    }

    /// Retry only while the SAME session still has no outcome (an outcome means the refresh
    /// worked; a different or absent session means stop).
    static func shouldRetryRefresh(sessionMatches: Bool, outcomeReceived: Bool) -> Bool {
        sessionMatches && !outcomeReceived
    }

    // MARK: Handoffs (spec A.6 table)

    /// What the Park handoff feeds `PinDropIntent` (-> `PinConfirmResult(notifyOnRestriction:
    /// true)` -> the existing `confirmPinDrop(result:)`): the SNAPPED coordinate, winner and
    /// distance when a curb owns the pin; otherwise the pin's ground coordinate with no segment
    /// (today's `detectedSegment == nil` "Save car here" path - never a dead end).
    static func parkTarget(outcome: CurbSnapOutcome?, fallbackPin: CLLocationCoordinate2D) -> CurbPlacementParkTarget {
        if let outcome {
            switch outcome {
            case .snapped(let result):
                return CurbPlacementParkTarget(
                    latitude: result.snappedCoordinate.latitude,
                    longitude: result.snappedCoordinate.longitude,
                    segment: result.segment,
                    distanceMeters: result.distanceMeters
                )
            case .noCurbInRange:
                break
            }
        }
        return CurbPlacementParkTarget(
            latitude: fallbackPin.latitude,
            longitude: fallbackPin.longitude,
            segment: nil,
            distanceMeters: nil
        )
    }

    /// What the report handoff feeds `ActiveSheet.reportPin`: the snapped coordinate and winner
    /// (so the coordinate is fixed BEFORE the sheet exists), or the pin with `segment: nil` (the
    /// existing OD-1 graceful degradation). `showsParkMyCarTile` per spec A.6: true for the pill,
    /// false for the long-press / Path B secondary link (Park is the card's own primary there).
    static func reportTarget(
        outcome: CurbSnapOutcome?,
        entry: CurbPlacementEntry,
        fallbackPin: CLLocationCoordinate2D
    ) -> CurbPlacementReportTarget {
        let target = parkTarget(outcome: outcome, fallbackPin: fallbackPin)
        let showsPark: Bool
        switch entry {
        case .reportPill:         showsPark = true
        case .longPress, .pathB:  showsPark = false
        }
        return CurbPlacementReportTarget(
            coordinate: CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude),
            segment: target.segment,
            coordinateSource: entry.coordinateSource,
            showsParkMyCarTile: showsPark
        )
    }
}

// MARK: - Handoff payloads

nonisolated struct CurbPlacementParkTarget {
    let latitude: Double
    let longitude: Double
    let segment: Segment?
    let distanceMeters: Double?
}

nonisolated struct CurbPlacementReportTarget {
    let coordinate: CLLocationCoordinate2D
    let segment: Segment?
    let coordinateSource: String
    /// Not consumed yet: `ReportSheet`'s grid does not render the Park tile (Stage 1 plumbing,
    /// `ReportSheet.showsParkMyCarTile`'s doc comment) and `ActiveSheet.reportPin` carries no such
    /// field. Computed here so Stage 2 wires it without re-deriving the spec's rule.
    let showsParkMyCarTile: Bool
}

// MARK: - First-use hint gate

/// One-shot gate for the placement mode's first-use hint pill (design review section 3.4: this
/// mode inverts "tap the map where" into "the map moves, not the pin", so the FIRST use gets one
/// line of affordance). `BackgroundNoteGate` convention: injectable `UserDefaults`,
/// `shouldShow()` / `markShown()` pair.
struct CurbPlacementHintGate {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = AppConstants.curbPlacementHintShownKey) {
        self.defaults = defaults
        self.key = key
    }

    /// True until `markShown()` has been called on this device.
    func shouldShow() -> Bool {
        !defaults.bool(forKey: key)
    }

    func markShown() {
        defaults.set(true, forKey: key)
    }
}
