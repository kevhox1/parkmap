//
//  SpotPassLinkRouter.swift
//  Services
//
//  Spot Pass C0: the full app's universal-link route STUB (`docs/specs/qr-spot-handoff.md` §5.3,
//  §8). `https://getwepark.com/p[#t=<token>]` opens the app; with `AppConstants.spotHandoffEnabled`
//  `false` (the C0 state) `handle(_:)` returns immediately and touches nothing.
//
//  With the flag on, the parsed link is only parked in `SpotPassLinkInbox`. There is deliberately
//  NO presentation here: a second independent `.sheet` hit the single-host `activeSheet` problem
//  once already (see `ContentView.routeRegularsInviteRedemption`). C2 reads the inbox and presents
//  through `activeSheet`.
//

import Foundation

/// One-slot buffer for a link that arrived before the UI that handles it exists/is mounted
/// (same buffer-then-drain shape as `AppDelegate.pendingDeepLinkCarID`).
@MainActor
final class SpotPassLinkInbox {
    static let shared = SpotPassLinkInbox()

    /// The latest parsed link, until a consumer clears it.
    var pending: SpotPassLink?

    init() {}
}

@MainActor
enum SpotPassLinkRouter {

    /// Routes `url`. Returns true only if it was recognised AND accepted (flag on).
    /// `enabled` defaults to the real flag; tests pass both values explicitly.
    @discardableResult
    static func handle(
        _ url: URL,
        enabled: Bool = AppConstants.spotHandoffEnabled,
        inbox: SpotPassLinkInbox = .shared
    ) -> Bool {
        guard enabled, let link = SpotPassLink(url: url) else { return false }
        inbox.pending = link
        return true
    }
}
