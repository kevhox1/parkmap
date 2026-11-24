//
//  ParkingAddressResolverTests.swift
//  WeParkTests
//
//  Address-anchored parking stream C (docs/specs/address-anchored-parking.md sections 3.2-3.4,
//  11): probe geometry, validation, confidence tiers, retry, parity, cache, throttle (fake
//  clock), back-off, timeout, and the coordinator's trigger rules (one settle = one call,
//  nothing during rapid changes, a new block invalidates).
//
//  Compile-failure-class notes: the geocoder fake is an `actor` conforming to the `nonisolated`
//  `ReverseGeocoding` protocol; the clock is a lock-guarded `@unchecked Sendable` class; the
//  coordinator is `@MainActor`, so its tests are `@MainActor`; pure helpers are `nonisolated` and
//  called directly; no XCTestCase extensions; no bare `Category`.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fakes

private actor PAFakeGeocoder: ReverseGeocoding {
    private var responses: [Result<[GeocodedPlacemark], Error>]
    private(set) var calls: [CLLocationCoordinate2D] = []
    private let delay: Duration?

    init(_ responses: [Result<[GeocodedPlacemark], Error>], delay: Duration? = nil) {
        self.responses = responses
        self.delay = delay
    }

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> [GeocodedPlacemark] {
        calls.append(coordinate)
        if let delay { try await Task.sleep(for: delay) }
        guard !responses.isEmpty else { return [] }
        let next = responses.count > 1 ? responses.removeFirst() : responses[0]
        return try next.get()
    }

    func callCount() -> Int { calls.count }
    func call(at index: Int) -> CLLocationCoordinate2D? { calls.indices.contains(index) ? calls[index] : nil }
}

private final class PAFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private struct PATestError: Error {}

// MARK: - Helpers

/// East-west curb at northing 0 from x = -50 to +50 (100 m), as `[[lat, lng]]`.
private func paLine() -> [[Double]] {
    [(-50.0, 0.0), (50.0, 0.0)].map { point in
        let c = CurbSnapTestFixtures.coordinate(x: point.0, y: point.1)
        return [c.latitude, c.longitude]
    }
}

private func paRequest(
    id: String = "SEG_E1",
    side: String = "N",
    street: String = "E 1 ST",
    fraction: Double = 0.5
) -> ParkingAddressRequest {
    ParkingAddressRequest(segmentID: id, side: side, street: street, line: paLine(), positionFraction: fraction)
}

/// A placemark located at the probe point the resolver will use for `request` at `fraction`.
private func paPlacemark(
    street: String? = "East 1st Street",
    number: String? = "123",
    request: ParkingAddressRequest,
    fraction: Double? = nil,
    metersOff: Double = 0
) -> GeocodedPlacemark {
    let probe = ParkingAddressGeometry.probePoint(
        line: request.line, fraction: fraction ?? request.positionFraction, side: request.side
    )
    let coordinate = probe.map {
        CLLocationCoordinate2D(latitude: $0.latitude + metersOff / 111_320.0, longitude: $0.longitude)
    }
    return GeocodedPlacemark(thoroughfare: street, subThoroughfare: number, coordinate: coordinate)
}

private func paResolver(
    _ geocoder: ReverseGeocoding,
    clock: PAFakeClock,
    configure: (inout ParkingAddressResolver.Config) -> Void = { _ in }
) -> ParkingAddressResolver {
    var config = ParkingAddressResolver.Config()
    configure(&config)
    return ParkingAddressResolver(geocoder: geocoder, config: config, now: { clock.now })
}

private func paMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    ParkingAddressGeometry.distanceMeters(a, b)
}

// MARK: - Geometry

final class ParkingAddressGeometryTests: XCTestCase {

    private func line(_ points: [(Double, Double)]) -> [[Double]] {
        points.map { point in
            let c = CurbSnapTestFixtures.coordinate(x: point.0, y: point.1)
            return [c.latitude, c.longitude]
        }
    }

    private func assertProbe(
        _ probe: CLLocationCoordinate2D?, x: Double, y: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let probe else { return XCTFail("nil probe", file: file, line: line) }
        let expected = CurbSnapTestFixtures.coordinate(x: x, y: y)
        XCTAssertLessThan(paMeters(probe, expected), 0.2, file: file, line: line)
    }

    func testEastWestBlockface_northSide_probeIsNorth() {
        let probe = ParkingAddressGeometry.probePoint(line: line([(-50, 0), (50, 0)]), fraction: 0.5, side: "N")
        assertProbe(probe, x: 0, y: 8)
    }

    func testEastWestBlockface_southSide_probeIsSouth() {
        let probe = ParkingAddressGeometry.probePoint(line: line([(-50, 0), (50, 0)]), fraction: 0.5, side: "S")
        assertProbe(probe, x: 0, y: -8)
    }

    func testNorthSouthBlockface_eastAndWest() {
        let ns = line([(0, -50), (0, 50)])
        assertProbe(ParkingAddressGeometry.probePoint(line: ns, fraction: 0.5, side: "E"), x: 8, y: 0)
        assertProbe(ParkingAddressGeometry.probePoint(line: ns, fraction: 0.5, side: "W"), x: -8, y: 0)
    }

    func testReversedDrawingDirection_doesNotFlipTheSide() {
        let reversed = line([(50, 0), (-50, 0)])
        assertProbe(ParkingAddressGeometry.probePoint(line: reversed, fraction: 0.5, side: "N"), x: 0, y: 8)
    }

    func testDiagonalHoustonShapedBlockface_northSideLeansNorthWest() {
        let diagonal = line([(0, 0), (50, 50)])
        let probe = ParkingAddressGeometry.probePoint(line: diagonal, fraction: 0.5, side: "N")
        let half = 8.0 / 2.0.squareRoot()
        assertProbe(probe, x: 25 - half, y: 25 + half)
    }

    func testFractionWalksTheCumulativeLength() {
        let bent = line([(0, 0), (30, 0), (30, 30)])
        // 60 m total; fraction 0.75 is 45 m along = 15 m up the second leg (side "E": x = 38).
        assertProbe(ParkingAddressGeometry.probePoint(line: bent, fraction: 0.75, side: "E"), x: 38, y: 15)
    }

    func testDegenerateInputs_returnNil() {
        XCTAssertNil(ParkingAddressGeometry.probePoint(line: [], fraction: 0.5, side: "N"))
        XCTAssertNil(ParkingAddressGeometry.probePoint(line: line([(0, 0), (0, 0)]), fraction: 0.5, side: "N"))
        XCTAssertNil(ParkingAddressGeometry.probePoint(line: line([(-5, 0), (5, 0)]), fraction: 0.5, side: "X"))
    }
}

// MARK: - Validator

final class ParkingAddressValidatorTests: XCTestCase {

    func testParseHouseNumber() {
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber("123"), "123")
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber("123-125"), "123")
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber("123A"), "123A")
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber("123a"), "123A")
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber(" 45 "), "45")
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber("123 1/2"), "123")
        XCTAssertEqual(ParkingAddressValidator.parseHouseNumber("123 Apt 4"), "123")
        XCTAssertNil(ParkingAddressValidator.parseHouseNumber("Pier 40"))
        XCTAssertNil(ParkingAddressValidator.parseHouseNumber(""))
        XCTAssertNil(ParkingAddressValidator.parseHouseNumber(nil))
    }

    func testParity() {
        XCTAssertEqual(ParkingAddressValidator.parity(of: "123"), 1)
        XCTAssertEqual(ParkingAddressValidator.parity(of: "124B"), 0)
        XCTAssertNil(ParkingAddressValidator.parity(of: "A"))
    }

    func testStreetMatch_usesCanonicalKey() {
        XCTAssertTrue(ParkingAddressValidator.streetMatches(thoroughfare: "East 1st Street", segmentStreet: "E 1 ST"))
        XCTAssertTrue(ParkingAddressValidator.streetMatches(thoroughfare: "1st Avenue", segmentStreet: "1 AVE"))
        XCTAssertTrue(ParkingAddressValidator.streetMatches(thoroughfare: "Chrystie Street", segmentStreet: "CHRYSTIE STREET"))
        XCTAssertFalse(ParkingAddressValidator.streetMatches(thoroughfare: "2nd Avenue", segmentStreet: "E 1 ST"))
        XCTAssertFalse(ParkingAddressValidator.streetMatches(thoroughfare: nil, segmentStreet: "E 1 ST"))
    }
}

// MARK: - Resolver

final class ParkingAddressResolverTests: XCTestCase {

    private func resolved(_ resolution: ParkingAddressResolution) -> ParkingAddress? {
        if case .resolved(let address) = resolution { return address }
        return nil
    }

    private func isBlockOnly(_ resolution: ParkingAddressResolution) -> Bool {
        if case .blockOnly = resolution { return true }
        return false
    }

    private func isUnavailable(_ resolution: ParkingAddressResolution) -> Bool {
        if case .unavailable = resolution { return true }
        return false
    }

    func testMatch_isVerified() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())

        let address = resolved(await resolver.resolve(request))

        XCTAssertEqual(address?.houseNumber, "123")
        XCTAssertEqual(address?.confidence, .verified)
        XCTAssertEqual(address?.source, .mapkit)
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testProbeIsOffsetTowardTheSnappedSide() async {
        let request = paRequest(side: "N")
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())
        _ = await resolver.resolve(request)

        let curb = CurbSnapTestFixtures.coordinate(x: 0, y: 0)
        guard let probe = await geocoder.call(at: 0) else { return XCTFail("no geocode call") }
        XCTAssertEqual(paMeters(probe, curb), 8, accuracy: 0.3)
        XCTAssertGreaterThan(probe.latitude, curb.latitude, "north-side blockface probes north of the curb")
    }

    func testStreetMismatch_retriesOnce_andResultIsApproximate() async {
        let request = paRequest(fraction: 0.5)
        // 0.5 is not < 0.5, so the retry steps back 0.15 to 0.35.
        let geocoder = PAFakeGeocoder([
            .success([paPlacemark(street: "2nd Avenue", number: "9", request: request)]),
            .success([paPlacemark(street: "East 1st Street", number: "125", request: request, fraction: 0.35)])
        ])
        let resolver = paResolver(geocoder, clock: PAFakeClock())

        let address = resolved(await resolver.resolve(request))

        XCTAssertEqual(address?.houseNumber, "125")
        XCTAssertEqual(address?.confidence, .approximate, "found via the offset retry is never 'verified'")
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 2)
        let first = await geocoder.call(at: 0)
        let second = await geocoder.call(at: 1)
        if let first, let second {
            XCTAssertGreaterThan(paMeters(first, second), 10, "retry probes further along the block")
        } else {
            XCTFail("expected two geocode calls")
        }
    }

    func testStreetMismatchTwice_isBlockOnly_neverRelabelsToTheOtherStreet() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(street: "2nd Avenue", number: "9", request: request)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())

        let resolution = await resolver.resolve(request)

        XCTAssertTrue(isBlockOnly(resolution))
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testNoHouseNumber_isBlockOnly() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(number: nil, request: request)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())
        let resolution = await resolver.resolve(request)
        XCTAssertTrue(isBlockOnly(resolution))
    }

    func testFarPlacemark_isDemotedToApproximate() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request, metersOff: 60)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())
        let address = resolved(await resolver.resolve(request))
        XCTAssertEqual(address?.confidence, .approximate)
    }

    func testParityConflict_demotesToApproximate_consistentParityStaysVerified() async {
        let first = paRequest(fraction: 0.5)
        let second = paRequest(fraction: 0.8)
        let third = paRequest(fraction: 0.2)
        let geocoder = PAFakeGeocoder([
            .success([paPlacemark(number: "123", request: first)]),
            .success([paPlacemark(number: "124", request: second)]),
            .success([paPlacemark(number: "125", request: third)])
        ])
        let resolver = paResolver(geocoder, clock: PAFakeClock())

        let a = resolved(await resolver.resolve(first))
        let b = resolved(await resolver.resolve(second))
        let c = resolved(await resolver.resolve(third))

        XCTAssertEqual(a?.confidence, .verified)
        XCTAssertEqual(b?.confidence, .approximate, "even number on a block where an odd one was verified")
        XCTAssertEqual(c?.confidence, .verified)
    }

    func testOfflineFailure_isUnavailable_andBacksOffThirtySeconds() async {
        let clock = PAFakeClock()
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.failure(PATestError()), .success([paPlacemark(request: request)])])
        let resolver = paResolver(geocoder, clock: clock)

        let first = await resolver.resolve(request)
        XCTAssertTrue(isUnavailable(first))

        clock.advance(10)
        let during = await resolver.resolve(request)
        XCTAssertTrue(isUnavailable(during), "inside the back-off window: no geocode at all")
        let callsDuring = await geocoder.callCount()
        XCTAssertEqual(callsDuring, 1)

        clock.advance(25)
        let after = resolved(await resolver.resolve(request))
        XCTAssertEqual(after?.houseNumber, "123")
    }

    func testNoResult_isBlockOnly_andBacksOff() async {
        let clock = PAFakeClock()
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([])])
        let resolver = paResolver(geocoder, clock: clock)

        let first = await resolver.resolve(request)
        XCTAssertTrue(isBlockOnly(first))
        let second = await resolver.resolve(paRequest(id: "OTHER"))
        XCTAssertTrue(isUnavailable(second))
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testThrottle_maxSixPerMinute_thenRecovers() async {
        let clock = PAFakeClock()
        // Distinct blocks so nothing is cached; a verified match each time.
        var requests: [ParkingAddressRequest] = []
        for index in 0..<7 { requests.append(paRequest(id: "SEG_\(index)")) }
        let matching = requests.map { Result<[GeocodedPlacemark], Error>.success([paPlacemark(request: $0)]) }
        let matchingGeocoder = PAFakeGeocoder(matching)
        let resolver = paResolver(matchingGeocoder, clock: clock)

        for index in 0..<6 {
            let address = resolved(await resolver.resolve(requests[index]))
            XCTAssertNotNil(address, "request \(index) is within the 6/min budget")
        }
        let seventh = await resolver.resolve(requests[6])
        XCTAssertTrue(isUnavailable(seventh))
        let callsAtLimit = await matchingGeocoder.callCount()
        XCTAssertEqual(callsAtLimit, 6)

        clock.advance(61)
        let recovered = resolved(await resolver.resolve(requests[6]))
        XCTAssertNotNil(recovered)
    }

    func testCache_sameBucketIsOneGeocode() async {
        let request = paRequest(fraction: 0.5)
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())

        let first = resolved(await resolver.resolve(request))
        let sameBucket = resolved(await resolver.resolve(paRequest(fraction: 0.52)))

        XCTAssertEqual(first?.houseNumber, sameBucket?.houseNumber)
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testCache_otherSideOrBucketIsAFreshGeocode() async {
        let request = paRequest(fraction: 0.5)
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock())
        _ = await resolver.resolve(request)
        _ = await resolver.resolve(paRequest(side: "S", fraction: 0.5))
        _ = await resolver.resolve(paRequest(fraction: 0.9))
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 3)
    }

    func testTimeout_isUnavailable() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])], delay: .seconds(5))
        let resolver = paResolver(geocoder, clock: PAFakeClock()) { $0.timeoutSeconds = 0.05 }
        let resolution = await resolver.resolve(request)
        XCTAssertTrue(isUnavailable(resolution))
    }

    func testCacheLimit_evictsOldest() async {
        let a = paRequest(id: "A")
        let b = paRequest(id: "B")
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: a)])])
        let resolver = paResolver(geocoder, clock: PAFakeClock()) {
            $0.cacheLimit = 1
            $0.maxRequestsPerMinute = 100
        }
        _ = await resolver.resolve(a)
        _ = await resolver.resolve(b)   // evicts A
        _ = await resolver.resolve(a)   // fresh geocode again
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 3)
    }
}

// MARK: - Coordinator

@MainActor
final class ParkingAddressCoordinatorTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeCoordinator(
        geocoder: ReverseGeocoding,
        isEnabled: Bool = true
    ) -> ParkingAddressCoordinator {
        ParkingAddressCoordinator(
            resolver: ParkingAddressResolver(geocoder: geocoder),
            debounce: .milliseconds(80),
            isEnabled: isEnabled
        )
    }

    func testSettle_isExactlyOneResolverCall() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let coordinator = makeCoordinator(geocoder: geocoder)

        coordinator.placementSnapChanged(request)
        coordinator.placementSnapChanged(request)   // same key again (e.g. settle after outcome): no-op
        await waitUntil { coordinator.placementAddress != nil }
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(coordinator.placementAddress?.houseNumber, "123")
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testRapidChanges_neverGeocodeMidChange_onlyTheLastOneResolves() async {
        let last = paRequest(fraction: 0.9)
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: last)])])
        let coordinator = makeCoordinator(geocoder: geocoder)

        coordinator.placementSnapChanged(paRequest(fraction: 0.1))
        coordinator.placementSnapChanged(paRequest(fraction: 0.4))
        coordinator.placementSnapChanged(last)
        await waitUntil { coordinator.placementAddress != nil }
        try? await Task.sleep(for: .milliseconds(150))

        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 1, "a live drag (changes inside the debounce) causes no geocode")
    }

    func testMovingToAnotherBlock_clearsTheStaleAddressImmediately() async {
        let request = paRequest(id: "BLOCK_A")
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let coordinator = makeCoordinator(geocoder: geocoder)

        coordinator.placementSnapChanged(request)
        await waitUntil { coordinator.placementAddress != nil }
        XCTAssertNotNil(coordinator.placementAddress)

        coordinator.placementSnapChanged(paRequest(id: "BLOCK_B"))
        XCTAssertNil(coordinator.placementAddress, "never show the previous block's address on the new block")
    }

    func testNoCurb_clearsAndCancels() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let coordinator = makeCoordinator(geocoder: geocoder)

        coordinator.placementSnapChanged(request)
        coordinator.placementSnapChanged(nil)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(coordinator.placementAddress)
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testFlagOff_neverGeocodes() async {
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let coordinator = makeCoordinator(geocoder: geocoder, isEnabled: false)

        coordinator.placementSnapChanged(request)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(coordinator.placementAddress)
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testEnsureAddress_fillsACarWithoutOne_andIsBoundedToTwoAttempts() async {
        let segment = CurbSnapTestFixtures.segment(
            id: "SEG_E1", street: "E 1 ST", from: "1 AVE", to: "2 AVE", side: "N",
            points: [(-50, 0), (50, 0)]
        )
        let car = ParkedCar(
            id: UUID(),
            latitude: CurbSnapTestFixtures.coordinate(x: 0, y: 0).latitude,
            longitude: CurbSnapTestFixtures.coordinate(x: 0, y: 0).longitude,
            detectedSegmentID: "SEG_E1",
            detectedSide: "N",
            street: "E 1 ST",
            fromStreet: "1 AVE",
            toStreet: "2 AVE",
            parkedAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let request = paRequest()
        let geocoder = PAFakeGeocoder([.success([paPlacemark(request: request)])])
        let coordinator = makeCoordinator(geocoder: geocoder)

        var applied: [(ParkingAddress, UUID)] = []
        coordinator.ensureAddress(for: car, segment: segment) { address, id in applied.append((address, id)) }
        await waitUntil { !applied.isEmpty }

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.1, car.id)
        XCTAssertEqual(applied.first?.0.confidence, .verified)

        // Resolved => no further attempts for this car.
        coordinator.ensureAddress(for: car, segment: segment) { address, id in applied.append((address, id)) }
        try? await Task.sleep(for: .milliseconds(100))
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testEnsureAddress_skipsACarThatAlreadyHasOne() async {
        let segment = CurbSnapTestFixtures.segment(
            id: "SEG_E1", street: "E 1 ST", side: "N", points: [(-50, 0), (50, 0)]
        )
        let car = ParkedCar(
            id: UUID(), latitude: 40.72, longitude: -73.98,
            detectedSegmentID: "SEG_E1", detectedSide: "N", street: "E 1 ST",
            fromStreet: nil, toStreet: nil, parkedAt: Date(timeIntervalSince1970: 1_000_000_000),
            notifyOnRestriction: true,
            address: ParkingAddress(
                houseNumber: "1", streetDisplay: "East 1st Street", confidence: .verified,
                source: .mapkit, resolvedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let geocoder = PAFakeGeocoder([])
        let coordinator = makeCoordinator(geocoder: geocoder)
        coordinator.ensureAddress(for: car, segment: segment) { _, _ in XCTFail("must not resolve") }
        try? await Task.sleep(for: .milliseconds(100))
        let calls = await geocoder.callCount()
        XCTAssertEqual(calls, 0)
    }
}
