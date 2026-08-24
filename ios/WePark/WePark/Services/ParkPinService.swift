//
//  ParkPinService.swift
//  WePark
//
//  W5: Single-pin persistence for the parked car.
//
//  Build 19: Rewritten to back the active parked-car state with
//  NSUbiquitousKeyValueStore (iCloud key-value storage) instead of UserDefaults, so the
//  parked car syncs across a user's devices signed into the same Apple ID and survives a
//  delete-and-reinstall. Spec: docs/icloud-parked-car-sync-spec.md.
//
//  No import SwiftUI — this is a pure service (QA invariant).
//  No Calendar.current anywhere.
//
//  Thread safety: save(), clearPin(), updateNotifyOnRestriction(), and applyRemoteChange()
//  MUST be called from the main thread. UserDefaults writes from background threads can
//  produce intermittent data loss on iOS, and NSUbiquitousKeyValueStore carries the same
//  requirement for its own reason: NSUbiquitousKeyValueStore.didChangeExternallyNotification
//  is NOT guaranteed to be delivered on the main thread when the change is genuinely
//  external. The observer registered in `startObservingRemoteChanges()` uses `queue: .main`
//  so `applyRemoteChange` — and therefore every mutation of `parkedCar` — only ever runs on
//  main, consistent with this file's existing invariant rather than adding a new one.
//  The @Observable macro propagates parkedCar to the main-thread SwiftUI view hierarchy.
//
//  W6 hook: firstPinDropped fires exactly once per app install (when hasEverParkedKey is
//  absent) — LOCAL DROPS ONLY. Never fired by applyRemoteChange() or the migration path.
//  W7.5 hook: pinDropped fires on every save(), including replacements — LOCAL DROPS ONLY.
//  Never fired by applyRemoteChange() or the migration path.
//
//  Build 19 hook: remoteCarChanged fires ONLY from applyRemoteChange() — never from
//  save()/clearPin(). This is the fix for the trap the spec exists to prevent: piping a
//  remote-arrived car through save()/pinDropped would incorrectly show the W6 permission-
//  rationale sheet on a device merely reacting to sync, and would incorrectly auto-open the
//  W7.5 "Parking until when?" prompt. See spec §3.5.
//
//  hasEverParkedKey is NEVER cleared by clearPin(), and is NEVER read or written by
//  applyRemoteChange() or the migration path in load() — only by save(). It is deliberately
//  device-local, not synced: iOS notification permission is granted per device, not per
//  Apple ID, so a brand-new device that receives a synced car still needs its own first
//  LOCAL pin drop to trigger the rationale sheet and request permission on that device (see
//  spec §3.4 for the full argument, including the counter-case considered and rejected).
//

import Foundation
import Combine
import Observation

@Observable
final class ParkPinService {

    // MARK: - Published state

    private(set) var parkedCar: ParkedCar?

    /// The `updatedAt` of the envelope currently applied to `parkedCar` (nil until the
    /// first `load()`/`save()`/`applyRemoteChange()`). This is the merge comparator state —
    /// exposed `private(set)` (not `private`) so tests can assert on it directly (spec §3.7).
    private(set) var currentUpdatedAt: Date?

    // MARK: - W6 hook — first-pin notification rationale trigger
    //
    // W6 subscribes via .onReceive(parkPinService.firstPinDropped) { ... }.
    // Emits exactly once: when no prior pin has ever been saved (hasEverParkedKey absent).
    // LOCAL DROPS ONLY — never fired by applyRemoteChange() or load()'s migration path.
    let firstPinDropped = PassthroughSubject<Void, Never>()

    // MARK: - W7.5 hook — "Parking until when?" prompt trigger
    //
    // W7.5 subscribes via .onReceive(parkPinService.pinDropped) { car in ... }.
    // Emits on every save(), including pin replacements.
    // LOCAL DROPS ONLY — never fired by applyRemoteChange() or load()'s migration path.
    let pinDropped = PassthroughSubject<ParkedCar, Never>()

    // MARK: - Build 19 hook — remote-arrival trigger
    //
    // ContentView subscribes via .onReceive(parkPinService.remoteCarChanged) { newCar, oldCarID in ... }.
    // Emits ONLY from applyRemoteChange() when a remote envelope with a strictly-greater
    // updatedAt is adopted. Never fires firstPinDropped or pinDropped as a side effect —
    // see spec §3.5 for the full trace of why those two publishers must stay untouched here.
    let remoteCarChanged = PassthroughSubject<(newCar: ParkedCar?, oldCarID: UUID?), Never>()

    // MARK: - Private storage

    /// The iCloud key-value store. Production default is the real
    /// `NSUbiquitousKeyValueStore.default`; tests inject a `MockUbiquitousStore` conforming
    /// to `UbiquitousKeyValueStoring` (spec §3.7) so merge/tombstone/migration logic is
    /// verifiable without real iCloud or a second device.
    private let cloudStore: UbiquitousKeyValueStoring

    /// `UserDefaults` — used ONLY for the one-time legacy migration read/removal (the
    /// pre-Build-19 storage key) and for the device-local `hasEverParkedKey` flag. Injectable
    /// so tests don't pollute `UserDefaults.standard`.
    private let defaults: UserDefaults

    /// Legacy (pre-Build-19) storage key. Read once by `load()`'s migration path, then the
    /// key is removed — never written to again by this feature.
    private let legacyStorageKey = "wepark_parked_car"

    /// Device-local, NOT synced. See file header and spec §3.4.
    private let hasEverParkedKey = "wepark_has_ever_parked"

    /// The single key under which the `SyncedCarEnvelope` lives in `cloudStore`.
    private let syncedStateKey = "wepark_synced_car_state"

    /// Token for the `didChangeExternallyNotification` observer, removed in `deinit`.
    private var remoteChangeObserver: NSObjectProtocol?

    // MARK: - Init

    /// Production initializer. Both parameters default to the real backing stores; tests use
    /// the second initializer below to inject a mock store, mirroring
    /// `NotificationScheduler(center:)`'s existing test-injection pattern.
    init() {
        self.cloudStore = NSUbiquitousKeyValueStore.default
        self.defaults = .standard
    }

    /// Test-injectable initializer. `defaults` also defaults to `.standard` but can be
    /// overridden so legacy-migration tests don't touch real UserDefaults state.
    internal init(cloudStore: UbiquitousKeyValueStoring, defaults: UserDefaults = .standard) {
        self.cloudStore = cloudStore
        self.defaults = defaults
    }

    deinit {
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
        }
    }

    // MARK: - Lifecycle

    /// Read persisted car pin on app launch, migrating a legacy `UserDefaults` car if one
    /// exists, then start observing remote changes. Must be called from the main thread.
    ///
    /// The migration is NOT a separate code path from the merge logic — it's the SAME
    /// last-write-wins comparison run once against a synthetic envelope built from the
    /// legacy blob. See spec §3.6.
    func load() {
        cloudStore.synchronize()   // best-effort freshness hint only

        let remote = decodeEnvelope(cloudStore.data(forKey: syncedStateKey))

        if let legacyData = defaults.data(forKey: legacyStorageKey),
           let legacyCar = try? JSONDecoder().decode(ParkedCar.self, from: legacyData) {
            let legacy = SyncedCarEnvelope(kind: .parked, updatedAt: legacyCar.parkedAt, car: legacyCar)

            let winner: SyncedCarEnvelope
            if let remote, remote.updatedAt > legacy.updatedAt {
                winner = remote
            } else {
                winner = legacy
            }

            apply(winner)

            if winner.updatedAt == legacy.updatedAt {
                // Legacy won (or tied, which can only happen if the values are identical) —
                // publish it so this Apple ID's other devices see it too.
                writeEnvelope(winner)
            }

            // One-time, either way — migration is a single pass, not a standing dual-read.
            defaults.removeObject(forKey: legacyStorageKey)
        } else {
            apply(remote)   // nil is a valid "no car" state (fresh pair / fresh device, no legacy blob)
        }

        startObservingRemoteChanges()
    }

    /// Applies a decoded envelope (or nil) to `parkedCar`/`currentUpdatedAt` WITHOUT firing
    /// any publisher. Used only by `load()` — at that point in the app lifecycle ContentView
    /// hasn't mounted its `.onReceive` subscriptions yet, and a cold-launch state (including
    /// a car that arrived via sync before this device ever launched — spec §3.3 case 6)
    /// should not retroactively fire firstPinDropped/pinDropped/remoteCarChanged.
    private func apply(_ envelope: SyncedCarEnvelope?) {
        guard let envelope else {
            parkedCar = nil
            currentUpdatedAt = nil
            return
        }
        switch envelope.kind {
        case .parked:
            parkedCar = envelope.car
        case .cleared:
            parkedCar = nil
        }
        currentUpdatedAt = envelope.updatedAt
    }

    /// Persist a new car pin. Silently replaces any existing pin.
    /// Must be called from the main thread.
    func save(_ car: ParkedCar) {
        // W6 hook: fire firstPinDropped before writing, exactly once per install.
        if !defaults.bool(forKey: hasEverParkedKey) {
            firstPinDropped.send()
            defaults.set(true, forKey: hasEverParkedKey)
        }

        // A fresh park's updatedAt EQUALS car.parkedAt (spec §0.1) — "the most recent park
        // wins" holds exactly in the normal case.
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: car.parkedAt, car: car)
        guard writeEnvelope(envelope) else { return }

        currentUpdatedAt = envelope.updatedAt
        parkedCar = car
        // W7.5 hook: fire only after a successful write (spec §6.2 contract, unchanged).
        pinDropped.send(car)
    }

    /// Remove the car pin by writing a `.cleared` TOMBSTONE — never by deleting/omitting the
    /// key. Absence of the key and presence of a tombstone are the only two representations
    /// of "no car"; only the tombstone is ever produced by a deliberate user action. See
    /// spec §3.2 for why this matters (a naive "just delete the key" implementation would
    /// let a cleared car resurrect from another device that hadn't yet synced the clear).
    ///
    /// Does NOT clear hasEverParkedKey (W6 invariant, unchanged).
    /// Must be called from the main thread.
    func clearPin() {
        let envelope = SyncedCarEnvelope(kind: .cleared, updatedAt: .nowET, car: nil)
        guard writeEnvelope(envelope) else { return }

        currentUpdatedAt = envelope.updatedAt
        // Explicitly NOT clearing hasEverParkedKey — W6 must fire only once ever.
        parkedCar = nil
    }

    // MARK: - W7: Per-pin notification opt-in

    /// Updates the `notifyOnRestriction` field on the current parked car.
    /// Constructs a new ParkedCar value (struct copy) with the updated field and re-persists.
    /// No-op if no car is currently parked.
    ///
    /// Bumps `updatedAt` to now even though `car.parkedAt` is unchanged — this is NOT a
    /// re-park, so it needs its own timestamp to participate in last-write-wins and
    /// propagate cross-device (spec §0.1).
    ///
    /// Must be called from the main thread.
    func updateNotifyOnRestriction(_ enabled: Bool) {
        guard let car = parkedCar else { return }
        let updated = ParkedCar(
            id: car.id,
            latitude: car.latitude,
            longitude: car.longitude,
            detectedSegmentID: car.detectedSegmentID,
            detectedSide: car.detectedSide,
            street: car.street,
            fromStreet: car.fromStreet,
            toStreet: car.toStreet,
            parkedAt: car.parkedAt,
            notifyOnRestriction: enabled
        )
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: .nowET, car: updated)
        guard writeEnvelope(envelope) else { return }

        currentUpdatedAt = envelope.updatedAt
        parkedCar = updated
    }

    // MARK: - Build 19: Remote change handling

    /// Entry point for `NSUbiquitousKeyValueStoreDidChangeExternallyNotification`. `internal`
    /// (not `private`) so it's directly callable from tests (spec §3.7) — tests can't trigger
    /// a real `didChangeExternallyNotification` any more than `NotificationScheduler`'s tests
    /// can grant real notification permission, so this mirrors `scheduleForTest`'s role as a
    /// direct test entry point.
    ///
    /// - Parameter reason: `userInfo[NSUbiquitousKeyValueStoreChangeReasonKey]` as an `Int`.
    ///   `ServerChange`/`InitialSyncChange`/`AccountChange` (and unrecognized/nil reasons,
    ///   defensively) all run the same merge check — `AccountChange` is deliberately NOT
    ///   special-cased (spec §0.2/§6 OQ-2). `QuotaViolationChange` is handled separately:
    ///   logged and returned, no partial write, no crash (AC-17) — irrelevant at this
    ///   payload's actual size (see AC-18), but handled defensively regardless.
    internal func applyRemoteChange(reason: Int?) {
        if let reason, reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            print("[ParkPinService] Ubiquitous key-value store quota violation — ignoring remote change")
            return
        }

        // A genuinely absent or corrupt key is a no-op, NEVER an implicit clear (spec §3.2).
        guard let remote = decodeEnvelope(cloudStore.data(forKey: syncedStateKey)) else { return }

        // Last-write-wins, strictly greater only. A remote value with an equal or earlier
        // updatedAt than what's already applied is a no-op — this is the guard that makes
        // a stale delivery (iCloud delivering an old value AFTER a newer local save) safe.
        if let current = currentUpdatedAt, remote.updatedAt <= current {
            return
        }

        let oldCarID = parkedCar?.id

        switch remote.kind {
        case .parked:
            parkedCar = remote.car
        case .cleared:
            parkedCar = nil
        }
        currentUpdatedAt = remote.updatedAt

        remoteCarChanged.send((newCar: parkedCar, oldCarID: oldCarID))
        // Deliberately does NOT touch firstPinDropped, pinDropped, or hasEverParkedKey.
    }

    /// Registers the external-change observer with an explicit main queue. Not guaranteed to
    /// be delivered on the main thread otherwise — see file header threading note.
    private func startObservingRemoteChanges() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            self?.applyRemoteChange(reason: reason)
        }
    }

    // MARK: - Envelope encode/decode helpers

    private func decodeEnvelope(_ data: Data?) -> SyncedCarEnvelope? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SyncedCarEnvelope.self, from: data)
    }

    /// Encodes and writes an envelope to `cloudStore`. Returns false (without writing) on an
    /// encoding failure, which is not expected for a simple Codable struct but should not
    /// crash the app nor leave a partial write.
    @discardableResult
    private func writeEnvelope(_ envelope: SyncedCarEnvelope) -> Bool {
        do {
            let data = try JSONEncoder().encode(envelope)
            cloudStore.set(data, forKey: syncedStateKey)
            return true
        } catch {
            assertionFailure("ParkPinService.writeEnvelope: encoding failed: \(error)")
            return false
        }
    }
}

// MARK: - UbiquitousKeyValueStoring

/// Protocol that mirrors the subset of `NSUbiquitousKeyValueStore` used by `ParkPinService`.
/// This allows test injection of an in-memory mock without requiring a real iCloud account
/// or a second device (spec §3.7) — mirrors `NotificationScheduler.swift`'s
/// `UNUserNotificationCenterProtocol` pattern exactly.
protocol UbiquitousKeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}
