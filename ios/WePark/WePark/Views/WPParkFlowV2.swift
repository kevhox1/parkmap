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
//    placed    token lands on the curb; confirm card: "In front of <address>", verdict, "Park here"
//              or "Park here anyway" (+ a warning on a don't curb), "Move" puts it back in the hand
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

// MARK: - Controller

@MainActor
@Observable
final class WPParkFlowController {

    enum Phase: Equatable { case idle, dragging, placed }

    private(set) var phase: Phase = .idle
    /// Token center in window coordinates (nil = parked at the rest position).
    private(set) var tokenPoint: CGPoint?
    /// Where the drag started (drawn as the dashed "came from" ring).
    private(set) var originPoint: CGPoint?
    private(set) var snap: CurbSnapResult?
    private(set) var model: WPCurbSheetModel?
    private(set) var indexReady = false

    @ObservationIgnored private var index: CurbSnapIndex?
    @ObservationIgnored private var indexKey: Int?
    @ObservationIgnored private var lastSegmentID: String?
    @ObservationIgnored private let selection = UISelectionFeedbackGenerator()
    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let notify = UINotificationFeedbackGenerator()

    /// Snap radius while a finger is dragging: about one block face wide.
    nonisolated static let snapMeters: Double = 40

    /// Builds (or reuses) the snap index for the loaded segments, off the main thread.
    func prepareIndex(segments: [Segment]) {
        let key = CurbPlacementPolicy.segmentsVersion(
            count: segments.count, firstID: segments.first?.id, lastID: segments.last?.id
        )
        if indexKey == key, index != nil { return }
        indexKey = key
        Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) { CurbSnapIndex(segments: segments) }.value
            guard indexKey == key else { return }
            index = built
            indexReady = true
        }
    }

    func beginDrag(from point: CGPoint) {
        guard phase != .dragging else { return }
        phase = .dragging
        originPoint = originPoint ?? point
        tokenPoint = point
        lastSegmentID = nil
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
            config: CurbSnapConfig(acquireRadius: Self.snapMeters, releaseRadius: Self.snapMeters + 8)
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

    /// Finger lifted: a snapped token lands on the curb (confirm card); otherwise it goes home.
    /// Returns true when it placed.
    @discardableResult
    func endDrag(landingPoint: CGPoint?) -> Bool {
        guard phase == .dragging else { return false }
        if snap != nil, model != nil {
            phase = .placed
            if let landingPoint { tokenPoint = landingPoint }
            impact.impactOccurred()
            return true
        }
        reset()
        return false
    }

    /// "Move": back in the hand, from the placed position.
    func pickUpAgain() {
        guard phase == .placed else { return }
        phase = .dragging
        originPoint = tokenPoint
    }

    func reset() {
        phase = .idle
        tokenPoint = nil
        originPoint = nil
        snap = nil
        model = nil
        lastSegmentID = nil
    }
}

// MARK: - Layer

/// Full-screen layer over the map. Only the token (and, while dragging or placed, a map-blocking
/// catcher) takes touches; everything else falls through to the map.
struct WPParkLayerV2: View {
    @Bindable var flow: WPParkFlowController
    /// Show the idle token (no parked car, no sheet, no trip plan).
    let showsRestingToken: Bool
    /// "Drag to a curb to park" next to the idle token. Off after the first successful park.
    let showsDragHint: Bool
    /// Window point -> ground coordinate (map projection seam).
    let coordinateForPoint: (CGPoint) -> CLLocationCoordinate2D?
    /// Ground coordinate -> window point (map projection seam), to land the token on the curb.
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

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var grabOffset: CGSize = .zero

    private var visible: Bool { flow.phase != .idle || showsRestingToken }

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if flow.phase != .idle {
                    // Blocks map pan while the car is in hand / waiting for confirmation.
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0))
                }
                if visible {
                    originRing(origin: origin)
                    token(origin: origin)
                    if flow.phase == .idle, showsDragHint { hint(origin: origin) }
                    if flow.phase == .dragging || flow.phase == .placed { bubble(origin: origin, width: proxy.size.width) }
                }
                VStack {
                    Spacer()
                    bottomCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(visible)
    }

    // MARK: Token

    private func localPoint(_ window: CGPoint, origin: CGPoint) -> CGPoint {
        CGPoint(x: window.x - origin.x, y: window.y - origin.y)
    }

    private func token(origin: CGPoint) -> some View {
        let window = flow.tokenPoint ?? restingPoint
        let p = localPoint(window, origin: origin)
        let lifted = flow.phase == .dragging
        return WPCarToken(isLifted: lifted)
            .scaleEffect(lifted ? 64.0 / 56.0 : 1)
            .position(p)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: flow.phase)
            .gesture(drag(origin: origin))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(flow.phase == .placed ? "Car token, placed" : "Car token")
            .accessibilityHint("Drag to a curb to park, or use the action to place it at your location.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Place at my location") { _ = placeAtUser() }
    }

    private func drag(origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let ctx = resolveContext()
                if flow.phase != .dragging {
                    let start = flow.tokenPoint ?? restingPoint
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
                let landing = flow.snap.flatMap { pointForCoordinate($0.snappedCoordinate) } ?? point
                flow.endDrag(landingPoint: landing)
            }
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

    private func hint(origin: CGPoint) -> some View {
        let p = localPoint(flow.tokenPoint ?? restingPoint, origin: origin)
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

    @ViewBuilder
    private func bubble(origin: CGPoint, width: CGFloat) -> some View {
        if let model = flow.model {
            let p = localPoint(flow.tokenPoint ?? restingPoint, origin: origin)
            WPDragBubbleView(bubble: WPDragBubble.make(from: model, windowName: nil))
                .position(x: min(max(p.x, 148), max(148, width - 148)), y: p.y - 78)
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
                    onMove: { flow.pickUpAgain() }
                )
            }
        }
    }

    private var dragSheet: some View {
        let bubble = flow.model.map { WPDragBubble.make(from: $0, windowName: nil) }
        return WPSheetShell {
            Text(bubble?.hint ?? "Drop the car where you parked")
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(flow.model?.title ?? "It snaps to the nearest curb.")
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
    let onMove: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WPSheetShell {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
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
                actions
            }
        }
    }

    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: WP.Space.s3))
            : AnyLayout(HStackLayout(spacing: WP.Space.s3))
        return layout {
            Button(action: onMove) { Text("Move") }
                .buttonStyle(.wpRound)
                .accessibilityHint("Picks the car back up")
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
