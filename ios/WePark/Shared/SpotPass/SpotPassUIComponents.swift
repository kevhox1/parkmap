//
//  SpotPassUIComponents.swift
//  Shared/SpotPass
//
//  The small stateless Spot Pass views shared by the seeker's screens (app), the App Clip, and
//  the Live Activities. Moved here from Views/SpotPass/SpotPassComponents.swift in C3 (no change).
//

import SwiftUI

// MARK: - Alias glyph disc

/// The alias's animal glyph on a tonal gradient disc (design §10.2). The driver sees the same
/// glyph on the clip, so this is the cheapest trust device the feature has.
struct AliasGlyphDisc: View {
    let symbolName: String
    let tintIndex: Int
    var size: CGFloat = 52
    var showsCheckSeal = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(SpotPassTheme.glyphGradient(tintIndex: tintIndex))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            if showsCheckSeal {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundStyle(.white, SpotPassTheme.indigo)
                    .background(Circle().fill(SpotPassTheme.ink).padding(-2))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Karma chip

/// Design §2.4 / §7.5: a capsule with a heart (indigo/lavender, never red) and a label. The badge
/// shows only the BUCKET label ("Helped 10+"); exact counts stay inside the app's own screens.
struct KarmaChip: View {

    enum Style {
        /// Bucket label on the badge (translucent indigo).
        case bucket
        /// Settled receipt ("+3 karma"): solid indigo, white label.
        case settled
        /// Karma that lands when the neighbor says thanks: dashed lavender border, dimmed label (design 7.5).
        case pending
    }

    let label: String
    var style: Style = .bucket
    /// At accessibility sizes the label hides and only the heart shows; VoiceOver keeps the text.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .foregroundStyle(style == .settled ? Color.white : SpotPassTheme.lavender)
            if !compact {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .pending ? Color.white.opacity(0.7) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(chipFill, in: Capsule())
        .overlay {
            switch style {
            case .bucket:
                Capsule().strokeBorder(SpotPassTheme.lavender.opacity(0.4), lineWidth: 1)
            case .pending:
                Capsule().strokeBorder(SpotPassTheme.lavender, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            case .settled:
                EmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style == .bucket ? "Karma: \(label.lowercased())" : label)
    }

    private var chipFill: Color {
        switch style {
        case .bucket: return SpotPassTheme.indigo.opacity(0.25)
        case .settled: return SpotPassTheme.indigo
        case .pending: return Color.clear
        }
    }
}

// MARK: - Screen chrome

/// Shared dark backdrop + dark-forced scheme for every Spot Pass screen.
struct SpotPassBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SpotPassTheme.screenBackground)
            .preferredColorScheme(.dark)
            .tint(SpotPassTheme.indigo)
    }
}

extension View {
    func spotPassBackdrop() -> some View { modifier(SpotPassBackdrop()) }
}

/// A text button with a 44 x 44 minimum hit area (design §1.3).
struct SpotPassTextButton: View {
    let title: String
    var minHeight: CGFloat = SpotPassTheme.textButtonMinSize
    var accessibilityHint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(minWidth: SpotPassTheme.textButtonMinSize, minHeight: minHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint ?? "")
    }
}
