//
//  ArrivalPromptSheet.swift
//  WePark
//
//  W8.5d: Arrival prompt sheet — fires once per Drive Mode session when the driver
//  reaches within `FinalApproachService.arrivalThresholdMeters` of the destination.
//
//  OQ-3 resolution: sheet via existing `ActiveSheet` enum (new case `.arrivalPrompt`).
//  Consistent with `ParkConfirmView` pattern; simpler dedicated view (no "Wrong street?"
//  alternatives — the user IS at their parking location, not selecting a block remotely).
//
//  Pin-drop hook (§3.5):
//    - "Park Here" confirm → `onParkHere(coord)` → `parkPinService.save(car)` at the
//      user's CURRENT GPS coordinate (NOT the destination coordinate — load-bearing distinction).
//    - `pinDropped` publisher fires → W7.5 "Park Until X" follow-up sheet fires naturally.
//    - Drive Mode ends on confirm (ContentView sets driveModeActive = false).
//
//  "Not Yet" dismiss: Drive Mode stays active. `arrivalPromptFired` remains true (no re-fire).
//  OQ-6 resolution: one-shot per session; End Drive pill always tappable.
//
//  No MapKit import (pure SwiftUI view).
//  No Calendar.current.
//

import SwiftUI
import CoreLocation

// MARK: - ArrivalPromptSheet

struct ArrivalPromptSheet: View {

    // MARK: - Inputs

    /// The user's GPS coordinate at the moment of arrival detection.
    /// This is the coordinate passed to `onParkHere` — the pin drops HERE,
    /// not at the destination the driver searched for.
    let arrivalCoordinate: CLLocationCoordinate2D

    /// Nearest street name from the current driving context, if available.
    /// Shown in the subtitle for spatial orientation ("Park on W 34 St?").
    /// Nil → generic subtitle ("Park here?").
    let nearestStreet: String?

    // MARK: - Callbacks

    /// Called when the user taps "Park Here".
    /// ContentView drops the W5 pin at `arrivalCoordinate` and ends Drive Mode.
    let onParkHere: (CLLocationCoordinate2D) -> Void

    /// Called when the user taps "Not Yet".
    /// ContentView dismisses the sheet; Drive Mode stays active.
    let onNotYet: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text("You've arrived")
                    .font(.title2)
                    .fontWeight(.bold)

                if let street = nearestStreet, !street.isEmpty {
                    Text("Park on \(formattedStreetName(street))?")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Park here?")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)

            // Action buttons
            VStack(spacing: 12) {
                // Primary: Park Here
                Button {
                    onParkHere(arrivalCoordinate)
                } label: {
                    Label("Park Here", systemImage: "mappin.and.ellipse")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Park here — drop pin at current location")
                .accessibilityHint("Drops a parking pin at your current GPS position and ends Drive Mode.")

                // Secondary: Not Yet
                Button {
                    onNotYet()
                } label: {
                    Text("Not Yet")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Not yet — continue Drive Mode")
                .accessibilityHint("Dismisses this prompt. Drive Mode stays active. You can end Drive Mode at any time using the End Drive button.")
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }

    // MARK: - Helpers

    /// Converts an ALL-CAPS street name from tile data to Title Case for display.
    /// e.g., "W 34 ST" → "W 34 St"
    private func formattedStreetName(_ rawStreet: String) -> String {
        rawStreet.split(separator: " ").map { word in
            let str = String(word)
            return str.prefix(1).uppercased() + str.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

// MARK: - Preview

#Preview {
    ArrivalPromptSheet(
        arrivalCoordinate: CLLocationCoordinate2D(latitude: 40.7506, longitude: -73.9935),
        nearestStreet: "W 34 ST",
        onParkHere: { _ in },
        onNotYet: {}
    )
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    .presentationBackground(.regularMaterial)
    .presentationCornerRadius(20)
}
