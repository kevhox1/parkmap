//
//  ParkingAddressModelTests.swift
//  WeParkTests
//
//  Address-anchored parking stream B (docs/specs/address-anchored-parking.md sections 4, 5):
//  `ParkedCar.address` backward-compatible Codable, iCloud merge carrying the address, the
//  display / VoiceOver / notification copy, the card model's address line + reserved layout row,
//  and the dark flag.
//
//  Compile-failure-class notes: all pure statics are `nonisolated`; the memberwise `ParkedCar`
//  init is called with labels in declaration order (`notifyOnRestriction` before `address`);
//  no XCTestCase extensions; no bare `Category`.
//

import XCTest
import CoreLocation
@testable import WePark

private let paFixedDate = Date(timeIntervalSince1970: 1_800_000_000)
private let paParkedAt = Date(timeIntervalSince1970: 1_000_000_000)

private func paAddress(
    number: String = "123",
    street: String = "East 1st Street",
    confidence: ParkingAddress.Confidence = .verified
) -> ParkingAddress {
    ParkingAddress(
        houseNumber: number, streetDisplay: street,
        confidence: confidence, source: .mapkit, resolvedAt: paFixedDate
    )
}

private func paCar(id: UUID = UUID(), address: ParkingAddress? = nil) -> ParkedCar {
    ParkedCar(
        id: id,
        latitude: 40.7236,
        longitude: -73.9877,
        detectedSegmentID: "SEG_E1",
        detectedSide: "N",
        street: "E 1 ST",
        fromStreet: "1 AVE",
        toStreet: "2 AVE",
        parkedAt: paParkedAt,
        notifyOnRestriction: true,
        address: address
    )
}

// MARK: - Codable

final class ParkedCarAddressCodableTests: XCTestCase {

    /// A blob written before this feature: no `address` key at all.
    private let preFeatureJSON = """
    {"id":"6E4C7D3A-1111-4222-8333-444455556666","latitude":40.7236,"longitude":-73.9877,
     "detectedSegmentID":"SEG_E1","detectedSide":"N","street":"E 1 ST","fromStreet":"1 AVE",
     "toStreet":"2 AVE","parkedAt":0,"notifyOnRestriction":false}
    """

    func testPreFeatureJSON_decodesWithNilAddress() throws {
        let car = try JSONDecoder().decode(ParkedCar.self, from: Data(preFeatureJSON.utf8))
        XCTAssertNil(car.address)
        XCTAssertFalse(car.notifyOnRestriction)
    }

    func testRoundTrip_preservesAddress() throws {
        let original = paCar(address: paAddress(number: "123A", confidence: .approximate))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ParkedCar.self, from: data)
        XCTAssertEqual(decoded.address, original.address)
        XCTAssertEqual(decoded.id, original.id)
    }

    func testNilAddress_isOmittedFromEncodedJSON() throws {
        let data = try JSONEncoder().encode(paCar(address: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["address"], "nil must be omitted so older builds see an unchanged shape")
    }

    /// The shape an OLDER build decodes with: it has no `address` field and must ignore the key.
    private struct LegacyShapeCar: Codable {
        let id: UUID
        let latitude: Double
        let longitude: Double
        let street: String?
        let parkedAt: Date
    }

    func testNewJSON_decodesOnOldShapeStruct() throws {
        let data = try JSONEncoder().encode(paCar(address: paAddress()))
        let legacy = try JSONDecoder().decode(LegacyShapeCar.self, from: data)
        XCTAssertEqual(legacy.street, "E 1 ST")
    }

    func testWithAddress_keepsIdentityAndEveryOtherField() {
        let car = paCar()
        let filled = car.withAddress(paAddress())
        XCTAssertEqual(filled.id, car.id)
        XCTAssertEqual(filled.detectedSegmentID, car.detectedSegmentID)
        XCTAssertEqual(filled.notifyOnRestriction, car.notifyOnRestriction)
        XCTAssertEqual(filled.address, paAddress())
    }
}

// MARK: - ParkPinService

final class ParkPinServiceAddressTests: XCTestCase {

    private let suiteName = "com.wepark.test.parkpinserviceaddress"
    private var defaults: UserDefaults!
    private var store: MockUbiquitousStore!
    private var service: ParkPinService!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)
        store = MockUbiquitousStore()
        if let defaults {
            service = ParkPinService(cloudStore: store, defaults: defaults)
        }
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        service = nil
        super.tearDown()
    }

    func testUpdateAddress_sameCarId_persistsAndBumpsUpdatedAt() {
        let car = paCar()
        service.save(car)
        let before = service.currentUpdatedAt

        let updated = service.updateAddress(paAddress(), forCarID: car.id)

        XCTAssertEqual(updated?.id, car.id, "address filled in later is the same car, not a new one")
        XCTAssertEqual(service.parkedCar?.address, paAddress())
        XCTAssertEqual(store.decodedEnvelope(forKey: "wepark_synced_car_state")?.car?.address, paAddress())
        XCTAssertNotNil(before)
        if let before, let after = service.currentUpdatedAt {
            XCTAssertGreaterThan(after, before)
        }
    }

    func testUpdateAddress_staleCarId_isIgnored() {
        service.save(paCar())
        XCTAssertNil(service.updateAddress(paAddress(), forCarID: UUID()))
        XCTAssertNil(service.parkedCar?.address)
    }

    func testNotifyToggle_keepsTheAddress() {
        service.save(paCar(address: paAddress()))
        service.updateNotifyOnRestriction(false)
        XCTAssertEqual(service.parkedCar?.address, paAddress())
        XCTAssertEqual(service.parkedCar?.notifyOnRestriction, false)
    }

    func testRemoteChange_carryingAnAddress_keepsIt() {
        let remote = paCar(address: paAddress())
        store.seed(
            SyncedCarEnvelope(kind: .parked, updatedAt: Date(timeIntervalSince1970: 9_000_000_000), car: remote),
            forKey: "wepark_synced_car_state"
        )
        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)
        XCTAssertEqual(service.parkedCar?.address, paAddress())
    }
}

// MARK: - Copy

final class ParkingAddressCopyTests: XCTestCase {

    func testLine_verifiedAndApproximate() {
        XCTAssertEqual(ParkingAddressCopy.line(paAddress()), "In front of 123 E 1st St")
        XCTAssertEqual(ParkingAddressCopy.line(paAddress(confidence: .approximate)), "Near 123 E 1st St")
    }

    func testLine_ordinalsFromGeocodedAndCanonicalSpellings() {
        XCTAssertEqual(ParkingAddressCopy.line(paAddress(number: "40", street: "West 42nd Street")), "In front of 40 W 42nd St")
        XCTAssertEqual(ParkingAddressCopy.line(paAddress(number: "9", street: "1 AVE")), "In front of 9 1st Ave")
    }

    func testSpoken_verifiedAndApproximate() {
        XCTAssertEqual(ParkingAddressCopy.spoken(paAddress()), "Parking in front of 123 East 1st Street")
        XCTAssertEqual(
            ParkingAddressCopy.spoken(paAddress(confidence: .approximate)),
            "Near 123 East 1st Street, number approximate"
        )
    }

    func testNotificationSentence_verifiedOnly() {
        XCTAssertEqual(ParkingAddressCopy.notificationSentence(paAddress()), "Your car is in front of 123 E 1st St.")
        XCTAssertNil(ParkingAddressCopy.notificationSentence(paAddress(confidence: .approximate)))
        XCTAssertNil(ParkingAddressCopy.notificationSentence(nil))
    }

    func testShareText_includesAddress() {
        XCTAssertEqual(ParkingAddressCopy.shareText(paAddress()), "Parked in front of 123 E 1st St (WePark)")
        XCTAssertEqual(
            ParkingAddressCopy.shareText(paAddress(confidence: .approximate)),
            "Parked near 123 E 1st St (WePark)"
        )
    }
}

// MARK: - Card model + layout

final class CurbPlacementCardAddressTests: XCTestCase {

    private func snappedModel() -> CurbPlacementCardModel {
        let segment = CurbSnapTestFixtures.segment(
            id: "PA_SNAP", street: "E 1 ST", from: "1 AVE", to: "2 AVE", side: "N",
            points: [(-10, 0), (10, 0)]
        )
        let outcome = CurbSnapOutcome.snapped(CurbSnapResult(
            segment: segment,
            positionFraction: 0.5,
            distanceMeters: 3,
            snappedCoordinate: CurbSnapTestFixtures.coordinate(x: 0, y: 0)
        ))
        return CurbPlacementCardModel.make(
            outcome: outcome, intent: .park, communityEnabled: false, engine: ParkingRulesEngine(),
            now: paFixedDate, dataStatus: .ready, oppositeSideLoaded: true, nearestCurb: nil,
            usesMetricSystem: false
        )
    }

    func testTitleAndSubtitle_restoreOrdinals() {
        let model = snappedModel()
        XCTAssertEqual(model.title, "E 1st St \u{00B7} North side")
        XCTAssertEqual(model.subtitle, "between 1st Ave & 2nd Ave")
        XCTAssertTrue(model.voiceOverLabel.hasPrefix("East 1st Street"))
    }

    func testWithAddress_setsLineAndSpokenValue() {
        let model = snappedModel().withAddress(paAddress(), reservesRow: true)
        XCTAssertEqual(model.addressLine, "In front of 123 E 1st St")
        XCTAssertTrue(model.reservesAddressRow)
        XCTAssertTrue(model.voiceOverValue.hasPrefix("Parking in front of 123 East 1st Street. between"))
    }

    func testWithAddress_nilAddress_reservesRowButShowsNothing_andVoiceOverIsUnchanged() {
        let base = snappedModel()
        let model = base.withAddress(nil, reservesRow: true)
        XCTAssertNil(model.addressLine)
        XCTAssertTrue(model.reservesAddressRow)
        XCTAssertEqual(model.voiceOverValue, base.voiceOverValue)
    }

    func testWithAddress_flagOff_isInert() {
        let base = snappedModel()
        let model = base.withAddress(paAddress(), reservesRow: false)
        XCTAssertNil(model.addressLine)
        XCTAssertFalse(model.reservesAddressRow)
        XCTAssertEqual(model.voiceOverValue, base.voiceOverValue)
    }

    func testWithAddress_neverShownInNonSnappedStates() {
        let loading = CurbPlacementCardModel.make(
            outcome: nil, intent: .park, communityEnabled: false, engine: ParkingRulesEngine(),
            now: paFixedDate, dataStatus: .loading, oppositeSideLoaded: false, nearestCurb: nil,
            usesMetricSystem: false
        ).withAddress(paAddress(), reservesRow: true)
        XCTAssertNil(loading.addressLine)
    }

    func testLayout_flagOffBudgetUnchanged_flagOnAddsOneSubtitleRow() {
        let config = CurbPlacementCardLayout.candidates[0]
        for tier in [CurbPlacementSizeTier.standard, .extended, .accessibility] {
            let base = CurbPlacementCardLayout.contentHeight(tier: tier, config: config, wantsLink: false)
            let off = CurbPlacementCardLayout.contentHeight(tier: tier, config: config, wantsLink: false, wantsAddress: false)
            let on = CurbPlacementCardLayout.contentHeight(tier: tier, config: config, wantsLink: false, wantsAddress: true)
            let m = CurbPlacementCardMetrics.metrics(for: tier)
            XCTAssertEqual(off, base)
            XCTAssertEqual(on, base + CurbPlacementCardLayout.chipToSubtitle + m.subtitle)
        }
    }

    func testLayout_addressRowDropsWithTheSubtitle() {
        let noSubtitle = CurbPlacementCardConfig(tipFraction: 0.30, link: .none, showsSubtitle: false)
        XCTAssertEqual(
            CurbPlacementCardLayout.contentHeight(tier: .standard, config: noSubtitle, wantsLink: false, wantsAddress: true),
            CurbPlacementCardLayout.contentHeight(tier: .standard, config: noSubtitle, wantsLink: false)
        )
    }

    func testLayout_tallPhoneStillFitsStandardTierWithAddressRow() {
        let r = CurbPlacementCardLayout.select(
            tier: .standard, fullHeight: 874, bottomInset: 34, wantsLink: false, wantsAddress: true
        )
        XCTAssertTrue(r.fits)
    }

    func testFlag_darkShipsOff() {
        XCTAssertFalse(AppConstants.addressAnchoredParkingEnabled)
    }
}
