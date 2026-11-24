//
//  AutoDetectLive.swift
//  Services/SpotPass/Driver/AutoDetect
//
//  Spot Pass C4: the CoreLocation-backed pieces of auto-detect. Thin on purpose: every decision is
//  in `AutoDetectLogic` / `AutoDetectController` and unit-tested; this file only adapts the system.
//
//    - `AutoDetectCLProvider`: `CLLocationUpdate.liveUpdates()` (iOS 17) consumed on the main actor.
//      The system suspends delivery while the phone is stationary, which is the battery story (spec
//      7.4: "standard accuracy while stationary near the anchor"). When In Use only.
//    - `AutoDetectBackgroundActivity`: owns a `CLBackgroundActivitySession` for the window (the blue pill).
//    - `AutoDetectAuthorizer`: the one place that asks for When In Use. NEVER `requestAlwaysAuthorization`.
//    - `ParkedCarAnchorReader`: the saved car's coordinate, read on demand, held in memory by the caller.
//
//  No coordinate is logged, stored or sent from here.
//

import CoreLocation
import Foundation
import UIKit

// MARK: - Background session

@MainActor
final class AutoDetectBackgroundActivity: AutoDetectBackgroundSession {
    private var session: CLBackgroundActivitySession?

    /// Created from the foreground and retained until `invalidate` (spec 7.4).
    init() {
        session = CLBackgroundActivitySession()
    }

    func invalidate() {
        session?.invalidate()
        session = nil
    }
}

// MARK: - Authorization

@MainActor
final class AutoDetectAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<AutoDetectAuthorization, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var current: AutoDetectAuthorization { Self.map(manager.authorizationStatus) }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> AutoDetectAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        default: return .denied
        }
    }

    /// When In Use only. If already decided, answers immediately without a prompt.
    func requestWhenInUse() async -> AutoDetectAuthorization {
        guard manager.authorizationStatus == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.map(manager.authorizationStatus)
        Task { @MainActor [weak self] in
            guard status != .notDetermined, let continuation = self?.continuation else { return }
            self?.continuation = nil
            continuation.resume(returning: status)
        }
    }
}

// MARK: - Provider

@MainActor
final class AutoDetectCLProvider: AutoDetectLocationProviding {
    private let authorizer = AutoDetectAuthorizer()
    private var task: Task<Void, Never>?

    var authorization: AutoDetectAuthorization { authorizer.current }

    func requestWhenInUse() async -> AutoDetectAuthorization {
        await authorizer.requestWhenInUse()
    }

    func start(onFix: @escaping @MainActor (AutoDetectFix) -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard !Task.isCancelled else { return }
                    guard let location = update.location else { continue }
                    onFix(AutoDetectFix(
                        latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                        horizontalAccuracy: location.horizontalAccuracy, speed: location.speed,
                        timestamp: location.timestamp
                    ))
                }
            } catch {
                // The sequence ended (authorization revoked, system stopped it): the manual paths remain.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Anchor

/// Reads the saved car's coordinate for the armed window. Same shape as `ParkedCarSegmentReader`
/// (no live `ParkPinService`, which `SpotPassDriverRuntime` cannot reach). The caller keeps it in
/// memory for one window and drops it.
enum ParkedCarAnchorReader {
    /// The app's in-memory parked car (`ParkPinService.parkedCar`), mirrored here by `ContentView` so the
    /// feature works when iCloud key-value storage is unavailable. Coordinates only, never persisted here.
    private(set) static var liveAnchor: AutoDetectAnchor?

    /// Called whenever the in-memory parked car changes (nil when cleared or not loaded).
    static func setLiveCar(latitude: Double?, longitude: Double?) {
        if let latitude, let longitude {
            liveAnchor = AutoDetectAnchor(latitude: latitude, longitude: longitude)
        } else {
            liveAnchor = nil
        }
    }

    /// In-memory car first, the synced key-value store only as a fallback (pure, for tests).
    nonisolated static func resolve(
        live: AutoDetectAnchor?, store: UbiquitousKeyValueStoring
    ) -> AutoDetectAnchor? {
        live ?? currentAnchor(store: store)
    }

    /// Must match `ParkPinService.syncedStateKey`.
    private nonisolated static let syncedStateKey = "wepark_synced_car_state"

    nonisolated static func currentAnchor(
        store: UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default
    ) -> AutoDetectAnchor? {
        guard let data = store.data(forKey: syncedStateKey),
              let envelope = try? JSONDecoder().decode(SyncedCarEnvelope.self, from: data)
        else { return nil }
        switch envelope.kind {
        case .parked:
            guard let car = envelope.car else { return nil }
            return AutoDetectAnchor(latitude: car.latitude, longitude: car.longitude)
        case .cleared:
            return nil
        }
    }
}

// MARK: - Composition

extension AutoDetectController {
    /// The live controller, or nil while `spotHandoffAutoDetectEnabled` is false (so the dark build
    /// constructs no location object at all).
    static func makeLive(enabled: Bool? = nil) -> AutoDetectController? {
        let enabled = enabled ?? AppConstants.spotHandoffAutoDetectEnabled
        guard enabled else { return nil }
        let controller = AutoDetectController(
            flagEnabled: enabled,
            optIn: UserDefaultsAutoDetectOptIn(),
            anchorProvider: {
                ParkedCarAnchorReader.resolve(live: ParkedCarAnchorReader.liveAnchor, store: NSUbiquitousKeyValueStore.default)
            },
            location: AutoDetectCLProvider(),
            makeSession: { AutoDetectBackgroundActivity() },
            isForeground: { UIApplication.shared.applicationState == .active }
        )
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.appWillTerminate() }
        }
        return controller
    }
}
