//
//  LocationPrimingCard.swift
//  WePark
//
//  DM-3 (`docs/drive-mode-default-spec.md` §0.2) — the one-shot, dismissible first-launch
//  location-priming card for the ambient/goal-first home screen.
//
//  NOT a blocking alert (spec §0.2/§0.1's "Must NOT ... nag" guardrail): this floats above the
//  map as its own card, same visual family as `ParkingGuidePromptBanner`/
//  `SpotPlacementConfirmCard` (`.regularMaterial`, rounded card, floating overlay — not a
//  `.sheet`/`.alert`), so the map stays fully visible and interactive underneath at all times.
//
//  Shown only when `locationService.authorizationStatus == .notDetermined` on the first-ever
//  flag-on home-screen render (`ContentView.locationPrimingCardShouldShow(...)`), and only
//  once ever regardless of the user's choice — persistence is owned by the caller
//  (`LocationPrimingCardGate`, `Services/Constants.swift`), matching `BackgroundNoteGate`'s
//  exact "caller owns the gate, this view is pure presentation" contract.
//
//  "Allow" fires the real system permission prompt (via the caller's
//  `locationService.requestAndFetchLocation()` — this view never talks to CoreLocation
//  directly). "Not now" dismisses with zero side effects. Both buttons are 50pt tall per
//  Kevin's standing bigger-touch-target preference (PR #110 gate) — this card is a one-shot,
//  high-stakes-feeling first impression, not a minor utility control.
//

import SwiftUI

struct LocationPrimingCard: View {

    /// Called when the user taps "Allow". The caller fires the real system prompt
    /// (`requestAndFetchLocation()`) and marks the one-shot gate shown.
    let onAllow: () -> Void

    /// Called when the user taps "Not now". The caller marks the one-shot gate shown with
    /// zero other side effects — no permission request, no map change.
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("See real parking conditions around you")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    Text("Allow location access to show live curb colors right where you are.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(action: onNotNow) {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Not now, don\u{2019}t allow location access")

                Button(action: onAllow) {
                    Text("Allow")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Allow location access")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }
}

// MARK: - Preview

#Preview {
    VStack {
        LocationPrimingCard(onAllow: {}, onNotNow: {})
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
