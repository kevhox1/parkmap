//
//  BlockDetailS13bTests.swift
//  WeParkTests
//
//  Community 2.0 S13b (build 20, docs/design/community-2.0-hero-gap-inventory.md WP3) — the
//  block detail redesign's pure, testable decision logic: `BlockDetailLogic`
//  (`Views/BlockDetailView.swift`) and `ZoneMessageComposeLogic`
//  (`Services/ZoneMessageService.swift`). Mirrors `ParkedCarDetailPhase4aTests.swift`'s own
//  house style (pure-logic extraction tested without mounting a SwiftUI view).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (24 tests):
//    BlockDetailLiveBlockPinsTests (6): matching segment / no match / flag-off-even-with-a-
//      match / newest-first sort / a blockfaceKey-shaped segment_id never matches a raw
//      segment.id (the two id shapes' non-collision this section's correctness depends on) /
//      empty input.
//    BlockDetailResolvedZoneIdTests (5): nolita / soho / les midpoints resolve; a midpoint
//      outside all three boxes resolves nil; a nil midpoint resolves nil.
//    BlockDetailShouldGateChatSendTests (5): the 4 communityEnabled × identityGateShouldShow
//      combinations (delegates to the SAME CommunityIdentityInterception.shouldShowIdentitySheet
//      every other contribution path uses) + the real-flag default-parameter path.
//    BlockDetailShowsEmptyChatterStateTests (3): empty+notLoading → true; empty+loading →
//      false (a loading state, not an empty one); nonempty → false.
//    ZoneMessageComposeLogicTests (4): empty/whitespace-only draft trims to "" and disables
//      send; a real draft trims correctly and enables send; leading/trailing whitespace is
//      stripped without touching internal spacing.
//    BlockStatusLineReuseTests (1): `ParkingRulesEngine.safetyLabel(for:at:)` — the single
//      function BOTH `BlockDetailView.safetyLabelView` and
//      `ParkedCarDetailView.safetyLabelView(for:)` call for their "big status line" — is pure
//      and deterministic for identical (segment, time) inputs. This is the strongest assertion
//      the seam allows without a SwiftUI view-inspection dependency: both call sites are
//      verified BY READING THE SOURCE (this PR's own report) to invoke this exact function,
//      not a forked copy; this test locks in that the function itself can't silently drift
//      between two calls with the same inputs.
//
//  No Calendar.current use.
//

import CoreLocation
import XCTest
@testable import WePark

// MARK: - Fixture helpers

private func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// Builds a minimal `CommunityPin` via the real JSON decode path — same reasoning as
/// `ParkedCarDetailPhase4aTests.makePin`'s own doc comment (model-contract honesty).
private func makeBlockPin(
    segmentId: String?,
    createdAt: Date
) -> CommunityPin {
    let id = UUID()
    let segmentIdJSON = segmentId.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "enforcement_active",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": 40.72,
      "lng": -74.00,
      "segment_id": \(segmentIdJSON),
      "author_id": null,
      "author_username": null,
      "created_at": "\(iso8601(createdAt))",
      "updated_at": "\(iso8601(createdAt))",
      "expires_at": null,
      "resolved_at": null,
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(CommunityPin.self, from: json)
}

// MARK: - BlockDetailLogic.liveBlockPins

final class BlockDetailLiveBlockPinsTests: XCTestCase {

    func testMatchingSegment_returnsPin() {
        let pin = makeBlockPin(segmentId: "SEG_A", createdAt: Date())
        let result = BlockDetailLogic.liveBlockPins(in: [pin], segmentId: "SEG_A", communityEnabled: true)
        XCTAssertEqual(result.map(\.id), [pin.id])
    }

    func testNoMatch_returnsEmpty() {
        let pin = makeBlockPin(segmentId: "SEG_B", createdAt: Date())
        let result = BlockDetailLogic.liveBlockPins(in: [pin], segmentId: "SEG_A", communityEnabled: true)
        XCTAssertTrue(result.isEmpty)
    }

    func testFlagOff_returnsEmpty_evenWithAMatch() {
        let pin = makeBlockPin(segmentId: "SEG_A", createdAt: Date())
        let result = BlockDetailLogic.liveBlockPins(in: [pin], segmentId: "SEG_A", communityEnabled: false)
        XCTAssertTrue(result.isEmpty, "Flag-off must render nothing regardless of what's in `pins`")
    }

    func testNewestFirstSort() {
        let older = makeBlockPin(segmentId: "SEG_A", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = makeBlockPin(segmentId: "SEG_A", createdAt: Date(timeIntervalSince1970: 1_800_003_600))
        let result = BlockDetailLogic.liveBlockPins(in: [older, newer], segmentId: "SEG_A", communityEnabled: true)
        XCTAssertEqual(result.map(\.id), [newer.id, older.id])
    }

    /// The correctness invariant "LIVE ON THIS BLOCK" depends on: a block-scoped restriction
    /// pin's `segment_id` is the 4-part `blockfaceKey` shape
    /// (`STREET|LOWSTREET|HIGHSTREET|SIDE`), never the raw tile `Segment.id` this filter
    /// matches against — so the two lists (this section vs. `TemporaryRestrictionBanner`) can
    /// never double-surface the same pin.
    func testBlockfaceKeyShapedSegmentId_neverMatchesRawSegmentId() {
        let restrictionPin = makeBlockPin(segmentId: "MOTT STREET|PRINCE STREET|SPRING STREET|W", createdAt: Date())
        let result = BlockDetailLogic.liveBlockPins(
            in: [restrictionPin],
            segmentId: "MOTT_STREET_PRINCE_STREET_SPRING_STREET_W_3",
            communityEnabled: true
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyInput_returnsEmpty() {
        let result = BlockDetailLogic.liveBlockPins(in: [], segmentId: "SEG_A", communityEnabled: true)
        XCTAssertTrue(result.isEmpty)
    }
}

// MARK: - BlockDetailLogic.resolvedZoneId

final class BlockDetailResolvedZoneIdTests: XCTestCase {

    func testNolitaMidpoint_resolvesNolita() {
        let midpoint = CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9950)
        XCTAssertEqual(BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: midpoint), "nolita")
    }

    func testSohoMidpoint_resolvesSoho() {
        let midpoint = CLLocationCoordinate2D(latitude: 40.7225, longitude: -74.0010)
        XCTAssertEqual(BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: midpoint), "soho")
    }

    func testLesMidpoint_resolvesLes() {
        let midpoint = CLLocationCoordinate2D(latitude: 40.7200, longitude: -73.9850)
        XCTAssertEqual(BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: midpoint), "les")
    }

    func testOutsideAllZones_resolvesNil() {
        // Far uptown — well outside all three Community 2.0 zone boxes.
        let midpoint = CLLocationCoordinate2D(latitude: 40.80, longitude: -73.95)
        XCTAssertNil(BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: midpoint))
    }

    func testNilMidpoint_resolvesNil() {
        XCTAssertNil(BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: nil))
    }
}

// MARK: - BlockDetailLogic.shouldGateChatSend

final class BlockDetailShouldGateChatSendTests: XCTestCase {

    func testCommunityEnabled_gateShouldShow_true() {
        XCTAssertTrue(BlockDetailLogic.shouldGateChatSend(communityEnabled: true, identityGateShouldShow: true))
    }

    func testCommunityEnabled_gateAlreadySeen_false() {
        XCTAssertFalse(BlockDetailLogic.shouldGateChatSend(communityEnabled: true, identityGateShouldShow: false))
    }

    func testCommunityDisabled_gateShouldShow_stillFalse() {
        XCTAssertFalse(BlockDetailLogic.shouldGateChatSend(communityEnabled: false, identityGateShouldShow: true),
            "Flag-off must never show the identity sheet, even if the device-local gate would otherwise fire")
    }

    func testCommunityDisabled_gateAlreadySeen_false() {
        XCTAssertFalse(BlockDetailLogic.shouldGateChatSend(communityEnabled: false, identityGateShouldShow: false))
    }

    func testDefaultParameter_usesRealFlag() {
        // Sanity check that the default-parameter path compiles and delegates correctly —
        // mirrors ParkedCarDetailShouldGateLeavingSoonPostTests' own "real-flag default" case.
        let result = BlockDetailLogic.shouldGateChatSend(identityGateShouldShow: true)
        XCTAssertEqual(result, AppConstants.communityEnabled && true)
    }
}

// MARK: - BlockDetailLogic.showsEmptyChatterState

final class BlockDetailShowsEmptyChatterStateTests: XCTestCase {

    func testEmptyAndNotLoading_true() {
        XCTAssertTrue(BlockDetailLogic.showsEmptyChatterState(messages: [], isLoading: false))
    }

    func testEmptyAndLoading_false() {
        XCTAssertFalse(BlockDetailLogic.showsEmptyChatterState(messages: [], isLoading: true),
            "Mid-fetch is a loading state, not an intentional empty state")
    }

    func testNonEmpty_false() throws {
        let json = """
        {"id":1,"zone_id":"nolita","author_id":null,"message_type":"user","body":"hi",
         "related_report_id":null,"created_at":"2026-09-05T09:00:00+00:00",
         "author_username":null,"author_reputation":null,"segment_id":null}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ZoneMessage.self, from: json)
        XCTAssertFalse(BlockDetailLogic.showsEmptyChatterState(messages: [message], isLoading: false))
    }
}

// MARK: - ZoneMessageComposeLogic

final class ZoneMessageComposeLogicTests: XCTestCase {

    func testEmptyDraft_trimsToEmpty_cannotSend() {
        XCTAssertEqual(ZoneMessageComposeLogic.trimmedBody(""), "")
        XCTAssertFalse(ZoneMessageComposeLogic.canSend(draft: ""))
    }

    func testWhitespaceOnlyDraft_trimsToEmpty_cannotSend() {
        XCTAssertEqual(ZoneMessageComposeLogic.trimmedBody("   \n\t  "), "")
        XCTAssertFalse(ZoneMessageComposeLogic.canSend(draft: "   \n\t  "))
    }

    func testRealDraft_trimsCorrectly_canSend() {
        XCTAssertEqual(ZoneMessageComposeLogic.trimmedBody("  hello block  "), "hello block")
        XCTAssertTrue(ZoneMessageComposeLogic.canSend(draft: "  hello block  "))
    }

    func testInternalSpacing_preserved() {
        XCTAssertEqual(ZoneMessageComposeLogic.trimmedBody("  two   words  "), "two   words")
    }
}

// MARK: - Big status line: same function feeds both surfaces (not forked)

final class BlockStatusLineReuseTests: XCTestCase {

    /// `BlockDetailView.safetyLabelView` and `ParkedCarDetailView.safetyLabelView(for:)` both
    /// call `engine.safetyLabel(for: segment, at: now).text` directly (verified by reading both
    /// files — neither re-derives or forks the label text). This test locks in the shared
    /// function's own determinism: the same (segment, time) input must always produce the same
    /// output, so the two call sites can never observe divergent behavior from the ONE function
    /// they both depend on.
    func testSafetyLabel_deterministic_forIdenticalInputs() {
        let rule = ParkingRule(
            category: .noStanding,
            description: "NO STANDING ANYTIME",
            days: [0, 1, 2, 3, 4, 5, 6],
            timeRanges: [],
            anytime: true,
            arrow: "both"
        )
        let segment = Segment(
            id: "SEG_STATUS_LINE",
            street: "BOWERY",
            fromStreet: "HESTER STREET",
            to: "GRAND STREET",
            side: "N",
            line: [[40.7183, -73.9942], [40.7190, -73.9940]],
            rules: [rule],
            dominantCategory: .noStanding
        )
        let engine = ParkingRulesEngine()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = engine.safetyLabel(for: segment, at: now)
        let second = engine.safetyLabel(for: segment, at: now)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.text, "No standing")
    }
}
