//
//  Constants.swift
//  WePark
//

import Foundation
import CoreLocation

enum AppConstants {
    /// Manhattan center, used as the default map center on first launch.
    /// Matches the PWA's `[40.7831, -73.9712]` (see `index.html`).
    static let manhattanCenter = (latitude: 40.7831, longitude: -73.9712)

    // MARK: - Viewport-polish: tile-grid coverage bounds

    /// Bounding box of the pre-built tile grid (from tiles/index.json).
    /// Used by `isInManhattanCoverage(_:)` to decide whether auto-center at launch
    /// is appropriate. A simple four-comparison check — no haversine, no polygon.
    ///
    /// Covers: Manhattan proper, Roosevelt Island, Marble Hill, and grid-edge slivers
    /// of Bronx/Queens. Excludes: Hoboken (lon -74.032 < lngMin), Jersey City, JFK
    /// (lat 40.641 < latMin), Yonkers (lat 40.931 > latMax), Flushing.
    /// Northwest Brooklyn (DUMBO/Brooklyn Heights ~40.703, -73.990) falls inside —
    /// auto-centering there is acceptable (honest basemap; no overlays at that loc).
    static let manhattanCoverageBounds = (
        latMin: 40.700,
        latMax: 40.882,
        lngMin: -74.020,
        lngMax: -73.907
    )

    /// Returns true if the given coordinate falls within the pre-built tile grid.
    /// Auto-center at launch fires only when this returns true (OD-2, viewport-polish spec).
    /// The deep-link / parked-car path bypasses this check — user explicitly parked there.
    static func isInManhattanCoverage(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude  >= manhattanCoverageBounds.latMin &&
        coordinate.latitude  <= manhattanCoverageBounds.latMax &&
        coordinate.longitude >= manhattanCoverageBounds.lngMin &&
        coordinate.longitude <= manhattanCoverageBounds.lngMax
    }

    /// In-app notification rationale shown before `UNUserNotificationCenter.requestAuthorization`.
    /// Verbatim from `docs/ios-mvp-spec.md` §3.6 — do not change without updating the spec.
    static let notificationRationale = "Get a reminder before alternate-side parking starts so you never get ticketed. Notifications are scheduled on-device only."

    // MARK: - W6 Notification keys

    /// UserDefaults key: set to true after the rationale sheet has been presented once per install.
    /// Guards `firstPinDropped` → rationale sheet presentation in ContentView.
    static let notificationRationaleShownKey = "wepark_notification_rationale_shown"

    /// UserDefaults key: W7 integration point — mute toggle.
    /// W6 stubs this as always absent (= false). W7 fills it in via the settings sheet.
    /// Do NOT read or write this key from W6 code; reserved for W7.
    static let notificationsMutedKey = "wepark_notifications_muted"

    /// Lead time (seconds) before the next restriction at which the notification fires.
    /// 1 hour — per `docs/ios-mvp-spec.md` §2.1 baseline and OQ-W6-1 answer.
    /// Change only this constant to adjust the lead time globally.
    static let notificationLeadTimeSeconds: TimeInterval = 1 * 3600

    // MARK: - W8.5b: Recent destinations

    /// UserDefaults key for the list of recently driven-to destinations.
    /// Bounded to 5 most-recent entries, MRU ordering (newest first).
    /// Each entry is a JSON-encoded `RecentDestination` struct.
    static let recentDestinationsKey = "wepark_recent_destinations"

    // MARK: - W8.5c: Drive Mode constants

    /// Drive Mode follow-mode zoom span in meters (N-S and E-W).
    /// PWA uses zoom level 18 (≈220m visible radius). We target a similar street-level view.
    /// Calibration deferred to W8.5c-follow after drive-test.
    static let drivingZoomMeters: Double = 300
}
