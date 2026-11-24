//
//  ParkingAddressResolver.swift
//  WePark
//
//  Address-anchored parking, MVP (docs/specs/address-anchored-parking.md sections 3.1-3.3):
//  reverse-geocode a point just BEHIND the snapped curb, validate the result against the snapped
//  blockface, and grade it verified / approximate / block-only.
//
//  Pieces, all `nonisolated` (the module defaults to MainActor isolation, so pure helpers that
//  tests and the resolver actor call need it explicitly):
//    - `ReverseGeocoding`            injectable geocoder seam (tests use a fake).
//    - `MapKitReverseGeocoder`       the real one (CLGeocoder, English locale so "East 1st
//                                    Street" canonicalizes the same on every device language).
//    - `ParkingAddressGeometry`      probe point: 8 m perpendicular to the blockface axis,
//                                    toward the snapped side's buildings.
//    - `ParkingAddressValidator`     street match (via `StreetNameNormalizer.canonical`), house
//                                    number parse, parity, distance bound, confidence.
//    - `ParkingAddressResolver`      actor: 1 in flight, max 6 requests/min, 10 s timeout, 30 s
//                                    back-off on failure, in-memory LRU of 200. Never persists.
//
//  The address NEVER changes which blockface rules apply (the legal anchor is the segment id +
//  side); a geocode naming a different street is discarded, never re-snapped.
//
//  PRIVACY: never log an address or a coordinate. The geocode request goes to Apple only.
//

import Foundation
import CoreLocation

// MARK: - Geocoder seam

nonisolated struct GeocodedPlacemark {
    let thoroughfare: String?
    let subThoroughfare: String?
    let coordinate: CLLocationCoordinate2D?
}

nonisolated protocol ReverseGeocoding: Sendable {
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> [GeocodedPlacemark]
}

/// MapKit-family reverse geocoding (deployment target is iOS 17, so `CLGeocoder`).
nonisolated struct MapKitReverseGeocoder: ReverseGeocoding {
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> [GeocodedPlacemark] {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let marks = try await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "en_US")
        )
        return marks.map {
            GeocodedPlacemark(
                thoroughfare: $0.thoroughfare,
                subThoroughfare: $0.subThoroughfare,
                coordinate: $0.location?.coordinate
            )
        }
    }
}

// MARK: - Geometry

nonisolated enum ParkingAddressGeometry {

    /// How far behind the curb (toward the buildings) the geocode probe sits.
    static let probeOffsetMeters = 8.0

    private static let metersPerDegreeLat = 111_320.0

    /// The probe point for a blockface: from the curb point at `fraction` along `line`
    /// (`[[lat, lng]]`, the tile convention), step `offsetMeters` perpendicular to the local
    /// axis, on the side whose normal points toward the segment's compass `side` ("N"/"S"/"E"/"W").
    /// Nil for a degenerate line or an unknown side.
    static func probePoint(
        line: [[Double]],
        fraction: Double,
        side: String,
        offsetMeters: Double = probeOffsetMeters
    ) -> CLLocationCoordinate2D? {
        guard let sideVector = compassVector(side),
              let spot = pointAndTangent(line: line, fraction: fraction) else { return nil }
        // Work in local east/north metres around the curb point.
        let tangent = spot.tangent
        let left = (east: -tangent.north, north: tangent.east)
        let right = (east: tangent.north, north: -tangent.east)
        let leftDot = left.east * sideVector.east + left.north * sideVector.north
        let rightDot = right.east * sideVector.east + right.north * sideVector.north
        let normal = rightDot > leftDot ? right : left
        let metersPerDegreeLng = metersPerDegreeLat * cos(spot.point.latitude * Double.pi / 180)
        guard metersPerDegreeLng > 0 else { return nil }
        return CLLocationCoordinate2D(
            latitude: spot.point.latitude + (normal.north * offsetMeters) / metersPerDegreeLat,
            longitude: spot.point.longitude + (normal.east * offsetMeters) / metersPerDegreeLng
        )
    }

    /// The point at `fraction` of the polyline's length (cumulative-length convention, same as
    /// `CandidateSegmentSearch.nearestPointOnPolyline`) and the unit tangent (east, north) of the
    /// edge it falls on. Nil if the line has no length.
    static func pointAndTangent(
        line: [[Double]],
        fraction: Double
    ) -> (point: CLLocationCoordinate2D, tangent: (east: Double, north: Double))? {
        let points = line.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
        guard points.count >= 2 else { return nil }
        var lengths: [Double] = []
        var total = 0.0
        for i in 1..<points.count {
            let edge = localDelta(from: points[i - 1], to: points[i])
            let length = (edge.east * edge.east + edge.north * edge.north).squareRoot()
            lengths.append(length)
            total += length
        }
        guard total > 0 else { return nil }
        let target = min(1, max(0, fraction)) * total
        var walked = 0.0
        for i in 1..<points.count {
            let length = lengths[i - 1]
            guard length > 0 else { continue }
            if walked + length >= target || i == points.count - 1 {
                let t = min(1, max(0, (target - walked) / length))
                let a = points[i - 1]
                let b = points[i]
                let edge = localDelta(from: a, to: b)
                let point = CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
                return (point, (edge.east / length, edge.north / length))
            }
            walked += length
        }
        return nil
    }

    /// Great-circle-ish distance in metres (haversine).
    static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * Double.pi / 180
        let dLng = (b.longitude - a.longitude) * Double.pi / 180
        let lat1 = a.latitude * Double.pi / 180
        let lat2 = b.latitude * Double.pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * asin(min(1, h.squareRoot()))
    }

    private static func localDelta(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> (east: Double, north: Double) {
        let midLat = (a.latitude + b.latitude) / 2
        let east = (b.longitude - a.longitude) * metersPerDegreeLat * cos(midLat * Double.pi / 180)
        let north = (b.latitude - a.latitude) * metersPerDegreeLat
        return (east, north)
    }

    private static func compassVector(_ side: String) -> (east: Double, north: Double)? {
        switch side.uppercased() {
        case "N": return (0, 1)
        case "S": return (0, -1)
        case "E": return (1, 0)
        case "W": return (-1, 0)
        default:  return nil
        }
    }
}

// MARK: - Validation

nonisolated enum ParkingAddressValidator {

    /// A placemark farther than this from the probe is demoted to approximate.
    static let maxPlacemarkDistanceMeters = 40.0

    nonisolated enum Verdict {
        /// The geocoded street is not the snapped street (corner building facing the avenue).
        case streetMismatch
        /// Right street, no house number: block-only.
        case noNumber
        case address(houseNumber: String, streetDisplay: String, confidence: ParkingAddress.Confidence)
    }

    /// Leading digits; "123-125" -> "123", "123A" -> "123A", "123 1/2" -> "123". Nil if none.
    static func parseHouseNumber(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        if let letter = rest.first, letter.isASCII, letter.isLetter {
            // "123A" keeps its letter, but only when the letter ends the token ("123A", not "123 Apt").
            let afterLetter = rest.dropFirst()
            if afterLetter.isEmpty || !(afterLetter.first?.isLetter ?? false) {
                return String(digits) + String(letter).uppercased()
            }
        }
        return String(digits)
    }

    /// 0 even / 1 odd from the number's leading digits; nil if unparseable.
    static func parity(of houseNumber: String) -> Int? {
        let digits = houseNumber.prefix(while: { $0.isASCII && $0.isNumber })
        guard let value = Int(digits) else { return nil }
        return value % 2
    }

    /// Canonical equality, the same matching key the rest of the app uses. Never loosened.
    static func streetMatches(thoroughfare: String?, segmentStreet: String) -> Bool {
        guard let thoroughfare, !thoroughfare.isEmpty, !segmentStreet.isEmpty else { return false }
        return StreetNameNormalizer.canonical(thoroughfare) == StreetNameNormalizer.canonical(segmentStreet)
    }

    /// Grades one placemark. `priorParity` is the parity of an already-verified address on the
    /// same blockface side (nil if none yet). A result found via the offset retry is never
    /// better than approximate.
    static func evaluate(
        placemark: GeocodedPlacemark,
        segmentStreet: String,
        probe: CLLocationCoordinate2D,
        priorParity: Int?,
        viaRetry: Bool
    ) -> Verdict {
        guard streetMatches(thoroughfare: placemark.thoroughfare, segmentStreet: segmentStreet),
              let thoroughfare = placemark.thoroughfare else {
            return .streetMismatch
        }
        guard let number = parseHouseNumber(placemark.subThoroughfare) else { return .noNumber }

        var confidence = ParkingAddress.Confidence.verified
        if viaRetry { confidence = .approximate }
        if let prior = priorParity, let mine = parity(of: number), prior != mine {
            confidence = .approximate
        }
        if let coordinate = placemark.coordinate {
            if ParkingAddressGeometry.distanceMeters(coordinate, probe) > maxPlacemarkDistanceMeters {
                confidence = .approximate
            }
        } else {
            // No location to bound the distance with: cannot prove "in front of".
            confidence = .approximate
        }
        return .address(houseNumber: number, streetDisplay: thoroughfare, confidence: confidence)
    }
}

// MARK: - Request / result

/// Everything the resolver needs about the snapped curb point, as plain values (Sendable).
nonisolated struct ParkingAddressRequest: Sendable {
    let segmentID: String
    /// "N" | "S" | "E" | "W".
    let side: String
    /// The segment's street as stored in the tile ("E 1 ST" / "EAST 1ST STREET").
    let street: String
    /// `[[lat, lng]]`, the tile polyline.
    let line: [[Double]]
    /// Position of the snapped curb point along the line, [0, 1].
    let positionFraction: Double
}

nonisolated enum ParkingAddressResolution {
    case resolved(ParkingAddress)
    /// Geocoded fine, but no usable number / no result: show nothing. Not worth retrying.
    case blockOnly
    /// Offline, timed out, throttled or backed off: show nothing; one retry on next foreground.
    case unavailable
}

// MARK: - Resolver

actor ParkingAddressResolver {

    nonisolated struct Config: Sendable {
        var maxRequestsPerMinute = 6
        var timeoutSeconds = 10.0
        var backoffSeconds = 30.0
        var cacheLimit = 200
        var retryFractionOffset = 0.15
        var fractionClamp = 0.05...0.95
        /// Bucket width of the cache key's position fraction.
        var fractionBucket = 0.1
    }

    private nonisolated struct CacheEntry {
        let segmentID: String
        let side: String
        let resolution: ParkingAddressResolution
    }

    private nonisolated enum AttemptOutcome {
        case verdict(ParkingAddressValidator.Verdict)
        case noResult
        case failed
        case throttled
    }

    private nonisolated struct TimeoutError: Error {}

    private let geocoder: ReverseGeocoding
    private let now: @Sendable () -> Date
    private let config: Config

    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private var requestTimes: [Date] = []
    private var backoffUntil: Date = .distantPast
    private var inFlight = false

    init(
        geocoder: ReverseGeocoding = MapKitReverseGeocoder(),
        config: Config = Config(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.geocoder = geocoder
        self.config = config
        self.now = now
    }

    /// Cache key: `segmentID + side + round(positionFraction, 0.1)`.
    nonisolated func cacheKey(for request: ParkingAddressRequest) -> String {
        let bucket = Int((request.positionFraction / config.fractionBucket).rounded())
        return "\(request.segmentID)|\(request.side)|\(bucket)"
    }

    func resolve(_ request: ParkingAddressRequest) async -> ParkingAddressResolution {
        let key = cacheKey(for: request)
        if let hit = cachedResolution(forKey: key) { return hit }

        // One geocode in flight: a later caller waits its turn (callers cancel superseded work).
        while inFlight {
            if Task.isCancelled { return .unavailable }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if Task.isCancelled { return .unavailable }
        if let hit = cachedResolution(forKey: key) { return hit }
        guard now() >= backoffUntil else { return .unavailable }

        inFlight = true
        defer { inFlight = false }

        let priorParity = verifiedParity(segmentID: request.segmentID, side: request.side)

        switch await attempt(request, fraction: request.positionFraction, priorParity: priorParity, viaRetry: false) {
        case .throttled:
            return .unavailable
        case .failed:
            backoffUntil = now().addingTimeInterval(config.backoffSeconds)
            return .unavailable
        case .noResult:
            backoffUntil = now().addingTimeInterval(config.backoffSeconds)
            return .blockOnly
        case .verdict(let verdict):
            switch verdict {
            case .address(let number, let street, let confidence):
                return finish(request, key: key, number: number, street: street, confidence: confidence)
            case .noNumber:
                return store(.blockOnly, request: request, key: key)
            case .streetMismatch:
                break
            }
        }

        // Corner building facing the avenue: one retry a little further along the block.
        let delta = request.positionFraction < 0.5 ? config.retryFractionOffset : -config.retryFractionOffset
        let retryFraction = min(config.fractionClamp.upperBound,
                                max(config.fractionClamp.lowerBound, request.positionFraction + delta))
        switch await attempt(request, fraction: retryFraction, priorParity: priorParity, viaRetry: true) {
        case .throttled:
            return .unavailable
        case .failed:
            backoffUntil = now().addingTimeInterval(config.backoffSeconds)
            return .unavailable
        case .noResult:
            backoffUntil = now().addingTimeInterval(config.backoffSeconds)
            return .blockOnly
        case .verdict(let verdict):
            if case .address(let number, let street, let confidence) = verdict {
                return finish(request, key: key, number: number, street: street, confidence: confidence)
            }
            return store(.blockOnly, request: request, key: key)
        }
    }

    // MARK: Private

    private func finish(
        _ request: ParkingAddressRequest,
        key: String,
        number: String,
        street: String,
        confidence: ParkingAddress.Confidence
    ) -> ParkingAddressResolution {
        if Task.isCancelled { return .unavailable }
        let address = ParkingAddress(
            houseNumber: number,
            streetDisplay: street,
            confidence: confidence,
            source: .mapkit,
            resolvedAt: now()
        )
        return store(.resolved(address), request: request, key: key)
    }

    private func store(
        _ resolution: ParkingAddressResolution,
        request: ParkingAddressRequest,
        key: String
    ) -> ParkingAddressResolution {
        if Task.isCancelled { return .unavailable }
        cache[key] = CacheEntry(segmentID: request.segmentID, side: request.side, resolution: resolution)
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > config.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache[evicted] = nil
        }
        return resolution
    }

    private func cachedResolution(forKey key: String) -> ParkingAddressResolution? {
        guard let entry = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return entry.resolution
    }

    /// Parity of any VERIFIED address already cached for this blockface side.
    private func verifiedParity(segmentID: String, side: String) -> Int? {
        for entry in cache.values where entry.segmentID == segmentID && entry.side == side {
            if case .resolved(let address) = entry.resolution, address.confidence == .verified,
               let parity = ParkingAddressValidator.parity(of: address.houseNumber) {
                return parity
            }
        }
        return nil
    }

    private func attempt(
        _ request: ParkingAddressRequest,
        fraction: Double,
        priorParity: Int?,
        viaRetry: Bool
    ) async -> AttemptOutcome {
        guard let probe = ParkingAddressGeometry.probePoint(
            line: request.line, fraction: fraction, side: request.side
        ) else {
            return .verdict(.noNumber)
        }

        let current = now()
        requestTimes.removeAll { current.timeIntervalSince($0) >= 60 }
        guard requestTimes.count < config.maxRequestsPerMinute else { return .throttled }
        requestTimes.append(current)

        let placemarks: [GeocodedPlacemark]
        do {
            placemarks = try await geocodeWithTimeout(probe)
        } catch {
            return .failed
        }
        guard !placemarks.isEmpty else { return .noResult }

        var sawMismatch = false
        for placemark in placemarks {
            let verdict = ParkingAddressValidator.evaluate(
                placemark: placemark,
                segmentStreet: request.street,
                probe: probe,
                priorParity: priorParity,
                viaRetry: viaRetry
            )
            switch verdict {
            case .address:
                return .verdict(verdict)
            case .streetMismatch:
                sawMismatch = true
            case .noNumber:
                continue
            }
        }
        return .verdict(sawMismatch ? .streetMismatch : .noNumber)
    }

    private func geocodeWithTimeout(_ coordinate: CLLocationCoordinate2D) async throws -> [GeocodedPlacemark] {
        let geocoder = self.geocoder
        let timeout = config.timeoutSeconds
        return try await withThrowingTaskGroup(of: [GeocodedPlacemark].self) { group in
            group.addTask { try await geocoder.reverseGeocode(coordinate) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }
}
