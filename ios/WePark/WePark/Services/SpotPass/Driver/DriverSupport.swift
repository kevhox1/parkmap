//
//  DriverSupport.swift
//  Services/SpotPass/Driver
//
//  Spot Pass C2: the live collaborators of `DriverFlowController` (each behind a protocol so
//  tests inject fakes):
//    - `DriverKeychainSecretStore`  the claimer secret (spec 9 item 12): keychain only, never
//                                   UserDefaults/App Group, never logged. The app's OWN item,
//                                   separate from the clip's.
//    - `AppActivityController`      the full app's Live Activity (App Intent buttons).
//    - `DriverReminderScheduler`    the reminder notification (spec 7.3): actions run in the
//                                   BACKGROUND (no app launch), category registered merge-safe.
//    - `DriverReminderCategory`     the category + the pure action mapping.
//    - `AppNotificationPushToken`   the app's APNs token for the thank-you alert.
//

import ActivityKit
import Foundation
import Security
import UserNotifications

// MARK: - Secret store

@MainActor
final class DriverKeychainSecretStore: HandoffSecretStoring {

    nonisolated static let service = "com.kevinhoxha.wepark.spotpass.claimer-secret"
    /// Distinct label from the clip's `wepark-appclip` items (spec 6.2).
    nonisolated static let label = "wepark-spotpass"

    func save(_ secret: ClaimerSecret, passID: UUID) {
        clear()
        guard let data = secret.rawValue.data(using: .utf8) else { return }
        SecItemAdd(Self.addAttributes(passID: passID, data: data) as CFDictionary, nil)
    }

    func secret(for passID: UUID) -> ClaimerSecret? {
        var query = Self.baseQuery(passID: passID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let string = String(data: data, encoding: .utf8)
        else { return nil }
        return ClaimerSecret(string)
    }

    func clear() {
        SecItemDelete(Self.baseQuery(passID: nil) as CFDictionary)
    }

    // Pure query builders (unit-tested; the real keychain is not touched in tests).

    nonisolated static func baseQuery(passID: UUID?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let passID { query[kSecAttrAccount as String] = passID.uuidString.lowercased() }
        return query
    }

    nonisolated static func addAttributes(passID: UUID, data: Data) -> [String: Any] {
        var attributes = baseQuery(passID: passID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = label
        // Readable from a lock-screen intent / notification action after the first unlock; never synced.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }
}

// MARK: - Live Activity

@MainActor
final class AppActivityController: DriverActivityControlling {

    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)?
    private var observer: Task<Void, Never>?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var current: Activity<SpotPassActivityAttributes>? {
        Activity<SpotPassActivityAttributes>.activities.first
    }

    func adoptExisting() -> Bool {
        guard let activity = current else { return false }
        observe(activity)
        return true
    }

    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?) {
        guard areActivitiesEnabled else { return (false, nil) }
        for existing in Activity<SpotPassActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = SpotPassActivityAttributes(alias: name, glyph: glyph, isClip: false)
        let state = HandoffActivityContent.state(phase: .counting, leaveAt: leaveAt, startedAt: startedAt)
        let content = ActivityContent(state: state, staleDate: leaveAt)
        guard let activity = try? Activity.request(attributes: attributes, content: content, pushType: .token) else {
            return (false, nil)
        }
        observe(activity)
        let token = await Self.firstToken(of: activity)
        return (true, token)
    }

    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?, passID: UUID?) async {
        guard let activity = current else { return }
        let state = SpotPassActivityAttributes.ContentState(
            phase: phase, leaveAt: leaveAt, startedAt: startedAt, passID: passID?.uuidString.lowercased()
        )
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

// MARK: - Reminder category (pure)

nonisolated enum DriverReminderCategory {

    /// Same identifiers the clip uses (`HandoffReminderPlan`): the two processes never share a
    /// notification center, and the plan builder is shared.
    static var categoryID: String { HandoffReminderPlan.categoryID }

    /// Three BACKGROUND actions (spec 7.3: "App: actions are background-capable"): no app launch,
    /// no authentication required, none destructive (red means curb rules, design 6).
    static func category() -> UNNotificationCategory {
        let leaving = UNNotificationAction(
            identifier: HandoffReminderPlan.actionLeavingNow, title: ClipCopy.actionLeavingNow, options: [],
            icon: UNNotificationActionIcon(systemImageName: "car.fill")
        )
        let extend = UNNotificationAction(
            identifier: HandoffReminderPlan.actionExtend, title: ClipCopy.actionFiveMore, options: [],
            icon: UNNotificationActionIcon(systemImageName: "plus.circle")
        )
        let cancel = UNNotificationAction(
            identifier: HandoffReminderPlan.actionCancel, title: ClipCopy.actionNotLeaving, options: [],
            icon: UNNotificationActionIcon(systemImageName: "xmark.circle")
        )
        return UNNotificationCategory(
            identifier: categoryID, actions: [leaving, extend, cancel], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: ClipCopy.reminderHiddenBody, options: []
        )
    }

    /// Whether a notification response is one of OUR reminder's actions (so the app delegate runs it
    /// in the background and holds its completion handler until it finishes).
    static func isReminderAction(categoryIdentifier: String, actionIdentifier: String) -> Bool {
        guard categoryIdentifier == categoryID else { return false }
        switch actionIdentifier {
        case HandoffReminderPlan.actionLeavingNow, HandoffReminderPlan.actionExtend, HandoffReminderPlan.actionCancel:
            return true
        default:
            return false
        }
    }
}

// MARK: - Reminder scheduler

/// The slice of `UNUserNotificationCenter` the scheduler needs.
@MainActor
protocol DriverNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

@MainActor
final class SystemDriverNotificationCenter: DriverNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: UNNotificationRequest) async {
        try? await center.add(request)
    }

    func removePending(identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

@MainActor
final class DriverReminderScheduler: HandoffReminderScheduling {

    private let center: any DriverNotificationCenter
    private let registerCategories: @MainActor ([UNNotificationCategory]) async -> Void

    init(
        center: (any DriverNotificationCenter)? = nil,
        registerCategories: @escaping @MainActor ([UNNotificationCategory]) async -> Void = { await NotificationCategoryRegistry.register($0) }
    ) {
        self.center = center ?? SystemDriverNotificationCenter()
        self.registerCategories = registerCategories
    }

    /// Asks for the app's normal notification permission the FIRST time (spec 6.3: "at the first
    /// action that needs it"). This is called from the driver's CTA tap, under an explanatory line,
    /// so the system prompt is always earned. A denied/undecided answer simply means "reminders off".
    func availability() async -> HandoffReminderAvailability {
        var status = await center.authorizationStatus()
        if status == .notDetermined {
            _ = await center.requestAuthorization()
            status = await center.authorizationStatus()
        }
        return HandoffReminderAvailability(status: status)
    }

    func schedule(_ reminders: [PlannedReminder], passID: UUID) async {
        // Merge-safe: never `setNotificationCategories` with a lone set (that replaces the address
        // and seeker categories, `NotificationCategoryRegistry`).
        await registerCategories([DriverReminderCategory.category()])
        cancelAll(passID: passID)
        for reminder in reminders {
            await center.add(Self.request(for: reminder, passID: passID, now: Date()))
        }
    }

    func cancelAll(passID: UUID) {
        let ids = [HandoffReminderPlan.leaveIdentifier(passID: passID), HandoffReminderPlan.lastCallIdentifier(passID: passID)]
        center.removePending(identifiers: ids)
        center.removeDelivered(identifiers: ids)
    }

    /// Pure request builder (unit-tested).
    nonisolated static func request(for reminder: PlannedReminder, passID: UUID, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = HandoffReminderPlan.categoryID
        content.threadIdentifier = HandoffReminderPlan.threadID(passID: passID)
        content.interruptionLevel = .active
        content.userInfo = ["kind": "reminder"]
        let interval = max(1, reminder.fireDate.timeIntervalSince(now))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
    }
}

// MARK: - Session + push token

/// The shared auth service's access token (the SAME anonymous identity every other write uses).
@MainActor
final class AuthServiceDriverSession: DriverSessionProviding {
    private let tokenProvider: () async -> String?

    init(tokenProvider: @escaping () async -> String?) {
        self.tokenProvider = tokenProvider
    }

    func accessToken() async -> String? { await tokenProvider() }
}

/// The app's hex APNs token for the thank-you alert, only while notifications are authorized.
@MainActor
final class AppNotificationPushToken: HandoffPushTokenProviding {
    private let tokenHex: () -> String?
    private let status: () async -> UNAuthorizationStatus

    init(
        tokenHex: @escaping () -> String?,
        status: @escaping () async -> UNAuthorizationStatus = { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    ) {
        self.tokenHex = tokenHex
        self.status = status
    }

    func deviceToken() async -> String? {
        switch await status() {
        case .authorized, .provisional, .ephemeral: return tokenHex()
        default: return nil
        }
    }
}

/// Used when the Supabase config keys are missing: every call reports "offline" so the UI shows the
/// calm retry screen instead of crashing.
@MainActor
final class UnconfiguredHandoffDriverAPI: HandoffDriverAPI {
    func peek(token: String) async throws -> HandoffPeekResult { throw HandoffAPIError.offline }
    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult { throw HandoffAPIError.offline }
    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool { throw HandoffAPIError.offline }
    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult { throw HandoffAPIError.offline }
    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool { throw HandoffAPIError.offline }
    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool { throw HandoffAPIError.offline }
}
