//
//  WeParkApp.swift
//  WePark
//
//  W6 additions:
//    - AppDelegate: conforms to UNUserNotificationCenterDelegate.
//      Sets UNUserNotificationCenter.current().delegate = self at launch.
//      Handles notification tap deep-link to ParkedCarDetailView (AC-W6.11, OQ-W6-3).
//    - notificationDeepLinkSubject: PassthroughSubject<UUID, Never> that ContentView
//      observes to present ParkedCarDetailView when a notification is tapped.
//    - UNUserNotificationCenter.current().delegate must be set before the app finishes
//      launching — set in application(_:didFinishLaunchingWithOptions:) (AC-W6.18).
//

import SwiftUI
import UserNotifications
import Combine

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Deep-link subject

    /// Emits the car ID to present when a notification is tapped (OQ-W6-3).
    /// ContentView subscribes via .onReceive and sets activeSheet = .parkedCarDetail.
    let notificationDeepLinkSubject = PassthroughSubject<UUID, Never>()

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // AC-W6.18: delegate must be set before the app finishes launching.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification is delivered while the app is in the foreground.
    /// Shows the notification banner normally (default behavior).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Display the notification banner + sound even when the app is in the foreground.
        completionHandler([.banner, .sound, .badge])
    }

    /// Called when the user taps a delivered notification (foreground, background, or killed app).
    /// Routes to ParkedCarDetailView via notificationDeepLinkSubject (AC-W6.11, OQ-W6-3).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard
            let action = userInfo["wepark_action"] as? String,
            action == "show_car_detail",
            let carIDString = userInfo["wepark_car_id"] as? String,
            let carID = UUID(uuidString: carIDString)
        else { return }

        // Route to ContentView on main thread. ContentView observes this subject
        // and presents ParkedCarDetailView for the matching car.
        DispatchQueue.main.async { [weak self] in
            self?.notificationDeepLinkSubject.send(carID)
        }
    }
}

// MARK: - WeParkApp

@main
struct WeParkApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate)
        }
    }
}
