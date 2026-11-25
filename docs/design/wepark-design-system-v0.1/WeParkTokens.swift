// WePark design tokens v0.1 ("Stoop, straight").
// Starting point only: adapt to the codebase's conventions (asset catalog colours, existing style types).
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum WP {
    enum Light {
        static let paper = Color(hex: 0xFBF6E6)
        static let card = Color(hex: 0xFFFFFF)
        static let text = Color(hex: 0x241F45)
        static let muted = Color(hex: 0x5A5578)
        static let line = Color(hex: 0x241F45)
        static let shadow = Color(hex: 0x241F45)
        static let parkText = Color(hex: 0x17803F)
        static let noParkText = Color(hex: 0xB8322A)
        static let divider = Color(hex: 0xE4E3EC)
    }
    enum Dark {
        static let paper = Color(hex: 0x241F45)
        static let card = Color(hex: 0x2E2856)
        static let lifted = Color(hex: 0x3F3870)
        static let text = Color(hex: 0xFBF6E6)
        static let muted = Color(hex: 0xC3BFDC)
        static let line = Color(hex: 0x6B64A0)
        static let shadow = Color(hex: 0x100D24)
        static let parkText = Color(hex: 0x3CCF7A)
        static let noParkText = Color(hex: 0xF5A79D)
    }
    // Same in light and dark. Text on these is always `ink`.
    static let ink = Color(hex: 0x241F45)
    static let taxi = Color(hex: 0xFFD23F)        // press or earned only
    static let park = Color(hex: 0x3CCF7A)        // "you can park" only
    static let noParkLine = Color(hex: 0xE39A90)
    static let hairline = Color(hex: 0xA9A7B8)
    static let plan = Color(hex: 0x6A4CFF)        // trip plan, not live
    static let planStripe = Color(hex: 0x5A3DF0)
    static let detailSoon = Color(hex: 0xF2A23A)
    static let detailMetered = Color(hex: 0x5B7CFA)

    enum Radius {
        static let chip: CGFloat = 16
        static let tile: CGFloat = 20
        static let card: CGFloat = 24
        static let sheet: CGFloat = 30
        static let bubble: CGFloat = 48
    }
    enum Border {
        static let fact: CGFloat = 1.5
        static let control: CGFloat = 2.5
        static let raised: CGFloat = 3
    }
    enum Raise { // hard shadow y-offset, zero blur
        static let sm: CGFloat = 3
        static let md: CGFloat = 4
        static let lg: CGFloat = 6
    }
    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32
        static let screenMargin: CGFloat = 18
    }
    enum Target {
        static let min: CGFloat = 48, standard: CGFloat = 64, drive: CGFloat = 80
    }
    enum CurbLine {
        static let width: CGFloat = 6
        static let dontDash: [CGFloat] = [10, 8]
        static let soonDash: [CGFloat] = [24, 8]
        static let meteredDash: [CGFloat] = [0.1, 11] // round caps = dots
        static let noDataWidth: CGFloat = 2
    }

    // Fredoka weights: Regular 400, Medium 500, SemiBold 600, Bold 700. Bundle the TTFs.
    enum Font {
        static func fredoka(_ size: CGFloat, _ weight: String, relativeTo style: SwiftUI.Font.TextStyle) -> SwiftUI.Font {
            .custom("Fredoka-\(weight)", size: size, relativeTo: style)
        }
        static let verdict = fredoka(68, "Bold", relativeTo: .largeTitle)   // drive mode only
        static let display = fredoka(44, "Bold", relativeTo: .largeTitle)
        static let title1 = fredoka(34, "SemiBold", relativeTo: .title)
        static let title2 = fredoka(22, "SemiBold", relativeTo: .title2)
        static let headline = fredoka(18, "SemiBold", relativeTo: .headline)
        static let body = fredoka(16, "Regular", relativeTo: .body)
        static let callout = fredoka(14, "Medium", relativeTo: .callout)
        static let caption = fredoka(13, "Regular", relativeTo: .caption)
        static let label = fredoka(12, "SemiBold", relativeTo: .caption2)   // caps, tracking 0.96
    }
}

/// Rule 2: raised pieces push down flat when pressed.
struct RaisedButtonStyle: ButtonStyle {
    var fill: Color = WP.taxi
    var raise: CGFloat = WP.Raise.lg
    var border: CGFloat = WP.Border.raised
    var shadow: Color = WP.ink

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        configuration.label
            .foregroundStyle(WP.ink)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(WP.ink, lineWidth: border))
            .background(Capsule().fill(shadow).offset(y: down ? 0 : raise))
            .offset(y: down ? raise : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: down)
    }
}
