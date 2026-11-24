//
//  AutoDetectController.swift
//  Services/SpotPass/Driver/AutoDetect
//
//  Spot Pass C4 (spec 7.4, 9): the armed-window lifecycle. It owns one location window at a time:
//
//      open (foreground, armed pass, opted in, saved car, leave time within 30 min)
//        -> hold a CLBackgroundActivitySession (blue pill) + location updates
//        -> feed fixes to `DepartureDetector`
//        -> on detection: stop everything FIRST, then tell the flow (one shot)
//      hard stops: depart / cancel / seeker-ended / expiry / 60 min cap / Turn off / app terminated
//
//  Safety rules enforced here (spec 9 items 1, 6, 15, 16):
//    - Nothing runs unless `spotHandoffAutoDetectEnabled`, the build declares the `location`
//      background mode, the driver opted in on the purpose screen, a car is saved and When In Use
//      is granted. We never request Always.
//    - The window only ever starts from the foreground (a background session cannot be created).
//    - No coordinate leaves the device and none is logged or persisted: the anchor and the
//      detector live in memory until `close`, and the ONLY outbound call this feature causes is the
//      flow's normal depart event (`{id, claimer_secret, source: "auto"}`).
//    - `close` is idempotent and stops location + invalidates the session on every path.
//
//  Isolation: the module defaults to MainActor. The CoreLocation work is an async sequence consumed
//  on the main actor (no delegate, so no `nonisolated` delegate hop); pure rules are in
//  `AutoDetectLogic.swift` and are `nonisolated`.
//

import Foundation
import Observation

// MARK: - Collaborators

/// A started window's background session (iOS 17 `CLBackgroundActivitySession`). `invalidate` ends the pill.
@MainActor
protocol AutoDetectBackgroundSession: AnyObject {
    func invalidate()
}

/// Location for the window. `start` delivers fixes on the main actor until `stop`.
@MainActor
protocol AutoDetectLocationProviding: AnyObject {
    var authorization: AutoDetectAuthorization { get }
    /// Shows the system When In Use prompt if undetermined (never Always). Returns the resulting status.
    func requestWhenInUse() async -> AutoDetectAuthorization
    func start(onFix: @escaping @MainActor (AutoDetectFix) -> Void)
    func stop()
}

@MainActor
protocol AutoDetectOptInStoring: AnyObject {
    var isOptedIn: Bool { get set }
}

/// What `DriverFlowController` needs from auto-detect (so tests and the flag-off path can use `nil`).
@MainActor
protocol AutoDetectControlling: AnyObject {
    var isRunning: Bool { get }
    var offer: AutoDetectOffer { get }
    /// The detector fired (the window is already closed): the flow should depart with source `auto`.
    var onDetected: (() -> Void)? { get set }
    /// The window opened (`reason == nil`) or ended.
    var onRunningChanged: ((Bool, AutoDetectEndReason?) -> Void)? { get set }
    func refreshOffer()
    func enable() async -> AutoDetectEnableResult
    func turnOff()
    func openIfEligible(passID: UUID, leaveAt: Date, expiresAt: Date)
    func passExtended(expiresAt: Date)
    func close(_ reason: AutoDetectEndReason)
}

nonisolated enum AutoDetectEnableResult: Equatable, Sendable {
    case enabled
    case needsSavedCar
    case locationDenied
    case unavailable
}

// MARK: - Controller

@MainActor
@Observable
final class AutoDetectController: AutoDetectControlling {

    private(set) var isRunning = false
    private(set) var offer: AutoDetectOffer = .hidden
    private(set) var isOptedIn: Bool

    @ObservationIgnored var onDetected: (() -> Void)?
    @ObservationIgnored var onRunningChanged: ((Bool, AutoDetectEndReason?) -> Void)?

    // MARK: Dependencies
    @ObservationIgnored private let flagEnabled: Bool
    @ObservationIgnored private let backgroundModeDeclared: () -> Bool
    @ObservationIgnored private let optIn: any AutoDetectOptInStoring
    @ObservationIgnored private let anchorProvider: () -> AutoDetectAnchor?
    @ObservationIgnored private let location: any AutoDetectLocationProviding
    @ObservationIgnored private let makeSession: () -> any AutoDetectBackgroundSession
    @ObservationIgnored private let isForeground: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleeper: @Sendable (TimeInterval) async -> Void

    // MARK: Window state (memory only, cleared in `close`)
    @ObservationIgnored private var detector: DepartureDetector?
    @ObservationIgnored private var session: (any AutoDetectBackgroundSession)?
    @ObservationIgnored private var windowPassID: UUID?
    @ObservationIgnored private var openedAt: Date?
    @ObservationIgnored private var passExpiresAt: Date?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?

    /// A fix older than this is a cached one from before the window and is ignored.
    nonisolated static let maxFixAge: TimeInterval = 15

    init(
        flagEnabled: Bool? = nil,
        backgroundModeDeclared: @escaping () -> Bool = { AutoDetectCapability.backgroundModeDeclared() },
        optIn: any AutoDetectOptInStoring,
        anchorProvider: @escaping () -> AutoDetectAnchor?,
        location: any AutoDetectLocationProviding,
        makeSession: @escaping () -> any AutoDetectBackgroundSession,
        isForeground: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.flagEnabled = flagEnabled ?? AppConstants.spotHandoffAutoDetectEnabled
        self.backgroundModeDeclared = backgroundModeDeclared
        self.optIn = optIn
        self.anchorProvider = anchorProvider
        self.location = location
        self.makeSession = makeSession
        self.isForeground = isForeground
        self.now = now
        self.sleeper = sleeper
        isOptedIn = optIn.isOptedIn
        refreshOffer()
    }

    // MARK: - Offer / opt-in

    func refreshOffer() {
        isOptedIn = optIn.isOptedIn
        offer = AutoDetectAvailability.offer(
            flagEnabled: flagEnabled, backgroundModeDeclared: backgroundModeDeclared(),
            optedIn: isOptedIn, hasAnchor: anchorProvider() != nil,
            authorization: location.authorization, isRunning: isRunning
        )
    }

    /// The purpose screen's primary button (second explicit opt-in, spec 9 item 1).
    func enable() async -> AutoDetectEnableResult {
        guard AutoDetectAvailability.isSupported(flagEnabled: flagEnabled, backgroundModeDeclared: backgroundModeDeclared()) else {
            return .unavailable
        }
        guard anchorProvider() != nil else {
            refreshOffer()
            return .needsSavedCar
        }
        var status = location.authorization
        if status == .notDetermined { status = await location.requestWhenInUse() }
        guard status == .authorized else {
            refreshOffer()
            return .locationDenied
        }
        optIn.isOptedIn = true
        refreshOffer()
        return .enabled
    }

    /// "Turn off": stops this window AND withdraws the opt-in, so the next pass never starts a window the
    /// driver said no to. They can opt in again from the same row.
    func turnOff() {
        optIn.isOptedIn = false
        if isRunning { close(.turnedOff) } else { refreshOffer() }
    }

    // MARK: - Open

    /// Opens the window if every precondition holds; otherwise does nothing (manual still works).
    /// Idempotent for the same pass. MUST be called from the foreground: a background session cannot be created.
    func openIfEligible(passID: UUID, leaveAt: Date, expiresAt: Date) {
        if isRunning {
            if windowPassID == passID { return }
            close(.replaced)
        }
        let savedAnchor = anchorProvider()
        guard AutoDetectAvailability.canRun(
            flagEnabled: flagEnabled, backgroundModeDeclared: backgroundModeDeclared(),
            optedIn: optIn.isOptedIn, hasAnchor: savedAnchor != nil, authorization: location.authorization
        ), let anchor = savedAnchor else {
            refreshOffer()
            return
        }
        let opened = now()
        guard AutoDetectWindowPolicy.shouldOpen(now: opened, leaveAt: leaveAt, expiresAt: expiresAt), isForeground() else {
            refreshOffer()
            return
        }
        detector = DepartureDetector(anchor: anchor)
        openedAt = opened
        passExpiresAt = expiresAt
        windowPassID = passID
        session = makeSession()
        isRunning = true
        location.start { [weak self] fix in self?.receive(fix) }
        scheduleDeadline()
        refreshOffer()
        onRunningChanged?(true, nil)
    }

    /// The driver bought five more minutes: the window may run to the new expiry (still capped at 60 min).
    func passExtended(expiresAt: Date) {
        guard isRunning else { return }
        passExpiresAt = expiresAt
        scheduleDeadline()
    }

    // MARK: - Fixes

    /// Internal (not private) so tests can feed synthetic fixes through the same path the provider uses.
    func receive(_ fix: AutoDetectFix) {
        guard isRunning, !enforceDeadline() else { return }
        guard now().timeIntervalSince(fix.timestamp) <= Self.maxFixAge else { return }
        guard var current = detector else { return }
        let fired = current.ingest(fix)
        detector = current
        guard fired else { return }
        // One shot: stop location and drop the session BEFORE anything else happens.
        close(.detected)
        onDetected?()
    }

    // MARK: - Deadline

    /// Closes the window if its deadline (60 min cap or pass expiry) has passed. Returns true if it closed.
    @discardableResult
    func enforceDeadline() -> Bool {
        guard isRunning, let opened = openedAt, let expires = passExpiresAt else { return false }
        let current = now()
        guard current >= AutoDetectWindowPolicy.deadline(openedAt: opened, expiresAt: expires) else { return false }
        close(AutoDetectWindowPolicy.endReason(now: current, expiresAt: expires))
        return true
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let opened = openedAt, let expires = passExpiresAt else { return }
        let wait = AutoDetectWindowPolicy.deadline(openedAt: opened, expiresAt: expires).timeIntervalSince(now())
        let sleeper = self.sleeper
        deadlineTask = Task { [weak self] in
            await sleeper(wait)
            guard !Task.isCancelled else { return }
            self?.enforceDeadline()
        }
    }

    // MARK: - Close

    /// Stops location, invalidates the session (the blue pill goes away), drops the anchor and the
    /// detector. Idempotent: safe to call from every terminal path.
    func close(_ reason: AutoDetectEndReason) {
        guard isRunning else { return }
        location.stop()
        session?.invalidate()
        session = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        detector = nil
        windowPassID = nil
        openedAt = nil
        passExpiresAt = nil
        isRunning = false
        refreshOffer()
        onRunningChanged?(false, reason)
    }

    /// `UIApplication.willTerminateNotification`: leave nothing running.
    func appWillTerminate() {
        close(.terminated)
    }
}

// MARK: - Opt-in persistence

@MainActor
final class UserDefaultsAutoDetectOptIn: AutoDetectOptInStoring {
    static let key = "spotPassAutoDetectOptedIn"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isOptedIn: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
