//
//  StoopPolish2Tests.swift
//  WeParkTests
//
//  Stoop polish batch 2 (flag-on logic only). Pins the PR #206 / #207 QA follow-ups that have
//  testable logic: stale leave-time slots, the pull screen title, the dark-mode ink pill palette,
//  the arrival sheet detents, and the one-line meter wording.
//

import SwiftUI
import XCTest
@testable import WePark

final class StoopPolish2Tests: XCTestCase {

    private func sp2Date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 25; c.hour = h; c.minute = m; c.second = s
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    // MARK: Stale leave-time slots

    func testStillOffered_keepsAFutureSlot() {
        let slots = WPPassLogic.leaveSlots(from: sp2Date(16, 2))
        let pick = slots[2]
        XCTAssertEqual(WPPassLogic.stillOffered(pick, in: slots), pick)
    }

    func testStillOffered_dropsASlotTheClockHasPassed() {
        // The sheet opened at 4:02 and a 4:30 slot was chosen; by 4:31 the recomputed slots start
        // at 4:45, so 4:30 is no longer offered and nothing is "chosen" (no clamped send).
        let pick = sp2Date(16, 30)
        let later = WPPassLogic.leaveSlots(from: sp2Date(16, 31))
        XCTAssertFalse(later.contains(pick))
        XCTAssertNil(WPPassLogic.stillOffered(pick, in: later))
        XCTAssertEqual(later.first, sp2Date(16, 45))
    }

    func testStillOffered_nilStaysNil() {
        XCTAssertNil(WPPassLogic.stillOffered(nil, in: WPPassLogic.leaveSlots(from: sp2Date(16, 2))))
    }

    func testRecomputedSlots_neverContainAPastTime() {
        // Every minute for two hours: no offered slot is ever at or before "now".
        var now = sp2Date(16, 0)
        for _ in 0..<120 {
            XCTAssertTrue(WPPassLogic.leaveSlots(from: now).allSatisfy { $0 > now }, "\(now)")
            now = now.addingTimeInterval(60)
        }
    }

    // MARK: Pull screen title

    func testPullTitle_matchesTheCountdownState() {
        let now = sp2Date(16, 0)
        XCTAssertEqual(WPPassCopy.pullTitle(leaveAt: now.addingTimeInterval(4 * 60), now: now), "Leaving soon")
        XCTAssertEqual(WPPassCopy.pullTitle(leaveAt: now, now: now), "Leaving now")
        XCTAssertEqual(WPPassCopy.pullTitle(leaveAt: now.addingTimeInterval(-30), now: now), "Leaving now")
        XCTAssertEqual(WPPassCopy.pullTitle(leaveAt: nil, now: now), "Leaving now")
        // Never says "Leaving now" while the box still counts down.
        XCTAssertNotEqual(WPPassCopy.pullTitle(leaveAt: now.addingTimeInterval(5), now: now), "Leaving now")
    }

    // MARK: Dark-mode ink pill

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    func testInkPill_inDark_isVisibleOnBothGrounds() {
        let dark = InkPillButtonStyle.Palette.resolve(dark: true)
        // The fill alone is close to the ground, so the pill is the lifted fill PLUS a line; the
        // line must read against both dark grounds (screen and card) and the label against the fill.
        XCTAssertNotEqual(dark.fill, WP.Hex.ink)
        XCTAssertNotNil(dark.outline)
        for ground in [WP.Hex.darkBackground, WP.Hex.darkSurface] {
            XCTAssertGreaterThan(contrast(dark.outline ?? 0, ground), 2.0, "outline vs ground \(String(ground, radix: 16))")
        }
        XCTAssertGreaterThan(contrast(dark.label ?? 0, dark.fill), 4.5, "label on pill")
    }

    func testInkPill_inLight_staysInk() {
        let light = InkPillButtonStyle.Palette.resolve(dark: false)
        XCTAssertEqual(light.fill, WP.Hex.ink)
        XCTAssertNil(light.outline)
        XCTAssertNil(light.label, "light keeps the caller's label color (taxi / white)")
    }

    // MARK: Arrival sheet

    func testArrivalDetents_areFullHeightAtAccessibilitySizes() {
        XCTAssertEqual(WPArrivalPromptV2.detents(accessibilitySize: true), [.large])
        XCTAssertEqual(WPArrivalPromptV2.detents(accessibilitySize: false), [.medium, .large])
    }

    // MARK: Meter wording

    func testGreenMeterLine_neverSaysNoMeter() {
        let side = WPDriveSide(kind: .park, isLeft: true, big: "Park", sub: "No meter running in your window")
        let line = WPDriveVerdict.compactLine(for: side)
        XCTAssertEqual(line, "Park \u{00B7} meter not running")
        XCTAssertFalse(line.lowercased().contains("no meter"))
    }
}
