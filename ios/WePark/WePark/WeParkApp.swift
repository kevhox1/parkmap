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
//      storage) instead of raw URLSession + UserDefaults. authService's public API and this
//      file's .task wiring are unchanged (AC-A1): CommunityPinService's write callers need
//      zero changes.
//
//  supabase-swift adoption — Stream B (Realtime), docs/supabase-swift-realtime-spec.md §3.4, §11:
//    - ONE shared `SupabaseClients` instance is now constructed here (app lifetime) and
//      injected into both `SupabaseAuthService` (via `makeAuthService()`) and
//      `CommunityPinService` (via `ContentView`'s init, using `makeRealtimePinChannel()`) —
//      matches `RealtimeClientV2`'s own doc: "Create one client per Supabase project and reuse
//      it across your app." Neither factory method requires this file to `import Auth` or
//      `import Realtime` itself — see `SupabaseClients.swift`'s header for why.
//
//  Community 2.0 Phase 4b additions (build 20, S12) — spec §2.9/§3 Phase 4,
//  Services/PushRegistrationService.swift:
//    - `pendingDeviceToken: Data?` — buffers the raw APNs device token from
//      `didRegisterForRemoteNotificationsWithDeviceToken`, mirroring `pendingDeepLinkCarID`'s
//      proven buffer-on-AppDelegate / drain-via-onChange-in-ContentView shape (same W6.1
//      "subscriber not attached yet" race this pattern already solves once).
//    - `didReceiveRemoteNotification(_:fetchCompletionHandler:)` — the SILENT push handler
//      (content-available). Fully self-contained: reads the parked car's segment via
//      `ParkedCarSegmentReader` (never location), runs it through the shared
//      `CommunityPushRelevance.isRelevant` predicate (the SAME pure function
//      `ContentView`'s foreground WP5 confirm-card path uses), dedupes via
//      `CommunityPushDedupeStore`, and — only on an actual match — enqueues a LOCAL
//      notification via the existing `UNUserNotificationCenter` machinery. Does not depend on
//      `ContentView`'s live `ParkPinService` instance being mounted (see
//      `ParkedCarSegmentReader`'s own doc comment for why that matters for a background wake).
//      All flag-gated behind `AppConstants.communityEnabled` — a no-op end-to-end while the
//      flag is off.
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

    // MARK: - Community 2.0 Phase 4b (S12): APNs device-token buffer

    /// Stores the raw APNs device token bytes from
    /// `didRegisterForRemoteNotificationsWithDeviceToken`, same buffer-and-drain shape as
    /// `pendingDeepLinkCarID` above. `ContentView` forwards this to
    /// `PushRegistrationService.didReceiveDeviceToken(_:)` via `.onChange(of:)`, then clears
    /// it back to `nil` for idempotency (a re-registration mid-session should re-forward, not
    /// silently no-op because a stale non-nil value is still sitting here).
    @Published var pendingDeviceToken: Data? = nil

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

    // MARK: - Community 2.0 Phase 4b (S12): APNs registration callbacks

    /// Called after a successful `UIApplication.registerForRemoteNotifications()` call.
    /// Buffers the raw token; `ContentView` forwards it to `PushRegistrationService` (see
    /// `pendingDeviceToken`'s own doc comment).
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingDeviceToken = deviceToken
        }
    }

    /// Called when `registerForRemoteNotifications()` fails — expected on the Simulator (no
    /// real APNs capability there) and, before permission has been granted, is simply never
    /// reached (registration is only ever requested once permission is already authorized —
    /// see `PushRegistrationService.requestRegistrationIfEnabled`). Logged only; never
    /// surfaced to the user. Registration retries naturally on the next foreground/launch via
    /// `PushRegistrationService.requestRegistrationIfEnabled()`.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] registerForRemoteNotifications failed: \(error)")
    }

    /// The SILENT push handler (`content-available`) — the background half of the
    /// Community 2.0 Phase 4b relevance-gate pipeline (spec §2.9 / §3 Phase 4, roadmap S12).
    ///
    /// Payload shape (sender: `supabase/functions/send-community-push`, PR #99 — verified
    /// against that Edge Function's body per `docs/qa/pr99-community-phase4b-push.md`'s
    /// "Privacy invariant holds" section): `{ aps: { "content-available": 1 }, pin_type,
    /// segment_id, pin_id, zone_id }`. No `author_id`, no lat/lng — the server never sends
    /// anything more specific than `zone_id`; `segment_id` is compared ENTIRELY on-device
    /// (`ParkedCarSegmentReader`).
    ///
    /// Self-contained by design — does NOT depend on `ContentView`'s live `ParkPinService`
    /// instance or any other SwiftUI state being mounted yet for this launch (see
    /// `ParkedCarSegmentReader`'s own doc comment for why a background app-refresh wake
    /// cannot assume that timing).
    ///
    /// Completion-handler discipline: `.noData` for every early-exit branch (flag off,
    /// malformed payload, not relevant, already seen, unrecognized type — no local
    /// notification was ever enqueued in any of those); `.newData` only after a local
    /// notification was actually added to `UNUserNotificationCenter`.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        DispatchQueue.main.async {
            guard AppConstants.communityEnabled else {
                completionHandler(.noData)
                return
            }

            guard
                let pinTypeRaw = userInfo["pin_type"] as? String,
                let pinType = PinType(rawValue: pinTypeRaw),
                let pinSegmentId = userInfo["segment_id"] as? String,
                let pinIdRaw = userInfo["pin_id"] as? String,
                let pinId = UUID(uuidString: pinIdRaw)
            else {
                completionHandler(.noData)
                return
            }

            // PRIVACY (spec §2.9): the ONLY location signal this device ever uploads is a
            // coarse zone_id. Relevance is decided ENTIRELY on-device by comparing this
            // payload's segment_id against the parked car's own segment_id — never uploaded
            // anywhere. See ParkedCarSegmentReader's doc comment.
            let parkedCarSegmentId = ParkedCarSegmentReader.currentSegmentId()

            guard CommunityPushRelevance.isRelevant(
                pinType: pinType,
                pinSegmentId: pinSegmentId,
                parkedCarSegmentId: parkedCarSegmentId
            ) else {
                completionHandler(.noData)
                return
            }

            // Cross-path dedupe (spec §3 Phase 4b item 3): a pin already surfaced via the
            // foreground confirm-prompt card must not ALSO fire a push notification, and
            // vice versa — see CommunityPushDedupeStore's own doc comment.
            let dedupe = CommunityPushDedupeStore()
            guard !dedupe.hasSeen(pinId) else {
                completionHandler(.noData)
                return
            }

            guard let copy = CommunityPushRelevance.notificationCopy(for: pinType) else {
                completionHandler(.noData)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            content.userInfo = [
                "wepark_action": "community_push",
                "wepark_pin_id": pinId.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: "wepark.community.\(pinId.uuidString)",
                content: content,
                trigger: nil
            )
            // PR #101 QA pass 1 fix (Finding #4, minor): mark-seen moves to AFTER a
            // successful `add(request:)` — marking it seen unconditionally beforehand meant a
            // rare `add` failure would permanently suppress this pin (no notification ever
            // shown, no retry, and the WP5 foreground card would also never re-offer it via
            // the shared dedupe store). Also (Finding #5, minor): `.newData` is now reported
            // ONLY on a genuine successful enqueue — `.noData` on the (rare) error path is
            // more accurate for `UIBackgroundFetchResult`'s informational purpose.
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    print("[AppDelegate] community push local notification failed: \(error)")
                    completionHandler(.noData)
                    return
                }
                dedupe.markSeen(pinId)
                completionHandler(.newData)
            }
        }
    }
}

// MARK: - WeParkApp

@main
struct WeParkApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - supabase-swift: shared SDK clients + anonymous auth identity (AC-A5 singleton)

    /// Single `SupabaseClients` instance for the app lifetime — one `AuthClient` and one
    /// `RealtimeClientV2` reused everywhere (spec §3.4). Neither `SupabaseAuthService` nor
    /// `CommunityPinService` construct their own SDK clients in production anymore; both are
    /// handed pieces of this one instance below.
    @State private var supabaseClients: SupabaseClients

    /// Single SupabaseAuthService instance for the app lifetime.
    ///
    /// Instantiated here (not in ContentView) to avoid body re-render races and to ensure
    /// there is exactly one instance (AC-A5). The same instance is passed to ContentView and
    /// from there into CommunityPinService so all writes share the same anonymous identity.
    ///
    /// Note: @State on App body properties is the Swift-idiomatic way to hold a single
    /// service instance at the app root without escaping it into a global. The instance is
    /// alive for the full app lifetime.
    @State private var authService: SupabaseAuthService

    /// Explicit init required because `authService` (a `@State` property) depends on
    /// `supabaseClients.authClient` — Swift stored properties can't reference sibling stored
    /// properties in their default-expression form (same reasoning as `ContentView.init`'s own
    /// explicit init, below). `supabaseClients.makeAuthService()` keeps this file free of
    /// `import Auth` — see `SupabaseClients.swift`'s header.
    init() {
        let clients = SupabaseClients()
        _supabaseClients = State(initialValue: clients)
        _authService = State(initialValue: clients.makeAuthService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate, authService: authService, supabaseClients: supabaseClients)
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
