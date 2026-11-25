//
//  WPVerdictBlock.swift
//  WePark
//
//  Round-2 verdict block (docs/design/wepark-round2/README.md "Verdict block", WPCurbSheet.dc.html):
//  one component, all seven kinds. Radius 24, padding 16 x 18. Over-line 15/500, time 36 to 44/700,
//  sub-line 14/500.
//
//      park     #3CCF7A fill                         (solid = park)
//      soon     3pt dashed #F2A23A outline           (free now, changes soon)
//      dont     3pt dashed #E39A90 outline, over-line #B8322A
//      meter    3pt dotted #5B7CFA outline
//      nodata   2pt solid #A9A7B8 outline
//      planpark park fill + 4pt white / 3pt violet ring (trip plan, not live)
//      plandont dashed coral outline, same as dont
//
//  SPEC CONFLICT (flagged in the PR): README.md and the design-system sheet text say "Soon =
//  #F2A23A fill", but WPCurbSheet.dc.html (`soon` block) and screenshots/b4-soon.png draw a 3pt
//  dashed amber OUTLINE on the white sheet. This follows the part file and the screen, which is
//  also what rule 3 and the five-state curb lines (long-dash amber) imply.
//
//  A verdict is a FACT: flat, never raised. Unsure is never `park`: `WPVerdictKind.kind(for:isPlan:)`
//  maps `.unknown` to `.nodata` (or `.plandont` in a plan) and only `.freeComfortably` to a park kind.
//  Text never truncates: it wraps and the block grows.
//

import SwiftUI

// MARK: - Kind and mapping

/// Which verdict block to draw. Pure value, directly unit-testable.
enum WPVerdictKind: CaseIterable, Equatable {
    case park, soon, dont, meter, nodata, planpark, plandont

    /// Every kind that belongs to a trip plan (carries the "not live" tag, never a live verdict).
    nonisolated var isPlan: Bool { self == .planpark || self == .plandont }

    /// Solid green fill.
    nonisolated var isFilled: Bool { self == .park || self == .planpark }

    /// Outline width, 0 for filled kinds.
    nonisolated var outlineWidth: CGFloat {
        switch self {
        case .park, .planpark: return 0
        case .soon, .dont, .meter, .plandont: return 3
        case .nodata: return 2
        }
    }

    /// Outline color hex (nil for filled kinds).
    nonisolated var outlineHex: UInt32? {
        switch self {
        case .park, .planpark: return nil
        case .soon: return WP.Hex.detailSoon
        case .dont, .plandont: return WP.Hex.noParkLine
        case .meter: return WP.Hex.detailMetered
        case .nodata: return WP.Hex.hairline
        }
    }

    /// Dash pattern: nil = solid, `[0, 6]` + round caps = dotted.
    nonisolated var dash: [CGFloat]? {
        switch self {
        case .soon, .dont, .plandont: return [10, 8]
        case .meter: return [0, 6]
        case .park, .planpark, .nodata: return nil
        }
    }

    /// Interior padding that keeps the content box the same size whatever the outline width.
    nonisolated var padding: (vertical: CGFloat, horizontal: CGFloat) {
        switch self {
        case .park, .planpark: return (16, 18)
        case .soon, .dont, .meter, .plandont: return (13, 15)
        case .nodata: return (14, 16)
        }
    }

    /// Maps the existing parking classifier to a verdict block.
    /// - Never returns a park kind for anything but `.freeComfortably` (never show a spot that
    ///   isn't a spot). In a plan, everything that is not clearly free is `.plandont`.
    nonisolated static func kind(for state: CurrentState, isPlan: Bool) -> WPVerdictKind {
        if isPlan {
            return state == .freeComfortably ? .planpark : .plandont
        }
        switch state {
        case .freeComfortably: return .park
        case .freeButRestrictionSoon: return .soon
        case .meteredActive: return .meter
        case .restrictedNow: return .dont
        case .unknown: return .nodata
        }
    }
}

// MARK: - Block

/// The round-2 verdict block.
struct WPVerdictBlock: View {
    let kind: WPVerdictKind
    /// Over-line, e.g. "Free to stay until".
    let over: String
    /// The time (or a short answer such as "No parking"), 36/700 scaling to 44 for park kinds.
    let big: String
    var sub: String? = nil
    /// Park kinds only: 0...1 portion of the window left (white part of the 10pt bar). Nil hides it.
    var fractionLeft: Double? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
    }

    private var overColor: Color {
        switch kind {
        case .dont, .plandont: return WP.noParkText
        case .nodata: return WP.muted
        case .park, .planpark: return WP.ink
        case .soon, .meter: return WP.text
        }
    }

    private var bodyColor: Color { kind.isFilled ? WP.ink : WP.text }

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s1) {
            Text(over)
                .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                .foregroundStyle(overColor)
            Text(big)
                .font(WP.Font.fredoka(kind.isFilled ? 44 : 36, .bold, relativeTo: .largeTitle))
                .foregroundStyle(bodyColor)
                .fixedSize(horizontal: false, vertical: true)
            if kind.isFilled, let fractionLeft {
                timeLeftBar(fractionLeft)
                    .padding(.vertical, WP.Space.s1)
            }
            if let sub {
                Text(sub)
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                    .foregroundStyle(bodyColor)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, kind.padding.vertical)
        .padding(.horizontal, kind.padding.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(kind.isFilled ? WP.park : Color.clear))
        .overlay(outline)
        .overlay(planRing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var outline: some View {
        if let hex = kind.outlineHex {
            shape.strokeBorder(
                Color(wpHex: hex),
                style: StrokeStyle(
                    lineWidth: kind.outlineWidth,
                    lineCap: kind == .meter ? .round : .butt,
                    dash: kind.dash ?? []
                )
            )
        }
    }

    /// Trip-plan park: 4pt white ring then 3pt violet ring, drawn OUTSIDE the block
    /// (mock `box-shadow: 0 0 0 4px #fff, 0 0 0 7px #6a4cff`).
    @ViewBuilder
    private var planRing: some View {
        if kind == .planpark {
            ZStack {
                shape.inset(by: -2).stroke(Color.white, lineWidth: 4)
                shape.inset(by: -5.5).stroke(WP.plan, lineWidth: 3)
            }
            .allowsHitTesting(false)
        }
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

    private var accessibilityText: String {
        var parts: [String] = []
        if kind.isPlan { parts.append("Trip plan, not live.") }
        parts.append(over)
        parts.append(big)
        if let sub { parts.append(sub) }
        return parts.joined(separator: " ")
    }
}
