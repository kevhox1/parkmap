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
}
