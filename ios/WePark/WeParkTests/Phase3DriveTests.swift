//
//  Phase3DriveTests.swift
//  WeParkTests
//
//  Design system Phase 3 (Drive mode, B5). Pins Kevin's accuracy rules:
//    - a side is `park` only when the goal-aware verdict (the map's single green gate) says so
//      AND the label is a free label; unclear / no-data / unknown are never `park`; a meter follows the map gate exactly
//    - left and right are spelled out in words
//    - the drive chip agrees with `WPCurbVerdict.isParkable` (the map's gate), including for
//      unreadable (UNKNOWN / no-data) signs that `isFree` alone would let through
//    - midnight is "midnight"; destination wording; the raised Park here needs a green side
//

import CoreLocation
import MapKit
import XCTest
@testable import WePark

final class Phase3DriveTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: Fixtures

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    /// Wed 11/25/2026 10:11 PM ET.
    private var now: Date { et(2026, 11, 25, 22, 11) }

    private func ruleJSON(
        _ category: WePark.Category, days: [Int] = [], ranges: [(Int, Int)] = [],
        anytime: Bool = false, description: String = ""
    ) -> [String: Any] {
        [
            "category": category.rawValue, "description": description, "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime, "arrow": "both",
        ]
    }

    private func driveSegment(_ rules: [[String: Any]], id: String = "D1") -> Segment {
        let dict: [String: Any] = [
            "id": id, "street": "EAST 1ST STREET", "from": "1ST AVENUE", "to": "2ND AVENUE",
            "side": "N", "line": [[40.7220, -73.9870], [40.7222, -73.9865]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private func label(_ text: String, _ severity: SafetyLabel.Severity) -> SafetyLabel {
        SafetyLabel(text: text, severity: severity)
    }

    // MARK: Side mapping

    func testSide_greenOnlyWhenGoalVerdictIsFree_andLabelIsFree() {
        let s = WPDriveVerdict.side(isLeft: true, label: label("Free until Mon 9:00 AM", .free), override: .free)
        XCTAssertEqual(s.kind, .park)
        XCTAssertEqual(s.big, "Park")
        XCTAssertEqual(s.sub, "Free until Mon 9:00\u{00A0}AM")
        let soon = WPDriveVerdict.side(isLeft: false, label: label("Free until Today 11:45 PM", .comingSoon), override: .free)
        XCTAssertEqual(soon.kind, .park)
    }

    func testSide_noGoalWindow_isNeverGreen() {
        let s = WPDriveVerdict.side(isLeft: true, label: label("Free until Mon 9:00 AM", .free), override: nil)
        XCTAssertEqual(s.kind, .soon)
        XCTAssertFalse(s.kind.isParkable)
    }

    func testSide_unclearNoDataUnknownMetered_areNeverPark_whateverTheGoalSays() {
        let unreadable = [
            label(NoSignData.headline, .restricted), label(UnclearSign.headline, .restricted),
            label(UnclearSign.upcomingLabel, .free), label("\u{2014}", .unknown), label("", .unknown),
        ]
        for l in unreadable {
            for override in [SafetyLabel.Severity.free, .restricted, nil] {
                let s = WPDriveVerdict.side(isLeft: true, label: l, override: override)
                XCTAssertNotEqual(s.kind, .park, "\(l.text) / \(String(describing: override))")
                XCTAssertNotEqual(s.kind, .soon, "\(l.text) / \(String(describing: override))")
            }
        }
        XCTAssertEqual(WPDriveVerdict.side(isLeft: true, label: label(NoSignData.headline, .restricted), override: .free).kind, .nodata)
    }

    /// A meter running inside the window is not park; a meter whose hours fall outside the window is
    /// legally free and the map draws it green, so the card reads park too. The card is derived from
    /// the SAME goal verdict, so it can never disagree with `WPCurbVerdict.isParkable`.
    func testMeter_cardAgreesWithMapGate_insideAndOutsideTheWindow() {
        let meterRules = [ruleJSON(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(480, 1140)])] // 8 AM to 7 PM
        let segment = driveSegment(meterRules)
        let cases: [(hours: Double, expectPark: Bool)] = [
            (8.0, true),    // 10:11 PM to 6:11 AM: meter off the whole window
            (14.0, false),  // runs into 8 AM: meter in the window
            (30.0, false),
        ]
        for (hours, expectPark) in cases {
            let target = now.addingTimeInterval(hours * 3600)
            let mapGreen = WPCurbVerdict.isParkable(segment: segment, engine: engine, from: now, until: target)
            XCTAssertEqual(mapGreen, expectPark, "fixture sanity \(hours)h")
            let chip = DrivingContextService.goalAwareChip(
                sideSegments: [segment], parkUntilMode: true, target: target,
                ignoringMeteredPayment: false, from: now, engine: engine, strictParkable: true
            )
            let side = WPDriveVerdict.side(
                isLeft: true, label: chip?.labelOverride ?? label("Metered", .metered), override: chip?.severity
            )
            XCTAssertEqual(side.kind == .park, mapGreen, "drive card must equal the map's verdict at \(hours)h")
        }
        // A metered label with a free goal verdict is park (the map's green); without one it is not.
        XCTAssertEqual(WPDriveVerdict.side(isLeft: true, label: label("Metered", .metered), override: .free).kind, .park)
        XCTAssertEqual(WPDriveVerdict.side(isLeft: true, label: label("Metered", .metered), override: .restricted).kind, .meter)
        XCTAssertEqual(WPDriveVerdict.side(isLeft: true, label: label("Metered", .metered), override: nil).kind, .meter)
    }

    func testSide_everyCombination_parkRequiresFreeLabelAndFreeGoalVerdict() {
        let severities: [SafetyLabel.Severity] = [.free, .comingSoon, .metered, .restricted, .unknown]
        let texts = ["Free until Mon 9:00 AM", "Free \u{2014} check signs", "No parking", "Metered",
                     NoSignData.headline, UnclearSign.headline, "Not free through your window", "\u{2014}", ""]
        let overrides: [SafetyLabel.Severity?] = [nil, .free, .restricted]
        for sev in severities {
            for text in texts {
                for override in overrides {
                    let s = WPDriveVerdict.side(isLeft: true, label: label(text, sev), override: override)
                    if s.kind == .park {
                        XCTAssertTrue(sev == .free || sev == .comingSoon || sev == .metered, "\(sev) \(text)")
                        XCTAssertEqual(override, .free, "\(sev) \(text)")
                        if sev != .metered { XCTAssertTrue(text.hasPrefix("Free"), text) }
                    }
                }
            }
        }
    }

    func testSide_freeLabelWithoutATime_neverClaimsAnEndTime() {
        let s = WPDriveVerdict.side(isLeft: true, label: label("Free \u{2014} check signs", .free), override: .free)
        XCTAssertEqual(s.kind, .park)
        XCTAssertEqual(s.sub, "Check the signs")
    }

    func testSide_notFreeThroughWindow_isDont_notNoParking() {
        let s = WPDriveVerdict.side(
            isLeft: false, label: label(WPDriveVerdict.notThroughWindow, .restricted), override: .restricted
        )
        XCTAssertEqual(s.kind, .dont)
        XCTAssertEqual(s.big, "Not free")
        XCTAssertFalse(s.big.lowercased().contains("no parking"), "free now: never claim a restriction")
        let plain = WPDriveVerdict.side(isLeft: false, label: label("No parking", .restricted), override: .restricted)
        XCTAssertEqual(plain.big, "No parking")
    }

    func testSide_freeLabelButWindowFails_isDont() {
        let s = WPDriveVerdict.side(isLeft: true, label: label("Free until Tomorrow 8:00 AM", .free), override: .restricted)
        XCTAssertEqual(s.kind, .dont)
    }

    func testMidnight_isSpelledOut() {
        let s = WPDriveVerdict.side(isLeft: true, label: label("Free until Today 12:00 AM", .free), override: .free)
        XCTAssertTrue(s.sub?.contains("midnight") ?? false)
        XCTAssertFalse(s.sub?.contains("12:00") ?? true)
    }

    // MARK: Left / right in words

    func testSides_areSpelledOutInWords() {
        let left = WPDriveVerdict.side(isLeft: true, label: label("No parking", .restricted), override: nil)
        let right = WPDriveVerdict.side(isLeft: false, label: label("No parking", .restricted), override: nil)
        XCTAssertEqual(left.name, "Left side")
        XCTAssertEqual(right.name, "Right side")
        XCTAssertTrue(left.spoken.hasPrefix("Left side."))
        XCTAssertTrue(right.spoken.hasPrefix("Right side."))
        XCTAssertEqual(right.plainLine, "Right side: no parking.")
        XCTAssertFalse(left.spoken.contains(".."))
    }

    func testSides_forContext_keepTheContextsLeftAndRight() {
        // The left/right split is DrivingContextService's (direction of travel); this only maps it.
        let ctx = DrivingContext(
            street: "E 1 ST", from: "1 AVE", to: "2 AVE",
            leftLabel: label("Free until Mon 9:00 AM", .free), rightLabel: label("No parking", .restricted),
            leftChipColorOverride: .free, rightChipColorOverride: .restricted
        )
        let sides = WPDriveVerdict.sides(for: ctx)
        XCTAssertEqual(sides.left.kind, .park)
        XCTAssertTrue(sides.left.isLeft)
        XCTAssertEqual(sides.right.kind, .dont)
        XCTAssertFalse(sides.right.isLeft)
    }

    func testSides_noContext_isChecking_andNeverPark() {
        let sides = WPDriveVerdict.sides(for: nil)
        XCTAssertEqual(sides.left.kind, .checking)
        XCTAssertEqual(sides.right.kind, .checking)
        XCTAssertEqual(sides.left.big, "Checking")
        XCTAssertEqual(WPDriveVerdict.primary(left: sides.left, right: sides.right), .checking)
        XCTAssertFalse(WPDriveVerdict.primary(left: sides.left, right: sides.right).isRaised)
    }

    // MARK: Primary action

    func testPrimary_raisedOnlyWithAGreenSide() {
        func s(_ kind: WPDriveKind, left: Bool = true) -> WPDriveSide {
            WPDriveSide(kind: kind, isLeft: left, big: "x", sub: nil)
        }
        XCTAssertEqual(WPDriveVerdict.primary(left: s(.park), right: s(.dont, left: false)), .park)
        XCTAssertEqual(WPDriveVerdict.primary(left: s(.dont), right: s(.park, left: false)), .park)
        XCTAssertEqual(WPDriveVerdict.primary(left: s(.dont), right: s(.nodata, left: false)), .anyway)
        XCTAssertEqual(WPDriveVerdict.primary(left: s(.meter), right: s(.soon, left: false)), .anyway)
        XCTAssertEqual(WPDriveVerdict.Primary.anyway.title, "Park here anyway")
        XCTAssertEqual(WPDriveVerdict.Primary.park.title, "Park here")
        XCTAssertTrue(WPDriveVerdict.Primary.park.isRaised)
        XCTAssertFalse(WPDriveVerdict.Primary.anyway.isRaised)
        for kind in WPDriveKind.allCases where kind != .park {
            XCTAssertFalse(kind.isParkable)
        }
    }

    func testWidthShare_greenSideGetsTheWiderCard() {
        func s(_ kind: WPDriveKind) -> WPDriveSide { WPDriveSide(kind: kind, isLeft: true, big: "x", sub: nil) }
        XCTAssertEqual(WPDriveVerdict.widthShare(of: s(.park), other: s(.park)), 0.5)
        XCTAssertEqual(WPDriveVerdict.widthShare(of: s(.dont), other: s(.dont)), 0.5)
        XCTAssertGreaterThan(WPDriveVerdict.widthShare(of: s(.park), other: s(.dont)), 0.5)
        XCTAssertLessThan(WPDriveVerdict.widthShare(of: s(.dont), other: s(.park)), 0.5)
        XCTAssertEqual(
            WPDriveVerdict.widthShare(of: s(.park), other: s(.dont)) + WPDriveVerdict.widthShare(of: s(.dont), other: s(.park)), 1.0,
            accuracy: 0.0001
        )
    }

    // MARK: Destination wording

    func testDestinationLine_wording() {
        XCTAssertEqual(WPDriveVerdict.destinationLine(meters: 1930, approaching: false, metric: false), "1.2 mi to destination")
        XCTAssertEqual(WPDriveVerdict.destinationLine(meters: 120, approaching: false, metric: false), "Destination in 400 ft")
        XCTAssertEqual(
            WPDriveVerdict.destinationLine(meters: 400, approaching: true, metric: false), "Destination in 0.2 mi",
            "approaching always reads \"in\""
        )
    }

    func testDestinationLine_metricAndRounding() {
        XCTAssertEqual(WPDriveVerdict.destinationLine(meters: 2000, approaching: false, metric: true), "2.0 km to destination")
        XCTAssertEqual(WPDriveVerdict.destinationLine(meters: 87, approaching: false, metric: true), "Destination in 90 m")
        XCTAssertEqual(WPDriveVerdict.distanceText(meters: 3, metric: false), "50 ft")
        XCTAssertEqual(WPDriveVerdict.distanceText(meters: 0, metric: true), "10 m")
    }

    func testVoiceTitle_andStreetTitle() {
        XCTAssertEqual(WPDriveVerdict.voiceTitle(muted: false), "Voice on")
        XCTAssertEqual(WPDriveVerdict.voiceTitle(muted: true), "Voice off")
        XCTAssertFalse(WPDriveVerdict.streetTitle("EAST 1ST STREET").contains("EAST"))
    }

    // MARK: The drive chip is the map's gate

    /// While the flag is on the chip uses `WPCurbVerdict.isParkable`; it never says `.free` for a
    /// side the map would draw red, including an UNKNOWN-sign curb that `isFree` alone ignores.
    func testGoalAwareChip_strict_agreesWithIsParkable_forEveryFixtureAndWindow() {
        let fixtures: [[[String: Any]]] = [
            [ruleJSON(.noParking, days: [1], ranges: [(480, 540)])],
            [ruleJSON(.noParking, days: [], ranges: [(480, 540)])],
            [ruleJSON(.noStanding, days: [0, 1, 2, 3, 4, 5, 6], anytime: true)],
            [ruleJSON(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(0, 1439)])],
            [ruleJSON(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(480, 1140)])],
            [ruleJSON(.unknown, description: "CARSHARE")],
            [ruleJSON(.noParking, anytime: true, description: "NO DATA: SUPERSEDED SIGN")],
            [ruleJSON(.unknown, description: "X"), ruleJSON(.noParking, days: [1], ranges: [(480, 540)])],
        ]
        for rules in fixtures {
            let segment = driveSegment(rules)
            for hours in [2.0, 9.0, 30.0, 96.0] {
                let target = now.addingTimeInterval(hours * 3600)
                let chip = DrivingContextService.goalAwareChip(
                    sideSegments: [segment], parkUntilMode: true, target: target,
                    ignoringMeteredPayment: false, from: now, engine: engine, strictParkable: true
                )
                let mapGreen = WPCurbVerdict.isParkable(segment: segment, engine: engine, from: now, until: target)
                XCTAssertEqual(chip?.severity == .free, mapGreen, "window \(hours)h \(rules)")
            }
        }
    }

    func testGoalAwareChip_strict_refusesUnknownSign_thatIsFreeIgnores() {
        let segment = driveSegment([ruleJSON(.unknown, days: [], ranges: [(480, 540)], description: "CARSHARE")])
        let target = now.addingTimeInterval(2 * 3600)
        let strict = DrivingContextService.goalAwareChip(
            sideSegments: [segment], parkUntilMode: true, target: target,
            ignoringMeteredPayment: false, from: now, engine: engine, strictParkable: true
        )
        XCTAssertEqual(strict?.severity, .restricted)
        XCTAssertFalse(WPCurbVerdict.isParkable(segment: segment, engine: engine, from: now, until: target))
    }

    func testGoalAwareChip_defaultIsLegacy_unchangedFlagOff() {
        // strictParkable defaults to false: the existing `isFree` path.
        let segment = driveSegment([ruleJSON(.noParking, days: [], ranges: [(480, 540)])])
        let target = now.addingTimeInterval(2 * 3600)
        let legacy = DrivingContextService.goalAwareChip(
            sideSegments: [segment], parkUntilMode: true, target: target,
            ignoringMeteredPayment: false, from: now, engine: engine
        )
        XCTAssertEqual(legacy?.severity, .free)
    }

    // MARK: Ink tint

    func testDriveTint_coversTheCity_andIsTranslucent() {
        let tint = WPDriveTintPolygon.make()
        let manhattan = MKMapRect(
            origin: MKMapPoint(CLLocationCoordinate2D(latitude: 40.882, longitude: -74.02)),
            size: MKMapSize(width: 1, height: 1)
        )
        XCTAssertTrue(tint.boundingMapRect.intersects(manhattan))
        XCTAssertTrue(tint.boundingMapRect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855))))
        XCTAssertGreaterThan(WPDriveTintPolygon.alpha, 0.1)
        XCTAssertLessThan(WPDriveTintPolygon.alpha, 0.6)
    }
}
