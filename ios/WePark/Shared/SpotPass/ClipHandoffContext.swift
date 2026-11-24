//
//  ClipHandoffContext.swift
//  Shared/SpotPass
//
//  Carry-over payload, clip -> full app (spec §6.2). Non-sensitive only: never a password, the
//  claimer secret, or a refresh token (those stay in the keychain under `clipKeychainLabel`).
//  C0 ships the shape and a UserDefaults-backed store; C2 (adoption) and C3 (writer) use it.
//

import Foundation

nonisolated struct ClipHandoffContext: Codable, Equatable, Sendable {
    var v: Int
    var userId: String
    var firstPassAt: Date
    var passesHelped: Int
    var passesPendingKarma: Int
    var lastAlias: String?
    var origin: String

    static let currentVersion = 1
    static let clipOrigin = "clip"

    init(
        v: Int = ClipHandoffContext.currentVersion,
        userId: String,
        firstPassAt: Date,
        passesHelped: Int,
        passesPendingKarma: Int,
        lastAlias: String?,
        origin: String = ClipHandoffContext.clipOrigin
    ) {
        self.v = v
        self.userId = userId
        self.firstPassAt = firstPassAt
        self.passesHelped = passesHelped
        self.passesPendingKarma = passesPendingKarma
        self.lastAlias = lastAlias
        self.origin = origin
    }
}

/// Reads/writes the context in a `UserDefaults` suite (the App Group suite in production, an
/// ephemeral suite in tests). A nil suite makes every call a no-op.
nonisolated struct ClipHandoffContextStore {
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = SpotPassShared.sharedDefaults()) {
        self.defaults = defaults
    }

    func save(_ context: ClipHandoffContext) {
        guard let defaults, let data = try? Self.makeEncoder().encode(context) else { return }
        defaults.set(data, forKey: SpotPassShared.carryOverDefaultsKey)
    }

    /// Returns nil when absent, undecodable, or from an unknown version.
    func load() -> ClipHandoffContext? {
        guard let defaults,
              let data = defaults.data(forKey: SpotPassShared.carryOverDefaultsKey),
              let context = try? Self.makeDecoder().decode(ClipHandoffContext.self, from: data),
              context.v == ClipHandoffContext.currentVersion
        else { return nil }
        return context
    }

    func clear() {
        defaults?.removeObject(forKey: SpotPassShared.carryOverDefaultsKey)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
