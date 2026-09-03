//
//  PushRegistrationServiceTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 4b — iOS side (build 20, S12).
//  Spec: docs/community-2.0-reconciliation-spec.md §2.9 + §3 Phase 4 +
//  docs/community-2.0-roadmap.md S12 row (incl. WP5 rider).
//
//  Test inventory (26 tests):
//    APNSEnvironmentTests (4):
//      1. testParse_developmentProfile_returnsSandbox
//      2. testParse_productionProfile_returnsProduction
//      3. testParse_nilProfileString_returnsProduction
//      4. testParse_malformedProfileString_returnsProduction
//    PushTokenUpsertPayloadTests (1):
//      5. testTokenUpsertPayload_containsUserIdEnvironmentZone
//    CommunityPushRelevanceIsRelevantTests (8):
//      6. testIsRelevant_sweeperPassed_matchingSegment_true
//      7. testIsRelevant_enforcementActive_matchingSegment_true
//      8. testIsRelevant_differentSegments_false
//      9. testIsRelevant_noParkedCar_nilSegment_false
//      10. testIsRelevant_pinHasNilSegment_false
//      11. testIsRelevant_openSpot_ownBlockMatch_false
//      12. testIsRelevant_leavingSoon_ownBlockMatch_false
//      13. testIsRelevant_unrelatedType_filming_false
//    CommunityPushRelevanceNotificationCopyTests (4):
//      14. testNotificationCopy_sweeperPassed_hasComplianceCopy
//      15. testNotificationCopy_enforcementActive_hasMoveOrFeedMeterCopy_noAvoidLanguage
//      16. testNotificationCopy_openSpot_nil
//      17. testNotificationCopy_filming_nil
//    CommunityPushRelevanceFirstUnseenSweeperPassedMatchTests (4):
//      18. testFirstUnseenMatch_matchingUnseenPin_returned
//      19. testFirstUnseenMatch_alreadySeenPin_skipped
//      20. testFirstUnseenMatch_wrongType_skipped
//      21. testFirstUnseenMatch_noParkedCar_nil
//    CommunityPushDedupeStoreTests (5):
//      22. testHasSeen_freshStore_false
//      23. testMarkSeen_thenHasSeen_true
//      24. testMarkSeen_isIdempotent_noDuplicateEntries
//      25. testMarkSeen_boundedTrim_dropsOldestBeyondMaxEntries
//      26. testSeenIds_skipsMalformedEntries
//
//  No Calendar.current use. No hardcoded Mapbox/Supabase secrets.
//

import XCTest
@testable import WePark

// MARK: - Shared fixture helper

/// Builds a fixture `CommunityPin` with `segment_id`/`confirm_count` overrides —
/// `CommunityPinServiceTests.makeFixturePin` (that file's own private helper) hardcodes both
/// to `null`/`0`, which this file's relevance/dedupe tests need to vary. Kept local to this
/// file (not shared) to avoid touching `CommunityPinServiceTests.swift`, out of this
/// session's scope.
private func makePushFixturePin(
    id: UUID = UUID(),
    pinType: PinType = .sweeperPassed,
    segmentId: String? = "MOTT ST|1|E",
    confirmCount: Int = 3
) -> CommunityPin {
    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType.rawValue)",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": 40.7217,
      "lng": -73.9950,
      "segment_id": \(segmentId.map { #""\#($0)""# } ?? "null"),
      "zone_id": "nolita",
      "author_id": null,
      "author_username": null,
      "created_at": "2026-09-03T10:00:00+00:00",
      "updated_at": "2026-09-03T10:00:00+00:00",
      "expires_at": "2026-09-03T12:00:00+00:00",
      "resolved_at": null,
      "confirm_count": \(confirmCount),
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }
    """

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Cannot decode date: \(string)")
        )
    }
    return try! decoder.decode(CommunityPin.self, from: Data(json.utf8))
}

// MARK: - 1. APNSEnvironment tests

final class APNSEnvironmentTests: XCTestCase {

    private func plistString(apsEnvironment: String) -> String {
        """
        garbage-CMS-bytes-before\
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>\(apsEnvironment)</string>
            </dict>
        </dict>
        </plist>
        garbage-CMS-bytes-after
        """
    }

    func testParse_developmentProfile_returnsSandbox() {
        let result = APNSEnvironment.parse(profileString: plistString(apsEnvironment: "development"))
        XCTAssertEqual(result, APNSEnvironment.sandbox)
    }

    func testParse_productionProfile_returnsProduction() {
        let result = APNSEnvironment.parse(profileString: plistString(apsEnvironment: "production"))
        XCTAssertEqual(result, APNSEnvironment.production)
    }

    /// The load-bearing failure mode: App Store Connect (TestFlight + App Store) strips
    /// `embedded.mobileprovision` entirely, so `profileString == nil` is the NORMAL path for
    /// every such install — `.production` is the correct, deliberate fallback.
    func testParse_nilProfileString_returnsProduction() {
        let result = APNSEnvironment.parse(profileString: nil)
        XCTAssertEqual(result, APNSEnvironment.production)
    }

    func testParse_malformedProfileString_returnsProduction() {
        let result = APNSEnvironment.parse(profileString: "not a plist at all, no xml markers here")
        XCTAssertEqual(result, APNSEnvironment.production)
    }
}

// MARK: - 2. Token-upsert payload shape tests

final class PushTokenUpsertPayloadTests: XCTestCase {

    func testTokenUpsertPayload_containsUserIdEnvironmentZone() {
        let userId = UUID()
        let payload = PushRegistrationService.tokenUpsertPayload(
            userId: userId,
            tokenHex: "abcd1234",
            environment: APNSEnvironment.sandbox,
            zoneId: "nolita"
        )
        XCTAssertEqual(payload["user_id"] as? String, userId.uuidString)
        XCTAssertEqual(payload["apns_token"] as? String, "abcd1234")
        XCTAssertEqual(payload["environment"] as? String, "sandbox")
        XCTAssertEqual(payload["zone_id"] as? String, "nolita")
        XCTAssertEqual(payload.count, 4, "payload must contain exactly these 4 keys — never lat/lng, never segment_id")
    }
}

// MARK: - 3. CommunityPushRelevance.isRelevant tests

final class CommunityPushRelevanceIsRelevantTests: XCTestCase {

    func testIsRelevant_sweeperPassed_matchingSegment_true() {
        XCTAssertTrue(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_enforcementActive_matchingSegment_true() {
        XCTAssertTrue(CommunityPushRelevance.isRelevant(
            pinType: .enforcementActive, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_differentSegments_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "ELIZABETH ST|1|W"
        ))
    }

    func testIsRelevant_noParkedCar_nilSegment_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: nil
        ))
    }

    func testIsRelevant_pinHasNilSegment_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: nil, parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    /// spec §3 Phase 4b item 2: open_spot/leaving_soon on your own block is never relevant to
    /// a parked user, even on an exact segment match.
    func testIsRelevant_openSpot_ownBlockMatch_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .openSpot, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_leavingSoon_ownBlockMatch_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .leavingSoon, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_unrelatedType_filming_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .filming, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }
}

// MARK: - 4. CommunityPushRelevance.notificationCopy tests

final class CommunityPushRelevanceNotificationCopyTests: XCTestCase {

    func testNotificationCopy_sweeperPassed_hasComplianceCopy() {
        let copy = CommunityPushRelevance.notificationCopy(for: .sweeperPassed)
        XCTAssertEqual(copy?.title, "Sweeper reported on your block")
        XCTAssertFalse(copy?.body.isEmpty ?? true)
    }

    /// AC parity with the rest of this codebase's "no avoid/ticket/fine/evasion/dodge" copy
    /// convention (mirrors ReportSheet's own AC-R17), and verbatim-matches direction doc §6's
    /// "move your car / feed the meter" framing, never ticket-avoidance language.
    func testNotificationCopy_enforcementActive_hasMoveOrFeedMeterCopy_noAvoidLanguage() {
        let copy = CommunityPushRelevance.notificationCopy(for: .enforcementActive)
        XCTAssertEqual(copy?.title, "Enforcement active on your block")
        let combined = ((copy?.title ?? "") + " " + (copy?.body ?? "")).lowercased()
        for forbidden in ["avoid", "ticket", "fine", "evasion", "dodge"] {
            XCTAssertFalse(combined.contains(forbidden), "copy must not contain '\(forbidden)'")
        }
        XCTAssertTrue(combined.contains("move your car") || combined.contains("feed the meter"))
    }

    func testNotificationCopy_openSpot_nil() {
        XCTAssertNil(CommunityPushRelevance.notificationCopy(for: .openSpot))
    }

    func testNotificationCopy_filming_nil() {
        XCTAssertNil(CommunityPushRelevance.notificationCopy(for: .filming))
    }
}

// MARK: - 5. CommunityPushRelevance.firstUnseenSweeperPassedMatch tests (WP5)

final class CommunityPushRelevanceFirstUnseenSweeperPassedMatchTests: XCTestCase {

    func testFirstUnseenMatch_matchingUnseenPin_returned() {
        let pin = makePushFixturePin(pinType: .sweeperPassed, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: "MOTT ST|1|E", seenPinIds: []
        )
        XCTAssertEqual(result?.id, pin.id)
    }

    func testFirstUnseenMatch_alreadySeenPin_skipped() {
        let pin = makePushFixturePin(pinType: .sweeperPassed, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: "MOTT ST|1|E", seenPinIds: [pin.id]
        )
        XCTAssertNil(result)
    }

    func testFirstUnseenMatch_wrongType_skipped() {
        let pin = makePushFixturePin(pinType: .enforcementActive, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: "MOTT ST|1|E", seenPinIds: []
        )
        XCTAssertNil(result, "firstUnseenSweeperPassedMatch is scoped to sweeper_passed only")
    }

    func testFirstUnseenMatch_noParkedCar_nil() {
        let pin = makePushFixturePin(pinType: .sweeperPassed, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: nil, seenPinIds: []
        )
        XCTAssertNil(result)
    }
}

// MARK: - 6. CommunityPushDedupeStore tests

final class CommunityPushDedupeStoreTests: XCTestCase {

    private let suiteName = "com.wepark.test.communitypushdedupestore"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    func testHasSeen_freshStore_false() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        XCTAssertFalse(store.hasSeen(UUID()))
    }

    func testMarkSeen_thenHasSeen_true() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        let id = UUID()
        store.markSeen(id)
        XCTAssertTrue(store.hasSeen(id))
    }

    func testMarkSeen_isIdempotent_noDuplicateEntries() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        let id = UUID()
        store.markSeen(id)
        store.markSeen(id)
        XCTAssertEqual(store.seenIds().count, 1)
    }

    func testMarkSeen_boundedTrim_dropsOldestBeyondMaxEntries() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen", maxEntries: 2)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        store.markSeen(first)
        store.markSeen(second)
        store.markSeen(third)
        XCTAssertFalse(store.hasSeen(first), "the oldest entry must be trimmed once maxEntries is exceeded")
        XCTAssertTrue(store.hasSeen(second))
        XCTAssertTrue(store.hasSeen(third))
        XCTAssertEqual(store.seenIds().count, 2)
    }

    func testSeenIds_skipsMalformedEntries() {
        ephemeralDefaults.set(["not-a-uuid", UUID().uuidString], forKey: "test.seen")
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        XCTAssertEqual(store.seenIds().count, 1, "a malformed stored entry must be skipped, not crash")
    }
}
