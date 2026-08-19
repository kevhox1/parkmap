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
//  Tier 3 sub-PR #1 additions:
//    - SupabaseAuthService instantiated as @State at app root (single instance, AC-A5).
//    - .task { await authService.ensureSession() } fires on first WindowGroup appear.
//      Non-blocking: the map loads while auth completes in the background.
//    - authService passed into ContentView and from there into CommunityPinService
//      so the same anonymous identity is used for all writes (AC-A5 singleton invariant).
//
//  supabase-swift adoption — Stream A (Auth/Keychain), docs/supabase-swift-realtime-spec.md §9:
//    - SupabaseAuthService's internals now wrap the SDK's AuthClient (Keychain-backed session
//      storage) instead of raw URLSession + UserDefaults. The AuthClient instance itself is
//      built inside SupabaseAuthService()'s own convenience init (via a SupabaseClients value —
//      see that file + SupabaseAuthService.swift's headers), so this file's authService
//      property declaration is textually unchanged from pre-SDK. authService's public API and
//      this file's .task wiring are unchanged (AC-A1): ContentView / CommunityPinService need
//      zero changes.
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

    // MARK: - Tier 3 sub-PR #1: Anonymous auth identity (AC-A5 singleton)

    /// Single SupabaseAuthService instance for the app lifetime.
    ///
    /// Instantiated here (not in ContentView) to avoid body re-render races and to ensure
    /// there is exactly one instance (AC-A5). The same instance is passed to ContentView and
    /// from there into CommunityPinService so all writes share the same anonymous identity.
    ///
    /// Note: @State on App body properties is the Swift-idiomatic way to hold a single
    /// service instance at the app root without escaping it into a global. The instance is
    /// alive for the full app lifetime.
    ///
    /// supabase-swift Stream A: SupabaseAuthService()'s convenience init builds its own
    /// SupabaseClients (and that struct's own AuthClient) internally — see
    /// SupabaseClients.swift. This keeps WeParkApp.swift's diff minimal for this stream; when
    /// Stream B wires CommunityPinService to the SDK's Realtime client, this property likely
    /// becomes a shared `@State private var supabaseClients = SupabaseClients()` injected into
    /// both services (spec §3.4) — deferred to that PR rather than speculatively added now.
    @State private var authService = SupabaseAuthService()

    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate, authService: authService)
                .task {
                    // Non-blocking: the map loads while auth completes in the background.
                    // ensureSession() fails silently if the network is unavailable (AC-A4).
                    // The app stays in read-only mode until auth is available.
                    await authService.ensureSession()
                }
                // FT-20 (2026-08-19): app defaults to dark mode, always, regardless of the
                // device's system appearance setting. Kevin: "I think that looks cleaner."
                // No in-app theme setting exists — this is a hard override, not a default
                // that a user can flip back to light. A system-following or user-toggleable
                // variant is a small, separate follow-up if he wants one later
                // (docs/field-testing-log.md FT-20).
                //
                // This modifier sets the SwiftUI environment's colorScheme for the whole
                // view hierarchy, including MKMapView hosted via MapViewRepresentable
                // (UIViewRepresentable) — SwiftUI cascades the resolved appearance to the
                // window's overrideUserInterfaceStyle, which MKMapView (and every other
                // UIKit view in the hierarchy) reads from its trait collection. No
                // MapViewRepresentable-side change is needed; MKMapView was already
                // rendering its dark basemap correctly whenever the device was in system
                // Dark Mode (confirmed on a build-16 device screenshot) — this just makes
                // that the permanent state instead of a system-setting-dependent one.
                //
                // Also set at the Info.plist level (`UIUserInterfaceStyle: Dark`) as the
                // authoritative whole-app switch — that key is what actually forces
                // system-presented UIKit chrome (share sheets, alerts, the keyboard) dark,
                // which this SwiftUI-scoped modifier does not reliably reach on its own.
                // Both together, not an either/or: SwiftUI Previews and any future
                // programmatic window creation still read this environment modifier.
                .preferredColorScheme(.dark)
        }
    }
}
