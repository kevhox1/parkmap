//
//  ParkingProximityScorer.swift
//  WePark
//
//  FT-20 Stream B — OQ-4's "parking near here" cheap summary (spec §3.2, §0's OQ-4
//  ruling, design-review finding S2).
//
//  ⚠️ Deliberately factored as its own reusable, UIKit/SwiftUI-view-free type — NOT a
//  one-off view helper — because Kevin's OQ-4 ruling frames this as the first step of an
//  already-specced flagship feature:
//
//    "the way it works in the future is to score parking nearby and direct the driver
//    through the optimal path (to find parking) nearby the target destination... OQ-4's
//    scoring should be factored as reusable logic, not a one-off chip — it is the same
//    scoring the routing feature will need, applied to a point rather than a path."
//
//  That future feature is `docs/smart-parking-route-2.0-concept.md` and patrol mode
//  (`docs/drive-mode-scope-spec.md` W8.5e–i), which ports the PWA's `generateParkingRoute`
//  greedy traversal (`index.html:7038`). Its per-candidate-node scoring step
//  (`scoreEdgeCoverage` in the PWA) needs exactly this: "given a point (or a short street
//  edge) and the currently-loaded segments, how good is parking right around here?" —
//  this type IS that scoring, applied to a single point + radius today. Patrol mode's
//  greedy traversal can call `ParkingProximityScorer.score(near:...)` once per candidate
//  node instead of re-deriving classify-and-bucket from scratch.
//
//  Reuses the exact classify-then-score building blocks already proven elsewhere in this
//  codebase rather than inventing new ones (design-review finding S2's explicit
//  instruction: "reuse the classification from ParkingRulesEngine/CurrentState; don't
//  invent a second one"):
//    - Per-segment classification: `ParkingRulesEngine.currentState(for:at:)` — the same
//      Option B `CurrentState` enum that colors the map and the ASP banner.
//    - Non-parkable skip categories + free/metered score weights: identical to
//      `RouteService.pickBestParkingAwareRoute`'s established skip set and +3/+1 weights
//      (`RouteService.swift:232-233`, `:283-291`) — so a future point-vs-route comparison
//      in patrol mode is apples-to-apples, not two independently-tuned heuristics.
//    - Proximity + block dedup: segment-midpoint `CLLocation.distance(from:)`, the same
//      pattern `pickBestParkingAwareRoute` already uses for its 30m route-sample check
//      (`RouteService.swift:265-276`), and `Segment.blockfaceKey` (`Segment.swift:173`,
//      FT-15's existing direction-agnostic block identity) for dedup rather than
//      reinventing a "street|from|to" key.
//
//  No network call. Scans an already-loaded `[Segment]` array only (e.g.
//  `TileLoader.segments`) — same "cheap, in-memory" framing as spec §3.2.
//

import Foundation
import CoreLocation
import SwiftUI

// MARK: - ParkingProximityBucket

/// The three-way "how's parking around here" bucket for the "place" state's summary line
/// (spec §3.2's wireframe: "Parking near here: mostly free"), plus a fourth case for "no
/// scoreable segments nearby" — callers should render no summary line at all in that case
/// rather than a misleading "no data" line (AC-10 is conditional on having something to say).
///
/// Design-review finding S2 (binding, spec §0b): the bucketed word carries semantic
/// color, reusing the app's existing `ParkingColors` green/amber/red — never new colors.
enum ParkingProximityBucket: Equatable {
    case mostlyFree
    case mixed
    case mostlyRestricted
    case noData

    /// User-facing bucket word — matches the spec's own wireframe/OQ-4 vocabulary
    /// verbatim ("mostly free" / "mixed" / "mostly restricted", spec §0b finding S2).
    var label: String {
        switch self {
        case .mostlyFree:       return "mostly free"
        case .mixed:             return "mixed"
        case .mostlyRestricted: return "mostly restricted"
        case .noData:            return ""
        }
    }

    /// S2: the matching EXISTING `ParkingColors` constant — never a new color. `.noData`
    /// has no color; callers should not render a summary line at all in that case.
    var color: Color? {
        switch self {
        case .mostlyFree:       return ParkingColors.freeComfortably
        case .mixed:             return ParkingColors.meteredActive
        case .mostlyRestricted: return ParkingColors.restricted
        case .noData:            return nil
        }
    }
}

// MARK: - ParkingProximityScore

/// Result of scanning the segments within a radius of a point.
struct ParkingProximityScore: Equatable {
    let freeCount: Int
    let meteredCount: Int
    let restrictedCount: Int
    let bucket: ParkingProximityBucket

    /// Total distinct blockfaces that contributed to the bucket (excludes `.unknown`-state
    /// segments and anything filtered by `ParkingProximityScorer`'s skip-category set).
    var scoredBlockfaceCount: Int { freeCount + meteredCount + restrictedCount }

    /// Same weighting `RouteService.pickBestParkingAwareRoute` scores routes with (free
    /// +3, metered +1, restricted +0) — no duration penalty, since a single point has no
    /// travel time of its own. Exposed so patrol mode's future per-candidate-node scoring
    /// can reuse identical weights rather than re-deriving them.
    var weightedScore: Double {
        Double(freeCount) * 3 + Double(meteredCount) * 1
    }

    /// "Parking near here: mostly free" — nil when there's nothing scoreable nearby (empty
    /// radius scan, or every nearby segment fell in the skip-category set), matching the
    /// "no rendered summary at all" behavior AC-10 implies for that case.
    var summaryLabel: String? {
        bucket == .noData ? nil : bucket.label
    }
}

// MARK: - ParkingProximityScorer

/// Pure, UIKit/SwiftUI-independent scan-and-score logic (SwiftUI is only used for
/// `Color`/`ParkingColors`, never `UIScreen`/`GeometryProxy`/etc.) — fully unit-testable
/// without a simulator.
///
/// ## Bucket boundary contract
///
/// This is a contract, not an implementation detail — build 18's patrol mode
/// (`docs/smart-parking-route-2.0-concept.md`, W8.5e–i) calls `score(near:...)` once per
/// candidate node in its greedy traversal, so the bucket boundaries below need to hold up
/// under arbitrary free/metered/restricted mixes, not just the "typical" ones.
///
/// `.mostlyFree` and `.mostlyRestricted` require a STRICT majority (> 50%) of the scored
/// (non-skip-category, non-`.unknown`) blockfaces. **A tie — exactly 50% — always resolves
/// to `.mixed`, regardless of the other 50%'s makeup.** Reasoned through explicitly:
///
///   - 50% free / 50% restricted (no metered): the textbook tie. Neither fraction exceeds
///     0.5, so `.mixed`. This is the only honest answer — calling it "mostly restricted"
///     (the pre-fix bug: restricted was checked first and `>=` let a 0.5 tie win)
///     talks a driver out of a street where half the curb is genuinely free; calling it
///     "mostly free" overstates how usable the block is.
///   - 50% restricted / remainder split across free + metered (e.g. 50/25/25): restricted
///     fraction is exactly 0.5, not `> 0.5` → `.mixed`. Correct: fully half the block is
///     drivable in some form (free or paid), so "mostly restricted" would be wrong even
///     though restricted is the single largest category.
///   - 50% free / remainder entirely metered (no restricted): free fraction is exactly
///     0.5, not `> 0.5` → `.mixed`. Consistent with the all-metered case below — metered
///     is parkable but not "free," so a 50/50 free/metered split reads as `.mixed` rather
///     than `.mostlyFree`.
///   - 100% metered: neither fraction is ever `> 0.5` (both are 0), so `.mixed` — metered
///     parking is genuinely available, so it must never read as `.mostlyRestricted`, but
///     it isn't literally "free" either. (Pinned by an existing test; unaffected by this
///     boundary fix since 0 was never `>= 0.5` either.)
///   - Because free/metered/restricted fractions of the same total sum to 1, at most one
///     of `freeFraction`/`restrictedFraction` can exceed 0.5 at a time — so the strict
///     `>` check on both branches can never disagree with itself regardless of check order.
///   - `total == 0` (no scoreable segments at all — everything skip-categoried, out of
///     radius, or `.unknown`) is `.noData`, always evaluated before the fraction math and
///     never reachable via any free/metered/restricted ratio. `.noData` must stay distinct
///     from `.mixed`: reporting "mixed" when we simply have no data would claim a
///     three-way split that was never observed.
enum ParkingProximityScorer {

    /// Radius scan default per spec §3.2's OQ-4 cheap version: "radius scan (100m)."
    static let defaultRadiusMeters: CLLocationDistance = 100

    /// Categories that are not parkable faces — identical skip set to
    /// `RouteService.pickBestParkingAwareRoute` (`RouteService.swift:232-233`). A block
    /// face permanently zoned NO_STANDING/NO_PARKING/SPECIAL/TRUCK_LOADING is never a
    /// parking opportunity regardless of the current time, so it's excluded from the
    /// bucket entirely rather than folded into "restricted" — same reasoning the route
    /// scorer already applies, kept consistent here for the reuse case above.
    private static let skipCategories: Set<Category> = [
        .noStanding, .noParking, .special, .truckLoading, .unknown
    ]

    /// Scans `segments` for block faces within `radiusMeters` of `point`, classifies each
    /// via `engine.currentState(for:at:)`, dedupes by `Segment.blockfaceKey`, and buckets
    /// the result into mostly-free / mixed / mostly-restricted / no-data.
    ///
    /// - Parameters:
    ///   - point: The destination (or, for a future patrol-mode caller, a candidate node)
    ///     to scan around.
    ///   - segments: Already-loaded segments (e.g. `TileLoader.segments`) — no network call.
    ///   - engine: The shared `ParkingRulesEngine` instance for classification.
    ///   - radiusMeters: Defaults to `defaultRadiusMeters` (100m per spec §3.2).
    ///   - now: Evaluation timestamp. Defaults to the current Eastern Time.
    static func score(
        near point: CLLocationCoordinate2D,
        segments: [Segment],
        engine: ParkingRulesEngine,
        radiusMeters: CLLocationDistance = defaultRadiusMeters,
        now: Date = .nowET
    ) -> ParkingProximityScore {
        let target = CLLocation(latitude: point.latitude, longitude: point.longitude)

        var seenBlockfaces = Set<String>()
        var freeCount = 0
        var meteredCount = 0
        var restrictedCount = 0

        for segment in segments {
            guard segment.line.count >= 2 else { continue }

            let dominant = segment.dominantCategory ?? .unknown
            if skipCategories.contains(dominant) { continue }

            guard let midpoint = segment.midpoint else { continue }
            let segmentLocation = CLLocation(latitude: midpoint.latitude, longitude: midpoint.longitude)
            guard segmentLocation.distance(from: target) <= radiusMeters else { continue }

            let key = segment.blockfaceKey
            guard !seenBlockfaces.contains(key) else { continue }
            seenBlockfaces.insert(key)

            switch engine.currentState(for: segment, at: now) {
            case .freeComfortably, .freeButRestrictionSoon:
                // A restriction starting within the next few hours is still parkable
                // RIGHT NOW — the same "free-equivalent" treatment
                // `RouteService.pickBestParkingAwareRoute` gives `.comingSoon` via
                // `safetyLabel`'s severity (free score bucket), kept consistent here.
                freeCount += 1
            case .meteredActive:
                meteredCount += 1
            case .restrictedNow:
                restrictedCount += 1
            case .unknown:
                // No rules data for this segment — excluded from the denominator rather
                // than guessed at.
                break
            }
        }

        let total = freeCount + meteredCount + restrictedCount
        let bucket: ParkingProximityBucket
        if total == 0 {
            bucket = .noData
        } else {
            let restrictedFraction = Double(restrictedCount) / Double(total)
            let freeFraction = Double(freeCount) / Double(total)
            // Tie-break rule (see the doc comment on `ParkingProximityScorer` for the
            // full case-by-case reasoning): a bucket only tips to an extreme on a STRICT
            // majority (> 0.5). An exact 50% split — in either direction, with any
            // makeup of the other 50% — lands in `.mixed`. Reporting a tied split as
            // leaning either way is actively misleading in both directions: calling an
            // exact 50/50 free/restricted split "mostly restricted" talks a driver out
            // of a street where half the curb is genuinely free; calling it "mostly
            // free" overstates how much of the curb is actually usable. `.mixed` is the
            // only honest answer at the boundary.
            if restrictedFraction > 0.5 {
                bucket = .mostlyRestricted
            } else if freeFraction > 0.5 {
                bucket = .mostlyFree
            } else {
                bucket = .mixed
            }
        }

        return ParkingProximityScore(
            freeCount: freeCount,
            meteredCount: meteredCount,
            restrictedCount: restrictedCount,
            bucket: bucket
        )
    }
}
