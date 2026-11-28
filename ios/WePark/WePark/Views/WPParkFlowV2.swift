//
//  WPParkFlowV2.swift
//  WePark
//
//  Phase 2b, B6: drag the car token to a curb. Flag-on only (`AppConstants.designSystemV2Enabled`).
//
//    idle      the 56pt car token sits on the map with "Drag to a curb to park"
//    dragging  token lifted to 64pt; the sheet drops away; a bubble above the token says what the
//              curb under it is (park / don't, with the end time); light haptic on pick-up, a tick
//              on each new curb, a warning haptic on a don't curb
//    placed    token lands on the curb; confirm card: "Not saved yet", "In front of <address>",
//              verdict, "Park here" or "Park here anyway" (+ a warning on a don't curb), "Cancel"
//
//  DT35-3: "placed" IS the pending draft. The draft is a ground coordinate (not a window point), so
//  the map keeps panning and zooming under it and the token stays glued to its spot. The car follows
//  the finger anywhere (along the block, across the street, off a curb); the verdict is always the
//  curb under the car and is cleared the moment it is over no curb. Nothing is written until the
//  confirm button runs `confirmPinDrop`.
//
//  Snapping uses the existing `CurbSnapIndex` (the curb-pin placement engine). The verdict comes
//  from `WPCurbSheetBuilder` (the same engine path as the curb sheet). Saving reuses the existing
//  `confirmPinDrop` in ContentView (park / save / reminder logic is not forked).
//

import CoreLocation
import Observation
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Draft

/// The pending placement (DT35-3): a car that has been put on a curb but NOT saved. A value type that
/// is deliberately not `Codable`: a draft is never persisted, so there is nothing to restore after a
/// relaunch (backgrounding and termination discard it).
struct WPParkDraft {
    /// Where the car sits on the ground (the foot point on the curb once it has landed).
    let groundCoordinate: CLLocationCoordinate2D
    let snap: CurbSnapResult
    let model: WPCurbSheetModel
    /// The opposite curb, for "Other side of the street" (nil = none in the data).
    let alternate: CurbSnapResult?
}

/// A short plain-language note shown next to the car (cleared after a few seconds or on the next move).
enum WPParkFlowNotice: Equatable {
    /// The car was released away from any curb and went back to the last curb it was on.
    case dropOnCurb
}

enum WPParkFlowCopy {
    static let notSavedYet = "Not saved yet"
    static let notSavedHint = "Drag the car to adjust it."
    static let notSavedSpoken = "Not saved yet. Your car is saved only when you tap Park here."
    static let dropOnCurb = "Drop the car on a curb"
    static let cancel = "Cancel"
    static let moveForward = "Move forward along the block"
    static let moveBack = "Move back along the block"
}

extension WPDragBubble {
    /// The car is over no curb (or past the snap range): never a verdict, never a stale green.
    static var noCurb: WPDragBubble {
        WPDragBubble(
            tone: .dont, headline: "Not on a curb", detail: "Drag onto a street",
            hint: "Drag the car onto a street to see if you can park there."
        )
    }

    /// The snap index is still building (the first drag beat it).
    static var gettingReady: WPDragBubble {
        WPDragBubble(
            tone: .soon, headline: "Getting the map ready", detail: "",
            hint: "One moment, then drag the car to a curb."
        )
    }

    /// Released off a curb while pending: the car went back to the last curb.
    static var dropOnCurb: WPDragBubble {
        WPDragBubble(
            tone: .dont, headline: WPParkFlowCopy.dropOnCurb, detail: "Back on the last curb",
            hint: WPParkFlowCopy.dropOnCurb
        )
    }
}

// MARK: - Controller

@MainActor
@Observable
final class WPParkFlowController {

    enum Phase: Equatable { case idle, dragging, placed }

    private(set) var phase: Phase = .idle
    /// Token center in window coordinates while idle or dragging (nil = at the rest position). While
    /// placed the token is positioned from `groundCoordinate` instead, so it follows the map.
    private(set) var tokenPoint: CGPoint?
    /// DT35-3: where the pending car sits on the ground. Non-nil exactly while `phase == .placed`.
    private(set) var groundCoordinate: CLLocationCoordinate2D?
    /// Bumps on every landing, side switch and restore so the layer can animate the car gliding to
    /// its curb (an animation keyed on this, not on the per-frame position of a pan).
    private(set) var landingTick = 0
    private(set) var notice: WPParkFlowNotice?
    /// Where the drag started (drawn as the dashed "came from" ring).
    private(set) var originPoint: CGPoint?
    private(set) var snap: CurbSnapResult?
    private(set) var model: WPCurbSheetModel?
    private(set) var indexReady = false
    /// DT35-2: the other curb of the placed block (same position along the street), computed once
    /// when the token lands. Non-nil = "Other side of the street" is offered. After a switch it
    /// holds the curb just left, so a second tap returns exactly there.
    private(set) var alternateSnap: CurbSnapResult?

    /// The last curb the car sat on before it was picked up again, for the off-curb release.
    private struct Landing {
        let snap: CurbSnapResult
        let model: WPCurbSheetModel
        let alternate: CurbSnapResult?
        let ground: CLLocationCoordinate2D
    }

    @ObservationIgnored private var lastLanding: Landing?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var index: CurbSnapIndex?
    @ObservationIgnored private var indexKey: Int?
    @ObservationIgnored private var lastSegmentID: String?
    /// The loaded segments, kept from `prepareIndex` so landing can look up the opposite curb.
    @ObservationIgnored private var knownSegments: [Segment] = []
    @ObservationIgnored private let selection = UISelectionFeedbackGenerator()
    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let notify = UINotificationFeedbackGenerator()

    /// Snap radius while a finger is dragging: about one block face wide.
    nonisolated static let snapMeters: Double = 40

    /// Anti-flicker dead-band when the car crosses to the other curb, in metres. Smaller than the
    /// curb-pin placement (up to 4 m) so crossing a 12 m street does not feel sticky.
    nonisolated static let tokenHysteresisMeters: Double = 1.5

    /// How far one VoiceOver "Move forward / back" action moves the car along the block.
    nonisolated static let nudgeMeters: Double = 5

    /// The snap rule for the token: 40 m reach, a 1.5 m dead-band.
    nonisolated static var tokenSnapConfig: CurbSnapConfig {
        CurbSnapConfig(
            acquireRadius: snapMeters, releaseRadius: snapMeters + 8,
            hysteresisMinMeters: tokenHysteresisMeters, hysteresisMaxMeters: tokenHysteresisMeters
        )
    }

    /// The pending draft, or nil when nothing is waiting to be saved.
    var draft: WPParkDraft? {
        guard phase == .placed, let groundCoordinate, let snap, let model else { return nil }
        return WPParkDraft(groundCoordinate: groundCoordinate, snap: snap, model: model, alternate: alternateSnap)
    }

    /// Builds (or reuses) the snap index for the loaded segments, off the main thread.
    func prepareIndex(segments: [Segment]) {
        let key = CurbPlacementPolicy.segmentsVersion(
            count: segments.count, firstID: segments.first?.id, lastID: segments.last?.id
        )
        if indexKey == key, index != nil { return }
        indexKey = key
        knownSegments = segments
        Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) { CurbSnapIndex(segments: segments) }.value
            guard indexKey == key else { return }
            index = built
            indexReady = true
        }
    }

    func beginDrag(from point: CGPoint) {
        guard phase != .dragging else { return }
        if phase == .placed, let snap, let model, let groundCoordinate {
            lastLanding = Landing(snap: snap, model: model, alternate: alternateSnap, ground: groundCoordinate)
            // Same curb until the finger moves it: no re-verdict and no haptic on pick-up.
            lastSegmentID = snap.segment.id
        } else {
            lastLanding = nil
            lastSegmentID = nil
        }
        phase = .dragging
        originPoint = point
        tokenPoint = point
        groundCoordinate = nil
        alternateSnap = nil
        clearNotice()
        impact.prepare()
        impact.impactOccurred()
    }

    /// Resolves the curb under the token. `coordinate` is the ground point under it.
    func update(
        point: CGPoint,
        coordinate: CLLocationCoordinate2D?,
        metersPerPoint: Double,
        engine: ParkingRulesEngine,
        now: Date,
        windowEnd: Date?,
        trip: TripPlan?,
        reports: (Segment) -> WPNeighborReports = { _ in WPNeighborReports() }
    ) {
        tokenPoint = point
        guard let coordinate, let index else {
            snap = nil; model = nil; lastSegmentID = nil
            return
        }
        let outcome = index.resolve(
            coordinate,
            incumbent: snap?.blockfaceKey,
            metersPerPoint: metersPerPoint,
            config: Self.tokenSnapConfig
        )
        switch outcome {
        case .snapped(let result):
            snap = result
            if result.segment.id != lastSegmentID {
                lastSegmentID = result.segment.id
                let built = WPNeighborVerdict.resolve(
                    segment: result.segment, engine: engine, now: now, windowEnd: windowEnd, trip: trip,
                    reports: reports(result.segment)
                )
                model = built
                if built.offersPrimaryPark {
                    selection.prepare(); selection.selectionChanged()
                } else {
                    notify.prepare(); notify.notificationOccurred(.warning)
                }
            }
        case .noCurbInRange:
            snap = nil; model = nil; lastSegmentID = nil
        }
    }

    /// VoiceOver / non-drag path: places the car on the curb nearest `coordinate` (the user's
    /// location) with the same snap, verdict and confirm card as a drag. Returns false when no
    /// curb is in range or the index is not ready yet.
    @discardableResult
    func placeAt(
        coordinate: CLLocationCoordinate2D, point: CGPoint,
        metersPerPoint: Double, engine: ParkingRulesEngine, now: Date, windowEnd: Date?, trip: TripPlan?,
        reports: (Segment) -> WPNeighborReports = { _ in WPNeighborReports() }
    ) -> Bool {
        beginDrag(from: point)
        update(
            point: point, coordinate: coordinate, metersPerPoint: metersPerPoint,
            engine: engine, now: now, windowEnd: windowEnd, trip: trip, reports: reports
        )
        return endDrag(landingPoint: point)
    }

    /// Finger lifted. A snapped car lands on the curb (the pending card). Released over no curb: a car
    /// that was already placed goes back to the last curb it was on (with a "Drop the car on a curb"
    /// note); only a first drag goes home. Returns true when it landed on a NEW curb.
    @discardableResult
    func endDrag(landingPoint: CGPoint?) -> Bool {
        guard phase == .dragging else { return false }
        if let snap, model != nil {
            phase = .placed
            groundCoordinate = snap.snappedCoordinate
            if let landingPoint { tokenPoint = landingPoint }
            alternateSnap = Self.oppositeSnap(of: snap, in: knownSegments)
            lastLanding = nil
            landingTick += 1
            impact.impactOccurred()
            return true
        }
        if let last = lastLanding {
            restore(last)
            return false
        }
        reset()
        return false
    }

    private func restore(_ last: Landing) {
        phase = .placed
        snap = last.snap
        model = last.model
        alternateSnap = last.alternate
        groundCoordinate = last.ground
        lastSegmentID = last.snap.segment.id
        lastLanding = nil
        landingTick += 1
        showNotice(.dropOnCurb)
        notify.prepare(); notify.notificationOccurred(.warning)
    }

    /// Curb sheet "Park here": the car goes onto the tapped curb as a pending draft. Nothing is saved.
    /// `segments` lets "Other side of the street" find the facing curb.
    func enterPending(
        at result: CurbSnapResult,
        segments: [Segment],
        engine: ParkingRulesEngine,
        now: Date,
        windowEnd: Date?,
        trip: TripPlan?,
        reports: (Segment) -> WPNeighborReports = { _ in WPNeighborReports() }
    ) {
        if !segments.isEmpty { knownSegments = segments }
        phase = .placed
        tokenPoint = nil
        originPoint = nil
        lastLanding = nil
        snap = result
        groundCoordinate = result.snappedCoordinate
        lastSegmentID = result.segment.id
        model = WPNeighborVerdict.resolve(
            segment: result.segment, engine: engine, now: now, windowEnd: windowEnd, trip: trip,
            reports: reports(result.segment)
        )
        alternateSnap = Self.oppositeSnap(of: result, in: knownSegments)
        clearNotice()
        landingTick += 1
        impact.prepare(); impact.impactOccurred()
    }

    /// "Other side of the street": swaps the placed snap to the opposite curb at the same position
    /// along the street, re-runs the verdict, and keeps the curb just left so a second tap returns to
    /// it. The token's side stays "what the finger dropped on"; there is no ask state here because
    /// the user pointed at a curb. No-op without an opposite curb.
    func switchSide(
        engine: ParkingRulesEngine,
        now: Date,
        windowEnd: Date?,
        trip: TripPlan?,
        reports: (Segment) -> WPNeighborReports = { _ in WPNeighborReports() }
    ) {
        guard phase == .placed, let current = snap, let target = alternateSnap else { return }
        alternateSnap = current
        snap = target
        groundCoordinate = target.snappedCoordinate
        lastSegmentID = target.segment.id
        model = WPNeighborVerdict.resolve(
            segment: target.segment, engine: engine, now: now, windowEnd: windowEnd, trip: trip,
            reports: reports(target.segment)
        )
        clearNotice()
        landingTick += 1
        selection.prepare(); selection.selectionChanged()
    }

    /// VoiceOver "Move forward / back along the block": nudges the pending car `meters` along the
    /// curb (negative = back), carrying on to the next piece of the block at a piece end. Same snap,
    /// verdict and card as a drag. Returns false when there is no draft or no curb at the new spot.
    @discardableResult
    func nudge(
        meters: Double, point: CGPoint,
        metersPerPoint: Double, engine: ParkingRulesEngine, now: Date, windowEnd: Date?, trip: TripPlan?,
        reports: (Segment) -> WPNeighborReports = { _ in WPNeighborReports() }
    ) -> Bool {
        guard phase == .placed, let snap,
              let target = Self.nudgedCoordinate(
                on: snap.segment.coordinates, fraction: snap.positionFraction, meters: meters
              ) else { return false }
        return placeAt(
            coordinate: target, point: point, metersPerPoint: metersPerPoint,
            engine: engine, now: now, windowEnd: windowEnd, trip: trip, reports: reports
        )
    }

    /// The point `meters` along `polyline` from `fraction`. Past either end it continues straight on
    /// along the end edge, so the caller can resolve whichever curb is there (the next piece).
    nonisolated static func nudgedCoordinate(
        on polyline: [CLLocationCoordinate2D], fraction: Double, meters: Double
    ) -> CLLocationCoordinate2D? {
        guard polyline.count >= 2 else { return nil }
        var length = 0.0
        for index in 1..<polyline.count {
            length += CLLocation(latitude: polyline[index - 1].latitude, longitude: polyline[index - 1].longitude)
                .distance(from: CLLocation(latitude: polyline[index].latitude, longitude: polyline[index].longitude))
        }
        guard length > 1 else { return nil }
        let target = min(1, max(0, fraction)) * length + meters
        if target >= 0, target <= length {
            return CandidateSegmentSearch.coordinate(atFraction: target / length, along: polyline)
        }
        let pastEnd = target > length
        let endPoint = pastEnd ? polyline[polyline.count - 1] : polyline[0]
        let neighbour = pastEnd ? polyline[polyline.count - 2] : polyline[1]
        let overflow = pastEnd ? target - length : -target
        let east = (endPoint.longitude - neighbour.longitude) * 111_320 * cos(endPoint.latitude * Double.pi / 180)
        let north = (endPoint.latitude - neighbour.latitude) * 111_320
        let norm = hypot(east, north)
        guard norm > 0 else { return endPoint }
        let dEast = east / norm * overflow
        let dNorth = north / norm * overflow
        return CLLocationCoordinate2D(
            latitude: endPoint.latitude + dNorth / 111_320,
            longitude: endPoint.longitude + dEast / (111_320 * cos(endPoint.latitude * Double.pi / 180))
        )
    }

    /// The curb under `coordinate` for a draft that has none yet: the foot point of the user's fix on
    /// the tapped curb when the fix is within the snap range of it, else the middle of the curb. Nil only
    /// for a degenerate polyline.
    nonisolated static func pendingSnap(
        on segment: Segment, near fix: CLLocationCoordinate2D?
    ) -> CurbSnapResult? {
        let coordinates = segment.coordinates
        guard coordinates.count >= 2 else { return nil }
        if let fix, let foot = CandidateSegmentSearch.nearestPointOnPolyline(from: fix, polyline: coordinates),
           foot.distanceMeters <= snapMeters {
            return CurbSnapResult(
                segment: segment, positionFraction: foot.fraction,
                distanceMeters: foot.distanceMeters, snappedCoordinate: foot.coordinate
            )
        }
        // The true middle of the polyline, not `Segment.midpoint` (that is a vertex, which for a
        // two-point piece is its far end: a car "locked" to a corner).
        guard let middle = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: coordinates) else { return nil }
        return CurbSnapResult(
            segment: segment, positionFraction: 0.5, distanceMeters: 0, snappedCoordinate: middle
        )
    }

    /// Confirm tapped: success haptic, and the draft is gone (the saved car takes over).
    func commit() {
        notify.prepare(); notify.notificationOccurred(.success)
        reset()
    }

    /// The opposite curb of `snap`'s block as a snap result, or nil when the data has none.
    nonisolated static func oppositeSnap(of snap: CurbSnapResult?, in segments: [Segment]) -> CurbSnapResult? {
        guard let snap else { return nil }
        let here = ParkSideOption(
            segment: snap.segment, coordinate: snap.snappedCoordinate, fraction: snap.positionFraction
        )
        guard let other = ParkSideResolver.switched(from: here, in: segments) else { return nil }
        return CurbSnapResult(
            segment: other.segment, positionFraction: other.fraction,
            distanceMeters: snap.distanceMeters, snappedCoordinate: other.coordinate
        )
    }

    func reset() {
        phase = .idle
        tokenPoint = nil
        originPoint = nil
        groundCoordinate = nil
        snap = nil
        model = nil
        lastSegmentID = nil
        alternateSnap = nil
        lastLanding = nil
        clearNotice()
    }

    private func showNotice(_ value: WPParkFlowNotice) {
        notice = value
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }
}

// MARK: - Layer

/// Full-screen layer over the map. Only the token (and, while dragging, a map-blocking catcher) takes
/// touches; everything else falls through to the map, so pan and pinch stay live while a draft is
/// pending (DT35-3).
struct WPParkLayerV2: View {
    @Bindable var flow: WPParkFlowController
    /// Show the idle token (no parked car, no sheet, no trip plan).
    let showsRestingToken: Bool
    /// "Drag to a curb to park" next to the idle token. Off after the first successful park.
    let showsDragHint: Bool
    /// Window point -> ground coordinate (map projection seam).
    let coordinateForPoint: (CGPoint) -> CLLocationCoordinate2D?
    /// Ground coordinate -> window point (map projection seam). Read every frame while a draft is
    /// pending so the car stays glued to its ground point through pan, pinch and inertia.
    let pointForCoordinate: (CLLocationCoordinate2D) -> CGPoint?
    /// Meters per screen point right now (for the snap hysteresis).
    let metersPerPoint: () -> Double
    let resolveContext: () -> (engine: ParkingRulesEngine, now: Date, windowEnd: Date?, trip: TripPlan?, segments: [Segment], reports: (Segment) -> WPNeighborReports)
    let address: String?
    let onConfirm: () -> Void
    /// VoiceOver action: place the car at the user's location. Returns false when it could not.
    let placeAtUser: () -> Bool
    /// Resting position of the token in window coordinates.
    let restingPoint: CGPoint
    /// The pending car is hidden behind the card: bring `coordinate` up into the visible map, with
    /// the car at `targetY` (window points from the top). Called outside the map's update cycle.
    var onRevealCar: ((CLLocationCoordinate2D, CGFloat) -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var grabOffset: CGSize = .zero
    @State private var cardHeight: CGFloat = 0
    @State private var revealedTick = -1
    @State private var screenHeight: CGFloat = 0

    private var visible: Bool { flow.phase != .idle || showsRestingToken }

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if flow.phase == .dragging {
                    // Blocks map pan only while the car is in hand (a second finger must not move the map).
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0))
                }
                if visible {
                    // Re-evaluated every frame while pending so the car follows the map. Paused (one
                    // render, re-rendered on state change) in every other phase.
                    TimelineView(.animation(minimumInterval: nil, paused: flow.phase != .placed)) { _ in
                        tokenLayer(origin: origin, width: proxy.size.width)
                    }
                }
                VStack {
                    Spacer()
                    bottomCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { screenHeight = proxy.size.height }
        }
        .ignoresSafeArea()
        .allowsHitTesting(visible)
        .onChange(of: flow.landingTick) { _, _ in revealIfHidden() }
        .onChange(of: cardHeight) { _, _ in revealIfHidden() }
    }

    /// Once per landing: if the card would cover the car, move the map so the car sits in the open
    /// area above the card (the user must always see where the car is).
    private func revealIfHidden() {
        guard flow.phase == .placed, cardHeight > 0, screenHeight > 0, revealedTick != flow.landingTick,
              let ground = flow.groundCoordinate, let point = pointForCoordinate(ground) else { return }
        revealedTick = flow.landingTick
        let visibleBottom = screenHeight - cardHeight - 120
        guard point.y > visibleBottom || point.y < 120 else { return }
        onRevealCar?(ground, max(160, (screenHeight - cardHeight) * 0.55))
    }

    // MARK: Token

    private func localPoint(_ window: CGPoint, origin: CGPoint) -> CGPoint {
        CGPoint(x: window.x - origin.x, y: window.y - origin.y)
    }

    /// Where the car is on screen right now (window coordinates). Nil while a pending car's ground
    /// point is off the map view (it is hidden until the map is panned back).
    private func windowPoint() -> CGPoint? {
        switch flow.phase {
        case .idle, .dragging:
            return flow.tokenPoint ?? restingPoint
        case .placed:
            guard let ground = flow.groundCoordinate else { return flow.tokenPoint ?? restingPoint }
            return pointForCoordinate(ground)
        }
    }

    @ViewBuilder
    private func tokenLayer(origin: CGPoint, width: CGFloat) -> some View {
        let window = windowPoint()
        ZStack(alignment: .topLeading) {
            originRing(origin: origin)
            snapDot(origin: origin)
            if let window {
                let p = localPoint(window, origin: origin)
                token(at: p)
                if flow.phase == .idle, showsDragHint { hint(at: p) }
                if flow.phase != .idle { bubble(at: p, width: width) }
            }
        }
    }

    private func token(at p: CGPoint) -> some View {
        let lifted = flow.phase == .dragging
        let pending = flow.phase == .placed
        return WPCarToken(isLifted: lifted, isPending: pending)
            .scaleEffect(lifted ? 64.0 / 56.0 : 1)
            // A bigger hit area than the 56 pt disc: easy to grab on a moving phone.
            .padding(WP.Space.s2)
            .contentShape(Circle())
            .position(p)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: flow.phase)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: flow.landingTick)
            .gesture(drag())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pending ? "Car token, not saved yet" : "Car token")
            .accessibilityHint(pending
                ? "Drag to move the car, or use the actions."
                : "Drag to a curb to park, or use the action to place it at your location.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Place at my location") { _ = placeAtUser() }
            .accessibilityActions {
                if pending {
                    Button(WPParkFlowCopy.moveForward) { nudge(WPParkFlowController.nudgeMeters) }
                    Button(WPParkFlowCopy.moveBack) { nudge(-WPParkFlowController.nudgeMeters) }
                    if flow.alternateSnap != nil {
                        Button(WPParkSideCopy.otherSide) { switchSide() }
                    }
                }
            }
    }

    private func drag() -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let ctx = resolveContext()
                if flow.phase != .dragging {
                    let start = windowPoint() ?? restingPoint
                    grabOffset = CGSize(width: start.x - value.startLocation.x, height: start.y - value.startLocation.y)
                    flow.beginDrag(from: start)
                    flow.prepareIndex(segments: ctx.segments)
                }
                let point = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
                flow.update(
                    point: point, coordinate: coordinateForPoint(point), metersPerPoint: metersPerPoint(),
                    engine: ctx.engine, now: ctx.now, windowEnd: ctx.windowEnd, trip: ctx.trip,
                    reports: ctx.reports
                )
            }
            .onEnded { value in
                let point = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
                // The car lands on the foot point (and glides there); the ground point is stored, not
                // this window point.
                flow.endDrag(landingPoint: point)
            }
    }

    private func nudge(_ meters: Double) {
        let ctx = resolveContext()
        let moved = flow.nudge(
            meters: meters, point: windowPoint() ?? restingPoint, metersPerPoint: metersPerPoint(),
            engine: ctx.engine, now: ctx.now, windowEnd: ctx.windowEnd, trip: ctx.trip, reports: ctx.reports
        )
        let spoken = moved ? (flow.model?.title ?? "Moved") : WPParkFlowCopy.dropOnCurb
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    private func originRing(origin: CGPoint) -> some View {
        Group {
            if flow.phase == .dragging, let o = flow.originPoint {
                Circle()
                    .strokeBorder(WP.hairline, style: StrokeStyle(lineWidth: WP.Border.control, dash: [6, 5]))
                    .frame(width: WP.Marker.carToken, height: WP.Marker.carToken)
                    .position(localPoint(o, origin: origin))
                    .accessibilityHidden(true)
            }
        }
    }

    /// The curb under the car while it is in hand: a dot on the foot point, so it is clear which curb
    /// the verdict is about.
    @ViewBuilder
    private func snapDot(origin: CGPoint) -> some View {
        if flow.phase == .dragging, let snap = flow.snap, let w = pointForCoordinate(snap.snappedCoordinate) {
            Circle()
                .fill(WP.ink)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(WP.card, lineWidth: 3))
                .position(localPoint(w, origin: origin))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func hint(at p: CGPoint) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        return Text("Drag to a curb to park")
            .font(WP.Font.fredoka(14, .semibold, relativeTo: .callout))
            .foregroundStyle(WP.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, WP.Space.s3)
            .padding(.vertical, WP.Space.s2)
            .background(shape.fill(WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .position(x: p.x, y: p.y - 56)
            .allowsHitTesting(false)
    }

    // MARK: Bubble above the token

    /// What the bubble says right now. The verdict is only ever the curb under the car: over no curb it
    /// says so, and it never keeps a previous green.
    private func bubbleContent() -> WPDragBubble? {
        if flow.notice != nil { return .dropOnCurb }
        if flow.phase == .dragging, !flow.indexReady, flow.model == nil { return .gettingReady }
        if let model = flow.model { return WPDragBubble.make(from: model, windowName: nil) }
        return flow.phase == .dragging ? .noCurb : nil
    }

    @ViewBuilder
    private func bubble(at p: CGPoint, width: CGFloat) -> some View {
        if let content = bubbleContent() {
            WPDragBubbleView(bubble: content)
                .position(x: min(max(p.x, 148), max(148, width - 148)), y: p.y - 84)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: Bottom card

    @ViewBuilder
    private var bottomCard: some View {
        switch flow.phase {
        case .idle:
            EmptyView()
        case .dragging:
            dragSheet
        case .placed:
            if let model = flow.model {
                WPParkConfirmCard(
                    model: model, address: address,
                    onPark: onConfirm,
                    onCancel: { flow.reset() },
                    onSwitchSide: flow.alternateSnap == nil ? nil : { switchSide() }
                )
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { cardHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in cardHeight = h }
                })
            } else {
                Color.clear.frame(height: 0).onAppear { cardHeight = 0 }
            }
        }
    }

    /// "Other side of the street": swap the snap; the car glides to the other curb (its ground point
    /// moved, the layer projects it).
    private func switchSide() {
        let ctx = resolveContext()
        flow.switchSide(
            engine: ctx.engine, now: ctx.now, windowEnd: ctx.windowEnd, trip: ctx.trip, reports: ctx.reports
        )
    }

    private var dragSheet: some View {
        let bubble = bubbleContent()
        return WPSheetShell {
            Text(bubble?.hint ?? "Drop the car where you parked")
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(flow.model?.title ?? bubble?.headline ?? "It snaps to the nearest curb.")
                .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WP.Space.s1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bubble

struct WPDragBubbleView: View {
    let bubble: WPDragBubble

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        let isPark = bubble.tone == .park
        VStack(spacing: 0) {
            Text(bubble.headline)
                .font(WP.Font.fredoka(18, .bold, relativeTo: .headline))
            if !bubble.detail.isEmpty {
                Text(bubble.detail)
                    .font(WP.Font.fredoka(14, .semibold, relativeTo: .callout))
            }
        }
        .foregroundStyle(isPark ? WP.ink : WP.text)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s2)
        .frame(maxWidth: 280)
        .background(shape.fill(isPark ? WP.park : WP.card))
        .overlay(bubbleOutline(shape: shape))
    }

    @ViewBuilder
    private func bubbleOutline(shape: RoundedRectangle) -> some View {
        switch bubble.tone {
        case .park:
            shape.strokeBorder(WP.ink, lineWidth: WP.Border.fact)
        case .soon:
            shape.strokeBorder(WP.detailSoon, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
        case .dont:
            shape.strokeBorder(WP.noParkLine, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
        }
    }
}

// MARK: - Confirm card (B6.4 / B6.5)

struct WPParkConfirmCard: View {
    let model: WPCurbSheetModel
    /// "In front of 50 E 1st St" when the address resolved, else nil.
    let address: String?
    let onPark: () -> Void
    /// Discards the pending draft (nothing was saved).
    let onCancel: () -> Void
    /// DT35-2: "Other side of the street". Nil hides the button (no opposite curb in the data).
    var onSwitchSide: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WPSheetShell {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
                // At accessibility sizes the verdict would push Park here off the screen: the
                // information scrolls in the upper part, the actions stay pinned below it.
                if typeSize.isAccessibilitySize {
                    ScrollView { VStack(alignment: .leading, spacing: WP.Space.s3) { info } }
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.36)
                } else {
                    info
                }
                actions
                if let onSwitchSide {
                    Button(action: onSwitchSide) { Text(WPParkSideCopy.otherSide) }
                        .buttonStyle(WPParkSideSecondaryStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var info: some View {
                WPNotSavedChip()
                VStack(alignment: .leading, spacing: 2) {
                    Text(address ?? model.title)
                        .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if address != nil {
                        Text(model.title)
                            .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                            .foregroundStyle(WP.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                WPVerdictBlock(
                    kind: model.variant.blockKind, over: model.over, big: model.big, sub: model.sub,
                    fractionLeft: model.variant == .park ? model.fractionLeft : nil
                )
                if !model.offersPrimaryPark {
                    Text(WPParkCopy.warning(for: model.variant))
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.noParkText)
                        .fixedSize(horizontal: false, vertical: true)
                }
    }

    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: WP.Space.s3))
            : AnyLayout(HStackLayout(spacing: WP.Space.s3))
        return layout {
            // The round button is a fixed disc: at accessibility sizes the word would overflow it.
            Group {
                if typeSize.isAccessibilitySize {
                    Button(action: onCancel) { Text(WPParkFlowCopy.cancel) }
                        .buttonStyle(.wpSecondary)
                } else {
                    Button(action: onCancel) { Text(WPParkFlowCopy.cancel) }
                        .buttonStyle(.wpRound)
                }
            }
            .accessibilityHint("Discards this placement. Nothing was saved.")
            if model.offersPrimaryPark {
                Button(model.ctaTitle, action: onPark)
                    .buttonStyle(RaisedButtonStyle(size: .commitment))
                    .padding(.bottom, WP.Raise.lg)
            } else {
                Button(action: onPark) {
                    Text(model.ctaTitle)
                        .font(WP.Font.fredoka(19, .semibold, relativeTo: .title3))
                        .foregroundStyle(WP.text)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, WP.Space.s4)
                        .padding(.vertical, WP.Space.s2)
                        .frame(maxWidth: .infinity, minHeight: WP.Control.commitmentHeight)
                        .background(Capsule().fill(WP.card))
                        .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// "Not saved yet": the pending state, spoken and drawn (dashed, like the pending car token).
struct WPNotSavedChip: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s1))
            : AnyLayout(HStackLayout(spacing: WP.Space.s2))
        return layout {
            Text(WPParkFlowCopy.notSavedYet)
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .padding(.horizontal, WP.Space.s3)
                .padding(.vertical, WP.Space.s1)
                .overlay(
                    Capsule().strokeBorder(WP.ink, style: StrokeStyle(lineWidth: WP.Border.fact, dash: [6, 4]))
                )
            Text(WPParkFlowCopy.notSavedHint)
                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WPParkFlowCopy.notSavedSpoken)
        .onAppear {
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: WPParkFlowCopy.notSavedYet)
            }
        }
    }
}

enum WPParkCopy {
    /// The warning on a curb that is not a clear spot. Never claims a specific restriction for
    /// an unclear or no-data curb.
    nonisolated static func warning(for variant: WPCurbVariant) -> String {
        switch variant {
        case .nodata: return "We have no sign data here. You can still save your car, but read the signs first."
        case .unclear: return "One sign here is unclear. You can still save your car, but check the posted sign first."
        case .meter: return "This curb is metered. You can still save your car here."
        default: return "Parking here is not allowed right now. You can still save your car, but you may be ticketed."
        }
    }

    /// "We'll remind you 1 hour before a restriction starts." from the user's real offsets.
    nonisolated static func reminderLead(_ offsets: ReminderOffsets) -> String {
        var parts: [String] = []
        if offsets.remindNightBefore { parts.append("the night before") }
        if offsets.remind2Hours { parts.append("2 hours before") }
        if offsets.remind1Hour { parts.append("1 hour before") }
        if offsets.remind30Min { parts.append("30 minutes before") }
        if offsets.remind15Min { parts.append("15 minutes before") }
        guard !parts.isEmpty else { return "We'll remind you before a restriction starts." }
        let joined: String
        if parts.count == 1 { joined = parts[0] } else {
            joined = parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }
        return "We'll remind you \(joined)."
    }
}

// MARK: - Reminder priming (B6.6, first park only)

/// Replaces `NotificationRationaleView` flag-on. Same permission request and shown-once key; the
/// marker is already flat (the car is parked whether or not they allow).
struct WPReminderPrimingSheet: View {
    /// "Parked. Free until Mon 9:00 AM." (from the engine), or just "Parked." when unknown.
    let parkedLine: String
    let offsets: ReminderOffsets
    let onDismiss: () -> Void
    let onPermissionGranted: () -> Void

    @State private var denied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if denied {
                Text("Reminders are off")
                    .font(WP.Font.fredoka(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .accessibilityAddTraits(.isHeader)
                Text("To get parking reminders, turn on notifications for WePark in Settings.")
                    .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WP.Space.s2)
                Button("Open Settings") { openSettings() }
                    .buttonStyle(RaisedButtonStyle(size: .commitment))
                    .padding(.top, WP.Space.s4)
                    .padding(.bottom, WP.Raise.lg)
                Button("Done", action: onDismiss)
                    .buttonStyle(.wpSecondary)
            } else {
                Text(parkedLine)
                    .font(WP.Font.fredoka(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Want a reminder before street cleaning?")
                    .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WP.Space.s2)
                Text("\(WPParkCopy.reminderLead(offsets)) You can change this any time.")
                    .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WP.Space.s1)
                Button("Remind me") { request() }
                    .buttonStyle(RaisedButtonStyle(size: .commitment))
                    .padding(.top, WP.Space.s4)
                    .padding(.bottom, WP.Raise.lg)
                    .accessibilityHint("Shows the iOS notification permission prompt")
                Button("Not now") {
                    UserDefaults.standard.set(true, forKey: AppConstants.notificationRationaleShownKey)
                    onDismiss()
                }
                .buttonStyle(.wpSecondary)
            }
        }
        .padding(.horizontal, WP.Space.screenMargin)
        .padding(.top, WP.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WP.card.ignoresSafeArea())
    }

    private func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: AppConstants.notificationRationaleShownKey)
                if granted {
                    onPermissionGranted()
                    onDismiss()
                } else {
                    denied = true
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
