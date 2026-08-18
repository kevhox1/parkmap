//
//  SupabaseAuthService.swift
//  WePark
//
//  supabase-swift adoption — Stream A (Auth/Keychain).
//  Spec: docs/supabase-swift-realtime-spec.md §9, §11 (Stream A), AC-A1 through AC-A5.
//
//  Replaces the Tier 3 sub-PR #1 hand-rolled raw-URLSession implementation (see git history —
//  that version persisted the session in UserDefaults and refreshed/parsed the JWT by hand)
//  with the supabase-swift SDK's `AuthClient` (Auth product, linked in Phase 0 — commit
//  `5e33c141`). The `AuthClient` instance itself is built in `SupabaseClients.swift` and
//  injected here — see that file's header for the Keychain-backed storage wiring.
//
//  ── Session storage ──────────────────────────────────────────────────────────────────────
//  Keychain-backed via the SDK's `KeychainLocalStorage` (the SDK's own platform default on
//  Apple platforms — `AuthClient.Configuration.defaultLocalStorage`), replacing the prior
//  hand-rolled UserDefaults persistence (the old `Keys.accessToken` / `refreshToken` / `userId`
//  / `expiresAt` constants are gone — nothing in this file writes to UserDefaults anymore).
//  This closes the QA nit on record since Tier 3 sub-PR #1's original header comment ("A
//  fast-follow PR should migrate to Keychain when the SDK is added").
//
//  ── Session-migration decision (spec §14's flagged open item) ───────────────────────────────
//  NO migration shim from the old UserDefaults keys to the new Keychain store, and this is a
//  deliberate decision, not an oversight:
//    - Kevin has confirmed he is currently the ONLY TestFlight user — there are no external
//      testers. The only session affected by this swap is his own, on his own device.
//    - The worst case on upgrade is a fresh anonymous identity, which costs him the ability to
//      delete/manage authorship on a handful of his own pre-upgrade test pins — not any real
//      user's data, not any reputation that matters outside his own testing.
//    - A migration shim that reads legacy UserDefaults keys and writes them into Keychain is
//      exactly the kind of code that can resurrect a session a user deliberately signed out of
//      (WePark has no user-visible sign-out today, but the shim would still need to reason
//      about that case correctly to be safe), for zero real benefit at today's user count.
//    - If an external TestFlight group is added later (on the backlog), that group installs
//      straight onto this SDK-backed build from their first launch — this never becomes a
//      retroactive problem for them.
//  The old UserDefaults keys are simply never read by this file again; any pre-existing values
//  are inert leftover bytes, not actively cleaned up (not worth the code at today's user count).
//
//  ── Auto-resign on `.signedOut` (AC-A3) ──────────────────────────────────────────────────────
//  The SDK's AuthClient publishes an auth-state-change event stream (`authStateChanges`)
//  including a `.signedOut` case. This fires both for an explicit `signOut()` call (WePark
//  exposes no such call today) AND for the SDK's own detection of a server-invalidated session
//  — see supabase-swift's `APIClient.handleError`, which emits `.signedOut` whenever a session
//  refresh fails with one of `session_not_found` / `session_expired` / `refresh_token_not_found`
//  / `refresh_token_already_used`. WePark's identity model is "silent anonymous session, always
//  logged in, never a user-visible logged-out state" (docs/tier3-auth-and-reactions-spec.md
//  §3.8) — so this service re-triggers an anonymous sign-in automatically on `.signedOut`,
//  closing a real (if narrow) gap: previously, a revoked session went unnoticed until the next
//  write's `validAccessToken()` call failed.
//
//  ── Public API: byte-identical (AC-A1) ───────────────────────────────────────────────────────
//  `currentUserId: UUID?`, `isAuthenticated: Bool`, `validAccessToken() async -> String?` keep
//  their exact pre-SDK signatures. Zero changes required in CommunityPinService's write methods.
//
//  ── Invariants (unchanged) ──────────────────────────────────────────────────────────────────
//   - @MainActor @Observable — mutations visible to SwiftUI without extra dispatch.
//   - No Calendar.current — session expiry arithmetic is handled entirely inside the SDK's
//     Session.isExpired / SessionManager, which likewise use Date()-based arithmetic, not
//     Calendar.
//   - SUPABASE_URL and SUPABASE_ANON_KEY read from Info.plist (bridged from Config.xcconfig),
//     via SupabaseClients — never hardcoded here.
//   - Single instance created in WeParkApp.swift and injected into ContentView / services.
//
//  ── COMPILE-UNVERIFIED ──────────────────────────────────────────────────────────────────────
//  Written on a Linux VPS with no Xcode/Swift toolchain — every API used here (AuthClient,
//  AuthClient.Configuration, signInAnonymously, .session, .authStateChanges, AuthChangeEvent,
//  Session) was verified against the pinned supabase-swift revision's actual source
//  (a71f55a8d522aa38e2cecd314b64c6b24d518f8c == v2.55.0, per Package.resolved) fetched from
//  GitHub, NOT from memory of other Supabase SDKs. See the PR description for the specific
//  source files read and the remaining points of uncertainty. Requires a Mac `xcodebuild build`
//  + `test` pass before merge.
//

import Foundation
import Auth

// MARK: - SupabaseAuthService

/// Anonymous identity layer for WePark, backed by the supabase-swift SDK's `AuthClient`.
///
/// On first launch (no Keychain-persisted session), calls the SDK's `signInAnonymously()`
/// without any user-visible prompt. The anonymous identity satisfies the `auth.uid() IS NOT
/// NULL` requirement of the `pins_insert_crowd` and `votes_insert_own` RLS policies.
///
/// Thread safety: `@MainActor @Observable`. All published-state mutations happen on the main
/// actor. The wrapped `AuthClient` is itself a Swift `actor`; every call into it is `await`ed.
@MainActor
@Observable
final class SupabaseAuthService {

    // MARK: - Public state

    /// The Supabase user UUID corresponding to `auth.uid()` in the JWT.
    /// Nil before a session is established or if authentication is unavailable.
    private(set) var currentUserId: UUID? = nil

    /// True once a valid session has been established.
    private(set) var isAuthenticated: Bool = false

    // MARK: - Internal state

    /// The current session's access token, kept for introspection/tests. No external caller
    /// reads this directly today — CommunityPinService's write path calls `validAccessToken()`
    /// instead, which always returns an up-to-date token (refreshing first if needed).
    private(set) var accessToken: String? = nil

    // MARK: - Dependencies

    /// The SDK's Auth client (actor). Constructed once in `WeParkApp.swift` via
    /// `SupabaseClients` and injected here — see that file's header for the Keychain-backed
    /// storage wiring.
    private let authClient: AuthClient

    /// Holds the long-lived Task observing `authClient.authStateChanges` for the service's
    /// lifetime (which is the app's lifetime — `SupabaseAuthService` is a WeParkApp-level
    /// singleton, see that file). Not explicitly cancelled on deinit: this service never
    /// deinitializes in practice, and a bare `Task` referencing only this actor pair carries no
    /// meaningful leak risk for an app-lifetime object.
    private var authStateTask: Task<Void, Never>?

    // MARK: - Init

    /// Designated initializer. Takes an already-configured `AuthClient` (Keychain-backed by
    /// default — see `SupabaseClients.swift`).
    init(authClient: AuthClient) {
        self.authClient = authClient
        observeAuthStateChanges()
    }

    /// Convenience initializer. Builds its own `SupabaseClients` from `Bundle.main`'s
    /// Info.plist keys (Config.xcconfig → Info.plist bridge) — mirrors the pre-SDK
    /// convenience init's behavior and call sites.
    convenience init() {
        self.init(authClient: SupabaseClients().authClient)
    }

    // MARK: - Public API

    /// Ensures a valid session is present. Called from WeParkApp on launch.
    ///
    /// Flow:
    ///  1. Ask the SDK for the current session. `AuthClient.session` reads the
    ///     Keychain-persisted session and transparently refreshes it if expired — with zero
    ///     network call at all if the persisted session is still valid.
    ///  2. If no session exists at all (true first launch, or the persisted one was cleared),
    ///     the SDK throws `AuthError.sessionMissing` — caught here and treated as "create a new
    ///     anonymous session."
    ///  3. Fails silently — app stays in read-only mode if auth is unavailable (AC-A4: no UI
    ///     shown on failure).
    func ensureSession() async {
        do {
            let session = try await authClient.session
            applySession(session)
        } catch {
            await signInAnonymously()
        }
    }

    // MARK: - Token access (called before writes)

    /// Proactively ensures the current token is valid before a write operation.
    ///
    /// - Returns: The current access token, or nil if authentication is unavailable.
    func validAccessToken() async -> String? {
        if let session = try? await authClient.session {
            accessToken = session.accessToken
            return session.accessToken
        }
        // No session at all, or a refresh failed — establish a fresh one (deduped below).
        await signInAnonymously()
        return accessToken
    }

    // MARK: - Anonymous sign-in

    /// Coalesces concurrent `signInAnonymously()` callers onto a single in-flight sign-in.
    ///
    /// Without this, two real call sites can legitimately race for the *same* underlying
    /// condition: `ensureSession()`'s "no session at all" fallback (below) and the
    /// `.signedOut` event handler's auto-resign (AC-A3) both observe the identical
    /// `AuthError.sessionMissing` when a persisted-but-expired session's refresh fails with a
    /// session-cleanup error code — the SDK doesn't distinguish "never had a session" from
    /// "had one, it just died server-side" at the error-type level, so both code paths
    /// legitimately fire. Without coalescing, that would create two distinct anonymous users
    /// instead of one (Supabase's anonymous signup has no idempotency key). Mirrors the SDK's
    /// own `inFlightRefreshTask` dedup pattern for `refreshSession` (SessionManager.swift).
    private var pendingSignIn: Task<Void, Never>?

    private func signInAnonymously() async {
        if let pendingSignIn {
            await pendingSignIn.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.authClient.signInAnonymously()
                self.applySession(session)
            } catch {
                // Fail silently (AC-A4: no UI shown on failure). App stays in read-only mode;
                // the next validAccessToken() call (or the next .signedOut/.initialSession
                // event) retries.
            }
        }
        pendingSignIn = task
        await task.value
        pendingSignIn = nil
    }

    // MARK: - Auth state observation (AC-A3: auto-resign on .signedOut)

    /// Subscribes to the SDK's auth-state-change stream for the service's entire lifetime.
    /// `authStateChanges` is `nonisolated` on the actor, so it can be read directly here; the
    /// `Task` itself inherits this initializer's MainActor isolation (this class is
    /// `@MainActor`), so every branch of `handleAuthStateChange` below runs on the main actor
    /// and can mutate `currentUserId` / `isAuthenticated` / `accessToken` directly.
    private func observeAuthStateChanges() {
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.authClient.authStateChanges {
                await self.handleAuthStateChange(event: event, session: session)
            }
        }
    }

    /// Exhaustive over `AuthChangeEvent` — a future SDK case addition should fail to compile
    /// here rather than silently falling through a `default:` branch.
    private func handleAuthStateChange(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
            if let session {
                applySession(session)
            }
            // A nil session on .initialSession just means "nothing persisted yet" — the
            // explicit ensureSession() call from WeParkApp's `.task` is what bootstraps the
            // very first anonymous session; this event stream doesn't need to duplicate that
            // for a nil-session .initialSession.

        case .signedOut:
            // WePark has no user-visible signed-out state (tier3-auth-and-reactions-spec.md
            // §3.8) — silently re-establish a fresh anonymous session. Covers both an explicit
            // signOut() call (not exposed to any caller today) and the SDK's own detection of a
            // server-invalidated session (APIClient.handleError's sessionCleanupErrorCodes).
            clearSession()
            await signInAnonymously()

        case .userDeleted:
            // The underlying auth.users row is gone. Clear local state, but do NOT auto-resign
            // here — account deletion is a meaningfully different case from a token hiccup, and
            // nothing in WePark triggers it today, so there's nothing to silently paper over
            // yet. Revisit if/when this ever becomes reachable in practice.
            clearSession()

        case .passwordRecovery, .mfaChallengeVerified:
            // Not applicable to WePark's anonymous-only identity model.
            break
        }
    }

    private func applySession(_ session: Session) {
        currentUserId = session.user.id
        accessToken = session.accessToken
        isAuthenticated = true
    }

    private func clearSession() {
        currentUserId = nil
        accessToken = nil
        isAuthenticated = false
    }
}

// MARK: - Test seam (DEBUG only)

#if DEBUG

/// In-memory session-storage double for unit tests.
///
/// WeParkTests reaches `SupabaseAuthService` only through `@testable import WePark` and
/// intentionally does NOT link the Auth SDK product itself — `project.pbxproj`'s
/// `WeParkTests` target has an empty `packageProductDependencies` (matching
/// docs/supabase-swift-realtime-spec.md §4.1 step 6's "Target: WePark only" scope cut). This
/// type is plain Foundation, no Auth import, so tests never need to name an Auth-module type
/// to pre-seed or clear a fake session store.
final class InMemoryAuthStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func retrieve(key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func remove(key: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

/// Adapts `InMemoryAuthStorage` to the SDK's `AuthLocalStorage` protocol. Kept private and in
/// this file (which already imports Auth) so `InMemoryAuthStorage` itself never has to.
private struct InMemoryAuthLocalStorageAdapter: AuthLocalStorage {
    let backing: InMemoryAuthStorage
    func store(key: String, value: Data) throws { backing.store(key: key, value: value) }
    func retrieve(key: String) throws -> Data? { backing.retrieve(key: key) }
    func remove(key: String) throws { backing.remove(key: key) }
}

extension SupabaseAuthService {
    /// Test-only initializer. Builds a real `AuthClient` (same SDK code path as production)
    /// wired to a mocked network + in-memory storage — no live Keychain access, no live
    /// network. Every parameter is a plain Foundation type so callers in `WeParkTests` never
    /// need `import Auth`.
    convenience init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        testStorage: InMemoryAuthStorage,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        let clients = SupabaseClients(
            supabaseURL: supabaseURL,
            supabaseAnonKey: supabaseAnonKey,
            localStorage: InMemoryAuthLocalStorageAdapter(backing: testStorage),
            fetch: fetch
        )
        self.init(authClient: clients.authClient)
    }
}

#endif
