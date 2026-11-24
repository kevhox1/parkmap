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
//  FT-20 (2026-08-19) dark-mode default — audit conclusion for this file:
//  The app now forces Dark appearance always (WeParkApp.swift / Info.plist
//  UIUserInterfaceStyle). Every constant below was re-checked for contrast against
//  MapKit's dark basemap rather than the light one they were originally tuned for.
//    - `restricted` / `restrictionComingSoon` / `freeComfortably` are SwiftUI's system
//      semantic colors (.red / .orange / .green), which bridge to UIColor.systemRed /
//      .systemOrange / .systemGreen — Apple's dynamic colors that resolve a distinct,
//      slightly brighter RGB value per appearance. These already resolve to their Dark
//      Mode variant now that the app is permanently dark; no literal change needed here.
//    - `meteredActive` is a fixed (non-adaptive) literal, amber-shifted from pure yellow
//      specifically so it would separate from Apple Maps' light tan basemap (see palette
//      doc §2.3). The palette doc's own Dark Mode section (§5.2) already reasoned that this
//      value reads at least as well — arguably better — against a dark basemap, since a
//      darker background can't wash out a warm color the way a bright one can. A
//      luminance-contrast check (WCAG 2.1 formula, this constant as text/fill over an
//      assumed near-black dark systemBackground) put every consumer well clear of AA.
//      Left unchanged; flagged in the FT-20 PR for a skeptical live look since it is the
//      one severity color that does NOT auto-adapt.
//    - `unknown`'s 0.35 opacity is a locked design decision (palette doc changelog,
//      2026-05-10: "Unknown opacity locked to 0.35") and is deliberately low-contrast by
//      design ("opacity lowers visual weight" above) — not a bug to fix. Worst-case
//      luminance-contrast estimate against a near-black dark basemap segment is lower
//      than against the light tan basemap it was tuned on, but not down to invisible.
//      Left unchanged; flagged in the FT-20 PR as the constant most worth Kevin's daylight
//      device check, since "how low is too low" here is a perceptual judgment call this
//      audit cannot make from a contrast formula alone.
//    - `constructionOrange` is a fixed literal used only as an OPAQUE marker/badge fill
//      (map pin circle, block-restriction banner icon), never blended with the basemap —
//      appearance-independent by construction. No change needed.
//  None of the above claims are validated in direct sunlight on a windshield mount — see
//  the FT-20 PR description for the honesty caveat this audit operates under.
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
