//
//  ClipCoreLocation.swift
//  WePark Clip
//
//  One-shot When-In-Use location for "Show me this block" (spec 5.1: clips get WhenInUse only,
//  reset at 4 a.m.). Never `requestAlwaysAuthorization`, no continuous updates, nothing stored.
//

import CoreLocation

@MainActor
final class ClipCoreLocationProvider: NSObject, ClipLocationProviding {

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<ClipCoordinate, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCoordinate() async throws -> ClipCoordinate {
        guard continuation == nil else { throw ClipLocationError.unavailable }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw ClipLocationError.denied
        default:
            break
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()   // answered in locationManagerDidChangeAuthorization
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<ClipCoordinate, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension ClipCoreLocationProvider: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(ClipLocationError.denied))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(.success(ClipCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        finish(.failure(denied ? ClipLocationError.denied : ClipLocationError.unavailable))
    }
}
