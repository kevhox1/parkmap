//
//  SpotPassComponents.swift
//  Views/SpotPass
//
//  Spot Pass C1: the small reusable pieces (design §11 names: `SpotPassQRView`, `KarmaChip`,
//  `AliasGlyphDisc`). No state, no flow logic.
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
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(chipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(SpotPassTheme.lavender.opacity(0.4), lineWidth: style == .bucket ? 1 : 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style == .bucket ? "Karma: \(label.lowercased())" : label)
    }

    private var chipFill: Color {
        switch style {
        case .bucket: return SpotPassTheme.indigo.opacity(0.25)
        case .settled: return SpotPassTheme.indigo
        }
    }
}

// MARK: - QR plate

/// The branded QR on its opaque white plate. The plate is a bitmap at integer pixel boundaries,
/// shown with `.interpolation(.none)`: no blur, no material, no scale animation, nothing over it
/// (design §1.5). The 4-module quiet zone is inside the bitmap.
struct SpotPassQRView: View {
    let token: String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Screens are 2x or 3x; round so modules stay whole pixels.
        let scale = max(1, displayScale.rounded())
        if let image = SpotPassQRImageCache.image(token: token, scale: scale) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: image.size.width, height: image.size.height)
                .clipShape(RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Spot Pass QR code. Show it to a neighbor who is leaving so they can scan it with their camera.")
                .accessibilityAddTraits(.isImage)
        } else {
            // The token failed validation or the URL exceeded the byte budget: never draw a code
            // that might not decode.
            RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 328, height: 328)
                .overlay {
                    Text("This pass can't be shown. Make a new one.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(24)
                }
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
