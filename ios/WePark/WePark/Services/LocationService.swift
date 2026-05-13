//
//  LocationService.swift
//  WePark
//
//  W5.1: Lightweight CoreLocation wrapper for the recenter-on-user feature.
//
//  Responsibilities:
//    - Request .whenInUse permission on first use (recenter button tap).
//    - Expose the most-recent user location via @Observable.
//    - Enable/disable updates on demand (single-shot fetch is fine for recenter).
//
//  This is intentionally minimal — Drive Mode (W8/W9) will own a more
//  comprehensive location tracking stack. This service is recenter-only.
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import CoreLocation
import Observation

@Observable
final class LocationService: NSObject {

    // MARK: - Published state

    /// Most-recently received user location. Nil until first fix acquired.
    private(set) var userLocation: CLLocationCoordinate2D?

    /// Incremented each time a new location fix is received.
    /// Observers can use .onChange(of: locationService.locationUpdateCount) to react
    /// to new fixes without needing CLLocationCoordinate2D to be Equatable.
    private(set) var locationUpdateCount: Int = 0

    /// True when the user has granted .whenInUse (or .always) permission.
    private(set) var isAuthorized: Bool = false

    // MARK: - Private

    private let manager: CLLocationManager

    // MARK: - Init

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Reflect initial authorization status.
        isAuthorized = [.authorizedWhenInUse, .authorizedAlways]
            .contains(manager.authorizationStatus)
    }

    // MARK: - API

    /// Request permission if not yet granted, then request a single location fix.
    /// Safe to call multiple times — subsequent calls are no-ops if authorized.
    func requestAndFetchLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            // Permission denied — nothing we can do without user visiting Settings.
            break
        @unknown default:
            break
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        isAuthorized = [.authorizedWhenInUse, .authorizedAlways].contains(status)
        // If the user just granted permission, fetch a location now.
        if isAuthorized {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        userLocation = loc.coordinate
        locationUpdateCount += 1
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Swallow — the recenter button is best-effort. If location fails,
        // the button tap is a no-op (userLocation stays nil).
        // kCLErrorLocationUnknown is transient; kCLErrorDenied is handled above.
        _ = error
    }
}
