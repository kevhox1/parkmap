//
//  WPVerdictBlocks.swift
//  WePark
//
//  Design system v0.1 verdict blocks (spec "Parts" > Verdict blocks; radius 24, padding 16 x 18).
//  Rule 1: verdicts are FACTS, so they are flat (no shadow). Rule 3: line style carries the
//  answer: park = solid green fill, don't = 3pt dashed coral outline, no data = 2pt solid grey
//  outline, trip plan = 4pt dashed violet outline plus the striped "not live" tag.
//
//  Never show a spot that isn't a spot: unsure = drawn as don't (callers map "unknown" to
//  `WPDontVerdict`, not `WPParkVerdict`).
//
//  Verdict text never truncates: it wraps and `fixedSize(vertical:)` lets the block grow.
//

import SwiftUI

private let wpVerdictShape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)

// MARK: - Park

/// Park verdict: green fill, "Free to stay until" 15/500, time 36-44/700, time-left bar
/// (10 tall, white on ink), supporting line 14/500. Text on park is always ink.
struct WPParkVerdict: View {
    var lead: String = "Free to stay until"
    let time: String
    /// 0...1 portion of the window still remaining (the white part of the bar). Nil hides the bar.
    var fractionLeft: Double? = nil
    var support: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            Text(lead)
                .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
            Text(time)
                .font(WP.Font.fredoka(40, .bold, relativeTo: .largeTitle))
                .fixedSize(horizontal: false, vertical: true)
            if let fractionLeft {
                timeLeftBar(fractionLeft)
            }
            if let support {
                Text(support)
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
            }
        }
        .foregroundStyle(WP.ink)
        .padding(.vertical, WP.Space.s4)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wpVerdictShape.fill(WP.park))
        .overlay(wpVerdictShape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }

    private func timeLeftBar(_ fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return Capsule()
            .fill(WP.ink)
            .frame(height: 10)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Don't

/// Don't verdict: 3pt dashed coral outline, "No parking", the reason, and when it frees up.
struct WPDontVerdict: View {
    var title: String = "No parking"
    var reason: String? = nil
    var freesUp: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s1) {
            Text(title)
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.noParkText)
            if let reason {
                Text(reason)
                    .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                    .foregroundStyle(WP.text)
            }
            if let freesUp {
                Text(freesUp)
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, WP.Space.s4)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wpVerdictShape.fill(WP.card))
        .overlay(
            wpVerdictShape.strokeBorder(
                WP.noParkLine,
                style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [10, 8])
            )
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - No data

/// No-data verdict: 2pt solid grey outline, "No sign data", "Read the posted signs...".
struct WPNoDataVerdict: View {
    var title: String = "No sign data"
    var message: String = "Read the posted signs before you park."

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s1) {
            Text(title)
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
            Text(message)
                .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                .foregroundStyle(WP.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, WP.Space.s4)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wpVerdictShape.fill(WP.card))
        .overlay(wpVerdictShape.strokeBorder(WP.hairline, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Trip plan

/// The persistent striped tag. Every trip-plan surface carries it.
struct WPTripPlanTag: View {
    static let text = "TRIP PLAN \u{00B7} NOT LIVE"

    var dates: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.text)
                .wpText(.label)
            if let dates {
                Text(dates)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
            }
        }
        .foregroundStyle(Color.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, WP.Space.s3)
        .padding(.vertical, WP.Space.s2)
        .background(WPStripes(base: WP.plan, stripe: WP.planStripe))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dates.map { "Trip plan, not live. \($0)" } ?? "Trip plan, not live")
    }
}

/// Diagonal stripes (base with a darker stripe every 8pt).
struct WPStripes: View {
    let base: Color
    let stripe: Color
    /// CSS `repeating-linear-gradient(135deg, a 0 10px, b 10px 20px)`: 10pt bands measured across
    /// the stripe, so the horizontal period is 20 x sqrt(2).
    var period: CGFloat = 20 * CGFloat(2).squareRoot()

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            let band = period / 2
            var x = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + band, y: size.height))
                path.addLine(to: CGPoint(x: x + band + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.closeSubpath()
                context.fill(path, with: .color(stripe))
                x += period
            }
        }
        .accessibilityHidden(true)
    }
}

/// Trip plan block: 4pt dashed violet outline with the striped tag. Not live: it never reads as
/// a verdict for right now.
struct WPTripPlanVerdict: View {
    let headline: String
    var detail: String? = nil
    var dates: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            WPTripPlanTag(dates: dates)
            Text(headline)
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
            if let detail {
                Text(detail)
                    .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                    .foregroundStyle(WP.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, WP.Space.s4)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wpVerdictShape.fill(WP.card))
        .overlay(
            wpVerdictShape.strokeBorder(
                WP.plan,
                style: StrokeStyle(lineWidth: 4, lineCap: .butt, dash: [10, 8])
            )
        )
    }
}
