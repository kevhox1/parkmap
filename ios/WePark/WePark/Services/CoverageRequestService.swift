//
//  CoverageRequestService.swift
//  WePark
//
//  Open item #39 — "Suggest a neighborhood" (the out-of-coverage demand signal).
//  Contract: `supabase/11-coverage-requests.sql` header ("THE iOS CONTRACT"). Dark-shipped
//  behind `AppConstants.coverageRequestsEnabled` (this file is inert until a view calls it).
//
//  Wire shape: `POST /rest/v1/coverage_requests`, authenticated role only (the app's anonymous
//  auth session counts), body `{city, note?, viewed_lat?, viewed_lng?}` — and ONLY those four
//  columns (sending `user_id` / `id` / `created_at` is rejected 42501; `user_id` is filled by
//  the database from the JWT).
//
//  !!! `Prefer: return=minimal` — NOT `return=representation`. !!!
//  Every other write path in this codebase (`CommunityPinService` and friends) sends
//  `return=representation`. Copy-pasting that here fails with 42501 on EVERY insert, even a
//  valid one: clients have no SELECT on this table by design, and an INSERT ... RETURNING needs
//  SELECT access to the written row. Success is any 2xx with no body to decode.
//  (Pinned by `CoverageRequestTests.testSubmit_sendsReturnMinimal...`.)
//
//  Validation mirrors the SQL so users get an inline message instead of a 4xx:
//    city: trimmed of the blank/invisible class (below), 2...80 characters, where the MINIMUM is
//          counted over VISIBLE characters (blank class removed everywhere) and the MAXIMUM over
//          all characters of the trimmed string. `char_length` counts Unicode code points, so
//          this counts `unicodeScalars`, not grapheme clusters (an emoji family is several
//          code points; the server would count them the same way).
//    note: optional, trimmed, <= 500 code points; empty/whitespace-only is omitted (server
//          stores NULL).
//  The blank class below must stay IDENTICAL to `v_blank` in 11-coverage-requests.sql.
//
//  Coarse location: `viewed_lat` / `viewed_lng` identify the VIEWED AREA (the map centre /
//  the searched destination), never the user's GPS fix, and are rounded to 2 decimals here
//  (~1 km) — the server rounds again; we simply never send more precision than needed. Both
//  or neither (a half pair violates a CHECK).
//
//  Errors (`CoverageRequestError`): any 42501 whose message begins "rate limit exceeded" maps to
//  ONE neutral, non-blaming message — the global backstop cap can trip for reasons that are not
//  this user's doing, so the per-user vs global texts are deliberately NOT distinguished.
//
//  Pure helpers are `nonisolated` (the target defaults to MainActor). No Calendar.current, no
//  SwiftUI, no logging of user-entered text.
//
//  [COMPILE-UNVERIFIED] Written on a Linux VPS with no Swift toolchain.
//

import Foundation

// MARK: - CoverageRequestDraft

/// What the form hands to the submitter (already normalized by `CoverageRequestRules`).
nonisolated struct CoverageRequestDraft {
    let city: String
    let note: String?
    let viewedLatitude: Double?
    let viewedLongitude: Double?
}

// MARK: - CoverageRequestRules

/// Client-side mirror of `11-coverage-requests.sql`'s validation. Pure; no state.
nonisolated enum CoverageRequestRules {

    nonisolated static let cityMinVisibleCharacters = 2
    nonisolated static let cityMaxCharacters = 80
    nonisolated static let noteMaxCharacters = 500

    /// User-facing inline messages.
    nonisolated static let cityTooShortMessage = "Enter at least 2 characters for the neighborhood or city."
    nonisolated static let cityTooLongMessage = "Please keep the name to 80 characters or fewer."
    nonisolated static let noteTooLongMessage = "Please keep your note to 500 characters or fewer."

    /// `true` for the SQL's blank/invisible class: tab/newline/CR (U+0009-000D), space, NEL,
    /// NBSP, soft hyphen, Ogham space, Mongolian vowel separator, U+2000-200F, U+2028-202F,
    /// U+205F-206F, ideographic space, BOM.
    nonisolated static func isBlankScalarValue(_ value: UInt32) -> Bool {
        switch value {
        case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x00AD, 0x1680, 0x180E,
             0x2000...0x200F, 0x2028...0x202F, 0x205F...0x206F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Strips leading and trailing blank/invisible characters (the server's trim).
    nonisolated static func trimmed(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end && isBlankScalarValue(scalars[start].value) {
            start += 1
        }
        while end > start && isBlankScalarValue(scalars[end - 1].value) {
            end -= 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start..<end])
        return String(view)
    }

    /// Code points of the trimmed text (`char_length` equivalent).
    nonisolated static func characterCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Code points that are NOT in the blank class (the check constraint's visible count).
    nonisolated static func visibleCharacterCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where !isBlankScalarValue(scalar.value) {
            count += 1
        }
        return count
    }

    /// The city as it will be sent.
    nonisolated static func normalizedCity(_ raw: String) -> String {
        trimmed(raw)
    }

    /// The note as it will be sent, or nil when empty after trimming.
    nonisolated static func normalizedNote(_ raw: String) -> String? {
        let value = trimmed(raw)
        return value.isEmpty ? nil : value
    }

    /// Inline message for the city field, or nil if it is acceptable. An EMPTY field returns
    /// nil here (the Submit button is simply disabled; an error on an untouched field is noise)
    /// — use `isCityAcceptable` for the submit gate.
    nonisolated static func cityIssueMessage(_ raw: String) -> String? {
        let city = normalizedCity(raw)
        if city.isEmpty { return nil }
        if characterCount(city) > cityMaxCharacters { return cityTooLongMessage }
        if visibleCharacterCount(city) < cityMinVisibleCharacters { return cityTooShortMessage }
        return nil
    }

    /// Inline message for the note field, or nil if acceptable.
    nonisolated static func noteIssueMessage(_ raw: String) -> String? {
        let note = trimmed(raw)
        if characterCount(note) > noteMaxCharacters { return noteTooLongMessage }
        return nil
    }

    /// `true` when the city satisfies the server's check (2+ visible, <= 80 total).
    nonisolated static func isCityAcceptable(_ raw: String) -> Bool {
        let city = normalizedCity(raw)
        return characterCount(city) <= cityMaxCharacters
            && visibleCharacterCount(city) >= cityMinVisibleCharacters
    }

    /// Submit gate for the whole form.
    nonisolated static func isFormSubmittable(city: String, note: String) -> Bool {
        isCityAcceptable(city) && noteIssueMessage(note) == nil
    }

    /// Rounds a viewed-area coordinate component to 2 decimals (~1 km). Never sends more
    /// precision than the server keeps.
    nonisolated static func coarse(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// The coarse pair to send, or nil if either component is missing / non-finite / out of
    /// range (both or neither — a half pair violates a CHECK).
    nonisolated static func coarsePair(latitude: Double?, longitude: Double?) -> (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else {
            return nil
        }
        return (coarse(latitude), coarse(longitude))
    }

    /// Builds the normalized draft the submitter sends. `nil` if the form isn't submittable.
    nonisolated static func makeDraft(
        city: String,
        note: String,
        viewedLatitude: Double?,
        viewedLongitude: Double?
    ) -> CoverageRequestDraft? {
        guard isFormSubmittable(city: city, note: note) else { return nil }
        let pair = coarsePair(latitude: viewedLatitude, longitude: viewedLongitude)
        return CoverageRequestDraft(
            city: normalizedCity(city),
            note: normalizedNote(note),
            viewedLatitude: pair?.latitude,
            viewedLongitude: pair?.longitude
        )
    }
}

// MARK: - CoverageRequestError

nonisolated enum CoverageRequestError: Error {
    /// No valid session.
    case notSignedIn
    /// 42501 beginning "rate limit exceeded" (per-user OR global — deliberately not told apart).
    case rateLimited
    /// 23514 check violation (length / range) — the client-side rules should prevent this.
    case invalidInput
    /// Offline / timed out / connection dropped.
    case network
    /// Any other non-2xx.
    case serverRejected
}

nonisolated extension CoverageRequestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "We couldn't connect just yet. Please try again in a moment."
        case .rateLimited:
            return "We can't take suggestions right now \u{2014} please try again a little later."
        case .invalidInput:
            return "Please check the name and try again."
        case .network:
            return "We couldn't reach WePark. Check your connection and try again."
        case .serverRejected:
            return "We couldn't send that. Please try again."
        }
    }
}

// MARK: - CoverageRequestSubmitting

@MainActor
protocol CoverageRequestSubmitting: AnyObject {
    /// Sends one suggestion. Returns normally on any 2xx; throws `CoverageRequestError`.
    func submit(_ draft: CoverageRequestDraft) async throws
}

// MARK: - CoverageRequestService

@MainActor
final class CoverageRequestService: CoverageRequestSubmitting {

    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let urlSession: URLSession
    private let session: any WriteSessionProviding

    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared,
        session: any WriteSessionProviding
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.session = session
    }

    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Bundle.main` — identical to
    /// `PushRegistrationService`'s convenience init.
    convenience init(authService: SupabaseAuthService) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, session: authService)
    }

    // MARK: - Pure helpers

    /// The JSON body: ONLY the four client-writable columns; optional fields omitted when nil.
    nonisolated static func requestBody(for draft: CoverageRequestDraft) -> [String: Any] {
        var body: [String: Any] = ["city": draft.city]
        if let note = draft.note {
            body["note"] = note
        }
        if let lat = draft.viewedLatitude, let lng = draft.viewedLongitude {
            body["viewed_lat"] = lat
            body["viewed_lng"] = lng
        }
        return body
    }

    /// Maps a failed response to a `CoverageRequestError`. Looks at the PostgREST error body
    /// (`{"code","message",...}`), not the HTTP status: 42501 arrives as 401/403 depending on
    /// the role, and the contract keys off SQLSTATE.
    nonisolated static func mapError(forStatus status: Int, body: Data) -> CoverageRequestError {
        var code: String?
        var message: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            code = object["code"] as? String
            message = object["message"] as? String
        }
        if code == "42501", let message, message.hasPrefix("rate limit exceeded") {
            return .rateLimited
        }
        if code == "23514" {
            return .invalidInput
        }
        return .serverRejected
    }

    // MARK: - Submit

    func submit(_ draft: CoverageRequestDraft) async throws {
        guard let jwt = await session.validAccessToken() else {
            throw CoverageRequestError.notSignedIn
        }
        guard let body = try? JSONSerialization.data(withJSONObject: Self.requestBody(for: draft)) else {
            throw CoverageRequestError.invalidInput
        }

        var request = URLRequest(url: supabaseURL.appendingPathComponent("rest/v1/coverage_requests"))
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // return=MINIMAL, never return=representation — see this file's header.
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = body

        let result: (Data, URLResponse)
        do {
            result = try await urlSession.data(for: request)
        } catch {
            throw CoverageRequestError.network
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw CoverageRequestError.serverRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapError(forStatus: http.statusCode, body: data)
        }
    }
}
