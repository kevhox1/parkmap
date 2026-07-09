//
//  RookieMistakesSectionView.swift
//  WePark
//
//  FT-12 §3(d): Rookie Mistakes / Gotchas. Content source of truth:
//  docs/parking-101-content.md §(d).
//

import SwiftUI

struct RookieMistakesSectionView: View {

    private let mistakes: [String] = [
        "ASP resumes the very next day after a suspension — don't assume a holiday break rolls over.",
        "Check both the day letters and the time window on a sign, not just one.",
        "A lower second plate on the same pole can change everything the top plate says — read the whole stack.",
        "Some meters run different hours than you'd assume. Always check the plate; don't guess from a nearby block.",
        "Standing \"just for a second\" near a hydrant is still a violation.",
        "A green WePark block is a snapshot of right now — recheck if you're staying past the horizon shown.",
        "\"No Parking\" still allows a quick stop to load or unload. It's not a full ban — see the 3-tier ladder above."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(mistakes.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                        .foregroundStyle(ParkingColors.restrictionComingSoon)
                        .padding(.top, 2)
                    Text(mistakes[i])
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        RookieMistakesSectionView()
            .padding()
    }
}
