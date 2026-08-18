//
//  SupabaseClients.swift
//  WePark
//
//  supabase-swift adoption — Stream A (Auth/Keychain).
//  Spec: docs/supabase-swift-realtime-spec.md §3.4, §4, §11 (Stream A scope).
//
//  App-lifetime holder for the supabase-swift SDK client instances used by WePark. This PR
//  (Stream A) wires only `AuthClient` (the `Auth` product, linked in Phase 0 — commit
//  `5e33c141`). Stream B (Realtime wiring, sequenced behind FT-15's CommunityPinService.swift
//  changes landing on main per spec §11) is expected to extend this file with a
//  `realtimeClient: RealtimeClientV2` property, built the same way and injected into
//  CommunityPinService alongside SupabaseAuthService's authClient.
//
//  NOT added here: a `RealtimeClientV2` property/construction. Guessing at Realtime's exact
//  2.55.0 init signature is out of Stream A's scope, and this PR is COMPILE-UNVERIFIED as it
//  stands (no Xcode/simulator in this environment) — better to leave that surface for whoever
//  picks up Stream B to verify against the real SDK docs/compiler at that time, per the
//  "flag uncertainty, don't guess" norm (.claude/agents/ios-engineer.md).
//
//  Session storage: Keychain-backed by default via `AuthClient.Configuration.defaultLocalStorage`
//  — the SDK's own platform-appropriate default, which resolves to `KeychainLocalStorage()` on
//  Apple platforms (supabase-swift Sources/Auth/Storage/AuthLocalStorage.swift, confirmed by
//  reading the pinned revision's source — see PR description for the exact commit inspected).
//  This replaces the prior hand-rolled UserDefaults persistence entirely. See
//  SupabaseAuthService.swift's header for the no-migration-shim decision (Kevin is the sole
//  TestFlight user; a fresh anonymous session on upgrade is acceptable).
//

import Foundation
import Auth

/// App-lifetime holder for the supabase-swift SDK client instances used by WePark.
///
/// Constructed once (see `WeParkApp.swift`'s `authService` convenience-init chain) and injected
/// into `SupabaseAuthService`. A value type wrapping a reference-type SDK client — cheap to pass
/// around; `Sendable` because `AuthClient` (a Swift `actor`) is itself `Sendable`.
struct SupabaseClients: Sendable {

    /// The SDK's Auth client. Keychain-backed session storage by default, `apikey` header
    /// attached to every request (matches the prior raw-URLSession implementation's header).
    let authClient: AuthClient

    // MARK: - Production init

    /// Builds clients from `Bundle.main`'s Info.plist keys (Config.xcconfig → Info.plist
    /// bridge) — the same source `SupabaseAuthService`'s pre-SDK convenience init used. Falls
    /// back to a placeholder URL if unset (fails silently downstream — every Auth call then
    /// fails and `SupabaseAuthService` stays unauthenticated — rather than crashing at launch;
    /// matches the prior implementation's behavior for a missing/misconfigured Config.xcconfig).
    init() {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: anonKey)
    }

    // MARK: - Designated init

    /// - Parameters:
    ///   - supabaseURL: The Supabase project's base URL (e.g. `https://xyz.supabase.co`).
    ///     `/auth/v1` is appended here to form the Auth server URL the SDK expects.
    ///   - supabaseAnonKey: Sent as the `apikey` header on every Auth request.
    ///   - localStorage: Defaults to the SDK's platform-appropriate default (Keychain on Apple
    ///     platforms). Production call sites should not override this. Tests use the
    ///     Foundation-only seam in `SupabaseAuthService`'s `#if DEBUG` test extension instead of
    ///     calling this initializer directly with a custom storage — see that file's header for
    ///     why (WeParkTests does not link the Auth product directly).
    ///   - fetch: Defaults to a plain `URLSession.shared`-backed fetch. Overridable so callers
    ///     can route Auth network traffic through a mocked session.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        localStorage: any AuthLocalStorage = AuthClient.Configuration.defaultLocalStorage,
        fetch: @escaping AuthClient.FetchHandler = { try await URLSession.shared.data(for: $0) }
    ) {
        self.authClient = AuthClient(
            url: supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": supabaseAnonKey],
            localStorage: localStorage,
            fetch: fetch
        )
    }
}
