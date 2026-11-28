//
//  WPParkSideLogic.swift
//  WePark
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1 section 1C): the pure state and copy
//  behind the Stoop side-aware park card (`Views/WPParkSideCardV2.swift`). Flag-on only; flag off
//  never reaches it.
//
//  Four states, from `ParkSideDecision`:
//    ask        "Which side did you park on?": two big buttons plus a mini map. NO verdict, no
//               free-until, no green/red until a side is chosen (`showsVerdict == false`).
//    picked     a side is chosen (resolver was confident, or the user chose): verdict, "Park here",
//               "Other side of the street" (hidden when the data has no opposite curb).
//    weakFix    GPS unusable: "Waiting for a better GPS signal", nothing is picked.
//    noCurb     nothing within 35 m: today's no-data wording.
//
//  Wording is driver's-seat: "Curb on my right / left" is relative to the retained approach course
//  (NYC parks with traffic). With no usable course the buttons say "This side" and the compass side
//  does the work. Never the phone's heading.
//
//  Pure and `nonisolated`. Never logs.
//

import Foundation
import CoreLocation

// MARK: - Copy

nonisolated enum WPParkSideCopy {
    static let askTitle = "Which side did you park on?"
    static let askHint = "Tap a curb on the map, or a button."
    static let curbRight = "Curb on my right"
    static let curbLeft = "Curb on my left"
    static let thisSide = "This side"
    static let otherSide = "Other side of the street"
    static let weakFixTitle = "Waiting for a better GPS signal"
    static let weakFixBody = "We can't tell which side of the street you are on yet. We won't guess."
    static let tryAgain = "Try again"
    static let placeOnMap = "Place it on the map"
    static let cancel = "Cancel"
    static let noCurbSave = "Save car here"
    static let miniMapLabel = "Map of both curbs of this block with your car between them"

    /// "Curb on your right" / "Curb on your left" (the saved-car and result sub-line, second person).
    static func handLine(_ hand: ParkSideHand) -> String {
        hand == .right ? "Curb on your right" : "Curb on your left"
    }

    static func handButton(_ hand: ParkSideHand) -> String {
        hand == .right ? curbRight : curbLeft
    }

    /// "Curb on your right \u{00B7} South side", or just "South side" with no usable reference.
    static func sideLine(side: String, hand: ParkSideHand?) -> String {
        let compass = WPCurbCopy.sideLabel(side)
        guard let hand else { return compass }
        return "\(handLine(hand)) \u{00B7} \(compass)"
    }

    /// "15 Stanton St" for a VERIFIED address only (an approximate number is never offered as a
    /// way to tell the curbs apart).
    static func verifiedNumberAndStreet(_ address: ParkingAddress?) -> String? {
        guard let address, address.confidence == .verified else { return nil }
        return ParkingAddressCopy.numberAndStreet(address)
    }

    /// VoiceOver form of the street: "15 Stanton Street".
    static func verifiedSpokenNumberAndStreet(_ address: ParkingAddress?) -> String? {
        guard let address, address.confidence == .verified else { return nil }
        let canonical = StreetNameNormalizer.canonical(address.streetDisplay)
        let street = CurbPlacementCardModel.expandedStreetName(StreetNameFormatter.display(canonical))
        return "\(address.houseNumber) \(street)"
    }
}

// MARK: - Ask buttons

nonisolated struct WPParkSideAskChoice: Equatable, Identifiable {
    let option: ParkSideOption
    /// "Curb on my right" / "Curb on my left" / "This side".
    let title: String
    /// "South side \u{00B7} near 15 Stanton St" (address only when verified).
    let detail: String
    /// "Curb on my right, south side, near 15 Stanton Street".
    let spoken: String
    /// The hand when the reference course is known.
    let hand: ParkSideHand?

    var id: String { option.segment.id }
}

// MARK: - Session

/// One presentation of the card: the resolver's decision at the moment of the tap plus where it came
/// from. `rawCoordinate` is the position used for the plain "no curb" save.
nonisolated struct WPParkSideSession: Identifiable {
    nonisolated enum Source: Equatable {
        /// Drive Mode "Park here" (after the sign checklist).
        case drive
        /// The arrival prompt's "Park here" (Drive Mode ends after the save).
        case arrival
    }

    let id = UUID()
    let decision: ParkSideDecision
    let source: Source
    let rawCoordinate: CLLocationCoordinate2D
}

nonisolated extension ParkingAddressRequest {
    /// The address request for one curb option.
    init(option: ParkSideOption) {
        self.init(
            segmentID: option.segment.id,
            side: option.segment.side,
            street: option.segment.street,
            line: option.segment.line,
            positionFraction: option.fraction
        )
    }
}

// MARK: - Focus

/// What the card is about right now, so the owner can resolve addresses for it (hints for both curbs
/// while asking, the placement address for the picked curb). Equatable so a change can be observed.
nonisolated enum WPParkSideFocus: Equatable {
    case none
    case ask(ParkSideOption, ParkSideOption)
    case picked(ParkSideOption)
}

// MARK: - Model

nonisolated struct WPParkSideCardModel: Equatable {

    nonisolated enum Phase: Equatable {
        case ask, picked, weakFix, noCurb
    }

    private(set) var phase: Phase
    /// Present in `.ask` (and kept after the user picks, so the card can show the map again).
    private(set) var choice: ParkSideChoice?
    /// The side the card is currently about (`.picked`).
    private(set) var current: ParkSidePick?
    /// The other curb of the block, for "Other side of the street". Nil = no switch offered.
    private(set) var alternate: ParkSideOption?

    /// `segments` is only read to find the opposite curb of a confident pick.
    init(decision: ParkSideDecision, segments: [Segment]) {
        switch decision {
        case .confident(let pick):
            phase = .picked
            current = pick
            alternate = ParkSideResolver.switched(from: pick.option, in: segments)
        case .onlyCurb(let pick):
            phase = .picked
            current = pick
            alternate = nil
        case .ask(let choice):
            phase = .ask
            self.choice = choice
        case .weakFix:
            phase = .weakFix
        case .noCurb:
            phase = .noCurb
        }
    }

    // MARK: Derived

    var focus: WPParkSideFocus {
        switch phase {
        case .ask:
            guard let choice else { return .none }
            return .ask(choice.first, choice.second)
        case .picked:
            guard let current else { return .none }
            return .picked(current.option)
        case .weakFix, .noCurb:
            return .none
        }
    }

    /// No verdict, free-until or green/red unless a side is picked.
    var showsVerdict: Bool { phase == .picked && current != nil }

    /// The segment the verdict is for (nil in every state without a pick).
    var verdictSegment: Segment? { showsVerdict ? current?.segment : nil }

    /// "Other side of the street" is offered (hidden, not disabled, when there is no other side).
    var canSwitch: Bool { phase == .picked && alternate != nil }

    /// What gets saved (`nil` until a side is picked).
    var selectedPick: ParkSidePick? { phase == .picked ? current : nil }

    /// "Curb on your right \u{00B7} South side" for the picked side (compass only with no reference).
    var pickedSideLine: String? {
        guard let current else { return nil }
        return WPParkSideCopy.sideLine(side: current.segment.side, hand: pickedHand)
    }

    var pickedHand: ParkSideHand? {
        guard let current, let bearing = current.travelBearing, let alternate else { return nil }
        return ParkSideResolver.hand(of: current.option, versus: alternate, travelBearing: bearing)
    }

    // MARK: Transitions

    /// Ask state: the user chose `option` (a button or a tap on the map).
    mutating func choose(_ option: ParkSideOption) {
        guard phase == .ask, let choice else { return }
        let other: ParkSideOption
        if option.segment.id == choice.first.segment.id {
            other = choice.second
        } else if option.segment.id == choice.second.segment.id {
            other = choice.first
        } else {
            return
        }
        current = ParkSideResolver.userChose(option, position: choice.position, travelBearing: choice.travelBearing)
        alternate = other
        phase = .picked
    }

    /// "Other side of the street": flips to the other curb; a second tap flips back. The basis
    /// becomes `.userChose`.
    mutating func switchSide() {
        guard phase == .picked, let current, let alternate else { return }
        self.current = ParkSideResolver.userChose(
            alternate, position: current.position, travelBearing: current.travelBearing
        )
        self.alternate = current.option
    }

    // MARK: Ask buttons

    /// The two buttons, in a stable order: right then left when the reference course is known,
    /// else by compass (north / west first, matching the mini map).
    func askChoices(hints: [String: ParkingAddress]) -> [WPParkSideAskChoice] {
        guard phase == .ask, let choice else { return [] }
        let options = [choice.first, choice.second]
        let hands: [ParkSideHand?] = [
            handForAsk(choice.first, other: choice.second, bearing: choice.travelBearing),
            handForAsk(choice.second, other: choice.first, bearing: choice.travelBearing)
        ]
        // Right/left only when both options resolve to different hands.
        let usable = hands[0] != nil && hands[1] != nil && hands[0] != hands[1]
        var built: [WPParkSideAskChoice] = []
        for index in 0..<2 {
            let option = options[index]
            let hand = usable ? hands[index] : nil
            let title = hand.map(WPParkSideCopy.handButton) ?? WPParkSideCopy.thisSide
            let compass = WPCurbCopy.sideLabel(option.segment.side)
            let hint = hints[option.segment.id]
            var detail = compass
            var spoken = "\(title), \(compass.lowercased())"
            if let number = WPParkSideCopy.verifiedNumberAndStreet(hint) {
                detail += " \u{00B7} near \(number)"
            }
            if let number = WPParkSideCopy.verifiedSpokenNumberAndStreet(hint) {
                spoken += ", near \(number)"
            }
            built.append(WPParkSideAskChoice(
                option: option, title: title, detail: detail, spoken: spoken, hand: hand
            ))
        }
        return built.sorted { lhs, rhs in
            if let l = lhs.hand, let r = rhs.hand { return l == .right && r == .left }
            return Self.compassRank(lhs.option.segment.side) < Self.compassRank(rhs.option.segment.side)
        }
    }

    private func handForAsk(_ option: ParkSideOption, other: ParkSideOption, bearing: Double?) -> ParkSideHand? {
        guard let bearing else { return nil }
        return ParkSideResolver.hand(of: option, versus: other, travelBearing: bearing)
    }

    /// North and west first (top and left of a north-up map).
    private static func compassRank(_ side: String) -> Int {
        switch side.uppercased() {
        case "N": return 0
        case "W": return 1
        case "E": return 2
        case "S": return 3
        default: return 4
        }
    }
}

// MARK: - Mini map layout

/// Screen layout of the chooser's mini map: both curbs and the car, drawn schematically (not map
/// tiles) so the hit areas are exact and the picture is stable. The street runs left to right. With
/// a known course the car travels toward the right edge (so "Curb on my right" is the lower curb,
/// as in a top-down map of a car heading right); without one the street is turned so east (or
/// north, on a north-south street) points right.
nonisolated enum WPParkSideMiniMapLayout {

    nonisolated struct Layout: Equatable {
        /// Points in the rect `[0, width] x [0, height]`, y growing downward.
        let first: [CGPoint]
        let second: [CGPoint]
        let car: CGPoint
        /// True when the car should draw a direction arrow (a usable course exists).
        let showsTravelArrow: Bool
        /// Screen y that separates the two curbs' tap areas.
        let dividerY: CGFloat
        /// `first` curb is the upper one.
        let firstIsUpper: Bool
    }

    static func make(
        first: [CLLocationCoordinate2D],
        second: [CLLocationCoordinate2D],
        car: CLLocationCoordinate2D,
        travelBearing: Double?,
        size: CGSize,
        padding: CGFloat = 30
    ) -> Layout? {
        guard first.count >= 2, second.count >= 2, size.width > 0, size.height > 0 else { return nil }

        // Street axis from the first curb's end points.
        let firstEnd = delta(from: first[0], to: first[first.count - 1])
        let axisLength = hypot(firstEnd.east, firstEnd.north)
        guard axisLength > 1 else { return nil }
        var axis = (east: firstEnd.east / axisLength, north: firstEnd.north / axisLength)

        // Pick which of the two directions along the axis points to the right edge.
        if let travelBearing {
            let radians = travelBearing * Double.pi / 180
            let dot = axis.east * sin(radians) + axis.north * cos(radians)
            if dot < 0 { axis = (-axis.east, -axis.north) }
        } else if abs(axis.east) > 1e-6 {
            if axis.east < 0 { axis = (-axis.east, -axis.north) }
        } else if axis.north < 0 {
            axis = (-axis.east, -axis.north)
        }
        // "Up" on screen is to the left of travel (a counter-clockwise quarter turn).
        let up = (east: -axis.north, north: axis.east)

        func project(_ coordinate: CLLocationCoordinate2D) -> (x: Double, up: Double) {
            let d = delta(from: car, to: coordinate)
            return (d.east * axis.east + d.north * axis.north, d.east * up.east + d.north * up.north)
        }
        var a = first.map(project)
        var b = second.map(project)
        // DT35-3 F1: real blocks are cut into pieces per side, so the two curbs can start and end at
        // different places along the street. Draw only the span both curbs share, so the two lines
        // read as aligned (no trapezoid). Skipped when they barely overlap.
        if let span = commonSpan(a, b) {
            let clippedA = clip(a, lo: span.lo, hi: span.hi)
            let clippedB = clip(b, lo: span.lo, hi: span.hi)
            if clippedA.count >= 2, clippedB.count >= 2 {
                a = clippedA
                b = clippedB
            }
        }
        let carPoint = project(car)
        let all = a + b + [carPoint]
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minUp = all.map(\.up).min(), let maxUp = all.map(\.up).max() else { return nil }

        // A floor on the extent keeps a short block from zooming to absurdity.
        let spanX = max(maxX - minX, 20)
        let spanUp = max(maxUp - minUp, 20)
        let usableWidth = max(1, Double(size.width - 2 * padding))
        let usableHeight = max(1, Double(size.height - 2 * padding))
        let scale = min(usableWidth / spanX, usableHeight / spanUp)
        let centerX = (minX + maxX) / 2
        let centerUp = (minUp + maxUp) / 2

        func screen(_ p: (x: Double, up: Double)) -> CGPoint {
            CGPoint(
                x: size.width / 2 + CGFloat((p.x - centerX) * scale),
                y: size.height / 2 - CGFloat((p.up - centerUp) * scale)
            )
        }
        let firstPoints = a.map(screen)
        let secondPoints = b.map(screen)
        let meanFirst = firstPoints.map(\.y).reduce(0, +) / CGFloat(firstPoints.count)
        let meanSecond = secondPoints.map(\.y).reduce(0, +) / CGFloat(secondPoints.count)
        return Layout(
            first: firstPoints,
            second: secondPoints,
            car: screen(carPoint),
            showsTravelArrow: travelBearing != nil,
            dividerY: (meanFirst + meanSecond) / 2,
            firstIsUpper: meanFirst <= meanSecond
        )
    }

    /// Smallest overlap (metres along the street) worth clipping to.
    static let minimumCommonSpanMeters = 5.0

    /// The along-street range both polylines cover, or nil when they overlap by less than
    /// `minimumCommonSpanMeters`.
    static func commonSpan(
        _ a: [(x: Double, up: Double)], _ b: [(x: Double, up: Double)]
    ) -> (lo: Double, hi: Double)? {
        guard let aMin = a.map(\.x).min(), let aMax = a.map(\.x).max(),
              let bMin = b.map(\.x).min(), let bMax = b.map(\.x).max() else { return nil }
        let lo = max(aMin, bMin)
        let hi = min(aMax, bMax)
        guard hi - lo >= minimumCommonSpanMeters else { return nil }
        return (lo, hi)
    }

    /// The part of the polyline whose along-street coordinate is inside `[lo, hi]`, with the cut
    /// ends interpolated exactly onto the boundary.
    static func clip(
        _ points: [(x: Double, up: Double)], lo: Double, hi: Double
    ) -> [(x: Double, up: Double)] {
        var result: [(x: Double, up: Double)] = []
        func append(_ point: (x: Double, up: Double)) {
            if let last = result.last, abs(last.x - point.x) < 1e-9, abs(last.up - point.up) < 1e-9 { return }
            result.append(point)
        }
        guard points.count >= 2 else { return [] }
        for index in 1..<points.count {
            let p = points[index - 1]
            let q = points[index]
            let dx = q.x - p.x
            var tIn = 0.0
            var tOut = 1.0
            if abs(dx) < 1e-12 {
                guard p.x >= lo, p.x <= hi else { continue }
            } else {
                let t0 = (lo - p.x) / dx
                let t1 = (hi - p.x) / dx
                tIn = max(0, min(t0, t1))
                tOut = min(1, max(t0, t1))
                guard tIn < tOut else { continue }
            }
            append((p.x + tIn * dx, p.up + tIn * (q.up - p.up)))
            append((p.x + tOut * dx, p.up + tOut * (q.up - p.up)))
        }
        return result
    }

    private static func delta(
        from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D
    ) -> (east: Double, north: Double) {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLng = metersPerDegreeLat * cos(a.latitude * Double.pi / 180)
        return ((b.longitude - a.longitude) * metersPerDegreeLng, (b.latitude - a.latitude) * metersPerDegreeLat)
    }
}

// MARK: - My Car flip memory (DT35-3 F2)

/// Remembers the two curbs of a "Wrong side? Switch" so flipping twice returns EXACTLY to where the
/// car started (same piece, same coordinate). Re-projecting from the live car each time drifted 1-11 m
/// and could land on the adjacent piece of a multi-piece block (5.6% of sampled cases). The memory
/// only applies while the saved car is still at one of the two remembered curbs; any other change to
/// the car (a re-park, a different car) makes it fall away and the target is recomputed.
nonisolated struct WPSideFlipMemory: Equatable {
    private(set) var first: ParkSideOption?
    private(set) var second: ParkSideOption?

    init() {}

    /// The car was at `current` and the user flipped it to `target`.
    mutating func recordFlip(from current: ParkSideOption, to target: ParkSideOption) {
        first = current
        second = target
    }

    /// The pair to offer for a car saved at (`segmentID`, `coordinate`): `here` is that curb as
    /// remembered, `target` the other one. Nil when the car is at neither remembered curb.
    func pair(
        segmentID: String?, coordinate: CLLocationCoordinate2D
    ) -> (here: ParkSideOption, target: ParkSideOption)? {
        guard let segmentID, let first, let second else { return nil }
        if Self.matches(first, segmentID: segmentID, coordinate: coordinate) { return (first, second) }
        if Self.matches(second, segmentID: segmentID, coordinate: coordinate) { return (second, first) }
        return nil
    }

    private static func matches(
        _ option: ParkSideOption, segmentID: String, coordinate: CLLocationCoordinate2D
    ) -> Bool {
        option.segment.id == segmentID
            && abs(option.coordinate.latitude - coordinate.latitude) < 1e-9
            && abs(option.coordinate.longitude - coordinate.longitude) < 1e-9
    }
}
