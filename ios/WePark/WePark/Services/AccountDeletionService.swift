//
//  AccountDeletionService.swift
//  WePark
//
//  Open item #38 — in-app account deletion (Apple App Store guideline 5.1.1(v)).
//  Contract: `supabase/10-account-deletion.sql` (the `delete_my_account()` RPC) and
//  `supabase/12-storage-delete-own.sql` (the owner-scoped Storage DELETE policy), both
//  summarized in `docs/supabase-ceremony-10-11.md`. Dark-shipped behind
//  `AppConstants.accountDeletionEnabled` (this file is inert until a view calls it).
//
//  THE SEQUENCE (files FIRST, account LAST — never delete the account while orphaning files):
//    1. List every object under the caller's prefix in the PRIVATE `pin-evidence` bucket
//       (`POST /storage/v1/object/list/pin-evidence`, paged `limit`/`offset`, recursing into
//       folders — Storage listing is not recursive; entries with `id == null` are folders).
//    1b. CROSS-CHECK the listing (hardening, QA PR #144 Y1): a Storage listing that silently
//       returns `[]` (wrong prefix / case / server quirk) is indistinguishable from "no photos",
//       and the RPC would then orphan real files. The user can SELECT their own `pin_evidence`
//       rows (`pin_evidence_select_own`): for every row `storage_path` MISSING from the listing,
//       probe the object directly (`GET /storage/v1/object/info/authenticated/pin-evidence/<path>`,
//       the JSON-bodied info route that works for private buckets with the user's JWT — a HEAD
//       cannot tell a missing object from a bad JWT) and ABORT if any still exists. A probe that
//       says "not found" is fine (a retry after a first run that removed the files but failed at
//       the RPC: rows remain, objects are gone); an inconclusive probe aborts (fail safe). NOT a
//       naive "rows exist but listing empty => abort" rule: that would deadlock that retry.
//    2. Remove them (`DELETE /storage/v1/object/pin-evidence`, `{"prefixes": [...]}`, <= 100
//       per request). Any non-2xx, or a returned list shorter than the paths sent = FAILURE.
//    3. ONLY if every removal succeeded: `POST /rest/v1/rpc/delete_my_account` (no arguments;
//       any 2xx = success, the body is never decoded). A 401 is treated as success ONLY if
//       `GET /auth/v1/user` confirms the user (or its session) no longer exists — i.e. the
//       account was already deleted by an earlier attempt whose response was lost.
//    4. Then end the local session (`endSessionAfterAccountDeletion(deletedUserId:)`), clear
//       per-user local state (`AccountDeletionLocalState`) and post `.weParkAccountDeleted` so
//       in-memory per-user caches reset.
//    Any failure in 1-3 aborts with a typed error and leaves everything intact; the whole
//    sequence is retryable (a re-list finds only what is left; the RPC is idempotent).
//
//  PATH CASE: the storage policies compare the path's first segment to `auth.uid()::text`,
//  which Postgres renders LOWERCASE. Swift's `UUID.uuidString` is UPPERCASE; an uppercase
//  prefix lists/removes NOTHING, which would look like "no photos" and let step 3 orphan real
//  files. Every prefix here is built by `storageRootPrefix(for:)`, which lowercases; pinned by
//  `AccountDeletionTests.testStorageRootPrefix_isLowercase`. (`PinEvidenceUploader` lowercases
//  its upload path for the same reason — do not regress either.)
//
//  LISTING PREFIX HAS NO TRAILING SLASH — a deliberate, flagged divergence from the SQL header's
//  `"prefix": "<uid>/"` example. The Storage server normalizes a non-empty list prefix to a
//  folder by appending "/" itself; current server code appends only when missing, but a server
//  that appends unconditionally would turn "<uid>/" into "<uid>//", match nothing, and silently
//  return `[]` (the exact "looks like no photos" failure above). Sending the bare "<uid>" is
//  correct under BOTH behaviors. Returned entry names are relative to the listed prefix, so
//  full object paths are rebuilt as "<prefix>/<name>".
//
//  Stack conventions (matches `PinEvidenceUploader`): raw URLSession + JSONSerialization/
//  Codable, no Storage SDK product linked; session/JWT via `SupabaseAuthService` behind the
//  small `AccountSessionProviding` protocol so tests inject a fake and a `URLProtocol` mock.
//  No `print`/`os_log` of paths or filenames anywhere (evidence photos can show real names —
//  `PinEvidenceUploader`'s PII posture). No SwiftUI. No `Calendar.current`.
//
//  [COMPILE-UNVERIFIED] Written on a Linux VPS with no Swift toolchain; first compile at
//  Kevin's Mac or CI.
//

import Foundation

// MARK: - Session seam

/// The slice of `SupabaseAuthService` that the authenticated write paths of this feature need.
/// A protocol so tests can inject a fake session without linking the Auth SDK.
@MainActor
protocol WriteSessionProviding: AnyObject {
    /// A currently valid access token (refreshing / minting an anonymous session if needed),
    /// or nil if authentication is unavailable. Same semantics as
    /// `SupabaseAuthService.validAccessToken()`.
    func validAccessToken() async -> String?
}

/// A JWT and the user id it was issued for, read from ONE session value so they cannot disagree.
nonisolated struct AccountSessionSnapshot: Sendable {
    let accessToken: String
    let userId: UUID
}

/// `WriteSessionProviding` plus what account deletion additionally needs.
@MainActor
protocol AccountSessionProviding: WriteSessionProviding {
    /// A valid access token and the `auth.uid()` it belongs to, from one consistent session
    /// snapshot (refreshing / minting an anonymous session if needed), or nil if authentication
    /// is unavailable. See `SupabaseAuthService.currentSessionSnapshot()`.
    func currentSessionSnapshot() async -> AccountSessionSnapshot?
    /// Ends the local session after a successful server-side deletion and establishes exactly one
    /// replacement anonymous identity (see `SupabaseAuthService.endSessionAfterAccountDeletion`).
    /// Must not throw.
    func endSessionAfterAccountDeletion(deletedUserId: UUID) async
}

extension SupabaseAuthService: AccountSessionProviding {}

// MARK: - Errors

/// Failure of the deletion sequence. Every case means "the account still exists" EXCEPT that a
/// `.accountDeletionFailed` thrown after step 2 means the evidence photos are already gone —
/// harmless and retryable (the account just has no photos now).
enum AccountDeletionError: Error {
    /// No valid session / user id (offline at launch, or sign-in never completed).
    case notSignedIn
    /// Listing or removing the evidence photos failed. The RPC was NOT called.
    case photoCleanupFailed
    /// `delete_my_account()` failed (or the connection dropped). If the connection dropped AFTER
    /// the server committed, the account may actually be gone — the RPC is idempotent, so a
    /// retry is always safe (the copy says so).
    case accountDeletionFailed
}

extension AccountDeletionError: LocalizedError {
    /// Plain, non-technical copy. Never includes a status code, path, or server text.
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "We couldn't confirm your account right now. Check your connection and try again."
        case .photoCleanupFailed:
            return "We couldn't remove your photos. Your account was not deleted \u{2014} please try again."
        case .accountDeletionFailed:
            return "We couldn't confirm your account was deleted. Please check your connection and try again \u{2014} it\u{2019}s safe to retry."
        }
    }
}

// MARK: - AccountDeleting

/// What the UI layer drives. A protocol so the confirmation model's tests don't need a network.
@MainActor
protocol AccountDeleting: AnyObject {
    /// Runs the full sequence. Throws `AccountDeletionError` on any failure; returns normally
    /// only after the server-side deletion succeeded and the local session was ended.
    func deleteAccount() async throws
}

// MARK: - Completion notification

extension Notification.Name {
    /// Posted (main thread) after a successful account deletion, once the local session has been
    /// replaced and `AccountDeletionLocalState` cleared. In-memory per-user caches that live
    /// outside any view (e.g. `RegularsService`) observe it and reset. Views that cache per-user
    /// state key off `SupabaseAuthService.currentUserId` instead (see `CrewFeedProfileState`).
    nonisolated static let weParkAccountDeleted = Notification.Name("wepark.accountDeleted")
}

// MARK: - AccountDeletionLocalState

/// Per-USER (not per-device) local state that must not outlive the account.
///
/// Decision record (the "which local state to clear" question):
///  - CLEARED: the Keychain session (via `endSessionAfterAccountDeletion`), and the
///    Community 2.0 identity-sheet gate (`CommunityIdentityGate.shownKey`) — that gate means
///    "this identity has been offered a handle"; the new anonymous identity has no `profiles`
///    row, so it must be offered one again on its first contribution.
///  - Push-registration bookkeeping needs no persisted clearing: `PushRegistrationService`
///    keeps `lastUploaded` in memory only, and its key now includes the user id, so the new
///    identity re-uploads the (device-level) APNs token on the next foreground/zone change.
///    The server already deleted the old user's `device_push_tokens` rows. We deliberately do
///    NOT call `unregisterForRemoteNotifications()` — the APNs token belongs to the device and
///    the next identity needs it.
///  - KEPT (device-local, not account data, per the SQL contract): the parked-car pin and its
///    iCloud-synced state (`wepark_parked_car`, `wepark_synced_car_state`,
///    `wepark_has_ever_parked`), reminders / reminder offsets / mute toggle, recents, garage
///    savings, onboarding flags, the zones cache, and the push dedupe set
///    (`wepark_community_push_seen_pin_ids` — pin ids this DEVICE has been told about, not
///    personal to the account).
///  - There is no cached profile / vote history / outbox on disk. IN-MEMORY per-user state is
///    reset elsewhere: the crew feed's profile/leaderboard (`CrewFeedProfileState`, keyed to
///    `currentUserId`) and `RegularsService` edges/notices (`.weParkAccountDeleted`).
///    `ZoneMessageService` / `CommunityPinService` hold PUBLIC data (their rows keep the old
///    author name on screen until the next refetch -- a known follow-up, see the PR notes).
enum AccountDeletionLocalState {
    /// UserDefaults keys removed on a successful deletion.
    static var perUserKeys: [String] {
        [CommunityIdentityGate.shownKey]
    }

    static func clear(defaults: UserDefaults = .standard) {
        for key in perUserKeys {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - AccountDeletionService

@MainActor
final class AccountDeletionService: AccountDeleting {

    // MARK: Constants

    /// The private evidence bucket (`supabase/02f-block-scoped-restrictions.sql` §8).
    nonisolated static let bucket = "pin-evidence"
    /// Storage list page size (`limit`); paging continues until a page is shorter than this.
    nonisolated static let listPageSize = 100
    /// Max paths per remove request (the SQL contract's "batches of <= 100 paths").
    nonisolated static let removeBatchSize = 100
    /// Safety bounds so a misbehaving server cannot spin the loops forever.
    nonisolated static let maxListPages = 500
    nonisolated static let maxFolderDepth = 4
    /// `pin_evidence` rows per PostgREST page (its default `max-rows` is 1000) and the page cap.
    nonisolated static let evidenceRowsPageSize = 1000
    nonisolated static let maxEvidenceRowPages = 50

    // MARK: Dependencies

    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let urlSession: URLSession
    private let session: any AccountSessionProviding
    private let clearLocalState: @MainActor () -> Void
    private let notificationCenter: NotificationCenter

    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL.
    ///   - supabaseAnonKey: The anon/public API key (never hardcoded; from Info.plist).
    ///   - urlSession: Injectable for tests (URLProtocol mock). Defaults to `.shared`.
    ///   - session: Provides the JWT, `auth.uid()` and the post-deletion sign-out.
    ///   - clearLocalState: Runs after the local session ended. Injectable for tests.
    ///   - notificationCenter: Where `.weParkAccountDeleted` is posted. Injectable for tests.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared,
        session: any AccountSessionProviding,
        clearLocalState: @escaping @MainActor () -> Void = { AccountDeletionLocalState.clear() },
        notificationCenter: NotificationCenter = .default
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.session = session
        self.clearLocalState = clearLocalState
        self.notificationCenter = notificationCenter
    }

    /// Convenience initializer reading `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Bundle.main`
    /// (Config.xcconfig -> Info.plist bridge) — identical to `PushRegistrationService`'s.
    convenience init(authService: SupabaseAuthService) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, session: authService)
    }

    // MARK: - Pure helpers

    /// The caller's root storage prefix: the user id, LOWERCASED, no trailing slash. See this
    /// file's header for both the case rule and the no-trailing-slash rule.
    nonisolated static func storageRootPrefix(for userId: UUID) -> String {
        userId.uuidString.lowercased()
    }

    /// Splits `paths` into consecutive batches of at most `size` (>= 1).
    nonisolated static func batches(of paths: [String], size: Int) -> [[String]] {
        let step = max(size, 1)
        var result: [[String]] = []
        var start = 0
        while start < paths.count {
            let end = min(start + step, paths.count)
            result.append(Array(paths[start..<end]))
            start = end
        }
        return result
    }

    // MARK: - The sequence

    func deleteAccount() async throws {
        // Token and user id from ONE session snapshot (a racing sign-in between two separate
        // reads could pair user A's id with user B's JWT: the listing would be A's, the RPC B's).
        guard let snapshot = await session.currentSessionSnapshot() else {
            throw AccountDeletionError.notSignedIn
        }
        let jwt = snapshot.accessToken
        let userId = snapshot.userId

        // Steps 1-2: photos. Any failure here aborts BEFORE the RPC.
        do {
            let objectPaths = try await collectObjectPaths(
                prefix: Self.storageRootPrefix(for: userId),
                depth: 0,
                jwt: jwt
            )
            // 1b: an unexpectedly short/empty listing must not let the RPC orphan real photos.
            try await crossCheckListing(listedPaths: objectPaths, userId: userId, jwt: jwt)
            for batch in Self.batches(of: objectPaths, size: Self.removeBatchSize) {
                try await removeObjects(batch, jwt: jwt)
            }
        } catch {
            throw AccountDeletionError.photoCleanupFailed
        }

        // Step 3: the account itself (one transaction server-side; idempotent).
        do {
            try await callDeleteRPC(jwt: jwt)
        } catch {
            throw AccountDeletionError.accountDeletionFailed
        }

        // Step 4: the server can't do these.
        await session.endSessionAfterAccountDeletion(deletedUserId: userId)
        clearLocalState()
        notificationCenter.post(name: .weParkAccountDeleted, object: nil)
    }

    // MARK: - Listing cross-check (step 1b)

    private struct EvidenceRow: Decodable {
        let storagePath: String
        private enum CodingKeys: String, CodingKey { case storagePath = "storage_path" }
    }

    /// For every `pin_evidence.storage_path` the caller owns that the Storage listing did NOT
    /// return, asks Storage directly whether the object still exists. Throws (=> abort before the
    /// RPC) if any does, or if the rows / a probe could not be read conclusively.
    private func crossCheckListing(listedPaths: [String], userId: UUID, jwt: String) async throws {
        let rowPaths = try await fetchEvidenceRowPaths(userId: userId, jwt: jwt)
        let listed = Set(listedPaths)
        var seen = Set<String>()
        for path in rowPaths {
            guard !listed.contains(path), seen.insert(path).inserted else { continue }
            if try await objectExists(path: path, jwt: jwt) {
                throw AccountDeletionError.photoCleanupFailed
            }
        }
    }

    /// `GET /rest/v1/pin_evidence?select=storage_path&uploaded_by=eq.<uid>` (RLS: own rows only),
    /// paged. Photo reports are rate-limited and rare, so this is one small request in practice.
    private func fetchEvidenceRowPaths(userId: UUID, jwt: String) async throws -> [String] {
        var all: [String] = []
        var offset = 0
        var pages = 0
        while true {
            pages += 1
            guard pages <= Self.maxEvidenceRowPages else {
                throw AccountDeletionError.photoCleanupFailed
            }
            guard var components = URLComponents(
                url: supabaseURL.appendingPathComponent("rest/v1/pin_evidence"),
                resolvingAgainstBaseURL: false
            ) else {
                throw AccountDeletionError.photoCleanupFailed
            }
            components.queryItems = [
                URLQueryItem(name: "select", value: "storage_path"),
                URLQueryItem(name: "uploaded_by", value: "eq.\(Self.storageRootPrefix(for: userId))"),
                URLQueryItem(name: "order", value: "id.asc"),
                URLQueryItem(name: "limit", value: String(Self.evidenceRowsPageSize)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            guard let url = components.url else {
                throw AccountDeletionError.photoCleanupFailed
            }
            let request = try makeRequest(url: url, method: "GET", jwt: jwt, jsonBody: nil)
            let (data, response) = try await urlSession.data(for: request)
            guard Self.isSuccess(response),
                  let rows = try? JSONDecoder().decode([EvidenceRow].self, from: data) else {
                throw AccountDeletionError.photoCleanupFailed
            }
            all.append(contentsOf: rows.map { $0.storagePath })
            if rows.count < Self.evidenceRowsPageSize { break }
            offset += rows.count
        }
        return all
    }

    /// True if Storage says the object exists, false if it positively says "no such object";
    /// THROWS for anything else (network error, bad JWT, missing bucket, unknown route, odd body)
    /// so an inconclusive probe aborts rather than being read as "gone".
    ///
    /// `GET /storage/v1/object/info/authenticated/<bucket>/<path>` returns JSON for a hit and a
    /// JSON error body for a miss (Storage reports a missing key as HTTP 400 or 404 depending on
    /// version, with `error: "not_found"` / `code: "NoSuchKey"` in the body) -- which is why this is
    /// a GET and not a HEAD.
    private func objectExists(path: String, jwt: String) async throws -> Bool {
        var url = supabaseURL
            .appendingPathComponent("storage/v1/object/info/authenticated")
            .appendingPathComponent(Self.bucket)
        for segment in path.split(separator: "/") {
            url = url.appendingPathComponent(String(segment))
        }
        let request = try makeRequest(url: url, method: "GET", jwt: jwt, jsonBody: nil)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountDeletionError.photoCleanupFailed
        }
        if (200..<300).contains(http.statusCode) { return true }
        if Self.isObjectNotFound(status: http.statusCode, body: data) { return false }
        throw AccountDeletionError.photoCleanupFailed
    }

    /// The Storage API's "no such object" answer, recognized STRICTLY (so a missing bucket, a bad
    /// JWT or an unknown route is never mistaken for a deleted photo).
    nonisolated static func isObjectNotFound(status: Int, body: Data) -> Bool {
        guard status == 400 || status == 404,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        if (object["code"] as? String) == "NoSuchKey" { return true }
        // The message is what distinguishes a missing OBJECT from a missing bucket/route; the `error`
        // label varies by storage-api version ("not_found" vs "Not Found"), so it is not required.
        let message = (object["message"] as? String)?.lowercased()
        return message == "object not found"
    }

    // MARK: - Storage listing (step 1)

    /// One entry of a Storage list response. Folders ("directories") have `id == null`.
    private struct StorageListEntry: Decodable {
        let name: String
        let id: String?
    }

    private struct RemovedObject: Decodable {
        let name: String?
    }

    /// Lists `prefix` (all pages) and recurses into folders, returning full object paths.
    private func collectObjectPaths(prefix: String, depth: Int, jwt: String) async throws -> [String] {
        let entries = try await listAllPages(prefix: prefix, jwt: jwt)
        var paths: [String] = []
        for entry in entries {
            let fullPath = "\(prefix)/\(entry.name)"
            if entry.id == nil {
                guard depth < Self.maxFolderDepth else {
                    throw AccountDeletionError.photoCleanupFailed
                }
                let nested = try await collectObjectPaths(prefix: fullPath, depth: depth + 1, jwt: jwt)
                paths.append(contentsOf: nested)
            } else {
                paths.append(fullPath)
            }
        }
        return paths
    }

    /// Pages through `POST /storage/v1/object/list/pin-evidence` with `limit` / `offset` until a
    /// page comes back shorter than the page size.
    private func listAllPages(prefix: String, jwt: String) async throws -> [StorageListEntry] {
        var all: [StorageListEntry] = []
        var offset = 0
        var pageCount = 0
        while true {
            pageCount += 1
            guard pageCount <= Self.maxListPages else {
                throw AccountDeletionError.photoCleanupFailed
            }
            let page = try await listPage(prefix: prefix, offset: offset, jwt: jwt)
            all.append(contentsOf: page)
            if page.count < Self.listPageSize { break }
            offset += page.count
        }
        return all
    }

    private func listPage(prefix: String, offset: Int, jwt: String) async throws -> [StorageListEntry] {
        let body: [String: Any] = [
            "prefix": prefix,
            "limit": Self.listPageSize,
            "offset": offset,
        ]
        let url = supabaseURL.appendingPathComponent("storage/v1/object/list/\(Self.bucket)")
        let request = try makeRequest(url: url, method: "POST", jwt: jwt, jsonBody: body)
        let (data, response) = try await urlSession.data(for: request)
        guard Self.isSuccess(response) else {
            throw AccountDeletionError.photoCleanupFailed
        }
        guard let entries = try? JSONDecoder().decode([StorageListEntry].self, from: data) else {
            throw AccountDeletionError.photoCleanupFailed
        }
        return entries
    }

    // MARK: - Storage removal (step 2)

    private func removeObjects(_ paths: [String], jwt: String) async throws {
        guard !paths.isEmpty else { return }
        let body: [String: Any] = ["prefixes": paths]
        let url = supabaseURL.appendingPathComponent("storage/v1/object/\(Self.bucket)")
        let request = try makeRequest(url: url, method: "DELETE", jwt: jwt, jsonBody: body)
        let (data, response) = try await urlSession.data(for: request)
        guard Self.isSuccess(response) else {
            throw AccountDeletionError.photoCleanupFailed
        }
        // The server answers with the list of objects it actually deleted. Fewer than we sent
        // (or an undecodable body) = failure: never proceed to the RPC on a partial removal.
        guard let removed = try? JSONDecoder().decode([RemovedObject].self, from: data),
              removed.count >= paths.count else {
            throw AccountDeletionError.photoCleanupFailed
        }
    }

    // MARK: - RPC (step 3)

    private func callDeleteRPC(jwt: String) async throws {
        let url = supabaseURL.appendingPathComponent("rest/v1/rpc/delete_my_account")
        let empty: [String: Any] = [:]
        let request = try makeRequest(url: url, method: "POST", jwt: jwt, jsonBody: empty)
        let (_, response) = try await urlSession.data(for: request)
        // Any 2xx is success (204 or 200 depending on PostgREST version); the body is void.
        if Self.isSuccess(response) { return }
        // A retry after a lost response: the account is already gone and the old JWT is stale, so
        // the gateway may answer 401. That is SUCCESS -- but only if Auth confirms the user (or
        // its session) no longer exists; a bare 401 is never trusted on its own.
        if (response as? HTTPURLResponse)?.statusCode == 401, await accountIsAlreadyGone(jwt: jwt) {
            return
        }
        throw AccountDeletionError.accountDeletionFailed
    }

    /// `GET /auth/v1/user` with the (stale) JWT: GoTrue answers 403 `user_not_found` (or
    /// `session_not_found`, the sessions cascade with the user) for a deleted account. Anything
    /// else -- 200 (still exists), another error, a network failure -- is "not confirmed".
    private func accountIsAlreadyGone(jwt: String) async -> Bool {
        let url = supabaseURL.appendingPathComponent("auth/v1/user")
        guard let request = try? makeRequest(url: url, method: "GET", jwt: jwt, jsonBody: nil),
              let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 403 || http.statusCode == 404,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error_code"] as? String else {
            return false
        }
        return code == "user_not_found" || code == "session_not_found"
    }

    // MARK: - Request plumbing

    private func makeRequest(
        url: URL,
        method: String,
        jwt: String,
        jsonBody: [String: Any]?
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            guard let body = try? JSONSerialization.data(withJSONObject: jsonBody) else {
                throw AccountDeletionError.photoCleanupFailed
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private nonisolated static func isSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
