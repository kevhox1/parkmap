//
//  HandoffActivityController.swift
//  Shared/SpotPass/Driver
//
//  The driver's lock-screen countdown (spec 7.2). Started in the FOREGROUND before the claim call
//  (`pushType: .token`) because `handoff-claim` is the only place the backend learns the activity
//  push token, so the activity must exist first; it is ended again if the claim fails.
//  Clips can only start Live Activities through the Live-Activities-only extension target.
//

import ActivityKit
import Foundation

nonisolated enum HandoffActivityContent {

    /// Hex string for an APNs-style token (what `handoff-claim` validates: `[0-9a-f]{32,1000}`).
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Content state for a phase. The countdown is stale at `leaveAt` so the lock screen swaps to
    /// "Time to go?" without any update (a Live Activity cannot self-update).
    static func state(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?) -> SpotPassActivityAttributes.ContentState {
        SpotPassActivityAttributes.ContentState(phase: phase, leaveAt: leaveAt, startedAt: startedAt)
    }

    static func staleDate(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?) -> Date? {
        phase == .counting ? leaveAt : nil
    }

    /// How long a finished activity lingers on the lock screen (thanks: 10 min, per the backend push).
    static func dismissal(for phase: SpotPassActivityAttributes.Phase, now: Date) -> Date {
        switch phase {
        case .thanks: return now.addingTimeInterval(600)
        case .passed: return now.addingTimeInterval(1800)
        default: return now
        }
    }
}

@MainActor
protocol HandoffActivityControlling: AnyObject {
    /// `ActivityAuthorizationInfo().areActivitiesEnabled`.
    var areActivitiesEnabled: Bool { get }
    /// Called when a push-to-end changes the phase while the clip is running.
    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)? { get set }
    /// Starts the activity; returns its push token (hex) if it arrived in time. Returns nil token
    /// when it could not start or the token timed out. `didStart` tells whether an activity exists.
    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?)
    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?) async
    func end(phase: SpotPassActivityAttributes.Phase, now: Date) async
}

@MainActor
final class ActivityKitHandoffActivityController: HandoffActivityControlling {

    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)?
    private var observer: Task<Void, Never>?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var current: Activity<SpotPassActivityAttributes>? {
        Activity<SpotPassActivityAttributes>.activities.first
    }

    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?) {
        guard areActivitiesEnabled else { return (false, nil) }
        // One activity at a time.
        for existing in Activity<SpotPassActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = SpotPassActivityAttributes(alias: name, glyph: glyph, isClip: true)
        let state = HandoffActivityContent.state(phase: .counting, leaveAt: leaveAt, startedAt: startedAt)
        let content = ActivityContent(state: state, staleDate: leaveAt)
        guard let activity = try? Activity.request(attributes: attributes, content: content, pushType: .token) else {
            return (false, nil)
        }
        observe(activity)
        let token = await Self.firstToken(of: activity)
        return (true, token)
    }

    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?) async {
        guard let activity = current else { return }
        let state = HandoffActivityContent.state(phase: phase, leaveAt: leaveAt, startedAt: startedAt)
        await activity.update(ActivityContent(state: state, staleDate: HandoffActivityContent.staleDate(phase: phase, leaveAt: leaveAt)))
    }

    func end(phase: SpotPassActivityAttributes.Phase, now: Date) async {
        observer?.cancel()
        guard let activity = current else { return }
        let state = HandoffActivityContent.state(phase: phase, leaveAt: nil, startedAt: nil)
        let policy: ActivityUIDismissalPolicy = phase == .cancelled || phase == .ended
            ? .immediate : .after(HandoffActivityContent.dismissal(for: phase, now: now))
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
    }

    private func observe(_ activity: Activity<SpotPassActivityAttributes>) {
        observer?.cancel()
        observer = Task { [weak self] in
            for await state in activity.contentStateUpdates {
                self?.onRemotePhase?(state.phase)
            }
        }
    }

    private static func firstToken(of activity: Activity<SpotPassActivityAttributes>) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await data in activity.pushTokenUpdates { return HandoffActivityContent.hex(data) }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
