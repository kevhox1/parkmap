//
//  ClipFlowController.swift
//  Shared/SpotPass/Driver
//
//  Spot Pass C3: the App Clip's state machine (spec section 3, design section 3). Lives in Shared
//  so unit tests (which build against the app target) can drive it with fakes; the clip's views
//  only render it.
//
//  Phases:  landing -> choosing -> arming -> armed -> pullingOut -> sending -> sent -> celebration
//           (+ unavailable / offline / busy / disabled / openApp / dismissed / cancelled / ended)
//
//  Safety rules enforced here (spec 9):
//    - Nothing arms until the driver taps the CTA ("Now" included: it arms and OPENS the
//      Time-to-go screen; it never departs by itself).
//    - Opening a deep link never cancels (cancel needs the confirm or the explicit action button).
//    - The claimer secret lives only in `HandoffSecretStoring` and is never logged or persisted elsewhere.
//

import Foundation
import Observation

nonisolated enum ClipPhase: Equatable, Sendable {
    case landing
    case choosing
    case arming
    case armed
    case pullingOut
    case sending
    case sent
    case celebration
    case unavailable
    case offline
    case busy
    case disabled
    /// The server armed the pass but did not return its id (old backend): the clip cannot manage it.
    case openApp
    case dismissed
    case cancelled
    case ended
}

nonisolated enum ClipArmFailure: Equatable, Sendable {
    case offline
    case busy
}

/// Once-per-launch install card (design F8): shown after the celebration, never twice in a launch.
nonisolated struct ClipInstallPromptPolicy: Equatable, Sendable {
    private(set) var shownThisLaunch = false

    mutating func shouldPresent() -> Bool {
        guard !shownThisLaunch else { return false }
        shownThisLaunch = true
        return true
    }
}

/// Notification delivery -> what the clip should do.
nonisolated enum ClipNotificationRoute: Equatable, Sendable {
    case thanks
    case action(ClipDeepAction)
    case ignore

    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> ClipNotificationRoute {
        if (userInfo["kind"] as? String) == "thanks" { return .thanks }
        if let action = HandoffReminderPlan.deepAction(forActionIdentifier: actionIdentifier) { return .action(action) }
        return .ignore
    }
}

struct ClipDependencies {
    let api: any HandoffDriverAPI
    let secrets: any HandoffSecretStoring
    let passStore: any HandoffPassStoring
    let session: any ClipSessionProviding
    let reminders: any HandoffReminderScheduling
    let activity: any HandoffActivityControlling
    let pushToken: any HandoffPushTokenProviding
    let feedback: any HandoffFeedback
    let carryOver: ClipHandoffContextStore
    var now: () -> Date = { Date() }
    /// How long the "Sent" confirmation shows before the celebration (design 3.6: 1.2 s).
    var sentDwell: TimeInterval = 1.2
}

@Observable
@MainActor
final class ClipFlowController {

    // MARK: Observable state
    private(set) var phase: ClipPhase = .landing
    private(set) var preview: HandoffPassPreview?
    var choice: LeaveChoice = .default
    private(set) var pass: HandoffActivePass?
    private(set) var reminderAvailability: HandoffReminderAvailability = .on
    private(set) var activityStarted = false
    private(set) var activitiesEnabled = true
    private(set) var armFailure: ClipArmFailure?
    private(set) var sendFailed = false
    var showCancelConfirm = false
    var toast: String?
    private(set) var showInstallCard = false

    // MARK: Private
    @ObservationIgnored private let deps: ClipDependencies
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var handledTokenURLs: Set<URL> = []
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var departMayHaveReachedServer = false
    @ObservationIgnored private(set) var installPolicy = ClipInstallPromptPolicy()

    init(dependencies: ClipDependencies) {
        deps = dependencies
        deps.activity.onRemotePhase = { [weak self] phase in self?.handleRemotePhase(phase) }
        restore()
    }

    var now: Date { deps.now() }

    /// The name used in copy: alias / opt-in first name from the peek, else the stored pass.
    var displayName: String? { pass?.name ?? preview?.name }
    var glyph: String { pass?.glyph ?? preview?.glyph ?? "" }
    var alias: String { pass?.alias ?? preview?.alias ?? "" }

    // MARK: - Restore (a notification launch carries no invocation URL; spec 5.1)

    private func restore() {
        guard let saved = deps.passStore.load() else { return }
        switch saved.status {
        case .armed:
            if deps.now() >= saved.expiresAt {
                cleanupLocal(passID: saved.id)
                phase = .ended
            } else {
                pass = saved
                phase = .armed
            }
        case .departed:
            pass = saved
            phase = .celebration
        }
    }

    // MARK: - Invocation

    func handle(url: URL) {
        guard let link = SpotPassLink(url: url) else { return }
        if let token = link.token {
            guard handledTokenURLs.insert(url).inserted else { return }
            // An active pass wins: its own token is already claimed, so a re-scan would only say "used".
            guard pass == nil else { return }
            begin(token: token)
        } else if let action = link.action {
            perform(action)
        }
    }

    private func begin(token: String) {
        self.token = token
        preview = nil
        armFailure = nil
        phase = .choosing
        peekTask?.cancel()
        peekTask = Task { await runPeek(token: token) }
    }

    func retry() {
        guard let token else { return }
        begin(token: token)
    }

    private func runPeek(token: String) async {
        do {
            let result = try await deps.api.peek(token: token)
            guard phase == .choosing || phase == .arming else { return }
            switch result {
            case .open(let found): preview = found
            case .unavailable: phase = .unavailable
            }
        } catch let error as HandoffAPIError {
            guard phase == .choosing || phase == .arming else { return }
            phase = Self.phase(for: error)
        } catch {
            if phase == .choosing || phase == .arming { phase = .offline }
        }
    }

    private static func phase(for error: HandoffAPIError) -> ClipPhase {
        switch error {
        case .disabled: return .disabled
        case .rateLimited: return .busy
        default: return .offline
        }
    }

    // MARK: - Choosing

    func select(_ newChoice: LeaveChoice) {
        guard phase == .choosing else { return }
        choice = newChoice
        deps.feedback.selection()
    }

    func notLeavingSoon() {
        guard phase == .choosing else { return }
        phase = .dismissed
    }

    // MARK: - Arm

    func arm() async {
        guard phase == .choosing, let token else { return }
        armFailure = nil
        phase = .arming
        deps.feedback.armImpact()
        await peekTask?.value                       // the alias is needed for the activity; peek is short
        guard phase == .arming else { return }

        let startedAt = deps.now()
        let requestedLeave = choice.leaveAt(from: startedAt)
        let name = preview?.name ?? "A neighbor"
        let activityGlyph = preview?.glyph ?? SpotPassGlyph.fallbackSymbol

        reminderAvailability = await deps.reminders.availability()
        activitiesEnabled = deps.activity.areActivitiesEnabled
        async let sessionResult = deps.session.session()
        async let pushResult = pushTokenIfWanted()
        let started = await deps.activity.start(name: name, glyph: activityGlyph, leaveAt: requestedLeave, startedAt: startedAt)
        let session = await sessionResult
        let pushToken = await pushResult
        activityStarted = started.didStart

        let request = HandoffClaimRequest(
            token: token, leaveAt: requestedLeave, pushToken: pushToken, activityToken: started.token,
            topic: (pushToken != nil || started.token != nil) ? SpotPassShared.clipBundleID : nil
        )
        let result: HandoffClaimResult
        do {
            result = try await deps.api.claim(request, userJWT: session?.accessToken)
        } catch let error as HandoffAPIError {
            await endActivityIfStarted(.ended)
            switch error {
            case .disabled: phase = .disabled
            case .rateLimited: armFailure = .busy; phase = .choosing
            default: armFailure = .offline; phase = .choosing
            }
            return
        } catch {
            await endActivityIfStarted(.ended)
            armFailure = .offline
            phase = .choosing
            return
        }

        switch result {
        case .unavailable:
            await endActivityIfStarted(.ended)
            phase = .unavailable
        case .armed(let grant):
            guard let passID = grant.passID else {
                // Old backend (no `id`): we cannot depart/extend/cancel. Calm fallback, never a silent failure.
                await endActivityIfStarted(.ended)
                phase = .openApp
                return
            }
            await finishArming(grant: grant, passID: passID, name: name, userId: session?.userId, startedAt: startedAt)
        }
    }

    private func finishArming(grant: HandoffArmedGrant, passID: UUID, name: String, userId: String?, startedAt: Date) async {
        deps.secrets.save(grant.secret, passID: passID)
        let armed = HandoffActivePass(
            id: passID, alias: preview?.alias ?? name, glyph: preview?.glyph ?? SpotPassGlyph.fallbackSymbol,
            displayName: preview?.displayName, armedAt: startedAt, leaveAt: grant.leaveAt,
            expiresAt: grant.expiresAt, extensions: 0, status: .armed, departedAt: nil,
            thanksReceived: false, userId: userId
        )
        pass = armed
        deps.passStore.save(armed)
        await scheduleReminders(for: armed)
        if activityStarted {
            await deps.activity.update(phase: .counting, leaveAt: grant.leaveAt, startedAt: startedAt)
        }
        // "Now" opens straight on the Time-to-go screen and never departs by itself (design F7).
        phase = choice.isNow ? .pullingOut : .armed
        deps.feedback.announce(ClipCopy.armedHeadline)
    }

    private func pushTokenIfWanted() async -> String? {
        guard reminderAvailability == .on else { return nil }
        return await deps.pushToken.deviceToken()
    }

    private func scheduleReminders(for pass: HandoffActivePass) async {
        guard reminderAvailability == .on else { return }
        let plan = HandoffReminderPlan.make(
            passID: pass.id, name: pass.name, leaveAt: pass.leaveAt, expiresAt: pass.expiresAt, now: deps.now()
        )
        await deps.reminders.schedule(plan, passID: pass.id)
    }

    // MARK: - Pulling out

    func showPullingOut() {
        guard pass?.status == .armed, phase == .armed else { return }
        phase = .pullingOut
    }

    func backToArmed() {
        if phase == .pullingOut { phase = .armed }
    }

    func pullOut(source: HandoffDepartSource = .manual) async {
        guard var current = pass, current.status == .armed, phase == .armed || phase == .pullingOut,
              let secret = deps.secrets.secret(for: current.id)
        else { return }
        sendFailed = false
        phase = .sending
        let sent: Bool
        do {
            let ok = try await deps.api.depart(id: current.id, secret: secret, source: source)
            // ok:false on a RETRY after a lost response = "may already be sent": treat as sent.
            sent = ok || departMayHaveReachedServer
        } catch let error as HandoffAPIError {
            if error != .disabled && error != .rateLimited { departMayHaveReachedServer = true }
            sendFailed = true
            phase = .pullingOut
            return
        } catch {
            departMayHaveReachedServer = true
            sendFailed = true
            phase = .pullingOut
            return
        }

        guard sent else {
            await endPass(phase: .ended)
            return
        }
        current.status = .departed
        current.departedAt = deps.now()
        pass = current
        deps.passStore.save(current)
        deps.secrets.clear()
        deps.reminders.cancelAll(passID: current.id)
        recordDeparture(current)
        deps.feedback.success()
        phase = .sent
        deps.feedback.announce(ClipCopy.sentLine(name: current.name))
        if activityStarted { await deps.activity.update(phase: .sent, leaveAt: nil, startedAt: nil) }
        if deps.sentDwell > 0 { try? await Task.sleep(nanoseconds: UInt64(deps.sentDwell * 1_000_000_000)) }
        if activityStarted { await deps.activity.update(phase: .passed, leaveAt: nil, startedAt: nil) }
        if phase == .sent { phase = .celebration }
    }

    private func recordDeparture(_ departed: HandoffActivePass) {
        guard let userId = departed.userId, !userId.isEmpty else { return }
        let updated = ClipCarryOver.afterDeparture(
            existing: deps.carryOver.load(), userId: userId, alias: departed.alias, now: deps.now()
        )
        deps.carryOver.save(updated)
    }

    // MARK: - Extend / cancel

    func extendFiveMinutes() async {
        guard var current = pass, current.status == .armed, current.extensions < HandoffActivePass.maxExtensions,
              let secret = deps.secrets.secret(for: current.id)
        else {
            toast = ClipCopy.extendFailed
            return
        }
        do {
            let result = try await deps.api.extend(id: current.id, secret: secret)
            guard result.ok else { toast = ClipCopy.extendFailed; return }
            current.leaveAt = result.leaveAt ?? current.leaveAt.addingTimeInterval(300)
            current.expiresAt = result.expiresAt ?? current.expiresAt.addingTimeInterval(300)
            current.extensions += 1
            pass = current
            deps.passStore.save(current)
            await scheduleReminders(for: current)
            if activityStarted { await deps.activity.update(phase: .counting, leaveAt: current.leaveAt, startedAt: current.armedAt) }
            toast = ClipCopy.extendDone
            deps.feedback.announce(ClipCopy.extendDone)
        } catch {
            toast = ClipCopy.extendFailed
        }
    }

    func requestCancel() {
        guard pass?.status == .armed else { return }
        showCancelConfirm = true
    }

    func confirmCancel() async {
        showCancelConfirm = false
        guard let current = pass, current.status == .armed,
              let secret = deps.secrets.secret(for: current.id)
        else { return }
        do {
            _ = try await deps.api.cancel(id: current.id, secret: secret)   // ok:false = already gone: same outcome
        } catch {
            toast = ClipCopy.cancelFailed
            return
        }
        await endPass(phase: .cancelled)
    }

    // MARK: - Expiry / remote events

    /// Called by a timer while the clip is foregrounded.
    func tick() async {
        guard let current = pass, current.status == .armed, deps.now() >= current.expiresAt else { return }
        await endPass(phase: .ended)
    }

    func receiveThanks() {
        guard var current = pass, current.status == .departed, !current.thanksReceived else { return }
        current.thanksReceived = true
        pass = current
        deps.passStore.save(current)
        if let settled = ClipCarryOver.afterThanks(existing: deps.carryOver.load()) { deps.carryOver.save(settled) }
        deps.feedback.success()
        deps.feedback.announce(ClipCopy.thanksHeadline)
        phase = .celebration
        Task { await deps.activity.end(phase: .thanks, now: deps.now()) }
    }

    private func handleRemotePhase(_ remote: SpotPassActivityAttributes.Phase) {
        switch remote {
        case .thanks:
            receiveThanks()
        case .ended:
            if let current = pass, current.status == .armed { Task { await endPass(phase: .ended) } }
        default:
            break
        }
    }

    func handleNotification(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        switch ClipNotificationRoute.route(actionIdentifier: actionIdentifier, userInfo: userInfo) {
        case .thanks: receiveThanks()
        case .action(let action): perform(action)
        case .ignore: break
        }
    }

    // MARK: - Deep actions

    func perform(_ action: ClipDeepAction) {
        guard let current = pass else { return }
        switch action {
        case .openPullingOut:
            if current.status == .armed, phase == .armed { phase = .pullingOut }
        case .leavingNow(let source):
            Task { await pullOut(source: source) }
        case .extend:
            Task { await extendFiveMinutes() }
        case .confirmCancel:
            if current.status == .armed {
                if phase == .armed { phase = .pullingOut }
                showCancelConfirm = true
            }
        case .cancelNow:
            Task { await confirmCancel() }
        }
    }

    // MARK: - Report

    func report(_ reason: HandoffReportReason) async {
        let target: HandoffReportTarget
        if let current = pass, current.status == .armed, let secret = deps.secrets.secret(for: current.id) {
            target = .claimed(id: current.id, secret: secret)
        } else if let token {
            target = .token(token)
        } else {
            return
        }
        guard (try? await deps.api.report(target: target, reason: reason)) == true else { return }
        toast = ClipCopy.reportThanks
        if pass?.status == .armed { await endPass(phase: .ended) } else { phase = .unavailable }
    }

    // MARK: - Install card

    /// The celebration view calls this ~1.5 s after the celebration lands.
    func celebrationLanded() {
        guard phase == .celebration, installPolicy.shouldPresent() else { return }
        showInstallCard = true
    }

    func dismissInstallCard() { showInstallCard = false }

    func dismissCelebration() {
        phase = .dismissed
    }

    // MARK: - Teardown

    private func endPass(phase newPhase: ClipPhase) async {
        guard let current = pass else { phase = newPhase; return }
        cleanupLocal(passID: current.id)
        pass = nil
        let activityPhase: SpotPassActivityAttributes.Phase = newPhase == .cancelled ? .cancelled : .ended
        await endActivityIfStarted(activityPhase)
        showCancelConfirm = false
        phase = newPhase
    }

    private func cleanupLocal(passID: UUID) {
        deps.reminders.cancelAll(passID: passID)
        deps.secrets.clear()
        deps.passStore.clear()
    }

    private func endActivityIfStarted(_ endPhase: SpotPassActivityAttributes.Phase) async {
        await deps.activity.end(phase: endPhase, now: deps.now())
        activityStarted = false
    }
}
