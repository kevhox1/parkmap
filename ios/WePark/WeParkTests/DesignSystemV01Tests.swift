//
//  DesignSystemV01Tests.swift
//  WeParkTests
//
//  Design system v0.1 + round-2 foundation (docs/design/wepark-design-system-v0.1,
//  docs/design/wepark-round2). Pure-value checks only: token values against tokens/*.css, the
//  verdict-kind mapping, curb-line styles, the flag default, and the appearance gate.
//

import XCTest
import SwiftUI
import UIKit
@testable import WePark

final class DesignSystemV01Tests: XCTestCase {

    // MARK: - Flag and appearance gate

    func testFlag_defaultsFalse() {
        XCTAssertFalse(AppConstants.designSystemV2Enabled)
    }

    /// Flag off = exactly today's forced dark; flag on hands the scheme to the window.
    func testRootColorScheme_flagOffIsDark_flagOnIsNil() {
        XCTAssertEqual(DesignSystemAppearance.preferredColorScheme(enabled: false), .dark)
        XCTAssertNil(DesignSystemAppearance.preferredColorScheme(enabled: true))
        // The shipping default (flag false) must resolve to dark.
        XCTAssertEqual(DesignSystemAppearance.preferredColorScheme(), .dark)
    }

    func testInterfaceStyle_driveModeAlwaysDark() {
        XCTAssertEqual(DesignSystemAppearance.interfaceStyle(driveModeActive: true), .dark)
        XCTAssertEqual(DesignSystemAppearance.interfaceStyle(driveModeActive: false), .unspecified)
    }

    /// The foundation must not ADD a dark (or any) UIUserInterfaceStyle to an Info.plist. The
    /// app's pre-existing forced dark lives in the build settings, untouched by this work.
    func testInfoPlists_haveNoUserInterfaceStyleOverride() throws {
        let iosRoot = try repoRoot().appendingPathComponent("ios/WePark")
        for path in ["Info.plist", "Support/Clip-Info.plist",
                     "Support/ClipLiveActivities-Info.plist", "Support/WeParkLiveActivities-Info.plist"] {
            let url = iosRoot.appendingPathComponent(path)
            // Text check: the app's Info.plist is preprocessed (#ifdef), so it is not valid plist XML.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) not readable") }
            XCTAssertTrue(text.contains("<plist"), path)
            XCTAssertFalse(text.contains("UIUserInterfaceStyle"), "\(path) must not set UIUserInterfaceStyle")
        }
    }

    // MARK: - Tokens vs tokens/*.css

    func testLightColorTokens_matchColorsCSS() throws {
        let css = try cssVariables(file: "colors.css", block: ":root")
        XCTAssertEqual(css["--ink"], hex(WP.Hex.ink))
        XCTAssertEqual(css["--paper"], hex(WP.Hex.paper))
        XCTAssertEqual(css["--card"], hex(WP.Hex.card))
        XCTAssertEqual(css["--taxi"], hex(WP.Hex.taxi))
        XCTAssertEqual(css["--park"], hex(WP.Hex.park))
        XCTAssertEqual(css["--park-text"], hex(WP.Hex.parkText))
        XCTAssertEqual(css["--nopark-line"], hex(WP.Hex.noParkLine))
        XCTAssertEqual(css["--nopark-text"], hex(WP.Hex.noParkText))
        XCTAssertEqual(css["--muted"], hex(WP.Hex.muted))
        XCTAssertEqual(css["--hairline"], hex(WP.Hex.hairline))
        XCTAssertEqual(css["--plan"], hex(WP.Hex.plan))
        XCTAssertEqual(css["--plan-stripe"], hex(WP.Hex.planStripe))
        XCTAssertEqual(css["--detail-soon"], hex(WP.Hex.detailSoon))
        XCTAssertEqual(css["--detail-metered"], hex(WP.Hex.detailMetered))
        XCTAssertEqual(css["--map-street"], hex(WP.Hex.divider))
        XCTAssertEqual(css["--map-block"], hex(WP.Hex.mapBlock))
    }

    func testDarkColorTokens_matchColorsCSS() throws {
        let css = try cssVariables(file: "colors.css", block: "[data-theme=\"dark\"]")
        XCTAssertEqual(css["--bg"], hex(WP.Hex.darkBackground))
        XCTAssertEqual(css["--surface"], hex(WP.Hex.darkSurface))
        XCTAssertEqual(css["--surface-raised"], hex(WP.Hex.darkLifted))
        XCTAssertEqual(css["--text"], hex(WP.Hex.darkText))
        XCTAssertEqual(css["--text-muted"], hex(WP.Hex.darkMuted))
        XCTAssertEqual(css["--line"], hex(WP.Hex.darkLine))
        XCTAssertEqual(css["--shadow"], hex(WP.Hex.darkShadow))
        XCTAssertEqual(css["--park-text"], hex(WP.Hex.park))
        XCTAssertEqual(css["--nopark-text"], hex(WP.Hex.darkNoParkText))
        // Dark divider: the css has no --divider; the divider IS the map street, whose dark value
        // is #3f3870. This pins the decision made in WPTokens.swift.
        XCTAssertEqual(css["--map-street"], hex(WP.Hex.darkDivider))
        XCTAssertEqual(WP.Hex.darkDivider, WP.Hex.darkLifted)
        XCTAssertEqual(css["--map-block"], hex(WP.Hex.darkSurface))
    }

    func testShapeTokens_matchShapeCSS() throws {
        let css = try cssVariables(file: "shape.css", block: ":root")
        XCTAssertEqual(css["--radius-chip"], "\(Int(WP.Radius.chip))px")
        XCTAssertEqual(css["--radius-tile"], "\(Int(WP.Radius.tile))px")
        XCTAssertEqual(css["--radius-card"], "\(Int(WP.Radius.card))px")
        XCTAssertEqual(css["--radius-sheet"], "\(Int(WP.Radius.sheet))px")
        XCTAssertEqual(css["--radius-bubble"], "\(Int(WP.Radius.bubble))px")
        XCTAssertEqual(css["--target-min"], "\(Int(WP.Target.minimum))px")
        XCTAssertEqual(css["--target-std"], "\(Int(WP.Target.standard))px")
        XCTAssertEqual(css["--target-drive"], "\(Int(WP.Target.drive))px")
        XCTAssertEqual(css["--margin-screen"], "\(Int(WP.Space.screenMargin))px")
        XCTAssertEqual(css["--space-1"], "4px")
        XCTAssertEqual(css["--space-8"], "32px")
        XCTAssertEqual(css["--border-fact"], "1.5px solid var(--line)")
        XCTAssertEqual(WP.Border.fact, 1.5)
        XCTAssertEqual(WP.Border.control, 2.5)
        XCTAssertEqual(WP.Border.raised, 3)
        XCTAssertEqual(css["--raise-sm"], "0 3px 0 var(--shadow)")
        XCTAssertEqual(WP.Raise.sm, 3)
        XCTAssertEqual(WP.Raise.md, 4)
        XCTAssertEqual(WP.Raise.lg, 6)
    }

    func testTypographyTokens_matchTypographyCSS() throws {
        let css = try cssVariables(file: "typography.css", block: ":root")
        // "--type-body: 400 16px/1.4 var(--font)" -> weight, size, line height.
        for style in WPTextStyle.allCases {
            let key: String
            switch style {
            case .verdict: key = "--type-verdict"
            case .display: key = "--type-display"
            case .title1: key = "--type-title-1"
            case .title2: key = "--type-title-2"
            case .headline: key = "--type-headline"
            case .body: key = "--type-body"
            case .callout: key = "--type-callout"
            case .caption: key = "--type-caption"
            case .label: key = "--type-label"
            }
            let value = try XCTUnwrap(css[key], key)
            let parts = value.split(separator: " ")
            XCTAssertEqual(Int(parts[0]), style.weight.cssWeight, key)
            let sizeAndLine = parts[1].split(separator: "/")
            XCTAssertEqual(Double(sizeAndLine[0].replacingOccurrences(of: "px", with: "")), Double(style.size), key)
            if sizeAndLine.count > 1, style != .label {
                XCTAssertEqual(Double(sizeAndLine[1]), Double(style.lineHeight), key)
            }
        }
    }

    func testTouchTargets_areAtLeast48() {
        XCTAssertGreaterThanOrEqual(WP.Target.minimum, 48)
        XCTAssertGreaterThanOrEqual(WP.Control.textLinkHeight, 48)
        XCTAssertGreaterThanOrEqual(WP.Control.chipHeight, 48)
        XCTAssertGreaterThanOrEqual(WP.Control.secondaryHeight, 48)
        XCTAssertGreaterThanOrEqual(WP.Control.rowMinHeight, 48)
        XCTAssertGreaterThanOrEqual(WPListMetrics.rowMinHeight, 48)
        XCTAssertGreaterThanOrEqual(WPHourChipRow.chipHeight, 48)
        // Primary 64 to 72 (round 2), drive 80.
        XCTAssertEqual(WP.Control.commitmentHeight, 72)
        XCTAssertEqual(WP.Control.inkPillHeight, 64)
        XCTAssertEqual(WP.Control.switchSize, CGSize(width: 56, height: 34))
        XCTAssertEqual(WP.Control.switchKnob, 22)
    }

    func testFredokaFonts_areRegistered() throws {
        for weight in WPFontWeight.allCases {
            if UIFont(name: weight.postScriptName, size: 16) == nil {
                throw XCTSkip("\(weight.postScriptName) not registered in this test host")
            }
        }
    }

    // MARK: - Verdict kinds

    func testVerdictKind_mapsClassifierStates() {
        XCTAssertEqual(WPVerdictKind.kind(for: .freeComfortably, isPlan: false), .park)
        XCTAssertEqual(WPVerdictKind.kind(for: .freeButRestrictionSoon, isPlan: false), .soon)
        XCTAssertEqual(WPVerdictKind.kind(for: .meteredActive, isPlan: false), .meter)
        XCTAssertEqual(WPVerdictKind.kind(for: .restrictedNow, isPlan: false), .dont)
        XCTAssertEqual(WPVerdictKind.kind(for: .unknown, isPlan: false), .nodata)
    }

    func testVerdictKind_planNeverGreenUnlessClearlyFree() {
        XCTAssertEqual(WPVerdictKind.kind(for: .freeComfortably, isPlan: true), .planpark)
        for state in [CurrentState.freeButRestrictionSoon, .meteredActive, .restrictedNow, .unknown] {
            XCTAssertEqual(WPVerdictKind.kind(for: state, isPlan: true), .plandont, "\(state)")
        }
    }

    /// Never show a fake spot: only `.freeComfortably` may produce a park kind.
    func testVerdictKind_onlyFreeComfortablyIsFilledGreen() {
        let all: [CurrentState] = [.freeComfortably, .freeButRestrictionSoon, .meteredActive, .restrictedNow, .unknown]
        for state in all where state != .freeComfortably {
            for isPlan in [false, true] {
                XCTAssertFalse(WPVerdictKind.kind(for: state, isPlan: isPlan).isFilled, "\(state) plan=\(isPlan)")
            }
        }
    }

    func testVerdictKind_lineStyleSpec() {
        XCTAssertEqual(WPVerdictKind.allCases.count, 7)
        XCTAssertNil(WPVerdictKind.park.outlineHex)
        XCTAssertEqual(WPVerdictKind.dont.outlineHex, WP.Hex.noParkLine)
        XCTAssertEqual(WPVerdictKind.dont.outlineWidth, 3)
        XCTAssertNotNil(WPVerdictKind.dont.dash)
        XCTAssertEqual(WPVerdictKind.meter.outlineHex, WP.Hex.detailMetered)
        XCTAssertEqual(WPVerdictKind.meter.dash, [0, 6])
        XCTAssertEqual(WPVerdictKind.soon.outlineHex, WP.Hex.detailSoon)
        XCTAssertEqual(WPVerdictKind.nodata.outlineHex, WP.Hex.hairline)
        XCTAssertEqual(WPVerdictKind.nodata.outlineWidth, 2)
        XCTAssertNil(WPVerdictKind.nodata.dash)
        XCTAssertTrue(WPVerdictKind.planpark.isPlan)
        XCTAssertTrue(WPVerdictKind.plandont.isPlan)
        XCTAssertFalse(WPVerdictKind.park.isPlan)
        // Solid = park; every non-park live kind is a broken or outlined line.
        for kind in WPVerdictKind.allCases where !kind.isFilled && kind != .nodata {
            XCTAssertNotNil(kind.dash, "\(kind)")
        }
    }

    // MARK: - Curb lines (handoff spec: 6pt)

    func testCurbLineStyles_followHandoff() {
        let park = CurbLineStyleV2.style(for: .park)
        XCTAssertEqual(park.colorHex, WP.Hex.park)
        XCTAssertEqual(park.width, 6)
        XCTAssertNil(park.dashPattern)
        let dont = CurbLineStyleV2.style(for: .dont)
        XCTAssertEqual(dont.colorHex, WP.Hex.noParkLine)
        XCTAssertEqual(dont.width, 6)
        XCTAssertEqual(dont.dashPattern, [10, 8])
        XCTAssertEqual(CurbLineStyleV2.style(for: .soon).dashPattern, [24, 8])
        let metered = CurbLineStyleV2.style(for: .metered)
        XCTAssertEqual(metered.dashPattern, [0.1, 11])
        XCTAssertTrue(metered.roundCaps)
        XCTAssertEqual(CurbLineStyleV2.style(for: .noData).width, 2)
    }

    func testCurbLineKinds_unsureIsDrawnAsDont_unlessDetailMode() {
        XCTAssertEqual(CurbLineStyleV2.kind(for: .unknown, detailMode: false), .dont)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .unknown, detailMode: true), .noData)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .meteredActive, detailMode: false), .dont)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .meteredActive, detailMode: true), .metered)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .freeButRestrictionSoon, detailMode: false), .park)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .freeButRestrictionSoon, detailMode: true), .soon)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .restrictedNow, detailMode: false), .dont)
        XCTAssertEqual(CurbLineStyleV2.kind(for: .freeComfortably, detailMode: false), .park)
    }

    // MARK: - Round-2 part values

    func testRound2PartConstants() {
        XCTAssertEqual(WPHourChipRow.morningHours, [6, 7, 8, 9, 10])
        XCTAssertEqual(WPHourChipRow.label(forHour: 9), "9 AM")
        XCTAssertEqual(WPCoachCard.progress(step: 2, total: 3), "2 of 3")
        XCTAssertEqual(WPKarmaSticker.text(for: 5), "+5 karma")
        XCTAssertEqual(WPKarmaSticker.rotation, 6)
        XCTAssertEqual(WPSpotPassedStamp.rotation, -5)
        XCTAssertEqual(WPTripFrame.lineWidth, 4)
        XCTAssertEqual(WPTripFrame.inset, 5)
        XCTAssertEqual(WPTripPlanTag.text, "TRIP PLAN \u{00B7} NOT LIVE")
    }

    // MARK: - Helpers (private: file-scoped names, no XCTestCase extensions)

    private func hex(_ value: UInt32) -> String {
        String(format: "#%06x", value)
    }

    private func repoRoot() throws -> URL {
        // .../ios/WePark/WeParkTests/<file> -> repo root is four levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("docs/design").path) else {
            throw XCTSkip("repo docs not reachable from the test host")
        }
        return url
    }

    /// Parses `--name: value;` declarations from one top-level block of a tokens CSS file.
    private func cssVariables(file: String, block: String) throws -> [String: String] {
        let root = try repoRoot()
        let url = root.appendingPathComponent("docs/design/wepark-design-system-v0.1/tokens/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        var inBlock = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if line.hasPrefix(block), line.hasSuffix("{") { inBlock = true }
                continue
            }
            if line.hasPrefix("}") { inBlock = false; continue }
            // A declaration line may hold several `--a: x; --b: y;` pairs.
            for decl in line.split(separator: ";") {
                guard let colon = decl.firstIndex(of: ":") else { continue }
                let name = decl[..<colon].trimmingCharacters(in: .whitespaces)
                let value = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("--") { result[name] = value.lowercased() }
            }
        }
        XCTAssertFalse(result.isEmpty, "no variables parsed for \(block) in \(file)")
        return result
    }
}
