//
//  DriveModeBottomCard.swift
//  WePark
//
//  W8.5c: Drive Mode bottom card UI.
//  W8.5c-polish PR-1: Distance-to-destination indicator added (Feature A).
//
//  Port of `renderDrivingContext` (index.html:5863–5910) adapted to SwiftUI.
//
//  Layout (OQ-1: full-width, pinned to bottom safe area via .safeAreaInset(edge: .bottom)):
//    - Street name row (headline) with optional distance-to-destination indicator (top-right)
//    - Two chips side-by-side: Left / Right, color-coded by severity
//    - Mute toggle button (speaker.wave.2.fill / speaker.slash.fill)
//
//  Font sizes use system defaults. Calibration deferred to W8.5c-follow post-drive-test.
//  No final-approach strip (deferred to W8.5d — showApproachStrip placeholder provided).
//
//  No import MapKit (pure SwiftUI view).
//  No Calendar.current.
//
//  Two-state layout:
//    - context == nil: GPS not matched to a tile segment → "Looking for street…" placeholder.
//      Shown at Drive Mode start before DrivingContextService has a fix, or when driving
//      in a gap between tile coverage areas.
//    - context != nil: GPS matched to a block → street name + left/right severity chips.
//      Chips color-code parking severity per the W4.5 palette.
//

import SwiftUI

// MARK: - DriveModeBottomCard

struct DriveModeBottomCard: View {

    // MARK: - Inputs

    /// Current driving context. Nil → show "Looking for street…" placeholder.
    let context: DrivingContext?

    /// Voice service for mute toggle binding.
    let voiceService: DrivingVoice

    /// W8.5c-polish PR-1: Distance to the active destination in meters.
    /// Pre-computed by ContentView via CLLocation.distance(from:) on every location fix.
    /// Nil when no destination is set — the indicator is hidden in that case (not "0 mi" / "—").
    var destinationDistance: Double? = nil

    /// W8.5c-polish PR-1: Whether to format the distance in metric (km) or imperial (mi).
    /// Defaults to checking Locale.current.measurementSystem so callers don't need to pass it
    /// explicitly in most cases. Exposed as a parameter to allow test injection without Locale mocking.
    var usesMetricSystem: Bool = (Locale.current.measurementSystem == .metric)

    /// W8.5d placeholder: when true, show the final-approach escalation strip.
    /// Not wired in W8.5c — always false.
    var showApproachStrip: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // W8.5d placeholder: final-approach strip goes here.
            // showApproachStrip && context != nil → escalation UI (W8.5d).

            cardContent
        }
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color(.separator)),
            alignment: .top
        )
    }

    // MARK: - Card content

    @ViewBuilder
    private var cardContent: some View {
        if let ctx = context {
            VStack(spacing: 10) {
                // Street name row
                // W8.5c-polish PR-1: distance indicator is inlined top-right of the street name.
                HStack {
                    Text(ctx.street.split(separator: " ").map { word in
                        String(word.prefix(1)).uppercased() + String(word.dropFirst()).lowercased()
                    }.joined(separator: " "))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // W8.5c-polish PR-1: distance-to-destination indicator.
                    // Hidden (conditional rendering) when destinationDistance is nil.
                    if let distMeters = destinationDistance {
                        Text(formattedDistance(meters: distMeters))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Distance to destination: \(formattedDistance(meters: distMeters))")
                    }

                    muteButton
                }
                .padding(.horizontal, 16)

                // Left / Right chips
                HStack(spacing: 12) {
                    chipView(label: "Left", safetyLabel: ctx.leftLabel)
                    chipView(label: "Right", safetyLabel: ctx.rightLabel)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        } else {
            // Placeholder when no street data (AC-W85c.27)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking for street\u{2026}")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                muteButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Chip view

    /// Color-coded severity chip. Port of `dm-side-chip` styling (index.html:5896–5899).
    private func chipView(label: String, safetyLabel: SafetyLabel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)

            let hasData = safetyLabel.text != "No data" && !safetyLabel.text.isEmpty
            Text(hasData ? safetyLabel.text : "\u{2014}")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(chipTextColor(for: safetyLabel.severity))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chipBackgroundColor(for: safetyLabel.severity), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Severity palette (port of W4.5 / ParkingColors)

    /// Chip background color per severity (W4.5 palette).
    private func chipBackgroundColor(for severity: SafetyLabel.Severity) -> Color {
        switch severity {
        case .free:       return ParkingColors.freeComfortably.opacity(0.15)
        case .metered:    return ParkingColors.meteredActive.opacity(0.15)
        case .restricted: return ParkingColors.restricted.opacity(0.15)
        case .unknown:    return Color(.secondarySystemGroupedBackground)
        }
    }

    /// Chip foreground text color per severity.
    private func chipTextColor(for severity: SafetyLabel.Severity) -> Color {
        switch severity {
        case .free:       return ParkingColors.freeComfortably
        case .metered:    return ParkingColors.meteredActive
        case .restricted: return ParkingColors.restricted
        case .unknown:    return Color.secondary
        }
    }

    // MARK: - Distance formatting (W8.5c-polish PR-1)

    /// Formats a distance in meters to a localized string respecting `usesMetricSystem`.
    ///
    /// Uses `MeasurementFormatter` + `Measurement<UnitLength>` — the same underlying
    /// mechanism recommended by Apple for localized unit presentation.
    /// Precision: one decimal place (e.g., "0.8 mi", "1.2 km").
    ///
    /// `usesMetricSystem` is injected as a stored property (not calling `Locale.current`
    /// directly inside this method) so unit tests can control the output locale without
    /// swizzling or subclassing.
    func formattedDistance(meters: Double) -> String {
        let measurement: Measurement<UnitLength>
        if usesMetricSystem {
            let km = meters / 1000.0
            measurement = Measurement(value: km, unit: UnitLength.kilometers)
        } else {
            let miles = meters / 1609.344
            measurement = Measurement(value: miles, unit: UnitLength.miles)
        }
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium          // "km" / "mi" abbreviated form
        formatter.numberFormatter.minimumFractionDigits = 1
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: measurement)
    }

    // MARK: - Mute button (AC-W85c.23, AC-W85c.28)

    private var muteButton: some View {
        Button {
            voiceService.isMuted.toggle()
        } label: {
            Image(systemName: voiceService.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(voiceService.isMuted ? Color.secondary : Color.accentColor)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: Circle())
        }
        .accessibilityLabel(voiceService.isMuted ? "Unmute Drive Mode voice" : "Mute Drive Mode voice")
        .accessibilityHint("Toggles the parking commentary voice announcements.")
    }
}

#Preview {
    let voice = DrivingVoice()
    VStack {
        Spacer()
        DriveModeBottomCard(
            context: DrivingContext(
                street: "W 34 ST",
                from: "7 AVE",
                to: "8 AVE",
                leftLabel: SafetyLabel(text: "Free until Thu 9:30am", severity: .free),
                rightLabel: SafetyLabel(text: "No parking", severity: .restricted)
            ),
            voiceService: voice
        )
    }
    .background(Color(.systemGroupedBackground))
}
