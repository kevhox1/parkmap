//
//  ParkPinServiceSyncTests.swift
//  WeParkTests
//
//  Build 19 — iCloud parked-car sync (docs/icloud-parked-car-sync-spec.md).
//
//  `ParkPinService` had ZERO unit test coverage before this feature (deferred W5 QA Finding
//  #3). This file is BOTH the regression net for the unchanged local save/load/clear
//  behavior AND the new coverage for the merge/tombstone/migration/quota logic — the state
//  matrix from spec §3.3, verified via `MockUbiquitousStore` (an in-memory
//  `UbiquitousKeyValueStoring`) so none of it needs real iCloud or a second device (§3.7).
//
//  What this file CANNOT verify (see spec §7 and the PR description): whether iCloud
//  actually delivers a write to a second device, how fast, whether `AccountChange` behaves
//  in practice as documented, or whether the entitlement is correctly provisioned in a real
//  archived build. All four require two physical devices signed into the same Apple ID.
//
//  No Calendar.current use.
//

import XCTest
import Combine
@testable import WePark

// MARK: - MockUbiquitousStore

/// In-memory `UbiquitousKeyValueStoring` for test injection. Mirrors
/// `NotificationSchedulerTests.MockNotificationCenter`'s role exactly — lets a test seed an
/// arbitrary remote envelope, call `applyRemoteChange()` directly, and assert on
/// `parkedCar`/`remoteCarChanged` output without a real device or a real iCloud account.
final class MockUbiquitousStore: UbiquitousKeyValueStoring {

    private var storage: [String: Data] = [:]
    private(set) var synchronizeCallCount = 0
    private(set) var setCallCount = 0

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    /// Matches `UbiquitousKeyValueStoring`'s `Data?` requirement (mirrors the real
    /// `NSUbiquitousKeyValueStore.set(_:forKey:)` overload for `Data`). `ParkPinService`
    /// never passes `nil` here — see the protocol's doc comment — but this mock honors the
    /// real store's semantics regardless: a `nil` write removes the key, same as
    /// `storage[key] = nil` does on a `[String: Data]` dictionary.
    func set(_ data: Data?, forKey key: String) {
        storage[key] = data
        setCallCount += 1
    }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCallCount += 1
        return true
    }

    /// Test helper: seeds an envelope directly into the store, as if it had arrived from
    /// another device, WITHOUT going through `ParkPinService` at all.
    func seed(_ envelope: SyncedCarEnvelope, forKey key: String) {
        storage[key] = try! JSONEncoder().encode(envelope)
    }

    /// Test helper: decodes whatever is currently stored under `key`, if anything.
    func decodedEnvelope(forKey key: String) -> SyncedCarEnvelope? {
        guard let data = storage[key] else { return nil }
        return try? JSONDecoder().decode(SyncedCarEnvelope.self, from: data)
    }
}

// MARK: - Shared fixtures

/// Key names duplicated here deliberately — `ParkPinService`'s storage keys are private
/// implementation detail, not part of its public contract. Tests know them because the spec
/// pins them (§3.1, §3.6): "wepark_synced_car_state" (cloud), "wepark_parked_car" (legacy
/// UserDefaults), "wepark_has_ever_parked" (device-local W6 flag).
private let syncedStateKey = "wepark_synced_car_state"
private let legacyStorageKey = "wepark_parked_car"
private let hasEverParkedKeyName = "wepark_has_ever_parked"

private func pcsCar(
    id: UUID = UUID(),
    parkedAt: Date,
    notifyOnRestriction: Bool = true
) -> ParkedCar {
    ParkedCar(
        id: id,
        latitude: 40.7183,
        longitude: -73.9942,
        detectedSegmentID: "TEST_SEGMENT",
        detectedSide: "N",
        street: "MOTT STREET",
        fromStreet: "GRAND STREET",
        toStreet: "HESTER STREET",
        parkedAt: parkedAt,
        notifyOnRestriction: notifyOnRestriction
    )
}

// MARK: - ParkPinServiceSyncTests

final class ParkPinServiceSyncTests: XCTestCase {

    private let suiteName = "com.wepark.test.parkpinservicesync"
    private var ephemeralDefaults: UserDefaults!
    private var mockStore: MockUbiquitousStore!
    private var service: ParkPinService!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        mockStore = MockUbiquitousStore()
        service = ParkPinService(cloudStore: mockStore, defaults: ephemeralDefaults)
        cancellables = []
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        mockStore = nil
        service = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - AC-1: the legacy UserDefaults blob is only ever touched by load()'s migration
    // path — no other method reads or writes it (save/clearPin/updateNotifyOnRestriction/
    // applyRemoteChange all go through cloudStore exclusively for the car itself).

    func testLegacyKey_untouchedBySaveClearAndToggle() {
        let car = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        service.save(car)
        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey), "save() must not write the legacy key")

        service.updateNotifyOnRestriction(false)
        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey), "updateNotifyOnRestriction() must not write the legacy key")

        service.clearPin()
        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey), "clearPin() must not write the legacy key")
    }

    func testLegacyKey_untouchedByApplyRemoteChange() {
        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey), "applyRemoteChange() must not touch the legacy key")
    }

    // MARK: - AC-2: fresh install, empty cloud store, no legacy blob → no car on launch.

    func testFreshInstall_emptyStoreNoLegacy_noCarOnLaunch() {
        service.load()
        XCTAssertNil(service.parkedCar)
        XCTAssertNil(service.currentUpdatedAt)
    }

    // MARK: - AC-3 (regression): save() fires firstPinDropped exactly once ever, pinDropped every time.

    func testSave_firstPinDropped_firesExactlyOncePerInstall() {
        var firstPinCount = 0
        service.firstPinDropped.sink { firstPinCount += 1 }.store(in: &cancellables)

        let carA = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        let carB = pcsCar(parkedAt: Date(timeIntervalSince1970: 2000))
        service.save(carA)
        service.save(carB)

        XCTAssertEqual(firstPinCount, 1, "firstPinDropped must fire exactly once per install")
    }

    func testSave_pinDropped_firesOnEverySave() {
        var pinDroppedCars: [ParkedCar] = []
        service.pinDropped.sink { pinDroppedCars.append($0) }.store(in: &cancellables)

        let carA = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        let carB = pcsCar(parkedAt: Date(timeIntervalSince1970: 2000))
        service.save(carA)
        service.save(carB)

        XCTAssertEqual(pinDroppedCars.count, 2, "pinDropped must fire on every save, including replacements")
        XCTAssertEqual(pinDroppedCars.last?.id, carB.id)
    }

    // MARK: - AC-4: save() writes a .parked envelope with updatedAt == car.parkedAt.

    func testSave_writesParkedEnvelope_updatedAtEqualsParkedAt() {
        let car = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        service.save(car)

        let envelope = mockStore.decodedEnvelope(forKey: syncedStateKey)
        XCTAssertEqual(envelope?.kind, .parked)
        XCTAssertEqual(envelope?.updatedAt, car.parkedAt)
        XCTAssertEqual(envelope?.car?.id, car.id)
        XCTAssertEqual(service.currentUpdatedAt, car.parkedAt)
    }

    // MARK: - AC-5: clearPin() writes a .cleared TOMBSTONE, not a removed/absent key.

    func testClearPin_writesTombstone_notAbsentKey() {
        let car = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        service.save(car)

        service.clearPin()

        let envelope = mockStore.decodedEnvelope(forKey: syncedStateKey)
        XCTAssertNotNil(envelope, "clearPin() must write a tombstone envelope, not remove the key")
        XCTAssertEqual(envelope?.kind, .cleared)
        XCTAssertNil(envelope?.car)
        XCTAssertNil(service.parkedCar)
        XCTAssertNotNil(service.currentUpdatedAt)
        XCTAssertGreaterThan(service.currentUpdatedAt!, car.parkedAt, "tombstone must carry a fresh updatedAt")
    }

    // MARK: - AC-6: migration — legacy-only device, empty cloud store.

    func testMigration_legacyOnly_becomesFirstEnvelope_legacyKeyRemoved() {
        let legacyCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 3000))
        ephemeralDefaults.set(try! JSONEncoder().encode(legacyCar), forKey: legacyStorageKey)

        service.load()

        XCTAssertEqual(service.parkedCar?.id, legacyCar.id)
        XCTAssertEqual(service.currentUpdatedAt, legacyCar.parkedAt)

        let envelope = mockStore.decodedEnvelope(forKey: syncedStateKey)
        XCTAssertEqual(envelope?.kind, .parked)
        XCTAssertEqual(envelope?.car?.id, legacyCar.id)
        XCTAssertEqual(envelope?.updatedAt, legacyCar.parkedAt)

        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey), "legacy key must be removed after migration")
    }

    // MARK: - AC-7: migration + conflict — resolved by updatedAt only, both directions.

    func testMigration_conflict_legacyNewer_legacyWins() {
        let legacyCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 9000))
        ephemeralDefaults.set(try! JSONEncoder().encode(legacyCar), forKey: legacyStorageKey)

        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 4000))
        let remoteEnvelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(remoteEnvelope, forKey: syncedStateKey)

        service.load()

        XCTAssertEqual(service.parkedCar?.id, legacyCar.id, "legacy is newer (9000 > 4000) — legacy must win")
        XCTAssertEqual(service.currentUpdatedAt, legacyCar.parkedAt)
        // Legacy won — the store must be overwritten with the legacy-derived envelope so
        // this Apple ID's other devices see it too.
        XCTAssertEqual(mockStore.decodedEnvelope(forKey: syncedStateKey)?.car?.id, legacyCar.id)
        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey))
    }

    func testMigration_conflict_remoteNewer_remoteWins() {
        let legacyCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        ephemeralDefaults.set(try! JSONEncoder().encode(legacyCar), forKey: legacyStorageKey)

        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 9000))
        let remoteEnvelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(remoteEnvelope, forKey: syncedStateKey)

        service.load()

        XCTAssertEqual(service.parkedCar?.id, remoteCar.id, "remote is newer (9000 > 1000) — remote must win")
        XCTAssertEqual(service.currentUpdatedAt, remoteCar.parkedAt)
        // Remote won — the store must NOT be clobbered with the losing legacy envelope.
        XCTAssertEqual(mockStore.decodedEnvelope(forKey: syncedStateKey)?.car?.id, remoteCar.id)
        XCTAssertNil(ephemeralDefaults.data(forKey: legacyStorageKey), "legacy key removed regardless of which side won")
    }

    /// Migration + a tombstone already in the cloud store, remote (tombstone) newer — legacy
    /// car must NOT resurrect. Extends AC-7's matrix with the tombstone case explicitly.
    func testMigration_conflict_remoteTombstoneNewer_carStaysCleared() {
        let legacyCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        ephemeralDefaults.set(try! JSONEncoder().encode(legacyCar), forKey: legacyStorageKey)

        let tombstone = SyncedCarEnvelope(kind: .cleared, updatedAt: Date(timeIntervalSince1970: 9000), car: nil)
        mockStore.seed(tombstone, forKey: syncedStateKey)

        service.load()

        XCTAssertNil(service.parkedCar, "a newer remote tombstone must win over the legacy car")
        XCTAssertEqual(service.currentUpdatedAt, tombstone.updatedAt)
    }

    // MARK: - AC-8: hasEverParkedKey is never read or written by applyRemoteChange()/load()'s
    // remote-only path/migration — only by save().

    func testHasEverParkedKey_untouchedByRemoteChange() {
        XCTAssertFalse(ephemeralDefaults.bool(forKey: hasEverParkedKeyName))

        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(service.parkedCar?.id, remoteCar.id)
        XCTAssertFalse(ephemeralDefaults.bool(forKey: hasEverParkedKeyName),
                        "hasEverParkedKey must remain unset after a remote-only arrival")
    }

    func testHasEverParkedKey_untouchedByLoadRemoteOnlyPath() {
        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.load()   // AC-verified case 6: fresh device, no legacy blob, store already has a car

        XCTAssertEqual(service.parkedCar?.id, remoteCar.id)
        XCTAssertFalse(ephemeralDefaults.bool(forKey: hasEverParkedKeyName),
                        "a fresh device's first LOCAL pin drop must still trigger the W6 rationale sheet later")
    }

    func testHasEverParkedKey_untouchedByMigration() {
        let legacyCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 3000))
        ephemeralDefaults.set(try! JSONEncoder().encode(legacyCar), forKey: legacyStorageKey)

        service.load()

        XCTAssertFalse(ephemeralDefaults.bool(forKey: hasEverParkedKeyName),
                        "migration is not a local pin drop and must not set hasEverParkedKey")
    }

    func testHasEverParkedKey_setOnlyBySave() {
        let car = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        service.save(car)
        XCTAssertTrue(ephemeralDefaults.bool(forKey: hasEverParkedKeyName))
    }

    // MARK: - AC-9: remote envelope with updatedAt <= current is a no-op.

    func testApplyRemoteChange_staleUpdatedAt_isNoOp() {
        let localCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        service.save(localCar)

        var remoteChangedFireCount = 0
        service.remoteCarChanged.sink { _ in remoteChangedFireCount += 1 }.store(in: &cancellables)

        // Stale delivery: an older car arrives AFTER the local save (spec §3.1's exact scenario).
        let staleCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        let staleEnvelope = SyncedCarEnvelope(kind: .parked, updatedAt: staleCar.parkedAt, car: staleCar)
        mockStore.seed(staleEnvelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(service.parkedCar?.id, localCar.id, "the newer local car must stay")
        XCTAssertEqual(service.currentUpdatedAt, localCar.parkedAt)
        XCTAssertEqual(remoteChangedFireCount, 0, "remoteCarChanged must not fire for a no-op merge")
    }

    func testApplyRemoteChange_equalUpdatedAt_isNoOp() {
        let sharedDate = Date(timeIntervalSince1970: 5000)
        let localCar = pcsCar(parkedAt: sharedDate)
        service.save(localCar)

        // Same updatedAt, different car id — must still be a no-op (strictly-greater only).
        let otherCar = pcsCar(parkedAt: sharedDate)
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: sharedDate, car: otherCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(service.parkedCar?.id, localCar.id)
    }

    // MARK: - AC-10: remote envelope, updatedAt > current, kind == .parked.

    func testApplyRemoteChange_newerParked_updatesCarAndFiresRemoteCarChanged() {
        let localCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        service.save(localCar)

        var events: [(newCar: ParkedCar?, oldCarID: UUID?)] = []
        service.remoteCarChanged.sink { events.append($0) }.store(in: &cancellables)

        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 9000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(service.parkedCar?.id, remoteCar.id)
        XCTAssertEqual(service.currentUpdatedAt, remoteCar.parkedAt)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.newCar?.id, remoteCar.id)
        XCTAssertEqual(events.first?.oldCarID, localCar.id)
    }

    // MARK: - AC-11: remote envelope, updatedAt > current, kind == .cleared.

    func testApplyRemoteChange_newerTombstone_clearsCarAndFiresRemoteCarChanged() {
        let localCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        service.save(localCar)

        var events: [(newCar: ParkedCar?, oldCarID: UUID?)] = []
        service.remoteCarChanged.sink { events.append($0) }.store(in: &cancellables)

        let tombstone = SyncedCarEnvelope(kind: .cleared, updatedAt: Date(timeIntervalSince1970: 9000), car: nil)
        mockStore.seed(tombstone, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertNil(service.parkedCar)
        XCTAssertEqual(service.currentUpdatedAt, tombstone.updatedAt)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.newCar)
        XCTAssertEqual(events.first?.oldCarID, localCar.id)
    }

    // MARK: - AC-12: firstPinDropped/pinDropped never fire from applyRemoteChange().

    func testApplyRemoteChange_neverFiresFirstPinDroppedOrPinDropped() {
        var firstPinCount = 0
        var pinDroppedCount = 0
        var remoteChangedCount = 0
        service.firstPinDropped.sink { firstPinCount += 1 }.store(in: &cancellables)
        service.pinDropped.sink { _ in pinDroppedCount += 1 }.store(in: &cancellables)
        service.remoteCarChanged.sink { _ in remoteChangedCount += 1 }.store(in: &cancellables)

        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 9000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(firstPinCount, 0)
        XCTAssertEqual(pinDroppedCount, 0)
        XCTAssertEqual(remoteChangedCount, 1)
    }

    /// Also exercises AccountChange (spec §0.2/OQ-2): treated identically to a normal remote
    /// update, no special-casing — same merge check, same publisher-suppression guarantee.
    func testApplyRemoteChange_accountChange_treatedAsNormalUpdate_stillSuppressesLocalPublishers() {
        var firstPinCount = 0
        var pinDroppedCount = 0
        service.firstPinDropped.sink { firstPinCount += 1 }.store(in: &cancellables)
        service.pinDropped.sink { _ in pinDroppedCount += 1 }.store(in: &cancellables)

        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 9000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreAccountChange)

        XCTAssertEqual(service.parkedCar?.id, remoteCar.id, "AccountChange must adopt the store's current value via the same merge check")
        XCTAssertEqual(firstPinCount, 0)
        XCTAssertEqual(pinDroppedCount, 0)
    }

    // MARK: - AC-16: updateNotifyOnRestriction() bumps updatedAt even though parkedAt is unchanged.

    func testUpdateNotifyOnRestriction_bumpsUpdatedAt_propagatesAsRemoteUpdate() {
        let originalParkedAt = Date(timeIntervalSince1970: 5000)
        let car = pcsCar(parkedAt: originalParkedAt, notifyOnRestriction: true)
        service.save(car)

        service.updateNotifyOnRestriction(false)

        let envelope = mockStore.decodedEnvelope(forKey: syncedStateKey)
        XCTAssertEqual(envelope?.car?.parkedAt, originalParkedAt, "parkedAt itself must not change")
        XCTAssertNotEqual(envelope?.updatedAt, originalParkedAt, "updatedAt must be bumped for a metadata-only edit")
        XCTAssertEqual(envelope?.car?.notifyOnRestriction, false)

        // The concrete test for §0.1's ruling: a second ParkPinService instance, seeded with
        // the PRE-toggle car, adopts the toggled value when the resulting envelope is applied
        // as a "remote" update — i.e. the toggle is not silently unpropagatable because
        // car.parkedAt didn't change.
        let secondStore = MockUbiquitousStore()
        let secondDefaults = UserDefaults(suiteName: suiteName + ".second")!
        secondDefaults.removePersistentDomain(forName: suiteName + ".second")
        let secondService = ParkPinService(cloudStore: secondStore, defaults: secondDefaults)
        let preToggleEnvelope = SyncedCarEnvelope(kind: .parked, updatedAt: originalParkedAt, car: car)
        secondStore.seed(preToggleEnvelope, forKey: syncedStateKey)
        secondService.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)
        XCTAssertEqual(secondService.parkedCar?.notifyOnRestriction, true)

        // Now the toggle's envelope arrives as a remote update on the second instance.
        secondStore.seed(envelope!, forKey: syncedStateKey)
        secondService.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)
        XCTAssertEqual(secondService.parkedCar?.notifyOnRestriction, false,
                        "the toggled value must win via the bumped updatedAt, even though parkedAt is identical")

        secondDefaults.removePersistentDomain(forName: suiteName + ".second")
    }

    func testUpdateNotifyOnRestriction_noCarParked_isNoOp() {
        service.updateNotifyOnRestriction(false)
        XCTAssertNil(service.parkedCar)
        XCTAssertNil(mockStore.decodedEnvelope(forKey: syncedStateKey))
    }

    // MARK: - AC-17: QuotaViolationChange handled without crash, no partial/corrupt write.

    func testApplyRemoteChange_quotaViolation_noCrashNoPartialWrite() {
        let localCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        service.save(localCar)

        // Seed a "remote" value that would otherwise win, to prove it's genuinely ignored.
        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 9000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange)

        XCTAssertEqual(service.parkedCar?.id, localCar.id, "a quota violation must not adopt the pending remote value")
        XCTAssertEqual(service.currentUpdatedAt, localCar.parkedAt)
    }

    // MARK: - AC-18: a representative SyncedCarEnvelope encodes to well under 2 KB (canary).

    func testSyncedCarEnvelope_encodedSize_staysUnderQuotaCanary() {
        let car = ParkedCar(
            id: UUID(),
            latitude: 40.718376,
            longitude: -73.994231,
            detectedSegmentID: "MOTT_STREET_GRAND_HESTER_N",
            detectedSide: "N",
            street: "MOTT STREET",
            fromStreet: "GRAND STREET",
            toStreet: "HESTER STREET",
            parkedAt: Date(),
            notifyOnRestriction: true
        )
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: Date(), car: car)
        let data = try! JSONEncoder().encode(envelope)
        XCTAssertLessThan(data.count, 2048, "a representative envelope should stay well under the 1 MB store's practical per-write budget")
    }

    // MARK: - Fresh-device-with-remote-car (spec §3.3 case 6) — full-state check beyond AC-8's flag assertion.

    func testFreshDevice_noLegacyBlob_remoteCarAppearsOnFirstLaunch() {
        let remoteCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 5000))
        let envelope = SyncedCarEnvelope(kind: .parked, updatedAt: remoteCar.parkedAt, car: remoteCar)
        mockStore.seed(envelope, forKey: syncedStateKey)

        service.load()

        XCTAssertEqual(service.parkedCar?.id, remoteCar.id,
                        "a fresh device must show the already-synced car with no action taken")
    }

    // MARK: - "Neither ever written" (spec §3.3 case 5) — identical to today's fresh-install state.

    func testNeitherLocalNorRemoteEverWritten_noCar() {
        service.load()
        XCTAssertNil(service.parkedCar)

        var events = 0
        service.remoteCarChanged.sink { _ in events += 1 }.store(in: &cancellables)
        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)   // key still absent
        XCTAssertNil(service.parkedCar)
        XCTAssertEqual(events, 0, "an absent/corrupt key must be a no-op, never an implicit clear")
    }

    // MARK: - Corrupt data — decode failure must not crash and must not clear an existing car.

    func testApplyRemoteChange_corruptData_isNoOp() {
        let localCar = pcsCar(parkedAt: Date(timeIntervalSince1970: 1000))
        service.save(localCar)

        mockStore.set(Data([0xFF, 0x00, 0x01]), forKey: syncedStateKey)   // not valid JSON

        service.applyRemoteChange(reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(service.parkedCar?.id, localCar.id, "corrupt remote data must not clear an existing car")
    }
}
