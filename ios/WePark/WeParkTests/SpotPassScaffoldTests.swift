//
//  SpotPassScaffoldTests.swift
//  Spot Pass C0 (docs/specs/qr-spot-handoff.md §8, §14): URL/token parsing, the dark flags, the
//  inert-when-off router, and the carry-over store round trip.
//

import XCTest
@testable import WePark

final class SpotPassLinkTests: XCTestCase {

    private let validToken = "AbCdEfGhIjKlMnOpQrSt_-"  // 22 base64url chars

    private func parse(_ string: String) -> SpotPassLink? {
        URL(string: string).flatMap { SpotPassLink(url: $0) }
    }

    func testTokenLength_is22() {
        XCTAssertEqual(validToken.count, 22)
        XCTAssertEqual(SpotPassLink.tokenLength, 22)
    }

    func testFragmentForm_parsesToken() {
        XCTAssertEqual(parse("https://getwepark.com/p#t=\(validToken)")?.token, validToken)
    }

    func testQueryFallback_parsesToken() {
        XCTAssertEqual(parse("https://getwepark.com/p?t=\(validToken)")?.token, validToken)
    }

    func testFragmentWinsOverQuery() {
        let other = "ZZZZZZZZZZZZZZZZZZZZZZ"
        XCTAssertEqual(parse("https://getwepark.com/p?t=\(other)#t=\(validToken)")?.token, validToken)
    }

    func testFragmentWithExtraParams_parsesToken() {
        XCTAssertEqual(parse("https://getwepark.com/p#x=1&t=\(validToken)")?.token, validToken)
    }

    func testBareLanding_hasNoToken() {
        let parsed = parse("https://getwepark.com/p")
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.token)
    }

    func testSubpath_isRecognised() {
        XCTAssertNotNil(parse("https://getwepark.com/p/anything"))
        XCTAssertEqual(parse("https://getwepark.com/p/#t=\(validToken)")?.token, validToken)
    }

    func testMalformedToken_isIndistinguishableFromAbsent() {
        XCTAssertNotNil(parse("https://getwepark.com/p#t=short"))
        XCTAssertNil(parse("https://getwepark.com/p#t=short")?.token)
        XCTAssertNil(parse("https://getwepark.com/p#t=\(validToken)x")?.token)
        XCTAssertNil(parse("https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrS!_-")?.token)
        XCTAssertNil(parse("https://getwepark.com/p#t=")?.token)
    }

    func testForeignLinks_areRejected() {
        XCTAssertNil(parse("http://getwepark.com/p#t=\(validToken)"))
        XCTAssertNil(parse("https://example.com/p#t=\(validToken)"))
        XCTAssertNil(parse("https://www.getwepark.com/p#t=\(validToken)"))
        XCTAssertNil(parse("https://getwepark.com/"))
        XCTAssertNil(parse("https://getwepark.com/pass#t=\(validToken)"))
        XCTAssertNil(parse("wepark://invite/\(validToken)"))
    }

    func testHostAndSchemeAreCaseInsensitive() {
        XCTAssertEqual(parse("HTTPS://GetWePark.com/p#t=\(validToken)")?.token, validToken)
    }

    func testIsValidToken_alphabet() {
        XCTAssertTrue(SpotPassLink.isValidToken("0123456789abcdefghijkl"))
        XCTAssertTrue(SpotPassLink.isValidToken("-_-_-_-_-_-_-_-_-_AZ09"))
        XCTAssertFalse(SpotPassLink.isValidToken("0123456789abcdefghijk+"))
        XCTAssertFalse(SpotPassLink.isValidToken(""))
    }

    func testSharedConstants_matchAssociationFile() {
        XCTAssertEqual(SpotPassShared.universalLinkHost, "getwepark.com")
        XCTAssertEqual(SpotPassShared.landingPath, "/p")
        XCTAssertEqual(SpotPassShared.appGroupID, "group.com.kevinhoxha.wepark.shared")
        XCTAssertEqual(SpotPassShared.clipBundleID, "com.kevinhoxha.wepark.Clip")
        XCTAssertEqual(SpotPassShared.clipKeychainLabel, "wepark-appclip")
    }
}

@MainActor
final class SpotPassLinkRouterTests: XCTestCase {

    private let url = URL(string: "https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_-")!

    func testSpotHandoffFlags_defaultFalse() {
        XCTAssertFalse(AppConstants.spotHandoffEnabled)
        XCTAssertFalse(AppConstants.spotHandoffAutoDetectEnabled)
    }

    func testRouter_flagOff_isInert() {
        let inbox = SpotPassLinkInbox()
        XCTAssertFalse(SpotPassLinkRouter.handle(url, enabled: false, inbox: inbox))
        XCTAssertNil(inbox.pending)
    }

    func testRouter_realDefault_isInert() {
        let inbox = SpotPassLinkInbox()
        XCTAssertFalse(SpotPassLinkRouter.handle(url, inbox: inbox))
        XCTAssertNil(inbox.pending)
    }

    func testRouter_flagOn_buffersLink() {
        let inbox = SpotPassLinkInbox()
        XCTAssertTrue(SpotPassLinkRouter.handle(url, enabled: true, inbox: inbox))
        XCTAssertEqual(inbox.pending?.token, "AbCdEfGhIjKlMnOpQrSt_-")
    }

    func testRouter_flagOn_ignoresForeignUrl() {
        let inbox = SpotPassLinkInbox()
        let foreign = URL(string: "wepark://invite/00000000-0000-0000-0000-000000000000")!
        XCTAssertFalse(SpotPassLinkRouter.handle(foreign, enabled: true, inbox: inbox))
        XCTAssertNil(inbox.pending)
    }
}

final class ClipHandoffContextStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "wepark.spotpass.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testRoundTrip() {
        let store = ClipHandoffContextStore(defaults: makeDefaults())
        let context = ClipHandoffContext(
            userId: "u-1",
            firstPassAt: Date(timeIntervalSince1970: 1_800_000_000),
            passesHelped: 2,
            passesPendingKarma: 1,
            lastAlias: "Bodega Cat"
        )
        XCTAssertNil(store.load())
        store.save(context)
        XCTAssertEqual(store.load(), context)
        XCTAssertEqual(context.v, 1)
        XCTAssertEqual(context.origin, "clip")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testUnknownVersion_isIgnored() {
        let store = ClipHandoffContextStore(defaults: makeDefaults())
        store.save(ClipHandoffContext(
            v: 99,
            userId: "u-1",
            firstPassAt: Date(timeIntervalSince1970: 1_800_000_000),
            passesHelped: 0,
            passesPendingKarma: 0,
            lastAlias: nil
        ))
        XCTAssertNil(store.load())
    }

    func testNilDefaults_isNoOp() {
        let store = ClipHandoffContextStore(defaults: nil)
        store.save(ClipHandoffContext(
            userId: "u-1",
            firstPassAt: Date(),
            passesHelped: 0,
            passesPendingKarma: 0,
            lastAlias: nil
        ))
        XCTAssertNil(store.load())
    }
}
