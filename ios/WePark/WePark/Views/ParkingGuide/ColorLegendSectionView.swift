//
//  ColorLegendSectionView.swift
//  WePark
//
//  FT-12 §3(c): How WePark's colors map to signs. Content source of truth:
//  docs/parking-101-content.md §(c).
//
//  AC-6: reuses the exact ParkingColors static constants from
//  docs/design/ios-mvp-palette.md §2.2 — no new hardcoded hex/RGB literals. Lists all
//  five states (red, orange, amber-yellow, green, gray), same technique
//  FAQHelpView.mapColorsBlock already uses: color swatch + plain-English label, never
//  color alone (spec §11 colorblindness note).
//

import SwiftUI

struct ColorLegendSectionView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A quick legend tying each map color to the sign that produced it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            legendRow(
                color: ParkingColors.restricted,
                title: "Red",
                description: "A restriction (No Parking / No Standing / No Stopping window, or an ASP window) is active right now."
            )
            legendRow(
                color: ParkingColors.restrictionComingSoon,
                title: "Orange",
                description: "Free right now, but the posted restriction starts within 6 hours. Fine for a quick errand — set a reminder for anything longer."
            )
            legendRow(
                color: ParkingColors.meteredActive,
                title: "Amber-yellow",
                description: "A metered sign, and the meter is currently active. Pay or move."
            )
            legendRow(
                color: ParkingColors.freeComfortably,
                title: "Green",
                description: "Free right now, with nothing posted in the near term."
            )
            legendRow(
                color: ParkingColors.unknown,
                title: "Gray",
                description: "WePark has no data for this block. The sign on the pole is the only truth here."
            )
        }
    }

    private func legendRow(color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) — \(description)")
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        ColorLegendSectionView()
            .padding()
    }
}
