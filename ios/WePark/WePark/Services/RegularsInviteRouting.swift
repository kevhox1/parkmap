//
//  RegularsInviteRouting.swift
//  WePark
//
//  Regulars network — S7 (iOS UI session). Spec: docs/regulars-network-spec.md §3.2 (invite
//  URL shape, countdown, redemption confirm copy), §2.4 (`redeem_regular_invite`'s four
//  terminal states). Sequencing: docs/regulars-roadmap.md, session S7.
//
//  Pure, view-free decision logic — same house style as `RealtimeMergeGate`/
//  `CommunityPushRelevance`/`CrewFeedMerge`: split testable logic from the SwiftUI view that
//  consumes it, so every branch below is directly unit-testable without hosting a view.
//
//  What lives here:
//   - `RegularsInviteLink` — builds/parses `wepark://invite/<uuid>` (spec §2.4's locked URL
//     shape: "the row's own id IS the token embedded in both the QR code and the share link").
//     `parse(_:)` is deliberately strict: wrong scheme, wrong host, a malformed/non-UUID token,
//     or extra path segments all resolve to `nil` — a "foreign" URL (e.g. a plain https link, or
//     someone else's custom scheme) must never be silently treated as a valid invite.
//   - `InviteCountdown` — the "expires in 9:47" countdown math (spec §3.2), computed against an
//     explicit `now: Date` parameter throughout — no `Date()`/`Calendar.current` internally, so
//     every test below runs against a fixed clock.
//   - `RegularInviteRedemptionCopy` — maps each of `redeem_regular_invite`'s four terminal states
//     (`RegularInviteRedeemResult`, `Models/Regular.swift`) to on-screen copy. Every string here
//     was checked by hand against this session's banned-word list (avoid, ticket, fine, evasion,
//     dodge) — none appear, matching the dispatch's explicit "honest, non-punitive copy"
//     requirement for `expiredOrUsed`/`cannotAddSelf`/`blocked`.
//
//  KNOWN, FLAGGED CONSTRAINT (not silently worked around — see this file's own note on
//  `preConfirmCopy` below): spec §3.2 sketches the PRE-confirm sheet as naming the inviter
//  ("Dave wants to add you as a Regular — add them back?"), but `regular_invites_select_own`
//  (`07-regulars-schema.sql` §S1-4) restricts SELECT on that table to `created_by = auth.uid()`
//  — a redeeming session has no RLS-permitted way to read the invite row (and therefore the
//  inviter's identity) BEFORE calling `redeem_regular_invite`, which is the only thing that
//  proves consent and unlocks the response's own `regular_id`. `preConfirmCopy` below is
//  therefore deliberately generic (no name) rather than fabricating a name from data this
//  client cannot have — flagged in this session's PR description as a spec-vs-schema gap for
//  the orchestrator, not silently substituted. Post-SUCCESS copy (`resultCopy` for `.success`)
//  DOES have `regular_id` from the RPC's own response and can be personalized once a profile
//  lookup resolves it (see `RegularInviteRedemptionView`).
//
//  No Calendar.current. No hardcoded Supabase secrets.
//

import Foundation

// MARK: - RegularsInviteLink

/// Builds and parses the `wepark://invite/<uuid>` deep link (spec §2.4/§3.2, decision 5 — "both
/// QR and share link, same underlying token").
enum RegularsInviteLink {

    /// The registered custom URL scheme (`Info.plist`'s `CFBundleURLTypes` — see this session's
    /// PR description for the one-time Xcode-project verification Kevin's gate covers).
    static let scheme = "wepark"

    /// The deep link's host component. `wepark://invite/<uuid>` parses as scheme="wepark",
    /// host="invite", path="/<uuid>" — NOT a path-only scheme (`wepark:///invite/<uuid>` would
    /// parse differently, with an empty host and "/invite/<uuid>" as the path); this constant
    /// and `build(token:)`/`parse(_:)` below all agree on the host-based shape.
    static let invitePathHost = "invite"

    /// Builds the canonical invite URL for a given token — the exact string rendered into the
    /// QR code (`RegularInviteView.qrCodeImage(from:)`) and the `ShareLink` payload alike (spec
    /// decision 5: one token, two presentations). `nonisolated` — pure, directly unit-testable
    /// from a plain (non-`async`, non-`@MainActor`) XCTest method without a `MainActor` hop, same
    /// posture as `RegularsService.makeDateDecodingJSONDecoder()`/`IdentitySheet.resolvedUsername`
    /// under this target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting.
    nonisolated static func build(token: UUID) -> URL {
        // Force-unwrap is safe: `token.uuidString` contains only characters (hex digits and
        // hyphens) that are always valid, unescaped path characters in a URL — this can never
        // fail to parse. Mirrors this codebase's existing "known-safe interpolated URL string"
        // precedent (e.g. `RegularsService.buildRequest`'s own `supabaseURL.appendingPathComponent`
        // calls) rather than threading an `Optional` through a construction that cannot fail.
        URL(string: "\(scheme)://\(invitePathHost)/\(token.uuidString)")!
    }

    /// Parses a URL that may or may not be a valid WePark invite link. Returns `nil` for
    /// anything that isn't EXACTLY `wepark://invite/<uuid>` (case-insensitive scheme/host, per
    /// `URL`'s own RFC 3986 comparison rules) — a wrong scheme, wrong host, missing/extra path
    /// segments, or a non-UUID token all reject rather than guess.
    ///
    /// - Parameter url: Any URL, including a "foreign" one (a plain `https://` link, a
    ///   different app's custom scheme, or a malformed WePark-looking link).
    /// - Returns: The invite token, or `nil` if `url` is not a valid WePark invite link.
    /// `nonisolated` — see `build(token:)`'s own doc comment for why.
    nonisolated static func parse(_ url: URL) -> UUID? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else { return nil }
        guard url.host?.caseInsensitiveCompare(invitePathHost) == .orderedSame else { return nil }

        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 1, let token = UUID(uuidString: segments[0]) else { return nil }
        return token
    }

    /// Combines `parse(_:)` with the `regularsEnabled` flag check `WeParkApp.onOpenURL` must
    /// perform before ever presenting `RegularInviteRedemptionView` — pulled out as its own
    /// pure, `nonisolated` function so this entry point's flag-off/foreign-URL guard is directly
    /// unit-testable without hosting a live `WeParkApp` scene (SwiftUI `View`/`App` bodies aren't
    /// hosted anywhere in this test target). `enabled` defaults to the real
    /// `AppConstants.regularsEnabled` flag for the production call site (`WeParkApp.swift`);
    /// tests pass an explicit value to exercise both branches, mirroring
    /// `AppConstants.regularsSettingsRowVisible(enabled:)`'s own default-parameter pattern.
    ///
    /// - Returns: `nil` whenever EITHER `enabled` is `false` OR `url` doesn't parse as a valid
    ///   invite link — a caller never needs to check the flag itself once it has called this.
    nonisolated static func resolveRedemptionToken(from url: URL, enabled: Bool = AppConstants.regularsEnabled) -> UUID? {
        guard enabled else { return nil }
        return parse(url)
    }
}

// MARK: - InviteCountdown

/// The invite sheet's "expires in 9:47" countdown (spec §3.2, 10-minute TTL per
/// `regular_invites.expires_at`'s server-side `default (now() + interval '10 minutes')`).
enum InviteCountdown {

    /// Seconds remaining until `expiresAt`, clamped to zero (never negative) — an already-past
    /// `expiresAt` reads as "0 seconds left," not a negative countdown. `nonisolated` — pure,
    /// directly unit-testable from a plain XCTest method (same reasoning as
    /// `RegularsInviteLink.build(token:)`'s own doc comment).
    nonisolated static func remainingSeconds(expiresAt: Date, now: Date) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// `true` once `remainingSeconds(expiresAt:now:) == 0` — the countdown view switches to an
    /// "Expired" state and its "regenerate" affordance at this point.
    nonisolated static func isExpired(expiresAt: Date, now: Date) -> Bool {
        remainingSeconds(expiresAt: expiresAt, now: now) <= 0
    }

    /// Formats remaining seconds as `m:ss` (e.g. "9:47", "0:03") — matches spec §3.2's own
    /// worked example verbatim ("a visible 'expires in 9:47' countdown"). Returns "Expired" at
    /// zero rather than "0:00", since the invite is no longer valid at that point, not merely
    /// displaying a boundary value.
    nonisolated static func formatted(remainingSeconds: Int) -> String {
        guard remainingSeconds > 0 else { return "Expired" }
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - RegularInviteRedeemResult convenience

extension RegularInviteRedeemResult {
    /// `true` only for `.success` — a case-agnostic check so a view can branch on "did this
    /// work" without pattern-matching an associated value it doesn't need (e.g. choosing which
    /// SF Symbol to show). `Equatable`'s synthesized `==` can't be used for this directly: it
    /// would require constructing a throwaway `.success(regularId: someUUID)` to compare
    /// against, which is fragile (any real, non-matching UUID makes the comparison `false`).
    /// `nonisolated` — pure, directly unit-testable from a plain XCTest method.
    nonisolated var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - RegularInviteRedemptionCopy

/// Maps `redeem_regular_invite`'s four terminal states (`RegularInviteRedeemResult`) to on-screen
/// copy for the redemption confirm surface (`RegularInviteRedemptionView`). Every string below
/// was hand-checked against this session's banned-word list: avoid, ticket, fine, evasion, dodge
/// — none appear in any case.
enum RegularInviteRedemptionCopy {

    /// The BEFORE-redemption confirm sheet's copy — deliberately generic, no inviter name. See
    /// this file's header for why (the redeeming session cannot read the invite row, or
    /// therefore the inviter's identity, before calling the RPC).
    static let preConfirmTitle = "Add this neighbor as a Regular?"
    static let preConfirmBody =
        "Someone shared this invite with you. Regulars can hand off their spot to you first and " +
        "send you quick heads-ups when they're moving their car. Only add people you actually know."
    static let preConfirmActionTitle = "Add as a Regular"
    static let preConfirmCancelTitle = "Not now"

    /// Copy for one of the four RPC result states. `regularHandle` is non-`nil` only for
    /// `.success` when a profile lookup for `regularId` resolved in time (see
    /// `RegularInviteRedemptionView`) — falls back to generic phrasing otherwise, never blocks
    /// on the lookup. `nonisolated` — pure, directly unit-testable from a plain XCTest method.
    nonisolated static func resultCopy(for result: RegularInviteRedeemResult, regularHandle: String?) -> (title: String, body: String) {
        switch result {
        case .success:
            if let regularHandle {
                return ("You're Regulars now", "You and \(regularHandle) can hand off spots and send each other quick heads-ups.")
            }
            return ("You're Regulars now", "You added a new Regular. You can hand off spots and send each other quick heads-ups.")
        case .expiredOrUsed:
            return (
                "This invite isn't available anymore",
                "It's already been used or the 10-minute window closed. Ask them to share a new one."
            )
        case .cannotAddSelf:
            return (
                "That's your own invite",
                "Share this link or QR code with someone else to add them as a Regular."
            )
        case .blocked:
            return (
                "This invite can't be used",
                "You and this person aren't able to connect as Regulars right now."
            )
        }
    }
}
