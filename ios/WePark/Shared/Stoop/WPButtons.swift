//
//  WPButtons.swift
//  WePark
//
//  Design system v0.1 buttons (spec "Parts" > Buttons, "Interactions").
//
//  Rule 2: a hard offset shadow (zero blur) means the piece can be pressed or was earned.
//  Raised press: translate Y by the raise, shadow offset to 0, ~180 ms spring, light haptic.
//  Flat press: the background shifts one step (white -> paper, ink -> #3F3870), no movement.
//  One taxi button per screen.
//

import SwiftUI
import UIKit

// MARK: - Motion / haptics

enum WPMotion {
    /// ~180 ms press/release spring.
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.7)
    /// Switch knob slide, 180 ms.
    static let knob = Animation.easeInOut(duration: 0.18)
    /// Sticker pop-in.
    static let pop = Animation.spring(response: 0.38, dampingFraction: 0.55)
    /// Car token drop (one bounce).
    static let drop = Animation.spring(response: 0.42, dampingFraction: 0.5)
}

enum WPHaptics {
    /// Light impact on touch-down of a raised piece.
    @MainActor static func lightImpact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Raised piece (shared press mechanics)

/// The press mechanics for any raised piece: background + ink border + a hard shadow shape
/// behind it. Pressing translates the piece down by `raise` and drops the shadow to 0.
/// `lift` (goal tile) rests the piece `lift` points above its layout position.
struct WPRaisedPiece<S: InsettableShape, Content: View>: View {
    let shape: S
    let fill: Color
    let border: CGFloat
    let borderColor: Color
    let raise: CGFloat
    var lift: CGFloat = 0
    let isPressed: Bool
    var isEnabled: Bool = true
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let down = isPressed && isEnabled
        let shadowY: CGFloat = (down || !isEnabled) ? 0 : raise
        content()
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(borderColor, lineWidth: border))
            .background(shape.fill(WP.shadow).offset(y: shadowY))
            .offset(y: (down ? raise : 0) - lift)
            // Reserve the raise below the piece so the shadow never overlaps a neighbor.
            .padding(.bottom, raise)
            .padding(.top, lift)
            .animation(reduceMotion ? nil : WPMotion.press, value: down)
            .onChange(of: isPressed) { _, pressed in
                if pressed && isEnabled { WPHaptics.lightImpact() }
            }
    }
}

// MARK: - Raised button (primary 80 / medium 64)

/// Taxi raised button. `.primary`: height 80, 3pt line, raise 6, label 28/700 ("Park here").
/// `.medium`: height 64, 2.5pt line, raise 4, label 20/600. Disabled: #E4E3EC fill,
/// #A9A7B8 line, muted label, no raise.
struct RaisedButtonStyle: ButtonStyle {
    enum Size {
        /// `commitment` is the round-2 full-screen primary (72 tall, raise 6, 24/700).
        case primary, medium, commitment

        var height: CGFloat {
            switch self {
            case .primary: return WP.Control.primaryHeight
            case .medium: return WP.Control.mediumHeight
            case .commitment: return WP.Control.commitmentHeight
            }
        }
        var raise: CGFloat { self == .medium ? WP.Raise.md : WP.Raise.lg }
        var border: CGFloat { self == .medium ? WP.Border.control : WP.Border.raised }
        var font: SwiftUI.Font {
            switch self {
            case .primary: return WP.Font.fredoka(28, .bold, relativeTo: .title)
            case .medium: return WP.Font.fredoka(20, .semibold, relativeTo: .title3)
            case .commitment: return WP.Font.fredoka(24, .bold, relativeTo: .title2)
            }
        }
    }

    var size: Size = .primary
    var fill: Color = WP.taxi

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, size: size, fill: fill)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let size: Size
        let fill: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            WPRaisedPiece(
                shape: Capsule(),
                fill: isEnabled ? fill : Color(wpHex: WP.Hex.divider),
                border: size.border,
                borderColor: isEnabled ? WP.ink : WP.hairline,
                raise: size.raise,
                isPressed: configuration.isPressed,
                isEnabled: isEnabled
            ) {
                configuration.label
                    .font(size.font)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isEnabled ? WP.ink : Color(wpHex: WP.Hex.muted))
                    .padding(.horizontal, WP.Space.s6)
                    .padding(.vertical, WP.Space.s2)
                    .frame(maxWidth: .infinity, minHeight: size.height)
            }
        }
    }
}

// MARK: - Flat styles

/// Shared flat-press body: background steps `fill` -> `pressedFill`; no movement.
private struct WPFlatPiece<S: InsettableShape, Content: View>: View {
    let shape: S
    let fill: Color
    let pressedFill: Color
    let border: CGFloat
    let borderColor: Color
    let isPressed: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(shape.fill(isPressed ? pressedFill : fill))
            .overlay(shape.strokeBorder(borderColor, lineWidth: border))
            .contentShape(shape)
    }
}

/// Ink pill: ink fill, taxi (or white) label 22/600, height 64. Pressed: fill -> #3F3870.
///
/// Dark mode: the ground (and the card) is ink-violet, so an ink fill would vanish into it and
/// leave floating text. In dark the pill is the lifted surface with a line and a cream label (the
/// same treatment `WPMyCarPrimaryStyle` and the selected hour chip already use). `labelColor`
/// applies to light mode only.
struct InkPillButtonStyle: ButtonStyle {
    var labelColor: Color = WP.taxi

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, labelColor: labelColor)
    }

    /// The pill's colors for a scheme. Pure so a test can pin the dark-mode contrast rule.
    nonisolated struct Palette: Equatable {
        let fill: UInt32
        let pressedFill: UInt32
        let disabledFill: UInt32
        /// Outline of the enabled pill (dark only: the fill alone is too close to the ground).
        let outline: UInt32?
        /// nil: use the caller's `labelColor` (light mode).
        let label: UInt32?

        nonisolated static func resolve(dark: Bool) -> Palette {
            dark
                ? Palette(fill: WP.Hex.darkLifted, pressedFill: WP.Hex.darkSurface, disabledFill: WP.Hex.darkSurface,
                          outline: WP.Hex.darkLine, label: WP.Hex.darkText)
                : Palette(fill: WP.Hex.ink, pressedFill: WP.Hex.darkLifted, disabledFill: WP.Hex.divider,
                          outline: nil, label: nil)
        }
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let labelColor: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let dark = scheme == .dark
            let palette = Palette.resolve(dark: dark)
            let label = palette.label.map { Color(wpHex: $0) } ?? labelColor
            WPFlatPiece(
                shape: Capsule(),
                fill: Color(wpHex: isEnabled ? palette.fill : palette.disabledFill),
                pressedFill: Color(wpHex: palette.pressedFill),
                border: (isEnabled && palette.outline == nil) ? 0 : WP.Border.control,
                borderColor: isEnabled ? Color(wpHex: palette.outline ?? WP.Hex.hairline) : (dark ? WP.line : WP.hairline),
                isPressed: configuration.isPressed && isEnabled
            ) {
                configuration.label
                    .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isEnabled ? label : (dark ? WP.muted : Color(wpHex: WP.Hex.muted)))
                    .padding(.horizontal, WP.Space.s6)
                    .padding(.vertical, WP.Space.s2)
                    .frame(maxWidth: .infinity, minHeight: WP.Control.inkPillHeight)
            }
        }
    }
}

/// Secondary: card fill, 2.5pt line, height 56, label 17/600. Pressed: fill -> paper.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            WPFlatPiece(
                shape: Capsule(),
                fill: isEnabled ? WP.card : Color(wpHex: WP.Hex.divider),
                pressedFill: WP.lifted,
                border: WP.Border.control,
                borderColor: isEnabled ? WP.line : WP.hairline,
                isPressed: configuration.isPressed && isEnabled
            ) {
                configuration.label
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isEnabled ? WP.text : Color(wpHex: WP.Hex.muted))
                    .padding(.horizontal, WP.Space.s5)
                    .padding(.vertical, WP.Space.s2)
                    .frame(maxWidth: .infinity, minHeight: WP.Control.secondaryHeight)
            }
        }
    }
}

/// Round: 72pt circle, card fill, 2.5pt line, label 14/600 (Report, Voice).
struct RoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            WPFlatPiece(
                shape: Circle(),
                fill: isEnabled ? WP.card : Color(wpHex: WP.Hex.divider),
                pressedFill: WP.lifted,
                border: WP.Border.control,
                borderColor: isEnabled ? WP.line : WP.hairline,
                isPressed: configuration.isPressed && isEnabled
            ) {
                configuration.label
                    .font(WP.Font.fredoka(14, .semibold, relativeTo: .callout))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isEnabled ? WP.text : Color(wpHex: WP.Hex.muted))
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: WP.Control.roundDiameter, minHeight: WP.Control.roundDiameter)
            }
            .frame(minWidth: WP.Control.roundDiameter, minHeight: WP.Control.roundDiameter)
        }
    }
}

/// Text link: 15/600 underlined, 48pt tall target. Pressed: dims.
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .underline()
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? WP.text : Color(wpHex: WP.Hex.hairline))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .frame(minHeight: WP.Control.textLinkHeight)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == RaisedButtonStyle {
    static var wpPrimary: RaisedButtonStyle { RaisedButtonStyle(size: .primary) }
    static var wpMedium: RaisedButtonStyle { RaisedButtonStyle(size: .medium) }
}
extension ButtonStyle where Self == InkPillButtonStyle {
    static var wpInkPill: InkPillButtonStyle { InkPillButtonStyle() }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var wpSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
extension ButtonStyle where Self == RoundButtonStyle {
    static var wpRound: RoundButtonStyle { RoundButtonStyle() }
}
extension ButtonStyle where Self == TextLinkButtonStyle {
    static var wpTextLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}
