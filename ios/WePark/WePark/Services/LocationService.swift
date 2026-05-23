//
//  LocationService.swift
//  WePark
//
//  W5.1: Lightweight CoreLocation wrapper for the recenter-on-user feature.
//  W8.5c: Added Drive Mode continuous location + heading API.
//
//  Responsibilities:
//    - Request .whenInUse permission on first use (recenter button tap).
//    - Expose the most-recent user location via @Observable.
//    - Enable/disable updates on demand (single-shot fetch is fine for recenter).
//    - W8.5c: startDriveMode() / endDriveMode() flip into continuous navigation mode.
//    - W8.5c: EMA heading stabilizer (port of stabilizedHeading, index.html:6546–6570).
//
//  EMA stabilizer constants (calibration deferred to W8.5c-follow post-drive-test):
//    DRIVING_HEADING_MIN_SPEED_MPS = 1.8 (same as PWA, index.html constant)
//    DRIVING_HEADING_EMA_ALPHA = 0.35 (same as PWA, index.html constant)
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import CoreLocation
import Observation
import UIKit

// MARK: - Constants

private let DRIVING_HEADING_MIN_SPEED_MPS: Double = 1.8
private let DRIVING_HEADING_EMA_ALPHA: Double = 0.35

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

    // MARK: - W8.5c: Drive Mode state

    /// EMA-stabilized heading for Drive Mode. Nil when Drive Mode is not active.
    /// Port of drivingLastGoodHeading / drivingHeadingEMA (index.html:6546–6570).
    private(set) var driveHeading: CLLocationDirection?

    /// Most-recent speed reading from Drive Mode location updates, in m/s.
    private(set) var driveSpeed: CLLocationSpeed?

    /// True while Drive Mode is actively running.
    private var driveModeActiveInternal: Bool = false

    // MARK: - Private EMA state

    /// EMA accumulator. Nil until first good heading above speed threshold.
    /// Port of drivingHeadingEMA (index.html:6560).
    private var headingEMA: Double?

    /// Previous drive coordinate, used for course-from-movement fallback.
    /// Port of drivingPrevPos (index.html:6549).
    private var prevDriveCoordinate: CLLocationCoordinate2D?

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

    // MARK: - Single-shot API (unchanged from W5.1)

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

    // MARK: - W8.5c: Drive Mode API

    /// Activates Drive Mode continuous location + heading updates.
    ///
    /// Follows spec §4 Step 4 + R-4 risk mitigation: stop before reconfiguring,
    /// then restart to avoid state confusion in CLLocationManager.
    ///
    /// Port of drive session setup from master spec §5 / PWA's driving geolocation setup.
    func startDriveMode() {
        guard !driveModeActiveInternal else { return }
        driveModeActiveInternal = true

        // R-4 mitigation: stop first, reconfigure, then restart.
        manager.stopUpdatingLocation()

        // Configure for automotive navigation (AC-W85c.6).
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone

        // Start continuous updates.
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()

        // Wake lock: prevent screen timeout while navigating (AC-W85c.9).
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    /// Deactivates Drive Mode, restores single-shot location posture.
    ///
    /// Port of drive session teardown from master spec §5 / PWA's exitDrivingMode (index.html:5593).
    func endDriveMode() {
        guard driveModeActiveInternal else { return }
        driveModeActiveInternal = false

        // Stop continuous updates.
        manager.stopUpdatingHeading()
        manager.stopUpdatingLocation()

        // Restore single-shot accuracy posture.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.distanceFilter = kCLDistanceFilterNone

        // Clear drive-specific state.
        driveHeading = nil
        driveSpeed = nil
        headingEMA = nil
        prevDriveCoordinate = nil

        // Restore single-shot posture with a fresh fix request.
        if isAuthorized {
            manager.requestLocation()
        }

        // Release wake lock (AC-W85c.9).
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - W8.5c: EMA heading stabilizer

    /// Swift port of `stabilizedHeading` from `index.html:6546–6570`.
    ///
    /// Algorithm:
    ///   1. Speed gate: if speed < 1.8 m/s, return last good heading (freeze on stop).
    ///   2. Course-from-movement fallback: if raw heading is nil but we have a previous
    ///      coordinate, compute bearing between prev and current.
    ///   3. EMA with circular wraparound: new_ema = ema + alpha * normalize(raw - ema).
    ///   4. Store result in headingEMA; return it as the stabilized heading.
    ///
    /// - Parameters:
    ///   - rawHeading: The device's magnetic heading, or nil if unavailable.
    ///   - speed: Current speed in m/s (from CLLocation.speed).
    ///   - current: Current coordinate (for course-from-movement fallback).
    /// - Returns: Stabilized heading in [0, 360), or nil if no trustworthy heading available.
    func stabilizedHeading(
        rawHeading: CLLocationDirection?,
        speed: CLLocationSpeed,
        current: CLLocationCoordinate2D
    ) -> CLLocationDirection? {
        var h: Double? = rawHeading.flatMap { $0 >= 0 ? $0 : nil }

        // Course-from-movement fallback when GPS heading unavailable.
        // Requires at least 4m of movement (same threshold as PWA: `if (moved >= 4)`).
        if h == nil, let prev = prevDriveCoordinate {
            let moved = haversineMeters(from: current, to: prev)
            if moved >= 4 {
                h = bearingFromTo(lat1: prev.latitude, lng1: prev.longitude,
                                  lat2: current.latitude, lng2: current.longitude)
            }
        }

        // Save current position for next tick's bearing computation.
        prevDriveCoordinate = current

        // Speed gate: under threshold, keep last good heading (OQ-6: freeze, not snap to north).
        let movingFastEnough = speed >= DRIVING_HEADING_MIN_SPEED_MPS
        guard movingFastEnough else {
            return driveHeading  // freeze on last good value (may be nil on first tick)
        }
        guard let heading = h else {
            return driveHeading  // no heading available at speed → keep last
        }

        // EMA smoothing with circular wraparound (index.html:6560–6567).
        if headingEMA == nil {
            headingEMA = heading
        } else {
            var diff = heading - headingEMA!
            while diff > 180 { diff -= 360 }
            while diff < -180 { diff += 360 }
            headingEMA = ((headingEMA! + DRIVING_HEADING_EMA_ALPHA * diff) + 360).truncatingRemainder(dividingBy: 360)
        }
        // Store as the last good heading so the speed-gate freeze path can return it.
        // Port of `drivingLastGoodHeading = drivingHeadingEMA` (index.html:6568).
        driveHeading = headingEMA
        return headingEMA
    }

    // MARK: - Private geometry helpers

    /// Haversine distance in meters between two coordinates.
    private func haversineMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

    /// Compass bearing from (lat1, lng1) to (lat2, lng2), in [0, 360).
    /// Port of `bearingFromTo` from `index.html:6572–6578`.
    private func bearingFromTo(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaLambda = (lng2 - lng1) * .pi / 180
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let authorized = [.authorizedWhenInUse, .authorizedAlways].contains(status)
        // Defer the @Observable property write to the next run loop cycle.
        // CLLocationManager delegates can fire during a SwiftUI render pass, and writing
        // @Observable state synchronously from a delegate method triggers
        // "Modifying state during view update" warnings.
        DispatchQueue.main.async { [weak self] in
            self?.isAuthorized = authorized
            if authorized && !(self?.driveModeActiveInternal ?? false) {
                // Only request single-shot location if NOT in continuous drive mode.
                manager.requestLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coordinate = loc.coordinate
        let speed = loc.speed  // m/s, negative when unavailable

        if driveModeActiveInternal {
            // Drive Mode: compute stabilized heading using speed and course-from-movement.
            // Use CLLocation.course as the raw heading fallback when the magnetometer isn't available.
            let courseHeading: CLLocationDirection? = loc.course >= 0 ? loc.course : nil
            let stabilized = stabilizedHeading(
                rawHeading: courseHeading,
                speed: max(0, speed),
                current: coordinate
            )
            DispatchQueue.main.async { [weak self] in
                self?.userLocation = coordinate
                self?.locationUpdateCount += 1
                self?.driveSpeed = speed >= 0 ? speed : 0
                self?.driveHeading = stabilized
            }
        } else {
            // Single-shot / recenter mode (unchanged W5.1 behavior).
            DispatchQueue.main.async { [weak self] in
                self?.userLocation = coordinate
                self?.locationUpdateCount += 1
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard driveModeActiveInternal else { return }
        // We use the magnetometer heading to update the EMA.
        // trueHeading >= 0 means the device has calibrated its heading relative to true north.
        // If trueHeading < 0, fall back to magneticHeading (raw compass, less accurate in cities).
        let rawHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard rawHeading >= 0 else { return }

        // Apply speed-gated EMA stabilization.
        let speed = max(0, driveSpeed ?? 0)
        guard let coord = userLocation else { return }
        let stabilized = stabilizedHeading(
            rawHeading: rawHeading,
            speed: speed,
            current: coord
        )
        DispatchQueue.main.async { [weak self] in
            self?.driveHeading = stabilized
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Swallow — the recenter button is best-effort. If location fails,
        // the button tap is a no-op (userLocation stays nil).
        // kCLErrorLocationUnknown is transient; kCLErrorDenied is handled above.
        _ = error
    }
}
