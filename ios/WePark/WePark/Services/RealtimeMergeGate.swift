//
//  RealtimeMergeGate.swift
//  WePark
//
//  supabase-swift adoption — Stream B (Realtime).
//  Spec: docs/supabase-swift-realtime-spec.md §3.4, §5.1, §8.2, §8.3.
//
//  Pure, framework-light decision helpers gating a Realtime `public.pins` event before it
//  reaches `CommunityPinService.mergeRealtimeChange(pin:)` / `removePin(id:)`.
//
//  Why this exists (§5.1): the Realtime subscription is ONE table-wide channel — Supabase's
//  `postgres_changes` filters only express single-column comparisons, so they cannot
//  reproduce the REST fetch channels' compound predicates (`resolved_at IS NULL AND
//  (expires_at IS NULL OR expires_at > now())`, plus a bounding-box). All of that filtering
//  happens client-side instead: `clientSideFilter` already covers expiry/resolved-at
//  (unchanged, §8.1); this file adds the two pieces that gap analysis found missing (§8.2):
//  pin-type eligibility as a single named constant, and viewport membership.
//
//  Only Foundation + MapKit (for MKCoordinateRegion) — no networking, no Supabase SDK import.
//  Matches the `DriveHeadingSnap.swift` house style of a framework-light pure-decision file.
//
//  Invariants:
//   - No Calendar.current.
//   - No force-unwraps.
//   - Pure functions / a `static let` constant only — no mutable state, no side effects.
//
//  Community 2.0 Phase 1 (docs/community-2.0-reconciliation-spec.md §1 delta table "One
//  Realtime channel per zone", §3 Phase 1 — build 20, session S3):
//   - `mergeablePinTypes` widened to include `.openSpot`/`.leavingSoon` (one-line addition in
//     this one place, per this file's own §8.3 design intent above).
//   - Adds `isInZone(pinZoneId:selectedZoneId:)` — a THIRD gating dimension alongside pin-type
//     eligibility and viewport, per the spec's explicit recommendation: "keep one channel, add
//     zone_id as one more RealtimeMergeGate dimension" rather than opening N zone-scoped
//     channels (which `postgres_changes`' single-column-comparison limitation can't express
//     compound-predicate anyway — the same reasoning that already ruled out per-source/
//     per-lifespan channels above). Client-side only; no server-side zone filter.
//

import Foundation
import MapKit

enum RealtimeMergeGate {

    // MARK: - Pin-type eligibility

    /// The `PinType` values eligible to be merged into `visiblePins` via Realtime.
    ///
    /// Single source of truth — previously a local `let mergeableTypes` re-derived inline
    /// inside `CommunityPinService.mergeRealtimeChange(pin:)`. Pulling it out here means a
    /// future pin type (FT-15/TF2-15's `filming`/`construction` already included below) slots
    /// in with a one-line addition in ONE place, not a re-derivation (§8.3) — no second
    /// Realtime-adoption pass required when new pin types ship.
    ///
    /// Values mirror `mergeRealtimeChange`'s exact pre-existing set: Tier 1 open-data display
    /// types + Tier 3 ephemeral crowd pins + FT-15/TF2-15 block-scoped `.construction`
    /// (`.filming` already covers FT-15's filming case via the Tier 1 line).
    static let mergeablePinTypes: Set<PinType> = [
        .filming, .specialEvent, .aspSuspendedToday,       // Tier 1
        .enforcementActive, .sweeperPassed, .brokenMeter,   // Tier 3
        .construction,                                       // FT-15/TF2-15
        .openSpot, .leavingSoon,                             // Community 2.0 Phase 1
    ]

    // MARK: - Viewport gating

    /// Multiplier applied to `region`'s span before testing membership in
    /// `isWithinRegion(lat:lng:region:paddingFactor:)`, so a pin sitting just outside the
    /// exact visible edge doesn't pop in/out of `visiblePins` on every sub-pixel pan.
    /// Spec §3.4's own recommendation: "slightly wider than the exact viewport (recommend
    /// 1.5x)".
    static let defaultPaddingFactor: Double = 1.5

    /// True if `(lat, lng)` falls within `region`, expanded by `paddingFactor`.
    ///
    /// Realtime has no server-side bounding-box filter (unlike the REST fetch channels'
    /// `URLQueryItem` bbox) — every INSERT/UPDATE/DELETE on `public.pins` city-wide reaches
    /// every subscribed client (spec §5.1, §8.2 gap #1). This is the client-side stand-in,
    /// gating every event against `CommunityPinService.lastFetchedRegion` before it reaches
    /// the merge core.
    ///
    /// - Parameters:
    ///   - lat: The pin's latitude.
    ///   - lng: The pin's longitude.
    ///   - region: The map region to test against — callers pass the most recently
    ///     REST-fetched viewport (`CommunityPinService.lastFetchedRegion`).
    ///   - paddingFactor: Multiplier applied to `region.span` before testing. `1.0` = the
    ///     exact viewport, `> 1.0` = wider. Defaults to `defaultPaddingFactor`.
    /// - Returns: `true` if the coordinate falls within the padded region's bounding box.
    static func isWithinRegion(
        lat: Double,
        lng: Double,
        region: MKCoordinateRegion,
        paddingFactor: Double = defaultPaddingFactor
    ) -> Bool {
        let halfLat = (region.span.latitudeDelta * paddingFactor) / 2.0
        let halfLng = (region.span.longitudeDelta * paddingFactor) / 2.0

        let swLat = region.center.latitude - halfLat
        let neLat = region.center.latitude + halfLat
        let swLng = region.center.longitude - halfLng
        let neLng = region.center.longitude + halfLng

        return lat >= swLat && lat <= neLat && lng >= swLng && lng <= neLng
    }

    // MARK: - Zone gating (Community 2.0 Phase 1)

    /// True if `pinZoneId` should be admitted under the currently-selected zone filter.
    ///
    /// `selectedZoneId == nil` means "no zone filter active" (e.g. Phase 1 UI — S4 — hasn't
    /// wired a zone chip selection yet, or a future "all zones" view) — every pin passes this
    /// dimension unconditionally, which is exactly this service's behavior before this session
    /// (zero change until a caller actually sets a selected zone).
    ///
    /// A pin with `pinZoneId == nil` (a row whose zone couldn't be resolved, or one that
    /// predates the zone seed) can never match a specific, non-nil `selectedZoneId` — it only
    /// passes when no zone filter is active. This mirrors `isWithinRegion`'s own strict
    /// membership test: a gate that admits "unknown" pins under an active filter would defeat
    /// the point of the filter.
    ///
    /// - Parameters:
    ///   - pinZoneId: The pin's `zone_id` (`CommunityPin.zoneId`).
    ///   - selectedZoneId: The zone currently selected by the crew feed's zone chips
    ///     (`CommunityPinService.selectedZoneId`). `nil` = no filter.
    /// - Returns: `true` if the pin should be admitted under the zone dimension.
    static func isInZone(pinZoneId: String?, selectedZoneId: String?) -> Bool {
        guard let selectedZoneId else { return true }
        return pinZoneId == selectedZoneId
    }
}
