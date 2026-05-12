//
//  ParkPinService.swift
//  WePark
//
//  W5: UserDefaults-backed single-pin persistence for the parked car.
//
//  No import SwiftUI — this is a pure service (QA invariant).
//  No Calendar.current anywhere.
//
//  Thread safety: save() and clearPin() MUST be called from the main thread.
//  UserDefaults writes from background threads can produce intermittent data loss on iOS.
//  The @Observable macro propagates parkedCar to the main-thread SwiftUI view hierarchy.
//
//  W6 hook: firstPinDropped fires exactly once per app install (when hasEverParkedKey is absent).
//  W7.5 hook: pinDropped fires on every save(), including replacements.
//
//  hasEverParkedKey is NEVER cleared by clearPin() — it persists for the lifetime of the install.
//

import Foundation
import Combine
import Observation

@Observable
final class ParkPinService {

    // MARK: - Published state

    private(set) var parkedCar: ParkedCar?

    // MARK: - W6 hook — first-pin notification rationale trigger
    //
    // W6 subscribes via .onReceive(parkPinService.firstPinDropped) { ... }.
    // Emits exactly once: when no prior pin has ever been saved (hasEverParkedKey absent).
    let firstPinDropped = PassthroughSubject<Void, Never>()

    // MARK: - W7.5 hook — "Parking until when?" prompt trigger
    //
    // W7.5 subscribes via .onReceive(parkPinService.pinDropped) { car in ... }.
    // Emits on every save(), including pin replacements.
    let pinDropped = PassthroughSubject<ParkedCar, Never>()

    // MARK: - Private storage

    private let defaults = UserDefaults.standard
    private let storageKey    = "wepark_parked_car"
    private let hasEverParkedKey = "wepark_has_ever_parked"

    // MARK: - Lifecycle

    /// Read persisted car pin on app launch. Must be called from the main thread.
    func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            parkedCar = try JSONDecoder().decode(ParkedCar.self, from: data)
        } catch {
            // Corrupted data — clear silently so the app doesn't crash on launch.
            defaults.removeObject(forKey: storageKey)
        }
    }

    /// Persist a new car pin. Silently replaces any existing pin.
    /// Must be called from the main thread.
    func save(_ car: ParkedCar) {
        // W6 hook: fire firstPinDropped before writing, exactly once per install.
        if !defaults.bool(forKey: hasEverParkedKey) {
            firstPinDropped.send()
            defaults.set(true, forKey: hasEverParkedKey)
        }

        do {
            let data = try JSONEncoder().encode(car)
            defaults.set(data, forKey: storageKey)
            parkedCar = car
        } catch {
            // Encoding failure is not expected for a simple Codable struct;
            // log and swallow — the UI should not crash on a save error.
            assertionFailure("ParkPinService.save: encoding failed: \(error)")
        }

        // W7.5 hook: fire after write so the parkedCar state is consistent.
        pinDropped.send(car)
    }

    /// Remove the car pin. Does NOT clear hasEverParkedKey (W6 invariant).
    /// Must be called from the main thread.
    func clearPin() {
        defaults.removeObject(forKey: storageKey)
        // Explicitly NOT clearing hasEverParkedKey — W6 must fire only once ever.
        parkedCar = nil
    }
}
