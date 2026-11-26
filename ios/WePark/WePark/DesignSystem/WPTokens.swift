//
//  WPTokens.swift
//  WePark
//
//  Design system v0.1 ("Stoop, straight") tokens. Source of truth:
//  docs/design/wepark-design-system-v0.1/README.md. Values are copied exactly; the spec's
//  rules are:
//    1. Facts are flat. 2. Raised means press or earned. 3. Line style carries the answer.
//
//  Layout of this file:
//    - `WP.Hex`     raw hex constants (nonisolated, so unit tests can assert them directly)
//    - `WP.*`       adaptive color tokens (light/dark resolved by the trait collection)
//    - `WP.Radius/Border/Raise/Space/Target/CurbLine`  shape + sizing constants
//
//  Nothing in the shipping UI reads these while `AppConstants.designSystemV2Enabled` is false.
//

import SwiftUI
import UIKit

// MARK: - Color helpers

extension UIColor {
    /// sRGB color from a 0xRRGGBB literal. Namespaced name to avoid colliding with any
    /// other hex initializer in the project.
    convenience init(wpHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// sRGB color from a 0xRRGGBB literal.
    init(wpHex hex: UInt32) {
        self.init(uiColor: UIColor(wpHex: hex))
    }

    /// A color that resolves to `light` or `dark` from the current trait collection.
    /// Works with `.preferredColorScheme` and `.environment(\.colorScheme, ...)`.
    static func wpAdaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(wpHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

// MARK: - WP namespace

enum WP {

    // MARK: Raw hex values (spec "Colour" tables)

    enum Hex {
        // Light
        nonisolated static let paper: UInt32 = 0xFBF6E6
        nonisolated static let card: UInt32 = 0xFFFFFF
        nonisolated static let ink: UInt32 = 0x241F45
        nonisolated static let taxi: UInt32 = 0xFFD23F
        nonisolated static let park: UInt32 = 0x3CCF7A
        nonisolated static let parkText: UInt32 = 0x17803F
        nonisolated static let noParkLine: UInt32 = 0xE39A90
        nonisolated static let noParkText: UInt32 = 0xB8322A
        nonisolated static let muted: UInt32 = 0x5A5578
        nonisolated static let hairline: UInt32 = 0xA9A7B8
        nonisolated static let divider: UInt32 = 0xE4E3EC
        nonisolated static let plan: UInt32 = 0x6A4CFF
        nonisolated static let planStripe: UInt32 = 0x5A3DF0
        nonisolated static let detailSoon: UInt32 = 0xF2A23A
        nonisolated static let detailMetered: UInt32 = 0x5B7CFA
        nonisolated static let mapBlock: UInt32 = 0xF5F1E6
        // Dark (drive mode and system dark). Taxi and park are unchanged.
        nonisolated static let darkBackground: UInt32 = 0x241F45
        nonisolated static let darkSurface: UInt32 = 0x2E2856
        nonisolated static let darkLifted: UInt32 = 0x3F3870
        nonisolated static let darkText: UInt32 = 0xFBF6E6
        nonisolated static let darkMuted: UInt32 = 0xC3BFDC
        nonisolated static let darkLine: UInt32 = 0x6B64A0
        nonisolated static let darkShadow: UInt32 = 0x100D24
        nonisolated static let darkNoParkText: UInt32 = 0xF5A79D
        /// Dark row divider / map street (css `--map-street` in dark). Equal to `darkLifted`.
        nonisolated static let darkDivider: UInt32 = 0x3F3870
    }

    // MARK: Adaptive color tokens

    /// Screen background. Light paper, dark ink-violet (dark mode is ink-violet, not black).
    static let paper = Color.wpAdaptive(light: Hex.paper, dark: Hex.darkBackground)
    /// Sheets, cards, rows.
    static let card = Color.wpAdaptive(light: Hex.card, dark: Hex.darkSurface)
    /// One step up from `card` / the pressed state of a flat card. Light: paper. Dark: lifted.
    static let lifted = Color.wpAdaptive(light: Hex.paper, dark: Hex.darkLifted)
    /// Primary text.
    static let text = Color.wpAdaptive(light: Hex.ink, dark: Hex.darkText)
    /// Secondary text.
    static let muted = Color.wpAdaptive(light: Hex.muted, dark: Hex.darkMuted)
    /// Fact / flat-control outline. Light: ink. Dark: line colour.
    static let line = Color.wpAdaptive(light: Hex.ink, dark: Hex.darkLine)
    /// Hard offset shadow under raised pieces. Light: ink. Dark: #100D24.
    static let shadow = Color.wpAdaptive(light: Hex.ink, dark: Hex.darkShadow)
    /// Green text on the surface (park words).
    static let parkText = Color.wpAdaptive(light: Hex.parkText, dark: Hex.park)
    /// Red text and the karma heart.
    static let noParkText = Color.wpAdaptive(light: Hex.noParkText, dark: Hex.darkNoParkText)
    /// Row dividers, off switch, map street. Light: #E4E3EC.
    /// Dark = #3F3870: tokens/colors.css has no dark --divider, but README says divider is also the
    /// "map street" colour and dark `--map-street` is #3F3870, so the same value applies.
    static let divider = Color.wpAdaptive(light: Hex.divider, dark: Hex.darkDivider)

    // Same in light and dark. Text on taxi and on park is always `ink`.
    static let ink = Color(wpHex: Hex.ink)
    static let taxi = Color(wpHex: Hex.taxi)            // things you press or earn only
    static let park = Color(wpHex: Hex.park)            // "you can park" fills and the curb line only
    static let noParkLine = Color(wpHex: Hex.noParkLine)
    static let hairline = Color(wpHex: Hex.hairline)
    static let plan = Color(wpHex: Hex.plan)            // trip plan (not live) only
    static let planStripe = Color(wpHex: Hex.planStripe)
    static let detailSoon = Color(wpHex: Hex.detailSoon)
    static let detailMetered = Color(wpHex: Hex.detailMetered)
    static let mapBlock = Color(wpHex: Hex.mapBlock)

    // MARK: Shape

    enum Radius {
        nonisolated static let chip: CGFloat = 16
        nonisolated static let tile: CGFloat = 20
        nonisolated static let card: CGFloat = 24
        nonisolated static let sheet: CGFloat = 30
        /// Drive side bubble: inner corners only; the outer edge is flush with the screen edge.
        nonisolated static let bubble: CGFloat = 48
        nonisolated static let marker: CGFloat = 14
    }

    enum Border {
        nonisolated static let fact: CGFloat = 1.5
        nonisolated static let control: CGFloat = 2.5
        nonisolated static let raised: CGFloat = 3
    }

    /// Hard shadow y-offset, zero blur.
    enum Raise {
        nonisolated static let sm: CGFloat = 3     // chips, stickers
        nonisolated static let md: CGFloat = 4     // tiles, medium buttons
        nonisolated static let lg: CGFloat = 6     // Park here, large cards
    }

    enum Space {
        nonisolated static let s1: CGFloat = 4
        nonisolated static let s2: CGFloat = 8
        nonisolated static let s3: CGFloat = 12
        nonisolated static let s4: CGFloat = 16
        nonisolated static let s5: CGFloat = 20
        nonisolated static let s6: CGFloat = 24
        nonisolated static let s8: CGFloat = 32
        nonisolated static let screenMargin: CGFloat = 18
        nonisolated static let all: [CGFloat] = [4, 8, 12, 16, 20, 24, 32]
    }

    enum Target {
        nonisolated static let minimum: CGFloat = 48
        nonisolated static let standard: CGFloat = 64
        nonisolated static let driveMin: CGFloat = 72
        nonisolated static let drive: CGFloat = 80
    }

    /// MapKit curb-line constants (spec "Curb lines").
    enum CurbLine {
        nonisolated static let width: CGFloat = 6
        nonisolated static let dontDash: [CGFloat] = [10, 8]
        nonisolated static let soonDash: [CGFloat] = [24, 8]
        /// Round caps turn these near-zero dashes into dots.
        nonisolated static let meteredDash: [CGFloat] = [0.1, 11]
        nonisolated static let noDataWidth: CGFloat = 2
        /// The curb whose sheet is open (b4-free / b4-dont): thicker fill, ink casing around it.
        nonisolated static let selectedWidth: CGFloat = 9
        nonisolated static let selectedCasingWidth: CGFloat = 14
    }

    /// Sizes of the raised/flat control family (spec "Parts").
    enum Control {
        nonisolated static let primaryHeight: CGFloat = 80
        /// Round-2 full-screen commitment button (taxi, raised 6).
        nonisolated static let commitmentHeight: CGFloat = 72
        nonisolated static let mediumHeight: CGFloat = 64
        nonisolated static let inkPillHeight: CGFloat = 64
        nonisolated static let secondaryHeight: CGFloat = 56
        nonisolated static let roundDiameter: CGFloat = 72
        nonisolated static let textLinkHeight: CGFloat = 48
        nonisolated static let goalTileHeight: CGFloat = 76
        nonisolated static let chipHeight: CGFloat = 48
        nonisolated static let rowMinHeight: CGFloat = 60
        nonisolated static let switchSize = CGSize(width: 56, height: 34)
        nonisolated static let switchKnob: CGFloat = 22
        nonisolated static let switchTravel: CGFloat = 23
    }

    /// Map marker sizes (spec "Map markers").
    enum Marker {
        nonisolated static let youDot: CGFloat = 22
        nonisolated static let youRing: CGFloat = 4
        nonisolated static let carToken: CGFloat = 56
        nonisolated static let parkedCar: CGFloat = 40
        nonisolated static let report: CGFloat = 44
    }
}
