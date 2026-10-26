//
//  GoalAwareDriveCardTests.swift
//  WeParkTests
//
//  fix/goal-aware-drive-card — Kevin's smoke finding (2026-10-26, simulator, flag-on):
//  in an escalated Cruise session with the Overnight goal carried in, `DriveModeBottomCard`
//  colored BOTH side chips green via the legacy `aggregateSideDetail`/`SafetyLabel.severity`
//  classification, while the map painted the left side red because it fails the Overnight
//  goal. These tests cover the fix:
//    - `DrivingContextService.goalAwareChipSeverity(...)` (the new pure function) in
//      isolation — the decision table the fix depends on.
//    - `DrivingContextService.update(...)` end-to-end — reproducing Kevin's exact repro
//      (both sides legacy-free, override colors disagree) and the no-filter/legacy-unchanged
//      parity case.
//
//  Test groups:
//    1. goalAwareChipSeverity decision table (9)
//    2. update(...) integration — Kevin's repro + parity (3)
//    3. DriveModeBottomCard render smoke with an override present (1)
//
//  All dates constructed via explicit DateComponents + America/New_York, matching the
//  house convention (W85cTests.swift's `testDate`: 2026-01-07 is a Wednesday, no ASP rules
//  typically active). No Calendar.current references.
//
//  Reference week used throughout: Wed 2026-01-07 / Thu 2026-01-08 / Fri 2026-01-09.
//

import XCTest
import CoreLocation
import SwiftUI
@testable import WePark

// MARK: - Fixture helpers (local to this file — w85cMakeSeg hardcodes `anytime: true`,
// which short-circuits isFree's day-of-week walk before it ever reaches an ASP category's
// day check; these tests need day-specific, non-`anytime` rules.)

private func gacSegment(
    side: String,
    rules: [ParkingRule],
    street: String = "W 34 ST",
    from: String = "7 AVE",
    to: String = "8 AVE",
    lat: Double = 40.750,
    lng: Double = -73.980
) -> Segment {
    Segment(
        id: UUID().uuidString,
        street: street,
        fromStreet: from,
        to: to,
        side: side,
        line: [[lat, lng], [lat + 0.0001, lng]],
        rules: rules,
        dominantCategory: rules.first?.category
    )
}

private func gacRule(
    category: WePark.Category,
    days: [Int] = [],
    timeRanges: [TimeRange] = [],
    anytime: Bool = false
) -> ParkingRule {
    ParkingRule(category: category, description: "", days: days, timeRanges: timeRanges, anytime: anytime, arrow: nil)
}

/// Wed 2026-01-07, 8:00 AM ET. Thu 1/8 and later fall inside an Overnight-style window
/// ([now, now+2 calendar days)); Tue 1/6 and Fri 1/9 00:00 do not.
private func gacWedMorning() -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 1; comps.day = 7
    comps.hour = 8; comps.minute = 0; comps.second = 0
    comps.timeZone = TimeZone(identifier: "America/New_York")
    return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
}

// MARK: - 1. goalAwareChipSeverity decision table

final class GoalAwareChipSeverityTests: XCTestCase {

    var engine: ParkingRulesEngine!
    let now = gacWedMorning()

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    /// Overnight-style window: [now, midnight of the day after tomorrow) — covers all of
    /// Thursday 1/8, excludes Friday 1/9 entirely. Mirrors `ParkingGoals.target(for: .freeOvernight)`.
    private var overnightTarget: Date { now.startOfDayET(offsetDays: 2) }

    // No filter active at all → nil (defer to legacy severity), regardless of segments.
    func testNoParkUntilMode_returnsNil() {
        let seg = gacSegment(side: "N", rules: [gacRule(category: .aspMonThu, days: [1, 4])])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: false,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertNil(result, "parkUntilMode == false must defer to legacy severity (nil override)")
    }

    // parkUntilMode true but no resolved target → nil (same stale-target guard as rebuildOverlays).
    func testParkUntilModeTrue_nilTarget_returnsNil() {
        let seg = gacSegment(side: "N", rules: [])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: true,
            target: nil,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertNil(result)
    }

    // No segments for this side (data gap) → nil, matching aggregateSideDetail's own
    // `.unknown` early return for an empty side.
    func testEmptySideSegments_returnsNil() {
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [],
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertNil(result)
    }

    // Overnight goal, side's only restriction is Tue/Fri — Thursday (inside the window) is
    // untouched, Friday falls outside the window (excluded by the day-boundary end) → passes.
    func testGoalActiveSide_passesOvernight_returnsFree() {
        let seg = gacSegment(side: "S", rules: [gacRule(category: .aspTueFri, days: [2, 5])])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .free, "ASP Tue/Fri has no restriction inside [Wed 8am, Fri midnight) — should pass")
    }

    // Overnight goal, side has a Mon/Thu ASP sweep — Thursday 1/8 falls inside the window →
    // fails. This is Kevin's exact repro: the side's legacy text ("Free until Tomorrow
    // 8:00 AM") is honest, but the goal's answer is "you'll have to move it" → red.
    func testGoalActiveSide_failsOvernight_returnsRestricted() {
        let seg = gacSegment(side: "N", rules: [gacRule(category: .aspMonThu, days: [1, 4])])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .restricted, "ASP Mon/Thu sweeps Thursday — inside the Overnight window — should fail")
    }

    // Metered side under Overnight (ignoringMeteredPayment: true) — a metered-only segment
    // with active billing hours inside the window still PASSES, because paying a meter
    // doesn't force relocation (§0.8.4).
    func testMeteredSide_overnightIgnoresMeteredPayment_passes() {
        let seg = gacSegment(side: "N", rules: [
            gacRule(category: .metered, days: [0, 1, 2, 3, 4, 5, 6], timeRanges: [TimeRange(start: 540, end: 1140)])
        ])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .free, "Overnight's ignoringMeteredPayment:true must let a metered-only side pass")
    }

    // Free a Few Hours / clock-set Park Until strict semantics (ignoringMeteredPayment:
    // false) — the SAME metered segment now fails, because a short-errand or power-user
    // clock-set promise is "zero required action," and paying a meter breaks that.
    func testMeteredSide_strictIgnoringMeteredPaymentFalse_fails() {
        let seg = gacSegment(side: "N", rules: [
            gacRule(category: .metered, days: [0, 1, 2, 3, 4, 5, 6], timeRanges: [TimeRange(start: 540, end: 1140)])
        ])
        let fewHoursTarget = now.addingTimeInterval(3 * 3600)
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: true,
            target: fewHoursTarget,
            ignoringMeteredPayment: false,
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .restricted, "Strict (ignoringMeteredPayment:false) must fail an active metered window")
    }

    // Clock-set power-user Park Until (no ParkingGoal involved at all — this function never
    // imports ParkingGoals) — same strict metered semantics, proving the single mechanism
    // covers both the goal-active and clock-set paths identically.
    func testClockSetParkUntil_strictMetered_matchesMapBehavior() {
        let seg = gacSegment(side: "N", rules: [
            gacRule(category: .metered, days: [0, 1, 2, 3, 4, 5, 6], timeRanges: [TimeRange(start: 540, end: 1140)])
        ])
        let clockSetTarget = now.addingTimeInterval(6 * 3600)
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [seg],
            parkUntilMode: true,
            target: clockSetTarget,
            ignoringMeteredPayment: false,  // clock-set Park Until's own existing default
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .restricted)
    }

    // ALL-must-pass semantics: a side backed by two physical segments, one of which fails
    // the goal, must read red overall — mirrors aggregateSideDetail's own conservative-min
    // philosophy (a side you may have to touch the car for, even if a different physical
    // piece of the same curb would clear).
    func testMultipleSegmentsOnSide_onePasses_oneFails_overallRestricted() {
        let passing = gacSegment(side: "N", rules: [gacRule(category: .aspTueFri, days: [2, 5])])
        let failing = gacSegment(side: "N", rules: [gacRule(category: .aspMonThu, days: [1, 4])])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [passing, failing],
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .restricted, "Any failing segment on the side must make the whole side red")
    }

    func testMultipleSegmentsOnSide_allPass_overallFree() {
        let a = gacSegment(side: "N", rules: [gacRule(category: .aspTueFri, days: [2, 5])])
        let b = gacSegment(side: "N", rules: [])
        let result = DrivingContextService.goalAwareChipSeverity(
            sideSegments: [a, b],
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
        XCTAssertEqual(result, .free)
    }
}

// MARK: - 2. update(...) integration — Kevin's exact repro + parity

final class GoalAwareDriveCardIntegrationTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var mockVoice: MockDrivingVoice!
    var service: DrivingContextService!
    let now = gacWedMorning()
    let anchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980)

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        mockVoice = MockDrivingVoice()
        service = DrivingContextService(voice: mockVoice)
    }

    override func tearDown() {
        service = nil
        mockVoice = nil
        engine = nil
        super.tearDown()
    }

    /// N = ASP Mon/Thu (fails Overnight — sweeps tomorrow, Thursday), S = ASP Tue/Fri
    /// (passes Overnight — next sweep is outside the window). Both sides read `.free`
    /// under the LEGACY classification right now (no restriction is active THIS INSTANT
    /// on either side), reproducing Kevin's "both chips green" smoke finding.
    private func kevinsRepro() -> [Segment] {
        [
            gacSegment(side: "N", rules: [gacRule(category: .aspMonThu, days: [1, 4])]),
            gacSegment(side: "S", rules: [gacRule(category: .aspTueFri, days: [2, 5])])
        ]
    }

    // Kevin's repro: Overnight goal active (parkUntilMode/target/ignoringMeteredPayment as
    // §0.8.6's rebuildOverlays would set them) — legacy severities stay green on both sides,
    // but the override must disagree with the left side exactly as the map does.
    func testUpdate_overnightGoalActive_leftFailsRightPasses_overridesDisagreeWithLegacy() {
        let segments = kevinsRepro()
        let target = now.startOfDayET(offsetDays: 2)
        service.update(
            coordinate: anchor,
            heading: 90.0,  // facing east: N=left, S=right (matches W85cTests convention)
            segments: segments,
            engine: engine,
            date: now,
            parkUntilMode: true,
            parkUntilTarget: target,
            parkUntilIgnoresMeteredPayment: true
        )
        let ctx = service.currentContext
        XCTAssertNotNil(ctx)
        // Legacy classification: unaffected by this fix — both free right now.
        XCTAssertEqual(ctx?.leftLabel.severity, .free, "Legacy severity must be untouched by this fix")
        XCTAssertEqual(ctx?.rightLabel.severity, .free, "Legacy severity must be untouched by this fix")
        // The fix: override disagrees with legacy on the left, matching the map's goal bucket.
        XCTAssertEqual(ctx?.leftChipColorOverride, .restricted, "Left must read red — it fails the Overnight goal")
        XCTAssertEqual(ctx?.rightChipColorOverride, .free, "Right must read green — it passes the Overnight goal")
    }

    // No Park Until filter active (parkUntilMode defaults to false) → both overrides nil,
    // legacy severities unaffected. This is the flag-off / no-filter byte-identical case.
    func testUpdate_noParkUntilFilter_overridesNilAndLegacyUnchanged() {
        let segments = kevinsRepro()
        service.update(
            coordinate: anchor,
            heading: 90.0,
            segments: segments,
            engine: engine,
            date: now
            // parkUntilMode/parkUntilTarget/parkUntilIgnoresMeteredPayment omitted — defaults.
        )
        let ctx = service.currentContext
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.leftLabel.severity, .free)
        XCTAssertEqual(ctx?.rightLabel.severity, .free)
        XCTAssertNil(ctx?.leftChipColorOverride, "No active filter → nil override (legacy color, unchanged)")
        XCTAssertNil(ctx?.rightChipColorOverride, "No active filter → nil override (legacy color, unchanged)")
    }

    // A side with no segment present (data gap) stays .unknown under the legacy
    // classification AND the override stays nil (goalAwareChipSeverity's own empty-side
    // guard) even while a filter is active elsewhere.
    func testUpdate_parkUntilModeActive_missingSide_overrideNilLegacyUnknown() {
        // Only an N segment — no S segment for this block at all.
        let segments = [gacSegment(side: "N", rules: [gacRule(category: .aspTueFri, days: [2, 5])])]
        service.update(
            coordinate: anchor,
            heading: 90.0,  // N=left, S=right — S has no match
            segments: segments,
            engine: engine,
            date: now,
            parkUntilMode: true,
            parkUntilTarget: now.startOfDayET(offsetDays: 2),
            parkUntilIgnoresMeteredPayment: true
        )
        let ctx = service.currentContext
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.rightLabel.severity, .unknown, "No S segment for this block → unknown, unchanged")
        XCTAssertNil(ctx?.rightChipColorOverride, "No segment on this side → override stays nil, same as before")
        XCTAssertEqual(ctx?.leftChipColorOverride, .free, "N (Tue/Fri) passes the Overnight window")
    }
}

// MARK: - 3. DriveModeBottomCard render smoke with an override present

@MainActor
final class GoalAwareDriveCardRenderTests: XCTestCase {

    // Confirms the card renders without crashing when a chip-color override disagrees
    // with the underlying SafetyLabel's legacy severity (the exact shape Kevin's repro
    // produces) — a regression guard for the view-layer wiring, not the color decision
    // itself (covered above).
    func testDriveModeBottomCard_withColorOverrideDisagreeingWithLegacy_rendersWithoutCrash() {
        let voice = DrivingVoice()
        let context = DrivingContext(
            street: "W 34 ST",
            from: "7 AVE",
            to: "8 AVE",
            leftLabel: SafetyLabel(text: "Free until Tomorrow 8:00 AM", severity: .free),
            rightLabel: SafetyLabel(text: "Free until Tuesday 8:00 AM", severity: .free),
            leftChipColorOverride: .restricted,
            rightChipColorOverride: .free
        )
        let card = DriveModeBottomCard(context: context, voiceService: voice)
        let host = UIHostingController(rootView: card)
        XCTAssertNotNil(host.view, "DriveModeBottomCard with a disagreeing override should render without crash")
    }
}
