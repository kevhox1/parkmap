//
//  W85bTests.swift
//  WeParkTests
//
//  W8.5b unit tests: parking-aware route scoring + recent destinations persistence.
//
//  Test groups:
//    - Scoring unit tests: RouteService.pickBestParkingAwareRoute (no live network).
//    - Recent destinations: RecentDestinationsStore CRUD + persistence.
//    - View smoke: DriveModeDestinationView renders without crashing.
//
//  @MainActor annotation on the test class is required because
//  RouteService.pickBestParkingAwareRoute is @MainActor (inherited from RouteService class).
//

import XCTest
import CoreLocation
import MapKit
import SwiftUI
@testable import WePark

// MARK: - W85bTests

@MainActor
final class W85bTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        UserDefaults.standard.removeObject(forKey: AppConstants.recentDestinationsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConstants.recentDestinationsKey)
        engine = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// Creates a minimal `DriveRoute` with a given geometry and duration.
    private func route(
        geometry: [CLLocationCoordinate2D],
        duration: TimeInterval = 0
    ) -> DriveRoute {
        DriveRoute(
            id: UUID(),
            distance: 1000,
            duration: duration,
            geometry: geometry,
            steps: []
        )
    }

    /// Creates a minimal `Segment` with known category and line (in [lat, lng] pairs).
    /// Uses `dominantCategory` so the scoring engine classifies the segment directly.
    private func seg(
        street: String = "TEST ST",
        from: String = "FIRST AVE",
        to: String = "SECOND AVE",
        category cat: WePark.Category,
        line linePairs: [[Double]]
    ) -> Segment {
        // Minimal ParkingRule matching the category so safetyLabel works correctly.
        let rule = ParkingRule(
            category: cat,
            description: "Test rule",
            days: [0, 1, 2, 3, 4, 5, 6],
            timeRanges: [],
            anytime: true,
            arrow: nil
        )
        return Segment(
            id: UUID().uuidString,
            street: street,
            fromStreet: from,
            to: to,
            side: "N",
            line: linePairs,
            rules: [rule],
            dominantCategory: cat
        )
    }

    /// Coordinate offset north by `meters`.
    private func north(_ base: CLLocationCoordinate2D, meters: Double = 5) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320.0, longitude: base.longitude)
    }

    /// Mid-Manhattan anchor coordinate for test routes.
    private let anchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980)

    // MARK: - Scoring: empty + single route

    func testScoring_emptyRoutes_returnsNil() {
        let result = RouteService.pickBestParkingAwareRoute([], segments: [], engine: engine)
        XCTAssertNil(result, "Empty routes should return nil")
    }

    func testScoring_singleRoute_returnsWithoutScoring() {
        let r = route(geometry: [anchor], duration: 0)
        let result = RouteService.pickBestParkingAwareRoute([r], segments: [], engine: engine)
        XCTAssertEqual(result?.id, r.id, "Single-route input should return that route")
    }

    // MARK: - Scoring: free segments near route

    func testScoring_freeSegmentNearRoute_picksRoute() {
        // Route A is at anchor; Route B is 5km away.
        let routeA = route(geometry: [anchor], duration: 0)
        let farCoord = CLLocationCoordinate2D(latitude: anchor.latitude + 0.045, longitude: anchor.longitude)
        let routeB = route(geometry: [farCoord], duration: 0)

        // Three free segments near Route A (midpoint within 5m of anchor).
        let freeSegs: [Segment] = (0..<3).map { i in
            seg(
                street: "FREE ST \(i)", from: "A", to: "B",
                category: .free,
                line: [
                    [anchor.latitude, anchor.longitude],
                    [anchor.latitude + 0.0001, anchor.longitude]
                ]
            )
        }

        // Test: [routeB, routeA] — routeA should win despite being index 1.
        let result = RouteService.pickBestParkingAwareRoute([routeB, routeA], segments: freeSegs, engine: engine)
        XCTAssertEqual(result?.id, routeA.id, "Route A with 3 free segments should win over Route B with 0")
    }

    // MARK: - Scoring: metered segments

    func testScoring_meteredSegmentNearRoute_countedAtOne() {
        // Route A: 3 metered segments = +3. Route B: 1 free segment = +3.
        // Tie → primary (index 0 = routeA) wins.
        let routeACoord = anchor
        let routeBCoord = CLLocationCoordinate2D(latitude: anchor.latitude + 0.01, longitude: anchor.longitude)
        let routeA = route(geometry: [routeACoord], duration: 0)
        let routeB = route(geometry: [routeBCoord], duration: 0)

        let meteredSegs: [Segment] = (0..<3).map { i in
            seg(street: "METER ST \(i)", from: "A", to: "B",
                category: .metered,
                line: [[routeACoord.latitude, routeACoord.longitude],
                        [routeACoord.latitude + 0.0001, routeACoord.longitude]])
        }
        let freeSeg = seg(street: "FREE ST", from: "C", to: "D",
                          category: .free,
                          line: [[routeBCoord.latitude, routeBCoord.longitude],
                                 [routeBCoord.latitude + 0.0001, routeBCoord.longitude]])

        let result = RouteService.pickBestParkingAwareRoute(
            [routeA, routeB],
            segments: meteredSegs + [freeSeg],
            engine: engine
        )
        // Both tie at 3; primary (routeA, index 0) wins.
        XCTAssertEqual(result?.id, routeA.id, "Tie should fall back to primary route (index 0)")
    }

    // MARK: - Scoring: duration penalty

    func testScoring_durationPenaltyApplied() {
        // Both routes have no nearby segments → both start at 0.
        // Route B has duration 600s → penalty -1.0 → Route A (0) wins.
        let routeA = route(geometry: [anchor], duration: 0)
        let routeB = route(
            geometry: [CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)],
            duration: 600
        )

        // Far segment — not near either route.
        let farCoord = north(anchor, meters: 500)
        let farSeg = seg(category: .free,
                         line: [[farCoord.latitude, farCoord.longitude],
                                [farCoord.latitude + 0.001, farCoord.longitude]])

        let result = RouteService.pickBestParkingAwareRoute([routeA, routeB], segments: [farSeg], engine: engine)
        XCTAssertEqual(result?.id, routeA.id, "Route A (no penalty) should beat Route B (600s penalty = -1)")
    }

    // MARK: - Scoring: skip set

    func testScoring_skipSetExcludes_noStanding() {
        // NO_STANDING near Route A should NOT be counted.
        // Route B has 1 free segment → Route B wins.
        let routeACoord = anchor
        let routeBCoord = CLLocationCoordinate2D(latitude: anchor.latitude + 0.01, longitude: anchor.longitude)
        let routeA = route(geometry: [routeACoord], duration: 0)
        let routeB = route(geometry: [routeBCoord], duration: 0)

        let noStandingSeg = seg(category: .noStanding,
                                line: [[routeACoord.latitude, routeACoord.longitude],
                                       [routeACoord.latitude + 0.0001, routeACoord.longitude]])
        let freeSeg = seg(street: "FREE ST", from: "C", to: "D",
                          category: .free,
                          line: [[routeBCoord.latitude, routeBCoord.longitude],
                                 [routeBCoord.latitude + 0.0001, routeBCoord.longitude]])

        let result = RouteService.pickBestParkingAwareRoute([routeA, routeB], segments: [noStandingSeg, freeSeg], engine: engine)
        XCTAssertEqual(result?.id, routeB.id, "Route B with 1 free segment should beat Route A with only NO_STANDING (skipped)")
    }

    // MARK: - Scoring: block key dedup

    func testScoring_blockKeyDedup_sameBlockNotDoubledCounted() {
        // Route A: 2 segments with SAME block key (SAME ST|FIRST|SECOND) → score +3 (not +6).
        // Route B: 2 UNIQUE free segments → score +6.
        // Route B should win.
        //
        // Geometry note: segment midpoint = line[count/2] = line[1] for a 2-element line.
        // Must keep midpoint within 30m of route sample point.
        // 0.0001 degree lat offset ≈ 11m (well within 30m).
        let routeACoord = anchor
        let routeBCoord = CLLocationCoordinate2D(latitude: anchor.latitude + 0.1, longitude: anchor.longitude)
        let routeA = route(geometry: [routeACoord], duration: 0)
        let routeB = route(geometry: [routeBCoord], duration: 0)

        // Two segments with identical street|from|to keys near Route A.
        // Both have midpoints (line[1]) within 11m of routeACoord.
        let dupSeg1 = seg(street: "SAME ST", from: "FIRST", to: "SECOND",
                          category: .free,
                          line: [[routeACoord.latitude - 0.0001, routeACoord.longitude],
                                 [routeACoord.latitude + 0.0001, routeACoord.longitude]])
        let dupSeg2 = seg(street: "SAME ST", from: "FIRST", to: "SECOND",
                          category: .free,
                          line: [[routeACoord.latitude - 0.00005, routeACoord.longitude],
                                 [routeACoord.latitude + 0.00005, routeACoord.longitude]])

        // Two unique free segments near Route B.
        // Both midpoints within 11m of routeBCoord.
        let uniqueSeg1 = seg(street: "UNIQUE A", from: "X", to: "Y",
                             category: .free,
                             line: [[routeBCoord.latitude - 0.0001, routeBCoord.longitude],
                                    [routeBCoord.latitude + 0.0001, routeBCoord.longitude]])
        let uniqueSeg2 = seg(street: "UNIQUE B", from: "X", to: "Y",
                             category: .free,
                             line: [[routeBCoord.latitude - 0.00005, routeBCoord.longitude],
                                    [routeBCoord.latitude + 0.00005, routeBCoord.longitude]])

        let result = RouteService.pickBestParkingAwareRoute(
            [routeA, routeB],
            segments: [dupSeg1, dupSeg2, uniqueSeg1, uniqueSeg2],
            engine: engine
        )
        // Route A: +3 (deduped, 1 block). Route B: +6 (2 unique blocks). Route B wins.
        XCTAssertEqual(result?.id, routeB.id, "Route B (2 unique blocks = +6) should beat Route A (1 deduped block = +3)")
    }

    // MARK: - Scoring: segment outside 30m radius

    func testScoring_segmentOutsideRadius_notCounted() {
        // A free segment 500m from Route A → not counted.
        // Both routes score 0 → primary (routeA) wins tie.
        let routeA = route(geometry: [anchor], duration: 0)
        let far = north(anchor, meters: 500)
        // Route B at 1km from anchor, segment at 500m — neither picks it up.
        let routeB = route(geometry: [north(anchor, meters: 1000)], duration: 0)

        let farSeg = seg(category: .free,
                         line: [[far.latitude, far.longitude],
                                [far.latitude + 0.0001, far.longitude]])

        let result = RouteService.pickBestParkingAwareRoute([routeA, routeB], segments: [farSeg], engine: engine)
        // Both score 0 (segment is >30m from both routes' sample points). Tie → primary (routeA).
        XCTAssertEqual(result?.id, routeA.id, "Both routes score 0 (segment out of radius); primary wins tie")
    }

    // MARK: - Scoring: stride sampling

    func testScoring_routeGeometryStride_samplesCorrectly() {
        // 180-point geometry → sampleStride = max(1, 180/60) = 3.
        // Sample points: indices 0, 3, 6, …, 177.
        // A free segment at index 90 (sampled, 90 % 3 == 0) should be counted.
        let coords: [CLLocationCoordinate2D] = (0..<180).map { i in
            CLLocationCoordinate2D(latitude: 40.750 + Double(i) * 0.000010, longitude: -73.980)
        }
        let r = route(geometry: coords, duration: 0)

        // Segment midpoint at index 90 (sampled).
        let sampledCoord = coords[90]
        let freeSeg = seg(category: .free,
                          line: [[sampledCoord.latitude, sampledCoord.longitude],
                                 [sampledCoord.latitude + 0.0001, sampledCoord.longitude]])

        // emptyRoute has empty geometry → skipped → r wins.
        let emptyRoute = route(geometry: [], duration: 0)
        let result = RouteService.pickBestParkingAwareRoute([emptyRoute, r], segments: [freeSeg], engine: engine)
        XCTAssertEqual(result?.id, r.id, "Route with 180-pt geometry should pick up free segment at sampled index 90")
    }

    // MARK: - Scoring: all routes tied → primary

    func testScoring_allRoutesTied_returnsPrimary() {
        // Three identical routes, no segments. All score -0.1 (duration 60s / 600 = 0.1).
        let r1 = route(geometry: [anchor], duration: 60)
        let r2 = route(geometry: [anchor], duration: 60)
        let r3 = route(geometry: [anchor], duration: 60)

        let result = RouteService.pickBestParkingAwareRoute([r1, r2, r3], segments: [], engine: engine)
        XCTAssertEqual(result?.id, r1.id, "Tied routes should return the primary route (index 0)")
    }

    // MARK: - Scoring: skip set (additional categories)

    func testScoring_noParking_inSkipSet_notCounted() {
        let routeA = route(geometry: [anchor], duration: 0)
        let routeB = route(geometry: [north(anchor, meters: 1000)], duration: 0)
        let noParkSeg = seg(category: .noParking,
                            line: [[anchor.latitude, anchor.longitude],
                                   [anchor.latitude + 0.0001, anchor.longitude]])
        // NO_PARKING not counted → both score 0 → primary (routeA) wins.
        let result = RouteService.pickBestParkingAwareRoute([routeA, routeB], segments: [noParkSeg], engine: engine)
        XCTAssertEqual(result?.id, routeA.id, "NO_PARKING should be skipped; tie → primary")
    }

    func testScoring_specialCategory_inSkipSet_notCounted() {
        let routeA = route(geometry: [anchor], duration: 0)
        let routeB = route(geometry: [north(anchor, meters: 1000)], duration: 0)
        let specialSeg = seg(category: .special,
                             line: [[anchor.latitude, anchor.longitude],
                                    [anchor.latitude + 0.0001, anchor.longitude]])
        let result = RouteService.pickBestParkingAwareRoute([routeA, routeB], segments: [specialSeg], engine: engine)
        XCTAssertEqual(result?.id, routeA.id, "SPECIAL should be skipped; tie → primary")
    }

    // MARK: - Recent destinations persistence

    func testRecentDestinations_addDestination_persistsToUserDefaults() {
        let store = RecentDestinationsStore()
        let dest = RecentDestination(
            id: UUID(),
            name: "Grand Central Terminal",
            latitude: 40.7527,
            longitude: -73.9772
        )
        store.add(dest)

        // Reload from UserDefaults.
        let fresh = RecentDestinationsStore()
        XCTAssertEqual(fresh.destinations.count, 1)
        XCTAssertEqual(fresh.destinations[0].name, "Grand Central Terminal")
        XCTAssertEqual(fresh.destinations[0].latitude, 40.7527, accuracy: 0.000001)
        XCTAssertEqual(fresh.destinations[0].longitude, -73.9772, accuracy: 0.000001)
    }

    func testRecentDestinations_capacityBound_oldestDropped() {
        let store = RecentDestinationsStore()

        // Add 6 destinations (newest last). MRU: newest = index 0.
        for i in 0..<6 {
            store.add(RecentDestination(
                id: UUID(),
                name: "Destination \(i)",
                latitude: 40.750 + Double(i) * 0.001,
                longitude: -73.980
            ))
        }

        // List should be capped at 5.
        XCTAssertEqual(store.destinations.count, 5, "List should be capped at 5 entries")
        // "Destination 0" (oldest) should be evicted.
        XCTAssertFalse(
            store.destinations.contains(where: { $0.name == "Destination 0" }),
            "First-inserted (oldest) destination should be evicted at capacity"
        )
        // "Destination 5" (newest) should be at index 0.
        XCTAssertEqual(store.destinations[0].name, "Destination 5")
    }

    func testRecentDestinations_delete_removesFromPersistence() {
        let store = RecentDestinationsStore()
        let d0 = RecentDestination(id: UUID(), name: "Home", latitude: 40.730, longitude: -74.000)
        let d1 = RecentDestination(id: UUID(), name: "Work", latitude: 40.750, longitude: -73.980)
        let d2 = RecentDestination(id: UUID(), name: "Gym", latitude: 40.760, longitude: -73.970)
        store.add(d0)
        store.add(d1)
        store.add(d2)

        // MRU order: Gym (0), Work (1), Home (2).
        XCTAssertEqual(store.destinations.count, 3)
        XCTAssertEqual(store.destinations[0].name, "Gym")

        // Delete index 1 ("Work").
        store.delete(at: IndexSet(integer: 1))
        XCTAssertEqual(store.destinations.count, 2)
        XCTAssertFalse(store.destinations.contains(where: { $0.name == "Work" }))

        // Reload and confirm persistence.
        let fresh = RecentDestinationsStore()
        XCTAssertEqual(fresh.destinations.count, 2)
        XCTAssertFalse(fresh.destinations.contains(where: { $0.name == "Work" }))
    }

    func testRecentDestinations_deduplicatesByName() {
        let store = RecentDestinationsStore()
        store.add(RecentDestination(id: UUID(), name: "Grand Central", latitude: 40.7527, longitude: -73.9772))
        store.add(RecentDestination(id: UUID(), name: "Grand Central", latitude: 40.7527, longitude: -73.9772))

        XCTAssertEqual(store.destinations.count, 1, "Duplicate name should replace (not duplicate) the existing entry")
    }

    func testRecentDestinations_mruOrdering() {
        let store = RecentDestinationsStore()
        store.add(RecentDestination(id: UUID(), name: "A", latitude: 40.700, longitude: -73.900))
        store.add(RecentDestination(id: UUID(), name: "B", latitude: 40.710, longitude: -73.910))
        store.add(RecentDestination(id: UUID(), name: "C", latitude: 40.720, longitude: -73.920))

        XCTAssertEqual(store.destinations[0].name, "C", "Most recently added should be first (MRU)")
        XCTAssertEqual(store.destinations[1].name, "B")
        XCTAssertEqual(store.destinations[2].name, "A")
    }

    // MARK: - Out-of-coverage detection

    func testOutOfCoverage_jerseyCity_isOutsideManhattanBounds() {
        let jerseyCityCoord = CLLocationCoordinate2D(latitude: 40.7178, longitude: -74.0431)
        XCTAssertFalse(
            AppConstants.isInManhattanCoverage(jerseyCityCoord),
            "Jersey City should be outside Manhattan coverage"
        )
    }

    func testOutOfCoverage_midtownManhattan_isInsideManhattanBounds() {
        let midtownCoord = CLLocationCoordinate2D(latitude: 40.7549, longitude: -73.9840)
        XCTAssertTrue(
            AppConstants.isInManhattanCoverage(midtownCoord),
            "Midtown Manhattan should be inside Manhattan coverage"
        )
    }

    // MARK: - View smoke

    func testDriveModeDestinationView_renders_withoutCrashing() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        let view = DriveModeDestinationView(
            currentRegion: region,
            segments: [],
            userLocation: nil,
            onRouteReady: { _, _ in }
        )
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view, "DriveModeDestinationView should render without crashing (no user location)")
    }

    func testDriveModeDestinationView_withUserLocation_renders_withoutCrashing() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        let view = DriveModeDestinationView(
            currentRegion: region,
            segments: [],
            userLocation: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),
            onRouteReady: { _, _ in }
        )
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view, "DriveModeDestinationView with user location should render without crashing")
    }
}
