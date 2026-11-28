//
//  StoopParkSideCardTests.swift
//  WeParkTests
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1 sections 1C to 1E): the Stoop side card's
//  pure model and copy, the mini-map layout, the token-path "Other side of the street", My Car's
//  `replaceSide`, and the regression that documents why the legacy "Wrong street?" dedupe is left
//  alone. Fixtures come from `ParkSideTestFixtures` (ParkSideResolverTests.swift).
//

import XCTest
import Combine
import CoreLocation
@testable import WePark

// MARK: - Model and copy

final class StoopParkSideCardModelTests: XCTestCase {

    private typealias F = ParkSideTestFixtures

    private func decision(
        oneway: Bool?, approachEastbound: Bool?, stopY: Double = 6, accuracy: Double = 6
    ) -> ParkSideDecision {
        let segments = F.pair(oneway: oneway)
        let track = approachEastbound.map { F.approach(eastbound: $0, y: stopY) } ?? []
        let stop = F.fix(x: 0, y: stopY, accuracy: accuracy, speed: 0)
        return ParkSideResolver.decide(fix: stop, track: track, segments: segments, now: F.now)
    }

    private func address(_ confidence: ParkingAddress.Confidence = .verified) -> ParkingAddress {
        ParkingAddress(
            houseNumber: "15", streetDisplay: "Stanton Street", confidence: confidence,
            source: .mapkit, resolvedAt: F.now
        )
    }

    // MARK: Ask

    func testAsk_hasNoVerdictAndNoSelection() {
        let model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: true), segments: F.pair(oneway: true))
        XCTAssertEqual(model.phase, .ask)
        XCTAssertFalse(model.showsVerdict)
        XCTAssertNil(model.verdictSegment, "no verdict, free-until or green/red before a side is chosen")
        XCTAssertNil(model.selectedPick)
        XCTAssertFalse(model.canSwitch)
        XCTAssertNil(model.pickedSideLine)
        XCTAssertEqual(model.askChoices(hints: [:]).count, 2)
    }

    func testAsk_oneWayEastbound_northCurbIsOnMyLeft() {
        let segments = F.pair(oneway: true)
        let model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: true), segments: segments)
        let choices = model.askChoices(hints: [:])
        XCTAssertEqual(choices.map(\.title), [WPParkSideCopy.curbRight, WPParkSideCopy.curbLeft])
        XCTAssertEqual(choices.first?.option.segment.id, "S")
        let north = choices.first { $0.option.segment.id == "N" }
        XCTAssertEqual(north?.title, "Curb on my left")
        XCTAssertEqual(north?.detail, "North side")
        XCTAssertEqual(north?.hand, .left)
    }

    func testAsk_twoWayWithApproach_travelSideIsMyRight() {
        // Two-way, mid-gap, but the geometry vote and heading vote cannot decide here because the
        // fix is too inaccurate to count as a heading-only pick: use a left-curb geometry fix.
        let segments = F.pair(oneway: false)
        let track = F.approach(eastbound: true, y: 11)
        let stop = F.fix(x: 0, y: 11.5, accuracy: 4, speed: 0)
        let decided = ParkSideResolver.decide(fix: stop, track: track, segments: segments, now: F.now)
        let model = WPParkSideCardModel(decision: decided, segments: segments)
        XCTAssertEqual(model.phase, .ask)
        let choices = model.askChoices(hints: [:])
        XCTAssertEqual(choices.first { $0.option.segment.id == "S" }?.title, "Curb on my right")
        XCTAssertEqual(choices.first { $0.option.segment.id == "N" }?.title, "Curb on my left")
    }

    func testAsk_noCourse_saysThisSideWithCompassOnBoth() {
        let segments = F.pair(oneway: true)
        let model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: nil), segments: segments)
        let choices = model.askChoices(hints: [:])
        XCTAssertEqual(choices.map(\.title), [WPParkSideCopy.thisSide, WPParkSideCopy.thisSide])
        XCTAssertEqual(choices.map(\.detail), ["North side", "South side"])
        XCTAssertTrue(choices.allSatisfy { $0.hand == nil })
    }

    func testAsk_verifiedAddressHint_isShownAndSpoken_approximateIsNot() {
        let segments = F.pair(oneway: true)
        let model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: true), segments: segments)
        let verified = model.askChoices(hints: ["S": address(.verified), "N": address(.approximate)])
        let south = verified.first { $0.option.segment.id == "S" }
        let north = verified.first { $0.option.segment.id == "N" }
        XCTAssertEqual(south?.detail, "South side \u{00B7} near 15 Stanton St")
        XCTAssertEqual(south?.spoken, "Curb on my right, south side, near 15 Stanton Street")
        XCTAssertEqual(north?.detail, "North side", "an approximate number never helps tell the curbs apart")
        XCTAssertEqual(north?.spoken, "Curb on my left, north side")
    }

    func testAsk_choosing_givesUserChoseAndShowsTheVerdict() {
        let segments = F.pair(oneway: true)
        var model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: true), segments: segments)
        guard let south = model.askChoices(hints: [:]).first(where: { $0.option.segment.id == "S" }) else {
            return XCTFail("missing south choice")
        }
        model.choose(south.option)

        XCTAssertEqual(model.phase, .picked)
        XCTAssertTrue(model.showsVerdict)
        XCTAssertEqual(model.selectedPick?.basis, .userChose)
        XCTAssertEqual(model.selectedPick?.segment.id, "S")
        XCTAssertEqual(model.pickedSideLine, "Curb on your right \u{00B7} South side")
        XCTAssertTrue(model.canSwitch, "the other curb is the alternate")
    }

    func testChoose_ignoresACurbThatWasNotOffered() {
        let segments = F.pair(oneway: true)
        var model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: true), segments: segments)
        let stray = ParkSideOption(
            segment: F.curb(id: "X", side: "S", y: -40, oneway: true),
            coordinate: F.coordinate(x: 0, y: -40), fraction: 0.5
        )
        model.choose(stray)
        XCTAssertEqual(model.phase, .ask)
    }

    // MARK: Picked / switch

    func testConfident_togglesBetweenTheTwoCurbs_andBack() {
        let segments = F.pair(oneway: true)
        let confident = ParkSideResolver.decide(
            fix: F.fix(x: 0, y: 0.5, accuracy: 4), track: [], segments: segments, now: F.now
        )
        var model = WPParkSideCardModel(decision: confident, segments: segments)
        XCTAssertEqual(model.selectedPick?.segment.id, "S")
        XCTAssertEqual(model.selectedPick?.basis, .geometry)
        XCTAssertTrue(model.canSwitch)
        let before = model.selectedPick?.coordinate

        model.switchSide()
        XCTAssertEqual(model.selectedPick?.segment.id, "N")
        XCTAssertEqual(model.selectedPick?.basis, .userChose)
        XCTAssertGreaterThan(model.selectedPick?.coordinate.latitude ?? 0, before?.latitude ?? 0)
        XCTAssertEqual(model.pickedSideLine, "North side", "no course: compass only")

        model.switchSide()
        XCTAssertEqual(model.selectedPick?.segment.id, "S")
        XCTAssertEqual(model.selectedPick?.coordinate.latitude ?? 0, before?.latitude ?? -1, accuracy: 1e-9)
    }

    func testOnlyCurb_hidesTheSwitch() {
        let segments = [F.curb(id: "S", side: "S", y: 0, oneway: true)]
        let only = ParkSideResolver.decide(
            fix: F.fix(x: 0, y: 1, accuracy: 5), track: [], segments: segments, now: F.now
        )
        var model = WPParkSideCardModel(decision: only, segments: segments)
        XCTAssertEqual(model.phase, .picked)
        XCTAssertFalse(model.canSwitch)
        model.switchSide()
        XCTAssertEqual(model.selectedPick?.segment.id, "S", "switching with no other curb is a no-op")
    }

    func testWeakFixAndNoCurb_pickNothing() {
        for state in [ParkSideDecision.weakFix, .noCurb] {
            let model = WPParkSideCardModel(decision: state, segments: [])
            XCTAssertNil(model.selectedPick)
            XCTAssertFalse(model.showsVerdict)
            XCTAssertFalse(model.canSwitch)
            XCTAssertEqual(model.focus, WPParkSideFocus.none)
        }
    }

    func testFocus_followsTheState() {
        let segments = F.pair(oneway: true)
        var model = WPParkSideCardModel(decision: decision(oneway: true, approachEastbound: true), segments: segments)
        guard case .ask = model.focus else { return XCTFail("ask focus") }
        guard let first = model.askChoices(hints: [:]).first else { return XCTFail("no choices") }
        model.choose(first.option)
        guard case .picked(let option) = model.focus else { return XCTFail("picked focus") }
        XCTAssertEqual(option.segment.id, first.option.segment.id)
    }

    func testSideLine_withoutReferenceIsCompassOnly() {
        XCTAssertEqual(WPParkSideCopy.sideLine(side: "S", hand: nil), "South side")
        XCTAssertEqual(WPParkSideCopy.sideLine(side: "N", hand: .left), "Curb on your left \u{00B7} North side")
    }
}

// MARK: - Mini map layout

final class WPParkSideMiniMapLayoutTests: XCTestCase {

    private typealias F = ParkSideTestFixtures
    private let size = CGSize(width: 320, height: 160)

    private func layout(travelBearing: Double?, rotation: Double = 0) -> WPParkSideMiniMapLayout.Layout? {
        let segments = F.pair(oneway: true, rotation: rotation)
        return WPParkSideMiniMapLayout.make(
            first: segments[0].coordinates, second: segments[1].coordinates,
            car: F.coordinate(x: 0, y: 6, rotation: rotation), travelBearing: travelBearing, size: size
        )
    }

    func testNoCourse_northCurbIsUpperAndStreetRunsLeftToRight() {
        guard let layout = layout(travelBearing: nil) else { return XCTFail("no layout") }
        // `first` is the south curb: it is the LOWER one on a north-up map.
        XCTAssertFalse(layout.firstIsUpper)
        XCTAssertFalse(layout.showsTravelArrow)
        XCTAssertLessThan(layout.first[0].x, layout.first[1].x)
    }

    func testEastboundCourse_rightHandCurbIsTheLowerOne_andTheCarHasAnArrow() {
        guard let layout = layout(travelBearing: 90) else { return XCTFail("no layout") }
        XCTAssertTrue(layout.showsTravelArrow)
        XCTAssertGreaterThan(layout.first[0].y, layout.second[0].y, "south (right of eastbound travel) is lower")
    }

    func testWestboundCourse_flipsTheDrawing_soRightIsStillLower() {
        guard let layout = layout(travelBearing: 270) else { return XCTFail("no layout") }
        // Westbound: the north curb is on the driver's right, and the drawing is turned so travel
        // points to the right edge: north (right-hand) must now be the lower curb.
        XCTAssertLessThan(layout.first[0].y, layout.second[0].y)
    }

    func testRotatedStreet_givesTheSameDrawingAsTheUnrotatedOne() {
        guard let plain = layout(travelBearing: 90),
              let turned = layout(travelBearing: 90 - 29, rotation: 29) else { return XCTFail("no layout") }
        XCTAssertEqual(plain.first[0].x, turned.first[0].x, accuracy: 1)
        XCTAssertEqual(plain.first[0].y, turned.first[0].y, accuracy: 1)
        XCTAssertEqual(plain.car.y, turned.car.y, accuracy: 1)
    }

    func testEverythingFitsInsideTheRect_andDividerSplitsTheCurbs() {
        guard let layout = layout(travelBearing: nil) else { return XCTFail("no layout") }
        for point in layout.first + layout.second + [layout.car] {
            XCTAssertTrue(point.x >= 0 && point.x <= size.width)
            XCTAssertTrue(point.y >= 0 && point.y <= size.height)
        }
        let ys = layout.first.map(\.y) + layout.second.map(\.y)
        XCTAssertTrue(layout.dividerY > ys.min() ?? 0 && layout.dividerY < ys.max() ?? 0)
    }

    func testDegenerateInput_returnsNil() {
        XCTAssertNil(WPParkSideMiniMapLayout.make(
            first: [], second: [], car: F.coordinate(x: 0, y: 0), travelBearing: nil, size: size
        ))
    }
}

// MARK: - Candidate search regression

final class ParkSideCandidateDedupeRegressionTests: XCTestCase {

    /// Documents why the legacy "Wrong street?" list can never offer the other curb: dedupe is by
    /// street|from|to with no side in the key. The Stoop path does NOT change this (flag off stays
    /// byte-identical); it finds the opposite curb with `ParkSideResolver` instead. If someone
    /// "fixes" the dedupe, this fails on purpose so they read the spec first.
    func testFindCandidateSegments_collapsesBothSidesOfABlock() {
        let segments = ParkSideTestFixtures.pair(oneway: true)
        let center = ParkSideTestFixtures.coordinate(x: 0, y: 6)
        let found = CandidateSegmentSearch.findCandidateSegments(
            lat: center.latitude, lng: center.longitude, in: segments, radius: 35, max: 4
        )
        XCTAssertEqual(found.count, 1, "both curbs share a block key, so only one survives the dedupe")
    }

    func testResolver_stillFindsTheOppositeCurbThatTheDedupeDrops() {
        let segments = ParkSideTestFixtures.pair(oneway: true)
        let found = CandidateSegmentSearch.oppositeSideCandidate(of: segments[0], in: segments)
        XCTAssertEqual(found?.id, "N")
    }
}

// MARK: - Token path

@MainActor
final class WPParkFlowSwitchSideTests: XCTestCase {

    private typealias F = ParkSideTestFixtures

    private func waitUntil(timeout: TimeInterval = 5.0, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testOppositeSnap_isTheOtherCurbAtTheSamePosition() {
        let segments = F.pair(oneway: true)
        guard let snap = CandidateSegmentSearch.nearestPointOnPolyline(
            from: F.coordinate(x: 30, y: 0), polyline: segments[0].coordinates
        ) else { return XCTFail("projection failed") }
        let result = CurbSnapResult(
            segment: segments[0], positionFraction: snap.fraction, distanceMeters: 3,
            snappedCoordinate: snap.coordinate
        )
        let other = WPParkFlowController.oppositeSnap(of: result, in: segments)
        XCTAssertEqual(other?.segment.id, "N")
        XCTAssertEqual(other?.positionFraction ?? -1, snap.fraction, accuracy: 0.001)
        XCTAssertNil(WPParkFlowController.oppositeSnap(of: result, in: [segments[0]]))
        XCTAssertNil(WPParkFlowController.oppositeSnap(of: nil, in: segments))
    }

    func testSwitchSide_flipsTheSnap_andASecondTapReturns() async {
        let segments = F.pair(oneway: true)
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: segments)
        await waitUntil { flow.indexReady }
        XCTAssertTrue(flow.indexReady)

        let engine = ParkingRulesEngine()
        flow.beginDrag(from: .zero)
        flow.update(
            point: .zero, coordinate: F.coordinate(x: 20, y: 1), metersPerPoint: 0.1,
            engine: engine, now: F.now, windowEnd: nil, trip: nil
        )
        XCTAssertTrue(flow.endDrag(landingPoint: .zero))
        XCTAssertEqual(flow.snap?.segment.id, "S")
        XCTAssertNotNil(flow.alternateSnap, "the other curb is offered once the token lands")
        let southCoordinate = flow.snap?.snappedCoordinate

        flow.switchSide(engine: engine, now: F.now, windowEnd: nil, trip: nil)
        XCTAssertEqual(flow.snap?.segment.id, "N")
        XCTAssertNotNil(flow.model, "the verdict is re-run for the new curb")

        flow.switchSide(engine: engine, now: F.now, windowEnd: nil, trip: nil)
        XCTAssertEqual(flow.snap?.segment.id, "S")
        XCTAssertEqual(flow.snap?.snappedCoordinate.latitude ?? 0, southCoordinate?.latitude ?? -1, accuracy: 1e-12)
    }

    func testNoOppositeCurb_offersNoSwitch() async {
        let segments = [F.curb(id: "S", side: "S", y: 0, oneway: true)]
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: segments)
        await waitUntil { flow.indexReady }

        flow.beginDrag(from: .zero)
        flow.update(
            point: .zero, coordinate: F.coordinate(x: 20, y: 1), metersPerPoint: 0.1,
            engine: ParkingRulesEngine(), now: F.now, windowEnd: nil, trip: nil
        )
        XCTAssertTrue(flow.endDrag(landingPoint: .zero))
        XCTAssertNil(flow.alternateSnap, "hidden, not disabled")
    }
}

// MARK: - replaceSide (My Car "Wrong side? Switch")

final class ParkPinServiceReplaceSideTests: XCTestCase {

    private let suiteName = "com.wepark.test.parkpinservicereplaceside"
    private var defaults: UserDefaults!
    private var store: MockUbiquitousStore!
    private var service: ParkPinService!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)
        store = MockUbiquitousStore()
        if let defaults {
            service = ParkPinService(cloudStore: store, defaults: defaults)
        }
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        service = nil
        super.tearDown()
    }

    private func southCar() -> ParkedCar {
        ParkedCar(
            id: UUID(), latitude: 40.72, longitude: -73.99,
            detectedSegmentID: "S", detectedSide: "S", street: "STANTON STREET",
            fromStreet: "ESSEX STREET", toStreet: "NORFOLK STREET",
            parkedAt: Date(timeIntervalSince1970: 1000), notifyOnRestriction: false,
            address: ParkingAddress(
                houseNumber: "12", streetDisplay: "Stanton Street", confidence: .verified,
                source: .mapkit, resolvedAt: Date(timeIntervalSince1970: 1000)
            )
        )
    }

    func testReplaceSide_keepsIdParkedAtAndReminderChoice_swapsCurbAndDropsTheOldAddress() {
        let car = southCar()
        service.save(car)
        let before = service.currentUpdatedAt
        let north = ParkSideTestFixtures.curb(id: "N", side: "N", y: 12, oneway: true)
        let target = ParkSideTestFixtures.coordinate(x: 0, y: 12)

        let updated = service.replaceSide(carID: car.id, with: north, coordinate: target)

        XCTAssertEqual(updated?.id, car.id, "an edit, not a re-park")
        XCTAssertEqual(updated?.detectedSegmentID, "N")
        XCTAssertEqual(updated?.detectedSide, "N")
        XCTAssertEqual(updated?.latitude ?? 0, target.latitude, accuracy: 1e-12)
        XCTAssertEqual(updated?.parkedAt, car.parkedAt)
        XCTAssertEqual(updated?.notifyOnRestriction, false)
        XCTAssertNil(updated?.address, "the old address described the other side")
        XCTAssertEqual(service.parkedCar?.detectedSegmentID, "N")
        // Synced: the iCloud envelope carries the new side and a later updatedAt.
        let stored = store.decodedEnvelope(forKey: "wepark_synced_car_state")
        XCTAssertEqual(stored?.car?.detectedSegmentID, "N")
        if let before, let after = service.currentUpdatedAt { XCTAssertGreaterThan(after, before) }
    }

    func testReplaceSide_doesNotSendPinDropped() {
        let car = southCar()
        service.save(car)
        var drops = 0
        let token = service.pinDropped.sink { _ in drops += 1 }
        let north = ParkSideTestFixtures.curb(id: "N", side: "N", y: 12, oneway: true)
        service.replaceSide(carID: car.id, with: north, coordinate: ParkSideTestFixtures.coordinate(x: 0, y: 12))
        XCTAssertEqual(drops, 0, "no Park Until / priming sheet for a side fix")
        token.cancel()
    }

    func testReplaceSide_staleCarId_isIgnored() {
        service.save(southCar())
        let north = ParkSideTestFixtures.curb(id: "N", side: "N", y: 12, oneway: true)
        XCTAssertNil(service.replaceSide(carID: UUID(), with: north, coordinate: ParkSideTestFixtures.coordinate(x: 0, y: 12)))
        XCTAssertEqual(service.parkedCar?.detectedSegmentID, "S")
    }
}
