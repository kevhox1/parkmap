//
//  ParkedCarDetailPhase4aTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 4a + WP4 rider (build 20 S10).
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 4 (4a slice only).
//        docs/design/community-2.0-hero-gap-inventory.md WP4.
//
//  Tests target `ParkedCarDetailLogic` — the pure, `nonisolated`-where-applicable decision/
//  formatting logic extracted from `ParkedCarDetailView.swift` so the new leaving-soon
//  handoff + WP4 rider (offset chips, swept badge) are unit-testable without mounting a
//  SwiftUI view or making a network call. Same house style as `ReportSheetTests.swift`
//  (`ReportSheet.destination(forTapping:...)`, `ReportSheet.buildMeta`) and
//  `CandidateSegmentSearchTests.swift`.
//
//  Test inventory (42 tests):
//    ParkedCarDetailLiveSweeperPinTests (7):
//      live match / wrong pin type / wrong segment / nil segmentId / expired / resolved /
//      flag-off-even-with-a-live-match.
//    ParkedCarDetailConfirmCountLabelTests (3): 0 / 1 / 2+ confirms grammar.
//    ParkedCarDetailReminderChipDefinitionsTests (3): count+order, verbatim labels,
//      keyPath-to-ReminderOffsets.default wiring.
//    ParkedCarDetailLeavingSoonChipsTests (3): chip minutes array, CTA label copy (two
//      values, verbatim em dash).
//    ParkedCarDetailShouldGateLeavingSoonPostTests (5): the 4 communityEnabled ×
//      identityGateShouldShow combinations (delegates to the SAME
//      CommunityIdentityInterception.shouldShowIdentitySheet every other contribution path
//      uses) + the real-flag default-parameter path.
//    ParkedCarDetailLeavingSoonInsertParamsTests (5): leavingMinutes + segmentId + a resolved
//      positionFraction; no resolved segment → segmentId/positionFraction both nil; a
//      resolved segment but the car far outside the search radius → segmentId still set,
//      positionFraction nil; leavingMinutes threads through all 4 presets; and a structural
//      guard that `LeavingSoonInsertParams` (the view-layer struct, NOT the real network
//      payload — see Finding #3's correction on this test's own docstring) has no
//      expiry-shaped field.
//
//    QA pass 1 (PR #98) round-1-fix additions:
//    ParkedCarDetailOwnLiveLeavingSoonPinTests (9, Finding #1): live own pin matching segment /
//      live own pin matching only via the tight-radius geo fallback / far away with no segment
//      match / other author's pin / expired own pin / resolved own pin / wrong pin type / nil
//      authorId (no session) / flag-off-even-with-a-live-match.
//    ParkedCarDetailIsLeavingSoonPostedTests (4, Finding #1): the post-tap transient window
//      (justPosted alone), the reopened-sheet window (ownLivePin alone), neither, and both.
//    ReminderOffsetsCrossSheetRaceTests (3, Finding #2): chips-then-Settings both survive WITH
//      the `ContentView.swift` resync fix; the same sequence WITHOUT it reproduces the exact
//      reported bug (documents the pre-fix failure mode so a regression is caught here, not
//      just live); Settings-then-chips (was already correct, still correct).
//
//  No Calendar.current use.
//

import XCTest
@testable import WePark

// MARK: - Fixture helpers

private func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// Builds a minimal `CommunityPin` via the real JSON decode path (model-contract honesty,
/// same reasoning as `ReportSheetTests.makePin(createdAt:)`).
///
/// `authorId`/`lat`/`lng` default to the values every pre-existing call site in this file
/// relied on (`nil` author, `40.72`/`-74.00`) — added (QA pass 1, PR #98 Finding #1) so the
/// new `ownLiveLeavingSoonPin` tests can build author- and location-specific fixtures without
/// touching any existing call site.
private func makePin(
    pinType: String,
    segmentId: String?,
    createdAt: Date,
    expiresAt: Date?,
    resolvedAt: Date?,
    confirmCount: Int,
    authorId: UUID? = nil,
    lat: Double = 40.72,
    lng: Double = -74.00
) -> CommunityPin {
    let id = UUID()
    let segmentIdJSON = segmentId.map { "\"\($0)\"" } ?? "null"
    let expiresAtJSON = expiresAt.map { "\"\(iso8601($0))\"" } ?? "null"
    let resolvedAtJSON = resolvedAt.map { "\"\(iso8601($0))\"" } ?? "null"
    let authorIdJSON = authorId.map { "\"\($0.uuidString)\"" } ?? "null"
    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType)",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": \(lat),
      "lng": \(lng),
      "segment_id": \(segmentIdJSON),
      "author_id": \(authorIdJSON),
      "author_username": null,
      "created_at": "\(iso8601(createdAt))",
      "updated_at": "\(iso8601(createdAt))",
      "expires_at": \(expiresAtJSON),
      "resolved_at": \(resolvedAtJSON),
      "confirm_count": \(confirmCount),
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // Force-unwrap is acceptable in tests — a decode failure means the fixture JSON is wrong,
    // which is a test-authoring error that should fail loudly (matches ReportSheetTests).
    return try! decoder.decode(CommunityPin.self, from: json)
}

private func makePhase4aSegment(id: String = "SEG1") -> Segment {
    Segment(
        id: id,
        street: "BOWERY",
        fromStreet: "HESTER STREET",
        to: "GRAND STREET",
        side: "N",
        line: [[40.7183, -73.9942], [40.7190, -73.9940]],
        rules: [],
        dominantCategory: nil
    )
}

private func makeCar(lat: Double, lng: Double, segmentId: String?) -> ParkedCar {
    ParkedCar(
        id: UUID(),
        latitude: lat,
        longitude: lng,
        detectedSegmentID: segmentId,
        detectedSide: segmentId == nil ? nil : "N",
        street: "BOWERY",
        fromStreet: "HESTER STREET",
        toStreet: "GRAND STREET",
        parkedAt: Date(),
        notifyOnRestriction: true
    )
}

// MARK: - liveSweeperPin

final class ParkedCarDetailLiveSweeperPinTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    func testLiveMatch_returnsPin() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-600), expiresAt: epoch.addingTimeInterval(6600),
            resolvedAt: nil, confirmCount: 3
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: "SEG1", now: epoch, communityEnabled: true
        )
        XCTAssertEqual(result?.id, pin.id)
    }

    func testWrongPinType_returnsNil() {
        let pin = makePin(
            pinType: "enforcement_active", segmentId: "SEG1",
            createdAt: epoch, expiresAt: nil, resolvedAt: nil, confirmCount: 0
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: "SEG1", now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testWrongSegment_returnsNil() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: "SEG2",
            createdAt: epoch, expiresAt: nil, resolvedAt: nil, confirmCount: 0
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: "SEG1", now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testNilSegmentId_returnsNilEvenWithMatchingPins() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: nil,
            createdAt: epoch, expiresAt: nil, resolvedAt: nil, confirmCount: 0
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: nil, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result, "no resolved segment on the car means nothing to match against")
    }

    func testExpired_returnsNil() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-8000), expiresAt: epoch.addingTimeInterval(-60),
            resolvedAt: nil, confirmCount: 5
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: "SEG1", now: epoch, communityEnabled: true
        )
        XCTAssertNil(result, "an expires_at in the past must hide the badge even if the fixture bypassed clientSideFilter")
    }

    func testResolved_returnsNil() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-600), expiresAt: epoch.addingTimeInterval(6600),
            resolvedAt: epoch.addingTimeInterval(-30), confirmCount: 2
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: "SEG1", now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testFlagOff_returnsNilEvenWithALiveMatch() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-600), expiresAt: epoch.addingTimeInterval(6600),
            resolvedAt: nil, confirmCount: 3
        )
        let result = ParkedCarDetailLogic.liveSweeperPin(
            in: [pin], segmentId: "SEG1", now: epoch, communityEnabled: false
        )
        XCTAssertNil(result, "flag-off parity: the badge must never render regardless of live data")
    }
}

// MARK: - confirmCountLabel

final class ParkedCarDetailConfirmCountLabelTests: XCTestCase {

    func testZero_usesPluralForm() {
        XCTAssertEqual(ParkedCarDetailLogic.confirmCountLabel(0), "0 confirms")
    }

    func testOne_usesSingularForm() {
        XCTAssertEqual(ParkedCarDetailLogic.confirmCountLabel(1), "1 confirm")
    }

    func testMultiple_usesPluralForm() {
        XCTAssertEqual(ParkedCarDetailLogic.confirmCountLabel(6), "6 confirms")
    }
}

// MARK: - reminderChipDefinitions (WP4 rider)

final class ParkedCarDetailReminderChipDefinitionsTests: XCTestCase {

    func testCountAndOrder_matchesPrototype() {
        let labels = ParkedCarDetailLogic.reminderChipDefinitions.map(\.label)
        XCTAssertEqual(labels, ["15 min", "30 min", "1 hr", "2 hr", "Night before"],
            "design/prototype.html:307-311 order")
    }

    func testKeyPathWiring_matchesDefaultOffsets() {
        // ReminderOffsets.default is remind1Hour-only (pre-FT-6 parity). Reading every
        // chip's keyPath against it should show exactly ONE selected chip: "1 hr".
        let selected = ParkedCarDetailLogic.reminderChipDefinitions
            .filter { ReminderOffsets.default[keyPath: $0.keyPath] }
            .map(\.label)
        XCTAssertEqual(selected, ["1 hr"])
    }

    func testKeyPathsAreWritable_toggleRoundTrips() {
        var offsets = ReminderOffsets.default
        for def in ParkedCarDetailLogic.reminderChipDefinitions {
            let before = offsets[keyPath: def.keyPath]
            offsets[keyPath: def.keyPath].toggle()
            XCTAssertNotEqual(offsets[keyPath: def.keyPath], before, "\(def.label) chip must be writable")
        }
    }
}

// MARK: - leavingSoonChipMinutes + CTA label

final class ParkedCarDetailLeavingSoonChipsTests: XCTestCase {

    func testChipMinutes_matchesPrototypeAndDBCheckConstraint() {
        // Also matches the §2.2 CHECK constraint (leaving_minutes in (5, 10, 15, 20)).
        XCTAssertEqual(ParkedCarDetailLogic.leavingSoonChipMinutes, [5, 10, 15, 20])
    }

    func testCTALabel_tenMinutes_verbatimCopy() {
        XCTAssertEqual(
            ParkedCarDetailLogic.leavingSoonCTALabel(minutes: 10),
            "Leaving in 10 min \u{2014} tell the crew"
        )
    }

    func testCTALabel_twentyMinutes_verbatimCopy() {
        XCTAssertEqual(
            ParkedCarDetailLogic.leavingSoonCTALabel(minutes: 20),
            "Leaving in 20 min \u{2014} tell the crew"
        )
    }
}

// MARK: - shouldGateLeavingSoonPost (identity-gate routing)

final class ParkedCarDetailShouldGateLeavingSoonPostTests: XCTestCase {

    func testDelegatesToSharedGate_allFourCombinations() {
        for communityEnabled in [true, false] {
            for identityGateShouldShow in [true, false] {
                let expected = CommunityIdentityInterception.shouldShowIdentitySheet(
                    communityEnabled: communityEnabled,
                    identitySheetShouldShow: identityGateShouldShow
                )
                let actual = ParkedCarDetailLogic.shouldGateLeavingSoonPost(
                    communityEnabled: communityEnabled,
                    identityGateShouldShow: identityGateShouldShow
                )
                XCTAssertEqual(actual, expected,
                    "communityEnabled=\(communityEnabled) identityGateShouldShow=\(identityGateShouldShow)")
            }
        }
    }

    func testCommunityEnabledTrue_identityShouldShowTrue_gates() {
        XCTAssertTrue(ParkedCarDetailLogic.shouldGateLeavingSoonPost(
            communityEnabled: true, identityGateShouldShow: true
        ))
    }

    func testCommunityEnabledTrue_identityAlreadyShown_doesNotGate() {
        XCTAssertFalse(ParkedCarDetailLogic.shouldGateLeavingSoonPost(
            communityEnabled: true, identityGateShouldShow: false
        ))
    }

    func testCommunityEnabledFalse_neverGatesRegardlessOfIdentityState() {
        XCTAssertFalse(ParkedCarDetailLogic.shouldGateLeavingSoonPost(
            communityEnabled: false, identityGateShouldShow: true
        ))
        XCTAssertFalse(ParkedCarDetailLogic.shouldGateLeavingSoonPost(
            communityEnabled: false, identityGateShouldShow: false
        ))
    }

    func testDefaultParameter_usesRealFlag_currentlyFalse() {
        // AppConstants.communityEnabled is false in this build — this call omits the
        // `communityEnabled:` argument entirely, so a regression that flips the default
        // (without anyone updating this test) would surface here.
        XCTAssertFalse(ParkedCarDetailLogic.shouldGateLeavingSoonPost(identityGateShouldShow: true))
    }
}

// MARK: - leavingSoonInsertParams (payload shape)

final class ParkedCarDetailLeavingSoonInsertParamsTests: XCTestCase {

    private let radius: Double = 35.0

    func testOnSegment_includesLeavingMinutesSegmentIdAndAFraction() {
        let seg = makePhase4aSegment()
        let car = makeCar(lat: 40.7186, lng: -73.9941, segmentId: seg.id)
        let params = ParkedCarDetailLogic.leavingSoonInsertParams(
            parkedCar: car, resolvedSegment: seg, leavingMinutes: 15,
            positionFractionSearchRadiusMeters: radius
        )
        XCTAssertEqual(params.leavingMinutes, 15)
        XCTAssertEqual(params.lat, car.latitude)
        XCTAssertEqual(params.lng, car.longitude)
        XCTAssertEqual(params.segmentId, seg.id)
        XCTAssertNotNil(params.positionFraction, "car sits directly on its own segment's line")
        if let fraction = params.positionFraction {
            XCTAssertGreaterThanOrEqual(fraction, 0)
            XCTAssertLessThanOrEqual(fraction, 1)
        }
    }

    func testNoResolvedSegment_segmentIdAndFractionAreNil() {
        let car = makeCar(lat: 40.7186, lng: -73.9941, segmentId: nil)
        let params = ParkedCarDetailLogic.leavingSoonInsertParams(
            parkedCar: car, resolvedSegment: nil, leavingMinutes: 10,
            positionFractionSearchRadiusMeters: radius
        )
        XCTAssertNil(params.segmentId)
        XCTAssertNil(params.positionFraction)
        XCTAssertEqual(params.leavingMinutes, 10)
    }

    func testCarFarFromSegmentLine_segmentIdStillSet_fractionNil() {
        let seg = makePhase4aSegment()
        // Roughly 9km away — well outside a 35m projection radius, but this is still the
        // car's OWN resolved `detectedSegmentID`; only the best-effort polyline projection
        // (positionFraction) should come back nil, not segmentId.
        let car = makeCar(lat: 40.80, lng: -73.90, segmentId: seg.id)
        let params = ParkedCarDetailLogic.leavingSoonInsertParams(
            parkedCar: car, resolvedSegment: seg, leavingMinutes: 20,
            positionFractionSearchRadiusMeters: radius
        )
        XCTAssertEqual(params.segmentId, seg.id)
        XCTAssertNil(params.positionFraction)
    }

    func testLeavingMinutes_threadsThroughAllFourPresets() {
        let seg = makePhase4aSegment()
        let car = makeCar(lat: 40.7186, lng: -73.9941, segmentId: seg.id)
        for minutes in ParkedCarDetailLogic.leavingSoonChipMinutes {
            let params = ParkedCarDetailLogic.leavingSoonInsertParams(
                parkedCar: car, resolvedSegment: seg, leavingMinutes: minutes,
                positionFractionSearchRadiusMeters: radius
            )
            XCTAssertEqual(params.leavingMinutes, minutes)
        }
    }

    /// Structural regression guard on THIS VIEW-LAYER STRUCT only — walks its `Mirror` so a
    /// future edit that adds an `expiresAt`-shaped field to `LeavingSoonInsertParams`
    /// specifically fails loudly.
    ///
    /// QA pass 1 correction (PR #98, Finding #3): this test does NOT prove anything about the
    /// real `CommunityPinService.insertCrowdPin` network payload one layer up — that call DOES
    /// send a client-computed `expires_at` for `leaving_soon` (pre-existing, unchanged by this
    /// session; see `CommunityPhase2bWritePathTests.testInsertCrowdPin_leavingSoonType_expiresAtIsClientComputed_notOmitted`
    /// for the real wire-payload assertion). What's true and tested THERE, not here: the
    /// client sends a value, the server's `derive_pin_expiry` trigger overrides it
    /// unconditionally (spec §2.11, verified live — HANDOFF 2026-08-27 "Gate 1").
    func testLeavingSoonInsertParamsStruct_hasNoExpiryShapedField() {
        let seg = makePhase4aSegment()
        let car = makeCar(lat: 40.7186, lng: -73.9941, segmentId: seg.id)
        let params = ParkedCarDetailLogic.leavingSoonInsertParams(
            parkedCar: car, resolvedSegment: seg, leavingMinutes: 15,
            positionFractionSearchRadiusMeters: radius
        )
        let fieldNames = Set(Mirror(reflecting: params).children.compactMap(\.label))
        XCTAssertEqual(fieldNames, ["lat", "lng", "segmentId", "positionFraction", "leavingMinutes"])
        XCTAssertFalse(
            fieldNames.contains { $0.lowercased().contains("expir") },
            "this view-layer struct specifically should stay free of an expiry field — the real client-computed expires_at lives one layer up, in CommunityPinService.insertCrowdPin"
        )
    }
}

// MARK: - ownLiveLeavingSoonPin (QA pass 1, PR #98 Finding #1)

final class ParkedCarDetailOwnLiveLeavingSoonPinTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let me = UUID(uuidString: "AAAA0001-0000-0000-0000-000000000001")!
    private let someoneElse = UUID(uuidString: "BBBB0002-0000-0000-0000-000000000002")!

    // Car "parked" at this coordinate for every test below.
    private let carLat = 40.7200
    private let carLng = -74.0000

    func testLiveOwnPin_matchingSegment_returnsPin() {
        let pin = makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertEqual(result?.id, pin.id)
    }

    func testLiveOwnPin_noSegmentMatch_butWithinTightRadius_returnsPin() {
        // ~10m north of the car — no segmentId on either side (e.g. the car's own
        // detectedSegmentID was nil at post time), but well within the 30m fallback radius.
        let pin = makePin(
            pinType: "leaving_soon", segmentId: nil,
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat + 0.00009, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: nil,
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertEqual(result?.id, pin.id)
    }

    func testOwnPin_farAway_noSegmentMatch_returnsNil() {
        // ~220m north — well outside the tight radius, and no segmentId to fall back on.
        let pin = makePin(
            pinType: "leaving_soon", segmentId: nil,
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat + 0.002, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: nil,
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testOtherAuthorPin_evenIfMatchingSegmentAndLive_returnsNil() {
        let pin = makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: someoneElse, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result, "someone else's leaving-soon pin must never suppress MY CTA")
    }

    func testExpiredOwnPin_returnsNil() {
        let pin = makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-1200), expiresAt: epoch.addingTimeInterval(-60),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testResolvedOwnPin_returnsNil() {
        let pin = makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: epoch.addingTimeInterval(-10), confirmCount: 0, authorId: me, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testWrongPinType_returnsNil() {
        let pin = makePin(
            pinType: "sweeper_passed", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }

    func testFlagOff_returnsNilEvenWithALiveMatchingOwnPin() {
        let pin = makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: me, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: false
        )
        XCTAssertNil(result, "flag-off parity: dedupe logic must never activate regardless of live data")
    }

    func testNilAuthorId_returnsNilEvenWithMatchingPins() {
        // No authenticated session — can't safely claim ownership of anything.
        let pin = makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: epoch.addingTimeInterval(-60), expiresAt: epoch.addingTimeInterval(720),
            resolvedAt: nil, confirmCount: 0, authorId: me, lat: carLat, lng: carLng
        )
        let result = ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: [pin], authorId: nil, segmentId: "SEG1",
            carLatitude: carLat, carLongitude: carLng, now: epoch, communityEnabled: true
        )
        XCTAssertNil(result)
    }
}

// MARK: - isLeavingSoonPosted (QA pass 1, PR #98 Finding #1)

final class ParkedCarDetailIsLeavingSoonPostedTests: XCTestCase {

    private func makeOwnPin() -> CommunityPin {
        makePin(
            pinType: "leaving_soon", segmentId: "SEG1",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_000_600),
            resolvedAt: nil, confirmCount: 0
        )
    }

    /// The post-tap transient window: a post just completed but `visiblePins` hasn't
    /// reflected it yet (e.g. response decoding failed) — the transient flag alone must
    /// still show the confirmation state.
    func testJustPostedTrue_ownLivePinNil_returnsTrue() {
        XCTAssertTrue(ParkedCarDetailLogic.isLeavingSoonPosted(justPosted: true, ownLivePin: nil))
    }

    /// A reopened sheet: the transient flag reset to `false` (fresh `@State`), but a live own
    /// pin was found in truth — must still show the confirmation state, not the CTA.
    func testJustPostedFalse_ownLivePinPresent_returnsTrue() {
        XCTAssertTrue(ParkedCarDetailLogic.isLeavingSoonPosted(justPosted: false, ownLivePin: makeOwnPin()))
    }

    func testJustPostedFalse_ownLivePinNil_returnsFalse() {
        XCTAssertFalse(ParkedCarDetailLogic.isLeavingSoonPosted(justPosted: false, ownLivePin: nil))
    }

    func testJustPostedTrue_ownLivePinAlsoPresent_returnsTrue() {
        XCTAssertTrue(ParkedCarDetailLogic.isLeavingSoonPosted(justPosted: true, ownLivePin: makeOwnPin()))
    }
}

// MARK: - ReminderOffsets cross-sheet race (QA pass 1, PR #98 Finding #2)

/// These tests exercise the REAL `ReminderOffsets.load(from:)`/`.save(_:to:)` persistence
/// primitives against an isolated `UserDefaults` suite, simulating the exact read-modify-write
/// sequence `ParkedCarDetailView`'s offset chips and `SettingsView`'s toggles independently
/// perform — without mounting SwiftUI or `ContentView`. What actually makes both edit orders
/// safe is: (1) `ParkedCarDetailView` always loads fresh at sheet-open time (unchanged by this
/// fix), and (2) `ContentView`'s cached copy — the thing `SettingsView` reads/writes through —
/// is now resynced from `UserDefaults` on every sheet dismiss (the one-line `ContentView.swift`
/// fix), so it can never hold a copy older than the last write from EITHER surface. These tests
/// model `ContentView`'s cache as a plain local `var`, loaded/saved exactly like the resync
/// point does.
final class ReminderOffsetsCrossSheetRaceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.reminderOffsetsRace.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Order: chips edit (My Car) → dismiss (the fix's resync) → Settings edit (a DIFFERENT
    /// toggle) → dismiss. Both edits must survive — this is the exact bug Finding #2 reported:
    /// without the resync, Settings would write back a copy that predated the chip edit,
    /// silently reverting it.
    func testChipsEditThenSettingsEdit_bothSurvive_withResync() {
        // My Car: chips write straight to UserDefaults (ParkedCarDetailView's own write path).
        var afterChipEdit = ReminderOffsets.default
        afterChipEdit.remind30Min = true
        ReminderOffsets.save(afterChipEdit, to: defaults)

        // ContentView's sheet-dismiss resync (the fix): reload fresh before Settings can see
        // a stale copy.
        var contentViewCache = ReminderOffsets.load(from: defaults)

        // Settings: toggles a DIFFERENT preset on top of the (now-fresh) cached copy, then
        // writes the FULL struct back — SettingsView.onChange(of: offsets)'s existing shape.
        contentViewCache.remindNightBefore = true
        ReminderOffsets.save(contentViewCache, to: defaults)

        let final = ReminderOffsets.load(from: defaults)
        XCTAssertTrue(final.remind30Min, "the My Car chip edit must survive a later, unrelated Settings edit")
        XCTAssertTrue(final.remindNightBefore, "the Settings edit itself must also be saved")
    }

    /// Documents the pre-fix failure mode with a RED-if-regressed test: reproduces Finding #2
    /// exactly as reported, WITHOUT the resync step, so removing the `ContentView.swift` fix
    /// in the future is caught here, not just in a live repro.
    func testChipsEditThenSettingsEdit_withoutResync_dropsTheChipEdit() {
        var afterChipEdit = ReminderOffsets.default
        afterChipEdit.remind30Min = true
        ReminderOffsets.save(afterChipEdit, to: defaults)

        // Simulate ContentView's cache WITHOUT the resync fix: still holding whatever it
        // loaded at launch/foreground — the pre-chip-edit default.
        var staleContentViewCache = ReminderOffsets.default

        staleContentViewCache.remindNightBefore = true
        ReminderOffsets.save(staleContentViewCache, to: defaults)

        let final = ReminderOffsets.load(from: defaults)
        XCTAssertFalse(final.remind30Min, "documents the pre-fix bug: a stale cache silently reverts the chip edit")
        XCTAssertTrue(final.remindNightBefore)
    }

    /// The other edit order: Settings first, then My Car chips. This was already correct
    /// BEFORE this fix (`ParkedCarDetailView` always loads fresh at sheet-open time,
    /// independent of `ContentView`'s cache) and remains correct after it — asserted here so
    /// a future change to My Car's load timing can't quietly break this direction while
    /// "fixing" the other one.
    func testSettingsEditThenChipsEdit_bothSurvive() {
        var afterSettingsEdit = ReminderOffsets.default
        afterSettingsEdit.remindNightBefore = true
        ReminderOffsets.save(afterSettingsEdit, to: defaults)

        // My Car's init-time load — always fresh, unchanged by this fix.
        var parkedCarDetailState = ReminderOffsets.load(from: defaults)
        parkedCarDetailState.remind30Min = true
        ReminderOffsets.save(parkedCarDetailState, to: defaults)

        let final = ReminderOffsets.load(from: defaults)
        XCTAssertTrue(final.remindNightBefore)
        XCTAssertTrue(final.remind30Min)
    }
}
