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
//    2. Remove them (`DELETE /storage/v1/object/pin-evidence`, `{"prefixes": [...]}`, <= 100
//       per request). Any non-2xx, or a returned list shorter than the paths sent = FAILURE.
//    3. ONLY if every removal succeeded: `POST /rest/v1/rpc/delete_my_account` (no arguments;
//       any 2xx = success, the body is never decoded).
//    4. Then end the local session (`endSessionAfterAccountDeletion`) and clear per-user local
//       state (`AccountDeletionLocalState`).
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

/// `WriteSessionProviding` plus what account deletion additionally needs.
@MainActor
protocol AccountSessionProviding: WriteSessionProviding {
    /// `auth.uid()` of the current session.
    var currentUserId: UUID? { get }
    /// Ends the local session after a successful server-side deletion (see
    /// `SupabaseAuthService.endSessionAfterAccountDeletion()`). Must not throw.
    func endSessionAfterAccountDeletion() async
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
    /// `delete_my_account()` failed (or the connection dropped). Nothing was deleted
    /// server-side (the RPC is one transaction).
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
            return "We couldn't delete your account. Please check your connection and try again."
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
///  - There is no cached profile / vote history / outbox on disk (`RegularsService`,
///    `ZoneMessageService` hold public data in memory only).
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

    // MARK: Dependencies

    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let urlSession: URLSession
    private let session: any AccountSessionProviding
    private let clearLocalState: @MainActor () -> Void

    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL.
    ///   - supabaseAnonKey: The anon/public API key (never hardcoded; from Info.plist).
    ///   - urlSession: Injectable for tests (URLProtocol mock). Defaults to `.shared`.
    ///   - session: Provides the JWT, `auth.uid()` and the post-deletion sign-out.
    ///   - clearLocalState: Runs last, after the local session ended. Injectable for tests.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared,
        session: any AccountSessionProviding,
        clearLocalState: @escaping @MainActor () -> Void = { AccountDeletionLocalState.clear() }
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.session = session
        self.clearLocalState = clearLocalState
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
        // Token first (this may mint an anonymous session), THEN the user id — same order as
        // `PinEvidenceUploader.upload`.
        guard let jwt = await session.validAccessToken(),
              let userId = session.currentUserId else {
            throw AccountDeletionError.notSignedIn
        }

        // Steps 1-2: photos. Any failure here aborts BEFORE the RPC.
        let objectPaths: [String]
        do {
            objectPaths = try await collectObjectPaths(
                prefix: Self.storageRootPrefix(for: userId),
                depth: 0,
                jwt: jwt
            )
            for batch in Self.batches(of: objectPaths, size: Self.removeBatchSize) {
                try await removeObjects(batch, jwt: jwt)
            }
        } catch {
            throw AccountDeletionError.photoCleanupFailed
        }

        // Step 3: the account itself (one transaction server-side).
        do {
            try await callDeleteRPC(jwt: jwt)
        } catch {
            throw AccountDeletionError.accountDeletionFailed
        }

        // Step 4: the server can't do these.
        await session.endSessionAfterAccountDeletion()
        clearLocalState()
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
        guard Self.isSuccess(response) else {
            throw AccountDeletionError.accountDeletionFailed
        }
    }

    // MARK: - Request plumbing

    private func makeRequest(
        url: URL,
        method: String,
        jwt: String,
        jsonBody: [String: Any]
    ) throws -> URLRequest {
        guard let body = try? JSONSerialization.data(withJSONObject: jsonBody) else {
            throw AccountDeletionError.photoCleanupFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private nonisolated static func isSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
