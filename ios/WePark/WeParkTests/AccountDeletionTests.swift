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

    var currentUserId: UUID? { userId }

    func validAccessToken() async -> String? { token }

    func endSessionAfterAccountDeletion() async {
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

    private let lock = NSLock()
    private var listRequests: [URLRequest] = []
    private var removeRequests: [URLRequest] = []
    private var rpcRequests: [URLRequest] = []

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

    func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
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
            let result = rpcHandler()
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
}

@MainActor
private func acctDelMakeRig(token: String? = "jwt-test-token", userId: UUID? = acctDelUpperUUID) -> AcctDelRig {
    let log = AcctDelEventLog()
    let server = AcctDelServer(log: log)
    AcctDelMockURLProtocol.requestHandler = { request in server.handle(request) }
    let session = AcctDelFakeSession(token: token, userId: userId, log: log)
    let service = AccountDeletionService(
        supabaseURL: URL(string: "https://example.supabase.co")!,
        supabaseAnonKey: "anon-key-test",
        urlSession: acctDelMockSession(),
        session: session,
        clearLocalState: { log.append("clearLocal") }
    )
    return AcctDelRig(log: log, server: server, session: session, service: service)
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

        XCTAssertEqual(rig.log.events, ["list:\(root)@0", "remove:1", "rpc"])
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
