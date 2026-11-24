//
//  SpotPassWelcomeView.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C2 (spec 6.3, design 8.2): "Tier 1'" — one screen that replaces the 3-card story deck
//  on a clip-origin first launch. Same mechanics as `OnboardingStoryView`: a `.fullScreenCover`, a
//  `.selection` haptic on appear, NEVER a permission request, no progress bar for a single card.
//  "Show me around" and "Skip" both finish it identically (the caller marks the deck seen and
//  schedules the unchanged Tier 2 / Tier 3).
//

import SwiftUI

struct SpotPassWelcomeView: View {
    let content: SpotPassWelcomeContent
    var alias: String?
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var settled = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [SpotPassTheme.inkRaised, SpotPassTheme.ink],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onFinish) {
                        Text(content.skipButton)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel(content.skipButton)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 20) {
                        illustration
                        Text(content.headline)
                            .font(.driverHeadline).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(content.body)
                            .font(.title3).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                        if let chip = content.chipLabel, let style = content.chipStyle {
                            KarmaChip(label: chip, style: style == .settled ? .settled : .pending)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity)
                    // Short, roomy, centered content when it fits; scrolls above the button at AX sizes.
                }
                .scrollBounceBehavior(.basedOnSize)

                Button(action: onFinish) {
                    Text(content.primaryButton)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color(.label), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .accessibilityLabel(content.primaryButton)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .task {
            // `.selection` on appear, like the deck (design 8.2). No permission request here, ever.
            UISelectionFeedbackGenerator().selectionChanged()
            if reduceMotion { settled = true } else { withAnimation(.spring(duration: 0.35)) { settled = true } }
        }
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: content.accessibilityLabel)
        }
    }

    /// The ticket stamp from the celebration, with a dashed curb-line arc behind it (code-drawn).
    private var illustration: some View {
        let height: CGFloat = typeSize.isAccessibilitySize ? 160 : 260
        return ZStack {
            Circle()
                .trim(from: 0.55, to: 0.95)
                .stroke(SpotPassTheme.lavender.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .frame(width: height * 1.2, height: height * 1.2)
                .offset(y: height * 0.35)
            VStack(spacing: 8) {
                Text("SPOT PASSED")
                    .font(.system(.headline, design: .rounded).weight(.heavy)).tracking(2)
                    .foregroundStyle(SpotPassTheme.lavender)
                DriverGlyphDisc(glyph: "", alias: alias ?? "", size: typeSize.isAccessibilitySize ? 56 : 88)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SpotPassTheme.lavender, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
            .rotationEffect(.degrees(-6))
            .scaleEffect(settled || reduceMotion ? 1 : 1.25)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
