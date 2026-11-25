//
//  WPTypography.swift
//  WePark
//
//  Fredoka (SIL OFL), four weights, bundled as STATIC instances cut from Google Fonts'
//  variable file (docs/design/fonts/Fredoka-VF.ttf; see docs/design/fonts/README.md). Static
//  instances have distinct PostScript names, so `Font.custom(name, size:, relativeTo:)` scales
//  with Dynamic Type and each weight renders as itself (a variable font would need per-axis
//  descriptor handling that SwiftUI's `.weight()` does not do reliably for custom fonts).
//
//  Registered via UIAppFonts in Info.plist for the app, the App Clip, and both Live Activities
//  extensions. Files live in Shared/Fonts so every target bundles them.
//

import SwiftUI
import UIKit

/// Fredoka weights used by the system (400/500/600/700).
enum WPFontWeight: CaseIterable {
    case regular, medium, semibold, bold

    nonisolated var postScriptName: String {
        switch self {
        case .regular: return "Fredoka-Regular"
        case .medium: return "Fredoka-Medium"
        case .semibold: return "Fredoka-SemiBold"
        case .bold: return "Fredoka-Bold"
        }
    }

    nonisolated var cssWeight: Int {
        switch self {
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        }
    }
}

/// The nine type styles from the spec table.
enum WPTextStyle: CaseIterable {
    case verdict, display, title1, title2, headline, body, callout, caption, label

    nonisolated var size: CGFloat {
        switch self {
        case .verdict: return 68
        case .display: return 44
        case .title1: return 34
        case .title2: return 22
        case .headline: return 18
        case .body: return 16
        case .callout: return 14
        case .caption: return 13
        case .label: return 12
        }
    }

    nonisolated var weight: WPFontWeight {
        switch self {
        case .verdict, .display: return .bold
        case .title1, .title2, .headline, .label: return .semibold
        case .callout: return .medium
        case .body, .caption: return .regular
        }
    }

    /// Spec line height as a multiple of the size.
    nonisolated var lineHeight: CGFloat {
        switch self {
        case .verdict: return 1.0
        case .display: return 1.05
        case .title1: return 1.1
        case .title2: return 1.2
        case .headline: return 1.25
        case .body: return 1.4
        case .callout, .caption: return 1.35
        case .label: return 1.2   // spec gives no value for label; single-line caps
        }
    }

    /// Dynamic Type text style this style scales with.
    nonisolated var relativeTo: Font.TextStyle {
        switch self {
        case .verdict, .display: return .largeTitle
        case .title1: return .title
        case .title2: return .title2
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .caption: return .caption
        case .label: return .caption2
        }
    }

    /// Label is uppercase with 0.08em tracking.
    nonisolated var isCaps: Bool { self == .label }
    nonisolated var tracking: CGFloat { self == .label ? size * 0.08 : 0 }
}

extension WP {
    enum Font {
        /// A Fredoka font at an explicit size/weight that scales with Dynamic Type.
        static func fredoka(
            _ size: CGFloat,
            _ weight: WPFontWeight,
            relativeTo style: SwiftUI.Font.TextStyle
        ) -> SwiftUI.Font {
            .custom(weight.postScriptName, size: size, relativeTo: style)
        }

        static func style(_ style: WPTextStyle) -> SwiftUI.Font {
            fredoka(style.size, style.weight, relativeTo: style.relativeTo)
        }

        static let verdict = style(.verdict)     // drive-mode side verdict only
        static let display = style(.display)
        static let title1 = style(.title1)
        static let title2 = style(.title2)
        static let headline = style(.headline)
        static let body = style(.body)
        static let callout = style(.callout)
        static let caption = style(.caption)
        static let label = style(.label)
    }
}

private struct WPTextModifier: ViewModifier {
    let style: WPTextStyle
    @ScaledMetric private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .font(WP.Font.style(style))
            // Line spacing is the extra leading over the font's natural line height.
            .lineSpacing(max(0, (style.lineHeight - 1.2) * style.size * scale))
            .tracking(style.tracking)
            .textCase(style.isCaps ? .uppercase : nil)
    }
}

extension View {
    /// Applies a design-system type style (font, line height, label caps/tracking).
    func wpText(_ style: WPTextStyle) -> some View {
        modifier(WPTextModifier(style: style))
    }
}
