//
//  WPCoachTripParts.swift
//  WePark
//
//  Round-2 shared parts for guidance and status (docs/design/wepark-round2/README.md, "Parts added
//  in round 2"): coach card and target ring, trip frame (the tag is `WPTripPlanTag`), the
//  "SPOT PASSED" stamp, the hollow token and the karma sticker.
//
//  Rule 2 in practice: the karma sticker is raised (earned). The stamp and the hollow token are
//  facts ("it ended", "nothing here"), so they are flat and drawn with broken lines.
//

import SwiftUI

// MARK: - Coach card and ring

/// Coach card: card fill, 2.5 line, radius 24, "n of 3", a 20/600 line, a 15/400 line, Skip (text
/// link, 48) and Next (ink pill, 48). No scrim: pair it with `.wpCoachRing` on the target.
struct WPCoachCard: View {
    let step: Int
    var total: Int = 3
    let title: String
    let message: String
    var skipTitle: String = "Skip"
    var nextTitle: String = "Next"
    let onSkip: () -> Void
    let onNext: () -> Void

    nonisolated static func progress(step: Int, total: Int) -> String { "\(step) of \(total)" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: WP.Space.s1) {
            Text(Self.progress(step: step, total: total))
                .font(WP.Font.fredoka(13, .semibold, relativeTo: .caption))
                .foregroundStyle(WP.text)
            Text(title)
                .font(WP.Font.fredoka(20, .semibold, relativeTo: .title3))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(skipTitle, action: onSkip)
                    .buttonStyle(.wpTextLink)
                Spacer(minLength: WP.Space.s3)
                Button(nextTitle, action: onNext)
                    .buttonStyle(WPCoachNextStyle())
            }
            .padding(.top, WP.Space.s2)
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s4)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.control))
        .accessibilityElement(children: .contain)
    }
}

/// Next: ink pill, 48 tall, label 17/600 white (taxi is reserved for the one raised thing).
struct WPCoachNextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
            .foregroundStyle(Color.white)
            .padding(.horizontal, WP.Space.s6)
            .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
            .background(
                shape.fill(configuration.isPressed ? Color(wpHex: WP.Hex.darkLifted) : Color(wpHex: WP.Hex.ink))
            )
            .contentShape(shape)
    }
}

private struct WPCoachRingModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                // 4pt taxi ring just outside the target, 2.5pt ink outline outside that.
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                ZStack {
                    shape.inset(by: -2).stroke(WP.taxi, lineWidth: 4)
                    shape.inset(by: -5.25).stroke(WP.ink, lineWidth: WP.Border.control)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Coach-mark target ring: 4pt taxi with a 2.5pt ink outline, drawn outside the view. No scrim.
    func wpCoachRing(isActive: Bool = true, cornerRadius: CGFloat = WP.Radius.sheet) -> some View {
        modifier(WPCoachRingModifier(isActive: isActive, cornerRadius: cornerRadius))
    }
}

// MARK: - Trip frame

private struct WPTripFrameModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                // 4pt dashed violet frame inset 5 from the screen edge. Decorative.
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .inset(by: WPTripFrame.inset + WPTripFrame.lineWidth / 2)
                    .stroke(WP.plan, style: StrokeStyle(lineWidth: WPTripFrame.lineWidth, dash: [10, 8]))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

enum WPTripFrame {
    nonisolated static let lineWidth: CGFloat = 4
    nonisolated static let inset: CGFloat = 5
}

extension View {
    /// Trip-plan frame: 4pt dashed #6A4CFF, inset 5 from the screen edge. Pair with `WPTripPlanTag`.
    /// While a plan shows there is no "you" dot, car token, goals, Start driving or Park here.
    func wpTripFrame(isActive: Bool = true) -> some View {
        modifier(WPTripFrameModifier(isActive: isActive))
    }
}

// MARK: - Stamp

/// "SPOT PASSED": 2.5pt dashed ink outline, radius 16, 16/700 tracked, rotated -5 degrees.
/// A fact (the pass ended), so it is flat.
struct WPSpotPassedStamp: View {
    var text: String = "SPOT PASSED"

    nonisolated static let rotation: Double = -5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        Text(text)
            .font(WP.Font.fredoka(16, .bold, relativeTo: .callout))
            .tracking(1.6)
            .foregroundStyle(WP.text)
            .multilineTextAlignment(.center)
            // Critical text never truncates: take the height it needs and wrap instead.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, 10)
            .overlay(
                shape.strokeBorder(
                    WP.text,
                    style: StrokeStyle(lineWidth: WP.Border.control, dash: [8, 6])
                )
            )
            .rotationEffect(.degrees(Self.rotation))
            .accessibilityLabel("Spot passed")
    }
}

// MARK: - Hollow token

/// Hollow token: 2.5pt dashed #A9A7B8 circle. Means "nothing here": the pass ended, no parked car.
struct WPHollowToken: View {
    var diameter: CGFloat = WP.Marker.carToken

    var body: some View {
        Circle()
            .strokeBorder(
                WP.hairline,
                style: StrokeStyle(lineWidth: WP.Border.control, dash: [7, 6])
            )
            .frame(width: diameter, height: diameter)
            .accessibilityLabel("Nothing here")
    }
}

// MARK: - Karma sticker

/// Karma sticker: taxi, 2.5 line, raised 3, rotated 6 degrees, "heart +5 karma" 16/700. Earned, so it
/// is raised. Pops in with a spring (instant under Reduce Motion).
struct WPKarmaSticker: View {
    let amount: Int

    nonisolated static let rotation: Double = 6

    nonisolated static func text(for amount: Int) -> String { "+\(amount) karma" }

    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WPRaisedPiece(
            shape: RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous),
            fill: WP.taxi,
            border: WP.Border.control,
            borderColor: WP.ink,
            raise: WP.Raise.sm,
            isPressed: false
        ) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(wpHex: WP.Hex.noParkText))
                    .accessibilityHidden(true)
                Text(Self.text(for: amount))
                    .font(WP.Font.fredoka(16, .bold, relativeTo: .callout))
                    .foregroundStyle(WP.ink)
                    // One line, always ("+5 karma" must not wrap).
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(.horizontal, WP.Space.s3)
            .padding(.vertical, 6)
        }
        .scaleEffect(settled ? 1 : 0.3)
        .rotationEffect(.degrees(settled ? Self.rotation : 0))
        .opacity(settled ? 1 : 0)
        .onAppear {
            if reduceMotion {
                settled = true
            } else {
                withAnimation(WPMotion.pop) { settled = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plus \(amount) karma")
    }
}
