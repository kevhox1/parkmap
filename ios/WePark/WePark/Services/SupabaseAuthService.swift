//
//  SupabaseAuthService.swift
//  WePark
//
//  Tier 3 Sub-PR #1 — Anonymous auth identity layer.
//  Spec: docs/tier3-auth-and-reactions-spec.md §3.8.
//
//  SDK path: raw URLSession (not supabase-swift SPM).
//  Rationale: adding supabase-swift via manual project.pbxproj edit requires constructing
//  a valid Package.resolved with exact version checksums. Without Xcode's resolver running
//  interactively, any checksum mismatch leaves the project in a broken state (xcodebuild
//  fails to resolve). The spec explicitly authorises this fallback: "Fallback to discuss:
//  implement sub-PR #1 with raw URLSession (defer the SDK) so the work isn't blocked."
//  See PR description §SDK-path for the full rationale and the recommended SDK-adoption PR.
//
//  Behaviour:
//   - On first launch (no session in UserDefaults), calls POST /auth/v1/signup?anon=true.
//   - Persists the access_token + refresh_token + user_id in UserDefaults.
//     (UserDefaults is consistent with WePark's existing persistence approach and avoids
//     Keychain API without the SDK. A fast-follow PR should migrate to Keychain when the SDK
//     is added — see HANDOFF.md carry-over note for sub-PR #1.)
//   - Refreshes the JWT when it is within 2 minutes of expiry (before any write call).
//   - Exposes currentUserId: UUID? and accessToken: String? for RLS-aware writes.
//   - Never shows any UI (AC-A4).
//
//  Invariants:
//   - @MainActor @Observable — mutations visible to SwiftUI without extra dispatch.
//   - No Calendar.current — date arithmetic uses Date() + TimeInterval only.
//   - SUPABASE_URL and SUPABASE_ANON_KEY read from Info.plist (bridged from Config.xcconfig).
//     Keys are never hardcoded here.
//   - Single instance created in WeParkApp.swift and injected into ContentView / services.
//

import Foundation

// MARK: - SupabaseAuthService

/// Anonymous identity layer for WePark.
///
/// Calls Supabase's `POST /auth/v1/signup?anon=true` on first launch to obtain a
/// signed JWT without any user-visible prompt. The anonymous identity satisfies the
/// `auth.uid() IS NOT NULL` requirement of the `pins_insert_crowd` and `votes_insert_own`
/// RLS policies.
///
/// Thread safety: `@MainActor @Observable`. All state mutations are on the main actor.
/// Callers that need the current JWT should `await authService.ensureSession()` before
/// their first write — the method is safe to call redundantly (no-op if already valid).
@MainActor
@Observable
final class SupabaseAuthService {

    // MARK: - Public state

    /// The Supabase user UUID corresponding to `auth.uid()` in the JWT.
    /// Nil before `ensureSession()` completes or if authentication failed.
    private(set) var currentUserId: UUID? = nil

    /// True once a valid session has been established.
    private(set) var isAuthenticated: Bool = false

    // MARK: - Internal state

    /// The current short-lived JWT. Nil until ensureSession() completes.
    /// Refreshed automatically when nearing expiry.
    private(set) var accessToken: String? = nil

    /// Used to detect approaching expiry without Calendar.current (AC-I5).
    private var tokenExpiresAt: Date? = nil

    /// Opaque refresh token for JWT renewal.
    private var refreshToken: String? = nil

    // MARK: - Dependencies

    private let supabaseURL: URL
    private let supabaseAnonKey: String

    /// Injectable URLSession for unit tests (MockURLProtocol pattern).
    let urlSession: URLSession

    // MARK: - Persistence keys

    private enum Keys {
        static let accessToken   = "wepark_auth_access_token"
        static let refreshToken  = "wepark_auth_refresh_token"
        static let userId        = "wepark_auth_user_id"
        static let expiresAt     = "wepark_auth_expires_at"
    }

    // MARK: - Init

    /// Designated initializer. Reads SUPABASE_URL + SUPABASE_ANON_KEY from Info.plist.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
    }

    /// Convenience initializer. Reads keys from Bundle.main (Config.xcconfig → Info.plist bridge).
    convenience init() {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key)
    }

    // MARK: - Public API

    /// Ensures a valid session is present. Called from WeParkApp on launch.
    ///
    /// Flow:
    ///  1. Try to restore a persisted session from UserDefaults.
    ///  2. If the token is expiring soon (within 2 min), refresh it.
    ///  3. If no session exists, call signInAnonymously().
    ///  4. Fails silently — app stays in read-only mode if auth is unavailable.
    func ensureSession() async {
        // Try restoring from UserDefaults first.
        if restorePersistedSession() {
            // Session restored — check if it needs refreshing.
            if tokenNeedsRefresh() {
                await refreshAccessToken()
            }
            return
        }
        // No persisted session — create an anonymous one.
        await signInAnonymously()
    }

    // MARK: - Token refresh (called before writes)

    /// Proactively ensures the current token is valid before a write operation.
    ///
    /// Should be called at the start of `insertCrowdPin`, `upsertVote`, and
    /// `callExtendPinExpiry` (via a shared helper in CommunityPinService) to guarantee
    /// the JWT attached to the write request is not expired.
    ///
    /// - Returns: The current access token, or nil if authentication is unavailable.
    func validAccessToken() async -> String? {
        if tokenNeedsRefresh() {
            await refreshAccessToken()
        }
        return accessToken
    }

    // MARK: - Anonymous sign-in

    private func signInAnonymously() async {
        guard let request = buildSignUpRequest() else { return }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                // Non-2xx — fail silently for TF1 (AC-A4: no UI shown on failure).
                return
            }
            applySession(from: data)
        } catch {
            // Network error — fail silently; app stays in read-only mode.
        }
    }

    // MARK: - Token refresh

    private func refreshAccessToken() async {
        guard let refreshToken, let request = buildRefreshRequest(token: refreshToken) else {
            // No refresh token — start fresh.
            await signInAnonymously()
            return
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                // Refresh failed — sign in fresh.
                clearPersistedSession()
                await signInAnonymously()
                return
            }
            applySession(from: data)
        } catch {
            clearPersistedSession()
            await signInAnonymously()
        }
    }

    // MARK: - Session persistence

    private func restorePersistedSession() -> Bool {
        let defaults = UserDefaults.standard
        guard
            let token = defaults.string(forKey: Keys.accessToken),
            let refresh = defaults.string(forKey: Keys.refreshToken),
            let userIDString = defaults.string(forKey: Keys.userId),
            let userID = UUID(uuidString: userIDString)
        else { return false }

        let expiresAt: Date
        let expiresInterval = defaults.double(forKey: Keys.expiresAt)
        if expiresInterval > 0 {
            expiresAt = Date(timeIntervalSince1970: expiresInterval)
        } else {
            // No expiry stored — treat as expired so we refresh.
            return false
        }

        // If token is already hard-expired (past expiry + 5 min buffer), clear it.
        if expiresAt.addingTimeInterval(300) < Date() {
            clearPersistedSession()
            return false
        }

        self.accessToken = token
        self.refreshToken = refresh
        self.currentUserId = userID
        self.tokenExpiresAt = expiresAt
        self.isAuthenticated = true
        return true
    }

    private func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(accessToken, forKey: Keys.accessToken)
        defaults.set(refreshToken, forKey: Keys.refreshToken)
        defaults.set(currentUserId?.uuidString, forKey: Keys.userId)
        if let exp = tokenExpiresAt {
            defaults.set(exp.timeIntervalSince1970, forKey: Keys.expiresAt)
        }
    }

    private func clearPersistedSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.accessToken)
        defaults.removeObject(forKey: Keys.refreshToken)
        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.expiresAt)
        self.accessToken = nil
        self.refreshToken = nil
        self.currentUserId = nil
        self.tokenExpiresAt = nil
        self.isAuthenticated = false
    }

    // MARK: - Token expiry check

    /// Returns true when the token is within 2 minutes of expiry.
    /// Uses Date() + TimeInterval — no Calendar.current (AC-I5).
    private func tokenNeedsRefresh() -> Bool {
        guard let exp = tokenExpiresAt else { return true }
        return exp.timeIntervalSinceNow < 120  // < 2 minutes remaining
    }

    // MARK: - Response parsing

    /// Parses a Supabase auth response and applies state + persistence.
    private func applySession(from data: Data) {
        struct AuthResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Int
            let user: UserPayload

            struct UserPayload: Decodable {
                let id: String
            }

            private enum CodingKeys: String, CodingKey {
                case accessToken  = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn    = "expires_in"
                case user
            }
        }

        guard let decoded = try? JSONDecoder().decode(AuthResponse.self, from: data),
              let userID = UUID(uuidString: decoded.user.id) else { return }

        self.accessToken = decoded.accessToken
        self.refreshToken = decoded.refreshToken
        self.currentUserId = userID
        // expires_in is seconds from now. Date() + TimeInterval — no Calendar.current.
        self.tokenExpiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        self.isAuthenticated = true
        persistSession()
    }

    // MARK: - Request builders

    /// POST /auth/v1/signup?anon=true — creates a new anonymous session.
    private func buildSignUpRequest() -> URLRequest? {
        guard var components = URLComponents(
            url: supabaseURL.appendingPathComponent("auth/v1/signup"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [URLQueryItem(name: "anon", value: "true")]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anonymous sign-up has no body (Supabase's anon signup endpoint accepts empty body).
        request.httpBody = "{}".data(using: .utf8)
        return request
    }

    /// POST /auth/v1/token?grant_type=refresh_token — refreshes an existing session.
    private func buildRefreshRequest(token: String) -> URLRequest? {
        guard var components = URLComponents(
            url: supabaseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["refresh_token": token]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
