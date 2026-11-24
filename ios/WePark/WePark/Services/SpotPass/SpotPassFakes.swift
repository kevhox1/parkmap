//
//  SpotPassFakes.swift
//  Services/SpotPass
//
//  Spot Pass C1: in-memory fakes for unit tests, SwiftUI previews and the local QA demo.
//  DEBUG ONLY: compiled out of Release, so no fake and no demo switch can ship.
//
//  Local QA demo (DEBUG builds, flag on): launch with `-spotPassUseFakeAPI YES` and the seeker
//  flow runs against `FakeSpotPassAPI.demo()` instead of the network: a pass is created, a
//  "neighbor scans" 10 s later (armed, leaving in about 30 min), and "departs" 25 s after that.
//

#if DEBUG

import Foundation

// MARK: - Fake API

@MainActor
final class FakeSpotPassAPI: SpotPassAPI {

    // Scripted results (tests mutate these between calls).
    var createResult: Result<SpotPassSession, Error>
    var statusResult: Result<SpotPassSnapshot, Error>
    var karmaResult: Result<SpotPassKarma, Error>
    var confirmResult: Result<SpotPassConfirmResult, Error> = .success(SpotPassConfirmResult(ok: true, seekerPoints: 0))
    var usernameResult: Result<String?, Error> = .success(nil)
    var cancelResult: Result<Void, Error> = .success(())
    /// Karma the next `fetchKarma` returns after a successful confirm (simulates the ledger award).
    var karmaAfterConfirm: SpotPassKarma?

    /// Optional time-based script for the demo: elapsed seconds since the pass was created.
    var statusScript: ((TimeInterval) -> SpotPassSnapshot)?
    private var createdAt: Date?

    // Recorded calls.
    private(set) var createCalls: [Bool] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var confirmations: [(id: UUID, outcome: SpotPassOutcome)] = []
    private(set) var statusCallCount = 0
    private(set) var karmaCallCount = 0

    init(
        createResult: Result<SpotPassSession, Error> = .success(FakeSpotPassAPI.sampleSession()),
        statusResult: Result<SpotPassSnapshot, Error> = .success(SpotPassSnapshot(status: .created)),
        karmaResult: Result<SpotPassKarma, Error> = .success(.zero)
    ) {
        self.createResult = createResult
        self.statusResult = statusResult
        self.karmaResult = karmaResult
    }

    func createHandoff(showName: Bool) async throws -> SpotPassSession {
        createCalls.append(showName)
        let session = try createResult.get()
        createdAt = Date()
        return session
    }

    func cancelHandoff(id: UUID) async throws {
        cancelledIDs.append(id)
        try cancelResult.get()
    }

    func confirmHandoffOutcome(id: UUID, outcome: SpotPassOutcome) async throws -> SpotPassConfirmResult {
        confirmations.append((id: id, outcome: outcome))
        let result = try confirmResult.get()
        if let karmaAfterConfirm { karmaResult = .success(karmaAfterConfirm) }
        return result
    }

    func fetchUsername() async throws -> String? {
        try usernameResult.get()
    }

    func fetchStatus(id: UUID) async throws -> SpotPassSnapshot {
        statusCallCount += 1
        if let statusScript, let createdAt {
            return statusScript(Date().timeIntervalSince(createdAt))
        }
        return try statusResult.get()
    }

    func fetchKarma() async throws -> SpotPassKarma {
        karmaCallCount += 1
        return try karmaResult.get()
    }

    // MARK: Samples

    /// A valid 22-char token so QR generation works against the fake.
    nonisolated static let sampleToken = "AbCdEfGhIjKlMnOpQrSt_-"

    nonisolated static func sampleSession(
        id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        alias: String = "Bodega Cat",
        glyph: String = "cat",
        displayName: String? = nil,
        now: Date = Date(),
        ttl: TimeInterval = 20 * 60
    ) -> SpotPassSession {
        SpotPassSession(
            id: id,
            token: sampleToken,
            alias: alias,
            glyph: glyph,
            displayName: displayName,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    /// The QA demo: created, then armed at +10 s (leaving in about 30 min), departed at +35 s.
    static func demo() -> FakeSpotPassAPI {
        let api = FakeSpotPassAPI(karmaResult: .success(SpotPassKarma(reputation: 12, helpedCount: 3)))
        api.karmaAfterConfirm = SpotPassKarma(reputation: 15, helpedCount: 3)
        api.confirmResult = .success(SpotPassConfirmResult(ok: true, seekerPoints: 3))
        api.usernameResult = .success("Maya")
        api.statusScript = { elapsed in
            let now = Date()
            if elapsed < 10 {
                return SpotPassSnapshot(status: .created, expiresAt: now.addingTimeInterval(20 * 60 - elapsed))
            }
            let leaveAt = now.addingTimeInterval(30 * 60)
            if elapsed < 35 {
                return SpotPassSnapshot(
                    status: .armed,
                    leaveAt: leaveAt,
                    expiresAt: leaveAt.addingTimeInterval(15 * 60)
                )
            }
            return SpotPassSnapshot(
                status: .departed,
                leaveAt: now,
                expiresAt: now.addingTimeInterval(15 * 60),
                departedAt: now.addingTimeInterval(-(elapsed - 35))
            )
        }
        return api
    }
}

// MARK: - In-memory persistence

@MainActor
final class InMemorySpotPassPersistence: SpotPassPersistence {
    private(set) var stored: SpotPassSession?
    private(set) var clearCount = 0

    init(stored: SpotPassSession? = nil) {
        self.stored = stored
    }

    func load() -> SpotPassSession? { stored }
    func save(_ session: SpotPassSession) { stored = session }
    func clear() {
        stored = nil
        clearCount += 1
    }
}

// MARK: - Recording feedback

@MainActor
final class RecordingSpotPassFeedback: SpotPassFeedback {
    private(set) var successCount = 0
    private(set) var announcements: [String] = []

    func success() { successCount += 1 }
    func announce(_ message: String) { announcements.append(message) }
}

#endif
