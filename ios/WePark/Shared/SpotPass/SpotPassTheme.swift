//
//  SpotPassTheme.swift
//  Views/SpotPass
//
//  Spot Pass C1: the design tokens (`docs/design/spot-pass-design.md` §1.1, §1.2, §1.3). Every
//  color, size and button style the Spot Pass screens use lives here, so a visual polish pass
//  (restyle, new art) changes this file and the small component views, not the flow logic.
//
//  Palette rule: Spot Pass accent is system indigo. Green, orange, red, yellow, teal, mint, cyan
//  and pink never appear in Spot Pass chrome (green/orange/red mean curb rules in this app).
//  Errors and ended states are neutral gray plus a symbol. Spot Pass surfaces are dark-forced; the
//  QR plate is always opaque white.
//

import SwiftUI

enum SpotPassTheme {

    // MARK: Palette (design §1.1)

    static let ink = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x24 / 255)
    static let inkRaised = Color(red: 0x1B / 255, green: 0x1A / 255, blue: 0x4B / 255)
    static let indigo = Color.indigo
    static let lavender = Color(red: 0xB8 / 255, green: 0xB5 / 255, blue: 0xFF / 255)
    static let paper = Color.white

    /// Card base: ink at the bottom, raised ink at the top.
    static var cardGradient: LinearGradient {
        LinearGradient(colors: [inkRaised, ink], startPoint: .top, endPoint: .bottom)
    }

    /// Screen background behind the card.
    static var screenBackground: some View {
        ink.ignoresSafeArea()
    }

    /// Four tonal gradients for the alias glyph disc (design §10.2). White glyph on each is at
    /// least 4.5:1. No green, teal, orange, red, yellow.
    static func glyphGradient(tintIndex: Int) -> LinearGradient {
        let pairs: [(Color, Color)] = [
            (Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255), Color(red: 0x3F / 255, green: 0x3D / 255, blue: 0xB5 / 255)),  // indigo
            (Color(red: 0x2F / 255, green: 0x6F / 255, blue: 0xD8 / 255), Color(red: 0x1F / 255, green: 0x4F / 255, blue: 0xA8 / 255)),  // blue
            (Color(red: 0x7B / 255, green: 0x52 / 255, blue: 0xD6 / 255), Color(red: 0x56 / 255, green: 0x36 / 255, blue: 0xA8 / 255)),  // purple
            (Color(red: 0x5B / 255, green: 0x6B / 255, blue: 0x9E / 255), Color(red: 0x3E / 255, green: 0x4C / 255, blue: 0x7A / 255))   // slate-blue
        ]
        let pair = pairs[((tintIndex % pairs.count) + pairs.count) % pairs.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Sizes (design §1.3, §2.1)

    /// Hero CTA ("Got it, thanks!", "Create my Spot Pass"). 68 pt (60 on short screens).
    static let heroButtonHeight: CGFloat = 68
    static let compactHeroButtonHeight: CGFloat = 60
    /// Standard primary/secondary buttons. Kevin's rule: roomy.
    static let buttonHeight: CGFloat = 56
    /// Minimum hit area for a text button.
    static let textButtonMinSize: CGFloat = 44
    /// The card on iPhone 17 (12 pt margins).
    static let cardCornerRadius: CGFloat = 36
    static let plateCornerRadius: CGFloat = 20
    /// Screens under this height use the SE layout (design §2.2).
    static let shortScreenHeight: CGFloat = 700
}

// MARK: - Button style

/// One style for every Spot Pass button. `fill` nil = material (secondary).
struct SpotPassButtonStyle: ButtonStyle {

    enum Kind {
        case primary      // indigo fill, white label
        case paper        // white fill, ink label (on dark)
        case secondary    // material fill, neutral label
    }

    var kind: Kind = .primary
    var minHeight: CGFloat = SpotPassTheme.buttonHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, 16)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .paper: return SpotPassTheme.ink
        case .secondary: return .white
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(SpotPassTheme.indigo)
        case .paper: return AnyShapeStyle(SpotPassTheme.paper)
        case .secondary: return AnyShapeStyle(Material.thinMaterial)
        }
    }
}
