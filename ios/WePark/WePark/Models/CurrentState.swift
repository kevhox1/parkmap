//
//  CurrentState.swift
//  WePark
//
//  Option B dynamic state enum — represents what's true about a parking segment
//  RIGHT NOW, not its static category. The same block can cycle through all
//  four non-unknown states in a single week.
//
//  Locked decision: docs/ios-mvp-spec.md §3.7 / docs/design/ios-mvp-palette.md §2.1
//

import SwiftUI

enum CurrentState: Equatable {
    /// Block is currently restricted — do not park.
    /// Includes: NO_PARKING anytime; ASP active in its current window;
    /// NO_STANDING; TRUCK_LOADING active now; SPECIAL active now.
    case restrictedNow

    /// Block is free right now, but a restriction starts within ~24 hours.
    /// Warning state — fine for a quick errand, not safe for overnight parking.
    case freeButRestrictionSoon

    /// Block requires payment right now (METERED during paid hours).
    case meteredActive

    /// Block is free right now with no restriction imminent (>24h away).
    /// Safe for overnight parking.
    case freeComfortably

    /// No data available for this segment.
    case unknown

    // MARK: - Color mapping

    /// Returns the SwiftUI color from ParkingColors corresponding to this state.
    /// The canonical mapping from spec §3.7 / palette doc §2.2.
    var swiftUIColor: Color {
        switch self {
        case .restrictedNow:         return ParkingColors.restricted
        case .freeButRestrictionSoon: return ParkingColors.restrictionComingSoon
        case .meteredActive:         return ParkingColors.meteredActive
        case .freeComfortably:       return ParkingColors.freeComfortably
        case .unknown:               return ParkingColors.unknown
        }
    }
}
