//
//  WPClipParts.swift
//  Shared/Stoop
//
//  Stoop Phase 5b (round-2 B11): the building blocks of the App Clip screens, in the Stoop
//  design system (paper, ink, taxi, Fredoka; flat facts, raised buttons). Pure views: value in,
//  closure out, no controller. Compiled into every target so the full app's DEBUG showcase and
//  the clip render the SAME views; the clip only mounts them behind `StoopFlag.designSystemV2Enabled`.
//
//  SF Rounded is NOT needed: the four Fredoka files (~200 KB) already ship in the clip bundle
//  (Foundation, Info.plist UIAppFonts), so the clip uses the real brand font.
//

import SwiftUI

// MARK: - Header

/// "WePark" + "App Clip" pill, with an optional Back pill on the right (min 48 pt target).
struct WPClipHeader: View {
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(WPClipCopy.appName)
                .font(WP.Font.fredoka(22, .bold, relativeTo: .title2))
                .foregroundStyle(WP.text)
            Text(WPClipCopy.appClipPill)
                .font(WP.Font.fredoka(13, .semibold, relativeTo: .caption))
                .foregroundStyle(WP.text)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.fact))
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            if let onBack {
                Button(action: onBack) {
                    Text(WPClipCopy.back)
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                        .padding(.horizontal, 18)
                        .frame(minHeight: WP.Target.minimum)
                        .background(Capsule().fill(WP.card))
                        .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.fact))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: WP.Target.minimum)
        // Chrome, not content: capped like the bottom bar so "WePark", the pill and Back never break
        // mid-word ("WeP/ark", "Bac/k") at AX sizes. The page below keeps scaling.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Page chrome

/// Scrolling content over paper with a pinned bottom bar. The bar's type is capped so the primary
/// action stays bounded at large Dynamic Type sizes (the content above keeps scaling and scrolls).
struct WPClipPage<Content: View, Bottom: View>: View {
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.s4) {
                WPClipHeader(onBack: onBack)
                content()
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s2)
            .padding(.bottom, WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(WP.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: WP.Space.s1) { bottom() }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s2)
                .padding(.bottom, WP.Space.s2)
                .frame(maxWidth: .infinity)
                .background(WP.paper.ignoresSafeArea(edges: .bottom))
        }
    }
}

// MARK: - Text

struct WPClipHeadline: View {
    let text: String
    var body: some View {
        Text(text)
            .font(WP.Font.fredoka(34, .bold, relativeTo: .title))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WPClipSubline: View {
    let text: String
    var body: some View {
        Text(text)
            .font(WP.Font.fredoka(19, .regular, relativeTo: .title3))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Card

/// A flat fact card: card fill, 1.5 pt line, no shadow.
struct WPClipCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s1) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WP.Space.s4)
            .background(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).fill(WP.card))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }
}

struct WPClipCardText: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                .foregroundStyle(WP.text)
            Text(detail)
                .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Glyph

/// The alias glyph: flat card disc, ink line, SF Symbol in ink. The alias + glyph handshake is the
/// trust device (the seeker's badge shows the same symbol).
struct WPClipGlyph: View {
    let glyph: String
    let alias: String
    var size: CGFloat = 72

    var body: some View {
        Circle()
            .fill(WP.card)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(WP.line, lineWidth: WP.Border.control))
            .overlay {
                Image(systemName: SpotPassGlyph.symbolName(for: glyph))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.text)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(alias.isEmpty ? "Neighbor" : "\(alias), glyph")
    }
}

// MARK: - Buttons

/// The one raised taxi button of a screen (72 pt, raised 6).
struct WPClipPrimaryButton: View {
    let title: String
    var isBusy = false
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBusy { ProgressView().tint(WP.ink) } else { Text(title) }
        }
        .buttonStyle(RaisedButtonStyle(size: .commitment))
        .disabled(isBusy)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }
}

/// "I'm not leaving": plain ink text, 56 pt tall target.
struct WPClipTextButton: View {
    let title: String
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                .foregroundStyle(WP.text)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint ?? "")
    }
}

/// A flat outlined pill button ("5 more min", "Not leaving"). 64 pt tall.
struct WPClipOutlineButton: View {
    let title: String
    var isDisabled = false
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                .multilineTextAlignment(.center)
                .foregroundStyle(isDisabled ? WP.muted : WP.text)
                .frame(maxWidth: .infinity, minHeight: WP.Target.standard)
                .padding(.horizontal, WP.Space.s3)
                .background(Capsule().fill(WP.card))
                .overlay(Capsule().strokeBorder(isDisabled ? WP.hairline : WP.line, lineWidth: WP.Border.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityHint(hint ?? "")
    }
}

// MARK: - Chip

/// A leave-time chip. Selected = taxi with a raised shadow (you pressed it); otherwise a flat card.
struct WPClipChip: View {
    let title: String
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(ChipStyle(isSelected: isSelected))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private struct ChipStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
            WPRaisedPiece(
                shape: shape, fill: isSelected ? WP.taxi : WP.card,
                border: isSelected ? WP.Border.control : WP.Border.fact,
                borderColor: isSelected ? WP.ink : WP.line,
                raise: WP.Raise.sm, isPressed: configuration.isPressed, isEnabled: isSelected
            ) {
                configuration.label
                    .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? WP.ink : WP.text)
                    .padding(.horizontal, WP.Space.s3)
                    .frame(maxWidth: .infinity, minHeight: WP.Target.standard)
            }
            .contentShape(shape)
        }
    }
}

// MARK: - Stamp

/// "SPOT PASSED": a dashed ink stamp, tilted. Earned, so it may sit at a slight angle.
struct WPClipStamp: View {
    var body: some View {
        Text(WPClipCopy.stamp)
            .textCase(.uppercase)
            .font(WP.Font.fredoka(20, .bold, relativeTo: .title3))
            .tracking(1.6)
            .foregroundStyle(WP.text)
            .padding(.horizontal, 22).padding(.vertical, 16)
            .overlay(
                RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
                    .strokeBorder(WP.line, style: StrokeStyle(lineWidth: WP.Border.control, dash: [7, 5]))
            )
            .rotationEffect(.degrees(-6))
            .padding(.vertical, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WPClipCopy.stamp)
    }
}

// MARK: - Install bar (B11.9)

/// The app row at the bottom of the finished screen: icon, name, tagline, "Get". The system install
/// overlay is presented by `onGet` (its copy cannot be changed); this row is our own.
struct WPClipInstallBar: View {
    let onGet: () -> Void

    var body: some View {
        HStack(spacing: WP.Space.s3) {
            WPClipAppIcon().frame(width: 56, height: 56).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(WPClipCopy.appName)
                    .font(WP.Font.fredoka(20, .semibold, relativeTo: .title3))
                    .foregroundStyle(WP.text)
                Text(WPClipCopy.appTagline)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
            }
            Spacer(minLength: 8)
            Button(action: onGet) {
                Text(WPClipCopy.get)
                    .font(WP.Font.fredoka(18, .bold, relativeTo: .headline))
                    .foregroundStyle(WP.taxi)
                    .padding(.horizontal, 22)
                    .frame(minHeight: WP.Target.minimum)
                    .background(Capsule().fill(WP.ink))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Get WePark")
            .accessibilityHint("Opens the App Store")
        }
        .padding(WP.Space.s3)
        .background(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).fill(WP.card))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .contain)
    }
}

/// The app mark (ink square, taxi dot) drawn in code: no image asset to ship in the clip.
struct WPClipAppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(WP.ink)
            .overlay(Circle().fill(WP.taxi).padding(14))
    }
}
