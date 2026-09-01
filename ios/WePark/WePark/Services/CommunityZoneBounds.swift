//
//  CommunityZoneBounds.swift
//  WePark
//
//  Community 2.0 — client-side zone bounding-box lookup.
//
//  MOVED from Views/CrewFeedSection.swift (Phase 2a / build 20 S6) — a Views file being the
//  only definition site for a pure geometry lookup meant a Services-layer consumer
//  (`CommunityPinService.insertCrowdPin`, this session's write-time zone stamping) would have
//  had to import a View file to reuse it. Same type, same values, same API — this is a pure
//  relocation, not a behavior change. `Views/CrewFeedSection.swift`'s own
//  `CrewFeedMerge.resolvedZoneId(for:)` call site is unaffected (Swift name resolution doesn't
//  care which file a top-level type lives in within the same module).
//
//  Spec: docs/community-2.0-reconciliation-spec.md §1 delta table ("Zone chips"), §2.3
//  (zones), roadmap S6 row ("stamp zone_id server-side on insertCrowdPin").
//

/// Client-side bounding-box lookup for a `(lat, lng)` coordinate against the three Community
/// 2.0 zones (Nolita/SoHo/LES).
///
/// Two consumers as of Phase 2a:
///  1. `CrewFeedMerge.resolvedZoneId(for:)` (`Views/CrewFeedSection.swift`) — DISPLAY-time
///     fallback for pins whose `zone_id` column is `nil` (every pin written before this
///     session's write-time stamping landed, or any future write path that still omits it).
///  2. `CommunityPinService.insertCrowdPin` (this session) — WRITE-time stamping: a caller
///     that doesn't pass an explicit `zoneId` gets one derived from the pin's own lat/lng at
///     insert time, so `pins.zone_id` is populated going forward instead of relying on the
///     display-only fallback forever (roadmap S6: "that's a display-only patch, not a cure").
///
/// Values copied VERBATIM from `supabase/03-community-2.0-schema.sql`'s applied seed rows
/// (§2.3, including the QA-pass-1-corrected `soho` `lat_max`, 40.7237 not the stale 40.7280) —
/// if that migration is ever retuned, this table must be updated in the same commit or this
/// fallback silently drifts from the real zone boundaries.
///
/// `nonisolated` is implicit here (no actor context, no mutable state) — safe to call from
/// any isolation context, including `CommunityPinService`'s `@MainActor` write path and plain
/// unit tests.
enum CommunityZoneBounds {
    /// (zoneId, latMin, latMax, lngMin, lngMax) — order doesn't matter for lookup (the
    /// three boxes don't overlap in the applied migration), but is kept in the same
    /// nolita/soho/les order as the seed SQL for easy side-by-side comparison.
    private static let boxes: [(zoneId: String, latMin: Double, latMax: Double, lngMin: Double, lngMax: Double)] = [
        ("nolita", 40.7217, 40.7256, -73.9967, -73.9930),
        ("soho",   40.7220, 40.7237, -74.0050, -73.9970),
        ("les",    40.7145, 40.7230, -73.9920, -73.9800),
    ]

    /// Returns the zone id whose bounding box contains `(lat, lng)`, or `nil` if none does
    /// (e.g. a coordinate outside all three Phase 1 zones — the legacy `soho-les` box has
    /// no bounds recorded here since it's a retired, chat-history-only id, spec §2.3).
    static func zoneId(forLat lat: Double, lng: Double) -> String? {
        boxes.first { lat >= $0.latMin && lat <= $0.latMax && lng >= $0.lngMin && lng <= $0.lngMax }?.zoneId
    }

    /// Community 2.0 Phase 3 (build 20 S9) — the reverse lookup: given a zone id, return its
    /// bounding box. New consumer: `CommunityPinService.fetchLeaderboardPins(zoneId:)`, which
    /// needs to filter a one-shot REST fetch to one zone's geography (the leaderboard query is
    /// a trailing-7-day historical fetch, not the viewport-scoped `visiblePins` pipeline — see
    /// that method's doc comment for why it can't reuse the existing channels). `nil` for any
    /// id not in `boxes` (e.g. the retired `soho-les` id, or a typo). `nonisolated` explicit
    /// (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — a pure, stateless lookup like
    /// this one must stay callable from a plain synchronous XCTestCase without `await`).
    nonisolated static func box(for zoneId: String) -> (latMin: Double, latMax: Double, lngMin: Double, lngMax: Double)? {
        guard let match = boxes.first(where: { $0.zoneId == zoneId }) else { return nil }
        return (match.latMin, match.latMax, match.lngMin, match.lngMax)
    }
}
