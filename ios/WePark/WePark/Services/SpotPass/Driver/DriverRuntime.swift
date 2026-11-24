//
//  DriverRuntime.swift
//  Services/SpotPass/Driver
//
//  Spot Pass C2: the app-lifetime home of the driver flow. ONE `DriverFlowController` serves the
//  UI, the Live Activity App Intents, the reminder notification actions and the Start Driving
//  hook, so a lock-screen "Leaving now" tap and the on-screen state can never diverge.
//
//  Nothing here runs with `AppConstants.spotHandoffEnabled == false`: the controller is built
//  lazily on first use, every entry point is gated by the flag at its call site, and the intent
//  performer is only registered when the flag is on.
//
//  DEBUG (compiled out of Release), reusing the clip's launch options (`ClipLaunchOptions`):
//    -spotPassUseFakeAPI YES            fake peek/claim/depart (real ActivityKit, notifications, keychain)
//    -spotPassFakeScenario <name>       open | unavailable | offline | disabled | slowPeek | claimOffline | noID | departFails
//    -spotPassClipURL <https url>       inject a universal link at launch (simctl cannot deliver one)
//    -spotPassFakeLeaveSeconds <n>      the fake claim returns leave_at = now + n s
//    -spotPassFakeThanksAfter <n>       n s after a depart, simulate the seeker's thanks
//    -spotPassSeedCarryOver YES         write a fake clip carry-over context (see `SpotPassWelcomeDebug`)
//

import Foundation
import Observation

// MARK: - Intent performer

/// The app's side of the App Intent bridge (`SpotPassIntentRuntime`). Pure forwarding: the logic
/// (and its tests) live in `DriverFlowController`.
@MainActor
final class SpotPassDriverIntentPerformer: SpotPassIntentPerforming {

    private let controller: () -> DriverFlowController

    init(controller: @escaping () -> DriverFlowController) {
        self.controller = controller
    }

    /// A pass id means the button was rendered on the Live Activity; none means Shortcuts (spec 7.5).
    func leavingNow(passID: String?) async -> SpotPassIntentOutcome {
        await controller().leavingNow(source: passID == nil ? .shortcut : .liveActivity, passID: passID)
    }

    func fiveMoreMinutes(passID: String?) async -> SpotPassIntentOutcome {
        await controller().fiveMoreMinutes(passID: passID)
    }

    func notLeaving(passID: String?) async -> SpotPassIntentOutcome {
        await controller().notLeaving(passID: passID)
    }
}

// MARK: - Start Driving gate

nonisolated enum SpotPassStartDriving {
    /// Start Driving tells the neighbor ONLY while the feature is on AND an armed, unexpired pass
    /// exists (spec 7.4: it never creates or arms anything).
    static func shouldDepart(enabled: Bool, hasArmedPass: Bool) -> Bool {
        enabled && hasArmedPass
    }

    static let toast = "Told your neighbor you're leaving."
}

// MARK: - Runtime

@MainActor
@Observable
final class SpotPassDriverRuntime {

    static let shared = SpotPassDriverRuntime()

    /// Drives the driver full-screen cover (the host is `SpotPassDriverLayer`).
    var coverPresented = false
    /// A clip-origin first launch wants the tailored Welcome (set by `SpotPassWelcomeCoordinator`).
    var welcomeRequested = false

    /// The shared auth service's token, set once ContentView mounts. nil in a background intent launch
    /// (depart/extend/cancel need none; only the claim uses it).
    @ObservationIgnored var accessTokenProvider: (() async -> String?)?
    @ObservationIgnored var pushTokenProvider: (() -> String?)?
    @ObservationIgnored var showToast: (String) -> Void = { ToastService.shared.show(message: $0) }

    @ObservationIgnored private var built: DriverFlowController?
    @ObservationIgnored private let factoryOverride: (() -> DriverFlowController)?

    init(factory: (() -> DriverFlowController)? = nil) {
        factoryOverride = factory
    }

    var controller: DriverFlowController {
        if let built { return built }
        let made = factoryOverride?() ?? makeLiveController()
        built = made
        return made
    }

    /// True once the controller exists (so flag-on-but-unused paths never build it).
    var hasController: Bool { built != nil }

    // MARK: Composition

    private func makeLiveController() -> DriverFlowController {
        let dependencies = DriverDependencies(
            api: makeAPI(),
            secrets: makeSecretStore(),
            passStore: UserDefaultsHandoffPassStore(defaults: .standard),
            session: AuthServiceDriverSession(tokenProvider: { [weak self] in await self?.accessTokenProvider?() }),
            reminders: DriverReminderScheduler(),
            activity: AppActivityController(),
            pushToken: AppNotificationPushToken(tokenHex: { [weak self] in self?.pushTokenProvider?() }),
            feedback: SystemHandoffFeedback()
        )
        return DriverFlowController(dependencies: dependencies)
    }

    /// The real keychain store; in DEBUG fake-API mode an in-memory one, so an UNSIGNED simulator build
    /// (where the keychain write fails) can still arm. Compiled out of Release.
    private func makeSecretStore() -> any HandoffSecretStoring {
        #if DEBUG
        let options = ClipLaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        if options.useFakeAPI { return DebugInMemoryHandoffSecretStore() }
        #endif
        return DriverKeychainSecretStore()
    }

    private func makeAPI() -> any HandoffDriverAPI {
        #if DEBUG
        let options = ClipLaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        if options.useFakeAPI {
            let fake = FakeHandoffDriverAPI(scenario: options.scenario, leaveSecondsOverride: options.fakeLeaveSeconds)
            guard let after = options.fakeThanksAfter else { return fake }
            return DepartObservingAPI(inner: fake) { [weak self] in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    self?.built?.receiveThanks()
                }
            }
        }
        #endif
        return URLSessionHandoffDriverAPI(bundle: .main) ?? UnconfiguredHandoffDriverAPI()
    }

    // MARK: Links

    #if DEBUG
    @ObservationIgnored private var debugInjected = false

    /// DEBUG: `-spotPassClipURL <https url>` (or `_XCAppClipURL`) delivers a universal link at launch.
    /// `simctl openurl` cannot reach the app for an https link (the system sends it to Safari), so QA uses this.
    func injectDebugLinkIfRequested(enabled: Bool = AppConstants.spotHandoffEnabled, inbox: SpotPassLinkInbox = .shared) {
        guard enabled, !debugInjected else { return }
        let options = ClipLaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        guard let url = options.injectedURL, let link = SpotPassLink(url: url) else { return }
        debugInjected = true
        inbox.pending = link
    }
    #endif

    /// Drains the buffered universal link (cold launch, or one that arrived before ContentView mounted).
    func drainInbox(
        enabled: Bool = AppConstants.spotHandoffEnabled,
        inbox: SpotPassLinkInbox = .shared
    ) {
        guard enabled, let link = inbox.pending else { return }
        inbox.pending = nil
        present(link: link)
    }

    /// Starts or resumes the flow for `link` and raises the cover when there is something to show.
    @discardableResult
    func present(link: SpotPassLink) -> Bool {
        if controller.handle(link: link) {
            coverPresented = true
            return true
        }
        // The generic landing with nothing active: a friendly line, never a dead end (spec 5.3).
        showToast(ClipCopy.landingBody)
        return false
    }

    /// An armed, unexpired driver pass exists (drives the "Your Spot Pass" More row). Never builds the
    /// controller just to find out: a stored record is read directly.
    var hasArmedPass: Bool {
        if hasController { return controller.hasArmedPass }
        guard let saved = UserDefaultsHandoffPassStore(defaults: .standard).load() else { return false }
        return saved.status == .armed && Date() < saved.expiresAt
    }

    /// "Your Spot Pass": reopens the armed pass's cover (the cover was closed, the pass stays on).
    func presentArmedPass() {
        guard hasArmedPass else { return }
        coverPresented = true
    }

    /// The reminder notification body was tapped: straight to the pulling-out screen (spec 7.3).
    func presentPullingOut() {
        guard controller.pass != nil else { return }
        controller.perform(.openPullingOut)
        coverPresented = true
    }

    // MARK: Push

    /// Seeker-originated pushes that concern the DRIVER: `thanks` and `handoff_ended`.
    func handle(push event: SpotPassPushEvent) async {
        let current = controller
        // A push for some other pass (the user is also a seeker) must not touch this one.
        if let id = event.handoffID, let pass = current.pass, pass.id != id { return }
        switch event.kind {
        case .thanks:
            guard current.receiveThanks() else { return }
            if event.opened {
                coverPresented = true
            } else if !coverPresented {
                showToast("\(ClipCopy.thanksHeadline) \(ClipCopy.thanksSub(name: current.displayName ?? "A neighbor"))")
                current.dismissCelebration()
            }
        case .handoffEnded:
            await current.receiveHandoffEnded()
        case .armed, .departed:
            break
        }
    }

    /// A pass is persisted from an earlier session (so the controller is worth building).
    private var storedPassExists: Bool {
        UserDefaultsHandoffPassStore(defaults: .standard).load() != nil
    }

    /// App became active: pick up anything a background intent or action changed, expire a lapsed pass.
    /// Never builds the controller when there is nothing it could act on.
    func foregrounded() async {
        guard hasController || storedPassExists else { return }
        await controller.refreshFromStorage()
    }

    // MARK: Start Driving

    /// Called from the Start Driving tap, BEFORE drive mode begins. Fire-and-forget: the drive must
    /// never wait on the network.
    func startDriving(enabled: Bool = AppConstants.spotHandoffEnabled) {
        guard enabled, hasController || storedPassExists else { return }
        Task {
            let driver = controller
            guard SpotPassStartDriving.shouldDepart(enabled: enabled, hasArmedPass: driver.hasArmedPass) else { return }
            if await driver.departForStartDriving() {
                showToast(SpotPassStartDriving.toast)
            }
        }
    }

    // MARK: Registration

    /// AppDelegate, flag-gated: lets a lock-screen intent reach the controller even in a background launch.
    func registerIntentPerformer() {
        SpotPassIntentRuntime.performer = SpotPassDriverIntentPerformer(controller: { self.controller })
    }
}

#if DEBUG
/// DEBUG: forwards to `inner` and reports each SUCCESSFUL depart (to simulate the seeker's thanks).
@MainActor
final class DepartObservingAPI: HandoffDriverAPI {
    private let inner: any HandoffDriverAPI
    private let onDeparted: () -> Void

    init(inner: any HandoffDriverAPI, onDeparted: @escaping () -> Void) {
        self.inner = inner
        self.onDeparted = onDeparted
    }

    func peek(token: String) async throws -> HandoffPeekResult { try await inner.peek(token: token) }
    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult {
        try await inner.claim(request, userJWT: userJWT)
    }
    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool {
        let ok = try await inner.depart(id: id, secret: secret, source: source)
        if ok { onDeparted() }
        return ok
    }
    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult { try await inner.extend(id: id, secret: secret) }
    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool { try await inner.cancel(id: id, secret: secret) }
    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool {
        try await inner.report(target: target, reason: reason)
    }
}
#endif
