//
//  WeParkApp.swift
//  WePark
//
//  W6 additions:
//    - AppDelegate: conforms to UNUserNotificationCenterDelegate.
//      Sets UNUserNotificationCenter.current().delegate = self at launch.
//      Handles notification tap deep-link to ParkedCarDetailView (AC-W6.11, OQ-W6-3).
//    - UNUserNotificationCenter.current().delegate must be set before the app finishes
//      launching — set in application(_:didFinishLaunchingWithOptions:) (AC-W6.18).
//
//  W6.1 fix:
//    - Replaced PassthroughSubject<UUID, Never> with @Published var pendingDeepLinkCarID: UUID?.
//      PassthroughSubject has no replay: if the delegate fires before ContentView's .onReceive
//      subscriber is attached (cold-kill / deep-background wake), the event is silently dropped.
//      @Published / ObservableObject stores the value; ContentView reads it via onChange(of:)
//      AND on foreground transition (scenePhase == .active) so it arrives regardless of timing.
//      After routing, pendingDeepLinkCarID is cleared to nil for idempotency — subsequent
//      foreground events do not re-present the sheet.
//

import SwiftUI
import UserNotifications
import Combine

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {

    // MARK: - Deep-link buffer (W6.1 fix)

    /// Stores the car ID to present when a notification is tapped (OQ-W6-3).
    ///
    /// Previously a PassthroughSubject — that dropped events when ContentView's .onReceive
    /// subscriber hadn't attached yet (cold-kill / background-wake race).
    ///
    /// Now @Published: the value persists until ContentView reads it. ContentView routes
    /// on .onChange(of: appDelegate.pendingDeepLinkCarID) *and* on scenePhase .active,
    /// covering both the foreground case and the cold-kill case. After routing, the caller
    /// sets this back to nil so the sheet does not re-present on the next foreground event.
    @Published var pendingDeepLinkCarID: UUID? = nil

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
    /// Buffers the car ID in pendingDeepLinkCarID (W6.1 fix — replaces PassthroughSubject).
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

        // Buffer the car ID on the main thread. ContentView picks it up via onChange(of:)
        // whether it subscribes immediately (foreground) or after the view hierarchy settles
        // (cold-kill / background wake). The value persists until ContentView clears it.
        DispatchQueue.main.async { [weak self] in
            self?.pendingDeepLinkCarID = carID
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
