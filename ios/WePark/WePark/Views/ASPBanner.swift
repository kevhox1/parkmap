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
//    .todaySuspended(reason)    → red background, white text: "ASP Suspended — <reason>"
//    .tomorrowSuspended(reason) → amber-yellow background, black text: "ASP Suspended Tomorrow — <reason>"
//    .aspInEffect               → green background, white text: "ASP in Effect Today"
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
            return .red
        case .tomorrowSuspended:
            // Amber-yellow from ParkingColors.meteredActive and the palette spec (§3).
            return Color(red: 0.92, green: 0.76, blue: 0.0)
        case .aspInEffect:
            return .green
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .tomorrowSuspended:
            return .black
        default:
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
