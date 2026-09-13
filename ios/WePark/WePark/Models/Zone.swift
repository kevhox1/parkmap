//
//  Zone.swift
//  WePark
//
//  Community 2.0 S14 — the client-side row shape for `public.zones`. Replaces the compiled-in
//  three-zone lookup table that used to live in `Services/` (retired this session) now that
//  the server table itself is growing from 3 rows to 41 (`docs/community-2.0-manhattan-zones.md`,
//  `supabase/06-manhattan-zones.sql`). Spec: `docs/community-2.0-s14-execution-spec.md` §3.1.
//
//  Fetched by `Services/ZoneStore.swift` — this file is the plain Codable model only, no
//  fetch/geometry/ordering logic (that lives in `ZoneStore.swift`'s `ZoneGeometry`/
//  `ZoneOrdering` enums, per this codebase's "pure decision logic separate from its data
//  model" convention).
//
//  `Equatable`/`Hashable` so `[Zone]` can drive `.onChange(of:)` (`CrewFeedSection` watches
//  `zoneStore.zones`) and dictionary/set membership checks throughout the picker logic.
//

import Foundation

/// One row of `public.zones` — a rectangular bounding-box approximation of a neighborhood
/// (`docs/community-2.0-manhattan-zones.md`'s "Where axis-aligned boxes can't match reality"
/// section documents the known overlap seams; `ZoneGeometry.zoneId(forLat:lng:in:)`'s
/// smallest-matching-box tie-break is the agreed mitigation, not true polygon geometry).
struct Zone: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let name: String
    let latMin: Double
    let latMax: Double
    let lngMin: Double
    let lngMax: Double

    private enum CodingKeys: String, CodingKey {
        case id, name
        case latMin = "lat_min"
        case latMax = "lat_max"
        case lngMin = "lng_min"
        case lngMax = "lng_max"
    }

    /// Crude area proxy (degrees², not meters²) — sufficient for the SMALLEST-box-wins tie-break
    /// (`ZoneGeometry.zoneId`) and the "no home zone, no origin" area tie-break
    /// (`ZoneOrdering.orderedZones`), since both only ever compare zones against each other, not
    /// against an absolute unit.
    var areaApprox: Double { (latMax - latMin) * (lngMax - lngMin) }

    /// Inclusive bounding-box containment check — same `>=`/`<=` semantics the retired
    /// compiled-table lookup used before this session replaced it.
    func contains(lat: Double, lng: Double) -> Bool {
        lat >= latMin && lat <= latMax && lng >= lngMin && lng <= lngMax
    }
}
