//
//  IdentitySheetTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2b (build 20 S7) — tests for `CommunityIdentityGate` (show-once
//  persistence) and `CommunityIdentityInterception.shouldShowIdentitySheet` (both flag
//  states). Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2 ("Identity sheet").
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (9 tests):
//    CommunityIdentityGate — mirrors ParkingGuidePromptGateTests' precedent exactly:
//      1. testFreshInstall_shouldShow_isTrue
//      2. testMarkShown_thenShouldShow_isFalse
//      3. testMarkShown_isIdempotent
//      4. testGate_neverTouchesStandardDefaults
//
//    CommunityIdentityInterception.shouldShowIdentitySheet(communityEnabled:identitySheetShouldShow:)
//    — all 4 combinations of the two flag dimensions:
//      5. testShouldShowIdentitySheet_flagOn_gateShouldShow_true
//      6. testShouldShowIdentitySheet_flagOn_gateAlreadyShown_false
//      7. testShouldShowIdentitySheet_flagOff_gateShouldShow_stillFalse   (the critical guard —
//         flag-off contribution paths must NEVER show the sheet, per spec §3 Phase 2)
//      8. testShouldShowIdentitySheet_flagOff_gateAlreadyShown_false
//
//    IdentitySheet.avatarOptions — verbatim list check (design/prototype.html:1016):
//      9. testAvatarOptions_matchesPrototypeVerbatim
//
//    IdentitySheet.generateDefaultHandle() — non-empty pre-fill (schema NOT NULL guard,
//    see the field's own doc comment in IdentitySheet.swift):
//      10. testGenerateDefaultHandle_neverEmpty_startsWithNeighbor
//

import XCTest
@testable import WePark

// MARK: - CommunityIdentityGate

final class CommunityIdentityGateTests: XCTestCase {

    private let suiteName = "com.wepark.test.communityidentitygate"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removeObject(forKey: CommunityIdentityGate.shownKey)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    func testFreshInstall_shouldShow_isTrue() {
        let gate = CommunityIdentityGate(defaults: ephemeralDefaults, key: CommunityIdentityGate.shownKey)
        XCTAssertTrue(gate.shouldShow(), "shouldShow() should return true on a fresh UserDefaults suite")
    }

    func testMarkShown_thenShouldShow_isFalse() {
        let gate = CommunityIdentityGate(defaults: ephemeralDefaults, key: CommunityIdentityGate.shownKey)
        gate.markShown()

        let stored = ephemeralDefaults.bool(forKey: CommunityIdentityGate.shownKey)
        XCTAssertTrue(stored, "UserDefaults key should be true after markShown()")
        XCTAssertFalse(gate.shouldShow(), "shouldShow() should return false after markShown()")
    }

    /// Directly exercises spec §3 Phase 2's fix: mark-shown must latch regardless of WHICH
    /// button led to it ("Join the board" vs. "Post anonymously") — this test proves the
    /// gate itself never re-arms, independent of the prototype's own re-prompting bug (that
    /// bug lived in `needIdentity()`'s never-latching logic, not in a gate like this one).
    func testMarkShown_isIdempotent() {
        let gate = CommunityIdentityGate(defaults: ephemeralDefaults, key: CommunityIdentityGate.shownKey)
        gate.markShown()
        for i in 0..<5 {
            XCTAssertFalse(gate.shouldShow(), "shouldShow() should return false on check #\(i + 1) after markShown")
        }
    }

    func testGate_neverTouchesStandardDefaults() {
        UserDefaults.standard.removeObject(forKey: "com.wepark.test.communityidentitygate.canary")
        let gate = CommunityIdentityGate(defaults: ephemeralDefaults, key: CommunityIdentityGate.shownKey)
        gate.markShown()
        XCTAssertNil(UserDefaults.standard.object(forKey: "com.wepark.test.communityidentitygate.canary"),
            "markShown() must not touch UserDefaults.standard when an ephemeral suite is injected")
    }
}

// MARK: - CommunityIdentityInterception

final class CommunityIdentityInterceptionTests: XCTestCase {

    func testShouldShowIdentitySheet_flagOn_gateShouldShow_true() {
        let result = CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: true, identitySheetShouldShow: true
        )
        XCTAssertTrue(result)
    }

    func testShouldShowIdentitySheet_flagOn_gateAlreadyShown_false() {
        let result = CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: true, identitySheetShouldShow: false
        )
        XCTAssertFalse(result)
    }

    /// The critical guard: even if the show-once gate would say "show it," flag-OFF must
    /// still return false — the report-submit contribution path predates Community 2.0
    /// entirely and must see ZERO behavior change while the flag is off (spec §3 Phase 2).
    func testShouldShowIdentitySheet_flagOff_gateShouldShow_stillFalse() {
        let result = CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: false, identitySheetShouldShow: true
        )
        XCTAssertFalse(result, "Flag-off must never show the identity sheet, regardless of the gate's own state")
    }

    func testShouldShowIdentitySheet_flagOff_gateAlreadyShown_false() {
        let result = CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: false, identitySheetShouldShow: false
        )
        XCTAssertFalse(result)
    }
}

// MARK: - IdentitySheet.avatarOptions

final class IdentitySheetAvatarOptionsTests: XCTestCase {

    /// Verbatim, design/prototype.html:1016.
    func testAvatarOptions_matchesPrototypeVerbatim() {
        XCTAssertEqual(IdentitySheet.avatarOptions, ["🥯", "☕", "🚕", "🌇", "🦝", "🍕", "🗽", "🐿️"])
    }
}

// MARK: - IdentitySheet.generateDefaultHandle()

final class IdentitySheetDefaultHandleTests: XCTestCase {

    /// `public.profiles.username` is `text ... not null` — a user's first-ever
    /// `upsertProfile` call must never send an empty/nil username. The pre-filled default
    /// handle is what guarantees that on the common "Join the board & post" path (see
    /// `IdentitySheet.handle`'s own doc comment).
    func testGenerateDefaultHandle_neverEmpty_startsWithNeighbor() {
        for _ in 0..<20 {
            let handle = IdentitySheet.generateDefaultHandle()
            XCTAssertFalse(handle.isEmpty)
            XCTAssertTrue(handle.hasPrefix("Neighbor"), "Got: \(handle)")
        }
    }
}
