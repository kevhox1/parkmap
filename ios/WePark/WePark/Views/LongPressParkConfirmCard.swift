//
//  LongPressParkConfirmCard.swift
//  WePark
//
//  Open item #17 (2026-09-11, S13c gate): slims the resting long-press popup for
//  `communityEnabled == true`. Kevin: the legacy three-button confirmationDialog is
//  "cluttered and the design doesn't really fit well in the current scheme" — with the
//  S13a Report pill + grid now owning every report entry point, the long-press popup's only
//  remaining job (flag-on) is confirming a park-pin drop, so it slims to Kevin's own
//  suggestion: "should just say confirm parking maybe."
//
//  Visual language matches this file's own confirm-card family rather than the bare
//  system confirmationDialog it replaces — same shape as `SpotPlacementConfirmCard`
//  (`Views/SpotPlacementView.swift`) and `ConfirmPromptCard` (`Views/ConfirmPromptCard.swift`):
//  `.regularMaterial` background, rounded-rect stroke in the community accent color, a
//  Capsule-shaped primary action, a plain secondary Cancel. Single primary action ("Park
//  here") per the spec's own resolution — no crowding, no report entries here anymore.
//
//  Flag-off parity: this view has exactly one call site (`ContentView.longPressParkConfirmOverlay`),
//  itself gated on `AppConstants.communityEnabled` — flag-off never mounts this file at all,
//  and keeps the pre-#17 three-button confirmationDialog byte-identical.
//
//  Copy compliance (mirrors ReportSheet's/SpotPlacementView's AC-R17): no "avoid", "ticket",
//  "fine", "evasion", or "dodge" language anywhere in this file.
//

import SwiftUI

/// A minimal park-confirmation card: "Park here?" + a single primary "Park here" action +
/// a native-styled Cancel. Presentation (positioning, dismiss wiring) is owned by the
/// caller (`ContentView.longPressParkConfirmOverlay`) — this view is purely the card itself,
/// same division of responsibility as `SpotPlacementConfirmCard`.
struct LongPressParkConfirmCard: View {

    /// Called when the user taps "Park here". The caller builds the `PinDropIntent` and
    /// presents `ParkConfirmView` (`ContentView.confirmLongPressPark(at:)`) — this view
    /// never touches segment-search or sheet-presentation state directly.
    let onConfirm: () -> Void

    /// Called when the user taps "Cancel" — dismiss only, no side effects.
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.communityBlue)
                Text("Park here?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                Button(action: onConfirm) {
                    Text("Park here")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Self.communityBlue, in: Capsule())
                .accessibilityLabel("Park here")
                .accessibilityHint("Drops your parked-car pin at this spot")

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Color(white: 0.46).opacity(0.16), in: Capsule())
                .accessibilityLabel("Cancel")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Self.communityBlue.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    /// Community blue `#0A84FF` — palette-sacred per the Community 2.0 spec §6, duplicated
    /// here rather than shared, matching this codebase's established per-file small-color
    /// convention (`SpotPlacementView.swift`'s own `communityBlue` doc comment explains the
    /// same choice).
    private static let communityBlue = Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
}
