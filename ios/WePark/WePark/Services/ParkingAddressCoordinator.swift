//
//  ParkingAddressCoordinator.swift
//  WePark
//
//  Address-anchored parking (docs/specs/address-anchored-parking.md sections 3.3-3.4): decides
//  WHEN the resolver runs and holds the result the placement card shows. All geocoding policy
//  (validation, throttle, cache) lives in `ParkingAddressResolver`; this type is only triggers.
//
//  Triggers:
//    (a) placement settle: `placementSnapChanged` - debounced (default 600 ms) after the snap
//        stops changing, never per frame; a changed blockface / side / fraction bucket
//        invalidates the shown address immediately (a stale address is never displayed on a new
//        block). Same key as the one already shown / in flight is a no-op, so one settle is
//        exactly one resolver call.
//    (b) `ensureAddress(for:)`: a saved car with no address (auto-detected park, car synced from
//        an older build, or the placement card had nothing yet).
//    (c) the same entry point on the next foreground retries once after an offline failure.
//
//  No camera / map mutation anywhere here (the address labels the point; it never moves it).
//  Never logs an address or coordinate.
//

import Foundation
import CoreLocation
import Observation
import UIKit

@MainActor
@Observable
final class ParkingAddressCoordinator {

    /// The address for the CURRENT placement snap, or nil. Cleared the moment the snap moves to
    /// another key. Observed by the card.
    private(set) var placementAddress: ParkingAddress?

    /// Max resolver attempts per saved car: the initial one plus one foreground retry.
    static let maxAttemptsPerCar = 2

    @ObservationIgnored private let resolver: ParkingAddressResolver
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private var placementKey: String?
    @ObservationIgnored private var placementTask: Task<Void, Never>?
    @ObservationIgnored private var carTask: Task<Void, Never>?
    @ObservationIgnored private var attemptsByCarID: [UUID: Int] = [:]

    init(
        resolver: ParkingAddressResolver = ParkingAddressResolver(),
        debounce: Duration = .milliseconds(600),
        isEnabled: Bool? = nil
    ) {
        self.resolver = resolver
        self.debounce = debounce
        self.isEnabled = isEnabled ?? AppConstants.addressAnchoredParkingEnabled
    }

    // MARK: (a) Placement

    /// Call when the placement outcome changes (blockface / outcome kind, or a settle) - never
    /// per frame. `request` is nil for "no curb in range" / no outcome.
    func placementSnapChanged(_ request: ParkingAddressRequest?) {
        guard isEnabled else { return }
        guard let request else {
            clearPlacement()
            return
        }
        let key = resolver.cacheKey(for: request)
        if key == placementKey { return }
        placementTask?.cancel()
        placementKey = key
        placementAddress = nil
        let debounce = self.debounce
        placementTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            let resolution = await self.resolver.resolve(request)
            guard !Task.isCancelled, self.placementKey == key else { return }
            if case .resolved(let address) = resolution {
                self.placementAddress = address
                Self.announce(address)
            }
        }
    }

    /// One polite (queued, non-interrupting) VoiceOver announcement per resolution; nothing when
    /// VoiceOver is off, and never on offline / no-result.
    private static func announce(_ address: ParkingAddress) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let text = NSAttributedString(
            string: ParkingAddressCopy.spoken(address),
            attributes: [.accessibilitySpeechQueueAnnouncement: true]
        )
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Placement ended (commit or cancel): drop everything, cancel any pending work.
    func clearPlacement() {
        placementTask?.cancel()
        placementTask = nil
        placementKey = nil
        placementAddress = nil
    }

    // MARK: (b)/(c) Saved car

    /// Fills in `car.address` if it has none. `apply` receives the resolved address and the car
    /// id (the caller writes it through `ParkPinService.updateAddress`, which ignores a stale id).
    /// Bounded: at most `maxAttemptsPerCar` attempts per car, and a block-only answer ends it.
    /// Never blocks saving; silent on failure.
    func ensureAddress(
        for car: ParkedCar,
        segment: Segment?,
        apply: @escaping @MainActor (ParkingAddress, UUID) -> Void
    ) {
        guard isEnabled, car.address == nil, carTask == nil,
              let segment, segment.id == car.detectedSegmentID,
              (attemptsByCarID[car.id] ?? 0) < Self.maxAttemptsPerCar else { return }
        let coordinate = CLLocationCoordinate2D(latitude: car.latitude, longitude: car.longitude)
        guard let fraction = CandidateSegmentSearch.nearestPointOnPolyline(
            from: coordinate, polyline: segment.coordinates
        )?.fraction else { return }

        attemptsByCarID[car.id, default: 0] += 1
        let request = ParkingAddressRequest(
            segmentID: segment.id,
            side: segment.side,
            street: segment.street,
            line: segment.line,
            positionFraction: fraction
        )
        let carID = car.id
        carTask = Task { [weak self] in
            guard let self else { return }
            let resolution = await self.resolver.resolve(request)
            self.carTask = nil
            switch resolution {
            case .resolved(let address):
                self.attemptsByCarID[carID] = Self.maxAttemptsPerCar
                apply(address, carID)
            case .blockOnly:
                self.attemptsByCarID[carID] = Self.maxAttemptsPerCar
            case .unavailable:
                break
            }
        }
    }
}

nonisolated extension ParkingAddressRequest {
    /// The request for a live placement snap.
    init(snap: CurbSnapResult) {
        self.init(
            segmentID: snap.segment.id,
            side: snap.segment.side,
            street: snap.segment.street,
            line: snap.segment.line,
            positionFraction: snap.positionFraction
        )
    }
}
