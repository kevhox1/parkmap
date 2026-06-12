//
//  SignCheckConfirmView.swift
//  WePark
//
//  TF2-7: Sign-check confirmation sheet — pre-step before ParkConfirmView.
//
//  Presented via ActiveSheet.signCheckConfirm(intent: PinDropIntent) when the driver
//  taps the "Park here" button in the Drive Mode overlay. Displays a 5-item checklist
//  of parking-safety reminders, then transitions to ParkConfirmView on confirm.
//
//  Why before, not inside ParkConfirmView (spec §5.3):
//    ParkConfirmView is also triggered from long-press (resting) and the W8.5d arrival prompt.
//    The sign-check is exclusively for the in-drive "Park here" button context — the driver
//    has just pulled over. Inserting it inside ParkConfirmView would show it on ALL paths,
//    including map-browsing long-presses, which is wrong context.
//
//  The W8.5d arrival prompt path BYPASSES this sheet (spec §5.4).
//
//  No MapKit import. No CoreLocation import. Static content + pass-through only.
//  No Calendar.current. No import of service types.
//
//  Checklist items are OPTIONAL affordances — checkboxes do not gate the "Confirm" button.
//  Rationale: mandatory checking would be trivially tapped through without reading;
//  optional checking preserves the educational intent without adding friction.
//
//  Sheet is dismissible (swipe-to-dismiss = cancel, does not proceed to ParkConfirmView).
//

import SwiftUI

// MARK: - SignCheckConfirmView

/// A five-item parking-safety checklist shown before `ParkConfirmView`.
///
/// - `intent`: The in-flight `PinDropIntent` carrying the GPS coordinate for the pin drop.
///   Passed through unchanged to `onConfirm` — no coordinate mutation.
/// - `onConfirm`: Called when the driver taps "I checked — Park here." The caller
///   (`ContentView.sheetContent`) sets `activeSheet = .parkConfirm(confirmedIntent)`.
/// - `onCancel`: Called on explicit "Cancel" tap OR on swipe-to-dismiss (`.onDisappear`
///   when the intent was not confirmed). The caller sets `activeSheet = nil`.
struct SignCheckConfirmView: View {

    let intent: PinDropIntent
    let onConfirm: (PinDropIntent) -> Void
    let onCancel: () -> Void

    // MARK: - Optional checkbox state (educational affordances, not gates)

    @State private var checked: [Bool] = Array(repeating: false, count: 5)

    // MARK: - Confirm tracking (for swipe-to-dismiss cancel detection)

    @State private var confirmed = false

    // MARK: - Body

    var body: some View {
        // TF2-9 fix: opaque background so Drive Mode overlay text cannot bleed through.
        // `.regularMaterial` (set by the caller's .presentationBackground) may be
        // translucent enough at .medium detent to show the bottom card text behind the
        // sheet. Wrapping in a ZStack with Color(.systemBackground) at the back ensures
        // the sheet body is fully opaque regardless of detent or blur transparency.
        NavigationStack {
            ZStack(alignment: .bottom) {
                // TF2-9: Opaque fill behind all content — blocks underlying Drive overlay text.
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // TF2-9: ScrollView wraps the checklist so all 5 items are reachable at any
                    // dynamic type size and at the .medium detent height. Without ScrollView the
                    // checklist can clip at large accessibility type sizes.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Subtitle
                            Text("Take 10 seconds — the signs are the final word.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .padding(.top, 4)
                                .padding(.bottom, 16)

                            // Checklist
                            VStack(alignment: .leading, spacing: 14) {
                                checklistRow(
                                    index: 0,
                                    icon: "signpost.right.fill",
                                    iconColor: .blue,
                                    text: "Read all posted signs on this side of the street — they stack top to bottom, all rules apply."
                                )
                                checklistRow(
                                    index: 1,
                                    icon: "flame.fill",
                                    iconColor: .red,
                                    text: "15 feet from a fire hydrant — no parking (NYC rule; hydrants are easy to miss at night)."
                                )
                                checklistRow(
                                    index: 2,
                                    icon: "curbcut.fill",
                                    iconColor: .orange,
                                    text: "Not blocking a driveway or curb cut."
                                )
                                checklistRow(
                                    index: 3,
                                    icon: "bus.fill",
                                    iconColor: .purple,
                                    text: "Not in a bus stop or no-standing zone (usually marked with a yellow curb or sign)."
                                )
                                checklistRow(
                                    index: 4,
                                    icon: "calendar.badge.clock",
                                    iconColor: .green,
                                    text: "Check today's ASP status — the banner at the top of the map shows it."
                                )
                            }
                            .padding(.horizontal)
                            // Bottom padding gives space so the last row isn't flush against
                            // the sticky CTA block below.
                            .padding(.bottom, 24)
                        }
                    }

                    // Sticky CTA block — pinned to the bottom of the sheet, NOT inside
                    // the ScrollView, so it remains visible without scrolling. A Divider
                    // separates it from the scrollable content.
                    Divider()
                    VStack(spacing: 12) {
                        // Primary: confirm and proceed to ParkConfirmView
                        Button {
                            confirmed = true
                            onConfirm(intent)
                        } label: {
                            Text("I checked — Park here")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                        .accessibilityLabel("I checked — Park here")
                        .accessibilityHint("Proceeds to the pin drop confirmation screen.")

                        // Secondary: cancel
                        Button {
                            confirmed = true  // mark so .onDisappear doesn't double-fire onCancel
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                        .accessibilityLabel("Cancel")
                        .accessibilityHint("Dismisses this sheet without parking.")
                    }
                    .padding(.top, 12)
                    .background(Color(.systemBackground))
                }
            }
            .navigationTitle("Check before you park")
            .navigationBarTitleDisplayMode(.large)
        }
        .onDisappear {
            // Swipe-to-dismiss path: if the user swiped down without tapping either CTA,
            // fire onCancel so ContentView clears activeSheet.
            if !confirmed {
                onCancel()
            }
        }
    }

    // MARK: - Checklist row builder

    @ViewBuilder
    private func checklistRow(
        index: Int,
        icon: String,
        iconColor: Color,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // SF Symbol icon
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 28, alignment: .center)

            // Rule text
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Optional checkbox (educational affordance — does not gate confirm button)
            Image(systemName: checked[index] ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(checked[index] ? Color.accentColor : Color.secondary)
                .onTapGesture {
                    checked[index].toggle()
                }
                .accessibilityLabel(checked[index] ? "Checked" : "Unchecked")
                .accessibilityHint("Optional — tap to mark as reviewed.")
                .accessibilityAddTraits(.isButton)
        }
    }
}
