//
//  CarPinSyncPolicy.swift
//  WePark
//
//  Pure decision logic for `MapViewRepresentable.Coordinator.syncCarPin`, extracted so the
//  "when must the parked-car annotation be (re)built" rule is unit-testable without an
//  `MKMapView` (build 27 smoke finding 13: the car icon disappeared after the car was
//  re-placed). No UIKit/MapKit imports, no state.
//

import Foundation

/// Identity of a rendered car pin: the car's id AND its stored position. Keying on the id
/// alone meant a same-id edit (or any external removal of the annotation) was never noticed.
struct CarPinKey: Equatable {
    let id: UUID
    let latitude: Double
    let longitude: Double
}

enum CarPinSyncPolicy {

    enum Action: Equatable {
        /// Nothing to do: what is on the map already matches the car.
        case none
        /// Remove whatever annotation exists and add a fresh one for the desired car
        /// (or just remove it when there is no desired car).
        case rebuild
    }

    /// - Parameters:
    ///   - rendered: key of the annotation this coordinator last added (nil = none).
    ///   - desired: key of the car that should be shown (nil = no parked car).
    ///   - annotationOnMap: whether the annotation this coordinator last added is still in
    ///     `mapView.annotations`. Self-heals the icon if anything removed it behind our back.
    nonisolated static func action(
        rendered: CarPinKey?,
        desired: CarPinKey?,
        annotationOnMap: Bool
    ) -> Action {
        if rendered != desired { return .rebuild }
        if desired != nil, !annotationOnMap { return .rebuild }
        return .none
    }
}
