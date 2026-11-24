//
//  ClipStyle.swift
//  WePark Clip
//
//  Shared look for the clip screens (design sections 1, 3): ink-to-indigo backdrop, rounded
//  headlines, 56/68 pt buttons, the SE (short screen) switch.
//

import SwiftUI

// MARK: - Short screen (iPhone SE class, design 3.2)

private struct ClipShortScreenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ClipScreenHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 874
}

extension EnvironmentValues {
    /// The clip's full height in points (drives the pinned-CTA cap, `ClipCTAPinning`).
    var clipScreenHeight: CGFloat {
        get { self[ClipScreenHeightKey.self] }
        set { self[ClipScreenHeightKey.self] = newValue }
    }

    /// True under 700 pt tall (iPhone SE): smaller glyph, chips and CTA.
    var clipIsShortScreen: Bool {
        get { self[ClipShortScreenKey.self] }
        set { self[ClipShortScreenKey.self] = newValue }
    }
}

// MARK: - Backdrop

struct ClipBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [SpotPassTheme.ink, SpotPassTheme.indigo.opacity(0.55)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Type

extension Font {
    static var clipHeadline: Font { .system(.largeTitle, design: .rounded).weight(.bold) }
    static var clipHero: Font { .system(.title, design: .rounded).weight(.bold) }
}

// MARK: - Wordmark row

struct ClipWordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "parkingsign.circle.fill")
                .foregroundStyle(SpotPassTheme.lavender)
            Text("WePark")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WePark")
    }
}

// MARK: - Hero button

/// The big white call to action (68 pt, 60 on SE). Grows with Dynamic Type, never truncates.
struct ClipHeroButtonStyle: ButtonStyle {
    @Environment(\.clipIsShortScreen) private var isShort
    var minHeight: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(SpotPassTheme.ink)
            .frame(maxWidth: .infinity, minHeight: minHeight ?? (isShort ? SpotPassTheme.compactHeroButtonHeight : SpotPassTheme.heroButtonHeight))
            .padding(.horizontal, 16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Glyph disc with idle float

struct ClipGlyphDisc: View {
    let glyph: String
    let alias: String
    var size: CGFloat = 96
    var showsSeal = false
    var floats = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        AliasGlyphDisc(
            symbolName: SpotPassGlyph.symbolName(for: glyph),
            tintIndex: SpotPassGlyph.tintIndex(forAlias: alias),
            size: size, showsCheckSeal: showsSeal
        )
        .shadow(color: SpotPassTheme.lavender.opacity(0.35), radius: 18)
        .offset(y: floats && !reduceMotion ? (up ? -4 : 4) : 0)
        .onAppear {
            guard floats, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { up = true }
        }
        // Decorative-with-name (design 3.10).
        .accessibilityHidden(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alias.isEmpty ? "Neighbor" : "\(alias), glyph")
    }
}
