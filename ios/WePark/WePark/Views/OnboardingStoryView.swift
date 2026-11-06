//
//  OnboardingStoryView.swift
//  WePark
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §1) — the
//  3 full-screen story cards shown before the live map is ever shown. Presented via
//  `.fullScreenCover`, not `.sheet` (no drag handle — would invite accidental early dismissal
//  before Skip/Continue are read, same reasoning `curb-pin-placement-design.md` §3 gives for
//  not making its own card draggable).
//
//  Pure presentation: every piece of real decision-making (whether to show this at all, what
//  happens on finish/skip — write the one-shot gate or not) lives in `ContentView`, handed down
//  as a single `onFinish` closure fired by EITHER the final card's "Let's go" tap OR the Skip
//  tap from any card. The content/sequencing itself (headline, body, continue label, which card
//  is final) comes from the pure `Models/OnboardingStoryModel.swift`, not improvised here.
//
//  Illustrations are drawn in code with SwiftUI `Path`/`Capsule`/`Circle` shapes using the real
//  `ParkingColors` constants (design doc §1.3) — zero asset pipeline, free Dark Mode
//  correctness, and each one literally foreshadows what the user is about to see on the real
//  map. `ParkingColors.restricted` is used for the "red" cases below — the design doc's own
//  table names this constant `ParkingColors.restrictedNow`, which does not exist in
//  `Services/ParkingColors.swift` (the real severity-spectrum constant for "cannot park right
//  now" is named `restricted`). Flagged here and in the PR description as a naming-only
//  deviation, not a value substitution: same `Color.red`, same semantic meaning, the design
//  doc's cited identifier was simply stale.
//

import SwiftUI

struct OnboardingStoryView: View {

    /// Fired by EITHER the final card's "Let's go" tap OR the Skip tap from any card — both
    /// complete the deck identically from this view's perspective. The caller decides whether
    /// that means "mark the real one-shot gate" (a genuine first-run) or "do nothing to any
    /// gate" (a manual replay from More, §3.2) — this view has no opinion on which.
    let onFinish: () -> Void

    @State private var cardIndex: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground).ignoresSafeArea()
            cardStack
            topBar
        }
        // §1.5: one light selection haptic on every card transition (Continue tap or swipe).
        .sensoryFeedback(.selection, trigger: cardIndex)
    }

    // MARK: - Card container

    /// §1.5 Reduce Motion: the page transition becomes a crossfade, not a slide. `TabView`'s
    /// own `.page` style only ever slides, so Reduce Motion swaps to a plain opacity-crossfade
    /// `ZStack` instead of trying to reconfigure `TabView`'s built-in transition.
    @ViewBuilder
    private var cardStack: some View {
        if reduceMotion {
            ZStack {
                ForEach(OnboardingStoryCard.allCases, id: \.rawValue) { card in
                    cardView(card)
                        .opacity(card.rawValue == cardIndex ? 1 : 0)
                        .allowsHitTesting(card.rawValue == cardIndex)
                }
            }
            .animation(.easeInOut, value: cardIndex)
        } else {
            TabView(selection: $cardIndex) {
                ForEach(OnboardingStoryCard.allCases, id: \.rawValue) { card in
                    cardView(card).tag(card.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func cardView(_ card: OnboardingStoryCard) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 56)
            illustration(for: card)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 160, idealHeight: 260, maxHeight: 320)
                .padding(.horizontal, 24)
                .layoutPriority(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.headline)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(card.body)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            continueButton(for: card)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Illustrations (§1.3) — code-drawn, `ParkingColors`, no assets

    @ViewBuilder
    private func illustration(for card: OnboardingStoryCard) -> some View {
        switch card {
        case .problem: CurbSideSwapIllustration()
        case .ask: GoalGlyphsIllustration()
        case .payoff: DrivingLookTrapezoidIllustration()
        }
    }

    // MARK: - Top bar: progress + Skip (§1.5)

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            progressBar
            Spacer(minLength: 12)
            skipButton
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    /// 3 segmented capsules, 4pt tall, equal width, 6pt gaps. Current/past segments full
    /// `Color(.label)`; future segments `Color(.label).opacity(0.2)`. Instant (no animation)
    /// under Reduce Motion; animates otherwise.
    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStoryCard.allCases, id: \.rawValue) { card in
                Capsule()
                    .fill(card.rawValue <= cardIndex ? Color(.label) : Color(.label).opacity(0.2))
                    .frame(height: 4)
            }
        }
        .animation(reduceMotion ? nil : .default, value: cardIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(cardIndex + 1) of \(OnboardingStoryCard.allCases.count)")
    }

    /// Footnote-weight text on an `.ultraThinMaterial` capsule — the design doc's standing
    /// "material over unpredictable background" rule for every floating control in this app.
    /// 44x44pt minimum tap target even though the visible label is smaller.
    private var skipButton: some View {
        Button(action: { onFinish() }) {
            Text("Skip")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Skip")
        .accessibilityHint("Skips the introduction and goes straight to the live map.")
    }

    // MARK: - Continue / "Let's go" (§1.5)

    /// Full-width capsule, `minHeight: 56`. Monochrome chrome (fill `Color(.label)`, label
    /// `Color(.systemBackground)`) — this screen has nothing to do with curb meaning yet, so no
    /// blue/green/red.
    private func continueButton(for card: OnboardingStoryCard) -> some View {
        Button(action: { advance(from: card) }) {
            Text(card.continueLabel)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(Color(.systemBackground))
                .background(Color(.label), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.continueLabel)
    }

    private func advance(from card: OnboardingStoryCard) {
        if onboardingStoryIsFinalCard(card) {
            onFinish()
        } else if let next = onboardingStoryNextCard(after: card) {
            cardIndex = next.rawValue
        }
    }
}

// MARK: - Illustration 1 (card "problem"): the ASP side-swap, drawn as data

/// Two short curb-line segments side by side — a street's two sides — left
/// `ParkingColors.freeComfortably` (green), right `ParkingColors.restricted` (the design doc
/// calls this constant `restrictedNow`; see this file's header for the naming note), a thin
/// gutter line between them, and two day labels underneath.
private struct CurbSideSwapIllustration: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Capsule().fill(ParkingColors.freeComfortably)
                Rectangle().fill(Color(.separator)).frame(width: 2)
                Capsule().fill(ParkingColors.restricted)
            }
            HStack(spacing: 0) {
                Text("Mon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Text("Tue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        // Decorative — the card's own headline/body already state the idea in words.
        .accessibilityHidden(true)
    }
}

// MARK: - Illustration 2 (card "ask"): three unselected goal glyphs

/// Three plain-outline circles in a row, each holding one of the real goal glyphs at full
/// size — white stroke only, no fill, nothing selected yet, because the story is "you get to
/// pick," not "here's the answer."
private struct GoalGlyphsIllustration: View {
    private let icons = ["moon.stars.fill", "hourglass", "parkingsign.circle.fill"]

    var body: some View {
        HStack(spacing: 20) {
            ForEach(icons, id: \.self) { icon in
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 26))
                            .foregroundStyle(Color.white)
                    )
            }
        }
        .padding(24)
        .accessibilityHidden(true)
    }
}

// MARK: - Illustration 3 (card "payoff"): the driving-look trapezoid

/// A small tilted trapezoid (the driving-look camera framing, Addendum 3 A3.6) containing
/// short curb-line segments, binary green/red only — literally what the live map will look
/// like two taps later.
private struct DrivingLookTrapezoidIllustration: View {
    /// true = free (green), false = restricted (red). 5 segments, alternating.
    private let segmentIsFree: [Bool] = [true, false, true, true, false]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TrapezoidShape()
                    .fill(Color(.systemGray6))
                HStack(spacing: proxy.size.width * 0.02) {
                    ForEach(segmentIsFree.indices, id: \.self) { index in
                        Capsule()
                            .fill(segmentIsFree[index]
                                  ? ParkingColors.freeComfortably
                                  : ParkingColors.restricted)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, proxy.size.width * 0.14)
                .frame(height: proxy.size.height * 0.42)
            }
            .clipShape(TrapezoidShape())
        }
        .padding(24)
        .accessibilityHidden(true)
    }
}

/// A narrower-top, wider-bottom quadrilateral — the tilted, zoomed-in driving-look camera
/// framing (`docs/design/goal-first-ambient-design.md` Addendum 3 A3.6).
private struct TrapezoidShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topInset = rect.width * 0.22
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview {
    OnboardingStoryView(onFinish: {})
}
