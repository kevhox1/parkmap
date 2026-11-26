//
//  StoopPolish1Tests.swift
//  WeParkTests
//
//  Stoop polish batch 1 (flag-on logic only). Pins the PR #200 QA follow-ups:
//    - no surface ever writes "until <non-time>" (the metered `.soon` fallback has its own wording)
//    - the parked-car callout names the FIRST restriction on the curb, not a search window
//    - the search count key is the actual loaded-tile set, not its size
//    - `nextMeterStart` finds meter windows from rule boundaries, however short
//

import CoreLocation
import XCTest
@testable import WePark

final class StoopPolish1Tests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: Fixtures (private names: no collision with other test files)

    private func sp1Date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    /// Wed 11/25/2026 10:11 PM ET.
    private var now: Date { sp1Date(2026, 11, 25, 22, 11) }

    private func sp1Rule(
        _ category: WePark.Category, days: [Int] = [], ranges: [(Int, Int)] = [], anytime: Bool = false
    ) -> [String: Any] {
        [
            "category": category.rawValue, "description": "", "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime, "arrow": "both",
        ]
    }

    private func sp1Segment(_ rules: [[String: Any]], id: String = "SP1") -> Segment {
        let dict: [String: Any] = [
            "id": id, "street": "WEST 53RD STREET", "from": "5TH AVENUE", "to": "6TH AVENUE",
            "side": "N", "line": [[40.7600, -73.9776], [40.7602, -73.9773]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private let everyDay = [0, 1, 2, 3, 4, 5, 6]

    /// A metered curb whose meter rule has no hours (so no meter start is ever found): the `.soon`
    /// fallback. Free now, legal, never green.
    private var fallbackRules: [[String: Any]] { [sp1Rule(.metered, days: everyDay, ranges: [])] }

    private func sp1Model(_ rules: [[String: Any]], window: Date? = nil) -> WPCurbSheetModel {
        WPCurbSheetBuilder.make(segment: sp1Segment(rules), engine: engine, now: now, windowEnd: window)
    }

    private let activeFilming = WPNeighborReports(restrictionLabel: "Blocked for filming", restrictionIsActive: true)

    // MARK: "until <non-time>" guard

    /// Every word that may legally follow "until": a clock (digit), a day word, or midnight.
    private func assertEveryUntilIsATime(_ text: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = text.lowercased()
        var search = lower.startIndex..<lower.endIndex
        while let r = lower.range(of: "until ", range: search) {
            let rest = lower[r.upperBound...]
            let word = rest.prefix { !$0.isWhitespace && $0 != "." && $0 != "," }
            let ok = word.first?.isNumber == true
                || ["midnight", "today", "tomorrow", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "noon"].contains(String(word))
            XCTAssertTrue(ok, "\"until \(word)\" is not a time in \(context): \(text)", file: file, line: line)
            search = r.upperBound..<lower.endIndex
        }
    }

    /// All the strings the surfaces can show for one resolved verdict (sheet block, drag bubble,
    /// car callout), with the block's over + big read together the way the block draws them.
    private func surfaceStrings(_ m: WPCurbSheetModel) -> [String] {
        let bubble = WPDragBubble.make(from: m, windowName: nil)
        return [
            "\(m.over) \(m.big)", m.sub ?? "",
            // `freeLine` is only ever shown for a legal (free) verdict.
            m.variant == .park || m.variant == .soon ? m.freeLine : "",
            bubble.headline, bubble.detail, bubble.hint,
            WPNeighborVerdict.calloutText(for: m) ?? "",
        ]
    }

    func testFallbackSoon_hasItsOwnWording_onEverySurface() {
        let m = sp1Model(fallbackRules)
        XCTAssertEqual(m.variant, .soon)
        XCTAssertFalse(m.bigIsTime)
        XCTAssertEqual(m.big, "Meter on this curb")
        XCTAssertEqual(m.freeLine, "Meter on this curb. Check the meter.")
        let bubble = WPDragBubble.make(from: m, windowName: nil)
        XCTAssertEqual(bubble.headline, "Meter on this curb")
        XCTAssertEqual(WPNeighborVerdict.calloutText(for: m), "Meter on this curb. Check the meter.")
        for text in surfaceStrings(m) {
            XCTAssertFalse(text.lowercased().contains("until meter"), text)
        }
    }

    func testFallbackSoon_withActiveFilmingReport_signLineIsNotGarbled() {
        let applied = WPNeighborVerdict.apply(activeFilming, to: sp1Model(fallbackRules))
        XCTAssertEqual(applied.variant, .dont)
        let sub = applied.sub ?? ""
        XCTAssertFalse(sub.lowercased().contains("until meter"), sub)
        XCTAssertTrue(sub.contains("has a meter"), sub)
    }

    func testNoSurfaceEverWritesUntilNonTime_acrossCurbKinds() {
        let kinds: [[[String: Any]]] = [
            [sp1Rule(.noParking, days: [4], ranges: [(480, 540)])],
            fallbackRules,
            [sp1Rule(.metered, days: everyDay, ranges: [(480, 1140)])],
            [sp1Rule(.metered, days: everyDay, ranges: [(0, 0)])],
            [sp1Rule(.metered, days: everyDay, ranges: [(480, 1140)]), sp1Rule(.noParking, days: [4], ranges: [(480, 540)])],
            [sp1Rule(.noStanding, days: everyDay, anytime: true)],
            [sp1Rule(.noParking, days: everyDay, ranges: [(1320, 0)])],
            [sp1Rule(.truckLoading, days: [1, 2, 3, 4, 5], ranges: [(420, 1080)])],
            [sp1Rule(.unknown)],
            [sp1Rule(.metered, days: everyDay, ranges: [(0, 1439)])],
            [],
        ]
        let windows: [Date?] = [nil, now.addingTimeInterval(3 * 3600), now.addingTimeInterval(9 * 3600), now.addingTimeInterval(48 * 3600)]
        for (i, rules) in kinds.enumerated() {
            for window in windows {
                let base = sp1Model(rules, window: window)
                for report in [WPNeighborReports(), activeFilming] {
                    let m = WPNeighborVerdict.apply(report, to: base)
                    for text in surfaceStrings(m) {
                        assertEveryUntilIsATime(text, "kind \(i), window \(String(describing: window)), \(m.variant)")
                    }
                }
            }
        }
    }

    func testOpenEndedPark_neverReadsUntil7PlusDays() {
        let m = sp1Model([sp1Rule(.noParking, days: [], ranges: [])])
        for report in [WPNeighborReports(), activeFilming] {
            let applied = WPNeighborVerdict.apply(report, to: m)
            for text in surfaceStrings(applied) {
                XCTAssertFalse(text.contains("until 7+"), text)
            }
        }
    }

    // MARK: Car callout

    func testCarCallout_namesFirstRestriction_notTheSearchWindow() {
        // No parking Thu 8-9 AM. A search window ending Thu 10 AM contains it; the saved car's
        // callout is about the car's own curb, so it names Thu 8 AM, never the window end.
        let segment = sp1Segment([sp1Rule(.noParking, days: [4], ranges: [(480, 540)])])
        let callout = WPNeighborVerdict.carCallout(segment: segment, engine: engine, now: now, reports: WPNeighborReports())
        let expected = WPNeighborVerdict.calloutText(for: WPNeighborVerdict.resolve(
            segment: segment, engine: engine, now: now, windowEnd: nil, trip: nil, reports: WPNeighborReports()
        ))
        XCTAssertEqual(callout, expected)
        XCTAssertEqual(callout, "Free until Tomorrow 8:00\u{00A0}AM")
        XCTAssertFalse((callout ?? "").contains("10"), "must not name the search window's end")
    }

    func testCarCallout_meterIsFirst_namesTheMeterStart() {
        let segment = sp1Segment([sp1Rule(.metered, days: everyDay, ranges: [(480, 1140)])])
        let callout = WPNeighborVerdict.carCallout(segment: segment, engine: engine, now: now, reports: WPNeighborReports())
        XCTAssertEqual(callout, "Free until Tomorrow 8:00\u{00A0}AM")
    }

    func testCarCallout_fallbackMeter_readsNaturally() {
        let segment = sp1Segment(fallbackRules)
        let callout = WPNeighborVerdict.carCallout(segment: segment, engine: engine, now: now, reports: WPNeighborReports())
        XCTAssertEqual(callout, "Meter on this curb. Check the meter.")
    }

    func testCarCallout_activeFilmingReport_isNeverGreener() {
        let segment = sp1Segment([sp1Rule(.noParking, days: [4], ranges: [(480, 540)])])
        let callout = WPNeighborVerdict.carCallout(segment: segment, engine: engine, now: now, reports: activeFilming)
        XCTAssertEqual(callout, "Blocked for filming")
    }

    // MARK: Window decides park vs soon

    func testRestrictionAtWindowEnd_isPark_withTheWindow_andSoonWithout() {
        // Thu 1:30 AM; no parking Thu 7-8 AM (inside the 6 h "soon" band). Overnight window ends 7 AM.
        let early = sp1Date(2026, 11, 26, 1, 30)
        let segment = sp1Segment([sp1Rule(.noParking, days: [4], ranges: [(420, 480)])])
        func variant(_ window: Date?) -> WPCurbVariant {
            WPCurbSheetBuilder.make(segment: segment, engine: engine, now: early, windowEnd: window).variant
        }
        let sevenAM = sp1Date(2026, 11, 26, 7, 0)
        XCTAssertEqual(variant(sevenAM), .park, "green on the map for this window, so the sheet agrees")
        XCTAssertEqual(variant(sp1Date(2026, 11, 26, 8, 0)), .soon, "restriction starts inside the window")
        XCTAssertEqual(variant(nil), .soon)
        // Map and sheet agree.
        XCTAssertTrue(WPCurbVerdict.isParkable(segment: segment, engine: engine, from: early, until: sevenAM))
    }

    // MARK: Search count key

    func testSearchCountKey_changesWhenTheLoadedSetChanges_atEqualCount() {
        let place = WPResolvedPlace(name: "X", address: nil, coordinate: CLLocationCoordinate2D(latitude: 40.76, longitude: -73.97))
        let end = now.addingTimeInterval(3600)
        let a = WPSearchCountKey(place: place, goal: .freeOvernight, segments: 10, loadedTiles: ["1_1", "1_2"], end: end)
        let sameSet = WPSearchCountKey(place: place, goal: .freeOvernight, segments: 10, loadedTiles: ["1_2", "1_1"], end: end)
        let swapped = WPSearchCountKey(place: place, goal: .freeOvernight, segments: 10, loadedTiles: ["1_1", "2_2"], end: end)
        XCTAssertEqual(a, sameSet)
        XCTAssertNotEqual(a, swapped, "an equal-sized tile swap must retrigger the count")
    }

    // MARK: nextMeterStart

    private func bruteForceNextMeterStart(_ segment: Segment, from: Date) -> Date? {
        var t = from
        let limit = from.addingTimeInterval(WPCurbSheetBuilder.lookAheadHours * 3600)
        while t < limit {
            t = t.addingTimeInterval(60)
            if engine.currentState(for: segment, at: t) == .meteredActive { return t }
        }
        return nil
    }

    func testNextMeterStart_findsAShortWindowTheOldStepMissed() {
        // Meter 8:00-8:10 AM. From 10:11 PM a 15 minute step lands at 8:11 and skips it.
        let segment = sp1Segment([sp1Rule(.metered, days: everyDay, ranges: [(480, 490)])])
        let start = WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: now)
        XCTAssertEqual(start, sp1Date(2026, 11, 26, 8, 0))
    }

    func testNextMeterStart_honorsDays() {
        // Mondays only: Wed 11/25 -> Mon 11/30 8:00.
        let segment = sp1Segment([sp1Rule(.metered, days: [1], ranges: [(480, 490)])])
        XCTAssertEqual(WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: now), sp1Date(2026, 11, 30, 8, 0))
    }

    func testNextMeterStart_nilWhenNoMeterHours() {
        XCTAssertNil(WPCurbCopy.nextMeterStart(segment: sp1Segment(fallbackRules), engine: engine, from: now))
        XCTAssertNil(WPCurbCopy.nextMeterStart(segment: sp1Segment([sp1Rule(.noParking, days: [4], ranges: [(480, 540)])]), engine: engine, from: now))
    }

    func testNextMeterStart_matchesAMinuteScan_forAssortedMeterRules() {
        let ruleSets: [[(days: [Int], ranges: [(Int, Int)])]] = [
            [(everyDay, [(480, 1140)])],
            [([1, 2, 3, 4, 5], [(540, 549)])],
            [([6], [(600, 601)])],
            [(everyDay, [(1380, 60)])],
            [(everyDay, [(300, 320), (700, 705)])],
            [([2], [(480, 490)]), ([5], [(720, 730)])],
        ]
        // The last four straddle DST: the eve of spring-forward (Mar 14 2027, Mar 8 2026) and of
        // fall-back (Nov 1 2026), plus the early morning of the change itself.
        let froms = [
            now, sp1Date(2026, 11, 26, 8, 5), sp1Date(2026, 11, 28, 23, 59),
            sp1Date(2027, 3, 13, 22, 0), sp1Date(2026, 3, 7, 22, 0),
            sp1Date(2026, 10, 31, 22, 0), sp1Date(2026, 11, 1, 0, 30),
        ]
        for (i, set) in ruleSets.enumerated() {
            let rules = set.map { sp1Rule(.metered, days: $0.days, ranges: $0.ranges) }
            let segment = sp1Segment(rules)
            for from in froms {
                let expected = bruteForceNextMeterStart(segment, from: from)
                let actual = WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: from)
                // The scan reports the first minute the meter is on after `from`; the boundary
                // search reports the next START. They agree unless the meter is already on at
                // `from` (the scan then returns from + 1 min, a continuation, not a start).
                if engine.currentState(for: segment, at: from) == .meteredActive { continue }
                XCTAssertEqual(actual, expected, "rule set \(i), from \(from)")
            }
        }
    }

    // MARK: nextMeterStart on DST days

    func testNextMeterStart_springForwardEve_isEightAMWallClock() {
        // Sat 3/13/2027 10 PM ET; clocks jump forward overnight. An 8 AM meter on Sunday starts at
        // 8:00 AM EDT (elapsed-minutes arithmetic gave 9:00 AM).
        let segment = sp1Segment([sp1Rule(.metered, days: everyDay, ranges: [(480, 540)])])
        let start = WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: sp1Date(2027, 3, 13, 22, 0))
        XCTAssertEqual(start, sp1Date(2027, 3, 14, 8, 0))
        XCTAssertEqual(start?.minuteOfDayET, 480)
    }

    func testNextMeterStart_fallBackEve_findsTheNextDaysMeter() {
        // Sat 10/31/2026 10 PM ET; clocks fall back overnight (25 hour day). The Sunday 8 AM meter
        // must be found (the elapsed-minutes version landed at 7 AM and was dropped as not in force).
        let segment = sp1Segment([sp1Rule(.metered, days: everyDay, ranges: [(480, 540)])])
        let start = WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: sp1Date(2026, 10, 31, 22, 0))
        XCTAssertEqual(start, sp1Date(2026, 11, 1, 8, 0))
    }

    func testNextMeterStart_sundayOnlyMeter_acrossFallBack() {
        // Meter only on Sunday 7:00-9:00: found at 7:00 AM EST on 11/1, not skipped.
        let segment = sp1Segment([sp1Rule(.metered, days: [0], ranges: [(420, 540)])])
        let start = WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: sp1Date(2026, 10, 31, 22, 0))
        XCTAssertEqual(start, sp1Date(2026, 11, 1, 7, 0))
    }
}
