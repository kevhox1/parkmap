//
//  DriveModeBottomCard.swift
//  WePark
//
//  W8.5c: Drive Mode bottom card UI.
//  W8.5c-polish PR-1: Distance-to-destination indicator added (Feature A).
//  W8.5d: Final-approach escalation strip wired (showApproachStrip parameter).
//  TF2-17: chips now render the detailed "Free until X" text (via
//    `SafetyLabel(for: SideAggregation)` upstream) instead of the generic
//    "Free — check signs" — no view-code change needed for that part, `chipView` already
//    renders `safetyLabel.text` verbatim.
//  TF2-18 design pass (2026-07-09 review):
//    P1-1: chips switched from tinted-background/saturated-text (WCAG-failing in Light
//      Mode, ~1.4–2.6:1) to solid-fill severity background + dark text (~4.9–12:1 in both
//      appearances — see `chipTextColor`/`chipBackgroundColor` for exact values and the PR
//      description for computed ratios). Matches the already-correct `ASPBanner` pattern.
//    P1-2: chips gained a `.comingSoon` (orange) tier — see `SafetyLabel.Severity.comingSoon`.
//    P2-5: Left/Right chips changed from side-by-side to stacked (full card width each) to
//      give TF2-17's longer "Free until X" copy room to render on one line without shrinking
//      to the 0.75 minimumScaleFactor floor.
//
//  Port of `renderDrivingContext` (index.html:5863–5910) adapted to SwiftUI.
//
//  Layout (OQ-1: full-width, pinned to bottom safe area via .safeAreaInset(edge: .bottom)):
//    - (W8.5d) Final-approach strip at top of card when showApproachStrip == true
//    - Street name row (headline) with optional distance-to-destination indicator (top-right)
//    - Two chips STACKED (TF2-18 P2-5): Left row, then Right row, each full card width,
//      color-coded by severity (solid-fill, TF2-18 P1-1)
//    - Mute toggle button (speaker.wave.2.fill / speaker.slash.fill)
//
//  Font sizes use system defaults. Calibration deferred to W8.5c-follow post-drive-test.
//  The approaching strip lives INSIDE the existing .safeAreaInset(edge: .bottom) card —
//  no new .safeAreaInset layer added (OQ-1 resolution: option (b), lowest regression risk).
//
//  No import MapKit (pure SwiftUI view).
//  No Calendar.current.
//
//  Two-state layout:
//    - context == nil: GPS not matched to a tile segment → "Looking for street…" placeholder.
//      Shown at Drive Mode start before DrivingContextService has a fix, or when driving
//      in a gap between tile coverage areas.
//    - context != nil: GPS matched to a block → street name + left/right severity chips.
//      Chips color-code parking severity per the W4.5 palette (TF2-18: solid-fill, see above).
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
            // W8.5d: Final-approach escalation strip.
            // Visible when showApproachStrip == true (state == .approaching).
            // Lives INSIDE the existing .safeAreaInset(edge: .bottom) card — no new overlay layer.
            // Strip is above cardContent so it appears at the top of the bottom card.
            if showApproachStrip {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text("Approaching destination")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.10))
            }

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

                // TF2-18 P2-5: Left / Right chips STACKED (was HStack side-by-side).
                // Each chip gets the full card width (~358pt after padding on a 390pt phone),
                // comfortably fitting TF2-17's longer "Free until Wednesday 9:30 AM" copy on
                // one line — side-by-side gave each chip only ~149pt, which routinely wrapped
                // to 2 lines and hit the 0.75 minimumScaleFactor floor (review §P2-5).
                VStack(spacing: 8) {
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
                .minimumScaleFactor(0.9)
                .foregroundStyle(chipTextColor(for: safetyLabel.severity))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chipBackgroundColor(for: safetyLabel.severity), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Severity palette (TF2-18 P1-1: solid-fill, WCAG-fixed)

    /// TF2-18 P1-1: near-black text color reused verbatim from `ASPBanner.swift`'s
    /// `.aspInEffect` amber-in-effect pairing (`Color(red: 0.15, green: 0.10, blue: 0.0)`).
    /// Computes ~9.9:1 against the amber chip background — see PR description for the full
    /// contrast table. Kept as its own named constant here (not moved into `ParkingColors`)
    /// because it's a TEXT color, not a severity color — `ParkingColors` is documented as
    /// severity-background-only (see that file's header comment).
    private static let chipDarkText = Color(red: 0.15, green: 0.10, blue: 0.0)

    /// Chip background color per severity.
    ///
    /// TF2-18 P1-1: solid-fill (no `.opacity()`) — the pre-existing `.opacity(0.15)` tint
    /// under full-saturation text computed to ~1.4–2.6:1 in Light Mode (WCAG AA fail at
    /// every severity). Matches the `ASPBanner` pattern, which was already solid-fill +
    /// dark/light text and already computed ~9.9:1.
    ///
    /// P1-2: added `.comingSoon` → `ParkingColors.restrictionComingSoon` (orange), restoring
    /// the map's "restriction coming soon" warning tier to Drive Mode.
    ///
    /// `.unknown` is unchanged (review: "already uses a system color, not a tinted-self
    /// color, and is fine").
    private func chipBackgroundColor(for severity: SafetyLabel.Severity) -> Color {
        switch severity {
        case .free:       return ParkingColors.freeComfortably
        case .comingSoon: return ParkingColors.restrictionComingSoon
        case .metered:    return ParkingColors.meteredActive
        case .restricted: return ParkingColors.restricted
        case .unknown:    return Color(.secondarySystemGroupedBackground)
        }
    }

    /// Chip foreground text color per severity.
    ///
    /// TF2-18 P1-1 override (review said "white for red/green"; computed contrast against
    /// the actual solid-fill backgrounds shows white fails badly — 2.22:1 on green,
    /// 3.55:1 on red, both below WCAG AA's 3:1 large-text floor, and red is below the 4.5:1
    /// normal-text floor too). Using dark text everywhere clears AA normal-text on all four
    /// severities in BOTH Light and Dark Mode (system Red/Green/Orange shift slightly
    /// brighter in Dark Mode, which only increases contrast against a dark foreground).
    /// See PR description for the full before/after ratio table. This is a flagged deviation
    /// from the review's literal text-color suggestion — the review's own INTENT (WCAG-passing
    /// solid-fill chips) is preserved; only the specific "white" choice for red/green changes.
    private func chipTextColor(for severity: SafetyLabel.Severity) -> Color {
        switch severity {
        case .free, .comingSoon, .restricted:
            return .black
        case .metered:
            return DriveModeBottomCard.chipDarkText
        case .unknown:
            return Color.secondary
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
            // HIG touch-target fix: interactive area is 44×44pt (HIG minimum).
            // Visual glyph + circle background stay at 36pt to preserve card proportions;
            // the outer 44pt frame adds invisible tap area around the visible circle.
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 36, height: 36)
                Image(systemName: voiceService.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(voiceService.isMuted ? Color.secondary : Color.accentColor)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(voiceService.isMuted ? "Unmute parking callouts" : "Mute parking callouts")
        .accessibilityHint("Toggles voice callouts for parking. Mute state is remembered across sessions.")
    }
}

// TF2-17 AC-14: preview literal updated from the stale hand-typed "Free until Thu 9:30am"
// to a realistic engine-formatted example matching `nextRestrictionTimeLabel`'s actual
// "\(dayLabel) \(h:mm a)" format — full weekday name, space before AM/PM.
#Preview("Light Mode") {
    let voice = DrivingVoice()
    VStack {
        Spacer()
        DriveModeBottomCard(
            context: DrivingContext(
                street: "W 34 ST",
                from: "7 AVE",
                to: "8 AVE",
                leftLabel: SafetyLabel(text: "Free until Wednesday 9:30 AM", severity: .free),
                rightLabel: SafetyLabel(text: "No parking", severity: .restricted)
            ),
            voiceService: voice
        )
    }
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.light)
}

// TF2-18 P1-2 preview: .comingSoon (orange) tier + worst-case text-length fixture
// (TF2-17 spec §6.3 / AC-12 — "Free until Wednesday 11:45 PM", 30 chars).
#Preview("Dark Mode — comingSoon + worst-case text") {
    let voice = DrivingVoice()
    VStack {
        Spacer()
        DriveModeBottomCard(
            context: DrivingContext(
                street: "FREDERICK DOUGLASS BLVD",
                from: "W 145 ST",
                to: "W 146 ST",
                leftLabel: SafetyLabel(text: "Free until Wednesday 11:45 PM", severity: .comingSoon),
                rightLabel: SafetyLabel(text: "Metered (paid until 7pm)", severity: .metered)
            ),
            voiceService: voice,
            destinationDistance: 482
        )
    }
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}
