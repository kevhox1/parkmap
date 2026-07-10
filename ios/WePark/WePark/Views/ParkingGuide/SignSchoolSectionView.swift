//
//  SignSchoolSectionView.swift
//  WePark
//
//  FT-12 §3(b): Sign-Reading School — the common sign types, each paired with one or
//  more SignPlateView replicas. Content source of truth: docs/parking-101-content.md §(b).
//
//  Content-accuracy rule (spec §5): every SignPlateView instance below renders ONLY
//  text that appears on a real sign. Decorative SF Symbols (e.g. the broom icon) are
//  used only on sub-section headers, never on the plate faces themselves.
//

import SwiftUI

struct SignSchoolSectionView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            aspSubsection
            restrictionLadderSubsection
            meteredSubsection
            hydrantSubsection
            arrowsSubsection
            combinedStacksSubsection
        }
    }

    // MARK: - ASP / Street cleaning

    private var aspSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("ASP / Street cleaning signs")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            } icon: {
                // Decorative mnemonic only — outside the plate face (spec §5).
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }

            Text("A real plate reads something like the one below. There's no broom icon on the actual sign — just the restriction, the days, and the window. Outside that window, or on a suspended day, you're free to park there.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SignPlateView(
                lines: [
                    .init("NO PARKING", color: .red),
                    .init("8-9:30AM TUES FRI", weight: .semibold),
                    .init("STREET CLEANING", weight: .semibold)
                ],
                borderColor: .black,
                accessibilityDescription: "Sign reads: No Parking, 8 to 9:30 AM, Tuesday and Friday, street cleaning"
            )
        }
    }

    // MARK: - 3-tier restriction ladder

    private var restrictionLadderSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The 3-tier restriction ladder")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("The single most-misunderstood distinction for new drivers — and the actual legal test between the first two tiers is what you're allowed to load: No Parking permits passengers or merchandise; No Standing permits passengers only, never cargo. That's the real difference, not whether the driver stays in the car.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ladderRow(
                    plate: SignPlateView(
                        lines: [.init("NO PARKING", color: .red)],
                        borderColor: .black,
                        accessibilityDescription: "Sign reads: No Parking"
                    ),
                    allowed: "Stop to actively load or unload passengers or merchandise",
                    notAllowed: "Leave the car parked, or idle with no active loading/unloading happening"
                )
                ladderRow(
                    plate: SignPlateView(
                        lines: [.init("NO STANDING", color: .red)],
                        borderColor: .red,
                        accessibilityDescription: "Sign reads: No Standing"
                    ),
                    allowed: "Stop to actively pick up or drop off passengers only — no merchandise",
                    notAllowed: "Load or unload cargo, or remain in the car for any other reason"
                )
                ladderRow(
                    plate: SignPlateView(
                        lines: [.init("NO STOPPING", color: .red)],
                        borderColor: .red,
                        accessibilityDescription: "Sign reads: No Stopping"
                    ),
                    allowed: "Nothing, except to obey a traffic signal, sign, or a police officer",
                    notAllowed: "Stop for any other reason, not even to drop someone off"
                )
            }
        }
    }

    private func ladderRow(plate: SignPlateView, allowed: String, notAllowed: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            plate
                .frame(width: 120)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(ParkingColors.freeComfortably)
                    Text(allowed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(ParkingColors.restricted)
                    Text(notAllowed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Metered / Muni-Meter

    private var meteredSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metered / Muni-Meter signs")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Pay during the posted hours. Outside them, and on major legal holidays, parking there is free.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SignPlateView(
                lines: [
                    .init("PAY TO PARK", color: .black),
                    .init("8AM-7PM", weight: .semibold)
                ],
                borderColor: .black,
                accessibilityDescription: "Sign reads: Pay to Park, 8 AM to 7 PM"
            )
        }
    }

    // MARK: - Hydrant 15-foot rule (no sign posted)

    private var hydrantSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Hydrant 15-foot rule")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "drop")
                    .foregroundStyle(.secondary)
            }

            Text("No sign is posted for this one — it's a universal NYC rule. Stay at least 15 feet from a hydrant on either side, roughly a car length. Standing there \"just for a second\" still counts as a violation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Arrows and side-of-street semantics

    private var arrowsSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Arrows and side-of-street semantics")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("A sign with an arrow applies in the direction the arrow points, up to the next sign or the corner — not the whole block, and only on that side of the street.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SignPlateView(
                lines: [
                    .init("NO PARKING", color: .red),
                    .init("8-9:30AM TUES FRI", weight: .semibold),
                    .init("\u{2190}", weight: .bold)
                ],
                borderColor: .black,
                accessibilityDescription: "Sign reads: No Parking, 8 to 9:30 AM, Tuesday and Friday, with a left-pointing arrow"
            )
        }
    }

    // MARK: - Combined sign stacks

    private var combinedStacksSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Combined sign stacks")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Multiple plates on one pole means all of the rules apply at the same time. Read top to bottom, and the most restrictive rule in effect at a given moment wins.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                SignPlateView(
                    lines: [
                        .init("NO STANDING", color: .red),
                        .init("8AM-6PM", weight: .semibold)
                    ],
                    borderColor: .red,
                    accessibilityDescription: "Sign reads: No Standing, 8 AM to 6 PM"
                )
                SignPlateView(
                    lines: [
                        .init("NO PARKING", color: .red),
                        .init("8-9:30AM TUES FRI", weight: .semibold),
                        .init("STREET CLEANING", weight: .semibold)
                    ],
                    borderColor: .black,
                    accessibilityDescription: "Sign reads: No Parking, 8 to 9:30 AM, Tuesday and Friday, street cleaning"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        SignSchoolSectionView()
            .padding()
    }
}
