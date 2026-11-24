//
//  SpotPassLink.swift
//  Shared/SpotPass
//
//  Parses the Spot Pass invocation / universal-link URL (spec §3, §5.3, §8):
//    https://getwepark.com/p#t=<token>     (primary: the fragment never reaches a server)
//    https://getwepark.com/p?t=<token>     (fallback form)
//    https://getwepark.com/p  or /p/...    (generic landing, no token)
//  Pure and offline. A recognised link with a missing or malformed token still parses (token ==
//  nil) so callers show the generic landing; bad tokens are never distinguishable from absent.
//

import Foundation

nonisolated struct SpotPassLink: Equatable, Hashable, Sendable {

    /// The 22-character base64url pass token (128 bits), or nil for the generic landing.
    let token: String?

    /// Token length: 128 bits in unpadded base64url.
    static let tokenLength = 22

    /// Parses `url`; returns nil unless it is `https://<SpotPassShared.universalLinkHost>/p[/...]`.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == SpotPassShared.universalLinkHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let path = components.path
        let landing = SpotPassShared.landingPath
        guard path == landing || path.hasPrefix(landing + "/") else { return nil }

        // Fragment form first (`#t=<token>`), then the query fallback (`?t=<token>`).
        var candidate: String?
        if let fragment = components.fragment,
           let fragmentItems = URLComponents(string: "?" + fragment)?.queryItems {
            candidate = fragmentItems.first(where: { $0.name == "t" })?.value
        }
        if candidate == nil {
            candidate = components.queryItems?.first(where: { $0.name == "t" })?.value
        }

        if let candidate, Self.isValidToken(candidate) {
            token = candidate
        } else {
            token = nil
        }
    }

    /// True for exactly 22 characters of `[A-Za-z0-9_-]`.
    static func isValidToken(_ value: String) -> Bool {
        guard value.utf8.count == tokenLength else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }
}
