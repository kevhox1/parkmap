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
    /// Superseded by ReminderOffsets.remind1Hour preset in FT-6. Retained for documentation.
    static let notificationLeadTimeSeconds: TimeInterval = 1 * 3600

    // MARK: - FT-6 Customizable Reminders

    /// UserDefaults key for the serialized `ReminderOffsets` value (JSON-encoded Data).
    /// Default (missing key) = `ReminderOffsets.default` = {remind1Hour: true, all others false}.
    static let reminderOffsetsKey = "wepark_reminder_offsets"

    /// Hour of day (Eastern Time) for the "Night before" reminder preset.
    /// 20 = 8:00 PM ET. Constant named for future user-configurable upgrade (§10 follow-up).
    static let nightBeforeHourET: Int = 20

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

    /// UserDefaults key: set to true after the background-limitation note has been shown once.
    /// Guards the one-time informational alert on first Drive Mode start explaining that
    /// parking commentary pauses when the app is backgrounded (spec §7 R-3, AC-DM.23).
    static let driveModeBackgroundNoteShownKey = "wepark_dm_bg_note_shown"

    // MARK: - FT-12: Parking 101 guide

    /// UserDefaults key: set to true after the first-launch "Parking 101" prompt banner
    /// has been shown/dismissed once per install (spec §7).
    static let parkingGuidePromptShownKey = "wepark_parking101_prompt_shown"
}

// MARK: - MoneyMathConstants (FT-12 §6)

/// Named, sourced dollar figures for the Parking 101 guide's Pitch section.
///
/// Rationale (spec §6 / OQ-4): these are private-market aggregator figures, not an
/// official DOT price list, and garage pricing drifts. Storing them as named constants
/// with a doc-commented source + pull date makes a future refresh a one-line diff
/// instead of a grep through view files — the same discipline this repo already wants
/// for the ASP-calendar annual refresh (`HANDOFF.md`).
///
/// If any of these figures change, update `docs/parking-101-content.md` in the same PR
/// — that doc is the copy source of truth and must not drift from these values.
enum MoneyMathConstants {

    // MARK: Monthly garage parking (market data)

    /// Citywide average monthly garage parking, low end.
    /// Source: SpotAngels, "The 2026 Ultimate Guide to Cheap Monthly Parking in NYC"
    /// (https://www.spotangels.com/blog/the-ultimate-nyc-monthly-parking-guide/).
    /// Pulled 2026-07-09.
    static let garageMonthlyCitywideLow: Double = 400

    /// Citywide average monthly garage parking, high end. Same source/date as above.
    static let garageMonthlyCitywideHigh: Double = 600

    /// Manhattan monthly garage parking, low end.
    /// Source: SpotAngels, "Manhattan Monthly Parking — Best Rates & Deals"
    /// (https://www.spotangels.com/nyc/manhattan-monthly-parking); SpotHero, "New York, NY
    /// Monthly Parking" (https://spothero.com/city/monthly/nyc-parking). Pulled 2026-07-09.
    static let garageMonthlyManhattanLow: Double = 500

    /// Manhattan monthly garage parking, high end ("$1,000+" in copy — this is the
    /// conservative floor of the "+" range). Same source/date as above.
    static let garageMonthlyManhattanHigh: Double = 1000

    // MARK: Street-cleaning ticket

    /// Approximate NYC street-cleaning (ASP) ticket cost. MUST match the figure already
    /// shipped in the Help & FAQ screen (`docs/in-app-faq-content.md` line 18,
    /// `FAQHelpView.swift`) — do not introduce a second, drifted figure for the same thing.
    static let streetCleaningTicketCost: Double = 65

    // MARK: Annual savings (computed, not separately sourced — spec §6 auditability requirement)

    /// Low end of the "money back in your pocket per year" framing.
    /// Computed as 12 × `garageMonthlyCitywideLow`, per spec §6 — never hand-edit this
    /// independently of the monthly constant above.
    static var annualSavingsLow: Double { garageMonthlyCitywideLow * 12 }

    /// High end of the annual-savings framing.
    /// Computed as 12 × `garageMonthlyManhattanHigh`, per spec §6.
    static var annualSavingsHigh: Double { garageMonthlyManhattanHigh * 12 }
}

// MARK: - ParkingGuidePromptGate (FT-12 §7)

/// One-time gate for the Parking 101 first-launch prompt banner (spec §7, OQ-2).
///
/// Mirrors `BackgroundNoteGate` exactly, but governs a dismissible bottom banner rather
/// than a blocking alert (see OQ-2 rationale: promotional/educational content at cold
/// launch should never compete with system permission dialogs the way a blocking sheet
/// would). `markShown()` fires on any of: tapping the banner to open the guide, tapping
/// the dismiss (X) control, or the ~8s auto-hide timer — all three count as "shown."
///
/// Usage:
///   let gate = ParkingGuidePromptGate()  // uses UserDefaults.standard
///   if gate.shouldShow() {
///       // present the banner
///       gate.markShown()
///   }
struct ParkingGuidePromptGate {
    private let defaults: UserDefaults
    private let key: String

    /// Designated init — accepts any `UserDefaults` instance so tests can inject an
    /// ephemeral suite instead of polluting `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard,
         key: String = AppConstants.parkingGuidePromptShownKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Returns `true` if the banner has never been shown on this device.
    func shouldShow() -> Bool {
        !defaults.bool(forKey: key)
    }

    /// Persists that the banner has been shown. Subsequent `shouldShow()` calls return `false`.
    func markShown() {
        defaults.set(true, forKey: key)
    }
}

// MARK: - BackgroundNoteGate

/// One-time gate for the Drive Mode background-limitation alert (spec §7 R-3, AC-DM.23).
///
/// Separating the gate logic from ContentView makes it unit-testable with an ephemeral
/// UserDefaults suite — no UIKit or SwiftUI dependencies required.
///
/// Usage:
///   let gate = BackgroundNoteGate()  // uses UserDefaults.standard
///   if gate.shouldShow() {
///       // present the alert
///       gate.markShown()
///   }
struct BackgroundNoteGate {
    private let defaults: UserDefaults
    private let key: String

    /// Designated init — accepts any `UserDefaults` instance so tests can inject an
    /// ephemeral suite instead of polluting `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard,
         key: String = AppConstants.driveModeBackgroundNoteShownKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Returns `true` if the alert has never been shown on this device.
    /// Returns `false` after `markShown()` has been called.
    func shouldShow() -> Bool {
        !defaults.bool(forKey: key)
    }

    /// Persists that the alert has been shown. Subsequent `shouldShow()` calls return `false`.
    func markShown() {
        defaults.set(true, forKey: key)
    }
}
