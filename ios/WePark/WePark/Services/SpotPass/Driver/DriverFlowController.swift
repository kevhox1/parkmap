//
//  DriverFlowController.swift
//  Services/SpotPass/Driver
//
//  Spot Pass C2: the FULL APP's driver state machine (spec sections 3, 4, 7, design 3, 5, 7).
//  The App Clip has its own (`ClipFlowController`, Shared); this one differs where the capability
//  matrix does (spec 4):
//    - the claim's push/activity topic is the APP's bundle id, not the clip's;
//    - the Live Activity buttons are App Intents that call straight back into this controller
//      WITHOUT any UI (`leavingNow`, `fiveMoreMinutes`, `notLeaving`), as do the reminder
//      notification actions;
//    - "Start Driving" sends the depart (`departForStartDriving`);
//    - no clip carry-over writes (the app reads the clip's context, it never writes it).
//
//  Phases:  landing -> choosing -> arming -> armed -> pullingOut -> sending -> sent -> celebration
//           (+ unavailable / offline / busy / disabled / openApp / dismissed / cancelled / ended)
//
//  Safety rules enforced here (spec 9):
//    - Nothing arms until the driver taps the CTA ("Now" included: it arms and OPENS the
//      Time-to-go screen; it never departs by itself).
//    - Opening a deep link never cancels.
//    - The claimer secret lives only in `HandoffSecretStoring` (keychain) and is never logged.
//    - Depart is idempotent across sources: a second source finds the pass already departed.
//

import Foundation
import Observation

// MARK: - Phase

nonisolated enum DriverPhase: Equatable, Sendable {
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
    /// The server armed the pass but did not return its id (old backend): it cannot be managed.
    case openApp
    case dismissed
    case cancelled
    case ended
}

nonisolated enum DriverArmFailure: Equatable, Sendable {
    case offline
    case busy
    /// The claimer secret could not be stored (keychain refused): nothing was armed.
    case saveFailed
}

// MARK: - Collaborators

/// The user's access token for `handoff-claim` (karma needs the verified claimer, spec 8). nil =
/// the pass still arms, it just earns no karma.
@MainActor
protocol DriverSessionProviding: AnyObject {
    func accessToken() async -> String?
}

/// The driver's lock-screen countdown (spec 7.2). Started in the FOREGROUND BEFORE the claim call
/// (`pushType: .token`) because `handoff-claim` is the only place the backend learns the
/// activity push token; ended again if the claim fails. Carries the pass id once known so the App
/// Intent buttons can name the pass they act on.
@MainActor
protocol DriverActivityControlling: AnyObject {
    var areActivitiesEnabled: Bool { get }
    /// A push-to-end changed the phase while the app is running.
    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)? { get set }
    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?)
    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?, passID: UUID?) async
    func end(phase: SpotPassActivityAttributes.Phase, now: Date) async
    /// A process that did not start the activity (a background intent launch, a relaunch) re-attaches
    /// to the live one. Returns true if an activity exists.
    func adoptExisting() -> Bool
}

struct DriverDependencies {
    let api: any HandoffDriverAPI
    let secrets: any HandoffSecretStoring
    let passStore: any HandoffPassStoring
    let session: any DriverSessionProviding
    let reminders: any HandoffReminderScheduling
    let activity: any DriverActivityControlling
    let pushToken: any HandoffPushTokenProviding
    let feedback: any HandoffFeedback
    var now: () -> Date = { Date() }
    /// How long the "Sent" confirmation shows before the celebration (design 3.6: 1.2 s).
    var sentDwell: TimeInterval = 1.2
}

// A finished (departed) pass may come back onto the screen once after a relaunch, and never past its
// expiry plus `HandoffActivePass.finishedRestoreGrace` (the same rule as the App Clip, PR #172).

/// Notification delivery -> what the driver flow should do.
nonisolated enum DriverNotificationRoute: Equatable, Sendable {
    case thanks
    case action(ClipDeepAction)
    case ignore

    /// The full app handles the SAME three actions as the clip, in the background.
    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> DriverNotificationRoute {
        if (userInfo["kind"] as? String) == "thanks" { return .thanks }
        if let action = HandoffReminderPlan.deepAction(forActionIdentifier: actionIdentifier) { return .action(action) }
        return .ignore
    }
}

// MARK: - Controller

@Observable
@MainActor
final class DriverFlowController {

    // MARK: Observable state
    private(set) var phase: DriverPhase = .landing
    private(set) var preview: HandoffPassPreview?
    var choice: LeaveChoice = .default
    private(set) var pass: HandoffActivePass?
    private(set) var reminderAvailability: HandoffReminderAvailability = .on
    private(set) var activityStarted = false
    private(set) var activitiesEnabled = true
    private(set) var armFailure: DriverArmFailure?
    private(set) var sendFailed = false
    var showCancelConfirm = false
    var toast: String?
    /// A link for a DIFFERENT pass arrived while one is armed: the armed pass stays, the screen says so.
    private(set) var showsOtherPassNote = false

    // MARK: Private
    @ObservationIgnored private let deps: DriverDependencies
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var departMayHaveReachedServer = false

    init(dependencies: DriverDependencies) {
        deps = dependencies
        deps.activity.onRemotePhase = { [weak self] phase in self?.handleRemotePhase(phase) }
        restore()
    }

    var now: Date { deps.now() }

    var displayName: String? { pass?.name ?? preview?.name }
    var glyph: String { pass?.glyph ?? preview?.glyph ?? "" }
    var alias: String { pass?.alias ?? preview?.alias ?? "" }

    /// An armed, unexpired pass exists (what Start Driving, the intents and the reminder actions act on).
    var hasArmedPass: Bool {
        guard let pass else { return false }
        return pass.status == .armed && now < pass.expiresAt
    }

    // MARK: - Restore (a notification or intent launch carries no link)

    private func restore() {
        guard let saved = deps.passStore.load() else { return }
        switch saved.status {
        case .armed:
            if deps.now() >= saved.expiresAt {
                cleanupLocal(passID: saved.id)
            } else {
                pass = saved
                phase = .armed
                activityStarted = deps.activity.adoptExisting()
            }
        case .departed:
            // A finished pass is terminal: it may come back onto the screen ONCE after a relaunch (e.g. a
            // thanks notification), and never past its expiry plus a grace. Otherwise it is cleared so the
            // next scan starts fresh.
            let expired = deps.now() >= saved.expiresAt.addingTimeInterval(HandoffActivePass.finishedRestoreGrace)
            if saved.thanksReceived || expired || (saved.restoreCount ?? 0) >= 1 {
                cleanupLocal(passID: saved.id)
                return
            }
            var restored = saved
            restored.restoreCount = (saved.restoreCount ?? 0) + 1
            deps.passStore.save(restored)
            pass = restored
            phase = .celebration
            activityStarted = deps.activity.adoptExisting()
        }
    }

    /// Re-read persisted state (a background intent/notification action may have changed it while
    /// the UI was not looking) and expire a lapsed pass. Called when the app becomes active.
    func refreshFromStorage() async {
        if let current = pass, current.status == .armed, deps.now() >= current.expiresAt {
            await endPass(phase: .ended)
            return
        }
        guard pass == nil, phase == .landing || phase == .dismissed || phase == .ended || phase == .cancelled else { return }
        restore()
    }

    // MARK: - Link

    /// A universal link (or a clip-style deep action) arrived. Returns true if it started or
    /// resumed a flow the UI should present.
    @discardableResult
    func handle(link: SpotPassLink) -> Bool {
        if let token = link.token {
            if let active = pass {
                if active.status == .armed, deps.now() < active.expiresAt {
                    // An armed pass wins (its own token is already claimed, so a re-scan would only say
                    // "used"), and a different pass is never auto-cancelled for: note it, change nothing.
                    let isOtherPass = active.tokenFingerprint.map { $0 != HandoffActivePass.fingerprint(forToken: token) } == true
                    if isOtherPass { showsOtherPassNote = true }
                    return true
                }
                if active.status == .departed {
                    if phase == .sent { return true }
                    // The same pass re-delivered while its celebration is up: nothing to do.
                    if phase == .celebration,
                       active.tokenFingerprint == HandoffActivePass.fingerprint(forToken: token) { return true }
                }
                // Terminal (finished, or armed but past its expiry): a NEW scan starts fresh.
                clearTerminalPass(active)
            }
            // The same link delivered twice while its flow is in progress (cold-launch buffer + live
            // activity delivery) must not restart the peek. A TERMINAL phase may begin again.
            if self.token == token, phase == .choosing || phase == .arming { return true }
            begin(token: token)
            return true
        }
        if let action = link.action {
            guard pass != nil else { return false }
            perform(action)
            return true
        }
        // The generic landing (`/p` with no token): nothing to present unless a pass is active.
        return pass != nil
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

    private static func phase(for error: HandoffAPIError) -> DriverPhase {
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
        await peekTask?.value
        guard phase == .arming else { return }

        let startedAt = deps.now()
        let requestedLeave = choice.leaveAt(from: startedAt)
        let name = preview?.name ?? "A neighbor"
        let activityGlyph = preview?.glyph ?? SpotPassGlyph.fallbackSymbol

        // The app's normal notification permission is asked here, at the earned tap (spec 6.3).
        reminderAvailability = await deps.reminders.availability()
        activitiesEnabled = deps.activity.areActivitiesEnabled
        async let jwtResult = deps.session.accessToken()
        async let pushResult = pushTokenIfWanted()
        let started = await deps.activity.start(name: name, glyph: activityGlyph, leaveAt: requestedLeave, startedAt: startedAt)
        let jwt = await jwtResult
        let pushToken = await pushResult
        activityStarted = started.didStart

        let request = HandoffClaimRequest(
            token: token, leaveAt: requestedLeave, pushToken: pushToken, activityToken: started.token,
            topic: (pushToken != nil || started.token != nil) ? SpotPassShared.appBundleID : nil
        )
        let result: HandoffClaimResult
        do {
            result = try await deps.api.claim(request, userJWT: jwt)
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
                await endActivityIfStarted(.ended)
                phase = .openApp
                return
            }
            await finishArming(grant: grant, passID: passID, name: name, startedAt: startedAt)
        }
    }

    private func finishArming(grant: HandoffArmedGrant, passID: UUID, name: String, startedAt: Date) async {
        guard deps.secrets.save(grant.secret, passID: passID) else {
            // Without the secret the driver could never depart/extend/cancel: do not look armed.
            // Best-effort release of the server-side claim (we still hold the secret in memory) so the
            // neighbor is not left waiting, then back to choosing with a calm message. Nothing stored.
            _ = try? await deps.api.cancel(id: passID, secret: grant.secret)
            await endActivityIfStarted(.ended)
            deps.secrets.clear()
            armFailure = .saveFailed
            phase = .choosing
            return
        }
        let armed = HandoffActivePass(
            id: passID, alias: preview?.alias ?? name, glyph: preview?.glyph ?? SpotPassGlyph.fallbackSymbol,
            displayName: preview?.displayName, armedAt: startedAt, leaveAt: grant.leaveAt,
            expiresAt: grant.expiresAt, extensions: 0, status: .armed, departedAt: nil,
            thanksReceived: false, userId: nil, tokenFingerprint: token.map(HandoffActivePass.fingerprint(forToken:))
        )
        pass = armed
        deps.passStore.save(armed)
        await scheduleReminders(for: armed)
        if activityStarted {
            await deps.activity.update(phase: .counting, leaveAt: grant.leaveAt, startedAt: startedAt, passID: passID)
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

    private var phaseAllowsDeparture: Bool {
        switch phase {
        case .sending, .sent, .celebration: return false
        default: return true
        }
    }

    /// The single departure path for EVERY source (button, Live Activity intent, notification action,
    /// Start Driving, Shortcut). Idempotent: a pass that already departed is left alone.
    func pullOut(source: HandoffDepartSource = .manual) async {
        guard var current = pass, current.status == .armed, phaseAllowsDeparture,
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
        deps.feedback.success()
        phase = .sent
        deps.feedback.announce(ClipCopy.sentLine(name: current.name))
        if activityStarted { await deps.activity.update(phase: .sent, leaveAt: nil, startedAt: nil, passID: nil) }
        if deps.sentDwell > 0 { try? await Task.sleep(nanoseconds: UInt64(deps.sentDwell * 1_000_000_000)) }
        if activityStarted { await deps.activity.update(phase: .passed, leaveAt: nil, startedAt: nil, passID: nil) }
        if phase == .sent { phase = .celebration }
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
            if activityStarted {
                await deps.activity.update(phase: .counting, leaveAt: current.leaveAt, startedAt: current.armedAt, passID: current.id)
            }
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

    // MARK: - Background actions (App Intents, reminder notification actions, Start Driving)

    /// True when `passID` (from a lock-screen button) names the current pass, or is absent (Shortcuts).
    private func matches(passID: String?) -> Bool {
        guard let passID, !passID.isEmpty else { return true }
        guard let current = pass else { return false }
        return passID.lowercased() == current.id.uuidString.lowercased()
    }

    /// "Leaving now" from anywhere outside the pulling-out screen.
    func leavingNow(source: HandoffDepartSource, passID: String? = nil) async -> SpotPassIntentOutcome {
        guard matches(passID: passID), let current = pass else { return .noActivePass }
        if current.status == .departed || phase == .sending { return .alreadySent }
        guard current.status == .armed, deps.now() < current.expiresAt else {
            await endPass(phase: .ended)
            return .noActivePass
        }
        await pullOut(source: source)
        if pass?.status == .departed { return .sent }
        return phase == .ended ? .noActivePass : .failed
    }

    func fiveMoreMinutes(passID: String? = nil) async -> SpotPassIntentOutcome {
        guard matches(passID: passID), let current = pass, current.status == .armed, deps.now() < current.expiresAt else {
            return .noActivePass
        }
        let before = current.extensions
        await extendFiveMinutes()
        return (pass?.extensions ?? before) > before ? .extended : .failed
    }

    /// "Not leaving": silent to the neighbor.
    func notLeaving(passID: String? = nil) async -> SpotPassIntentOutcome {
        guard matches(passID: passID), let current = pass, current.status == .armed else { return .noActivePass }
        await confirmCancel()
        return pass == nil ? .cancelled : .failed
    }

    /// "Start Driving in WePark = sends the ping" (spec 7.4). Returns true only if THIS call told the neighbor.
    func departForStartDriving() async -> Bool {
        guard hasArmedPass else { return false }
        return await leavingNow(source: .startDriving) == .sent
    }

    // MARK: - Expiry / remote events

    func tick() async {
        guard let current = pass, current.status == .armed, deps.now() >= current.expiresAt else { return }
        await endPass(phase: .ended)
    }

    /// The seeker said thanks. Returns true if this call settled the karma (false: already settled
    /// or no departed pass).
    @discardableResult
    func receiveThanks() -> Bool {
        guard var current = pass, current.status == .departed, !current.thanksReceived else { return false }
        current.thanksReceived = true
        pass = current
        deps.passStore.save(current)
        deps.feedback.success()
        deps.feedback.announce(ClipCopy.thanksHeadline)
        phase = .celebration
        let endedAt = deps.now()
        Task { await deps.activity.end(phase: .thanks, now: endedAt) }
        return true
    }

    /// The seeker cancelled or parked (`handoff_ended`): an armed pass is over.
    func receiveHandoffEnded() async {
        guard let current = pass, current.status == .armed else { return }
        await endPass(phase: .ended)
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

    func handleNotification(actionIdentifier: String, userInfo: [AnyHashable: Any]) async {
        switch DriverNotificationRoute.route(actionIdentifier: actionIdentifier, userInfo: userInfo) {
        case .thanks: receiveThanks()
        case .action(let action): await performAndWait(action)
        case .ignore: break
        }
    }

    // MARK: - Deep actions

    func perform(_ action: ClipDeepAction) {
        Task { await performAndWait(action) }
    }

    /// Awaitable form: the notification delegate must not call its completion handler until this returns.
    func performAndWait(_ action: ClipDeepAction) async {
        guard let current = pass else { return }
        switch action {
        case .openPullingOut:
            if current.status == .armed, phase == .armed { phase = .pullingOut }
        case .leavingNow(let source):
            _ = await leavingNow(source: source)
        case .extend:
            _ = await fiveMoreMinutes()
        case .confirmCancel:
            if current.status == .armed {
                if phase == .armed { phase = .pullingOut }
                showCancelConfirm = true
            }
        case .cancelNow:
            _ = await notLeaving()
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

    // MARK: - Celebration

    /// "Done": the pass is finished, so clear it (and its secret and reminders). The next scan starts
    /// fresh and relaunching never revives it. (A late thanks after Done can no longer settle locally; the
    /// server still credits the karma.)
    func dismissCelebration() {
        if let current = pass {
            guard current.status != .armed else { phase = .dismissed; return }
            cleanupLocal(passID: current.id)
        } else {
            deps.passStore.clear()
        }
        pass = nil
        showsOtherPassNote = false
        phase = .dismissed
    }

    /// Drops a pass that can no longer be acted on, ahead of a fresh scan.
    private func clearTerminalPass(_ terminal: HandoffActivePass) {
        let wasArmed = terminal.status == .armed
        cleanupLocal(passID: terminal.id)
        pass = nil
        showsOtherPassNote = false
        showCancelConfirm = false
        if wasArmed && activityStarted { Task { await endActivityIfStarted(.ended) } }
    }

    // MARK: - Teardown

    private func endPass(phase newPhase: DriverPhase) async {
        guard let current = pass else { phase = newPhase; return }
        cleanupLocal(passID: current.id)
        pass = nil
        showsOtherPassNote = false
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
