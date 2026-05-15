//
//  ParkedCar.swift
//  WePark
//
//  W5: Codable model representing the user's parked car pin.
//
//  No import SwiftUI — this is a pure data model (QA invariant).
//  No Calendar.current — parkedAt is stored as a raw Date (UTC timestamp);
//  display formatting happens in the view layer using Calendar.easternTime.
//
//  Persistence: UserDefaults-backed single blob via ParkPinService.
//  Single-pin model — only one ParkedCar exists at a time.
//
//  AC-W5.3 (no snap): latitude/longitude are the exact tap coordinate
//  from the long-press (Path A) or the segment midpoint (Path B).
//  detectedSegmentID is used for rules re-lookup only, never to reposition the pin.
//
//  W7: Added notifyOnRestriction — per-pin reminder opt-in (§4.A).
//  Custom CodingKeys + init(from:) so pre-W7 persisted pins decode safely:
//  missing key → default true (notification active). This handles the existing
//  UserDefaults blob without invalidating it or crashing on load.
//

import Foundation

struct ParkedCar: Codable, Identifiable {

    /// Stable identity for SwiftUI `.sheet(item:)` binding.
    var id: UUID

    /// Exact tap coordinate — no snapping to polyline.
    let latitude: Double
    let longitude: Double

    /// Segment ID for rules re-lookup in ParkedCarDetailView.
    /// Nil if no segment was within 35m at pin-drop time (no-nearby-data fallback).
    let detectedSegmentID: String?

    /// Side of street derived from the detected segment: "N" | "S" | "E" | "W".
    /// Nil when detectedSegmentID is nil.
    let detectedSide: String?

    /// Cached street name for display without re-lookup.
    let street: String?

    /// Cached from-cross-street for "between X and Y" subtitle.
    let fromStreet: String?

    /// Cached to-cross-street for "between X and Y" subtitle.
    let toStreet: String?

    /// Wall-clock timestamp of pin drop (stored as UTC; display uses ET calendar).
    let parkedAt: Date

    /// W7: Whether the user opted into a reminder notification for this specific parking session.
    /// Defaults true (reminder active). Persisted so the user can flip it in ParkedCarDetailView
    /// after pin drop without losing the setting across app relaunches.
    let notifyOnRestriction: Bool

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case latitude
        case longitude
        case detectedSegmentID
        case detectedSide
        case street
        case fromStreet
        case toStreet
        case parkedAt
        case notifyOnRestriction
    }

    // MARK: - Custom decode (for pre-W7 migration)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try container.decode(UUID.self,    forKey: .id)
        latitude           = try container.decode(Double.self,  forKey: .latitude)
        longitude          = try container.decode(Double.self,  forKey: .longitude)
        detectedSegmentID  = try container.decodeIfPresent(String.self, forKey: .detectedSegmentID)
        detectedSide       = try container.decodeIfPresent(String.self, forKey: .detectedSide)
        street             = try container.decodeIfPresent(String.self, forKey: .street)
        fromStreet         = try container.decodeIfPresent(String.self, forKey: .fromStreet)
        toStreet           = try container.decodeIfPresent(String.self, forKey: .toStreet)
        parkedAt           = try container.decode(Date.self,    forKey: .parkedAt)
        // Safe decoding default — existing pins before W7 will get notifyOnRestriction = true.
        notifyOnRestriction = try container.decodeIfPresent(Bool.self, forKey: .notifyOnRestriction) ?? true
    }

    // MARK: - Memberwise init (used by callers that construct ParkedCar directly)

    init(
        id: UUID,
        latitude: Double,
        longitude: Double,
        detectedSegmentID: String?,
        detectedSide: String?,
        street: String?,
        fromStreet: String?,
        toStreet: String?,
        parkedAt: Date,
        notifyOnRestriction: Bool = true
    ) {
        self.id                 = id
        self.latitude           = latitude
        self.longitude          = longitude
        self.detectedSegmentID  = detectedSegmentID
        self.detectedSide       = detectedSide
        self.street             = street
        self.fromStreet         = fromStreet
        self.toStreet           = toStreet
        self.parkedAt           = parkedAt
        self.notifyOnRestriction = notifyOnRestriction
    }
}
