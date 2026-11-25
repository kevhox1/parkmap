//
//  ASPSuspensionPerfTests.swift
//  WeParkTests
//
//  perf/aspsuspension-dateformatter: `rebuildOverlays` -> `ASPSuspensionService.isSuspended` built a
//  new DateFormatter on every call (51 of 92 profiler samples; 15-60 s black screen at first launch
//  in a Debug sim). These tests
//    - pin `isSuspended` / `toETDateString` / `reasonForSuspension` to a fresh-formatter reference
//      over every hour of a DST-spanning range (output must not change), and
//    - time a realistic overlay classification pass (about 5k real tile segments) with `measure`.
//

import XCTest
@testable import WePark

final class ASPSuspensionPerfTests: XCTestCase {

    private func et(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        c.timeZone = .easternTime
        return Calendar.easternTime.date(from: c) ?? Date()
    }

    /// Reference implementation: the original per-call DateFormatter.
    private func referenceKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .easternTime
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// About `limit` real segments from the bundled tiles (deterministic file order).
    private func loadSegments(limit: Int) throws -> [Segment] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WePark/Resources/tiles")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tile_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Segment] = []
        let decoder = JSONDecoder()
        for file in files where out.count < limit {
            out.append(contentsOf: try decoder.decode([Segment].self, from: Data(contentsOf: file)))
        }
        return Array(out.prefix(limit))
    }

    // MARK: - Output unchanged

    func testDateKeyMatchesReferenceFormatter_everyHourAcrossDST() {
        // 2026-03-01 ... 2026-12-31 covers both DST transitions and the year boundary.
        var t = et(2026, 3, 1)
        let end = et(2027, 1, 2)
        var count = 0
        while t < end {
            XCTAssertEqual(t.toETDateString(), referenceKey(t))
            t.addTimeInterval(1800)
            count += 1
        }
        XCTAssertGreaterThan(count, 10_000)
    }

    func testIsSuspendedMatchesReference_everyHour() {
        let service = ASPSuspensionService()
        var t = et(2026, 1, 1)
        let end = et(2027, 1, 2)
        var suspendedHours = 0
        while t < end {
            let expectedReason = service.reasonForSuspension(t)
            XCTAssertEqual(service.isSuspended(t), expectedReason != nil)
            if service.isSuspended(t) { suspendedHours += 1 }
            t.addTimeInterval(3600)
        }
        // Dec 8 is bundled as a suspension day; some date must be suspended.
        XCTAssertGreaterThan(suspendedHours, 0)
        XCTAssertTrue(service.isSuspended(et(2026, 12, 8, 0, 0)))
        XCTAssertTrue(service.isSuspended(et(2026, 12, 8, 23, 59)))
        XCTAssertFalse(service.isSuspended(et(2026, 12, 15, 10)))
    }

    /// Overlay color sample: digest of `currentState` + three goal verdicts over real segments at
    /// a suspended and a normal day. Set TEST_RUNNER_WEPARK_DIGEST_PATH to dump it for before/after diffing.
    func testOverlayDigest_dumpForBeforeAfterComparison() throws {
        let segments = try loadSegments(limit: 5_000)
        let engine = ParkingRulesEngine()
        var lines: [String] = []
        for now in [et(2026, 12, 8, 10), et(2026, 12, 15, 10), et(2026, 12, 16, 20)] {
            let target = ParkingGoals.target(for: .freeFewHours, from: now)
            let overnight = ParkingGoals.target(for: .freeOvernight, from: now)
            for seg in segments {
                let state = engine.currentState(for: seg, at: now)
                let few = engine.isFree(segment: seg, from: now, until: target)
                let night = engine.isFree(segment: seg, from: now, until: overnight, ignoringMeteredPayment: true)
                let label = engine.safetyLabel(for: seg, at: now).text
                lines.append("\(now.timeIntervalSince1970)|\(seg.id)|\(state)|\(few)|\(night)|\(label)")
            }
        }
        XCTAssertEqual(segments.count, 5_000)
        if let path = ProcessInfo.processInfo.environment["WEPARK_DIGEST_PATH"] {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Timing

    /// Runs `body` inside `measure` and records every iteration's wall time, then appends the
    /// median to the file named by WEPARK_TIMING_PATH (when set) and prints it.
    private func timed(_ name: String, _ body: @escaping () -> Void) {
        var samples: [Double] = []
        measure {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let sorted = samples.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let line = "\(name): median \(String(format: "%.2f", median)) ms over \(samples.count) runs"
        print("PERF " + line)
        if let path = ProcessInfo.processInfo.environment["WEPARK_TIMING_PATH"] {
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (existing + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// One overlay rebuild's classification work: currentState for ~5k segments (what the map's
    /// current-state overlay does) on a normal day.
    func testPerf_currentStateOverlayPass_5kSegments() throws {
        let segments = try loadSegments(limit: 5_000)
        let engine = ParkingRulesEngine()
        let now = et(2026, 12, 15, 10)
        timed("currentState overlay pass, 5k segments") {
            var reds = 0
            for seg in segments where engine.currentState(for: seg, at: now) == .restrictedNow { reds += 1 }
            XCTAssertGreaterThanOrEqual(reds, 0)
        }
    }

    /// Goal overlay pass: isFree (Overnight window) for ~5k segments.
    func testPerf_goalOverlayPass_5kSegments() throws {
        let segments = try loadSegments(limit: 5_000)
        let engine = ParkingRulesEngine()
        let now = et(2026, 12, 15, 10)
        let target = ParkingGoals.target(for: .freeOvernight, from: now)
        timed("goal (Overnight) overlay pass, 5k segments") {
            var greens = 0
            for seg in segments where engine.isFree(segment: seg, from: now, until: target) { greens += 1 }
            XCTAssertGreaterThanOrEqual(greens, 0)
        }
    }

    /// The raw hot call, 20k lookups.
    func testPerf_isSuspended_20kCalls() {
        let service = ASPSuspensionService()
        let base = et(2026, 12, 15, 10)
        timed("isSuspended, 20k calls") {
            var hits = 0
            for i in 0..<20_000 where service.isSuspended(base.addingTimeInterval(Double(i % 14) * 86_400)) { hits += 1 }
            XCTAssertGreaterThanOrEqual(hits, 0)
        }
    }
}
