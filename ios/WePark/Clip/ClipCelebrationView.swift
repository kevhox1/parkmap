//
//  ClipCelebrationView.swift
//  WePark Clip
//
//  The payoff (spec 6.1 beat 4, design 7.1, 7.2) and the install ask at peak emotion (beat 5,
//  design 8.1). Karma is PENDING (dashed) until the seeker confirms, then settles. The install card
//  appears ~1.5 s after the celebration lands, once per launch, never before the payoff.
//

import SwiftUI

struct ClipCelebrationView: View {
    @Bindable var controller: ClipFlowController
    var onGetApp: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.clipIsShortScreen) private var isShort
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stamped = false
    @State private var confettiStart = Date()

    private var thanked: Bool { controller.pass?.thanksReceived == true }
    private var name: String { controller.displayName ?? "A neighbor" }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: isShort ? 14 : 22) {
                    stamp
                    Text(thanked ? ClipCopy.thanksHeadline : ClipCopy.passedHeadline)
                        .font(.clipHeadline).foregroundStyle(.white).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(thanked ? ClipCopy.thanksSub(name: name) : ClipCopy.passedSub)
                        .font(.title3).foregroundStyle(SpotPassTheme.lavender).multilineTextAlignment(.center)
                    VStack(spacing: 6) {
                        KarmaChip(label: thanked ? ClipCopy.karmaSettled : ClipCopy.karmaPending,
                                  style: thanked ? .settled : .pending)
                        if !thanked {
                            Text(ClipCopy.karmaPendingCaption).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                        }
                    }
                    SpotPassTextButton(title: ClipCopy.done, minHeight: 56) { controller.dismissCelebration() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, controller.showInstallCard ? 340 : 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            if !reduceMotion && !thanked {
                ConfettiView(start: confettiStart).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if controller.showInstallCard {
                ClipInstallCard(showsLockScreenLine: controller.activitiesEnabled, onGet: onGetApp, onNotNow: { controller.dismissInstallCard() })
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: controller.showInstallCard)
        .task {
            confettiStart = Date()
            if !reduceMotion { withAnimation(.spring(duration: 0.35)) { stamped = true } } else { stamped = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            controller.celebrationLanded()
        }
    }

    private var stamp: some View {
        VStack(spacing: 8) {
            Text("SPOT PASSED")
                .font(.system(.headline, design: .rounded).weight(.heavy)).tracking(2)
                .foregroundStyle(SpotPassTheme.lavender)
            ClipGlyphDisc(glyph: controller.glyph, alias: controller.alias, size: typeSize.isAccessibilitySize ? 64 : 88)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(SpotPassTheme.lavender, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
        .rotationEffect(.degrees(-6))
        .scaleEffect(stamped || reduceMotion ? 1 : 1.25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spot passed")
    }
}

// MARK: - Install card

/// Our own copy; "Get WePark" presents the system SKOverlay (its banner copy cannot be changed, F5).
struct ClipInstallCard: View {
    /// False when Live Activities are off: never promise a lock-screen one-tap that cannot happen.
    var showsLockScreenLine = true
    var onGet: () -> Void
    var onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ClipCopy.installHeadline).font(.title2.bold()).foregroundStyle(.white)
            Text(ClipCopy.installBody).font(.body).foregroundStyle(.white)
            if showsLockScreenLine {
                Text(ClipCopy.installSecondary).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
            }
            Button(ClipCopy.installButton, action: onGet)
                .buttonStyle(ClipHeroButtonStyle(minHeight: SpotPassTheme.heroButtonHeight))
                .accessibilityHint("Opens the App Store")
            HStack { Spacer(); SpotPassTextButton(title: ClipCopy.installNotNow, action: onNotNow); Spacer() }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep your karma. Get WePark to keep your karma and hear when a spot opens near you.")
    }
}

// MARK: - Confetti (1.8 s, then stops; indigo / lavender / white / sky only)

struct ConfettiView: View {
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
