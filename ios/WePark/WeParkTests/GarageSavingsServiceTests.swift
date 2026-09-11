//
//  GarageSavingsServiceTests.swift
//  WeParkTests
//
//  Community 2.0 S13c — garage-savings stat (docs/design/community-2.0-final-parity-audit.md
//  §3, Option A). Covers `Services/GarageSavingsService.swift`: accrual math, the ET
//  month-boundary reset (never Calendar.current), and `GarageSavingsCopy.summary`.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge, matching every other
//  Community 2.0 file's posture.
//
//  Uses an ephemeral UserDefaults suite per test (mirrors ParkingGuidePromptGateTests /
//  ReminderOffsetsTests's own convention) so UserDefaults.standard is never polluted.
//
//  Test inventory (14 tests):
//    GarageSavingsServiceAccrualTests (8):
//      1. testCurrentMonthTotal_freshInstall_returnsZero
//      2. testRecordSessionEnded_accruesHoursAtHourlyRate
//      3. testRecordSessionEnded_returnsNewTotal
//      4. testRecordSessionEnded_multipleSessionsSameMonth_accumulate
//      5. testRecordSessionEnded_futureParkedAt_clampsToZeroDuration
//      6. testRecordSessionEnded_zeroDurationSession_accruesNothing
//      7. testCurrentMonthTotal_afterAccrual_matchesReturnedTotal
//      8. testRecordSessionEnded_usesConstantsHourlyRate_notAHardcodedLiteral
//
//    GarageSavingsServiceMonthResetTests (4):
//      9. testEtMonthKey_formatsFourDigitYearTwoDigitMonth
//      10. testEtMonthKey_differsAcrossMonthBoundary
//      11. testCurrentMonthTotal_priorMonthPersistedTotal_returnsZero
//      12. testRecordSessionEnded_priorMonthBaseline_resetsBeforeAccruing_notAdditive
//
//    GarageSavingsCopyTests (2):
//      13. testSummary_roundsToNearestWholeDollar
//      14. testSummary_containsRequiredCopyFragments
//
//  No Calendar.current use (Calendar.easternTime only, per Services/Date+ET.swift).
//  No hardcoded Mapbox/Supabase secrets.
//

import XCTest
@testable import WePark

// MARK: - Accrual

final class GarageSavingsServiceAccrualTests: XCTestCase {

    private let suiteName = "com.wepark.test.garagesavings.accrual"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A fixed reference "now" so every test in this class reasons about the same ET month,
    /// regardless of when the suite actually runs.
    private let fixedNow = Date(timeIntervalSince1970: 1_798_000_000)  // 2026-12-22-ish UTC

    func testCurrentMonthTotal_freshInstall_returnsZero() {
        let service = GarageSavingsService(defaults: defaults)
        XCTAssertEqual(service.currentMonthTotal(now: fixedNow), 0)
    }

    /// 2-hour session × `garageSavingsHourlyRate` ($500/mo ÷ 720h ≈ $0.6944/hr) ≈ $1.39.
    func testRecordSessionEnded_accruesHoursAtHourlyRate() {
        let service = GarageSavingsService(defaults: defaults)
        let parkedAt = fixedNow.addingTimeInterval(-2 * 3600)  // 2 hours ago
        let total = service.recordSessionEnded(parkedAt: parkedAt, now: fixedNow)
        let expected = 2.0 * MoneyMathConstants.garageSavingsHourlyRate
        XCTAssertEqual(total, expected, accuracy: 0.0001)
    }

    func testRecordSessionEnded_returnsNewTotal() {
        let service = GarageSavingsService(defaults: defaults)
        let parkedAt = fixedNow.addingTimeInterval(-3600)
        let returned = service.recordSessionEnded(parkedAt: parkedAt, now: fixedNow)
        XCTAssertEqual(returned, service.currentMonthTotal(now: fixedNow), accuracy: 0.0001,
            "The returned total must match what a subsequent currentMonthTotal() read reports")
    }

    func testRecordSessionEnded_multipleSessionsSameMonth_accumulate() {
        let service = GarageSavingsService(defaults: defaults)
        _ = service.recordSessionEnded(parkedAt: fixedNow.addingTimeInterval(-3600), now: fixedNow)
        let secondNow = fixedNow.addingTimeInterval(3600)  // still same ET month
        let total = service.recordSessionEnded(parkedAt: secondNow.addingTimeInterval(-2 * 3600), now: secondNow)
        let expected = 1.0 * MoneyMathConstants.garageSavingsHourlyRate + 2.0 * MoneyMathConstants.garageSavingsHourlyRate
        XCTAssertEqual(total, expected, accuracy: 0.0001,
            "A second session in the SAME month must accumulate onto the first, not overwrite it")
    }

    /// `parkedAt` in the future (clock skew / malformed car) must clamp to a zero-duration
    /// accrual — never a NEGATIVE delta that could subtract from the running total.
    func testRecordSessionEnded_futureParkedAt_clampsToZeroDuration() {
        let service = GarageSavingsService(defaults: defaults)
        let futureParkedAt = fixedNow.addingTimeInterval(3600)  // 1 hour in the "future"
        let total = service.recordSessionEnded(parkedAt: futureParkedAt, now: fixedNow)
        XCTAssertEqual(total, 0, "A future parkedAt must never produce a negative accrual")
    }

    func testRecordSessionEnded_zeroDurationSession_accruesNothing() {
        let service = GarageSavingsService(defaults: defaults)
        let total = service.recordSessionEnded(parkedAt: fixedNow, now: fixedNow)
        XCTAssertEqual(total, 0)
    }

    func testCurrentMonthTotal_afterAccrual_matchesReturnedTotal() {
        let service = GarageSavingsService(defaults: defaults)
        let parkedAt = fixedNow.addingTimeInterval(-4 * 3600)
        _ = service.recordSessionEnded(parkedAt: parkedAt, now: fixedNow)
        let readBack = service.currentMonthTotal(now: fixedNow)
        XCTAssertEqual(readBack, 4.0 * MoneyMathConstants.garageSavingsHourlyRate, accuracy: 0.0001)
    }

    /// Traceability check (spec §3's "no new, unsourced constant" requirement): the accrual
    /// must use `MoneyMathConstants.garageSavingsHourlyRate`, itself derived from
    /// `garageMonthlyManhattanLow` — not a hardcoded literal that could silently drift from
    /// the Parking 101 figure this stat is supposed to be traceable to.
    func testRecordSessionEnded_usesConstantsHourlyRate_notAHardcodedLiteral() {
        let service = GarageSavingsService(defaults: defaults)
        let total = service.recordSessionEnded(parkedAt: fixedNow.addingTimeInterval(-3600), now: fixedNow)
        XCTAssertEqual(total, MoneyMathConstants.garageSavingsHourlyRate, accuracy: 0.0001)
        // Sanity: the rate itself must be derived from the $500/mo figure, ÷720h.
        XCTAssertEqual(MoneyMathConstants.garageSavingsHourlyRate,
                       MoneyMathConstants.garageMonthlyManhattanLow / 720.0, accuracy: 0.0001)
    }
}

// MARK: - Month-boundary reset (never Calendar.current)

final class GarageSavingsServiceMonthResetTests: XCTestCase {

    private let suiteName = "com.wepark.test.garagesavings.monthreset"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEtMonthKey_formatsFourDigitYearTwoDigitMonth() {
        // 2026-03-19, 08:00 EDT — comfortably inside March in ET too.
        let marchMid = Date(timeIntervalSince1970: 1_773_921_600)
        XCTAssertEqual(GarageSavingsService.etMonthKey(for: marchMid), "2026-03")
    }

    func testEtMonthKey_differsAcrossMonthBoundary() {
        // Well inside two different months — no ET/UTC day-boundary ambiguity risk.
        let januaryMid = Date(timeIntervalSince1970: 1_768_500_000)   // ~2026-01-15
        let februaryMid = Date(timeIntervalSince1970: 1_770_500_000)  // ~2026-02-07
        XCTAssertNotEqual(
            GarageSavingsService.etMonthKey(for: januaryMid),
            GarageSavingsService.etMonthKey(for: februaryMid)
        )
    }

    /// A total persisted under a PRIOR ET month key must read back as 0 this month — the
    /// month rolled over since the last accrual.
    func testCurrentMonthTotal_priorMonthPersistedTotal_returnsZero() {
        let service = GarageSavingsService(defaults: defaults)
        let januaryNow = Date(timeIntervalSince1970: 1_768_500_000)
        _ = service.recordSessionEnded(parkedAt: januaryNow.addingTimeInterval(-3600), now: januaryNow)
        XCTAssertGreaterThan(service.currentMonthTotal(now: januaryNow), 0, "Sanity: January's accrual landed")

        let februaryNow = Date(timeIntervalSince1970: 1_770_500_000)
        XCTAssertEqual(service.currentMonthTotal(now: februaryNow), 0,
            "A February read must not see January's leftover total")
    }

    /// The reset must happen BEFORE the new accrual is added — a session recorded in the new
    /// month must NOT be additive on top of last month's stale total.
    func testRecordSessionEnded_priorMonthBaseline_resetsBeforeAccruing_notAdditive() {
        let service = GarageSavingsService(defaults: defaults)
        let januaryNow = Date(timeIntervalSince1970: 1_768_500_000)
        _ = service.recordSessionEnded(parkedAt: januaryNow.addingTimeInterval(-10 * 3600), now: januaryNow)

        let februaryNow = Date(timeIntervalSince1970: 1_770_500_000)
        let februaryTotal = service.recordSessionEnded(parkedAt: februaryNow.addingTimeInterval(-3600), now: februaryNow)

        XCTAssertEqual(februaryTotal, 1.0 * MoneyMathConstants.garageSavingsHourlyRate, accuracy: 0.0001,
            "February's total must start fresh at 0, not carry January's 10-hour baseline forward")
    }
}

// MARK: - GarageSavingsCopy

final class GarageSavingsCopyTests: XCTestCase {

    func testSummary_roundsToNearestWholeDollar() {
        XCTAssertTrue(GarageSavingsCopy.summary(total: 12.4).hasPrefix("$12 "))
        XCTAssertTrue(GarageSavingsCopy.summary(total: 12.6).hasPrefix("$13 "))
    }

    /// Copy option #3 from the audit (§3): "$X back in your pocket this month — no garage
    /// needed" — checked by fragment (not full-string-verbatim) since Kevin may still adjust
    /// wording at his gate per this session's dispatch instruction; the fragments below are
    /// the parts load-bearing to the stat's MEANING, not just its exact phrasing.
    func testSummary_containsRequiredCopyFragments() {
        let summary = GarageSavingsCopy.summary(total: 42)
        XCTAssertTrue(summary.contains("$42"))
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("this month"))
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("garage"))
    }
}
