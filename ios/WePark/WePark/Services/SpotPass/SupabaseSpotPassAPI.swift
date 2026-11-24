//
//  SupabaseSpotPassAPI.swift
//  Services/SpotPass
//
//  Spot Pass C1: the live `SpotPassAPI`. Same plumbing as `AccountDeletionService` and
//  `PushRegistrationService`: plain PostgREST over `URLSession` with the anon key as `apikey` and
//  the anonymous session's JWT as `Authorization`, reading `SUPABASE_URL` / `SUPABASE_ANON_KEY`
//  from Info.plist (Config.xcconfig bridge). No new SDK dependency.
//
//  Contract (spec §8): RPC argument names are exactly `show_name`, `id`, `outcome`.
//

import Foundation

@MainActor
final class SupabaseSpotPassAPI: SpotPassAPI {

    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let urlSession: URLSession
    private let session: any AccountSessionProviding
    private let now: () -> Date

    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared,
        session: any AccountSessionProviding,
        now: @escaping () -> Date = { Date() }
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.session = session
        self.now = now
    }

    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Bundle.main`, identical to
    /// `AccountDeletionService` / `PushRegistrationService`.
    convenience init(authService: SupabaseAuthService) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, session: authService)
    }

    // MARK: - SpotPassAPI

    func createHandoff(showName: Bool) async throws -> SpotPassSession {
        let data = try await send(
            Self.rpcRequest(
                baseURL: supabaseURL, anonKey: supabaseAnonKey, jwt: try await jwt(),
                function: "create_handoff", arguments: ["show_name": showName]
            )
        )
        return try SpotPassWire.decodeCreated(data, now: now())
    }

    func cancelHandoff(id: UUID) async throws {
        _ = try await send(
            Self.rpcRequest(
                baseURL: supabaseURL, anonKey: supabaseAnonKey, jwt: try await jwt(),
                function: "cancel_handoff", arguments: ["id": id.uuidString.lowercased()]
            )
        )
    }

    func confirmHandoffOutcome(id: UUID, outcome: SpotPassOutcome) async throws -> SpotPassConfirmResult {
        let data = try await send(
            Self.rpcRequest(
                baseURL: supabaseURL, anonKey: supabaseAnonKey, jwt: try await jwt(),
                function: "confirm_handoff_outcome",
                arguments: ["id": id.uuidString.lowercased(), "outcome": outcome.rawValue]
            )
        )
        return try SpotPassWire.decodeConfirm(data)
    }

    func fetchStatus(id: UUID) async throws -> SpotPassSnapshot {
        let data = try await send(
            Self.statusRequest(
                baseURL: supabaseURL, anonKey: supabaseAnonKey, jwt: try await jwt(), id: id
            )
        )
        return try SpotPassWire.decodeSnapshot(data)
    }

    func fetchKarma() async throws -> SpotPassKarma {
        let data = try await send(
            Self.rpcRequest(
                baseURL: supabaseURL, anonKey: supabaseAnonKey, jwt: try await jwt(),
                function: "get_my_handoff_karma", arguments: [:]
            )
        )
        return try SpotPassWire.decodeKarma(data)
    }

    func fetchUsername() async throws -> String? {
        guard let snapshot = await session.currentSessionSnapshot() else {
            throw SpotPassAPIError.notSignedIn
        }
        let data = try await send(
            Self.usernameRequest(
                baseURL: supabaseURL, anonKey: supabaseAnonKey,
                jwt: snapshot.accessToken, userId: snapshot.userId
            )
        )
        return SpotPassWire.decodeUsername(data)
    }

    // MARK: - Request builders (pure, unit-tested; no network)

    nonisolated static func rpcRequest(
        baseURL: URL,
        anonKey: String,
        jwt: String,
        function: String,
        arguments: [String: Any]
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("rest/v1/rpc/\(function)")
        var request = baseRequest(url: url, method: "POST", anonKey: anonKey, jwt: jwt)
        guard let body = try? JSONSerialization.data(withJSONObject: arguments) else {
            throw SpotPassAPIError.malformedResponse
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// `GET /rest/v1/spot_handoffs?id=eq.<id>&select=id,status,leave_at,expires_at,departed_at,outcome` (named columns only: `select *` is denied by the column grants)
    nonisolated static func statusRequest(
        baseURL: URL,
        anonKey: String,
        jwt: String,
        id: UUID
    ) throws -> URLRequest {
        try tableRequest(
            baseURL: baseURL, anonKey: anonKey, jwt: jwt, table: "spot_handoffs",
            filterColumn: "id", filterValue: id.uuidString.lowercased(),
            select: "id,status,leave_at,expires_at,departed_at,outcome"
        )
    }

    /// `GET /rest/v1/profiles?id=eq.<uid>&select=username`
    nonisolated static func usernameRequest(
        baseURL: URL,
        anonKey: String,
        jwt: String,
        userId: UUID
    ) throws -> URLRequest {
        try tableRequest(
            baseURL: baseURL, anonKey: anonKey, jwt: jwt, table: "profiles",
            filterColumn: "id", filterValue: userId.uuidString.lowercased(),
            select: "username"
        )
    }

    private nonisolated static func tableRequest(
        baseURL: URL,
        anonKey: String,
        jwt: String,
        table: String,
        filterColumn: String,
        filterValue: String,
        select: String
    ) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: filterColumn, value: "eq.\(filterValue)"),
            URLQueryItem(name: "select", value: select)
        ]
        guard let url = components?.url else { throw SpotPassAPIError.malformedResponse }
        return baseRequest(url: url, method: "GET", anonKey: anonKey, jwt: jwt)
    }

    private nonisolated static func baseRequest(
        url: URL,
        method: String,
        anonKey: String,
        jwt: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Plumbing

    private func jwt() async throws -> String {
        guard let token = await session.validAccessToken() else { throw SpotPassAPIError.notSignedIn }
        return token
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            throw Self.map(urlError: error)
        } catch {
            throw SpotPassAPIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw SpotPassAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.map(statusCode: http.statusCode)
        }
        return data
    }

    /// Every transport-level failure is "no connection" to the seeker (design §9.5 copy).
    nonisolated static func map(urlError: URLError) -> SpotPassAPIError {
        .offline
    }

    nonisolated static func map(statusCode: Int) -> SpotPassAPIError {
        switch statusCode {
        case 401: return .notSignedIn
        case 404: return .notFound
        default: return .rejected(statusCode: statusCode)
        }
    }
}
