//
//  SupabaseAuthServiceTests.swift
//  WeParkTests
//
//  supabase-swift adoption — Stream A (Auth/Keychain).
//  Spec: docs/supabase-swift-realtime-spec.md §9, §11, AC-A1 through AC-A5.
//
//  Replaces the pre-SDK `SupabaseAuthServiceTests` class that used to live in
//  Tier3AuthReactionsTests.swift (URLProtocol-mocked against raw URLSession + UserDefaults).
//  That class is now against the SDK-backed internals: real `AuthClient` (the actor
//  supabase-swift ships), wired to a mocked network via the SDK's own `fetch` customization
//  point (`AuthClient.Configuration.fetch`) and to an in-memory storage double instead of
//  Keychain (`SupabaseAuthService`'s `#if DEBUG` test-seam initializer).
//
//  Why this file constructs everything through Foundation-only types (no `import Auth`):
//  `WeParkTests` intentionally does not link the Auth SDK product — `project.pbxproj`'s
//  `WeParkTests` target has an empty `packageProductDependencies` (only the `WePark` app
//  target links `Auth` + `Realtime`, matching
//  docs/supabase-swift-realtime-spec.md §4.1 step 6: "Target: WePark only ... tests reach the
//  SDK-backed types through @testable import WePark, no direct product link needed on the test
//  target"). `SupabaseAuthService`'s `#if DEBUG` test-seam initializer
//  (`init(supabaseURL:supabaseAnonKey:testStorage:fetch:)`) exists specifically so this file
//  never needs to name an `Auth`-module type — every parameter here is `Foundation`/WePark-local.
//
//  Test inventory (7 tests):
//    1. testEnsureSession_noPersistedSession_signsInAnonymously        (AC-A1)
//    2. testEnsureSession_validPersistedSession_doesNotHitNetwork      (AC-A2)
//    3. testEnsureSession_expiredToken_callsRefresh                    (AC-A2 support — see below)
//    4. testEnsureSession_httpFailure_staysUnauthenticated             (AC-A4, fail-silently)
//    5. testValidAccessToken_returnsCurrentSessionToken                (AC-A1 support)
//    6. testAutoResignOnSignedOut_reestablishesAnonymousSession        (AC-A3)
//    7. testKeychainNotUserDefaults_noLegacyKeysWritten                (AC-A2, negative half)
//
//  AC-A4's "no Calendar.current usage introduced" is verified by code review of the diff
//  (SupabaseAuthService.swift / SupabaseClients.swift contain zero Calendar references — all
//  session-expiry arithmetic lives inside the SDK's Session.isExpired / SessionManager, which
//  are Date()-based, not Calendar-based), not by a test in this file.
//
//  Baseline before this file existed: the 5 tests removed from Tier3AuthReactionsTests.swift's
//  old SupabaseAuthServiceTests class. This file originally replaced 4 of those 5 in intent and
//  added AC-A3 (auto-resign on .signedOut, new — the old raw-URLSession implementation had no
//  auth-state stream to test) and an explicit AC-A2 negative-half check — but silently DROPPED
//  the 5th (`testEnsureSession_expiredToken_callsRefresh`, the "session exists, is expired,
//  refresh succeeds" path — the single most common non-first-launch session state in
//  production), a real coverage loss flagged by QA
//  (docs/qa/supabase-auth-keychain-stream-a-qa.md, Finding #1: net test count went +1, which
//  masked the loss unless you diffed test *names*, not just counts). Test #3 above
//  (`testEnsureSession_expiredToken_callsRefresh`) restores equivalent coverage — added during
//  supabase-swift Stream B (Realtime) since that pass is in the same SDK context, per the QA
//  report's own recommendation to fold the fix in there rather than opening a separate PR.
//
//  COMPILE-UNVERIFIED — see SupabaseAuthService.swift's header for the full disclosure. The
//  Session/User JSON shape below was verified against supabase-swift's actual Decodable
//  requirements at the pinned revision (a71f55a8d522aa38e2cecd314b64c6b24d518f8c == 2.55.0),
//  not guessed from memory.
//

import XCTest
@testable import WePark

// MARK: - Shared fixtures

private let kURL = URL(string: "https://auth-seam-test.supabase.co")!
private let kAnonKey = "test-anon-key-seam"
private let kUser1 = UUID(uuidString: "B0000001-0000-0000-0000-000000000001")!
private let kUser2 = UUID(uuidString: "B0000002-0000-0000-0000-000000000002")!

/// A valid Supabase Auth SDK `Session` JSON fixture. See this file's header for why the shape
/// matters — it must satisfy supabase-swift's actual `Decodable` requirements, not a
/// hand-rolled approximation. `expiresAt` (not `expiresIn`) is what `Session.isExpired` checks.
private func sessionJSON(userId: UUID, expiresInSeconds: TimeInterval = 3600) -> Data {
    let expiresAt = Date().addingTimeInterval(expiresInSeconds).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.test.token.\(userId.uuidString)",
      "refresh_token": "refresh-test-token",
      "token_type": "bearer",
      "expires_in": \(expiresInSeconds),
      "expires_at": \(expiresAt),
      "user": {
        "id": "\(userId.uuidString)",
        "aud": "authenticated",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "is_anonymous": true
      }
    }
    """.data(using: .utf8)!
}

/// A Supabase Auth SDK error-response JSON fixture carrying a specific `error_code`. Used to
/// trigger a REAL `.signedOut` event via the SDK's own `APIClient.handleError` session-cleanup
/// path (session_not_found / session_expired / refresh_token_not_found /
/// refresh_token_already_used all trigger it) — this exercises the actual SDK behavior rather
/// than a hand-invoked private method.
///
/// Field name is `error_code` (not `code`) deliberately: `APIClient.handleError` only reads
/// `_RawAPIErrorResponse.code` when the response carries an `X-Supabase-Api-Version` header at
/// or after 2024-01-01 (this fixture doesn't set one); otherwise it falls back to
/// `_RawAPIErrorResponse.errorCode`, which decodes from the `error_code` JSON key. This exact
/// shape — `error_code` + `message`, no API-version header, 403 status — mirrors
/// supabase-swift's own test for this scenario
/// (Tests/AuthTests/AuthClientTests.swift, `removeSessionAndSignoutIfRefreshTokenNotFoundErrorReturned`,
/// read at the pinned revision to confirm this fixture actually triggers `.signedOut`).
private func errorJSON(code: String) -> Data {
    """
    { "error_code": "\(code)", "message": "test error" }
    """.data(using: .utf8)!
}

/// Thread-safe mock URLProtocol, scoped to this file only (distinct static storage from
/// Tier3AuthReactionsTests.swift's AuthMockURLProtocol / WriteMockURLProtocol — avoids
/// shared-state races when tests run in parallel across files).
final class SeamMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = SeamMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func seamMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SeamMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Builds an authenticated fetch closure — every request succeeds with `userId`'s session.
private func alwaysSucceedFetch(userId: UUID) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    let session = seamMockSession()
    SeamMockURLProtocol.requestHandler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         sessionJSON(userId: userId))
    }
    return { try await session.data(for: $0) }
}

// MARK: - SupabaseAuthServiceTests

@MainActor
final class SupabaseAuthServiceTests: XCTestCase {

    // MARK: AC-A1: first launch → signs in anonymously

    /// AC-A1: ensureSession() with no persisted session calls the SDK's signInAnonymously()
    /// (via POST to /auth/v1/signup) and sets currentUserId.
    func testEnsureSession_noPersistedSession_signsInAnonymously() async {
        let session = seamMockSession()
        var capturedPaths: [String] = []
        SeamMockURLProtocol.requestHandler = { request in
            capturedPaths.append(request.url?.path ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    sessionJSON(userId: kUser1))
        }

        let service = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await session.data(for: $0) }
        )

        await service.ensureSession()

        XCTAssertEqual(service.currentUserId, kUser1,
            "AC-A1: currentUserId must be set to the anonymous user UUID after ensureSession()")
        XCTAssertTrue(service.isAuthenticated,
            "AC-A1: isAuthenticated must be true after successful ensureSession()")
        XCTAssertNotNil(service.accessToken,
            "AC-A1: accessToken must be non-nil after successful ensureSession()")
        XCTAssertTrue(capturedPaths.contains { $0.contains("/signup") },
            "AC-A1: a fresh anonymous session must be created via the signup endpoint, got paths: \(capturedPaths)")
    }

    // MARK: AC-A2: valid persisted (Keychain-shaped) session → no network call at all

    /// AC-A2: ensureSession() with a valid session already in storage does not touch the
    /// network at all — the SDK's `AuthClient.session` reads local storage first and only
    /// calls out to the network if the stored session is expired.
    ///
    /// Deliberately does NOT hand-seed `InMemoryAuthStorage` with a hand-written JSON blob:
    /// the SDK's storage layer (`SessionStorage.live`, Sources/Auth/Internal/SessionStorage.swift)
    /// round-trips `Session` through a *plain* `JSONDecoder()`/`JSONEncoder()` — no
    /// `.convertFromSnakeCase`, no custom ISO8601 date strategy — which is a DIFFERENT decoder
    /// than the one used for network responses (`AuthClient.Configuration.jsonDecoder`, snake_case
    /// + custom date parsing). Hand-crafting a byte-correct fixture for the storage shape would be
    /// guessing at an internal implementation detail this PR can't compile-verify. Instead: seed
    /// storage via a REAL signup round-trip (first `SupabaseAuthService`, using the *network*
    /// fixture shape, which the SDK itself then encodes into storage using its own logic), then
    /// construct a SECOND service instance sharing the same storage — simulating an app relaunch
    /// — and assert it makes no network call.
    func testEnsureSession_validPersistedSession_doesNotHitNetwork() async {
        let storage = InMemoryAuthStorage()
        let seedSession = seamMockSession()
        SeamMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             sessionJSON(userId: kUser1))
        }
        let firstLaunch = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: storage,
            fetch: { try await seedSession.data(for: $0) }
        )
        await firstLaunch.ensureSession()
        XCTAssertEqual(firstLaunch.currentUserId, kUser1, "sanity: seed session should have applied")

        // "Relaunch": a fresh service instance reading the same (now-persisted) storage.
        var networkCallCount = 0
        let session = seamMockSession()
        SeamMockURLProtocol.requestHandler = { request in
            networkCallCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    sessionJSON(userId: kUser2))
        }
        let secondLaunch = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: storage,
            fetch: { try await session.data(for: $0) }
        )

        await secondLaunch.ensureSession()

        XCTAssertEqual(networkCallCount, 0,
            "AC-A2: must not touch the network when a valid session is already in storage")
        XCTAssertEqual(secondLaunch.currentUserId, kUser1,
            "AC-A2: must restore the persisted userId, not create a new anonymous one")
    }

    // MARK: Restored coverage (QA Finding #1): session exists, is expired, refresh succeeds

    /// The "session exists, is expired, refresh succeeds" path — the single most common
    /// non-first-launch session state in production (every time the app is reopened after the
    /// ~1hr access-token lifetime has passed, but the refresh token is still valid). This is
    /// DISTINCT from `testAutoResignOnSignedOut_reestablishesAnonymousSession`, which exercises
    /// the refresh-FAILS case: here the refresh endpoint succeeds and the EXISTING session must
    /// be restored, not replaced with a new anonymous identity.
    ///
    /// Same "seed via a real signup round-trip, then construct a second instance sharing that
    /// storage to simulate a relaunch" technique as
    /// `testEnsureSession_validPersistedSession_doesNotHitNetwork` above (see that test's doc
    /// comment for why this file never hand-crafts the storage JSON shape directly) — the seed
    /// session's `expiresInSeconds` is set to 10s, inside the SDK's own `defaultExpiryMargin`
    /// (30s, `Internal/Constants.swift` — confirmed via `Session.isExpired`,
    /// `Sources/Auth/Types.swift:143-146`: "expired or will expire within the next 30 seconds"),
    /// so `AuthClient.session`'s `SessionManager.session()` treats it as needing a refresh on
    /// the very next `ensureSession()` call, without waiting for outright wall-clock expiry.
    func testEnsureSession_expiredToken_callsRefresh() async {
        let storage = InMemoryAuthStorage()

        let seedSession = seamMockSession()
        SeamMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             sessionJSON(userId: kUser1, expiresInSeconds: 10))
        }
        let seeder = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: storage,
            fetch: { try await seedSession.data(for: $0) }
        )
        await seeder.ensureSession()
        XCTAssertEqual(seeder.currentUserId, kUser1, "sanity: the near-expiry seed session should have applied once")

        // "Relaunch": a fresh service instance reading the same (now within-refresh-margin)
        // storage. The refresh endpoint SUCCEEDS this time (the distinguishing factor vs.
        // testAutoResignOnSignedOut_reestablishesAnonymousSession's refresh-fails fixture).
        var capturedPaths: [String] = []
        let session = seamMockSession()
        SeamMockURLProtocol.requestHandler = { request in
            capturedPaths.append(request.url?.path ?? "")
            // Refresh succeeds: same user, fresh token/expiry.
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    sessionJSON(userId: kUser1, expiresInSeconds: 3600))
        }
        let service = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: storage,
            fetch: { try await session.data(for: $0) }
        )

        // Unlike the .signedOut auto-resign path, a successful refresh is applied directly
        // within ensureSession()'s own call stack (authClient.session returns the refreshed
        // Session synchronously to its caller) — no polling needed here.
        await service.ensureSession()

        XCTAssertTrue(capturedPaths.contains { $0.contains("/token") },
            "A near-expiry session must trigger a refresh call (POST /auth/v1/token?grant_type=refresh_token), got paths: \(capturedPaths)")
        XCTAssertFalse(capturedPaths.contains { $0.contains("/signup") },
            "A successful refresh must restore the EXISTING session, not fall back to a new anonymous signup")
        XCTAssertEqual(service.currentUserId, kUser1,
            "A successful refresh must restore the same userId, not create a new anonymous identity")
        XCTAssertTrue(service.isAuthenticated,
            "isAuthenticated must be true after a successful refresh")
    }

    // MARK: AC-A4: HTTP failure on sign-in → fails silently, stays unauthenticated

    /// AC-A4: if the sign-in endpoint returns a non-2xx, currentUserId stays nil and no UI is
    /// shown — the app stays in read-only mode.
    func testEnsureSession_httpFailure_staysUnauthenticated() async {
        let session = seamMockSession()
        SeamMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kURL, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let service = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await session.data(for: $0) }
        )

        await service.ensureSession()

        XCTAssertNil(service.currentUserId,
            "AC-A4: currentUserId must remain nil when sign-in returns a server error")
        XCTAssertFalse(service.isAuthenticated,
            "AC-A4: isAuthenticated must remain false when sign-in returns a server error")
    }

    // MARK: validAccessToken() returns the live session's token

    func testValidAccessToken_returnsCurrentSessionToken() async {
        let service = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: alwaysSucceedFetch(userId: kUser1)
        )

        let token = await service.validAccessToken()

        XCTAssertNotNil(token, "validAccessToken() must return a token once a session is established")
        XCTAssertEqual(service.currentUserId, kUser1,
            "validAccessToken() must establish a session as a side effect if none existed yet")
    }

    // MARK: AC-A3: auto-resign on .signedOut

    /// AC-A3: a `.signedOut` event from the SDK's auth-state stream triggers an automatic
    /// re-sign-in, with no caller action. Triggered here via a REAL SDK code path — not a
    /// hand-invoked private method: a refresh call that fails with a session-cleanup error
    /// code (`refresh_token_not_found`) makes supabase-swift's own `APIClient.handleError`
    /// emit `.signedOut` internally (verified against the pinned SDK revision's source).
    func testAutoResignOnSignedOut_reestablishesAnonymousSession() async throws {
        let storage = InMemoryAuthStorage()

        // Seed storage with an EXPIRED session via a real signup round-trip — see
        // testEnsureSession_validPersistedSession_doesNotHitNetwork's doc comment for why this
        // file never hand-crafts the storage JSON shape directly (different decoder than the
        // network-response shape).
        let seedSession = seamMockSession()
        SeamMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             sessionJSON(userId: kUser1, expiresInSeconds: -3600))
        }
        let seeder = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: storage,
            fetch: { try await seedSession.data(for: $0) }
        )
        await seeder.ensureSession()
        XCTAssertEqual(seeder.currentUserId, kUser1, "sanity: the expired seed session should have applied once")

        // "Relaunch": a fresh service instance reading the same (now-expired) storage.
        let session = seamMockSession()
        SeamMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/token") {
                // The refresh attempt: server says the refresh token is gone -> the SDK emits
                // .signedOut internally and this service's observer should auto-resign.
                return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                        errorJSON(code: "refresh_token_not_found"))
            }
            // Any subsequent signup call (the auto-resign) succeeds with a fresh user.
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    sessionJSON(userId: kUser2))
        }

        let service = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: storage,
            fetch: { try await session.data(for: $0) }
        )

        // ensureSession() triggers the expired-session refresh attempt, which fails with
        // refresh_token_not_found, which the SDK turns into a real .signedOut emission that
        // this service's authStateChanges observer reacts to by auto-resigning.
        await service.ensureSession()

        // Auto-resign is asynchronous relative to the .signedOut emission (it happens on the
        // authStateChanges stream, a separate Task from ensureSession()'s own call stack) — poll
        // briefly for the new session to land rather than asserting immediately.
        var attempts = 0
        while service.currentUserId != kUser2, attempts < 20 {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            attempts += 1
        }

        XCTAssertEqual(service.currentUserId, kUser2,
            "AC-A3: a .signedOut event must trigger an automatic re-sign-in with no caller action")
        XCTAssertTrue(service.isAuthenticated,
            "AC-A3: isAuthenticated must be true again after the auto-resign completes")
    }

    // MARK: AC-A2 (negative half): no legacy UserDefaults keys are ever written

    /// AC-A2: the pre-SDK implementation's UserDefaults keys must never be written by the
    /// SDK-backed implementation — session persistence is entirely Keychain-backed in
    /// production (see SupabaseClients.swift: `localStorage` defaults to
    /// `AuthClient.Configuration.defaultLocalStorage`, which resolves to `KeychainLocalStorage`
    /// on Apple platforms per the SDK's own source). This test proves the negative half
    /// (nothing lands in UserDefaults); the positive half (Keychain is the actual backend) is
    /// verified by code inspection rather than a live Keychain round-trip in this test target,
    /// to avoid a flaky/entitlement-dependent XCTest run — see PR description.
    func testKeychainNotUserDefaults_noLegacyKeysWritten() async {
        let legacyKeys = [
            "wepark_auth_access_token",
            "wepark_auth_refresh_token",
            "wepark_auth_user_id",
            "wepark_auth_expires_at",
        ]
        for key in legacyKeys { UserDefaults.standard.removeObject(forKey: key) }

        let service = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: alwaysSucceedFetch(userId: kUser1)
        )
        await service.ensureSession()

        XCTAssertTrue(service.isAuthenticated, "sanity check: session should have been established")
        for key in legacyKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key),
                "AC-A2: legacy UserDefaults key '\(key)' must never be written by the SDK-backed implementation")
        }

        for key in legacyKeys { UserDefaults.standard.removeObject(forKey: key) }
    }
}

// MARK: - Account deletion handoff (open item #38; QA PR #144 Y2)
//
//  Real SDK (`AuthClient`) behind the mocked network + in-memory storage seam, like the tests
//  above. The contract under test: after `endSessionAfterAccountDeletion(deletedUserId:)` returns,
//  the app is on exactly ONE new anonymous identity (never zero when the network works, never two),
//  whatever order the SDK's separate `.signedOut` handler task runs in, and the deleted user's
//  token is never served again even when local sign-out fails.
//
//  Cases:
//    1. testEndSession_replacesIdentityBeforeReturning_exactlyOneMint
//    2. testEndSession_logoutFailsWithAnyStatus_stillMintsExactlyOne
//    3. testEndSession_sdkCannotRemoveStoredSession_wipesItDirectly
//    4. testEndSession_removalFailsEverywhere_andMintOffline_neverServesDeletedToken
//    5. testEndSession_withNoStoredSession_mintsExactlyOne
//    6. testEndSession_mintOffline_leavesNoSession_noRetryLoop_thenLazyMintRecovers
//    7. testCurrentSessionSnapshot_tokenAndUserFromOneSession
//    8. testSessionStorageKey_matchesSDKDefault

/// Routes the SDK's Auth endpoints and counts what it saw. Thread-safe (the mock URLProtocol
/// answers on a background queue).
private final class SeamAuthServer: @unchecked Sendable {
    private let lock = NSLock()
    private let signupUsers: [UUID]
    private var attempts = 0
    private var mints = 0
    private var signupStatus = 200
    private var logoutStatus = 200
    private var logouts: [String] = []

    init(signupUsers: [UUID]) {
        self.signupUsers = signupUsers
    }

    func setSignupStatus(_ status: Int) { lock.lock(); signupStatus = status; lock.unlock() }
    func setLogoutStatus(_ status: Int) { lock.lock(); logoutStatus = status; lock.unlock() }

    var signupAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var logoutQueries: [String] { lock.lock(); defer { lock.unlock() }; return logouts }

    func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        lock.lock(); defer { lock.unlock() }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url ?? kURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        if path.hasSuffix("/signup") {
            attempts += 1
            guard signupStatus == 200 else { return (response(signupStatus), Data()) }
            let user = signupUsers[min(mints, signupUsers.count - 1)]
            mints += 1
            return (response(200), sessionJSON(userId: user))
        }
        if path.hasSuffix("/logout") {
            logouts.append(request.url?.query ?? "")
            return (response(logoutStatus), Data())
        }
        return (response(404), Data())
    }
}

@MainActor
private func seamMakeService(server: SeamAuthServer, storage: InMemoryAuthStorage) -> SupabaseAuthService {
    let session = seamMockSession()
    SeamMockURLProtocol.requestHandler = { request in server.handle(request) }
    return SupabaseAuthService(
        supabaseURL: kURL,
        supabaseAnonKey: kAnonKey,
        testStorage: storage,
        fetch: { try await session.data(for: $0) }
    )
}

/// Lets any late `.signedOut` handler task run (it hops to the main actor) before asserting that
/// nothing further happened.
private func seamSettle() async throws {
    for _ in 0..<20 { await Task.yield() }
    try await Task.sleep(nanoseconds: 300_000_000)
}

private func seamStoredText(_ storage: InMemoryAuthStorage) -> String? {
    storage.retrieve(key: SupabaseClients.sessionStorageKey).map { String(decoding: $0, as: UTF8.self) }
}

@MainActor
final class SupabaseAuthServiceAccountDeletionTests: XCTestCase {

    /// Y2 core: no polling, no sleeping between the call returning and the assertions -- the new
    /// identity is ALREADY in place. Then a late `.signedOut` handler must not mint a second user.
    func testEndSession_replacesIdentityBeforeReturning_exactlyOneMint() async throws {
        let server = SeamAuthServer(signupUsers: [kUser1, kUser2])
        let storage = InMemoryAuthStorage()
        let service = seamMakeService(server: server, storage: storage)
        await service.ensureSession()
        XCTAssertEqual(service.currentUserId, kUser1, "sanity: first identity")
        XCTAssertEqual(server.signupAttempts, 1)

        await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)

        XCTAssertEqual(service.currentUserId, kUser2, "the replacement identity must be settled on return")
        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(server.signupAttempts, 2, "exactly one replacement sign-up (1 initial + 1)")
        XCTAssertEqual(server.logoutQueries, ["scope=local"], "local scope only: no other session is touched")

        try await seamSettle()

        XCTAssertEqual(server.signupAttempts, 2, "the late .signedOut handler must not mint a second user")
        XCTAssertEqual(service.currentUserId, kUser2)
        let stored = try XCTUnwrap(seamStoredText(storage))
        XCTAssertTrue(stored.contains(kUser2.uuidString), "the persisted session is the replacement's")
        XCTAssertFalse(stored.contains(kUser1.uuidString), "the deleted user's session is gone from storage")
    }

    /// The server already destroyed the session, so /logout may answer anything.
    func testEndSession_logoutFailsWithAnyStatus_stillMintsExactlyOne() async throws {
        for status in [401, 403, 404, 500] {
            let server = SeamAuthServer(signupUsers: [kUser1, kUser2])
            let service = seamMakeService(server: server, storage: InMemoryAuthStorage())
            await service.ensureSession()
            server.setLogoutStatus(status)

            await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)
            try await seamSettle()

            XCTAssertEqual(service.currentUserId, kUser2, "logout status \(status)")
            XCTAssertEqual(server.signupAttempts, 2, "logout status \(status): exactly one replacement mint")
        }
    }

    /// The SDK's own storage delete fails (it logs and swallows that). Force the mint to fail too,
    /// so the ONLY thing that can empty storage is the direct wipe.
    func testEndSession_sdkCannotRemoveStoredSession_wipesItDirectly() async throws {
        let server = SeamAuthServer(signupUsers: [kUser1, kUser2])
        let storage = InMemoryAuthStorage()
        let service = seamMakeService(server: server, storage: storage)
        await service.ensureSession()
        XCTAssertNotNil(seamStoredText(storage), "sanity: a session is stored")
        server.setSignupStatus(500)
        storage.failNextRemovals(1)

        await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)

        XCTAssertNil(seamStoredText(storage), "the deleted user's session must be wiped even if the SDK could not")
        XCTAssertNil(service.currentUserId)
        XCTAssertNil(service.accessToken)
        XCTAssertFalse(service.isAuthenticated)
    }

    /// Worst case: neither the SDK nor the direct wipe can remove the stored session, and the
    /// network is down. The deleted user's token must STILL never be served; once the network is
    /// back the next request mints the replacement, which overwrites the dead session.
    func testEndSession_removalFailsEverywhere_andMintOffline_neverServesDeletedToken() async throws {
        let server = SeamAuthServer(signupUsers: [kUser1, kUser2])
        let storage = InMemoryAuthStorage()
        let service = seamMakeService(server: server, storage: storage)
        await service.ensureSession()
        server.setSignupStatus(500)
        storage.failNextRemovals(Int.max)

        await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)

        XCTAssertNil(service.currentUserId, "the deleted identity must not stay cached")
        XCTAssertNil(service.accessToken)
        XCTAssertNotNil(seamStoredText(storage), "sanity: the dead session really is still stored")

        let offlineToken = await service.validAccessToken()
        XCTAssertNil(offlineToken, "offline: no token at all beats the deleted user's token")
        let offlineSnapshot = await service.currentSessionSnapshot()
        XCTAssertNil(offlineSnapshot)

        server.setSignupStatus(200)
        let token = await service.validAccessToken()
        XCTAssertNotNil(token)
        XCTAssertTrue(token?.contains(kUser2.uuidString) == true, "the replacement identity's token")
        XCTAssertFalse(token?.contains(kUser1.uuidString) == true)
        XCTAssertEqual(service.currentUserId, kUser2)
    }

    /// SDK `signOut` returns early (no event, no request) when nothing is stored; the handoff must
    /// still end with exactly one identity.
    func testEndSession_withNoStoredSession_mintsExactlyOne() async throws {
        let server = SeamAuthServer(signupUsers: [kUser2])
        let service = seamMakeService(server: server, storage: InMemoryAuthStorage())

        await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)
        try await seamSettle()

        XCTAssertEqual(service.currentUserId, kUser2)
        XCTAssertEqual(server.signupAttempts, 1)
        XCTAssertTrue(server.logoutQueries.isEmpty, "nothing stored => the SDK sends no logout")
    }

    func testEndSession_mintOffline_leavesNoSession_noRetryLoop_thenLazyMintRecovers() async throws {
        let server = SeamAuthServer(signupUsers: [kUser1, kUser2])
        let service = seamMakeService(server: server, storage: InMemoryAuthStorage())
        await service.ensureSession()
        server.setSignupStatus(500)

        await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)
        try await seamSettle()

        XCTAssertNil(service.currentUserId)
        XCTAssertFalse(service.isAuthenticated)
        // A failed mint creates no user, so the two possible callers (this method and the
        // separate .signedOut handler) may each make one attempt: at most 1 initial + 2. The point
        // is that nothing retries on its own.
        let attemptsAfterHandoff = server.signupAttempts
        XCTAssertLessThanOrEqual(attemptsAfterHandoff, 3)
        try await seamSettle()
        XCTAssertEqual(server.signupAttempts, attemptsAfterHandoff, "no background retry loop")

        server.setSignupStatus(200)
        let token = await service.validAccessToken()
        XCTAssertNotNil(token, "the existing lazy path recovers on the next write")
        XCTAssertEqual(service.currentUserId, kUser2)
    }

    /// QA G5: token and user id from ONE session value.
    func testCurrentSessionSnapshot_tokenAndUserFromOneSession() async throws {
        let server = SeamAuthServer(signupUsers: [kUser1, kUser2])
        let service = seamMakeService(server: server, storage: InMemoryAuthStorage())

        let first = await service.currentSessionSnapshot()
        let firstSnapshot = try XCTUnwrap(first)
        XCTAssertEqual(firstSnapshot.userId, kUser1)
        XCTAssertTrue(firstSnapshot.accessToken.contains(kUser1.uuidString), "the JWT belongs to the snapshot's user")

        await service.endSessionAfterAccountDeletion(deletedUserId: kUser1)

        let second = await service.currentSessionSnapshot()
        let secondSnapshot = try XCTUnwrap(second)
        XCTAssertEqual(secondSnapshot.userId, kUser2)
        XCTAssertTrue(secondSnapshot.accessToken.contains(kUser2.uuidString))
    }

    /// `SupabaseClients.sessionStorageKey` (used by the direct wipe) must be the key the SDK
    /// really writes, or the wipe silently does nothing.
    func testSessionStorageKey_matchesSDKDefault() async {
        let storage = InMemoryAuthStorage()
        let service = seamMakeService(server: SeamAuthServer(signupUsers: [kUser1]), storage: storage)

        await service.ensureSession()

        XCTAssertNotNil(
            storage.retrieve(key: SupabaseClients.sessionStorageKey),
            "the SDK must persist the session under SupabaseClients.sessionStorageKey"
        )
    }
}
