//
//  ParkingColors.swift
//  WePark
//
//  Severity-spectrum color constants for the dynamic parking state map.
//  Color encodes CURRENT STATE (what's true right now), not static category.
//  Same block changes color throughout the day as its actual parking state changes.
//
//  Source: docs/design/ios-mvp-palette.md §2.2
//  Locked decision: docs/ios-mvp-spec.md §3.7
//

import SwiftUI

enum ParkingColors {
    /// Cannot park right now.
    /// Triggered by: NO_PARKING anytime; ASP active in its current window;
    /// NO_STANDING; TRUCK_LOADING active; SPECIAL active now.
    static let restricted = Color.red

    /// Free right now, but a restriction is starting within ~24 hours.
    /// Triggered by: ASP block whose next active window starts within the
    /// ParkingRulesEngine.nearFutureWindow threshold (24h).
    static let restrictionComingSoon = Color.orange

    /// Metered (pay to park) right now.
    /// Amber-shifted from pure yellow so it reads against Apple Maps' tan
    /// basemap in daylight — see palette doc §2.3.
    static let meteredActive = Color(red: 0.92, green: 0.76, blue: 0.0)

    /// Free right now with no restriction imminent.
    /// Triggered by: FREE block; ASP block whose next window is >24h away;
    /// METERED block during its free hours.
    static let freeComfortably = Color.green

    /// Unknown — no data available for this segment.
    /// Sits outside the severity spectrum; opacity lowers visual weight.
    static let unknown = Color.gray.opacity(0.35)

    /// Construction marker "safety orange" (FT-15/TF2-15 §9.1).
    ///
    /// Single source of truth for this color — hoisted here per QA nit #4
    /// (docs/qa/ft15-b4-fetch-channel-qa.md) after the same RGB literal was found
    /// duplicated across `PinMarkerAnnotation.markerStyle` (as a `UIColor`),
    /// `PinDetailSheet.iconColor`, and `BlockDetailView.TemporaryRestrictionBanner`.
    /// `PinMarkerAnnotation` needs a `UIColor` (MapKit annotation view API) — use
    /// `UIColor(ParkingColors.constructionOrange)` there rather than a second literal.
    static let constructionOrange = Color(red: 0.91, green: 0.45, blue: 0.05)
}
