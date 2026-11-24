//
//  SpotPassPush.swift
//  Services/SpotPass
//
//  Spot Pass C1: the seeker's push hook (`docs/specs/qr-spot-handoff.md` §7.1: `send-handoff-push`
//  kinds `armed` and `departed` are alerts to the seeker).
//
//  A push never carries state the app trusts. It only says "something changed": the store reacts by
//  refreshing from the server (the poll is the truth). So a missing, late or forged push cannot
//  put the seeker in a wrong state.
//
//  PAYLOAD (assumed; the backend payload shape is not in the §8 contract, see the PR's known
//  gaps): custom keys `handoff_kind` (or `kind`) in { armed, departed, thanks, handoff_ended } and
//  an optional `handoff_id`. Parsing is tolerant; unknown payloads are ignored.
//
//  Inert while `AppConstants.spotHandoffEnabled` is false: `SpotPassPushRouter.handle` returns
//  before touching anything.
//

import Foundation

nonisolated enum SpotPassPushKind: String, Equatable, Sendable {
    case armed
    case departed
    case thanks
    case handoffEnded = "handoff_ended"
}

nonisolated struct SpotPassPushEvent: Equatable, Sendable {
    let kind: SpotPassPushKind
    let handoffID: UUID?
    /// True when the user tapped the notification (open the pass), false for a foreground or
    /// silent delivery (just refresh).
    let opened: Bool

    /// Parses a notification's `userInfo`. Returns nil for anything that is not a Spot Pass push.
    static func parse(userInfo: [AnyHashable: Any], opened: Bool) -> SpotPassPushEvent? {
        let rawKind = (userInfo["handoff_kind"] as? String) ?? (userInfo["kind"] as? String)
        guard let rawKind, let kind = SpotPassPushKind(rawValue: rawKind) else { return nil }
        let id = (userInfo["handoff_id"] as? String).flatMap(UUID.init(uuidString:))
        return SpotPassPushEvent(kind: kind, handoffID: id, opened: opened)
    }
}

extension Notification.Name {
    /// Posted (main thread) with a `SpotPassPushEvent` as `object` when a Spot Pass push arrives.
    nonisolated static let spotPassPushReceived = Notification.Name("wepark.spotPass.pushReceived")
}

/// Buffers an event that arrived before the UI could handle it (cold-launch notification tap),
/// same buffer-then-drain shape as `SpotPassLinkInbox`.
@MainActor
final class SpotPassPushInbox {
    static let shared = SpotPassPushInbox()
    var pending: SpotPassPushEvent?
    init() {}
}

@MainActor
enum SpotPassPushRouter {

    /// Routes a notification payload. Returns true only if it was a Spot Pass push AND the feature
    /// is enabled.
    @discardableResult
    static func handle(
        userInfo: [AnyHashable: Any],
        opened: Bool,
        enabled: Bool = AppConstants.spotHandoffEnabled,
        inbox: SpotPassPushInbox = .shared,
        center: NotificationCenter = .default
    ) -> Bool {
        guard enabled, let event = SpotPassPushEvent.parse(userInfo: userInfo, opened: opened) else {
            return false
        }
        inbox.pending = event
        center.post(name: .spotPassPushReceived, object: event)
        return true
    }
}
