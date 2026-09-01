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
//  Test inventory (26 tests):
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
//      guard that the payload shape has no client-supplied expiry field at all (spec §2.11).
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
private func makePin(
    pinType: String,
    segmentId: String?,
    createdAt: Date,
    expiresAt: Date?,
    resolvedAt: Date?,
    confirmCount: Int
) -> CommunityPin {
    let id = UUID()
    let segmentIdJSON = segmentId.map { "\"\($0)\"" } ?? "null"
    let expiresAtJSON = expiresAt.map { "\"\(iso8601($0))\"" } ?? "null"
    let resolvedAtJSON = resolvedAt.map { "\"\(iso8601($0))\"" } ?? "null"
    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType)",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": 40.72,
      "lng": -74.00,
      "segment_id": \(segmentIdJSON),
      "author_id": null,
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

private func makeSegment(id: String = "SEG1") -> Segment {
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
        let seg = makeSegment()
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
        let seg = makeSegment()
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
        let seg = makeSegment()
        let car = makeCar(lat: 40.7186, lng: -73.9941, segmentId: seg.id)
        for minutes in ParkedCarDetailLogic.leavingSoonChipMinutes {
            let params = ParkedCarDetailLogic.leavingSoonInsertParams(
                parkedCar: car, resolvedSegment: seg, leavingMinutes: minutes,
                positionFractionSearchRadiusMeters: radius
            )
            XCTAssertEqual(params.leavingMinutes, minutes)
        }
    }

    /// Structural regression guard for spec §2.11: "the client sends leaving_minutes, never
    /// a raw expiry." `LeavingSoonInsertParams` has no expiry-shaped field at all — this
    /// walks its Mirror rather than trusting a doc comment, so a future edit that
    /// accidentally reintroduces a client-side `expiresAt` param fails this test loudly.
    func testPayloadShape_hasNoClientSuppliedExpiryField() {
        let seg = makeSegment()
        let car = makeCar(lat: 40.7186, lng: -73.9941, segmentId: seg.id)
        let params = ParkedCarDetailLogic.leavingSoonInsertParams(
            parkedCar: car, resolvedSegment: seg, leavingMinutes: 15,
            positionFractionSearchRadiusMeters: radius
        )
        let fieldNames = Set(Mirror(reflecting: params).children.compactMap(\.label))
        XCTAssertEqual(fieldNames, ["lat", "lng", "segmentId", "positionFraction", "leavingMinutes"])
        XCTAssertFalse(
            fieldNames.contains { $0.lowercased().contains("expir") },
            "spec §2.11: expires_at is server-derived; the client must never smuggle one through"
        )
    }
}
