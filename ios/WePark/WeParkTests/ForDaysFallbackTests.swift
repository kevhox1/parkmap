//
//  ForDaysFallbackTests.swift
//  WeParkTests
//
//  DT35-1 (PR4): the "nothing nearby is free until the picked time" fallback. The binary search
//  must equal a brute-force scan of the 30 minute grid, the result is never earlier than the
//  Overnight end or later than the request, and green is only ever coloured for the shown end.
//  Also pins nesting (green(requested) in green(T*) in green(Overnight)) on a multi-day fixture
//  and the banner copy strings.
//
//  Reference: 2026-06-04 is a Thursday. Fixture curbs (all readable signs, NO_PARKING windows):
//    sat   restricted Saturday 12:00 PM to 2:00 PM  (clear until Sat 12 PM)
//    sun   restricted Sunday   8:00 AM to 10:00 AM  (clear until Sun 8 AM)
//    tue   restricted Tuesday  7:00 AM to 9:00 AM   (clear until Tue 7 AM)
//    clear a free rule only                          (clear for the whole range)
//

import XCTest
@testable import WePark

final class ForDaysFallbackTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private let nbsp = "\u{00A0}"
    private let now = ForDaysFallbackTests.etDate(2026, 6, 4, 10, 0)

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    nonisolated private static func etDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }

    // MARK: Fixtures

    private func makeSegment(id: String, rules: [[String: Any]]) -> Segment {
        let dict: [String: Any] = [
            "id": id, "street": "MOTT STREET", "from": "GRAND STREET", "to": "HESTER STREET",
            "side": "N", "line": [[40.7183, -73.9942], [40.7190, -73.9940]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private func rule(_ category: String, days: [Int], start: Int, end: Int, anytime: Bool = false) -> [String: Any] {
        [
            "category": category, "description": "", "days": days,
            "timeRanges": anytime ? [] : [["start": start, "end": end]],
            "anytime": anytime, "arrow": "both",
        ]
    }

    private var sat: Segment { makeSegment(id: "sat", rules: [rule("NO_PARKING", days: [6], start: 720, end: 840)]) }
    private var sun: Segment { makeSegment(id: "sun", rules: [rule("NO_PARKING", days: [0], start: 480, end: 600)]) }
    private var tue: Segment { makeSegment(id: "tue", rules: [rule("NO_PARKING", days: [2], start: 420, end: 540)]) }
    private var clear: Segment { makeSegment(id: "clear", rules: [rule("FREE", days: [1, 2, 3, 4, 5], start: 480, end: 1320)]) }
    private var never: Segment { makeSegment(id: "never", rules: [rule("NO_PARKING", days: [], start: 0, end: 0, anytime: true)]) }

    private var grid: [Date] { ForDaysUntil.grid(now: now, morningHour: 7) }

    private func resolve(_ segments: [Segment], requested: Date) -> WPForDaysState {
        let engine = self.engine!
        let from = now
        return ForDaysFallback.resolve(
            requested: requested,
            grid: grid,
            anyClear: { ForDaysFallback.anyClear(segments: segments, engine: engine, from: from, until: $0) },
            count: { ForDaysFallback.clearCount(segments: segments, engine: engine, from: from, until: $0) }
        )
    }

    private func green(_ segments: [Segment], until: Date) -> Set<String> {
        Set(segments.filter {
            WPCurbVerdict.isParkable(segment: $0, engine: engine, from: now, until: until)
        }.map(\.id))
    }

    private func bruteForceBest(_ segments: [Segment], requested: Date) -> Date? {
        grid.filter { $0 <= requested }.last { !green(segments, until: $0).isEmpty }
    }

    // MARK: Fixture sanity (the engine says what the comments say)

    func testFixture_clearUntilTimesMatchTheEngine() {
        XCTAssertTrue(green([sat], until: Self.etDate(2026, 6, 6, 12, 0)).contains("sat"))
        XCTAssertFalse(green([sat], until: Self.etDate(2026, 6, 6, 12, 30)).contains("sat"))
        XCTAssertTrue(green([tue], until: Self.etDate(2026, 6, 9, 7, 0)).contains("tue"))
        XCTAssertFalse(green([tue], until: Self.etDate(2026, 6, 9, 7, 30)).contains("tue"))
        XCTAssertTrue(green([clear], until: Self.etDate(2026, 6, 11, 0, 0)).contains("clear"))
    }

    // MARK: Binary search equals brute force

    func testBinarySearch_equalsBruteForce_forEveryRequestedStep() {
        let segments = [sat, sun, tue]
        for requested in grid {
            let state = resolve(segments, requested: requested)
            let brute = bruteForceBest(segments, requested: requested)
            XCTAssertEqual(state.effective, brute ?? grid[0], "requested \(requested)")
            XCTAssertEqual(state.kind == .empty, brute == nil, "requested \(requested)")
            XCTAssertGreaterThanOrEqual(state.effective, grid[0], "never below the Overnight end")
            XCTAssertLessThanOrEqual(state.effective, requested, "never later than the request")
        }
    }

    func testFallback_pickedTuesday9AM_fallsBackToTheLatestClearStep() {
        let state = resolve([sat, sun, tue], requested: Self.etDate(2026, 6, 9, 9, 0))
        // Tue is restricted from 7 AM so Tue 9 AM is not free anywhere; the latest end with a
        // clear curb is the tue curb's own limit, Tue 7:00 AM.
        XCTAssertTrue(state.isFallback)
        XCTAssertEqual(state.kind, .fallback)
        XCTAssertEqual(state.effective, Self.etDate(2026, 6, 9, 7, 0))
        XCTAssertEqual(state.requested, Self.etDate(2026, 6, 9, 9, 0))
        XCTAssertEqual(state.guardKind, .steppedDown)
    }

    func testFallback_neverColoursForTheRequestedTime() {
        let segments = [sat, sun, tue]
        let requested = Self.etDate(2026, 6, 9, 9, 0)
        let state = resolve(segments, requested: requested)
        XCTAssertTrue(green(segments, until: requested).isEmpty, "nothing is clear until the request")
        let colored = green(segments, until: state.effective)
        XCTAssertEqual(colored.count, state.greenCount, "the green set is exactly what is clear until T*")
        XCTAssertEqual(colored, ["tue"])
    }

    func testFallbackColors_onlyUpToTheShownEnd_notBeyond() {
        let segments = [sat, sun, tue]
        let state = resolve(segments, requested: Self.etDate(2026, 6, 11, 0, 0))
        XCTAssertEqual(state.effective, Self.etDate(2026, 6, 9, 7, 0))
        let later = grid.first { $0 > state.effective }!
        XCTAssertTrue(green(segments, until: later).isEmpty, "one step past T* has no green at all")
    }

    func testRequestedHasGreen_noFallback_noBanner() {
        let segments = [sat, clear]
        let requested = Self.etDate(2026, 6, 9, 9, 0)
        let state = resolve(segments, requested: requested)
        XCTAssertFalse(state.isFallback)
        XCTAssertNil(state.kind)
        XCTAssertNil(state.guardKind)
        XCTAssertEqual(state.effective, requested)
        XCTAssertEqual(state.greenCount, 1)
    }

    // MARK: Empty at the minimum

    func testEmpty_whenEvenTheOvernightEndHasNoClearCurb() {
        let state = resolve([never], requested: Self.etDate(2026, 6, 9, 9, 0))
        XCTAssertEqual(state.kind, .empty)
        XCTAssertFalse(state.isFallback)
        XCTAssertEqual(state.effective, grid[0], "display only, nothing coloured")
        XCTAssertEqual(state.greenCount, 0)
        XCTAssertEqual(state.guardKind, .empty)
        XCTAssertTrue(green([never], until: state.effective).isEmpty)
    }

    func testEmpty_whenRequestIsTheMinimumAndNothingIsClear() {
        let state = resolve([never], requested: grid[0])
        XCTAssertEqual(state.kind, .empty)
    }

    func testEmpty_noSegmentsLoaded() {
        XCTAssertEqual(resolve([], requested: Self.etDate(2026, 6, 9, 9, 0)).kind, .empty)
    }

    // MARK: Thin fallback

    func testThinFallback_threshold() {
        let requested = Self.etDate(2026, 6, 9, 9, 0)
        let best = Self.etDate(2026, 6, 6, 12, 0)
        func state(bestCount: Int) -> WPForDaysState {
            ForDaysFallback.resolve(
                requested: requested, grid: grid,
                anyClear: { $0 <= best },
                count: { $0 == best ? bestCount : 100 }
            )
        }
        XCTAssertEqual(state(bestCount: 10).effective, best)
        XCTAssertTrue(state(bestCount: 10).thin, "10 of 100 is under 25 percent")
        XCTAssertFalse(state(bestCount: 25).thin, "exactly 25 percent is not thin")
        XCTAssertFalse(state(bestCount: 60).thin)
    }

    // MARK: Pan recomputes

    func testPan_switchesBetweenFallbackAndRequested_withNoStaleState() {
        let requested = Self.etDate(2026, 6, 9, 9, 0)
        let areaWithoutLongCurbs = [sat, tue]
        let areaWithAClearCurb = [sat, clear]
        let first = resolve(areaWithoutLongCurbs, requested: requested)
        XCTAssertTrue(first.isFallback)
        let panned = resolve(areaWithAClearCurb, requested: requested)
        XCTAssertFalse(panned.isFallback, "snaps back to the requested time with no banner")
        XCTAssertEqual(panned.effective, requested)
        let pannedBack = resolve(areaWithoutLongCurbs, requested: requested)
        XCTAssertEqual(pannedBack, first, "recomputed from what is loaded, same answer")
    }

    // MARK: Monotonic + nesting

    func testMonotonic_clearCountNeverRisesAsTheEndMovesLater() {
        let segments = [sat, sun, tue, clear, never]
        var previous = Int.max
        for end in grid {
            let n = ForDaysFallback.clearCount(segments: segments, engine: engine, from: now, until: end)
            XCTAssertLessThanOrEqual(n, previous, "at \(end)")
            previous = n
        }
    }

    func testNesting_laterEndIsASubsetOfAnEarlierEnd() {
        let segments = [sat, sun, tue, clear, never]
        var earlierSet = green(segments, until: grid[0])
        for end in grid.dropFirst() {
            let laterSet = green(segments, until: end)
            XCTAssertTrue(laterSet.isSubset(of: earlierSet), "green(\(end)) must nest in the previous step")
            earlierSet = laterSet
        }
    }

    func testNesting_requestedInEffectiveInOvernight() {
        let segments = [sat, sun, tue, clear, never]
        let overnight = green(segments, until: ParkingGoals.overnightEnd(from: now, morningHour: 7))
        for requested in grid {
            let state = resolve(segments, requested: requested)
            let atRequested = green(segments, until: requested)
            let atEffective = green(segments, until: state.effective)
            XCTAssertTrue(atRequested.isSubset(of: atEffective), "requested \(requested)")
            XCTAssertTrue(atEffective.isSubset(of: overnight), "requested \(requested)")
        }
    }

    func testNesting_forDaysAtTheMinimumEqualsOvernight() {
        let segments = [sat, sun, tue, clear, never]
        let state = resolve(segments, requested: grid[0])
        let overnight = green(segments, until: ParkingGoals.overnightEnd(from: now, morningHour: 7))
        XCTAssertEqual(green(segments, until: state.effective), overnight)
    }

    func testPickedEnd_greenIsExactlyWhatTheEngineSays() {
        let segments = [sat, sun, tue, clear]
        let requested = Self.etDate(2026, 6, 9, 6, 30)
        let state = resolve(segments, requested: requested)
        XCTAssertEqual(state.effective, requested)
        let expected = Set(segments.filter {
            engine.isFree(segment: $0, from: now, until: requested, ignoringMeteredPayment: false)
        }.map(\.id))
        XCTAssertEqual(green(segments, until: state.effective), expected)
        XCTAssertEqual(state.greenCount, expected.count)
    }

    // MARK: Copy strings

    func testBannerCopy_fallback() {
        let state = WPForDaysState(
            requested: Self.etDate(2026, 6, 9, 9, 0), effective: Self.etDate(2026, 6, 7, 20, 0),
            isFallback: true, greenCount: 12, kind: .fallback, thin: false
        )
        XCTAssertEqual(WPForDaysCopy.bannerTitle(requested: state.requested), "Nothing nearby is free until Tue 9\(nbsp)AM.")
        XCTAssertEqual(WPForDaysCopy.bannerDetail(state), "Best nearby: free until Sun 8\(nbsp)PM.")
        XCTAssertEqual(WPForDaysCopy.chip(state), "Best nearby: until Sun 8\(nbsp)PM")
        XCTAssertEqual(
            WPForDaysCopy.bannerSpoken(state),
            "Nothing nearby is free until Tuesday 9\(nbsp)AM. Best nearby: free until Sunday 8\(nbsp)PM."
        )
    }

    func testBannerCopy_thinFallbackAddsOnlyAFewCurbs() {
        var state = WPForDaysState(
            requested: Self.etDate(2026, 6, 9, 9, 0), effective: Self.etDate(2026, 6, 7, 20, 0),
            isFallback: true, greenCount: 2, kind: .fallback, thin: true
        )
        XCTAssertEqual(WPForDaysCopy.bannerDetail(state), "Best nearby: free until Sun 8\(nbsp)PM. Only a few curbs.")
        state.thin = false
        XCTAssertFalse(WPForDaysCopy.bannerDetail(state).contains("Only a few"))
    }

    func testBannerCopy_empty() {
        let state = WPForDaysState(
            requested: Self.etDate(2026, 6, 9, 9, 0), effective: Self.etDate(2026, 6, 5, 7, 0),
            isFallback: false, greenCount: 0, kind: .empty, thin: false
        )
        XCTAssertEqual(WPForDaysCopy.bannerTitle(requested: state.requested), "Nothing nearby is free until Tue 9\(nbsp)AM.")
        XCTAssertEqual(WPForDaysCopy.bannerDetail(state), "No clear curbs found very nearby. Try Overnight, or pan the map.")
        XCTAssertEqual(WPForDaysCopy.chip(state), "No clear curbs nearby")
    }

    func testBannerCopy_noKindMeansNoBanner() {
        let state = WPForDaysState(
            requested: Self.etDate(2026, 6, 9, 9, 0), effective: Self.etDate(2026, 6, 9, 9, 0),
            isFallback: false, greenCount: 5, kind: nil, thin: false
        )
        XCTAssertNil(WPForDaysCopy.chip(state))
        XCTAssertEqual(WPForDaysCopy.bannerDetail(state), "")
    }

    func testRowLabelAndAnnouncement() {
        XCTAssertEqual(WPForDaysCopy.requestRowLabel(isFallback: true), "You asked for:")
        XCTAssertEqual(WPForDaysCopy.requestRowLabel(isFallback: false), "Free until:")
        XCTAssertEqual(
            WPForDaysCopy.announcement(effective: Self.etDate(2026, 6, 8, 17, 0)),
            "Best nearby is now free until Monday 5\(nbsp)PM"
        )
    }

    func testGoalSheetInput_fallback_headlineTileAndBannerShowEffectiveEnd() {
        let requested = Self.etDate(2026, 6, 9, 9, 0)
        let effective = Self.etDate(2026, 6, 7, 20, 0)
        let state = WPForDaysState(
            requested: requested, effective: effective, isFallback: true, greenCount: 12, kind: .fallback, thin: false
        )
        let input = WPGoalSheetInput(
            selectedGoal: .parkAndForget, now: now,
            fewHoursEnd: now.addingTimeInterval(3 * 3600), overnightEnd: Self.etDate(2026, 6, 5, 7, 0),
            forDaysEnd: effective, detailMode: false, loading: false, guardKind: .steppedDown, note: nil,
            morningHour: 7, forDaysPick: requested, forDaysState: state, forDaysClampNote: false
        )
        XCTAssertEqual(input.headlineEnd, "Sun 6/7, 8\(nbsp)PM", "the headline is T*, not the request")
        XCTAssertEqual(input.tileUntil(.parkAndForget), "until Sun 8\(nbsp)PM")
        XCTAssertEqual(input.selectedEnd, effective)
        XCTAssertNotNil(input.forDaysBanner)
        XCTAssertNil(input.factLine, "the legacy full-week guard line never shows for a manual pick")
    }
}
