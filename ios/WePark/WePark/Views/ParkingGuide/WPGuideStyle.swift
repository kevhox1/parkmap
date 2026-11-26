//
//  WPGuideStyle.swift
//  Views/ParkingGuide
//
//  Stoop Phase 6b (round-2 B16): one place that decides how the Parking 101 copy is drawn. The
//  words live ONCE, in the section views (docs/parking-101-content.md); this file only restyles
//  them. Flag off, every role below reproduces exactly the system styling the guide has always had.
//  Flag on, the same words come out in Fredoka over round-2 cards (white, 1.5 line, radius 20).
//
//  Nothing here adds or rewrites a rule: a card is a frame around existing text.
//

import SwiftUI

/// What a line of guide copy is.
enum WPGuideTextRole {
    /// A sub-heading ("Hydrant 15-foot rule").
    case heading
    /// Ordinary guide copy.
    case body
    /// A bold line inside prose ("Put together: ...").
    case strong
    /// Small print (the money-math source note).
    case caption
    /// A short line beside a sign plate (what the sign allows / does not allow).
    case note
}

struct GuideText: View {
    let text: String
    let role: WPGuideTextRole

    init(_ text: String, _ role: WPGuideTextRole) {
        self.text = text
        self.role = role
    }

    var body: some View {
        if AppConstants.designSystemV2Enabled {
            Text(text)
                .font(Self.stoopFont(role))
                .foregroundStyle(role == .caption ? WP.muted : WP.text)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch role {
            case .heading:
                Text(text).font(.subheadline).fontWeight(.semibold)
            case .body:
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            case .strong:
                Text(text).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
            case .caption, .note:
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func stoopFont(_ role: WPGuideTextRole) -> Font {
        switch role {
        case .heading: return WP.Font.fredoka(20, .semibold, relativeTo: .title3)
        case .body: return WP.Font.fredoka(16, .regular, relativeTo: .body)
        case .strong: return WP.Font.fredoka(16, .semibold, relativeTo: .body)
        case .caption: return WP.Font.fredoka(13, .regular, relativeTo: .caption)
        case .note: return WP.Font.fredoka(15, .regular, relativeTo: .callout)
        }
    }
}

/// A round-2 guide card around one topic. A no-op while the flag is off.
struct WPGuideCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if AppConstants.designSystemV2Enabled {
            let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
            content
                .padding(WP.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(WP.card))
                .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        } else {
            content
        }
    }
}

extension View {
    /// Wraps one guide topic in a Stoop card (flag on); unchanged otherwise.
    func wpGuideCard() -> some View { modifier(WPGuideCardModifier()) }
}
