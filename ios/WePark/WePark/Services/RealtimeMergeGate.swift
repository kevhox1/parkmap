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
}
