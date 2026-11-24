//
//  HandoffStorage.swift
//  Shared/SpotPass/Driver
//
//  Where the clip keeps its state (spec sections 5.1, 6.2, 9 item 12):
//    - the CLAIMER SECRET: keychain only, labelled `SpotPassShared.clipKeychainLabel`. Never in
//      UserDefaults or the App Group, never logged.
//    - the non-sensitive active-pass snapshot (alias, times, status): App Group `UserDefaults`, so a
//      launch from a notification (which carries no invocation URL) can restore the screen.
//    - the clip's anonymous Supabase session (refresh token): keychain, same label.
//

import CryptoKit
import Foundation
import Security

// MARK: - Active pass snapshot

nonisolated struct HandoffActivePass: Codable, Equatable, Sendable {

    enum Status: String, Codable, Sendable {
        case armed
        case departed
    }

    var id: UUID
    var alias: String
    var glyph: String
    var displayName: String?
    var armedAt: Date
    var leaveAt: Date
    var expiresAt: Date
    var extensions: Int
    var status: Status
    var departedAt: Date?
    var thanksReceived: Bool
    /// The clip's anonymous user id (not a secret): used for the carry-over context.
    var userId: String?
    /// One-way fingerprint of the invocation token this pass was claimed with (NOT the token), so a
    /// re-delivered URL for THIS pass is told apart from a scan of a DIFFERENT one. nil on older saves.
    var tokenFingerprint: String?

    /// First 8 bytes of SHA-256, hex. Not reversible to the token.
    static func fingerprint(forToken token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var name: String { displayName ?? alias }

    /// The server allows 3 extensions (spec section 3).
    static let maxExtensions = 3
}

@MainActor
protocol HandoffPassStoring: AnyObject {
    func load() -> HandoffActivePass?
    func save(_ pass: HandoffActivePass)
    func clear()
}

@MainActor
final class UserDefaultsHandoffPassStore: HandoffPassStoring {
    nonisolated static let key = "spotPassClipActivePass"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> HandoffActivePass? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HandoffActivePass.self, from: data)
    }

    func save(_ pass: HandoffActivePass) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pass) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

@MainActor
final class InMemoryHandoffPassStore: HandoffPassStoring {
    var pass: HandoffActivePass?
    func load() -> HandoffActivePass? { pass }
    func save(_ pass: HandoffActivePass) { self.pass = pass }
    func clear() { pass = nil }
}

// MARK: - Secret storage

@MainActor
protocol HandoffSecretStoring: AnyObject {
    /// Returns false when the secret could NOT be stored: the caller must not arm without it.
    @discardableResult func save(_ secret: ClaimerSecret, passID: UUID) -> Bool
    func secret(for passID: UUID) -> ClaimerSecret?
    func clear()
}

@MainActor
final class InMemoryHandoffSecretStore: HandoffSecretStoring {
    private var stored: (UUID, ClaimerSecret)?
    @discardableResult func save(_ secret: ClaimerSecret, passID: UUID) -> Bool { stored = (passID, secret); return true }
    func secret(for passID: UUID) -> ClaimerSecret? { stored?.0 == passID ? stored?.1 : nil }
    func clear() { stored = nil }
}

/// Generic-password keychain item. One item per clip (one active pass at a time); the account is
/// the pass id, so a stale secret can never be used for a different pass.
@MainActor
final class KeychainHandoffSecretStore: HandoffSecretStoring {

    nonisolated static let service = "com.kevinhoxha.wepark.clip.claimer-secret"

    @discardableResult func save(_ secret: ClaimerSecret, passID: UUID) -> Bool {
        clear()
        guard let data = secret.rawValue.data(using: .utf8) else { return false }
        let attributes = Self.addAttributes(passID: passID, data: data)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func secret(for passID: UUID) -> ClaimerSecret? {
        var query = Self.baseQuery(passID: passID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let string = String(data: data, encoding: .utf8)
        else { return nil }
        return ClaimerSecret(string)
    }

    func clear() {
        SecItemDelete(Self.baseQuery(passID: nil) as CFDictionary)
    }

    // MARK: Pure query builders (unit-tested; the real keychain is not touched in tests)

    nonisolated static func baseQuery(passID: UUID?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let passID { query[kSecAttrAccount as String] = passID.uuidString.lowercased() }
        return query
    }

    nonisolated static func addAttributes(passID: UUID, data: Data) -> [String: Any] {
        var attributes = baseQuery(passID: passID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = SpotPassShared.clipKeychainLabel
        // Usable from a notification action while the phone is locked after first unlock; never synced.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }
}

// MARK: - Carry-over (clip -> full app)

/// Pure updates of the shared `ClipHandoffContext` (spec section 6.2). The full app (C2) adopts it.
nonisolated enum ClipCarryOver {

    /// After a successful depart: one more pass whose karma is pending.
    static func afterDeparture(
        existing: ClipHandoffContext?, userId: String, alias: String, now: Date
    ) -> ClipHandoffContext {
        var context = existing ?? ClipHandoffContext(
            userId: userId, firstPassAt: now, passesHelped: 0, passesPendingKarma: 0, lastAlias: alias
        )
        context.userId = userId
        context.passesPendingKarma += 1
        context.lastAlias = alias
        return context
    }

    /// After the seeker confirms: one pending pass becomes settled.
    static func afterThanks(existing: ClipHandoffContext?) -> ClipHandoffContext? {
        guard var context = existing else { return nil }
        context.passesPendingKarma = max(0, context.passesPendingKarma - 1)
        context.passesHelped += 1
        return context
    }
}
