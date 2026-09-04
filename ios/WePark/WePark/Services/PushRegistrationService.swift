//
//  PushRegistrationService.swift
//  WePark
//
//  Community 2.0 Phase 4b — iOS side (build 20, S12).
//  Spec: docs/community-2.0-reconciliation-spec.md §2.9 (as amended 2026-09-02, PR #100) +
//  §3 Phase 4 + docs/community-2.0-roadmap.md S12 row (incl. its WP5 rider) +
//  docs/qa/pr99-community-phase4b-push.md (the live backend this pipeline talks to).
//
//  Everything in this file is flag-gated behind `AppConstants.communityEnabled` — with the
//  flag off, zero registration happens, zero tokens are ever uploaded, and the WP5 helpers
//  are simply never called by ContentView. (`AppConstants.communityEnabled` is currently
//  `false` — this whole pipeline ships dark, same posture as every other Community 2.0 phase.)
//
//  What lives here (four independent, individually-testable pieces):
//
//   1. `APNSEnvironment` — runtime sandbox-vs-production detection. See its own doc comment
//      for the embedded.mobileprovision heuristic and its (expected, load-bearing) failure
//      mode: TestFlight/App Store builds don't ship that file at all.
//
//   2. `ParkedCarSegmentReader` — a synchronous, on-device-only read of the parked car's
//      segment id, for the ONE call site (`AppDelegate`'s background silent-push handler,
//      `WeParkApp.swift`) that cannot reach `ContentView`'s live `ParkPinService` instance.
//      PRIVACY: this is the on-device comparison point — the segment id it returns is NEVER
//      uploaded anywhere. See its own doc comment.
//
//   3. `CommunityPushRelevance` — the ONE shared pure predicate used by BOTH the background
//      silent-push path (`WeParkApp.swift`'s `AppDelegate`) and the foreground realtime WP5
//      confirm-card path (`ContentView.swift`). Per the roadmap's own framing ("S12 is
//      already writing the on-device relevance-gate predicate... the in-app foregrounded
//      card needs the identical predicate on a different trigger") and this codebase's S9
//      routing-model lesson (pure function, wired into both call sites, tested once).
//
//   4. `CommunityPushDedupeStore` — the cross-path "never re-prompt/re-notify for the same
//      pin_id" dedupe, backed by UserDefaults so it survives the app backgrounding/relaunching
//      between the push path and the in-app card path.
//
//   5. `PushRegistrationService` — the class that actually does the registration + token
//      upload work: asks for remote-notification registration (only via the EXISTING
//      permission flow — see `requestRegistrationIfEnabled`'s doc comment, this file adds NO
//      new prompt), captures the device token, resolves zone_id from the parked car or
//      current location, and upserts `(user_id, apns_token, environment, zone_id)` into
//      `device_push_tokens`.
//
//  Self-contained by design: this file builds its OWN minimal authenticated Supabase REST
//  request (mirroring `CommunityPinService.buildAuthenticatedRequest`'s exact shape —
//  `apikey` + `Authorization: Bearer <jwt>` headers, `Prefer: resolution=merge-duplicates,
//  return=minimal` for the upsert) rather than extending `CommunityPinService.swift`, which
//  this session's scope deliberately excludes (see PR description's file-touch list).
//
//  Entitlements/capabilities this file assumes are ALREADY PRESENT (verified, not re-added
//  by this PR): `aps-environment` in `WePark.entitlements` and `remote-notification` in
//  `Info.plist`'s `UIBackgroundModes` — both landed in commit b509eaa8 (S11 prep).
//
//  [COMPILE-UNVERIFIED] — written on a Linux VPS with no Xcode/Swift toolchain. Every API
//  used here (`UIApplication.registerForRemoteNotifications`, `UNUserNotificationCenter`,
//  `PropertyListSerialization`, `NSUbiquitousKeyValueStore`) is standard Foundation/UIKit,
//  not an SDK dependency — see the PR description for the specific points that most need a
//  Mac `xcodebuild build` + `test` pass before merge.
//

import Foundation
import UIKit
import UserNotifications

// MARK: - APNSEnvironment

/// Runtime detection of which APNs environment THIS build's provisioning profile targets.
/// Maps to `device_push_tokens.environment`'s two allowed values (`"sandbox"` / `"production"`,
/// spec §2.9's `check (environment in ('sandbox', 'production'))`).
enum APNSEnvironment {
    // `nonisolated` throughout this enum: this project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
    // MainActor` build setting (see `CommunityZoneBounds.box(for:)`'s doc comment for the
    // established precedent/rationale) would otherwise implicitly isolate these pure, static,
    // no-instance-state functions to the main actor — breaking both the synchronous plain
    // `XCTestCase` call sites in `PushRegistrationServiceTests.swift` and the call from
    // `AppDelegate`'s `DispatchQueue.main.async` closure (a GCD closure, not a Swift-actor-
    // recognized MainActor context, in `WeParkApp.swift`).
    nonisolated static let sandbox = "sandbox"
    nonisolated static let production = "production"

    /// Entry point used in production — reads the real embedded provisioning profile (if
    /// any) and parses it. See `parse(profileString:)` for the actual decision logic and its
    /// failure mode; this wrapper only exists to inject a real file read at the one
    /// production call site while keeping `parse` itself a pure, directly-testable function.
    nonisolated static func detectCurrent() -> String {
        parse(profileString: embeddedProfileString())
    }

    /// MECHANISM: `embedded.mobileprovision` is a CMS (PKCS#7)-signed blob wrapping an XML
    /// plist with an `Entitlements.aps-environment` key (`"development"` or `"production"` —
    /// the same two values Apple's own provisioning-profile UI uses). This function does NOT
    /// verify the CMS signature (no need to — this is a local heuristic, not a security
    /// boundary); it string-searches the raw content for the embedded `<?xml ... </plist>`
    /// region and parses THAT substring as a normal plist.
    ///
    /// Split out from `detectCurrent()` (rather than reading `Bundle.main` directly here) so
    /// every branch — present+development, present+production, present+malformed, absent —
    /// is directly testable with a synthetic input string, no real provisioning profile file
    /// needed on disk (task requirement: "environment-stamping logic, mock the detection
    /// inputs").
    ///
    /// FAILURE MODE (expected, not a bug — this is the load-bearing case in production):
    /// **Apple strips `embedded.mobileprovision` entirely from every App Store Connect
    /// distribution build — both TestFlight and full App Store releases.** Only
    /// Development/Ad-Hoc/Enterprise-signed `.ipa`s carry this file at all. So `profileString
    /// == nil` is the NORMAL path for every TestFlight/App Store install, and `.production`
    /// is the correct fallback for exactly that reason — this is not a parsing failure being
    /// papered over, it's how Apple's own re-signing pipeline works. (It is also why this
    /// codebase's `WePark.entitlements` file has a hardcoded, Debug-looking
    /// `aps-environment: development` value that must NOT be trusted at runtime for a
    /// Release/TestFlight binary — Xcode does not necessarily rewrite that literal string per
    /// configuration the way it does for some other entitlement keys, which is the whole
    /// reason this runtime heuristic exists instead of just reading a bundled constant.) The
    /// Simulator hits the identical "absent" branch (no provisioning profile of any kind is
    /// embedded in a Simulator build) — harmless, since `registerForRemoteNotifications()`
    /// never actually succeeds in the Simulator, so no token is ever generated to stamp.
    ///
    /// A present-but-malformed/unparseable plist (a future Apple format change, a corrupted
    /// profile) also falls back to `.production` for the same "safe default" reasoning:
    /// silently mis-stamping a real device as `.sandbox` when it's actually `.production`
    /// would misroute pushes for that user's real install more often than the reverse would
    /// (most non-Xcode-attached real-world installs, by volume, ARE TestFlight/App Store).
    nonisolated static func parse(profileString: String?) -> String {
        guard let raw = profileString,
              let xmlStart = raw.range(of: "<?xml"),
              let plistEnd = raw.range(of: "</plist>")
        else {
            return production
        }
        let plistXML = String(raw[xmlStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistXML.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let apsEnvironment = entitlements["aps-environment"] as? String
        else {
            return production
        }
        return apsEnvironment == "development" ? sandbox : production
    }

    /// Reads `embedded.mobileprovision` from the app bundle, if present, decoded as
    /// ISO-Latin-1 (a lossless byte-for-byte decode — the CMS wrapper's non-plist bytes don't
    /// need to be valid text, they just need to round-trip so the `<?xml`/`</plist>`
    /// substring search in `parse(profileString:)` works against the embedded plist region).
    private nonisolated static func embeddedProfileString() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path)
        else {
            return nil
        }
        return String(data: data, encoding: .isoLatin1)
    }
}

// MARK: - ParkedCarSegmentReader

/// Synchronous, on-device-only read of the parked car's segment id — for the ONE call site
/// that cannot reach `ContentView`'s live `ParkPinService` instance: `AppDelegate`'s
/// background silent-push handler (`WeParkApp.swift`), which must be able to answer "does
/// this push match my parked car?" even if `ContentView`'s SwiftUI view hierarchy hasn't
/// mounted yet for this particular background-wake launch — a background app-refresh wake
/// for a silent push does not guarantee the same subscriber-attachment timing a foreground
/// launch does (see the W6.1 postmortem, `HANDOFF.md`, for the exact class of "event fires
/// before the SwiftUI subscriber is attached" bug this sidesteps entirely by not depending
/// on SwiftUI state at all here).
///
/// Deliberately duplicates `ParkPinService`'s own `syncedStateKey` / envelope-decode shape
/// (`Services/ParkPinService.swift`, `Models/SyncedCarEnvelope.swift`) rather than
/// instantiating a full `ParkPinService()` — that type's `init()`/`load()` have real side
/// effects (registering an `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
/// observer) that this one-shot reader does not want, and `ParkPinService.swift` itself is
/// out of this session's file-touch scope (see PR description). If that file's storage
/// key or envelope shape ever changes, this reader must be updated in the same commit.
///
/// PRIVACY (spec §2.9): returns ONLY the segment id, NEVER lat/lng. This is the on-device
/// comparison point cited throughout §2.9 — "the client... compares the payload's segment_id
/// against its own on-device ParkedCar.segmentId," never uploading location anywhere. The
/// server only ever learns which ZONE a device is subscribed to (coarse, already-public) —
/// never which blockface.
enum ParkedCarSegmentReader {
    /// Must match `ParkPinService.syncedStateKey` exactly (`Services/ParkPinService.swift`).
    private nonisolated static let syncedStateKey = "wepark_synced_car_state"

    // `nonisolated` — same `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` reasoning as
    // `APNSEnvironment` above: this is called from `AppDelegate`'s `DispatchQueue.main.async`
    // closure (`WeParkApp.swift`), a GCD context Swift's actor-isolation checker does not
    // treat as MainActor-isolated by default.
    nonisolated static func currentSegmentId(
        store: UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default
    ) -> String? {
        guard let data = store.data(forKey: syncedStateKey),
              let envelope = try? JSONDecoder().decode(SyncedCarEnvelope.self, from: data)
        else {
            return nil
        }
        switch envelope.kind {
        case .parked:  return envelope.car?.detectedSegmentID
        case .cleared: return nil
        }
    }
}

// MARK: - CommunityPushRelevance

/// The ONE shared pure relevance predicate used by both the background silent-push handler
/// (`WeParkApp.swift`'s `AppDelegate.application(_:didReceiveRemoteNotification:...)`) and
/// the foreground realtime WP5 confirm-card trigger (`ContentView.swift`). No dependency on
/// UIKit, SwiftUI, networking, or any live service instance — pure data in, pure data out.
///
/// Every function below is explicitly `nonisolated` — same `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` reasoning as `APNSEnvironment` above (established precedent:
/// `CommunityZoneBounds.box(for:)`). Call sites span a `@MainActor` context
/// (`ContentView.swift`), a GCD `DispatchQueue.main.async` closure
/// (`AppDelegate`, `WeParkApp.swift`), and plain synchronous `XCTestCase` methods
/// (`PushRegistrationServiceTests.swift`) — none of the latter two are recognized as
/// MainActor-isolated by the Swift concurrency checker, so an un-annotated function here
/// would fail to compile at those call sites without an `await`/actor hop it has no reason
/// to need.
enum CommunityPushRelevance {

    /// A pin is relevant to THIS device if and only if:
    ///   1. Both the pin's segment id and the parked car's segment id are non-nil, AND
    ///   2. They're equal, AND
    ///   3. The pin's type is one this pipeline ever surfaces at all (`sweeperPassed` /
    ///      `enforcementActive` — `open_spot`/`leaving_soon` are NEVER relevant here, even on
    ///      an exact segment match: spec §3 Phase 4b item 2, "open_spot/leaving_soon on your
    ///      own block → no notification, not relevant to a parked user" — telling someone
    ///      already parked on a block about an open spot on that SAME block is a no-op).
    ///
    /// No location is read or uploaded by this function itself — every parameter is a plain,
    /// already-resolved `String?`. The caller is responsible for sourcing `parkedCarSegmentId`
    /// from purely on-device state (`ParkedCarSegmentReader`, or `ParkedCar.detectedSegmentID`
    /// directly) and NEVER uploading it anywhere (spec §2.9's privacy design).
    nonisolated static func isRelevant(pinType: PinType, pinSegmentId: String?, parkedCarSegmentId: String?) -> Bool {
        guard let parkedCarSegmentId, let pinSegmentId, parkedCarSegmentId == pinSegmentId else {
            return false
        }
        switch pinType {
        case .sweeperPassed, .enforcementActive:
            return true
        default:
            return false
        }
    }

    /// Local-notification copy per type. `nil` for any type `isRelevant` never returns `true`
    /// for (kept as an exhaustive switch with a `default: nil` rather than only defining the
    /// two live cases, so a future `PinType` case addition doesn't need to touch this file to
    /// stay correct — it just silently falls through to "no notification," matching
    /// `isRelevant`'s own default).
    nonisolated static func notificationCopy(for pinType: PinType) -> (title: String, body: String)? {
        switch pinType {
        case .sweeperPassed:
            // Compliance framing, not urgency — informational, matches the confirm-prompt
            // card's own title (`Views/ConfirmPromptCard.swift`, `design/prototype.html:104`).
            return (
                "Sweeper reported on your block",
                "A neighbor reported the street sweeper on your block. Open WePark to confirm once it's passed."
            )
        case .enforcementActive:
            // Verbatim framing from docs/community-1.0-direction.md §6: "Copy is neutral /
            // compliance ('Enforcement active on this block' → prompts move your car / feed
            // the meter), never 'avoid tickets.'" No ticket-avoidance language anywhere here.
            return (
                "Enforcement active on your block",
                "An agent was reported nearby — move your car or feed the meter."
            )
        default:
            return nil
        }
    }

    /// WP5 (roadmap S12 rider): the first pin in `pins` eligible for the in-app foreground
    /// "did it pass?" confirm-prompt card (`Views/ConfirmPromptCard.swift`) — a
    /// `sweeper_passed` pin matching the parked car's segment that hasn't already been
    /// surfaced by EITHER this card or the background push path (`seenPinIds` is the shared
    /// cross-path dedupe set — see `CommunityPushDedupeStore`).
    ///
    /// Scoped to `sweeperPassed` only: the confirm-prompt card's copy ("Did it pass? Your
    /// confirm tells N neighbors it's clear") is specific to that type per the prototype
    /// (`design/prototype.html:104-113`) — `enforcementActive` has no analogous in-app card
    /// in this session's scope, only the background push notification.
    nonisolated static func firstUnseenSweeperPassedMatch(
        pins: [CommunityPin],
        parkedCarSegmentId: String?,
        seenPinIds: Set<UUID>
    ) -> CommunityPin? {
        pins.first { pin in
            pin.pinType == .sweeperPassed
                && !seenPinIds.contains(pin.id)
                && isRelevant(
                    pinType: pin.pinType,
                    pinSegmentId: pin.segmentId,
                    parkedCarSegmentId: parkedCarSegmentId
                )
        }
    }
}

// MARK: - CommunityPushDedupeStore

/// Cross-path dedupe: a `pin_id` that has already triggered EITHER the background silent-push
/// local notification OR the foreground in-app confirm-prompt card must never trigger the
/// OTHER path afterward either — spec §3 Phase 4b item 3 / roadmap S12: "Foreground realtime
/// and background push must not double-prompt for the same pin (dedupe by pin_id)."
///
/// Backed by `UserDefaults` (not a plain in-memory `Set`) so the dedupe survives the app being
/// backgrounded/killed BETWEEN the two trigger paths — e.g. the silent push fires and marks a
/// pin seen while the app is suspended, then the user opens the app minutes later and that
/// same pin is still sitting in the realtime-fed `visiblePins` list; without a persisted
/// store, the confirm card would fire a second time for a pin the user was already told about.
///
/// Bounded to `maxEntries` (default 200) via simple FIFO trim — not a TTL. These are ephemeral
/// pin ids: `sweeper_passed`'s own TTL already retires them from `visiblePins` naturally, so
/// this store only needs to avoid growing unbounded over an install's lifetime, not expire
/// individual entries on a schedule.
///
/// Every member below is explicitly `nonisolated` — called both from `AppDelegate`'s GCD
/// closure (`WeParkApp.swift`) and from plain synchronous `XCTestCase` methods
/// (`PushRegistrationServiceTests.swift`), same `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// reasoning as `CommunityPushRelevance` above.
struct CommunityPushDedupeStore {
    private nonisolated static let defaultsKey = "wepark_community_push_seen_pin_ids"

    private let defaults: UserDefaults
    private let key: String
    private let maxEntries: Int

    nonisolated init(
        defaults: UserDefaults = .standard,
        key: String = CommunityPushDedupeStore.defaultsKey,
        maxEntries: Int = 200
    ) {
        self.defaults = defaults
        self.key = key
        self.maxEntries = maxEntries
    }

    nonisolated func hasSeen(_ pinId: UUID) -> Bool {
        storedIds().contains(pinId.uuidString)
    }

    /// All previously-seen ids, as `UUID`s — malformed/legacy string entries are silently
    /// skipped rather than crashing. Used by `ContentView` to build the `seenPinIds: Set<UUID>`
    /// argument `CommunityPushRelevance.firstUnseenSweeperPassedMatch` takes.
    nonisolated func seenIds() -> Set<UUID> {
        Set(storedIds().compactMap(UUID.init(uuidString:)))
    }

    nonisolated func markSeen(_ pinId: UUID) {
        var ids = storedIds()
        guard !ids.contains(pinId.uuidString) else { return }
        ids.append(pinId.uuidString)
        if ids.count > maxEntries {
            ids.removeFirst(ids.count - maxEntries)
        }
        defaults.set(ids, forKey: key)
    }

    private nonisolated func storedIds() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}

// MARK: - PushRegistrationService

/// Owns APNs registration, environment stamping, and `device_push_tokens` upload.
///
/// Thread safety: `@MainActor` — mutates its own state (`deviceTokenHex`, `currentZoneId`,
/// `lastUploaded`) only from the main actor, matching `SupabaseAuthService`'s own precedent
/// (the auth token this class needs comes from that same main-actor-isolated service).
@MainActor
final class PushRegistrationService {

    // MARK: - Dependencies

    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let authService: SupabaseAuthService
    private let urlSession: URLSession
    private let environmentProvider: () -> String

    /// PR #101 QA pass 1 fix: every instance method below gates on this rather than reading
    /// `AppConstants.communityEnabled` directly. `AppConstants.communityEnabled` is a hardcoded
    /// `static let` — with it `false` (its current, real value), there was previously NO way
    /// for a test to exercise this service's "flag on" wire behavior at all, which is exactly
    /// the class of gap that let Finding #1 (the missing `on_conflict` param) ship undetected
    /// by the original 26 tests. Defaults to the real flag for every production call site
    /// (mirrors `AppConstants.communityPhase1PinTypes(enabled: Bool = communityEnabled)`'s own
    /// "parameterized pure function, defaults to the real flag" precedent in `Constants.swift`)
    /// — tests inject `{ true }` explicitly instead of mutating the immutable global constant.
    private let communityEnabledProvider: () -> Bool

    // MARK: - State

    /// The hex-encoded APNs device token, once `didReceiveDeviceToken(_:)` has fired at least
    /// once this launch. `private(set)` — narrowest access widening for direct test
    /// assertion, matching `CommunityPinService.periodicRefreshTask`'s own precedent.
    private(set) var deviceTokenHex: String?

    /// The most recently resolved zone id (parked car's zone, else current-location zone,
    /// else `nil`). `private(set)` for the same test-assertion reason as `deviceTokenHex`.
    private(set) var currentZoneId: String?

    /// Identifies exactly which `(token, environment, zone)` triple was last SUCCESSFULLY
    /// uploaded — `attemptUpsert` no-ops if the current candidate matches this, so a foreground
    /// re-check or a zone recompute that resolves to the same value doesn't re-POST needlessly.
    private struct UploadKey: Equatable {
        let tokenHex: String
        let environment: String
        let zoneId: String
    }
    private var lastUploaded: UploadKey?

    /// The task created by the most recent `attemptUpsert()` call. `internal` (not `private`)
    /// so tests can `await service.inFlightUpload?.value` to deterministically wait for a
    /// triggered upload to finish before asserting on the mock request — same "narrowest
    /// access widening for test assertions" precedent `CommunityPinService` already
    /// establishes for `realtimeConnectTask`/`realtimeDisconnectTask`.
    var inFlightUpload: Task<Void, Never>?

    // MARK: - Init

    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        authService: SupabaseAuthService,
        urlSession: URLSession = .shared,
        environmentProvider: @escaping () -> String = { APNSEnvironment.detectCurrent() },
        communityEnabledProvider: @escaping () -> Bool = { AppConstants.communityEnabled }
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.authService = authService
        self.urlSession = urlSession
        self.environmentProvider = environmentProvider
        self.communityEnabledProvider = communityEnabledProvider
    }

    /// Convenience initializer reading `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Bundle.main`
    /// (Config.xcconfig → Info.plist bridge) — mirrors
    /// `CommunityPinService.init(authService:realtimeChannel:)`'s own convenience init exactly
    /// (same two keys, same placeholder-URL fallback when Config.xcconfig hasn't been set up).
    convenience init(authService: SupabaseAuthService) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, authService: authService)
    }

    // MARK: - Registration entry point

    /// Requests remote-notification registration — but ONLY reuses the EXISTING notification
    /// permission flow's outcome; this method never itself presents any prompt (system or
    /// in-app). Two call sites, both pre-existing UI moments:
    ///   1. `NotificationRationaleView`'s `onPermissionGranted` callback (`ContentView.swift`)
    ///      — fires the instant the user grants permission through the W6 rationale sheet.
    ///   2. Defensively at launch and app-foreground, in case permission was already granted
    ///      in a PRIOR session (e.g. an existing user upgrading into a build where
    ///      `communityEnabled` just flipped true) — `getNotificationSettings` only READS the
    ///      current authorization status, it does not prompt.
    ///
    /// `registerForRemoteNotifications()` itself is idempotent and safe to call repeatedly
    /// per Apple's own documentation — no internal guard needed here beyond the flag check.
    func requestRegistrationIfEnabled() {
        guard communityEnabledProvider() else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // MARK: - Device token capture

    /// Called from `ContentView`'s `.onChange(of: appDelegate.pendingDeviceToken)` forwarding
    /// (mirrors the existing `pendingDeepLinkCarID` buffer-on-AppDelegate /
    /// drain-via-onChange-in-ContentView pattern, W6.1's proven fix for the "subscriber not
    /// attached yet" race — see `WeParkApp.swift`).
    func didReceiveDeviceToken(_ deviceToken: Data) {
        guard communityEnabledProvider() else { return }
        deviceTokenHex = Self.hexString(from: deviceToken)
        attemptUpsert()
    }

    // `nonisolated` even though the enclosing class is `@MainActor` — this is a pure,
    // no-instance-state function; without the annotation it would inherit the class's
    // MainActor isolation and be uncallable from a plain synchronous XCTestCase method.
    nonisolated static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Zone tracking

    /// Called by `ContentView` whenever the derived zone changes: the parked car moved,
    /// cleared, or (no car parked) the user's current location crossed into a different zone.
    /// `nil` means neither signal resolved to a known zone — the upload is skipped and stays
    /// skipped (spec §2.9: "a token without a zone receives nothing by design — the server
    /// fans out per zone").
    func updateZone(_ zoneId: String?) {
        guard communityEnabledProvider() else { return }
        currentZoneId = zoneId
        attemptUpsert()
    }

    /// Called on app foreground (`ContentView.handleScenePhaseChange`'s `.active` branch).
    /// Re-attempts the upload using whatever token/zone are currently known — a no-op if
    /// nothing has changed since the last successful upload (`attemptUpsert`'s own dedupe via
    /// `lastUploaded`).
    func handleAppForeground() {
        guard communityEnabledProvider() else { return }
        attemptUpsert()
    }

    // MARK: - Upload

    /// Builds the upsert payload as a pure, standalone function — split out from
    /// `upsertToken(_:)` so the payload SHAPE (task requirement: "token-upsert payload shape,
    /// user_id/env/zone") is directly unit-testable without a live `SupabaseAuthService` or
    /// network mock. `nonisolated` for the same reason as `hexString(from:)` above — this
    /// class is `@MainActor`, but this specific function touches no instance state and is
    /// called directly from a plain synchronous `XCTestCase` method.
    nonisolated static func tokenUpsertPayload(
        userId: UUID,
        tokenHex: String,
        environment: String,
        zoneId: String
    ) -> [String: Any] {
        [
            "user_id": userId.uuidString,
            "apns_token": tokenHex,
            "environment": environment,
            "zone_id": zoneId,
        ]
    }

    private func attemptUpsert() {
        guard communityEnabledProvider(),
              let tokenHex = deviceTokenHex,
              let zoneId = currentZoneId
        else { return }
        let environment = environmentProvider()
        let candidate = UploadKey(tokenHex: tokenHex, environment: environment, zoneId: zoneId)
        guard candidate != lastUploaded else { return }
        inFlightUpload = Task { [weak self] in
            await self?.upsertToken(candidate)
        }
    }

    private func upsertToken(_ candidate: UploadKey) async {
        guard let jwt = await authService.validAccessToken(),
              let userId = authService.currentUserId
        else { return }
        guard !Task.isCancelled else { return }

        let payload = Self.tokenUpsertPayload(
            userId: userId,
            tokenHex: candidate.tokenHex,
            environment: candidate.environment,
            zoneId: candidate.zoneId
        )
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // PR #101 QA pass 1 fix (Finding #1, BLOCKING): the request URL MUST carry
        // `on_conflict=user_id,apns_token` — the table's real `unique (user_id, apns_token)`
        // constraint (`supabase/03-community-2.0-schema.sql:535-542`). `device_push_tokens.id`
        // is a server-generated `uuid primary key` never present in `tokenUpsertPayload`'s
        // body; per PostgREST's documented default, an omitted `on_conflict` compiles to
        // `ON CONFLICT (id)`, which never actually conflicts (id is fresh every INSERT
        // attempt) — so the underlying INSERT instead hit the real `(user_id, apns_token)`
        // constraint as an UNCAUGHT `23505` error on every upsert after a device's first-ever
        // registration, silently defeating "re-upsert on zone change/foreground" (an explicit
        // acceptance criterion). Corroborated by this repo's own
        // `supabase/functions/ingest-film-permits/index.ts:507-518`, which documents the
        // identical PostgREST conflict-target-must-be-explicit behavior for a different table.
        // `user_id,apns_token` is a plain multi-column constraint (not a named/expression
        // index), so PostgREST resolves the bare comma-separated column list directly — no
        // index-name lookup needed, unlike ingest-film-permits' expression-index case.
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/device_push_tokens"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "user_id,apns_token")]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Upsert on the schema's `unique (user_id, apns_token)` constraint (spec §2.9), now
        // correctly targeted via the `on_conflict` query param above. Same `return=minimal`
        // shape `CommunityPinService.upsertVote`/`upsertProfile` already use — this avoids
        // needing SELECT rights on the table at all. (The PR #100 incident this file's header
        // cites was PostgREST-CLIENT-default `return=representation`, which DOES require
        // SELECT — this codebase's own raw-URLSession write paths have always opted OUT of
        // that default explicitly via this exact header; §2.9's amendment adding an
        // owner-read-own SELECT policy is an independent, additional safety net, not something
        // this write path depends on.)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = body

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            lastUploaded = candidate
        } catch {
            // Best-effort — the next zone change / foreground / relaunch retries naturally,
            // since `attemptUpsert`'s dedupe only skips when the LAST upload SUCCEEDED
            // (`lastUploaded` is only ever set in the success branch above).
        }
    }
}
