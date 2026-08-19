//
//  SupabaseClients.swift
//  WePark
//
//  supabase-swift adoption — Stream A (Auth/Keychain) + Stream B (Realtime).
//  Spec: docs/supabase-swift-realtime-spec.md §3.4, §4, §11.
//
//  App-lifetime holder for the supabase-swift SDK client instances used by WePark. Constructed
//  ONCE in `WeParkApp.swift` and injected into `SupabaseAuthService` (`authClient`) and
//  `CommunityPinService` (`realtimeClient`, via `makeRealtimePinChannel()`) — matches
//  `RealtimeClientV2`'s own doc comment: "Create one client per Supabase project and reuse it
//  across your app."
//
//  Session storage: Keychain-backed by default via `AuthClient.Configuration.defaultLocalStorage`
//  — the SDK's own platform-appropriate default, which resolves to `KeychainLocalStorage()` on
//  Apple platforms (supabase-swift Sources/Auth/Storage/AuthLocalStorage.swift, confirmed by
//  reading the pinned revision's source — see PR description for the exact commit inspected).
//  This replaces the prior hand-rolled UserDefaults persistence entirely. See
//  SupabaseAuthService.swift's header for the no-migration-shim decision (Kevin is the sole
//  TestFlight user; a fresh anonymous session on upgrade is acceptable).
//
//  Stream B (Realtime): `realtimeClient: RealtimeClientV2` is constructed with ONLY the
//  `apikey` header — no `accessToken`/`Authorization` — deliberately mirroring the REST fetch
//  path's own "no Authorization header, anon key only" convention for reads (AC-D21,
//  `CommunityPinService.buildOpenDataRequest`'s doc comment). `pins_select_public` already
//  permits anonymous SELECT on non-`parked_car` pins; Realtime authorizes each subscribed row
//  against the same RLS using the anon key's own embedded `role: anon` claim (Supabase's anon
//  key IS itself a signed JWT), so no per-user JWT plumbing is needed here. If a future write
//  path ever needs Realtime to see the authenticated user's identity, wire
//  `RealtimeClientOptions.accessToken` to `authClient.session.accessToken` at that time — not
//  done now, to keep this PR's read-path behavior byte-consistent with the existing REST read
//  path's own documented invariant.
//
//  `makeRealtimePinChannel()` returns the `RealtimePinSubscribing` PROTOCOL type (declared in
//  `Services/RealtimePinChannel.swift`), not the concrete `SupabasePinRealtimeChannel` class —
//  this is deliberate so `WeParkApp.swift` / `ContentView.swift` never need `import Realtime`
//  themselves just to wire the pin service up (same reasoning `makeAuthService()` applies to
//  keep those files `import Auth`-free).
//

import Foundation
import Auth
import Realtime

/// App-lifetime holder for the supabase-swift SDK client instances used by WePark.
///
/// Constructed once (see `WeParkApp.swift`'s `authService` convenience-init chain) and injected
/// into `SupabaseAuthService`. A value type wrapping a reference-type SDK client — cheap to pass
/// around; `Sendable` because `AuthClient` (a Swift `actor`) is itself `Sendable`.
struct SupabaseClients: Sendable {

    /// The SDK's Auth client. Keychain-backed session storage by default, `apikey` header
    /// attached to every request (matches the prior raw-URLSession implementation's header).
    let authClient: AuthClient

    /// The SDK's Realtime client — one WebSocket connection shared for this Supabase
    /// project's lifetime (Stream B). `apikey` header only — see this file's header comment
    /// for why no `accessToken`/JWT is wired here.
    let realtimeClient: RealtimeClientV2

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
        // NOT changed here: `emitLocalSessionAsInitialSession` (Stream A QA Finding #2,
        // docs/qa/supabase-auth-keychain-stream-a-qa.md) stays at the SDK default (`false`).
        // Evaluated flipping it to `true` while touching this file for Stream B — traced
        // `AuthClient.emitInitialSession`'s actual implementation at the pinned revision
        // (Sources/Auth/AuthClient.swift:1527-1560) and confirmed the "no persisted session"
        // case is identical either way, but the "persisted, EXPIRED session" case genuinely
        // changes shape: `true` emits `.initialSession` with the STALE session first
        // (synchronously), then refreshes in a background Task — vs. today's `false` behavior,
        // which only ever emits `.initialSession` with an already-fresh (or already-cleaned-up)
        // session. `validAccessToken()` itself isn't affected (it always re-checks via
        // `authClient.session`, never trusts the cached `accessToken` property), but this is a
        // real behavioral change to auth-internals timing, not a pure no-op silence-the-warning
        // toggle. QA's own note flagged it as "worth re-examining if it's changed later" — this
        // is exactly that re-examination, and the conclusion is: defer. Out of scope for a
        // Realtime PR to also change Auth event-ordering semantics without a dedicated review.
        // Stream B: one RealtimeClientV2 for the app's lifetime, `apikey` header only — see
        // this file's header comment for why no accessToken/JWT is wired here. `/realtime/v1`
        // matches RealtimeClientV2's own doc-comment example
        // (`https://<project>.supabase.co/realtime/v1`).
        self.realtimeClient = RealtimeClientV2(
            url: supabaseURL.appendingPathComponent("realtime/v1"),
            options: RealtimeClientOptions(headers: ["apikey": supabaseAnonKey])
        )
    }

    // MARK: - Factory methods

    /// Builds a `SupabaseAuthService` wrapping this instance's shared `authClient`. Returns the
    /// concrete type directly (not a protocol) — `SupabaseAuthService`'s public API is already
    /// stable and byte-identical (AC-A1), so no test-seam abstraction is needed at this
    /// boundary. Exists so `WeParkApp.swift` never needs `import Auth` itself just to
    /// construct this.
    func makeAuthService() -> SupabaseAuthService {
        SupabaseAuthService(authClient: authClient)
    }

    /// Builds a `RealtimePinSubscribing`-conforming channel wrapping this instance's shared
    /// `realtimeClient`. Returns the PROTOCOL type (declared in
    /// `Services/RealtimePinChannel.swift`), not the concrete `SupabasePinRealtimeChannel`
    /// class — so `WeParkApp.swift` / `ContentView.swift` never need `import Realtime`
    /// themselves just to wire `CommunityPinService` up.
    func makeRealtimePinChannel() -> RealtimePinSubscribing {
        SupabasePinRealtimeChannel(realtimeClient: realtimeClient)
    }
}
