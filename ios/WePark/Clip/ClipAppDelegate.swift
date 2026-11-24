//
//  ClipAppDelegate.swift
//  WePark Clip
//
//  Notification plumbing for the clip. A launch from a notification carries NO invocation URL
//  (spec 5.1), so action taps arrive here and are bridged into the flow controller; events that
//  land before the controller exists are buffered. Also receives the clip's ephemeral APNs token.
//  No background modes, no silent-push handling (clips cannot run background activity).
//

import UIKit
import UserNotifications

// MARK: - Push token

@MainActor
final class ClipPushTokenBroker: HandoffPushTokenProviding {

    static let shared = ClipPushTokenBroker()

    private var token: String?
    /// Max wait in `deviceToken()`, so arming is never held up by APNs.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 1.5) { self.timeout = timeout }

    func didRegister(deviceToken data: Data) {
        token = HandoffActivityContent.hex(data)
    }

    func deviceToken() async -> String? {
        if let token { return token }
        UIApplication.shared.registerForRemoteNotifications()
        let deadline = Date().addingTimeInterval(timeout)
        while token == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return token
    }
}

// MARK: - Event bridge

@MainActor
final class ClipEventBridge {
    static let shared = ClipEventBridge()

    private var pending: [(String, [AnyHashable: Any])] = []
    var handler: ((String, [AnyHashable: Any]) -> Void)? {
        didSet {
            guard let handler else { return }
            let buffered = pending
            pending = []
            buffered.forEach { handler($0.0, $0.1) }
        }
    }

    func deliver(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        if let handler { handler(actionIdentifier, userInfo) } else { pending.append((actionIdentifier, userInfo)) }
    }
}

// MARK: - Delegate

final class ClipAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([HandoffReminderPlan.category()])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in ClipPushTokenBroker.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected on the simulator / without the push entitlement: arming simply goes without a push token.
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            ClipEventBridge.shared.deliver(actionIdentifier: identifier, userInfo: userInfo)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        // A thank-you arriving while the clip is open should land in the UI as well as the banner.
        if (userInfo["kind"] as? String) == "thanks" {
            Task { @MainActor in
                ClipEventBridge.shared.deliver(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo)
            }
        }
        completionHandler([.banner, .sound])
    }
}
