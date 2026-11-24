//
//  DriverStyle.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C2: the shared look of the full app's driver screens (design sections 1, 3, 7):
//  ink-to-indigo backdrop, rounded headlines, 56/68 pt buttons, the SE (short screen) switch.
//  The App Clip has its own copy of these (`Clip/ClipStyle.swift`, a different target); the two
//  stay visually identical so a driver who installs the app sees the same screens.
//

import SwiftUI

// MARK: - Short screen (iPhone SE class, design 3.2)

private struct DriverShortScreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True under 700 pt tall (iPhone SE): smaller glyph, chips and CTA.
    var driverIsShortScreen: Bool {
        get { self[DriverShortScreenKey.self] }
        set { self[DriverShortScreenKey.self] = newValue }
    }
}

// MARK: - Backdrop

struct DriverBackdrop: View {
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
    static var driverHeadline: Font { .system(.largeTitle, design: .rounded).weight(.bold) }
}

// MARK: - Wordmark

struct DriverWordmark: View {
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
struct DriverHeroButtonStyle: ButtonStyle {
    @Environment(\.driverIsShortScreen) private var isShort
    var minHeight: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(SpotPassTheme.ink)
            .frame(
                maxWidth: .infinity,
                minHeight: minHeight ?? (isShort ? SpotPassTheme.compactHeroButtonHeight : SpotPassTheme.heroButtonHeight)
            )
            .padding(.horizontal, 16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Glyph disc

struct DriverGlyphDisc: View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alias.isEmpty ? "Neighbor" : "\(alias), glyph")
    }
}

// MARK: - Chip

struct DriverChip: View {
    let title: String
    let accessibilityLabel: String
    let isSelected: Bool
    var wide = false
    let action: () -> Void

    @Environment(\.driverIsShortScreen) private var isShort

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected { Image(systemName: "checkmark.circle.fill") }
                Text(title).lineLimit(2).minimumScaleFactor(0.8)
            }
            .font(.headline)
            .foregroundStyle(isSelected ? SpotPassTheme.ink : .white)
            .frame(maxWidth: .infinity, minHeight: isShort ? 52 : SpotPassTheme.buttonHeight)
            .frame(minWidth: 96)
            .background(isSelected ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .layoutPriority(wide ? 1 : 0)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Confetti (1.8 s, then stops; indigo / lavender / white / sky only)

struct DriverConfettiView: View {
    let start: Date
    private static let duration = 1.8
    private static let colors: [Color] = [.indigo, SpotPassTheme.lavender, .white, Color(red: 0x7D / 255, green: 0xB8 / 255, blue: 1)]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                guard t >= 0, t < Self.duration else { return }
                for i in 0..<36 {
                    let seed = Double(i)
                    let x = (sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let drift = (sin(seed * 78.233) * 12345.6789).truncatingRemainder(dividingBy: 1)
                    let startX = abs(x) * size.width
                    let progress = t / Self.duration
                    let px = startX + drift * 60 * progress
                    let py = -20 + progress * (size.height * 0.75) * (0.6 + abs(drift) * 0.6)
                    let rect = CGRect(x: px, y: py, width: 8, height: 12)
                    canvas.opacity = 1 - progress * 0.6
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
        .ignoresSafeArea()
    }
}
