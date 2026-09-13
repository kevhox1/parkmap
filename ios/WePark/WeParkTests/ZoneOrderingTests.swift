//
//  ZoneOrderingTests.swift
//  WeParkTests
//
//  Community 2.0 S14 — pure-logic tests for `ZoneOrdering` and `ZoneSelectionDefaulting`
//  (`Services/ZoneStore.swift`), backing the nearest-first zone-chip picker.
//  Spec: docs/community-2.0-s14-execution-spec.md §3.4, §6.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (13 tests):
//    ZoneOrdering.orderedZones:
//      1. testOrderedZones_homeZonePinnedFirst_evenUnderDistanceTie
//      2. testOrderedZones_ascendingDistanceSanityCheck
//      3. testOrderedZones_areaTieBreak_noHomeZone
//      4. testOrderedZones_noOrigin_alphabeticalFallback
//      5. testOrderedZones_homeZoneNotInList_noCrash_distanceOrderingStillApplies
//    ZoneOrdering.visibleChipZones:
//      6. testVisibleChipZones_appendsOutOfWindowSelectedZone
//      7. testVisibleChipZones_selectedZoneAlreadyInWindow_noDuplicate
//      8. testVisibleChipZones_noSelection_needsNoAppend
//      9. testVisibleChipZones_countBelowLimit_needsNoMoreChip (byte-identical-at-3-zones proof)
//    ZoneSelectionDefaulting.defaultSelection:
//     10. testDefaultSelection_keepsStillValidSelection
//     11. testDefaultSelection_reDefaultsWhenSelectionVanished
//     12. testDefaultSelection_nilCurrentSelection_defaultsToFirst
//     13. testDefaultSelection_emptyOrderedZones_returnsNil
//
//  No Calendar.current use. No hardcoded Mapbox/Supabase secrets.
//

import XCTest
@testable import WePark

// MARK: - Fixtures

private let nolita = Zone(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930)
private let soho   = Zone(id: "soho",   name: "SoHo",   latMin: 40.7220, latMax: 40.7237, lngMin: -74.0050, lngMax: -73.9970)
private let les    = Zone(id: "les",    name: "LES",    latMin: 40.7145, latMax: 40.7230, lngMin: -73.9920, lngMax: -73.9800)
private let threeZoneFixture = [nolita, soho, les]

/// A synthetic 9-zone fixture — one more than the picker's 8-chip visible limit — for
/// exercising `visibleChipZones`'s "More" threshold in the affirmative case.
private func makeNineZoneFixture() -> [Zone] {
    (1...9).map { i in
        Zone(id: "zone-\(i)", name: "Zone \(i)",
             latMin: 40.70 + Double(i) * 0.01, latMax: 40.705 + Double(i) * 0.01,
             lngMin: -74.00 + Double(i) * 0.01, lngMax: -73.995 + Double(i) * 0.01)
    }
}

// MARK: - ZoneOrdering.orderedZones

final class ZoneOrderingOrderedZonesTests: XCTestCase {

    /// Home zone pinned first UNCONDITIONALLY — not merely a distance-0 tie. A device
    /// location exactly at the origin used for distance calc would tie nolita/soho/les at
    /// their respective nearest-edge distances; home-zone pinning must win regardless of
    /// where that tie falls.
    func testOrderedZones_homeZonePinnedFirst_evenUnderDistanceTie() {
        // Origin inside "les" (nearest by distance) but home zone is explicitly "soho" —
        // home must still be first.
        let ordered = ZoneOrdering.orderedZones(
            zones: threeZoneFixture,
            homeZoneId: "soho",
            originLat: 40.7200, originLng: -73.9850
        )
        XCTAssertEqual(ordered.first?.id, "soho")
    }

    /// No home zone set — plain ascending distance from the origin.
    func testOrderedZones_ascendingDistanceSanityCheck() {
        // Origin inside "les" — les should sort first (distance 0), the other two after.
        let ordered = ZoneOrdering.orderedZones(
            zones: threeZoneFixture,
            homeZoneId: nil,
            originLat: 40.7200, originLng: -73.9850
        )
        XCTAssertEqual(ordered.first?.id, "les")
    }

    /// No home zone, and the origin sits inside two overlapping zones (both distance 0) —
    /// smallest-area zone must sort first, same tie-break rationale as `ZoneGeometry.zoneId`.
    func testOrderedZones_areaTieBreak_noHomeZone() {
        let bigZone = Zone(id: "big", name: "Big", latMin: 40.70, latMax: 40.75, lngMin: -74.02, lngMax: -73.95)
        let smallZone = Zone(id: "small", name: "Small", latMin: 40.715, latMax: 40.725, lngMin: -73.99, lngMax: -73.97)
        let ordered = ZoneOrdering.orderedZones(
            zones: [bigZone, smallZone],
            homeZoneId: nil,
            originLat: 40.72, originLng: -73.98
        )
        XCTAssertEqual(ordered.first?.id, "small")
    }

    /// No origin at all (no car, no device location) — falls back to alphabetical by name, a
    /// stable order, never raw fetch-order id soup.
    func testOrderedZones_noOrigin_alphabeticalFallback() {
        let ordered = ZoneOrdering.orderedZones(
            zones: threeZoneFixture,
            homeZoneId: nil,
            originLat: nil, originLng: nil
        )
        XCTAssertEqual(ordered.map(\.name), ["LES", "Nolita", "SoHo"])
    }

    /// A `homeZoneId` that doesn't match any zone in `zones` (e.g. a stale value from before a
    /// fetch settled) must never crash — ordering proceeds normally by distance.
    func testOrderedZones_homeZoneNotInList_noCrash_distanceOrderingStillApplies() {
        let ordered = ZoneOrdering.orderedZones(
            zones: threeZoneFixture,
            homeZoneId: "not-a-real-zone",
            originLat: 40.7200, originLng: -73.9850
        )
        XCTAssertEqual(ordered.first?.id, "les")
        XCTAssertEqual(ordered.count, 3)
    }
}

// MARK: - ZoneOrdering.visibleChipZones

final class ZoneOrderingVisibleChipZonesTests: XCTestCase {

    func testVisibleChipZones_appendsOutOfWindowSelectedZone() {
        let nine = makeNineZoneFixture()
        // "zone-9" is outside the top-8 window but is the current selection — must still
        // appear (appended), so the user never sees their own pick vanish from the row.
        let visible = ZoneOrdering.visibleChipZones(ordered: nine, selectedZoneId: "zone-9", limit: 8)
        XCTAssertEqual(visible.count, 9)
        XCTAssertTrue(visible.contains { $0.id == "zone-9" })
    }

    func testVisibleChipZones_selectedZoneAlreadyInWindow_noDuplicate() {
        let nine = makeNineZoneFixture()
        let visible = ZoneOrdering.visibleChipZones(ordered: nine, selectedZoneId: "zone-1", limit: 8)
        XCTAssertEqual(visible.count, 8, "already-visible selection must not be duplicated")
    }

    func testVisibleChipZones_noSelection_needsNoAppend() {
        let nine = makeNineZoneFixture()
        let visible = ZoneOrdering.visibleChipZones(ordered: nine, selectedZoneId: nil, limit: 8)
        XCTAssertEqual(visible.count, 8)
    }

    /// Byte-identical-at-3-zones proof: with today's 3-row table, `zones.count <= limit`
    /// always, so the "More" chip's own `zoneStore.zones.count > limit` gate (evaluated by the
    /// view, not this function) never fires — `visibleChipZones` itself just returns
    /// everything, unchanged UX from the fixed 3-chip row.
    func testVisibleChipZones_countBelowLimit_needsNoMoreChip() {
        let ordered = ZoneOrdering.orderedZones(zones: threeZoneFixture, homeZoneId: nil, originLat: nil, originLng: nil)
        let visible = ZoneOrdering.visibleChipZones(ordered: ordered, selectedZoneId: nil, limit: 8)
        XCTAssertEqual(visible.count, 3)
        XCTAssertEqual(Set(visible.map(\.id)), Set(threeZoneFixture.map(\.id)))
    }
}

// MARK: - ZoneSelectionDefaulting

final class ZoneSelectionDefaultingTests: XCTestCase {

    func testDefaultSelection_keepsStillValidSelection() {
        let ordered = ZoneOrdering.orderedZones(zones: threeZoneFixture, homeZoneId: nil, originLat: nil, originLng: nil)
        let result = ZoneSelectionDefaulting.defaultSelection(currentSelection: "soho", orderedZones: ordered)
        XCTAssertEqual(result, "soho", "a still-valid selection must never be yanked out from under the user")
    }

    /// The current selection id vanished from a fresh fetch (e.g. a retired id) — re-defaults
    /// to the ordered list's first entry.
    func testDefaultSelection_reDefaultsWhenSelectionVanished() {
        let ordered = ZoneOrdering.orderedZones(zones: threeZoneFixture, homeZoneId: nil, originLat: nil, originLng: nil)
        let result = ZoneSelectionDefaulting.defaultSelection(currentSelection: "soho-les", orderedZones: ordered)
        XCTAssertEqual(result, ordered.first?.id)
    }

    func testDefaultSelection_nilCurrentSelection_defaultsToFirst() {
        let ordered = ZoneOrdering.orderedZones(zones: threeZoneFixture, homeZoneId: "les", originLat: nil, originLng: nil)
        let result = ZoneSelectionDefaulting.defaultSelection(currentSelection: nil, orderedZones: ordered)
        XCTAssertEqual(result, "les")
    }

    /// First-launch-and-offline edge case (no cache, fetch failed): `orderedZones` is empty —
    /// must resolve to `nil`, never crash.
    func testDefaultSelection_emptyOrderedZones_returnsNil() {
        let result = ZoneSelectionDefaulting.defaultSelection(currentSelection: nil, orderedZones: [])
        XCTAssertNil(result)
    }
}
