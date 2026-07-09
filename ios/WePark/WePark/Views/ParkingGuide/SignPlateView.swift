//
//  SignPlateView.swift
//  WePark
//
//  FT-12 (docs/ft12-beginners-manual-spec.md §5, OQ-3): reusable SwiftUI vector
//  replica of a real NYC parking sign plate. Zero bundled raster images — every
//  instance is a data literal (lines + border color + accessibility string) fed
//  into this one component.
//
//  Content-accuracy rule (spec §5): a SignPlateView must ONLY ever render text that
//  appears on a real sign. Real NYC ASP/street-cleaning signs do NOT carry a broom
//  icon — decorative SF Symbols (a broom-style mnemonic, etc.) are allowed next to a
//  *section header*, outside the plate, never on the plate face itself.
//
//  OQ-7 (deliberate): the plate background stays white regardless of Dark Mode — real
//  signs are white/red/black regardless of time of day, and auto-adapting to
//  .systemBackground would make this look like an app card instead of a sign replica.
//  Only the screen chrome around the plate adapts normally.
//

import SwiftUI

// MARK: - SignPlateView

struct SignPlateView: View {

    /// One line of text on the sign plate.
    struct Line: Equatable {
        let text: String
        let weight: Font.Weight
        let color: Color

        init(_ text: String, weight: Font.Weight = .bold, color: Color = .black) {
            self.text = text
            self.weight = weight
            self.color = color
        }
    }

    /// The lines of text rendered on the plate face, top to bottom.
    let lines: [Line]

    /// Border color — typically `.black` for most plates, `.red` for No Standing /
    /// No Stopping emphasis.
    let borderColor: Color

    /// VoiceOver label reading the literal sign text (AC-4). Must be non-empty and
    /// must match the rendered `lines` content — this is what a VoiceOver user hears
    /// in place of "image, sign plate."
    let accessibilityDescription: String

    // MARK: - Body

    var body: some View {
        VStack(spacing: 2) {
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i].text)
                    .font(.system(.headline, design: .default, weight: lines[i].weight))
                    .foregroundStyle(lines[i].color)
                    .multilineTextAlignment(.center)
                    // AC-8: allow the plate to wrap rather than clip at large Dynamic
                    // Type sizes. Capped at accessibility3 per spec §11 — beyond that,
                    // wrapping keeps every word visible instead of silently truncating.
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        // Deliberately NOT .systemBackground — see OQ-7 in the file header.
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 3))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        // Spec §11: the plate's layout caps at .accessibility3 — beyond that, the sign
        // replica would stop resembling a real sign face. The text itself still wraps
        // rather than clipping (fixedSize above); this only bounds further OS-level growth.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        SignPlateView(
            lines: [
                .init("NO PARKING", color: .red),
                .init("8-9:30AM TUES FRI", weight: .semibold),
                .init("STREET CLEANING", weight: .semibold)
            ],
            borderColor: .black,
            accessibilityDescription: "Sign reads: No Parking, 8 to 9:30 AM, Tuesday and Friday, street cleaning"
        )
        SignPlateView(
            lines: [
                .init("NO STANDING", color: .red),
                .init("ANYTIME", weight: .semibold)
            ],
            borderColor: .red,
            accessibilityDescription: "Sign reads: No Standing, anytime"
        )
    }
    .padding()
}
