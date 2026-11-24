//
//  HandoffDriverAPI.swift
//  Shared/SpotPass/Driver
//
//  The driver-side API (peek / claim / depart / extend / cancel / report) as a protocol plus the
//  live `URLSession` implementation. Plain `URLSession` to the edge functions, no Supabase SDK
//  (keeps the clip small, spec section 5.1). Never logs a request or response.
//

import Foundation

@MainActor
protocol HandoffDriverAPI: AnyObject {
    func peek(token: String) async throws -> HandoffPeekResult
    /// `userJWT` is the clip's anonymous session (optional; without it the pass arms but earns no karma).
    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult
    /// Returns the server's `ok`. A RETRY returning false means "may already be sent".
    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool
    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult
    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool
    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool
}

@MainActor
final class URLSessionHandoffDriverAPI: HandoffDriverAPI {

    private let baseURL: URL
    private let anonKey: String
    private let urlSession: URLSession

    init(baseURL: URL, anonKey: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.urlSession = urlSession
    }

    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from the bundle (Config.xcconfig bridge).
    convenience init?(bundle: Bundle = .main) {
        guard let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: urlString), url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String, !key.isEmpty
        else { return nil }
        self.init(baseURL: url, anonKey: key)
    }

    func peek(token: String) async throws -> HandoffPeekResult {
        try HandoffWire.decodePeek(try await post("handoff-peek", ["token": token]))
    }

    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult {
        try HandoffWire.decodeClaim(try await post("handoff-claim", HandoffWire.claimBody(request), userJWT: userJWT))
    }

    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool {
        let body = HandoffWire.securedBody(id: id, secret: secret, extra: ["source": source.rawValue])
        return try HandoffWire.decodeOK(try await post("handoff-depart", body))
    }

    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult {
        try HandoffWire.decodeExtend(try await post("handoff-extend", HandoffWire.securedBody(id: id, secret: secret)))
    }

    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool {
        try HandoffWire.decodeOK(try await post("handoff-cancel", HandoffWire.securedBody(id: id, secret: secret)))
    }

    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool {
        try HandoffWire.decodeOK(try await post("handoff-report", HandoffWire.reportBody(target: target, reason: reason)))
    }

    // MARK: Request building (pure, unit-tested)

    nonisolated static func request(
        baseURL: URL, anonKey: String, function: String, body: [String: Any], userJWT: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/\(function)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw HandoffAPIError.malformedResponse
        }
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let userJWT { request.setValue("Bearer \(userJWT)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func post(_ function: String, _ body: [String: Any], userJWT: String? = nil) async throws -> Data {
        let request = try Self.request(baseURL: baseURL, anonKey: anonKey, function: function, body: body, userJWT: userJWT)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw HandoffAPIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw HandoffAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HandoffWire.error(forStatus: http.statusCode, body: data)
        }
        return data
    }
}
