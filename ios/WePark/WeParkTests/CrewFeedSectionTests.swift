//
//  CrewFeedSectionTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 1 — crew feed UI layer (build 20, session S4).
//  Spec: docs/community-2.0-reconciliation-spec.md §1 delta table ("Crew feed"), §3 Phase 1,
//  §6 (verbatim design values). Covers `Views/CrewFeedSection.swift`'s pure, view-free
//  `CrewFeedMerge` logic + `CommunityZone` — everything testable without hosting a SwiftUI
//  view, per this session's dispatch instructions.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge, matching every other
//  Community 2.0 file's posture.
//
//  No Calendar.current use. No hardcoded Mapbox tokens or Supabase keys.
//

import XCTest
import SwiftUI
@testable import WePark

// MARK: - Fixture helpers

/// Same ISO8601-with-fractional-seconds-then-plain decoder strategy used throughout the
/// Community 2.0 test files (`Community2Phase1ModelTests.c2Decoder()`,
/// `ZoneMessageServiceTests.zoneMessageDecoder()`), duplicated locally per this repo's
/// file-independence convention.
private func crewFeedDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatters: [ISO8601DateFormatter] = {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return [withFraction, plain]
        }()
        for formatter in formatters {
            if let date = formatter.date(from: string) { return date }
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Cannot decode date: \(string)")
        )
    }
    return decoder
}

/// Builds one `pins_with_author`-shaped `CommunityPin` fixture, following the existing
/// `c2PinFixture`/`ft15PinFixture` convention (JSON-decode, not memberwise init, so tests
/// exercise the real `Codable` contract) — scoped locally to this file.
private func crewFeedPinFixture(
    id: String = "10000000-0000-0000-0000-000000000001",
    pinType: String = "enforcement_active",
    zoneId: String? = "nolita",
    lat: Double = 40.7230,
    lng: Double = -73.9950,
    segmentId: String? = "MOTT ST|PRINCE ST|SPRING ST|E",
    authorId: String? = "A0000000-0000-0000-0000-000000000001",
    authorUsername: String? = "MulberryMike",
    createdAt: String = "2026-08-27T09:00:00+00:00",
    confirmCount: Int = 0,
    claimedBy: String? = nil
) -> CommunityPin {
    let json = """
    {
      "id": "\(id)",
      "pin_type": "\(pinType)",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": \(lat),
      "lng": \(lng),
      "segment_id": \(segmentId.map { "\"\($0)\"" } ?? "null"),
      "zone_id": \(zoneId.map { "\"\($0)\"" } ?? "null"),
      "author_id": \(authorId.map { "\"\($0)\"" } ?? "null"),
      "author_username": \(authorUsername.map { "\"\($0)\"" } ?? "null"),
      "created_at": "\(createdAt)",
      "updated_at": "\(createdAt)",
      "expires_at": null,
      "resolved_at": null,
      "confirm_count": \(confirmCount),
      "dispute_count": 0,
      "meta": null,
      "notes": null,
      "claimed_by": \(claimedBy.map { "\"\($0)\"" } ?? "null")
    }
    """.data(using: .utf8)!
    // Force-unwrap acceptable in tests (fixture-authoring error should fail loudly).
    return try! crewFeedDecoder().decode(CommunityPin.self, from: json)
}

/// Builds one `zone_messages_with_author`-shaped `ZoneMessage` fixture.
private func crewFeedMessageFixture(
    id: Int = 1,
    zoneId: String = "nolita",
    authorId: String? = "B0000000-0000-0000-0000-000000000001",
    authorUsername: String? = "Springy",
    body: String = "Anyone still on Mott?",
    createdAt: String = "2026-08-27T09:00:00+00:00"
) -> ZoneMessage {
    let json = """
    {
      "id": \(id),
      "zone_id": "\(zoneId)",
      "author_id": \(authorId.map { "\"\($0)\"" } ?? "null"),
      "message_type": "user",
      "body": "\(body)",
      "related_report_id": null,
      "created_at": "\(createdAt)",
      "author_username": \(authorUsername.map { "\"\($0)\"" } ?? "null"),
      "author_reputation": 12,
      "segment_id": null
    }
    """.data(using: .utf8)!
    return try! crewFeedDecoder().decode(ZoneMessage.self, from: json)
}

private let kCrewFeedEpoch = Date(timeIntervalSince1970: 1_756_281_600) // 2025-08-27T00:00:00Z-ish; exact value irrelevant, just fixed.

// MARK: - CommunityZone

final class CommunityZoneTests: XCTestCase {

    func testRawValues_matchZoneTableIds() {
        // Spec §2.3: exact `public.zones.id` values — never translated client-side.
        XCTAssertEqual(CommunityZone.nolita.rawValue, "nolita")
        XCTAssertEqual(CommunityZone.soho.rawValue, "soho")
        XCTAssertEqual(CommunityZone.les.rawValue, "les")
    }

    func testDisplayNames_matchPrototypeChipLabels() {
        XCTAssertEqual(CommunityZone.nolita.displayName, "Nolita")
        XCTAssertEqual(CommunityZone.soho.displayName, "SoHo")
        XCTAssertEqual(CommunityZone.les.displayName, "LES")
    }

    func testAllCases_exactlyThreeZones() {
        XCTAssertEqual(CommunityZone.allCases.count, 3)
    }
}

// MARK: - CrewFeedMerge.merge — ordering + zone filtering

final class CrewFeedMergeOrderingTests: XCTestCase {

    func testMerge_interleavesMessagesAndPins_newestFirst() {
        let oldPin = crewFeedPinFixture(id: "10000000-0000-0000-0000-000000000001",
                                         createdAt: "2026-08-27T09:00:00+00:00")
        let midMessage = crewFeedMessageFixture(id: 1, createdAt: "2026-08-27T09:05:00+00:00")
        let newPin = crewFeedPinFixture(id: "10000000-0000-0000-0000-000000000002",
                                         createdAt: "2026-08-27T09:10:00+00:00")

        let feed = CrewFeedMerge.merge(messages: [midMessage], pins: [oldPin, newPin], zoneId: "nolita")

        XCTAssertEqual(feed.map(\.id), [
            "pin-\(newPin.id.uuidString)",
            "chat-\(midMessage.id)",
            "pin-\(oldPin.id.uuidString)",
        ])
    }

    func testMerge_filtersOutMessagesFromOtherZones() {
        let inZone = crewFeedMessageFixture(id: 1, zoneId: "nolita")
        let outOfZone = crewFeedMessageFixture(id: 2, zoneId: "soho")

        let feed = CrewFeedMerge.merge(messages: [inZone, outOfZone], pins: [], zoneId: "nolita")

        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed.first?.id, "chat-1")
    }

    func testMerge_filtersOutPinsFromOtherZones() {
        let inZone = crewFeedPinFixture(id: "10000000-0000-0000-0000-000000000001", zoneId: "nolita")
        let outOfZone = crewFeedPinFixture(id: "10000000-0000-0000-0000-000000000002", zoneId: "les")

        let feed = CrewFeedMerge.merge(messages: [], pins: [inZone, outOfZone], zoneId: "nolita")

        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed.first?.id, "pin-10000000-0000-0000-0000-000000000001")
    }

    /// S4 QA pass 1, PR #94 Finding #3 fix: a `nil`-`zone_id` pin is NO LONGER unconditionally
    /// excluded — `CrewFeedMerge.resolvedZoneId(for:)` falls back to a `CommunityZoneBounds`
    /// lookup by `(lat, lng)`. The fixture's default coordinate (40.7230, -73.9950) falls
    /// inside nolita's bounding box, so a `nil`-zone pin there now correctly surfaces in the
    /// nolita feed — this is the whole point of the fix (pre-existing enforcement/sweeper
    /// pins, which no write path stamps with a zone, must still be visible).
    func testMerge_pinWithNilZone_includedViaBoundingBoxFallback() {
        let noZonePin = crewFeedPinFixture(zoneId: nil) // default lat/lng is inside nolita's box

        let feed = CrewFeedMerge.merge(messages: [], pins: [noZonePin], zoneId: "nolita")

        XCTAssertEqual(feed.count, 1)
    }

    /// A `nil`-`zone_id` pin whose coordinate falls OUTSIDE all three known bounding boxes
    /// is still excluded — the fallback only ever ADMITS a pin into a zone it can actually
    /// place, it never admits one into every zone indiscriminately.
    func testMerge_pinWithNilZone_outsideAllBoxes_stillExcluded() {
        let farAwayPin = crewFeedPinFixture(zoneId: nil, lat: 40.70, lng: -74.02)

        let feed = CrewFeedMerge.merge(messages: [], pins: [farAwayPin], zoneId: "nolita")

        XCTAssertTrue(feed.isEmpty)
    }

    func testMerge_emptyInputs_returnsEmptyArray() {
        XCTAssertTrue(CrewFeedMerge.merge(messages: [], pins: [], zoneId: "nolita").isEmpty)
    }
}

// MARK: - CommunityZoneBounds / CrewFeedMerge.resolvedZoneId (S4 QA pass 1 Finding #3 fix)

final class CommunityZoneBoundsTests: XCTestCase {

    func testZoneId_pointInsideNolita_returnsNolita() {
        XCTAssertEqual(CommunityZoneBounds.zoneId(forLat: 40.7230, lng: -73.9950), "nolita")
    }

    func testZoneId_pointInsideSoho_returnsSoho() {
        XCTAssertEqual(CommunityZoneBounds.zoneId(forLat: 40.7225, lng: -74.0000), "soho")
    }

    func testZoneId_pointInsideLes_returnsLes() {
        XCTAssertEqual(CommunityZoneBounds.zoneId(forLat: 40.7200, lng: -73.9850), "les")
    }

    func testZoneId_pointOutsideAllBoxes_returnsNil() {
        XCTAssertNil(CommunityZoneBounds.zoneId(forLat: 40.70, lng: -74.02))
    }

    /// Boundary inclusivity — the applied migration's ranges are closed intervals
    /// (`gte`/`lte`-equivalent), matching `RealtimeMergeGate.isWithinRegion`'s own
    /// inclusive-bounds convention.
    func testZoneId_exactBoundaryCoordinate_included() {
        XCTAssertEqual(CommunityZoneBounds.zoneId(forLat: 40.7217, lng: -73.9967), "nolita")
    }
}

final class CrewFeedMergeResolvedZoneIdTests: XCTestCase {

    func testResolvedZoneId_pinHasExplicitZoneId_usedDirectly_boundingBoxIgnored() {
        // zoneId "les" explicit, but the coordinate is inside nolita's box — the explicit
        // value must win; the bounding-box fallback is nil-zone-only.
        let pin = crewFeedPinFixture(zoneId: "les", lat: 40.7230, lng: -73.9950)
        XCTAssertEqual(CrewFeedMerge.resolvedZoneId(for: pin), "les")
    }

    func testResolvedZoneId_nilZoneId_fallsBackToBoundingBox() {
        let pin = crewFeedPinFixture(zoneId: nil, lat: 40.7200, lng: -73.9850) // inside les
        XCTAssertEqual(CrewFeedMerge.resolvedZoneId(for: pin), "les")
    }

    func testResolvedZoneId_nilZoneId_outsideAllBoxes_returnsNil() {
        let pin = crewFeedPinFixture(zoneId: nil, lat: 40.70, lng: -74.02)
        XCTAssertNil(CrewFeedMerge.resolvedZoneId(for: pin))
    }
}

// MARK: - CrewFeedMerge.showsEmptyState

final class CrewFeedMergeEmptyStateTests: XCTestCase {

    func testShowsEmptyState_trueWhenFeedEmptyAndNotLoading() {
        XCTAssertTrue(CrewFeedMerge.showsEmptyState(feed: [], isLoadingMessages: false))
    }

    func testShowsEmptyState_falseWhileLoadingEvenIfFeedEmpty() {
        // AC-P1.2/AC-P1.4: don't flash the empty state mid-fetch — that's a loading state,
        // not "genuinely nothing here."
        XCTAssertFalse(CrewFeedMerge.showsEmptyState(feed: [], isLoadingMessages: true))
    }

    func testShowsEmptyState_falseWhenFeedNonEmpty() {
        let feed = [CrewFeedItem.pin(crewFeedPinFixture())]
        XCTAssertFalse(CrewFeedMerge.showsEmptyState(feed: feed, isLoadingMessages: false))
    }
}

// MARK: - CrewFeedMerge — pin row formatting

final class CrewFeedMergeRowFormattingTests: XCTestCase {

    func testCrossStreets_fourPartSegmentId_parsesLowHigh() {
        let pin = crewFeedPinFixture(segmentId: "MOTT ST|PRINCE ST|SPRING ST|E")
        let cross = CrewFeedMerge.crossStreets(for: pin)
        XCTAssertEqual(cross?.from, "PRINCE ST")
        XCTAssertEqual(cross?.to, "SPRING ST")
    }

    func testCrossStreets_rawTileSegmentId_returnsNil() {
        // Raw tile `segment.id` shape (Views/ReportSheet.swift's `segment?.id` call site) —
        // underscore-joined, not pipe-delimited. Must degrade to nil, not mis-parse.
        let pin = crewFeedPinFixture(segmentId: "SOUTH_STREET_WHITEHALL_STREET_OLD_SLIP_E_9")
        XCTAssertNil(CrewFeedMerge.crossStreets(for: pin))
    }

    func testCrossStreets_nilSegmentId_returnsNil() {
        let pin = crewFeedPinFixture(segmentId: nil)
        XCTAssertNil(CrewFeedMerge.crossStreets(for: pin))
    }

    func testTitle_fourPartSegmentId_includesStreet() {
        let pin = crewFeedPinFixture(pinType: "enforcement_active", segmentId: "MOTT ST|PRINCE ST|SPRING ST|E")
        XCTAssertEqual(CrewFeedMerge.title(for: pin), "Enforcement Active — MOTT ST")
    }

    func testTitle_noSegmentId_fallsBackToDisplayLabel() {
        let pin = crewFeedPinFixture(pinType: "sweeper_passed", segmentId: nil)
        XCTAssertEqual(CrewFeedMerge.title(for: pin), "Sweeper Passed")
    }

    func testTitle_rawTileSegmentId_fallsBackToDisplayLabel() {
        let pin = crewFeedPinFixture(pinType: "open_spot", segmentId: "SOUTH_STREET_WHITEHALL_STREET_OLD_SLIP_E_9")
        XCTAssertEqual(CrewFeedMerge.title(for: pin), "Open Spot")
    }

    func testSubLinePin_withCrossStreets_includesBtwnClauseAndAge() {
        let pin = crewFeedPinFixture(
            segmentId: "MOTT ST|PRINCE ST|SPRING ST|E",
            authorUsername: "MulberryMike",
            createdAt: iso(kCrewFeedEpoch.addingTimeInterval(-300))
        )
        let sub = CrewFeedMerge.subLine(for: pin, now: kCrewFeedEpoch)
        XCTAssertEqual(sub, "btwn PRINCE ST & SPRING ST · 5m ago · MulberryMike")
    }

    func testSubLinePin_withoutCrossStreets_omitsBtwnClause() {
        let pin = crewFeedPinFixture(
            segmentId: nil,
            authorUsername: "MulberryMike",
            createdAt: iso(kCrewFeedEpoch.addingTimeInterval(-30))
        )
        let sub = CrewFeedMerge.subLine(for: pin, now: kCrewFeedEpoch)
        XCTAssertEqual(sub, "Just now · MulberryMike")
    }

    func testSubLinePin_nilAuthorUsername_fallsBackToNeighbor() {
        let pin = crewFeedPinFixture(segmentId: nil, authorId: nil, authorUsername: nil,
                                      createdAt: iso(kCrewFeedEpoch))
        let sub = CrewFeedMerge.subLine(for: pin, now: kCrewFeedEpoch)
        XCTAssertEqual(sub, "Just now · Neighbor")
    }

    func testSubLineMessage_includesAuthorAndAge() {
        let message = crewFeedMessageFixture(
            authorUsername: "Springy",
            createdAt: iso(kCrewFeedEpoch.addingTimeInterval(-120))
        )
        XCTAssertEqual(CrewFeedMerge.subLine(for: message, now: kCrewFeedEpoch), "Springy · 2m ago")
    }

    func testConfirmBadge_zeroConfirms_returnsNil() {
        let pin = crewFeedPinFixture(confirmCount: 0)
        XCTAssertNil(CrewFeedMerge.confirmBadge(for: pin))
    }

    func testConfirmBadge_nonZero_returnsCheckmarkFormat() {
        let pin = crewFeedPinFixture(confirmCount: 3)
        XCTAssertEqual(CrewFeedMerge.confirmBadge(for: pin), "✓ 3")
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - CrewFeedMerge.icon — spec §6 appendix verbatim values

final class CrewFeedMergeIconTests: XCTestCase {

    func testIcon_enforcementActive_matchesSpecAppendix() {
        let icon = CrewFeedMerge.icon(for: .enforcementActive)
        XCTAssertEqual(icon.glyph, "🎫")
        XCTAssertEqual(icon.color, hexColor(0xFF9F0A))
    }

    func testIcon_sweeperPassed_matchesSpecAppendix() {
        let icon = CrewFeedMerge.icon(for: .sweeperPassed)
        XCTAssertEqual(icon.glyph, "🧹")
        XCTAssertEqual(icon.color, hexColor(0x30D158))
    }

    func testIcon_openSpot_matchesSpecAppendix() {
        let icon = CrewFeedMerge.icon(for: .openSpot)
        XCTAssertEqual(icon.glyph, "P")
        XCTAssertEqual(icon.color, hexColor(0x0A84FF))
    }

    func testIcon_leavingSoon_matchesSpecAppendix() {
        let icon = CrewFeedMerge.icon(for: .leavingSoon)
        XCTAssertEqual(icon.glyph, "🚙")
        XCTAssertEqual(icon.color, hexColor(0x0A84FF))
    }

    func testIcon_construction_matchesSpecAppendix() {
        let icon = CrewFeedMerge.icon(for: .construction)
        XCTAssertEqual(icon.glyph, "🚧")
        XCTAssertEqual(icon.color, hexColor(0xE8730D))
    }

    func testIcon_blockNote_matchesSpecAppendix() {
        let icon = CrewFeedMerge.icon(for: .blockNote)
        XCTAssertEqual(icon.glyph, "📌")
        XCTAssertEqual(icon.color, hexColor(0x9BA1AF))
    }

    func testIcon_unexpectedType_returnsNonCrashingFallback() {
        // special_event is not expected in the crew feed, but the switch must stay
        // exhaustive-safe — never fail to render a row.
        let icon = CrewFeedMerge.icon(for: .specialEvent)
        XCTAssertFalse(icon.glyph.isEmpty)
    }

    private func hexColor(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - CrewFeedMerge.distinctContributorCount

final class CrewFeedMergeContributorCountTests: XCTestCase {

    func testDistinctContributorCount_countsUniqueAuthorsAcrossMessagesAndPins() {
        let message1 = crewFeedMessageFixture(id: 1, authorId: "A0000000-0000-0000-0000-000000000001")
        let message2 = crewFeedMessageFixture(id: 2, authorId: "A0000000-0000-0000-0000-000000000002")
        let pin1 = crewFeedPinFixture(id: "10000000-0000-0000-0000-000000000001",
                                       authorId: "A0000000-0000-0000-0000-000000000001") // same as message1
        let pin2 = crewFeedPinFixture(id: "10000000-0000-0000-0000-000000000002",
                                       authorId: "A0000000-0000-0000-0000-000000000003")

        let count = CrewFeedMerge.distinctContributorCount(messages: [message1, message2], pins: [pin1, pin2])

        XCTAssertEqual(count, 3) // .001, .002, .003 — pin1 dedupes against message1's author
    }

    func testDistinctContributorCount_ignoresNilAuthors() {
        let message = crewFeedMessageFixture(authorId: nil)
        let pin = crewFeedPinFixture(authorId: nil)

        XCTAssertEqual(CrewFeedMerge.distinctContributorCount(messages: [message], pins: [pin]), 0)
    }

    func testDistinctContributorCount_emptyInputs_isZero() {
        XCTAssertEqual(CrewFeedMerge.distinctContributorCount(messages: [], pins: []), 0)
    }
}

// MARK: - PinMarkerAnnotation.ageString (S4 extraction — age-formatting helper)

final class PinMarkerAnnotationAgeStringTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 2_000_000)

    func testAgeString_under60Seconds_returnsJustNow() {
        XCTAssertEqual(PinMarkerAnnotation.ageString(since: epoch.addingTimeInterval(-45), now: epoch), "Just now")
    }

    func testAgeString_5Minutes_returnsMinutesAgo() {
        XCTAssertEqual(PinMarkerAnnotation.ageString(since: epoch.addingTimeInterval(-300), now: epoch), "5m ago")
    }

    func testAgeString_exactly60Minutes_returnsOneHourAgo() {
        XCTAssertEqual(PinMarkerAnnotation.ageString(since: epoch.addingTimeInterval(-3600), now: epoch), "1h ago")
    }

    func testAgeString_3Hours_returnsHoursAgo() {
        XCTAssertEqual(PinMarkerAnnotation.ageString(since: epoch.addingTimeInterval(-10_800), now: epoch), "3h ago")
    }

    func testTimeSinceBadge_delegatesToAgeString_forPinCreatedAt() {
        let pin = crewFeedPinFixture(createdAt: iso(epoch.addingTimeInterval(-120)))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "2m ago")
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
