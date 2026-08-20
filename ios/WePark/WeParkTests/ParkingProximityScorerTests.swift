//
//  ParkingProximityScorerTests.swift
//  WeParkTests
//
//  FT-20 Stream B — OQ-4's "parking near here" cheap summary.
//  docs/ft20-bottom-sheet-navigation-spec.md §3.2, §0's OQ-4 ruling, §0b finding S2.
//
//  `ParkingProximityScorer` is pure, UIKit/simulator-free logic (SwiftUI is used only for
//  `Color`/`ParkingColors`, never anything that needs a host) — fully unit-testable here,
//  same rationale `BrowseSheetDetentMathTests` documents for `BrowseSheetDetentMath`.
//
//  Extra care here specifically because this type is reused by build 18's patrol mode
//  (per the spec's OQ-4 ruling) — a wrong bucket boundary or a wrong skip-category here
//  would propagate into that future feature's scoring, not just this slice's UI.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
@testable import WePark

@MainActor
final class ParkingProximityScorerTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    /// Wednesday 1pm ET — an ordinary weekday daytime hour, matching the fixture pattern
    /// already established in `ParkingRulesEngineParityTests`/`W85bTests`. Confirmed
    /// against `Resources/asp-2026.json` that 2026-05-13 is NOT an ASP-suspended date
    /// (nearest suspensions are 05-14/05-22/05-23/05-25/05-27/05-28), so the ASP-category
    /// fixtures below evaluate as genuinely "restricted now," not accidentally suspended.
    /// `etDate(...)` is the shared `extension XCTestCase` helper from
    /// `ParkingRulesEngineParityTests.swift`.
    private lazy var now = etDate(year: 2026, month: 5, day: 13, hour: 13)

    /// Mid-Manhattan anchor coordinate — the "destination" every test scans around.
    private let anchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980)

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// Coordinate offset north of `anchor` by `meters`.
    private func near(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: anchor.latitude + meters / 111_320.0, longitude: anchor.longitude)
    }

    /// Builds a `Segment` whose midpoint sits at `coordinate`, with rules that classify
    /// to the requested `category`'s current state at `now` (Wednesday 1pm ET, all days
    /// active — so day-of-week never matters for these fixtures).
    ///
    /// `.metered` needs a real all-day `timeRanges` entry (`currentState`'s "isMeteredNow"
    /// check reads literal time ranges, unlike the `anytime` flag other categories rely
    /// on — see `ParkingRulesEngineParityTests`' metered fixtures for the same pattern).
    private func segment(
        id: String = UUID().uuidString,
        street: String = "TEST ST",
        from: String = "FIRST AVE",
        to: String = "SECOND AVE",
        side: String = "N",
        category: WePark.Category,
        coordinate: CLLocationCoordinate2D,
        rulesOverride: [ParkingRule]? = nil
    ) -> Segment {
        let rules: [ParkingRule]
        if let rulesOverride {
            rules = rulesOverride
        } else if category == .metered {
            rules = [ParkingRule(
                category: .metered,
                description: "Metered parking",
                days: [0, 1, 2, 3, 4, 5, 6],
                timeRanges: [TimeRange(start: 0, end: 1439)],
                anytime: true,
                arrow: nil
            )]
        } else {
            rules = [ParkingRule(
                category: category,
                description: "Test rule",
                days: [0, 1, 2, 3, 4, 5, 6],
                timeRanges: [],
                anytime: true,
                arrow: nil
            )]
        }
        // Midpoint = line[count/2] = line[1] for a 2-element line (matches
        // `Segment.midpoint`'s `coords[coords.count / 2]`).
        return Segment(
            id: id,
            street: street,
            fromStreet: from,
            to: to,
            side: side,
            line: [
                [coordinate.latitude - 0.00005, coordinate.longitude],
                [coordinate.latitude, coordinate.longitude],
            ],
            rules: rules,
            dominantCategory: category
        )
    }

    // MARK: - No data nearby

    func testScore_noSegments_returnsNoDataBucket() {
        let result = ParkingProximityScorer.score(near: anchor, segments: [], engine: engine, now: now)
        XCTAssertEqual(result.bucket, .noData)
        XCTAssertNil(result.summaryLabel)
        XCTAssertEqual(result.scoredBlockfaceCount, 0)
    }

    func testScore_onlySegmentsOutsideRadius_returnsNoDataBucket() {
        let farSeg = segment(category: .free, coordinate: near(500))
        let result = ParkingProximityScorer.score(
            near: anchor, segments: [farSeg], engine: engine, radiusMeters: 100, now: now
        )
        XCTAssertEqual(result.bucket, .noData)
    }

    func testScore_onlySkipCategorySegmentsNearby_returnsNoDataBucket() {
        // NO_STANDING is in the skip set — never counted, even though it's within radius
        // and has real rules data (mirrors RouteService.pickBestParkingAwareRoute's
        // treatment of the same category).
        let noStanding = segment(category: .noStanding, coordinate: near(10))
        let result = ParkingProximityScorer.score(
            near: anchor, segments: [noStanding], engine: engine, now: now
        )
        XCTAssertEqual(result.bucket, .noData)
        XCTAssertEqual(result.restrictedCount, 0, "NO_STANDING must not silently count as restricted.")
    }

    // MARK: - Bucket classification

    func testScore_allFreeSegments_bucketsMostlyFree() {
        let segs = (0..<3).map { i in
            segment(street: "FREE ST \(i)", from: "A\(i)", to: "B\(i)", category: .free, coordinate: near(20))
        }
        let result = ParkingProximityScorer.score(near: anchor, segments: segs, engine: engine, now: now)
        XCTAssertEqual(result.bucket, .mostlyFree)
        XCTAssertEqual(result.summaryLabel, "mostly free")
        XCTAssertEqual(result.freeCount, 3)
        XCTAssertEqual(result.weightedScore, 9)
    }

    func testScore_allMeteredSegments_bucketsMixedNotFree() {
        // 100% metered is neither "mostly free" nor "mostly restricted" — metered means
        // paid parking IS available, so it should land in "mixed," not either extreme.
        let segs = (0..<3).map { i in
            segment(street: "METER ST \(i)", from: "A\(i)", to: "B\(i)", category: .metered, coordinate: near(20))
        }
        let result = ParkingProximityScorer.score(near: anchor, segments: segs, engine: engine, now: now)
        XCTAssertEqual(result.bucket, .mixed)
        XCTAssertEqual(result.summaryLabel, "mixed")
        XCTAssertEqual(result.meteredCount, 3)
        XCTAssertEqual(result.weightedScore, 3)
    }

    func testScore_allRestrictedSegments_bucketsMostlyRestricted() {
        // NOTE: NO_PARKING is a skip-listed category (permanently unparkable, matching
        // RouteService.pickBestParkingAwareRoute's skip set) — using it here would land
        // in `.noData`, not `.mostlyRestricted`. ASP_DAILY is a category that swings
        // between free and restricted over the week, so "active now" is the right
        // fixture for a genuinely time-varying restricted state.
        let aspSegs = (0..<3).map { i -> Segment in
            let rule = ParkingRule(
                category: .aspDaily,
                description: "ASP",
                days: [0, 1, 2, 3, 4, 5, 6],
                timeRanges: [TimeRange(start: 0, end: 1439)],
                anytime: true,
                arrow: nil
            )
            return segment(
                street: "ASP ST \(i)", from: "A\(i)", to: "B\(i)",
                category: .aspDaily, coordinate: near(20), rulesOverride: [rule]
            )
        }
        let result = ParkingProximityScorer.score(near: anchor, segments: aspSegs, engine: engine, now: now)
        XCTAssertEqual(result.bucket, .mostlyRestricted)
        XCTAssertEqual(result.summaryLabel, "mostly restricted")
        XCTAssertEqual(result.restrictedCount, 3)
    }

    func testScore_evenSplitFreeAndRestricted_bucketsMixed() {
        let free = segment(street: "FREE ST", from: "A", to: "B", category: .free, coordinate: near(20))
        let aspRule = ParkingRule(
            category: .aspDaily, description: "ASP", days: [0, 1, 2, 3, 4, 5, 6],
            timeRanges: [TimeRange(start: 0, end: 1439)], anytime: true, arrow: nil
        )
        let restricted = segment(
            street: "ASP ST", from: "C", to: "D", category: .aspDaily,
            coordinate: near(20), rulesOverride: [aspRule]
        )
        let result = ParkingProximityScorer.score(
            near: anchor, segments: [free, restricted], engine: engine, now: now
        )
        XCTAssertEqual(result.bucket, .mixed, "A 50/50 free/restricted split should not tip to either extreme.")
    }

    func testScore_majorityFreeWithSomeRestricted_bucketsMostlyFree() {
        let frees = (0..<3).map { i in
            segment(street: "FREE ST \(i)", from: "A\(i)", to: "B\(i)", category: .free, coordinate: near(20))
        }
        let aspRule = ParkingRule(
            category: .aspDaily, description: "ASP", days: [0, 1, 2, 3, 4, 5, 6],
            timeRanges: [TimeRange(start: 0, end: 1439)], anytime: true, arrow: nil
        )
        let restricted = segment(
            street: "ASP ST", from: "C", to: "D", category: .aspDaily,
            coordinate: near(20), rulesOverride: [aspRule]
        )
        let result = ParkingProximityScorer.score(
            near: anchor, segments: frees + [restricted], engine: engine, now: now
        )
        XCTAssertEqual(result.bucket, .mostlyFree)
    }

    // MARK: - Dedup by blockfaceKey

    func testScore_sameBlockfaceRepeatedInTileData_countedOnce() {
        // Two Segment rows describing the SAME physical blockface (identical
        // street/from/to/side — e.g. two overlapping tile sub-segments) must not double-count.
        let a = segment(street: "SAME ST", from: "A", to: "B", side: "N", category: .free, coordinate: near(10))
        let b = segment(street: "SAME ST", from: "A", to: "B", side: "N", category: .free, coordinate: near(15))
        let result = ParkingProximityScorer.score(near: anchor, segments: [a, b], engine: engine, now: now)
        XCTAssertEqual(result.freeCount, 1, "Same blockfaceKey must be deduped, not double-counted.")
    }

    func testScore_sameStreetDifferentSides_countedSeparately() {
        // Different `side` values are different blockfaces (Segment.blockfaceKey includes
        // side) — both should count.
        let north = segment(street: "SAME ST", from: "A", to: "B", side: "N", category: .free, coordinate: near(10))
        let south = segment(street: "SAME ST", from: "A", to: "B", side: "S", category: .free, coordinate: near(10))
        let result = ParkingProximityScorer.score(near: anchor, segments: [north, south], engine: engine, now: now)
        XCTAssertEqual(result.freeCount, 2)
    }

    // MARK: - Radius boundary

    func testScore_segmentComfortablyInsideRadius_included() {
        // Deliberately not asserting exactly AT the 100m boundary — CLLocation.distance(
        // from:)'s geodesic result isn't perfectly exact against the simple
        // degrees-to-meters conversion `near(_:)` uses, so this asserts a value
        // comfortably inside the radius rather than courting floating-point boundary noise.
        let seg = segment(category: .free, coordinate: near(95))
        let result = ParkingProximityScorer.score(
            near: anchor, segments: [seg], engine: engine, radiusMeters: 100, now: now
        )
        XCTAssertEqual(result.freeCount, 1)
    }

    func testScore_segmentJustOutsideRadius_excluded() {
        let seg = segment(category: .free, coordinate: near(150))
        let result = ParkingProximityScorer.score(
            near: anchor, segments: [seg], engine: engine, radiusMeters: 100, now: now
        )
        XCTAssertEqual(result.freeCount, 0)
        XCTAssertEqual(result.bucket, .noData)
    }

    // MARK: - Unknown-state segments excluded from the denominator

    func testScore_segmentWithNoRulesData_excludedFromBucketButNotSkipped() {
        // dominantCategory .free (not skip-listed) but empty `rules` → engine classifies
        // this as CurrentState.unknown (no data), which must be excluded from the
        // free/metered/restricted denominator rather than guessed into a bucket.
        let noData = segment(category: .free, coordinate: near(10), rulesOverride: [])
        let result = ParkingProximityScorer.score(near: anchor, segments: [noData], engine: engine, now: now)
        XCTAssertEqual(result.scoredBlockfaceCount, 0)
        XCTAssertEqual(result.bucket, .noData)
    }

    // MARK: - Weighted score matches RouteService's weights

    func testWeightedScore_matchesRouteServiceWeights_freeThreeMeteredOne() {
        let free = segment(street: "FREE ST", from: "A", to: "B", category: .free, coordinate: near(10))
        let metered = segment(street: "METER ST", from: "C", to: "D", category: .metered, coordinate: near(10))
        let result = ParkingProximityScorer.score(near: anchor, segments: [free, metered], engine: engine, now: now)
        XCTAssertEqual(result.weightedScore, 3 + 1, accuracy: 0.001)
    }

    // MARK: - ParkingProximityBucket color mapping (design-review finding S2)

    func testBucketColor_mostlyFree_isExistingFreeComfortablyGreen() {
        XCTAssertEqual(ParkingProximityBucket.mostlyFree.color, ParkingColors.freeComfortably)
    }

    func testBucketColor_mixed_isExistingMeteredActiveAmber() {
        XCTAssertEqual(ParkingProximityBucket.mixed.color, ParkingColors.meteredActive)
    }

    func testBucketColor_mostlyRestricted_isExistingRestrictedRed() {
        XCTAssertEqual(ParkingProximityBucket.mostlyRestricted.color, ParkingColors.restricted)
    }

    func testBucketColor_noData_isNil() {
        XCTAssertNil(ParkingProximityBucket.noData.color)
    }

    // MARK: - Bucket labels match the spec's own vocabulary verbatim

    func testBucketLabels_matchSpecVocabularyVerbatim() {
        XCTAssertEqual(ParkingProximityBucket.mostlyFree.label, "mostly free")
        XCTAssertEqual(ParkingProximityBucket.mixed.label, "mixed")
        XCTAssertEqual(ParkingProximityBucket.mostlyRestricted.label, "mostly restricted")
    }
}
