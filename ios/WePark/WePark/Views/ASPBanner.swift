//
//  ASPBanner.swift
//  WePark
//
//  W7 (§3.A): ASP suspension status banner, displayed at the top of the map.
//
//  Placement: applied to MapViewRepresentable via `.safeAreaInset(edge: .top)` in ContentView.
//  This pushes the map content down rather than overlapping it.
//
//  Three states (from ASPSuspensionService.suspensionState(at:)):
//    .todaySuspended(reason)    → green background, white text: "ASP Suspended — <reason>"
//                                 Good news for the parker (no need to move); green = safe/free.
//    .tomorrowSuspended(reason) → soft blue background, white text: "ASP Suspended Tomorrow — <reason>"
//                                 Informational preview; neutral/muted tone distinct from amber.
//    .aspInEffect               → amber background, dark text: "ASP in Effect Today"
//                                 Caution (must move on schedule); amber = pay-to-park / caution.
//
//  Not dismissible — the suspension status is a ground-truth safety fact that persists all day.
//
//  Accessibility: The container has an .accessibilityLabel combining the full sentence
//  so VoiceOver reads the complete status (not just visible abbreviated text).
//
//  Refresh: ContentView reads suspensionState on .onAppear and on scenePhase → .active.
//  The suspension calendar is date-based (days only), so no polling timer is needed.
//
//  Colors are from docs/design/ios-mvp-palette.md §3 and ParkingColors.swift.
//  No new color constants are introduced.
//
//  No Calendar.current use.
//

import SwiftUI

struct ASPBanner: View {

    let state: SuspensionBannerState

    var body: some View {
        HStack {
            Spacer()
            Text(bannerText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
            Spacer()
        }
        .background(backgroundColor)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Banner text

    private var bannerText: String {
        switch state {
        case .todaySuspended(let reason):
            return "ASP Suspended \u{2014} \(reason)"
        case .tomorrowSuspended(let reason):
            return "ASP Suspended Tomorrow \u{2014} \(reason)"
        case .aspInEffect:
            return "ASP in Effect Today"
        }
    }

    // MARK: - Colors

    private var backgroundColor: Color {
        switch state {
        case .todaySuspended:
            // Green = good news for the parker (no need to move). Reuses ParkingColors.freeComfortably.
            return .green
        case .tomorrowSuspended:
            // Soft blue: informational/preview tone; distinct from amber so the two don't look alike.
            return Color(red: 0.24, green: 0.56, blue: 0.90)
        case .aspInEffect:
            // Amber-yellow: caution (must move on schedule). Reuses ParkingColors.meteredActive.
            return Color(red: 0.92, green: 0.76, blue: 0.0)
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .aspInEffect:
            // Dark text on amber for contrast (WCAG AA on this amber value).
            return Color(red: 0.15, green: 0.10, blue: 0.0)
        default:
            // White text on green (todaySuspended) and soft blue (tomorrowSuspended).
            return .white
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        switch state {
        case .todaySuspended(let reason):
            return "ASP suspended today. Reason: \(reason). No need to move your car."
        case .tomorrowSuspended(let reason):
            return "ASP suspended tomorrow. Reason: \(reason)."
        case .aspInEffect:
            return "ASP in effect today. Move your car on schedule."
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        ASPBanner(state: .todaySuspended(reason: "Memorial Day"))
        ASPBanner(state: .tomorrowSuspended(reason: "Thanksgiving"))
        ASPBanner(state: .aspInEffect)
    }
}
