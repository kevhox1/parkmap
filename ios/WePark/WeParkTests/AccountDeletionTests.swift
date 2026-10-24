//
//  AccountDeletionTests.swift
//  WeParkTests
//
//  Open item #38 — in-app account deletion. Spec/contract: `supabase/10-account-deletion.sql`,
//  `supabase/12-storage-delete-own.sql`, `docs/supabase-ceremony-10-11.md`.
//
//  Network tests are URLProtocol-mocked (no live calls), in the style of `RouteServiceTests` /
//  `FT15B3Tests`: the mock, server simulator, fake session and event log below are PREFIXED
//  `AcctDel` so they can never shadow another test file's helpers.
//
//  Cases:
//   1. AccountDeletionServiceTests
//      - testStorageRootPrefix_isLowercase                      (the uppercase-uuidString trap)
//      - testBatches_splitsIntoChunksOfAtMostSize
//      - testSuccess_runsListRemoveRpcSignoutThenLocalClear_inOrder
//      - testSuccess_listAndRemoveRequestsUseLowercasePrefix_andBearerToken
//      - testEmptyBucket_skipsRemove_stillCallsRpc
//      - testListPagination_pagesByLimitAndOffset_untilShortPage
//      - testListPagination_fullPageFollowedByEmptyPage
//      - testRemovalHttpFailure_abortsBeforeRpc
//      - testRemovalShortReturnedList_abortsBeforeRpc
//      - testListFailure_abortsBeforeRpc
//      - testRpcFailure_afterRemoval_surfacesError_andDoesNotSignOut
//      - testRpc200WithNullBody_isSuccess
//      - testNoSession_throwsNotSignedIn_andSendsNothing
//   2. AccountDeletionLocalStateTests
//      - testClear_removesIdentityGate_keepsDeviceLocalKeys
//   3. AccountDeletionModelTests
//      - testConfirmDeletion_success_endsDeleted
//      - testConfirmDeletion_failure_returnsToIdleWithPlainMessage_andIsRetryable
//      - testConfirmDeletion_doubleTap_runsOnce
//      - testConfirmDeletion_unknownError_usesGenericMessage
//   4. AccountDeletionFlagTests
//      - testAccountDeletionFlag_defaultsFalse
//      - testAccountDeletionRow_hidden_whenDisabled
//   5. AuthorDisplayNameTests ("Former neighbor" rule)
//   6. AccountDeletionHardeningTests -- QA PR #144 follow-up (listing cross-check, retries, caps,
//      RPC outcomes); case list in the MARK 6 comment near the end of this file
//   7. CrewFeedProfileStateTests / AccountDeletionRegularsResetTests -- stale per-user state
//   (The identity-handoff tests live in SupabaseAuthServiceTests.swift:
//    SupabaseAuthServiceAccountDeletionTests.)
//
//  [COMPILE-UNVERIFIED] Written with no Swift toolchain on this machine.
//

import XCTest
@testable import WePark

// MARK: - Event log

/// Thread-safe ordered log shared by the URLProtocol server, the fake session and the
/// local-state closure, so the test can assert the CROSS-component order.
private final class AcctDelEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - Fake session

@MainActor
private final class AcctDelFakeSession: AccountSessionProviding {
    var token: String?
    let userId: UUID?
    let log: AcctDelEventLog

    init(token: String? = "jwt-test-token", userId: UUID? = nil, log: AcctDelEventLog) {
        self.token = token
        self.userId = userId
        self.log = log
    }

    private(set) var endedForUserIds: [UUID] = []

    func validAccessToken() async -> String? { token }

    func currentSessionSnapshot() async -> AccountSessionSnapshot? {
        guard let token, let userId else { return nil }
        return AccountSessionSnapshot(accessToken: token, userId: userId)
    }

    func endSessionAfterAccountDeletion(deletedUserId: UUID) async {
        endedForUserIds.append(deletedUserId)
        log.append("signout")
    }
}

// MARK: - URLProtocol mock + server simulator

private final class AcctDelMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = AcctDelMockURLProtocol.requestHandler else {
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

private func acctDelMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AcctDelMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// URLSession turns `httpBody` into `httpBodyStream` once a request passes through a real
/// session; read either.
private func acctDelBodyData(from request: URLRequest) -> Data? {
    if let data = request.httpBody, !data.isEmpty { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        guard read > 0 else { break }
        data.append(contentsOf: buffer[0..<read])
    }
    return data.isEmpty ? nil : data
}

private func acctDelJSONObject(from request: URLRequest) -> [String: Any] {
    guard let data = acctDelBodyData(from: request),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

private func acctDelHTTPResponse(_ request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url ?? URL(string: "https://example.supabase.co")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
}

/// One entry of a Storage list response. `isFolder` -> `id: null`.
private func acctDelListEntriesJSON(files: [String] = [], folders: [String] = []) -> Data {
    var items: [String] = []
    for folder in folders {
        items.append("{\"name\":\"\(folder)\",\"id\":null,\"updated_at\":null,\"created_at\":null,\"last_accessed_at\":null,\"metadata\":null}")
    }
    for file in files {
        items.append("{\"name\":\"\(file)\",\"id\":\"\(UUID().uuidString)\",\"updated_at\":\"2026-10-01T00:00:00Z\",\"created_at\":\"2026-10-01T00:00:00Z\",\"last_accessed_at\":\"2026-10-01T00:00:00Z\",\"metadata\":{\"size\":1}}")
    }
    return Data("[\(items.joined(separator: ","))]".utf8)
}

/// Stand-in for the Supabase Storage + PostgREST endpoints the sequence touches. Configure the
/// closures BEFORE running; every handled request is appended to `log` in arrival order.
private final class AcctDelServer: @unchecked Sendable {
    let log: AcctDelEventLog

    var listHandler: (_ prefix: String, _ offset: Int) -> (status: Int, body: Data) = { _, _ in
        (200, Data("[]".utf8))
    }
    var removeHandler: (_ paths: [String]) -> (status: Int, body: Data) = { paths in
        let objects = paths.map { "{\"name\":\"\($0)\"}" }
        return (200, Data("[\(objects.joined(separator: ","))]".utf8))
    }
    var rpcHandler: () -> (status: Int, body: Data) = { (204, Data()) }
    /// `GET /rest/v1/pin_evidence` -- the caller's own evidence rows (default: none).
    var rowsHandler: () -> (status: Int, body: Data) = { (200, Data("[]".utf8)) }
    /// `GET /storage/v1/object/info/authenticated/pin-evidence/<path>` -- default: Storage's
    /// "no such object" answer (404 + not_found body).
    var probeHandler: (_ path: String) -> (status: Int, body: Data) = { _ in
        (404, Data("{\"statusCode\":\"404\",\"error\":\"not_found\",\"message\":\"Object not found\"}".utf8))
    }
    /// Set to make every probe fail at the transport level.
    var probeError: Error?
    /// `GET /auth/v1/user` -- only reached after an RPC 401.
    var authUserHandler: () -> (status: Int, body: Data) = { (200, Data("{}".utf8)) }
    /// Set to make the RPC fail at the transport level (response lost).
    var rpcError: Error?

    private let lock = NSLock()
    private var listRequests: [URLRequest] = []
    private var removeRequests: [URLRequest] = []
    private var rpcRequests: [URLRequest] = []
    private var rowsRequests: [URLRequest] = []
    private var probeRequests: [URLRequest] = []

    init(log: AcctDelEventLog) {
        self.log = log
    }

    var capturedListRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return listRequests
    }
    var capturedRemoveRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return removeRequests
    }
    var capturedRpcRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return rpcRequests
    }
    var capturedRowsRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return rowsRequests
    }
    var capturedProbeRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return probeRequests
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        let body = acctDelJSONObject(from: request)

        if method == "POST" && path.hasSuffix("/storage/v1/object/list/pin-evidence") {
            let prefix = body["prefix"] as? String ?? ""
            let offset = body["offset"] as? Int ?? -1
            log.append("list:\(prefix)@\(offset)")
            lock.lock(); listRequests.append(request); lock.unlock()
            let result = listHandler(prefix, offset)
            return (acctDelHTTPResponse(request, status: result.status), result.body)
        }
        if method == "DELETE" && path.hasSuffix("/storage/v1/object/pin-evidence") {
            let paths = body["prefixes"] as? [String] ?? []
            log.append("remove:\(paths.count)")
            lock.lock(); removeRequests.append(request); lock.unlock()
            let result = removeHandler(paths)
            return (acctDelHTTPResponse(request, status: result.status), result.body)
        }
        if method == "POST" && path.hasSuffix("/rest/v1/rpc/delete_my_account") {
            log.append("rpc")
            lock.lock(); rpcRequests.append(request); lock.unlock()
            if let rpcError { throw rpcError }
            let result = rpcHandler()
            return (acctDelHTTPResponse(request, status: result.status), result.body)
        }
        if method == "GET" && path.hasSuffix("/rest/v1/pin_evidence") {
            log.append("rows")
            lock.lock(); rowsRequests.append(request); lock.unlock()
            let result = rowsHandler()
            return (acctDelHTTPResponse(request, status: result.status), result.body)
        }
        if method == "GET", let range = path.range(of: "/storage/v1/object/info/authenticated/pin-evidence/") {
            let objectPath = String(path[range.upperBound...])
            log.append("probe:\(objectPath)")
            lock.lock(); probeRequests.append(request); lock.unlock()
            if let probeError { throw probeError }
            let result = probeHandler(objectPath)
            return (acctDelHTTPResponse(request, status: result.status), result.body)
        }
        if method == "GET" && path.hasSuffix("/auth/v1/user") {
            log.append("authUser")
            let result = authUserHandler()
            return (acctDelHTTPResponse(request, status: result.status), result.body)
        }
        log.append("unexpected:\(method) \(path)")
        return (acctDelHTTPResponse(request, status: 404), Data())
    }
}

// MARK: - Fixtures

private let acctDelUpperUUID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
private let acctDelLowerUUIDString = "abcdef01-2345-6789-abcd-ef0123456789"

private struct AcctDelRig {
    let log: AcctDelEventLog
    let server: AcctDelServer
    let session: AcctDelFakeSession
    let service: AccountDeletionService
    /// Private center so the completion notification is observable without cross-test bleed.
    let notifications: NotificationCenter
}

@MainActor
private func acctDelMakeRig(token: String? = "jwt-test-token", userId: UUID? = acctDelUpperUUID) -> AcctDelRig {
    let log = AcctDelEventLog()
    let server = AcctDelServer(log: log)
    AcctDelMockURLProtocol.requestHandler = { request in try server.handle(request) }
    let session = AcctDelFakeSession(token: token, userId: userId, log: log)
    let notifications = NotificationCenter()
    let service = AccountDeletionService(
        supabaseURL: URL(string: "https://example.supabase.co")!,
        supabaseAnonKey: "anon-key-test",
        urlSession: acctDelMockSession(),
        session: session,
        clearLocalState: { log.append("clearLocal") },
        notificationCenter: notifications
    )
    return AcctDelRig(log: log, server: server, session: session, service: service, notifications: notifications)
}

// MARK: - 1. AccountDeletionService

@MainActor
final class AccountDeletionServiceTests: XCTestCase {

    func testStorageRootPrefix_isLowercase() {
        // Swift prints UUIDs UPPERCASE; Postgres' auth.uid()::text is lowercase. An uppercase
        // prefix lists/removes nothing and would let the RPC orphan real photos.
        XCTAssertEqual(acctDelUpperUUID.uuidString, "ABCDEF01-2345-6789-ABCD-EF0123456789")
        let prefix = AccountDeletionService.storageRootPrefix(for: acctDelUpperUUID)
        XCTAssertEqual(prefix, acctDelLowerUUIDString)
        XCTAssertEqual(prefix, prefix.lowercased())
        XCTAssertFalse(prefix.hasSuffix("/"), "bare uid, no trailing slash (see file header)")
    }

    func testBatches_splitsIntoChunksOfAtMostSize() {
        let paths = (0..<250).map { "p\($0)" }
        let batches = AccountDeletionService.batches(of: paths, size: 100)
        XCTAssertEqual(batches.map { $0.count }, [100, 100, 50])
        XCTAssertEqual(batches.flatMap { $0 }, paths)
        XCTAssertEqual(AccountDeletionService.batches(of: [], size: 100).count, 0)
    }

    func testSuccess_runsListRemoveRpcSignoutThenLocalClear_inOrder() async throws {
        let rig = acctDelMakeRig()
        let root = acctDelLowerUUIDString
        rig.server.listHandler = { prefix, _ in
            if prefix == root {
                return (200, acctDelListEntriesJSON(folders: ["group1"]))
            }
            if prefix == "\(root)/group1" {
                return (200, acctDelListEntriesJSON(files: ["a.jpg", "b.jpg"]))
            }
            return (200, Data("[]".utf8))
        }

        try await rig.service.deleteAccount()

        XCTAssertEqual(rig.log.events, [
            "list:\(root)@0",
            "list:\(root)/group1@0",
            "rows",
            "remove:2",
            "rpc",
            "signout",
            "clearLocal",
        ])
        let removed = acctDelJSONObject(from: rig.server.capturedRemoveRequests[0])["prefixes"] as? [String]
        XCTAssertEqual(removed, ["\(root)/group1/a.jpg", "\(root)/group1/b.jpg"])
    }

    func testSuccess_listAndRemoveRequestsUseLowercasePrefix_andBearerToken() async throws {
        let rig = acctDelMakeRig(token: "jwt-xyz")
        let root = acctDelLowerUUIDString
        rig.server.listHandler = { prefix, _ in
            prefix == root ? (200, acctDelListEntriesJSON(files: ["solo.jpg"])) : (200, Data("[]".utf8))
        }

        try await rig.service.deleteAccount()

        let listBody = acctDelJSONObject(from: rig.server.capturedListRequests[0])
        XCTAssertEqual(listBody["prefix"] as? String, acctDelLowerUUIDString)
        XCTAssertEqual(listBody["limit"] as? Int, 100)
        XCTAssertEqual(listBody["offset"] as? Int, 0)

        let listRequest = rig.server.capturedListRequests[0]
        XCTAssertEqual(listRequest.httpMethod, "POST")
        XCTAssertEqual(listRequest.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-xyz")
        XCTAssertEqual(listRequest.value(forHTTPHeaderField: "apikey"), "anon-key-test")

        let removeRequest = rig.server.capturedRemoveRequests[0]
        XCTAssertEqual(removeRequest.httpMethod, "DELETE")
        XCTAssertEqual(removeRequest.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-xyz")
        let removed = acctDelJSONObject(from: removeRequest)["prefixes"] as? [String]
        XCTAssertEqual(removed, ["\(root)/solo.jpg"])
        for path in removed ?? [] {
            XCTAssertTrue(path.hasPrefix(acctDelLowerUUIDString + "/"), "uid segment must be lowercase")
        }

        let rpcRequest = rig.server.capturedRpcRequests[0]
        XCTAssertEqual(rpcRequest.httpMethod, "POST")
        XCTAssertEqual(rpcRequest.url?.path.hasSuffix("/rest/v1/rpc/delete_my_account"), true)
        XCTAssertEqual(rpcRequest.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-xyz")
    }

    func testEmptyBucket_skipsRemove_stillCallsRpc() async throws {
        let rig = acctDelMakeRig()

        try await rig.service.deleteAccount()

        XCTAssertEqual(rig.log.events, [
            "list:\(acctDelLowerUUIDString)@0",
            "rows",
            "rpc",
            "signout",
            "clearLocal",
        ])
        XCTAssertEqual(rig.server.capturedRemoveRequests.count, 0)
    }

    func testListPagination_pagesByLimitAndOffset_untilShortPage() async throws {
        let rig = acctDelMakeRig()
        let root = acctDelLowerUUIDString
        // 230 files directly under the uid: pages of 100, 100, 30.
        rig.server.listHandler = { prefix, offset in
            guard prefix == root else { return (200, Data("[]".utf8)) }
            let total = 230
            let end = min(offset + 100, total)
            let names = offset < total ? (offset..<end).map { "f\($0).jpg" } : []
            return (200, acctDelListEntriesJSON(files: names))
        }

        try await rig.service.deleteAccount()

        let listEvents = rig.log.events.filter { $0.hasPrefix("list:") }
        XCTAssertEqual(listEvents, ["list:\(root)@0", "list:\(root)@100", "list:\(root)@200"])
        // 230 paths -> remove batches of 100, 100, 30; RPC strictly after the last.
        XCTAssertEqual(rig.log.events.filter { $0.hasPrefix("remove:") }, ["remove:100", "remove:100", "remove:30"])
        XCTAssertEqual(Array(rig.log.events.suffix(3)), ["rpc", "signout", "clearLocal"])
    }

    func testListPagination_fullPageFollowedByEmptyPage() async throws {
        let rig = acctDelMakeRig()
        let root = acctDelLowerUUIDString
        rig.server.listHandler = { prefix, offset in
            guard prefix == root, offset == 0 else { return (200, Data("[]".utf8)) }
            return (200, acctDelListEntriesJSON(files: (0..<100).map { "f\($0).jpg" }))
        }

        try await rig.service.deleteAccount()

        XCTAssertEqual(rig.log.events.filter { $0.hasPrefix("list:") }, ["list:\(root)@0", "list:\(root)@100"])
        XCTAssertEqual(rig.log.events.filter { $0.hasPrefix("remove:") }, ["remove:100"])
    }

    func testRemovalHttpFailure_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        let root = acctDelLowerUUIDString
        rig.server.listHandler = { prefix, _ in
            prefix == root ? (200, acctDelListEntriesJSON(files: ["a.jpg"])) : (200, Data("[]".utf8))
        }
        rig.server.removeHandler = { _ in (500, Data("{}".utf8)) }

        do {
            try await rig.service.deleteAccount()
            XCTFail("expected photoCleanupFailed")
        } catch let error as AccountDeletionError {
            guard case .photoCleanupFailed = error else {
                return XCTFail("expected photoCleanupFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertFalse(rig.log.events.contains("rpc"), "the RPC must NOT run after a failed removal")
        XCTAssertFalse(rig.log.events.contains("signout"))
        XCTAssertFalse(rig.log.events.contains("clearLocal"))
    }

    func testRemovalShortReturnedList_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        let root = acctDelLowerUUIDString
        rig.server.listHandler = { prefix, _ in
            prefix == root ? (200, acctDelListEntriesJSON(files: ["a.jpg", "b.jpg"])) : (200, Data("[]".utf8))
        }
        // 200 OK but only ONE of the two objects reported deleted.
        rig.server.removeHandler = { _ in (200, Data("[{\"name\":\"a.jpg\"}]".utf8)) }

        do {
            try await rig.service.deleteAccount()
            XCTFail("expected photoCleanupFailed")
        } catch let error as AccountDeletionError {
            guard case .photoCleanupFailed = error else {
                return XCTFail("expected photoCleanupFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertFalse(rig.log.events.contains("rpc"))
        XCTAssertFalse(rig.log.events.contains("signout"))
    }

    func testListFailure_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        rig.server.listHandler = { _, _ in (403, Data("{\"message\":\"denied\"}".utf8)) }

        do {
            try await rig.service.deleteAccount()
            XCTFail("expected photoCleanupFailed")
        } catch let error as AccountDeletionError {
            guard case .photoCleanupFailed = error else {
                return XCTFail("expected photoCleanupFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(rig.log.events, ["list:\(acctDelLowerUUIDString)@0"])
    }

    func testRpcFailure_afterRemoval_surfacesError_andDoesNotSignOut() async {
        let rig = acctDelMakeRig()
        let root = acctDelLowerUUIDString
        rig.server.listHandler = { prefix, _ in
            prefix == root ? (200, acctDelListEntriesJSON(files: ["a.jpg"])) : (200, Data("[]".utf8))
        }
        rig.server.rpcHandler = { (500, Data("{\"code\":\"XX000\",\"message\":\"boom\"}".utf8)) }

        do {
            try await rig.service.deleteAccount()
            XCTFail("expected accountDeletionFailed")
        } catch let error as AccountDeletionError {
            guard case .accountDeletionFailed = error else {
                return XCTFail("expected accountDeletionFailed, got \(error)")
            }
            // Plain-language copy, no status codes / server text.
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("500"))
            XCTAssertFalse(message.contains("boom"))
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(rig.log.events, ["list:\(root)@0", "rows", "remove:1", "rpc"])
    }

    func testRpc200WithNullBody_isSuccess() async throws {
        let rig = acctDelMakeRig()
        rig.server.rpcHandler = { (200, Data("null".utf8)) }

        try await rig.service.deleteAccount()

        XCTAssertEqual(Array(rig.log.events.suffix(3)), ["rpc", "signout", "clearLocal"])
    }

    func testNoSession_throwsNotSignedIn_andSendsNothing() async {
        let rig = acctDelMakeRig(token: nil)

        do {
            try await rig.service.deleteAccount()
            XCTFail("expected notSignedIn")
        } catch let error as AccountDeletionError {
            guard case .notSignedIn = error else {
                return XCTFail("expected notSignedIn, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(rig.log.events, [])
    }
}

// MARK: - 2. Local state

@MainActor
final class AccountDeletionLocalStateTests: XCTestCase {

    func testClear_removesIdentityGate_keepsDeviceLocalKeys() throws {
        let suiteName = "AccountDeletionLocalStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: CommunityIdentityGate.shownKey)
        defaults.set(Data("car".utf8), forKey: "wepark_parked_car")
        defaults.set(true, forKey: "wepark_has_ever_parked")
        defaults.set(true, forKey: AppConstants.notificationsMutedKey)

        AccountDeletionLocalState.clear(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: CommunityIdentityGate.shownKey),
                       "the new anonymous identity must be offered a handle again")
        XCTAssertNotNil(defaults.data(forKey: "wepark_parked_car"), "parked car is device-local")
        XCTAssertTrue(defaults.bool(forKey: "wepark_has_ever_parked"))
        XCTAssertTrue(defaults.bool(forKey: AppConstants.notificationsMutedKey))
    }
}

// MARK: - 3. Confirmation model

@MainActor
private final class AcctDelGatedDeleter: AccountDeleting {
    private(set) var callCount = 0
    var errorToThrow: Error?
    private var continuation: CheckedContinuation<Void, Never>?

    func deleteAccount() async throws {
        callCount += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        if let errorToThrow {
            throw errorToThrow
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct AcctDelUnrelatedError: Error {}

@MainActor
final class AccountDeletionModelTests: XCTestCase {

    private func waitUntilDeleting(_ model: AccountDeletionModel) async {
        var spins = 0
        while !model.isDeleting && spins < 200 {
            await Task.yield()
            spins += 1
        }
    }

    func testConfirmDeletion_success_endsDeleted() async {
        let deleter = AcctDelGatedDeleter()
        let model = AccountDeletionModel(deleter: deleter)
        XCTAssertTrue(model.isIdle)

        let run = Task { await model.confirmDeletion() }
        await waitUntilDeleting(model)
        XCTAssertTrue(model.isDeleting)
        deleter.release()
        await run.value

        XCTAssertTrue(model.isDeleted)
        XCTAssertNil(model.errorMessage)
    }

    func testConfirmDeletion_failure_returnsToIdleWithPlainMessage_andIsRetryable() async {
        let deleter = AcctDelGatedDeleter()
        deleter.errorToThrow = AccountDeletionError.photoCleanupFailed
        let model = AccountDeletionModel(deleter: deleter)

        let run = Task { await model.confirmDeletion() }
        await waitUntilDeleting(model)
        deleter.release()
        await run.value

        XCTAssertTrue(model.isIdle, "failure leaves everything intact and retryable")
        XCTAssertEqual(model.errorMessage, AccountDeletionError.photoCleanupFailed.errorDescription)

        // Retry succeeds.
        deleter.errorToThrow = nil
        let retry = Task { await model.confirmDeletion() }
        await waitUntilDeleting(model)
        deleter.release()
        await retry.value
        XCTAssertTrue(model.isDeleted)
        XCTAssertEqual(deleter.callCount, 2)
    }

    func testConfirmDeletion_doubleTap_runsOnce() async {
        let deleter = AcctDelGatedDeleter()
        let model = AccountDeletionModel(deleter: deleter)

        let first = Task { await model.confirmDeletion() }
        await waitUntilDeleting(model)

        // Second tap while the first is still running: returns immediately, no second run.
        await model.confirmDeletion()
        XCTAssertEqual(deleter.callCount, 1)
        XCTAssertTrue(model.isDeleting)

        deleter.release()
        await first.value
        XCTAssertTrue(model.isDeleted)

        // A tap after success is also a no-op.
        await model.confirmDeletion()
        XCTAssertEqual(deleter.callCount, 1)
    }

    func testConfirmDeletion_unknownError_usesGenericMessage() async {
        let deleter = AcctDelGatedDeleter()
        deleter.errorToThrow = AcctDelUnrelatedError()
        let model = AccountDeletionModel(deleter: deleter)

        let run = Task { await model.confirmDeletion() }
        await waitUntilDeleting(model)
        deleter.release()
        await run.value

        XCTAssertEqual(model.errorMessage, AccountDeletionModel.genericFailureMessage)
        XCTAssertTrue(model.isIdle)
    }
}

// MARK: - 4. Flag guards

@MainActor
final class AccountDeletionFlagTests: XCTestCase {

    func testAccountDeletionFlag_defaultsFalse() {
        XCTAssertFalse(
            AppConstants.accountDeletionEnabled,
            "accountDeletionEnabled must ship dark until Kevin confirms migrations 10 and 12 are applied and verified."
        )
    }

    func testAccountDeletionRow_hidden_whenDisabled() {
        XCTAssertFalse(AppConstants.accountDeletionRowVisible(enabled: false))
        XCTAssertTrue(AppConstants.accountDeletionRowVisible(enabled: true))
        XCTAssertEqual(
            AppConstants.accountDeletionRowVisible(),
            AppConstants.accountDeletionRowVisible(enabled: AppConstants.accountDeletionEnabled),
            "the no-argument call must resolve identically to an explicit call with the real flag value"
        )
    }
}

// MARK: - 5. "Former neighbor"

private func acctDelDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = withFraction.date(from: string) { return date }
        if let date = plain.date(from: string) { return date }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Cannot decode date: \(string)")
        )
    }
    return decoder
}

private func acctDelPin(
    source: String,
    authorId: String?,
    authorUsername: String?
) -> CommunityPin {
    let authorIdJSON = authorId.map { "\"\($0)\"" } ?? "null"
    let usernameJSON = authorUsername.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "id": "10000000-0000-0000-0000-0000000000AA",
      "pin_type": "enforcement_active",
      "source": "\(source)",
      "lifespan": "ephemeral",
      "lat": 40.7230,
      "lng": -73.9950,
      "segment_id": null,
      "zone_id": "nolita",
      "author_id": \(authorIdJSON),
      "author_username": \(usernameJSON),
      "created_at": "2026-08-27T09:00:00+00:00",
      "updated_at": "2026-08-27T09:00:00+00:00",
      "expires_at": null,
      "resolved_at": null,
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": null,
      "notes": null,
      "claimed_by": null
    }
    """
    return try! acctDelDecoder().decode(CommunityPin.self, from: Data(json.utf8))
}

private func acctDelMessage(
    messageType: String,
    authorId: String?,
    authorUsername: String?
) -> ZoneMessage {
    let authorIdJSON = authorId.map { "\"\($0)\"" } ?? "null"
    let usernameJSON = authorUsername.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "id": 7,
      "zone_id": "nolita",
      "author_id": \(authorIdJSON),
      "message_type": "\(messageType)",
      "body": "hello",
      "related_report_id": null,
      "created_at": "2026-08-27T09:00:00+00:00",
      "author_username": \(usernameJSON),
      "author_reputation": null,
      "segment_id": null
    }
    """
    return try! acctDelDecoder().decode(ZoneMessage.self, from: Data(json.utf8))
}

@MainActor
final class AuthorDisplayNameTests: XCTestCase {

    private let someAuthor = "A0000000-0000-0000-0000-000000000001"

    // The shared label itself.
    func testFormerNeighborLabel_text() {
        XCTAssertEqual(AuthorDisplayName.formerNeighbor, "Former neighbor")
        XCTAssertEqual(AuthorDisplayName.neighbor, "Neighbor")
    }

    // Core rule.
    func testResolve_usernamePresent_alwaysWins() {
        XCTAssertEqual(AuthorDisplayName.resolve(username: "Mike", authorId: nil, isUserAuthored: true), "Mike")
    }

    func testResolve_nullAuthor_userAuthored_isFormerNeighbor() {
        XCTAssertEqual(AuthorDisplayName.resolve(username: nil, authorId: nil, isUserAuthored: true), "Former neighbor")
    }

    func testResolve_nullAuthor_notUserAuthored_staysNeighbor() {
        XCTAssertEqual(AuthorDisplayName.resolve(username: nil, authorId: nil, isUserAuthored: false), "Neighbor")
    }

    func testResolve_liveAuthorWithoutUsername_staysNeighbor() {
        // e.g. a Realtime-pushed row: author_id present, joined username absent.
        XCTAssertEqual(
            AuthorDisplayName.resolve(username: nil, authorId: UUID(), isUserAuthored: true),
            "Neighbor"
        )
    }

    // Pins: only source == crowd.
    func testPin_crowd_nullAuthor_isFormerNeighbor() {
        let pin = acctDelPin(source: "crowd", authorId: nil, authorUsername: nil)
        XCTAssertEqual(AuthorDisplayName.name(for: pin), "Former neighbor")
    }

    func testPin_openData_nullAuthor_mustNotBeFormerNeighbor() {
        let pin = acctDelPin(source: "open_data", authorId: nil, authorUsername: nil)
        XCTAssertEqual(AuthorDisplayName.name(for: pin), "Neighbor")
    }

    func testPin_hybrid_nullAuthor_mustNotBeFormerNeighbor() {
        let pin = acctDelPin(source: "hybrid", authorId: nil, authorUsername: nil)
        XCTAssertEqual(AuthorDisplayName.name(for: pin), "Neighbor")
    }

    func testPin_crowd_liveAuthor_usesUsername_orNeighborWhenUnjoined() {
        let named = acctDelPin(source: "crowd", authorId: someAuthor, authorUsername: "MulberryMike")
        XCTAssertEqual(AuthorDisplayName.name(for: named), "MulberryMike")
        let unjoined = acctDelPin(source: "crowd", authorId: someAuthor, authorUsername: nil)
        XCTAssertEqual(AuthorDisplayName.name(for: unjoined), "Neighbor")
    }

    // Chat: only message_type == user.
    func testMessage_user_nullAuthor_isFormerNeighbor() {
        let message = acctDelMessage(messageType: "user", authorId: nil, authorUsername: nil)
        XCTAssertEqual(AuthorDisplayName.name(for: message), "Former neighbor")
    }

    func testMessage_systemTracker_nullAuthor_mustNotBeFormerNeighbor() {
        let message = acctDelMessage(messageType: "system_tracker", authorId: nil, authorUsername: nil)
        XCTAssertEqual(AuthorDisplayName.name(for: message), "Neighbor")
    }

    func testMessage_user_liveAuthor_usesUsername() {
        let message = acctDelMessage(messageType: "user", authorId: someAuthor, authorUsername: "Springy")
        XCTAssertEqual(AuthorDisplayName.name(for: message), "Springy")
    }

    // Wired into the shared sub-lines (chat AND pin rows agree).
    func testCrewFeedSubLines_useTheSharedLabel() {
        let now = Date()
        let crowdPin = acctDelPin(source: "crowd", authorId: nil, authorUsername: nil)
        XCTAssertTrue(CrewFeedMerge.subLine(for: crowdPin, now: now).hasSuffix("Former neighbor"))
        let openDataPin = acctDelPin(source: "open_data", authorId: nil, authorUsername: nil)
        XCTAssertTrue(CrewFeedMerge.subLine(for: openDataPin, now: now).hasSuffix("Neighbor"))
        XCTAssertFalse(CrewFeedMerge.subLine(for: openDataPin, now: now).contains("Former"))
        let userMessage = acctDelMessage(messageType: "user", authorId: nil, authorUsername: nil)
        XCTAssertTrue(CrewFeedMerge.subLine(for: userMessage, now: now).hasPrefix("Former neighbor"))
    }
}

// MARK: - 6. Hardening (QA PR #144: Y1 listing cross-check, lost-RPC, caps, retry, snapshot)
//
//  Cases:
//   - AccountDeletionHardeningTests
//      Y1:  testY1_emptyListing_rowExists_probeSaysObjectExists_abortsBeforeRpc
//           testY1_emptyListing_rowExists_probeNotFound_proceeds
//           testY1_emptyListing_rowExists_probeNotFound400_proceeds
//           testY1_listingConsistentWithRows_noProbe_proceeds
//           testY1_probeServerError_abortsBeforeRpc
//           testY1_probeTransportError_abortsBeforeRpc
//           testY1_probeInconclusiveBodies_abortBeforeRpc
//           testY1_rowsRequestFailure_abortsBeforeRpc
//           testY1_mixedListing_probesOnlyRowsMissingFromListing
//           testY1_duplicateMissingRows_probedOnce
//           testY1_rowsRequest_isScopedToCaller_andAuthenticated
//           testY1_probeRequest_usesAuthenticatedInfoRoute
//           testIsObjectNotFound_strictRecognition
//      Retry: testPartialRemovalThenRetry_secondRunSucceeds
//             testLostRpcResponse_thenRetry_succeeds
//      Caps:  testFolderDepthCap_abortsBeforeRpc
//             testListPageCap_abortsBeforeRpc
//      RPC:   testRpcTransportError_isRetrySafeFailure_andDoesNotSignOut
//             testRpc401_confirmedAccountGone_isSuccess
//             testRpc401_userStillExists_isFailure
//             testRpc401_goneNotConfirmed_isFailure
//      Misc:  testSnapshotUserId_drivesPrefix_andSignout
//             testSuccess_postsNotification_afterLocalClear
//             testFailure_doesNotPostNotification
//             testConfirmCopy_saysParkedCarAndRemindersAreKept
//   - CrewFeedProfileStateTests (Y3, pure state)
//   - AccountDeletionRegularsResetTests (Y3, RegularsService)

private let acctDelRoot = acctDelLowerUUIDString
private let acctDelNotFoundBody = Data(#"{"statusCode":"404","error":"not_found","message":"Object not found"}"#.utf8)

private func acctDelRowsJSON(_ paths: [String]) -> Data {
    let items = paths.map { "{\"storage_path\":\"\($0)\"}" }
    return Data("[\(items.joined(separator: ","))]".utf8)
}

/// Mutable "bucket" backing list / remove / probe so multi-run scenarios behave like a server.
private final class AcctDelObjectStore: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]
    private var removeCallsAllowed: Int

    init(names: [String], removeCallsAllowed: Int = Int.max) {
        self.names = names
        self.removeCallsAllowed = removeCallsAllowed
    }

    func page(offset: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(names.dropFirst(offset).prefix(100))
    }

    /// Removes the given FULL paths (`root/name`). Returns false (= server error) once the allowed
    /// number of remove calls is used up.
    func tryRemove(paths: [String], root: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard removeCallsAllowed > 0 else { return false }
        if removeCallsAllowed != Int.max { removeCallsAllowed -= 1 }
        let gone = Set(paths)
        names.removeAll { gone.contains("\(acctDelRoot)/\($0)") }
        return true
    }

    func allowRemoveCalls(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        removeCallsAllowed = count
    }

    func contains(path: String, root: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.contains { "\(acctDelRoot)/\($0)" == path }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return names.count
    }
}

@MainActor
private func acctDelWire(_ rig: AcctDelRig, store: AcctDelObjectStore, rowPaths: [String]) {
    let root = acctDelLowerUUIDString
    rig.server.listHandler = { prefix, offset in
        guard prefix == root else { return (200, Data("[]".utf8)) }
        return (200, acctDelListEntriesJSON(files: store.page(offset: offset)))
    }
    rig.server.removeHandler = { paths in
        guard store.tryRemove(paths: paths, root: root) else { return (500, Data("{}".utf8)) }
        let objects = paths.map { "{\"name\":\"\($0)\"}" }
        return (200, Data("[\(objects.joined(separator: ","))]".utf8))
    }
    rig.server.rowsHandler = { (200, acctDelRowsJSON(rowPaths)) }
    rig.server.probeHandler = { path in
        if store.contains(path: path, root: root) {
            return (200, Data("{}".utf8))
        }
        return (404, acctDelNotFoundBody)
    }
}

@MainActor
private func acctDelRun(_ service: AccountDeletionService) async -> AccountDeletionError? {
    do {
        try await service.deleteAccount()
        return nil
    } catch let error as AccountDeletionError {
        return error
    } catch {
        return nil
    }
}

@MainActor
private func acctDelIsPhotoFailure(_ error: AccountDeletionError?) -> Bool {
    guard let error else { return false }
    if case .photoCleanupFailed = error { return true }
    return false
}

@MainActor
private func acctDelIsAccountFailure(_ error: AccountDeletionError?) -> Bool {
    guard let error else { return false }
    if case .accountDeletionFailed = error { return true }
    return false
}

private final class AcctDelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class AccountDeletionHardeningTests: XCTestCase {

    // MARK: Y1 -- the listing cross-check

    /// The dangerous case: Storage lists nothing although the caller's evidence rows point at
    /// objects that DO exist (wrong prefix / case / server quirk). Must abort before the RPC.
    func testY1_emptyListing_rowExists_probeSaysObjectExists_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        let path = "\(acctDelRoot)/group1/PHOTO.jpg"
        rig.server.rowsHandler = { (200, acctDelRowsJSON([path])) }
        rig.server.probeHandler = { _ in (200, Data("{\"name\":\"group1/PHOTO.jpg\"}".utf8)) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(error), "expected photoCleanupFailed, got \(String(describing: error))")
        XCTAssertEqual(rig.log.events, ["list:\(acctDelRoot)@0", "rows", "probe:\(path)"])
        XCTAssertFalse(rig.log.events.contains("rpc"), "the RPC must NOT run: it would orphan the photo")
        XCTAssertFalse(rig.log.events.contains("signout"))
        XCTAssertFalse(rig.log.events.contains("clearLocal"))
    }

    /// The retry-after-first-run case: files already gone, rows remain (only the RPC removes
    /// rows). A naive "rows exist but listing empty => abort" rule would deadlock here.
    func testY1_emptyListing_rowExists_probeNotFound_proceeds() async {
        let rig = acctDelMakeRig()
        let path = "\(acctDelRoot)/group1/PHOTO.jpg"
        rig.server.rowsHandler = { (200, acctDelRowsJSON([path])) }
        // default probeHandler: 404 + not_found body

        let error = await acctDelRun(rig.service)

        XCTAssertNil(error)
        XCTAssertEqual(rig.log.events, [
            "list:\(acctDelRoot)@0", "rows", "probe:\(path)", "rpc", "signout", "clearLocal",
        ])
        XCTAssertEqual(rig.server.capturedRemoveRequests.count, 0, "nothing left to remove")
    }

    /// Storage versions report a missing key as HTTP 400 with the real status inside the body.
    func testY1_emptyListing_rowExists_probeNotFound400_proceeds() async {
        let rig = acctDelMakeRig()
        let path = "\(acctDelRoot)/group1/PHOTO.jpg"
        rig.server.rowsHandler = { (200, acctDelRowsJSON([path])) }
        rig.server.probeHandler = { _ in
            (400, Data(#"{"statusCode":"404","error":"not_found","message":"Object not found","code":"NoSuchKey"}"#.utf8))
        }

        let error = await acctDelRun(rig.service)

        XCTAssertNil(error)
        XCTAssertTrue(rig.log.events.contains("rpc"))
    }

    func testY1_listingConsistentWithRows_noProbe_proceeds() async {
        let rig = acctDelMakeRig()
        let store = AcctDelObjectStore(names: ["a.jpg", "b.jpg"])
        acctDelWire(rig, store: store, rowPaths: ["\(acctDelRoot)/a.jpg", "\(acctDelRoot)/b.jpg"])

        let error = await acctDelRun(rig.service)

        XCTAssertNil(error)
        XCTAssertEqual(rig.log.events, [
            "list:\(acctDelRoot)@0", "rows", "remove:2", "rpc", "signout", "clearLocal",
        ])
        XCTAssertTrue(rig.server.capturedProbeRequests.isEmpty, "nothing is missing from the listing")
    }

    func testY1_probeServerError_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        rig.server.rowsHandler = { (200, acctDelRowsJSON(["\(acctDelRoot)/g/A.jpg"])) }
        rig.server.probeHandler = { _ in (500, Data("{}".utf8)) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(error))
        XCTAssertFalse(rig.log.events.contains("rpc"))
        XCTAssertFalse(rig.log.events.contains("signout"))
    }

    func testY1_probeTransportError_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        rig.server.rowsHandler = { (200, acctDelRowsJSON(["\(acctDelRoot)/g/A.jpg"])) }
        rig.server.probeError = URLError(.notConnectedToInternet)

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(error), "probe error must fail safe")
        XCTAssertFalse(rig.log.events.contains("rpc"))
    }

    /// A bad JWT, a missing bucket or an unknown route is NOT "the photo is gone".
    func testY1_probeInconclusiveBodies_abortBeforeRpc() async {
        let bodies: [(Int, String)] = [
            (400, #"{"statusCode":"400","error":"Invalid JWT","message":"exp claim timestamp check failed"}"#),
            (404, #"{"statusCode":"404","error":"Bucket not found","message":"Bucket not found"}"#),
            (404, #"{"message":"Route GET:/storage/v1/object/info/x not found","error":"Not Found","statusCode":404}"#),
            (404, "not json"),
            (404, ""),
        ]
        for (status, body) in bodies {
            let rig = acctDelMakeRig()
            rig.server.rowsHandler = { (200, acctDelRowsJSON(["\(acctDelRoot)/g/A.jpg"])) }
            rig.server.probeHandler = { _ in (status, Data(body.utf8)) }

            let error = await acctDelRun(rig.service)

            XCTAssertTrue(acctDelIsPhotoFailure(error), "status \(status) body \(body) must abort")
            XCTAssertFalse(rig.log.events.contains("rpc"), "status \(status) body \(body)")
        }
    }

    func testY1_rowsRequestFailure_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        rig.server.rowsHandler = { (500, Data("{}".utf8)) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(error))
        XCTAssertEqual(rig.log.events, ["list:\(acctDelRoot)@0", "rows"])
    }

    func testY1_mixedListing_probesOnlyRowsMissingFromListing() async {
        let rig = acctDelMakeRig()
        // Listing has a.jpg only; rows have a.jpg AND b.jpg (b was removed by an earlier run).
        let store = AcctDelObjectStore(names: ["a.jpg"])
        acctDelWire(rig, store: store, rowPaths: ["\(acctDelRoot)/a.jpg", "\(acctDelRoot)/b.jpg"])

        let error = await acctDelRun(rig.service)

        XCTAssertNil(error)
        XCTAssertEqual(rig.log.events, [
            "list:\(acctDelRoot)@0", "rows", "probe:\(acctDelRoot)/b.jpg", "remove:1", "rpc", "signout", "clearLocal",
        ])
    }

    func testY1_duplicateMissingRows_probedOnce() async {
        let rig = acctDelMakeRig()
        let path = "\(acctDelRoot)/g/A.jpg"
        rig.server.rowsHandler = { (200, acctDelRowsJSON([path, path])) }

        let error = await acctDelRun(rig.service)

        XCTAssertNil(error)
        XCTAssertEqual(rig.server.capturedProbeRequests.count, 1)
    }

    func testY1_rowsRequest_isScopedToCaller_andAuthenticated() async throws {
        let rig = acctDelMakeRig(token: "jwt-rows")

        _ = await acctDelRun(rig.service)

        let request = try XCTUnwrap(rig.server.capturedRowsRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-rows")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key-test")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["select"], "storage_path")
        XCTAssertEqual(items["uploaded_by"], "eq.\(acctDelLowerUUIDString)", "lowercase uid, own rows only")
        XCTAssertEqual(items["limit"], "1000")
        XCTAssertEqual(items["offset"], "0")
    }

    func testY1_probeRequest_usesAuthenticatedInfoRoute() async throws {
        let rig = acctDelMakeRig(token: "jwt-probe")
        rig.server.rowsHandler = { (200, acctDelRowsJSON(["\(acctDelRoot)/g/A.jpg"])) }

        _ = await acctDelRun(rig.service)

        let request = try XCTUnwrap(rig.server.capturedProbeRequests.first)
        XCTAssertEqual(request.httpMethod, "GET", "a HEAD cannot tell a missing object from a bad JWT")
        XCTAssertEqual(request.url?.path, "/storage/v1/object/info/authenticated/pin-evidence/\(acctDelRoot)/g/A.jpg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-probe")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key-test")
    }

    func testIsObjectNotFound_strictRecognition() {
        let notFound = acctDelNotFoundBody
        XCTAssertTrue(AccountDeletionService.isObjectNotFound(status: 404, body: notFound))
        XCTAssertTrue(AccountDeletionService.isObjectNotFound(status: 400, body: notFound))
        XCTAssertTrue(AccountDeletionService.isObjectNotFound(
            status: 400, body: Data(#"{"code":"NoSuchKey","message":"The resource was not found"}"#.utf8)))
        // The `error` label differs across storage-api versions; the message is what counts.
        XCTAssertTrue(AccountDeletionService.isObjectNotFound(
            status: 404, body: Data(#"{"statusCode":"404","error":"Not Found","message":"Object not found"}"#.utf8)))
        XCTAssertFalse(AccountDeletionService.isObjectNotFound(status: 500, body: notFound))
        XCTAssertFalse(AccountDeletionService.isObjectNotFound(status: 200, body: notFound))
        XCTAssertFalse(AccountDeletionService.isObjectNotFound(status: 401, body: notFound))
        XCTAssertFalse(AccountDeletionService.isObjectNotFound(
            status: 404, body: Data(#"{"error":"Bucket not found","message":"Bucket not found"}"#.utf8)))
        XCTAssertFalse(AccountDeletionService.isObjectNotFound(status: 404, body: Data()))
    }

    // MARK: Retry scenarios

    /// 150 files: batch 1 (100) is removed, batch 2 fails. Nothing was deleted server-side; the
    /// retry re-lists only the 50 left, the 100 already-gone rows are probed (404), and it succeeds.
    func testPartialRemovalThenRetry_secondRunSucceeds() async {
        let rig = acctDelMakeRig()
        let names = (0..<150).map { "f\($0).jpg" }
        let store = AcctDelObjectStore(names: names, removeCallsAllowed: 1)
        acctDelWire(rig, store: store, rowPaths: names.map { "\(acctDelRoot)/\($0)" })

        let first = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(first))
        XCTAssertEqual(store.count, 50, "the first batch of 100 was removed before batch 2 failed")
        XCTAssertFalse(rig.log.events.contains("rpc"))

        store.allowRemoveCalls(Int.max)
        let second = await acctDelRun(rig.service)

        XCTAssertNil(second)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(rig.log.events.filter { $0 == "rpc" }.count, 1, "RPC ran exactly once, on the retry")
        XCTAssertEqual(Array(rig.log.events.suffix(3)), ["rpc", "signout", "clearLocal"])
        // The retry probed exactly the 100 rows whose objects the first run had removed.
        XCTAssertEqual(rig.server.capturedProbeRequests.count, 100)
    }

    /// The RPC committed but its response was lost (transport error): the user sees a retryable
    /// error; on retry the listing is empty, rows remain, probes say gone, the (idempotent) RPC
    /// succeeds and local cleanup runs.
    func testLostRpcResponse_thenRetry_succeeds() async {
        let rig = acctDelMakeRig()
        let store = AcctDelObjectStore(names: ["a.jpg"])
        acctDelWire(rig, store: store, rowPaths: ["\(acctDelRoot)/a.jpg"])
        rig.server.rpcError = URLError(.networkConnectionLost)

        let first = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsAccountFailure(first))
        XCTAssertFalse(rig.log.events.contains("signout"), "no local sign-out until the RPC is confirmed")

        rig.server.rpcError = nil
        let second = await acctDelRun(rig.service)

        XCTAssertNil(second)
        XCTAssertEqual(Array(rig.log.events.suffix(3)), ["rpc", "signout", "clearLocal"])
    }

    // MARK: Caps

    func testFolderDepthCap_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        // Every level contains one more folder, forever.
        rig.server.listHandler = { _, _ in (200, acctDelListEntriesJSON(folders: ["d"])) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(error))
        let lists = rig.log.events.filter { $0.hasPrefix("list:") }
        XCTAssertEqual(lists.count, AccountDeletionService.maxFolderDepth + 1)
        XCTAssertFalse(rig.log.events.contains("rows"))
        XCTAssertFalse(rig.log.events.contains("rpc"))
    }

    func testListPageCap_abortsBeforeRpc() async {
        let rig = acctDelMakeRig()
        // A server that always answers with a FULL page never lets the loop end on its own.
        let fullPage = acctDelListEntriesJSON(files: (0..<100).map { "f\($0).jpg" })
        rig.server.listHandler = { _, _ in (200, fullPage) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsPhotoFailure(error))
        XCTAssertEqual(rig.log.events.filter { $0.hasPrefix("list:") }.count, AccountDeletionService.maxListPages)
        XCTAssertFalse(rig.log.events.contains("rpc"))
    }

    // MARK: RPC outcomes

    func testRpcTransportError_isRetrySafeFailure_andDoesNotSignOut() async {
        let rig = acctDelMakeRig()
        rig.server.rpcError = URLError(.networkConnectionLost)

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsAccountFailure(error))
        XCTAssertTrue(
            (error?.errorDescription ?? "").contains("safe to retry"),
            "the copy must say a retry is safe (the response may have been lost after the commit)"
        )
        XCTAssertFalse(rig.log.events.contains("signout"))
        XCTAssertFalse(rig.log.events.contains("clearLocal"))
    }

    /// A retry for an account that is already gone: the gateway answers 401 for the stale JWT and
    /// Auth confirms the user no longer exists => SUCCESS, local cleanup runs.
    func testRpc401_confirmedAccountGone_isSuccess() async {
        for code in ["user_not_found", "session_not_found"] {
            let rig = acctDelMakeRig()
            rig.server.rpcHandler = { (401, Data(#"{"message":"JWT invalid"}"#.utf8)) }
            rig.server.authUserHandler = {
                (403, Data("{\"code\":403,\"error_code\":\"\(code)\",\"msg\":\"gone\"}".utf8))
            }

            let error = await acctDelRun(rig.service)

            XCTAssertNil(error, "\(code) after an RPC 401 means the account is already deleted")
            XCTAssertEqual(Array(rig.log.events.suffix(4)), ["rpc", "authUser", "signout", "clearLocal"])
        }
    }

    func testRpc401_userStillExists_isFailure() async {
        let rig = acctDelMakeRig()
        rig.server.rpcHandler = { (401, Data("{}".utf8)) }
        rig.server.authUserHandler = { (200, Data(#"{"id":"x"}"#.utf8)) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsAccountFailure(error), "a bare 401 is never trusted as 'deleted'")
        XCTAssertFalse(rig.log.events.contains("signout"))
    }

    func testRpc401_goneNotConfirmed_isFailure() async {
        let rig = acctDelMakeRig()
        rig.server.rpcHandler = { (401, Data("{}".utf8)) }
        rig.server.authUserHandler = { (401, Data(#"{"error_code":"bad_jwt"}"#.utf8)) }

        let error = await acctDelRun(rig.service)

        XCTAssertTrue(acctDelIsAccountFailure(error))
        XCTAssertFalse(rig.log.events.contains("signout"))
    }

    // MARK: Misc

    /// The uid used for every prefix and for the local sign-out is the SNAPSHOT's (token and id
    /// come from one session value).
    func testSnapshotUserId_drivesPrefix_andSignout() async {
        let rig = acctDelMakeRig()

        _ = await acctDelRun(rig.service)

        XCTAssertEqual(rig.log.events.first, "list:\(acctDelLowerUUIDString)@0")
        XCTAssertEqual(rig.session.endedForUserIds, [acctDelUpperUUID])
    }

    func testSuccess_postsNotification_afterLocalClear() async {
        let rig = acctDelMakeRig()
        let log = rig.log
        let token = rig.notifications.addObserver(forName: .weParkAccountDeleted, object: nil, queue: nil) { _ in
            log.append("notified")
        }
        defer { rig.notifications.removeObserver(token) }

        let error = await acctDelRun(rig.service)

        XCTAssertNil(error)
        XCTAssertEqual(Array(rig.log.events.suffix(3)), ["signout", "clearLocal", "notified"])
    }

    func testFailure_doesNotPostNotification() async {
        let rig = acctDelMakeRig()
        rig.server.rpcHandler = { (500, Data("{}".utf8)) }
        let flag = AcctDelFlag()
        let token = rig.notifications.addObserver(forName: .weParkAccountDeleted, object: nil, queue: nil) { _ in
            flag.set()
        }
        defer { rig.notifications.removeObserver(token) }

        _ = await acctDelRun(rig.service)

        XCTAssertFalse(flag.isSet)
    }

    func testConfirmCopy_saysParkedCarAndRemindersAreKept() {
        let copy = DeleteAccountConfirmView.keptOnDeviceCopy.lowercased()
        XCTAssertTrue(copy.contains("parked car"))
        XCTAssertTrue(copy.contains("reminders"))
        XCTAssertTrue(copy.contains("kept"))
        XCTAssertTrue(copy.contains("this device"))
    }
}

// MARK: - 7. Y3: per-user in-memory state

private func acctDelProfile(id: UUID, username: String) -> CommunityProfile {
    let json = """
    {
      "id": "\(id.uuidString)",
      "username": "\(username)",
      "avatar": null,
      "reputation": 12,
      "created_at": "2026-08-27T09:00:00+00:00",
      "helped_count": 1,
      "accurate_report_count": 2,
      "total_report_count": 3
    }
    """
    return try! acctDelDecoder().decode(CommunityProfile.self, from: Data(json.utf8))
}

@MainActor
final class CrewFeedProfileStateTests: XCTestCase {

    private let deletedUser = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let newUser = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    func testFresh_needsLoad_forAUser_butNotForNil() {
        let state = CrewFeedProfileState()
        XCTAssertTrue(state.needsLoad(for: deletedUser))
        XCTAssertFalse(state.needsLoad(for: nil))
        XCTAssertNil(state.profile)
    }

    func testRecordLoad_thenSameUser_doesNotReload_andKeepsProfile() {
        var state = CrewFeedProfileState()
        state.recordLoad(acctDelProfile(id: deletedUser, username: "Mike"), for: deletedUser)

        XCTAssertFalse(state.needsLoad(for: deletedUser))
        XCTAssertFalse(state.syncIdentity(deletedUser), "same identity: nothing dropped")
        XCTAssertEqual(state.profile?.username, "Mike")
    }

    /// The bug: after deletion the NEW identity must not see the old profile and must be fetched.
    func testIdentityChange_dropsDeletedUsersProfile_andAllowsReload() {
        var state = CrewFeedProfileState()
        state.recordLoad(acctDelProfile(id: deletedUser, username: "Mike"), for: deletedUser)

        XCTAssertTrue(state.syncIdentity(newUser), "the previous user's cache must be dropped")

        XCTAssertNil(state.profile, "no deleted-user profile card under the new identity")
        XCTAssertFalse(state.hasAttemptedLoad, "the attempted-load flag must reset or the new identity never loads")
        XCTAssertTrue(state.needsLoad(for: newUser))
    }

    func testIdentityBecomesNil_midHandoff_dropsProfile() {
        var state = CrewFeedProfileState()
        state.recordLoad(acctDelProfile(id: deletedUser, username: "Mike"), for: deletedUser)

        XCTAssertTrue(state.syncIdentity(nil))

        XCTAssertNil(state.profile)
        XCTAssertFalse(state.needsLoad(for: nil))
        XCTAssertTrue(state.needsLoad(for: newUser))
    }

    func testAttemptWithNoProfileRow_isRememberedPerUser_notAcrossUsers() {
        var state = CrewFeedProfileState()
        state.recordLoad(nil, for: deletedUser)
        XCTAssertFalse(state.needsLoad(for: deletedUser), "a nil profile is a completed attempt")
        XCTAssertTrue(state.needsLoad(for: newUser), "but only for that user")
        XCTAssertTrue(state.syncIdentity(newUser))
        XCTAssertFalse(state.hasAttemptedLoad)
    }

    func testSyncIdentity_whenNothingLoaded_isNoop() {
        var state = CrewFeedProfileState()
        XCTAssertFalse(state.syncIdentity(nil))
        XCTAssertFalse(state.syncIdentity(newUser))
    }

    func testReset_clearsEverything() {
        var state = CrewFeedProfileState()
        state.recordLoad(acctDelProfile(id: deletedUser, username: "Mike"), for: deletedUser)
        state.reset()
        XCTAssertNil(state.profile)
        XCTAssertNil(state.ownerId)
        XCTAssertFalse(state.hasAttemptedLoad)
    }

    func testLoadKey_changesWithIdentity() {
        XCTAssertNotEqual(
            CrewFeedLoadKey(zoneId: "nolita", userId: deletedUser),
            CrewFeedLoadKey(zoneId: "nolita", userId: newUser),
            "an identity change must re-run the crew feed's .task"
        )
        XCTAssertEqual(
            CrewFeedLoadKey(zoneId: "nolita", userId: newUser),
            CrewFeedLoadKey(zoneId: "nolita", userId: newUser)
        )
    }
}

@MainActor
final class AccountDeletionRegularsResetTests: XCTestCase {

    private func makeService() -> RegularsService {
        RegularsService(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseAnonKey: "anon-key-test"
        )
    }

    private func edge() -> RegularEdge {
        RegularEdge(lowUserId: UUID(), highUserId: UUID(), createdAt: Date())
    }

    func testResetForAccountDeletion_clearsPerUserGraph() {
        let service = makeService()
        service.inject(edges: [edge(), edge()])
        XCTAssertEqual(service.edges.count, 2)

        service.resetForAccountDeletion()

        XCTAssertTrue(service.edges.isEmpty)
        XCTAssertTrue(service.notices.isEmpty)
        XCTAssertNil(service.edgesFetchError)
        XCTAssertNil(service.noticesFetchError)
        XCTAssertFalse(service.isLoadingEdges)
        XCTAssertFalse(service.isLoadingNotices)
    }

    func testAccountDeletedNotification_resetsRegularsService() async {
        let service = makeService()
        service.inject(edges: [edge()])

        NotificationCenter.default.post(name: .weParkAccountDeleted, object: nil)

        // The observer delivers on the main queue; give it a moment.
        var spins = 0
        while !service.edges.isEmpty && spins < 100 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            spins += 1
        }
        XCTAssertTrue(service.edges.isEmpty, "the deleted account's trust graph must not survive deletion")
    }
}
