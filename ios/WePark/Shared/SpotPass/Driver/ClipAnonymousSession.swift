//
//  ClipAnonymousSession.swift
//  Shared/SpotPass/Driver
//
//  The clip's anonymous Supabase identity (spec section 6.2), over plain GoTrue REST so the clip
//  links no Supabase SDK. Best effort: a failure never blocks arming a pass (claim works without a
//  user JWT; the pass just earns no karma). The session record goes in the keychain under the
//  clip label; only the user id leaves it (into the carry-over context).
//

import Foundation
import Security

nonisolated struct ClipSessionRecord: Codable, Equatable, Sendable {
    var userId: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

@MainActor
protocol ClipSessionProviding: AnyObject {
    /// A valid session (signing in anonymously if none), or nil on any failure. Never throws.
    func session() async -> ClipSessionRecord?
}

@MainActor
final class GoTrueClipSession: ClipSessionProviding {

    nonisolated static let keychainService = "com.kevinhoxha.wepark.clip.session"

    private let baseURL: URL
    private let anonKey: String
    private let urlSession: URLSession
    private let now: () -> Date

    init(baseURL: URL, anonKey: String, urlSession: URLSession = .shared, now: @escaping () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.urlSession = urlSession
        self.now = now
    }

    convenience init?(bundle: Bundle = .main) {
        guard let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: urlString), url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String, !key.isEmpty
        else { return nil }
        self.init(baseURL: url, anonKey: key)
    }

    func session() async -> ClipSessionRecord? {
        if let stored = Self.loadRecord() {
            if stored.expiresAt > now().addingTimeInterval(60) { return stored }
            if let refreshed = await refresh(stored) { return refreshed }
        }
        return await signInAnonymously()
    }

    private func signInAnonymously() async -> ClipSessionRecord? {
        guard let request = Self.request(baseURL: baseURL, anonKey: anonKey, path: "auth/v1/signup", query: nil,
                                         body: ["data": [String: String]()]) else { return nil }
        return await perform(request)
    }

    private func refresh(_ record: ClipSessionRecord) async -> ClipSessionRecord? {
        guard let request = Self.request(baseURL: baseURL, anonKey: anonKey, path: "auth/v1/token",
                                         query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                         body: ["refresh_token": record.refreshToken]) else { return nil }
        return await perform(request)
    }

    private func perform(_ request: URLRequest) async -> ClipSessionRecord? {
        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let record = Self.decode(data, now: now())
        else { return nil }
        Self.saveRecord(record)
        return record
    }

    // MARK: Pure

    nonisolated static func request(
        baseURL: URL, anonKey: String, path: String, query: [URLQueryItem]?, body: [String: Any]
    ) -> URLRequest? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url, let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        return request
    }

    nonisolated static func decode(_ data: Data, now: Date) -> ClipSessionRecord? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let user = json["user"] as? [String: Any], let uid = user["id"] as? String
        else { return nil }
        let ttl = (json["expires_in"] as? Double) ?? 3600
        return ClipSessionRecord(userId: uid, accessToken: access, refreshToken: refresh,
                                 expiresAt: now.addingTimeInterval(ttl))
    }

    // MARK: Keychain

    private nonisolated static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "session"]
    }

    nonisolated static func loadRecord() -> ClipSessionRecord? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(ClipSessionRecord.self, from: data)
    }

    nonisolated static func saveRecord(_ record: ClipSessionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        SecItemDelete(query() as CFDictionary)
        var attributes = query()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = SpotPassShared.clipKeychainLabel
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
