//
//  WPParkDraftTests.swift
//  WeParkTests
//
//  DT35-3 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR2): drag the car freely along the block
//  with a pending ("Not saved yet") draft, plus the two #221 QA follow-ups (F1 mini-map clip, F2 exact
//  flip-back). Multi-piece fixtures (synthetic Stanton-shaped block and the REAL Stanton
//  Bowery-Chrystie tiles), not only a single-piece curb.
//
//  Helpers are enum-namespaced with unique names (no XCTestCase extensions).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Real tiles

enum Pr2DragTestTiles {

    /// Every Stanton St segment in the bundled tiles (`#filePath` precedent from the PR1 tests).
    static func stantonSegments() throws -> [Segment] {
        let tilesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WePark/Resources/tiles")
        let files = try FileManager.default.contentsOfDirectory(at: tilesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tile_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var all: [Segment] = []
        for file in files {
            let segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: file))
            all += segments.filter { $0.street == "STANTON STREET" }
        }
        return all
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

// MARK: - Controller

@MainActor
final class WPParkFlowFreeDragTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let engine = ParkingRulesEngine()

    private func waitUntil(timeout: TimeInterval = 5.0, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func readyFlow(_ segments: [Segment]) async -> WPParkFlowController {
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: segments)
        await waitUntil { flow.indexReady }
        return flow
    }

    private func drag(_ flow: WPParkFlowController, to x: Double, _ y: Double) {
        flow.update(
            point: .zero, coordinate: CurbSnapTestFixtures.coordinate(x: x, y: y), metersPerPoint: 0.1,
            engine: engine, now: now, windowEnd: nil, trip: nil
        )
    }

    // Continuous position along the block.

    func testDragAlongTheBlock_footFollowsTheFingerContinuously_acrossPieces() async {
        let segments = ParkSidePieceFixtures.block()
        let flow = await readyFlow(segments)
        XCTAssertTrue(flow.indexReady)
        flow.beginDrag(from: .zero)
        var seen: [Double] = []
        var lastX = 0.0
        for x in stride(from: -80.0, through: 80.0, by: 7.3) {
            lastX = x
            drag(flow, to: x, 1)
            guard let snap = flow.snap else { return XCTFail("no snap at x=\(x)") }
            let expected = CurbSnapTestFixtures.coordinate(x: x, y: 0)
            XCTAssertLessThan(Pr2DragTestTiles.meters(snap.snappedCoordinate, expected), 0.5,
                              "x=\(x): the foot is the finger's projection, not a vertex or midpoint")
            seen.append(snap.snappedCoordinate.longitude)
        }
        XCTAssertEqual(Set(seen).count, seen.count, "every position is distinct (no snapping to vertices)")
        XCTAssertTrue(flow.endDrag(landingPoint: .zero))
        guard let draft = flow.draft else { return XCTFail("no draft after landing") }
        XCTAssertLessThan(
            Pr2DragTestTiles.meters(draft.groundCoordinate, CurbSnapTestFixtures.coordinate(x: lastX, y: 0)), 1.0
        )
        XCTAssertEqual(flow.groundCoordinate?.latitude, flow.snap?.snappedCoordinate.latitude)
    }

    // Side flips at the centre line with the token hysteresis.

    func testDragAcrossTheStreet_flipsSideNearTheCentreLine() async {
        let flow = await readyFlow(ParkSidePieceFixtures.block())
        flow.beginDrag(from: .zero)
        drag(flow, to: 10, 1)
        XCTAssertEqual(flow.snap?.segment.side, "S")
        drag(flow, to: 10, 6.4)
        XCTAssertEqual(flow.snap?.segment.side, "S", "inside the 1.5 m dead-band the side holds")
        drag(flow, to: 10, 7.2)
        XCTAssertEqual(flow.snap?.segment.side, "N", "past the centre line the other curb takes over")
        drag(flow, to: 10, 4.8)
        XCTAssertEqual(flow.snap?.segment.side, "S", "and back")
    }

    func testTokenHysteresis_isSmallerThanTheCurbPinPlacement() {
        let config = WPParkFlowController.tokenSnapConfig
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 0.3), 1.5, accuracy: 1e-9)
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 5), 1.5, accuracy: 1e-9)
        XCTAssertLessThan(config.hysteresisMeters(metersPerPoint: 5), CurbSnapConfig.standard.hysteresisMeters(metersPerPoint: 5))
    }

    // The verdict is the curb under the car, never a stale one.

    func testOverNoCurb_verdictIsCleared_neverStale() async {
        let flow = await readyFlow(ParkSidePieceFixtures.block())
        flow.beginDrag(from: .zero)
        drag(flow, to: 10, 1)
        XCTAssertNotNil(flow.model)
        drag(flow, to: 10, 90)
        XCTAssertNil(flow.snap)
        XCTAssertNil(flow.model, "over no curb there is no verdict, not the last curb's")
    }

    // Off-curb release.

    func testOffCurbRelease_whenPending_returnsToTheLastCurb() async {
        let flow = await readyFlow(ParkSidePieceFixtures.block())
        flow.beginDrag(from: .zero)
        drag(flow, to: 20, 1)
        XCTAssertTrue(flow.endDrag(landingPoint: .zero))
        let landed = flow.groundCoordinate
        let landedID = flow.snap?.segment.id

        flow.beginDrag(from: .zero)
        drag(flow, to: 20, 90)
        XCTAssertFalse(flow.endDrag(landingPoint: .zero))
        XCTAssertEqual(flow.phase, .placed, "still pending, not sent home")
        XCTAssertEqual(flow.snap?.segment.id, landedID)
        XCTAssertEqual(flow.groundCoordinate?.latitude ?? 0, landed?.latitude ?? -1, accuracy: 1e-12)
        XCTAssertEqual(flow.notice, .dropOnCurb)
        XCTAssertNotNil(flow.model)
        XCTAssertEqual(WPParkFlowCopy.dropOnCurb, "Drop the car on a curb")
    }

    func testOffCurbRelease_onTheFirstDrag_goesHome() async {
        let flow = await readyFlow(ParkSidePieceFixtures.block())
        flow.beginDrag(from: .zero)
        drag(flow, to: 20, 90)
        XCTAssertFalse(flow.endDrag(landingPoint: .zero))
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.draft)
    }

    // Pending state.

    func testEnterPending_putsTheCarOnTheCurb_withoutSavingAnything() async throws {
        let suite = "com.wepark.test.wpparkdraft.pending"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MockUbiquitousStore()
        let service = ParkPinService(cloudStore: store, defaults: defaults)

        let segments = ParkSidePieceFixtures.block()
        let flow = await readyFlow(segments)
        let tapped = try XCTUnwrap(segments.first { $0.id == "N_2" })
        let snap = try XCTUnwrap(WPParkFlowController.pendingSnap(
            on: tapped, near: CurbSnapTestFixtures.coordinate(x: 55, y: 14)
        ))
        flow.enterPending(at: snap, segments: segments, engine: engine, now: now, windowEnd: nil, trip: nil)
        XCTAssertEqual(flow.phase, .placed)
        XCTAssertEqual(flow.draft?.snap.segment.id, "N_2")
        XCTAssertEqual(flow.alternateSnap?.segment.id, "S_2", "the facing piece, offered as Other side")

        // Drag it around and cancel: still nothing written.
        flow.beginDrag(from: .zero)
        drag(flow, to: 40, 3)
        _ = flow.endDrag(landingPoint: .zero)
        flow.reset()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.draft)
        XCTAssertNil(service.parkedCar, "a pending draft never creates a ParkedCar")
        XCTAssertEqual(store.setCallCount, 0, "and never touches iCloud")
    }

    func testDraft_isNeverEncodable() async {
        let segments = ParkSidePieceFixtures.block()
        let flow = await readyFlow(segments)
        guard let snap = WPParkFlowController.pendingSnap(on: segments[0], near: nil) else {
            return XCTFail("no snap")
        }
        flow.enterPending(at: snap, segments: segments, engine: engine, now: now, windowEnd: nil, trip: nil)
        XCTAssertNotNil(flow.draft)
        XCTAssertFalse((flow.draft as Any) is Encodable, "a draft is never persisted")
    }

    func testSwitchSide_movesTheGroundPoint_andBack() async throws {
        let segments = ParkSidePieceFixtures.block()
        let flow = await readyFlow(segments)
        flow.beginDrag(from: .zero)
        drag(flow, to: 55, 1)
        XCTAssertTrue(flow.endDrag(landingPoint: .zero))
        let south = try XCTUnwrap(flow.groundCoordinate)
        let tick = flow.landingTick
        flow.switchSide(engine: engine, now: now, windowEnd: nil, trip: nil)
        let north = try XCTUnwrap(flow.groundCoordinate)
        XCTAssertEqual(flow.snap?.segment.id, "N_2")
        XCTAssertEqual(Pr2DragTestTiles.meters(south, north), 12, accuracy: 0.5)
        XCTAssertGreaterThan(flow.landingTick, tick)
        flow.switchSide(engine: engine, now: now, windowEnd: nil, trip: nil)
        XCTAssertEqual(flow.groundCoordinate?.latitude ?? 0, south.latitude, accuracy: 1e-12)
    }

    func testCommit_clearsTheDraft() async {
        let segments = ParkSidePieceFixtures.block()
        let flow = await readyFlow(segments)
        guard let snap = WPParkFlowController.pendingSnap(on: segments[0], near: nil) else {
            return XCTFail("no snap")
        }
        flow.enterPending(at: snap, segments: segments, engine: engine, now: now, windowEnd: nil, trip: nil)
        flow.commit()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.draft)
    }

    // Pending entry position.

    func testPendingSnap_usesTheFootOfTheFix_orTheTrueMiddle() throws {
        let segments = ParkSidePieceFixtures.block()
        let curb = try XCTUnwrap(segments.first { $0.id == "N_1" }) // x in [-30, 30], y = 12
        let near = try XCTUnwrap(WPParkFlowController.pendingSnap(
            on: curb, near: CurbSnapTestFixtures.coordinate(x: 10, y: 5)
        ))
        XCTAssertLessThan(Pr2DragTestTiles.meters(near.snappedCoordinate, CurbSnapTestFixtures.coordinate(x: 10, y: 12)), 0.5)
        XCTAssertEqual(near.distanceMeters, 7, accuracy: 0.3)

        let far = try XCTUnwrap(WPParkFlowController.pendingSnap(
            on: curb, near: CurbSnapTestFixtures.coordinate(x: 10, y: -80)
        ))
        XCTAssertLessThan(Pr2DragTestTiles.meters(far.snappedCoordinate, CurbSnapTestFixtures.coordinate(x: 0, y: 12)), 0.5,
                          "no fix near: the middle of the curb, not its far vertex")
        XCTAssertEqual(far.positionFraction, 0.5, accuracy: 1e-9)

        let noFix = try XCTUnwrap(WPParkFlowController.pendingSnap(on: curb, near: nil))
        XCTAssertEqual(noFix.positionFraction, 0.5, accuracy: 1e-9)
    }

    // VoiceOver nudge.

    func testNudgedCoordinate_movesAlongTheCurb_andPastTheEnd() throws {
        let line = (CurbSnapTestFixtures.coordinate(x: 0, y: 0), CurbSnapTestFixtures.coordinate(x: 60, y: 0))
        let polyline = [line.0, line.1]
        let forward = try XCTUnwrap(WPParkFlowController.nudgedCoordinate(on: polyline, fraction: 0.5, meters: 10))
        XCTAssertLessThan(Pr2DragTestTiles.meters(forward, CurbSnapTestFixtures.coordinate(x: 40, y: 0)), 0.3)
        let back = try XCTUnwrap(WPParkFlowController.nudgedCoordinate(on: polyline, fraction: 0.5, meters: -10))
        XCTAssertLessThan(Pr2DragTestTiles.meters(back, CurbSnapTestFixtures.coordinate(x: 20, y: 0)), 0.3)
        let past = try XCTUnwrap(WPParkFlowController.nudgedCoordinate(on: polyline, fraction: 1, meters: 5))
        XCTAssertLessThan(Pr2DragTestTiles.meters(past, CurbSnapTestFixtures.coordinate(x: 65, y: 0)), 0.3)
        let before = try XCTUnwrap(WPParkFlowController.nudgedCoordinate(on: polyline, fraction: 0, meters: -5))
        XCTAssertLessThan(Pr2DragTestTiles.meters(before, CurbSnapTestFixtures.coordinate(x: -5, y: 0)), 0.3)
        XCTAssertNil(WPParkFlowController.nudgedCoordinate(on: [line.0], fraction: 0, meters: 5))
    }

    func testNudge_carriesOnToTheNextPieceOfTheBlock() async throws {
        let segments = ParkSidePieceFixtures.block()
        let flow = await readyFlow(segments)
        flow.beginDrag(from: .zero)
        drag(flow, to: 25, 1)
        XCTAssertTrue(flow.endDrag(landingPoint: .zero))
        XCTAssertEqual(flow.snap?.segment.id, "S_1")
        let moved = flow.nudge(
            meters: 10, point: .zero, metersPerPoint: 0.1, engine: engine, now: now, windowEnd: nil, trip: nil
        )
        XCTAssertEqual(moved, .moved)
        XCTAssertEqual(flow.snap?.segment.id, "S_2", "past the piece end the car continues on the next piece")
        let ground = try XCTUnwrap(flow.groundCoordinate)
        XCTAssertLessThan(Pr2DragTestTiles.meters(ground, CurbSnapTestFixtures.coordinate(x: 35, y: 0)), 1.0)
        XCTAssertEqual(flow.phase, .placed)
    }

    func testNudge_withoutADraft_doesNothing() async {
        let flow = await readyFlow(ParkSidePieceFixtures.block())
        XCTAssertEqual(flow.nudge(
            meters: 5, point: .zero, metersPerPoint: 0.1, engine: engine, now: now, windowEnd: nil, trip: nil
        ), .noCurb)
    }
}

// MARK: - F1: mini-map clip

final class WPParkMiniMapClipTests: XCTestCase {

    private let size = CGSize(width: 320, height: 160)

    func testUnevenPieces_areClippedToTheirCommonSpan() throws {
        // North piece 0...100 m, south piece starts 12 m late and ends 2 m early.
        let north = [CurbSnapTestFixtures.coordinate(x: 0, y: 12), CurbSnapTestFixtures.coordinate(x: 100, y: 12)]
        let south = [CurbSnapTestFixtures.coordinate(x: 12, y: 0), CurbSnapTestFixtures.coordinate(x: 98, y: 0)]
        let layout = try XCTUnwrap(WPParkSideMiniMapLayout.make(
            first: north, second: south, car: CurbSnapTestFixtures.coordinate(x: 50, y: 6),
            travelBearing: nil, size: size
        ))
        XCTAssertEqual(layout.first.count, 2)
        XCTAssertEqual(layout.second.count, 2)
        XCTAssertEqual(layout.first[0].x, layout.second[0].x, accuracy: 0.01, "left ends line up")
        XCTAssertEqual(layout.first[1].x, layout.second[1].x, accuracy: 0.01, "right ends line up")
    }

    func testClip_interpolatesTheCutEnds_andKeepsInteriorVertices() {
        let line: [(x: Double, up: Double)] = [(0, 0), (10, 1), (20, 4), (30, 9)]
        let clipped = WPParkSideMiniMapLayout.clip(line, lo: 5, hi: 25)
        XCTAssertEqual(clipped.count, 4)
        XCTAssertEqual(clipped.first?.x ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(clipped.first?.up ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(clipped.last?.x ?? -1, 25, accuracy: 1e-9)
        XCTAssertEqual(clipped.last?.up ?? -1, 6.5, accuracy: 1e-9)
    }

    func testBarelyOverlappingCurbs_areDrawnOverTheCarsPieceSpan() throws {
        let north = [CurbSnapTestFixtures.coordinate(x: 0, y: 12), CurbSnapTestFixtures.coordinate(x: 50, y: 12)]
        let south = [CurbSnapTestFixtures.coordinate(x: 47, y: 0), CurbSnapTestFixtures.coordinate(x: 100, y: 0)]
        let northRun: [(x: Double, up: Double)] = [(x: 0.0, up: 0.0), (x: 50.0, up: 0.0)]
        let southRun: [(x: Double, up: Double)] = [(x: 47.0, up: 0.0), (x: 100.0, up: 0.0)]
        XCTAssertNil(WPParkSideMiniMapLayout.commonSpan(northRun, southRun), "3 m of overlap is below the 5 m floor")
        let layout = try XCTUnwrap(WPParkSideMiniMapLayout.make(
            first: north, second: south, car: CurbSnapTestFixtures.coordinate(x: 48, y: 6),
            travelBearing: nil, size: size
        ))
        // Below the 5 m floor, both are drawn over the span of the curb the car is on (follow-up F1).
        XCTAssertEqual(layout.first.first?.x ?? 0, layout.second.first?.x ?? -999, accuracy: 0.05)
        XCTAssertEqual(layout.first.last?.x ?? 0, layout.second.last?.x ?? -999, accuracy: 0.05)
    }

    /// Real Stanton Bowery-Chrystie: the north and south pieces cover different ranges (the PR1 QA F1).
    func testRealStanton_northAndSouthPieces_drawAligned() throws {
        let segments = try Pr2DragTestTiles.stantonSegments()
        let prefix = "STANTON_STREET_BOWERY_CHRYSTIE_STREET_"
        var checked = 0
        for index in 0...3 {
            guard let north = segments.first(where: { $0.id == "\(prefix)N_\(index)" }),
                  let south = segments.first(where: { $0.id == "\(prefix)S_\(index)" }),
                  let middle = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: north.coordinates),
                  let foot = CandidateSegmentSearch.nearestPointOnPolyline(from: middle, polyline: south.coordinates)
            else { continue }
            let car = CLLocationCoordinate2D(
                latitude: (middle.latitude + foot.coordinate.latitude) / 2,
                longitude: (middle.longitude + foot.coordinate.longitude) / 2
            )
            guard let layout = WPParkSideMiniMapLayout.make(
                first: north.coordinates, second: south.coordinates, car: car, travelBearing: nil, size: size
            ) else { continue }
            checked += 1
            XCTAssertEqual(layout.first.first?.x ?? 0, layout.second.first?.x ?? -999, accuracy: 0.05, "\(index) start")
            XCTAssertEqual(layout.first.last?.x ?? 0, layout.second.last?.x ?? -999, accuracy: 0.05, "\(index) end")
            for point in layout.first + layout.second + [layout.car] {
                XCTAssertTrue(point.x >= 0 && point.x <= size.width && point.y >= 0 && point.y <= size.height)
            }
        }
        XCTAssertGreaterThan(checked, 0, "found no real Stanton pieces to check")
    }
}

// MARK: - F2: exact flip-back

final class WPSideFlipMemoryTests: XCTestCase {

    /// Every Stanton piece, several positions along it: flip, flip back, flip again. The way back is
    /// the ORIGINAL piece and coordinate exactly (re-projecting drifted 1-11 m or hopped a piece).
    func testRealStanton_flippingTwiceReturnsExactly() throws {
        let segments = try Pr2DragTestTiles.stantonSegments()
        var flips = 0
        for piece in segments where piece.coordinates.count >= 2 {
            for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
                guard let car = CandidateSegmentSearch.coordinate(atFraction: fraction, along: piece.coordinates),
                      let foot = CandidateSegmentSearch.nearestPointOnPolyline(from: car, polyline: piece.coordinates)
                else { continue }
                let here = ParkSideOption(segment: piece, coordinate: car, fraction: foot.fraction)
                let footOption = ParkSideOption(segment: piece, coordinate: foot.coordinate, fraction: foot.fraction)
                guard let target = ParkSideResolver.switched(from: footOption, in: segments) else { continue }
                flips += 1

                var memory = WPSideFlipMemory()
                memory.recordFlip(from: here, to: target)
                // The car is now saved at `target`.
                guard let back = memory.pair(segmentID: target.segment.id, coordinate: target.coordinate) else {
                    XCTFail("\(piece.id)@\(fraction): memory lost after the first flip"); continue
                }
                XCTAssertEqual(back.here, target)
                XCTAssertEqual(back.target, here, "\(piece.id)@\(fraction): back is the original option exactly")
                XCTAssertEqual(back.target.coordinate.latitude, car.latitude)
                XCTAssertEqual(back.target.coordinate.longitude, car.longitude)

                // Flip back, then flip again: the same target again, still exact.
                memory.recordFlip(from: back.here, to: back.target)
                guard let again = memory.pair(segmentID: piece.id, coordinate: car) else {
                    XCTFail("\(piece.id)@\(fraction): memory lost after the way back"); continue
                }
                XCTAssertEqual(again.target, target)
            }
        }
        XCTAssertGreaterThan(flips, 50, "expected many real flips to check")
    }

    func testMemory_fallsAwayWhenTheCarIsSomewhereElse() throws {
        let segments = ParkSidePieceFixtures.block()
        let south = try XCTUnwrap(segments.first { $0.id == "S_1" })
        let north = try XCTUnwrap(segments.first { $0.id == "N_1" })
        let here = ParkSideOption(segment: south, coordinate: CurbSnapTestFixtures.coordinate(x: 5, y: 0), fraction: 0.6)
        let there = ParkSideOption(segment: north, coordinate: CurbSnapTestFixtures.coordinate(x: 5, y: 12), fraction: 0.6)
        var memory = WPSideFlipMemory()
        XCTAssertNil(memory.pair(segmentID: "S_1", coordinate: here.coordinate), "empty memory offers nothing")
        memory.recordFlip(from: here, to: there)
        XCTAssertNil(memory.pair(segmentID: "S_0", coordinate: here.coordinate), "a different piece")
        XCTAssertNil(memory.pair(segmentID: "N_1", coordinate: CurbSnapTestFixtures.coordinate(x: 9, y: 12)),
                     "same piece, a different spot (the car was moved another way)")
        XCTAssertNil(memory.pair(segmentID: nil, coordinate: here.coordinate))
    }
}
