//
//  PitchSectionView.swift
//  WePark
//
//  FT-12 §3(a): "The Pitch" — why free parking is doable, plus the money math.
//  Content source of truth: docs/parking-101-content.md §(a). Dollar figures come
//  from MoneyMathConstants (Constants.swift) — no inline literals (AC-5).
//
//  Tone: warmer / more encouraging than the rest of the guide (OQ-5) — this section's
//  job is confidence-building. Still no absolutes ("always," "guaranteed," "never").
//

import SwiftUI

struct PitchSectionView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free parking in NYC is a routine, not a gamble.")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text("Alternate-side parking (ASP) means moving your car off one side of the street about twice a week, around a posted window — and it's suspended roughly 40 days a year on holidays and emergencies. That's the whole trick. WePark's color-coded map and reminders do the remembering for you, so you just need to learn the rhythm once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("The money math")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.top, 4)

            Text(moneyMathBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(annualSavingsBody)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text("Figures vary by neighborhood, season, and provider — these are market-data estimates, not official city pricing. Source: SpotAngels and SpotHero NYC monthly-parking listings, pulled 2026-07-09.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Copy assembled from MoneyMathConstants (AC-5: no duplicated literals)

    private var moneyMathBody: String {
        "Manhattan garages commonly run \(currencyRange(MoneyMathConstants.garageMonthlyManhattanLow, MoneyMathConstants.garageMonthlyManhattanHigh))+/month; citywide the average is closer to \(currencyRange(MoneyMathConstants.garageMonthlyCitywideLow, MoneyMathConstants.garageMonthlyCitywideHigh))/month, depending on the neighborhood. Free street parking costs $0, but it takes the habit of moving your car on schedule, and if you miss a window you risk a street-cleaning ticket around \(currency(MoneyMathConstants.streetCleaningTicketCost)) — the same figure WePark's Help & FAQ uses. WePark's reminders exist specifically to keep that from happening."
    }

    private var annualSavingsBody: String {
        "Put together: that's roughly \(currencyRange(MoneyMathConstants.annualSavingsLow, MoneyMathConstants.annualSavingsHigh)) a year back in your pocket if you're willing to learn the rhythm."
    }

    private func currency(_ value: Double) -> String {
        "$\(Int(value))"
    }

    private func currencyRange(_ low: Double, _ high: Double) -> String {
        "$\(Int(low))–\(Int(high))"
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        PitchSectionView()
            .padding()
    }
}
