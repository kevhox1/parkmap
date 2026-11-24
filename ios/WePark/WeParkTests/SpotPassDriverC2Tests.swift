//
//  SpotPassDriverC2Tests.swift
//  Spot Pass C2 (docs/specs/qr-spot-handoff.md sections 3, 4, 6.2, 6.3, 7.2, 7.3, 7.4, 7.5, 8, 9;
//  docs/design/spot-pass-design.md sections 3, 5, 6, 7, 8.2): the FULL APP's driver flow, against
//  fakes only. No network, no real notification center, no ActivityKit, no keychain.
//
//  Groups: 1 flow state machine, 2 background actions + intents, 3 Start Driving gate, 4 reminders,
//  5 notification routing, 6 Welcome + onboarding composition, 7 clip adoption, 8 link routing and
//  runtime, 9 secret hygiene, 10 flag-off inertness.
//

import XCTest
import UserNotifications
@testable import WePark

// MARK: - Test doubles

@MainActor
private final class DriverScriptedAPI: HandoffDriverAPI {
    var peekResult: Result<HandoffPeekResult, HandoffAPIError> =
        .success(.open(HandoffPassPreview(alias: "Bodega Cat", glyph: "bodega_cat", displayName: nil)))
    var claimResult: Result<HandoffClaimResult, HandoffAPIError> = .success(.armed(HandoffArmedGrant(
        passID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
        leaveAt: Date(timeIntervalSince1970: 1_800_000_600), expiresAt: Date(timeIntervalSince1970: 1_800_001_500),
        secret: ClaimerSecret("SECRET-SECRET-SECRET-1"))))
    var departResults: [Result<Bool, HandoffAPIError>] = []
    var extendResult: Result<HandoffExtendResult, HandoffAPIError>?
    private(set) var calls: [String] = []
    private(set) var lastClaim: HandoffClaimRequest?
    private(set) var lastClaimJWT: String?
    private(set) var departSources: [HandoffDepartSource] = []

    func peek(token: String) async throws -> HandoffPeekResult {
        calls.append("peek")
        return try peekResult.get()
    }

    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult {
        calls.append("claim")
        lastClaim = request
        lastClaimJWT = userJWT
        return try claimResult.get()
    }

    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool {
        calls.append("depart")
        departSources.append(source)
        return try (departResults.isEmpty ? .success(true) : departResults.removeFirst()).get()
    }

    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult {
        calls.append("extend")
        if let extendResult { return try extendResult.get() }
        return HandoffExtendResult(ok: true, leaveAt: nil, expiresAt: nil)
    }

    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool {
        calls.append("cancel")
        return true
    }

    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool {
        calls.append("report")
        return true
    }
}

@MainActor
private final class DriverRecordingReminders: HandoffReminderScheduling {
    var available: HandoffReminderAvailability = .on
    private(set) var scheduled: [PlannedReminder] = []
    private(set) var cancelledPassIDs: [UUID] = []
    func availability() async -> HandoffReminderAvailability { available }
    func schedule(_ reminders: [PlannedReminder], passID: UUID) async { scheduled = reminders }
    func cancelAll(passID: UUID) { cancelledPassIDs.append(passID) }
}

@MainActor
private final class DriverRecordingActivity: DriverActivityControlling {
    var areActivitiesEnabled = true
    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)?
    var token: String? = "ab12cd34ef56ab12cd34ef56ab12cd34ef56"
    var existing = false
    private(set) var started = 0
    private(set) var updates: [(phase: SpotPassActivityAttributes.Phase, passID: UUID?)] = []
    private(set) var ended: [SpotPassActivityAttributes.Phase] = []

    func adoptExisting() -> Bool { existing }
    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?) {
        guard areActivitiesEnabled else { return (false, nil) }
        started += 1
        return (true, token)
    }
    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?, passID: UUID?) async {
        updates.append((phase, passID))
    }
    func end(phase: SpotPassActivityAttributes.Phase, now: Date) async { ended.append(phase) }
}

@MainActor
private final class DriverStubSession: DriverSessionProviding {
    var token: String? = "jwt-1"
    func accessToken() async -> String? { token }
}

@MainActor
private final class DriverStubPushToken: HandoffPushTokenProviding {
    var token: String? = "00112233445566778899aabbccddeeff00112233"
    func deviceToken() async -> String? { token }
}

@MainActor
private final class DriverRecordingFeedback: HandoffFeedback {
    private(set) var events: [String] = []
    func selection() { events.append("selection") }
    func armImpact() { events.append("arm") }
    func success() { events.append("success") }
    func lightImpact() { events.append("light") }
    func announce(_ message: String) { events.append("announce:\(message)") }
}

private let driverToken = "AbCdEfGhIjKlMnOpQrSt_-"
private let driverLink = SpotPassLink(url: URL(string: "https://getwepark.com/p#t=\(driverToken)") ?? URL(fileURLWithPath: "/"))
private let driverPassID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()

@MainActor
private final class DriverHarness {
    let api = DriverScriptedAPI()
    let secrets = InMemoryHandoffSecretStore()
    let passes = InMemoryHandoffPassStore()
    let session = DriverStubSession()
    let reminders = DriverRecordingReminders()
    let activity = DriverRecordingActivity()
    let push = DriverStubPushToken()
    let feedback = DriverRecordingFeedback()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var controller: DriverFlowController!

    init() {
        controller = makeController()
    }

    func makeController() -> DriverFlowController {
        DriverFlowController(dependencies: DriverDependencies(
            api: api, secrets: secrets, passStore: passes, session: session, reminders: reminders,
            activity: activity, pushToken: push, feedback: feedback,
            now: { [weak self] in self?.clock ?? Date() }, sentDwell: 0
        ))
    }

    func scan() async {
        if let link = driverLink { controller.handle(link: link) }
        await settle()
    }

    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func armed(_ choice: LeaveChoice = .minutes(10)) async {
        await scan()
        controller.select(choice)
        await controller.arm()
    }
}

// MARK: - 1. Flow state machine

@MainActor
final class DriverFlowControllerTests: XCTestCase {

    func testNoTokenLink_isNotPresentedWithoutAPass() {
        let h = DriverHarness()
        guard let landing = SpotPassLink(url: URL(string: "https://getwepark.com/p") ?? URL(fileURLWithPath: "/")) else {
            return XCTFail("landing link should parse")
        }
        XCTAssertFalse(h.controller.handle(link: landing))
        XCTAssertEqual(h.controller.phase, .landing)
    }

    func testScan_peeksAndShowsAlias_withTenMinutePreselected() async {
        let h = DriverHarness()
        await h.scan()
        XCTAssertEqual(h.controller.phase, .choosing)
        XCTAssertEqual(h.controller.preview?.alias, "Bodega Cat")
        XCTAssertEqual(h.controller.choice, .minutes(10))
        XCTAssertEqual(h.api.calls, ["peek"])
        XCTAssertNil(h.passes.pass, "nothing is armed by a scan")
    }

    func testPeekFailures_mapToCalmPhases() async {
        let unavailable = DriverHarness()
        unavailable.api.peekResult = .success(.unavailable)
        await unavailable.scan()
        XCTAssertEqual(unavailable.controller.phase, .unavailable)

        let offline = DriverHarness()
        offline.api.peekResult = .failure(.offline)
        await offline.scan()
        XCTAssertEqual(offline.controller.phase, .offline)

        let disabled = DriverHarness()
        disabled.api.peekResult = .failure(.disabled)
        await disabled.scan()
        XCTAssertEqual(disabled.controller.phase, .disabled)

        let busy = DriverHarness()
        busy.api.peekResult = .failure(.rateLimited)
        await busy.scan()
        XCTAssertEqual(busy.controller.phase, .busy)
    }

    func testSameLinkTwiceWhileChoosing_peeksOnce() async {
        let h = DriverHarness()
        await h.scan()
        await h.scan()
        XCTAssertEqual(h.api.calls.filter { $0 == "peek" }.count, 1)
    }

    func testRescanAfterDismiss_beginsAgain() async {
        let h = DriverHarness()
        await h.scan()
        h.controller.notLeavingSoon()
        XCTAssertEqual(h.controller.phase, .dismissed)
        await h.scan()
        XCTAssertEqual(h.controller.phase, .choosing)
        XCTAssertEqual(h.api.calls.filter { $0 == "peek" }.count, 2)
    }

    func testArm_claimUsesAppTopic_userJWT_andActivityToken() async {
        let h = DriverHarness()
        await h.armed(.minutes(30))
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertEqual(h.api.lastClaim?.topic, SpotPassShared.appBundleID, "the APP's bundle id, never the clip's")
        XCTAssertNotEqual(h.api.lastClaim?.topic, SpotPassShared.clipBundleID)
        XCTAssertEqual(h.api.lastClaim?.activityToken, h.activity.token)
        XCTAssertEqual(h.api.lastClaim?.pushToken, h.push.token)
        XCTAssertEqual(h.api.lastClaimJWT, "jwt-1", "the user JWT rides on the claim so karma can accrue")
        XCTAssertEqual(h.api.lastClaim?.token, driverToken)
    }

    func testArm_persistsPass_savesSecret_schedulesReminders_updatesActivityWithPassID() async {
        let h = DriverHarness()
        await h.armed()
        XCTAssertEqual(h.passes.pass?.id, driverPassID)
        XCTAssertEqual(h.passes.pass?.status, .armed)
        XCTAssertNotNil(h.secrets.secret(for: driverPassID))
        XCTAssertFalse(h.reminders.scheduled.isEmpty)
        XCTAssertEqual(h.activity.updates.last?.phase, .counting)
        XCTAssertEqual(h.activity.updates.last?.passID, driverPassID, "the intent buttons need the pass id")
        XCTAssertTrue(h.feedback.events.contains("arm"))
    }

    func testArm_reminderDenied_stillArms_andOmitsPushToken() async {
        let h = DriverHarness()
        h.reminders.available = .off
        await h.armed()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertNil(h.api.lastClaim?.pushToken)
        XCTAssertTrue(h.reminders.scheduled.isEmpty)
        XCTAssertEqual(h.controller.reminderAvailability, .off)
    }

    func testArm_activitiesOff_armsWithoutActivityToken() async {
        let h = DriverHarness()
        h.activity.areActivitiesEnabled = false
        await h.armed()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertNil(h.api.lastClaim?.activityToken)
        XCTAssertFalse(h.controller.activityStarted)
    }

    func testArm_nowOpensPullingOut_andNeverDeparts() async {
        let h = DriverHarness()
        await h.armed(.now)
        XCTAssertEqual(h.controller.phase, .pullingOut)
        XCTAssertFalse(h.api.calls.contains("depart"), "Now arms; it never departs by itself")
    }

    func testArm_failures() async {
        let offline = DriverHarness()
        offline.api.claimResult = .failure(.offline)
        await offline.armed()
        XCTAssertEqual(offline.controller.phase, .choosing)
        XCTAssertEqual(offline.controller.armFailure, .offline)
        XCTAssertEqual(offline.activity.ended, [.ended], "the pre-claim activity is ended again")

        let busy = DriverHarness()
        busy.api.claimResult = .failure(.rateLimited)
        await busy.armed()
        XCTAssertEqual(busy.controller.armFailure, .busy)

        let disabled = DriverHarness()
        disabled.api.claimResult = .failure(.disabled)
        await disabled.armed()
        XCTAssertEqual(disabled.controller.phase, .disabled)

        let used = DriverHarness()
        used.api.claimResult = .success(.unavailable)
        await used.armed()
        XCTAssertEqual(used.controller.phase, .unavailable)

        let noID = DriverHarness()
        noID.api.claimResult = .success(.armed(HandoffArmedGrant(
            passID: nil, leaveAt: Date(timeIntervalSince1970: 1_800_000_600),
            expiresAt: Date(timeIntervalSince1970: 1_800_001_500), secret: ClaimerSecret("x"))))
        await noID.armed()
        XCTAssertEqual(noID.controller.phase, .openApp)
        XCTAssertNil(noID.passes.pass)
    }

    func testPullOut_sendsOnce_clearsSecret_cancelsReminders_celebrates() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut(source: .manual)
        XCTAssertEqual(h.controller.phase, .celebration)
        XCTAssertEqual(h.api.departSources, [.manual])
        XCTAssertNil(h.secrets.secret(for: driverPassID))
        XCTAssertEqual(h.reminders.cancelledPassIDs.last, driverPassID)
        XCTAssertEqual(h.passes.pass?.status, .departed)
        XCTAssertEqual(h.activity.updates.map(\.phase).suffix(2), [.sent, .passed])
        // A second source finds the pass already departed.
        await h.controller.pullOut(source: .liveActivity)
        XCTAssertEqual(h.api.departSources, [.manual], "depart is idempotent across sources")
    }

    func testPullOut_networkFailure_staysArmed_thenRetrySucceedsAsSent() async {
        let h = DriverHarness()
        await h.armed()
        h.api.departResults = [.failure(.offline), .success(false)]
        await h.controller.pullOut()
        XCTAssertEqual(h.controller.phase, .pullingOut)
        XCTAssertTrue(h.controller.sendFailed)
        await h.controller.pullOut()
        XCTAssertEqual(h.controller.phase, .celebration, "ok:false on a retry means it may already be sent")
    }

    func testExtend_updatesTimes_reschedules_andCapsAtThree() async {
        let h = DriverHarness()
        await h.armed()
        let before = h.passes.pass?.leaveAt ?? .distantPast
        await h.controller.extendFiveMinutes()
        XCTAssertEqual(h.passes.pass?.extensions, 1)
        XCTAssertEqual(h.passes.pass?.leaveAt, before.addingTimeInterval(300))
        XCTAssertEqual(h.controller.toast, ClipCopy.extendDone)
        await h.controller.extendFiveMinutes()
        await h.controller.extendFiveMinutes()
        await h.controller.extendFiveMinutes()
        XCTAssertEqual(h.passes.pass?.extensions, 3)
        XCTAssertEqual(h.controller.toast, ClipCopy.extendFailed)
        XCTAssertEqual(h.api.calls.filter { $0 == "extend" }.count, 3)
    }

    func testCancel_isSilent_noDepart_endsActivity() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.confirmCancel()
        XCTAssertEqual(h.controller.phase, .cancelled)
        XCTAssertTrue(h.api.calls.contains("cancel"))
        XCTAssertFalse(h.api.calls.contains("depart"))
        XCTAssertNil(h.passes.pass)
        XCTAssertNil(h.secrets.secret(for: driverPassID))
        XCTAssertEqual(h.activity.ended.last, .cancelled)
    }

    func testOpeningACancelDeepAction_doesNotCancel() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.performAndWait(.confirmCancel)
        XCTAssertTrue(h.controller.showCancelConfirm)
        XCTAssertFalse(h.api.calls.contains("cancel"), "opening alone is ambiguous and must never cancel")
    }

    func testThanks_settlesKarma_once_andEndsActivity() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut()
        XCTAssertTrue(h.controller.receiveThanks())
        XCTAssertFalse(h.controller.receiveThanks(), "idempotent")
        XCTAssertEqual(h.controller.pass?.thanksReceived, true)
        await h.settle()
        XCTAssertEqual(h.activity.ended.last, .thanks)
        h.controller.dismissCelebration()
        XCTAssertNil(h.passes.pass, "a settled pass is finished for good")
    }

    func testDoneBeforeThanks_keepsDepartedPassSoALateThanksCanLand() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut()
        h.controller.dismissCelebration()
        XCTAssertEqual(h.passes.pass?.status, .departed)
        XCTAssertTrue(h.controller.receiveThanks())
    }

    func testExpiry_endsArmedPass() async {
        let h = DriverHarness()
        await h.armed()
        h.clock = Date(timeIntervalSince1970: 1_800_001_501)
        await h.controller.tick()
        XCTAssertEqual(h.controller.phase, .ended)
        XCTAssertNil(h.passes.pass)
    }

    func testHandoffEnded_endsAnArmedPass() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.receiveHandoffEnded()
        XCTAssertEqual(h.controller.phase, .ended)
        XCTAssertEqual(h.activity.ended.last, .ended)
    }

    func testRestore_armedPassComesBack_andReattachesToTheActivity() async {
        let h = DriverHarness()
        await h.armed()
        h.activity.existing = true
        let revived = h.makeController()
        XCTAssertEqual(revived.phase, .armed)
        XCTAssertEqual(revived.pass?.id, driverPassID)
        XCTAssertTrue(revived.activityStarted, "a background launch must still update the live activity")
    }

    func testRestore_expiredArmed_andStaleDeparted_arePurged() async {
        let h = DriverHarness()
        await h.armed()
        h.clock = Date(timeIntervalSince1970: 1_800_002_000)
        let expired = h.makeController()
        XCTAssertNil(expired.pass)
        XCTAssertNil(h.passes.pass)

        let d = DriverHarness()
        await d.armed()
        await d.controller.pullOut()
        d.clock = d.clock.addingTimeInterval(DriverPassLifetime.departedLinger + 1)
        XCTAssertNil(d.makeController().pass)
    }

    func testRestore_recentDeparted_showsCelebration() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut()
        h.clock = h.clock.addingTimeInterval(60)
        XCTAssertEqual(h.makeController().phase, .celebration)
    }

    func testReport_whileArmed_usesTheSecret_andEndsThePass() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.report(.spam)
        XCTAssertTrue(h.api.calls.contains("report"))
        XCTAssertEqual(h.controller.phase, .ended)
    }

    func testActivePassWinsOverARescan() async {
        let h = DriverHarness()
        await h.armed()
        let other = SpotPassLink(url: URL(string: "https://getwepark.com/p#t=ZZZZZZZZZZZZZZZZZZZZZZ") ?? URL(fileURLWithPath: "/"))
        XCTAssertEqual(other.map { h.controller.handle(link: $0) }, true)
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertEqual(h.api.calls.filter { $0 == "peek" }.count, 1)
    }
}

// MARK: - 2. Background actions and intents

@MainActor
final class DriverBackgroundActionTests: XCTestCase {

    func testLeavingNow_withNoPass_isNoActivePass() async {
        let h = DriverHarness()
        let outcome = await h.controller.leavingNow(source: .shortcut)
        XCTAssertEqual(outcome, .noActivePass)
        XCTAssertTrue(h.api.calls.isEmpty)
    }

    func testLeavingNow_sendsWithTheSource_thenIsIdempotent() async {
        let h = DriverHarness()
        await h.armed()
        let first = await h.controller.leavingNow(source: .liveActivity, passID: driverPassID.uuidString)
        XCTAssertEqual(first, .sent)
        XCTAssertEqual(h.api.departSources, [.liveActivity])
        let second = await h.controller.leavingNow(source: .shortcut)
        XCTAssertEqual(second, .alreadySent)
        XCTAssertEqual(h.api.departSources.count, 1)
    }

    func testStalePassID_isANoOp() async {
        let h = DriverHarness()
        await h.armed()
        let outcome = await h.controller.leavingNow(source: .liveActivity, passID: UUID().uuidString)
        XCTAssertEqual(outcome, .noActivePass)
        XCTAssertFalse(h.api.calls.contains("depart"), "a stale lock-screen button never acts on a newer pass")
    }

    func testPassIDMatch_isCaseInsensitive() async {
        let h = DriverHarness()
        await h.armed()
        let outcome = await h.controller.leavingNow(source: .liveActivity, passID: driverPassID.uuidString.lowercased())
        XCTAssertEqual(outcome, .sent)
    }

    func testLeavingNow_afterExpiry_isNoActivePass_andCleansUp() async {
        let h = DriverHarness()
        await h.armed()
        h.clock = Date(timeIntervalSince1970: 1_800_001_501)
        let outcome = await h.controller.leavingNow(source: .notification)
        XCTAssertEqual(outcome, .noActivePass)
        XCTAssertFalse(h.api.calls.contains("depart"), "expired passes cannot depart")
        XCTAssertNil(h.passes.pass)
    }

    func testLeavingNow_networkFailure_isFailed_andStaysArmed() async {
        let h = DriverHarness()
        await h.armed()
        h.api.departResults = [.failure(.offline)]
        let outcome = await h.controller.leavingNow(source: .liveActivity)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(h.passes.pass?.status, .armed)
    }

    func testFiveMoreMinutes_andNotLeaving() async {
        let h = DriverHarness()
        await h.armed()
        let more = await h.controller.fiveMoreMinutes(passID: driverPassID.uuidString)
        XCTAssertEqual(more, .extended)
        let cancelled = await h.controller.notLeaving(passID: driverPassID.uuidString)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertFalse(h.api.calls.contains("depart"), "Not leaving is silent to the neighbor")
        let again = await h.controller.notLeaving()
        XCTAssertEqual(again, .noActivePass)
    }

    func testFiveMoreMinutes_atTheCap_isFailed() async {
        let h = DriverHarness()
        await h.armed()
        for _ in 0..<3 { _ = await h.controller.fiveMoreMinutes() }
        let outcome = await h.controller.fiveMoreMinutes()
        XCTAssertEqual(outcome, .failed)
    }

    func testIntentPerformer_mapsTheSource_byPassIDPresence() async {
        let h = DriverHarness()
        await h.armed()
        let performer = SpotPassDriverIntentPerformer(controller: { h.controller })
        let fromActivity = await performer.leavingNow(passID: driverPassID.uuidString)
        XCTAssertEqual(fromActivity, .sent)
        XCTAssertEqual(h.api.departSources, [.liveActivity])

        let s = DriverHarness()
        await s.armed()
        let shortcut = SpotPassDriverIntentPerformer(controller: { s.controller })
        let result = await shortcut.leavingNow(passID: nil)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(s.api.departSources, [.shortcut])
    }

    func testIntentStructs_forwardToThePerformer_andNoOpWithoutOne() async throws {
        let previous = SpotPassIntentRuntime.performer
        defer { SpotPassIntentRuntime.performer = previous }

        SpotPassIntentRuntime.performer = nil
        _ = try await LeavingNowIntent(passID: nil).perform()          // inert: must not crash
        _ = try await NotLeavingIntent(passID: nil).perform()
        _ = try await FiveMoreMinutesIntent(passID: nil).perform()

        let h = DriverHarness()
        await h.armed()
        SpotPassIntentRuntime.performer = SpotPassDriverIntentPerformer(controller: { h.controller })
        _ = try await LeavingNowIntent(passID: driverPassID.uuidString).perform()
        XCTAssertEqual(h.api.departSources, [.liveActivity])
    }

    func testIntentOutcomeDialogs() {
        XCTAssertEqual(SpotPassIntentOutcome.noActivePass.dialog, "No active Spot Pass.")
        XCTAssertFalse(SpotPassIntentOutcome.sent.dialog.lowercased().contains("location"))
        for outcome in [SpotPassIntentOutcome.sent, .alreadySent, .extended, .cancelled, .noActivePass, .failed] {
            XCTAssertFalse(outcome.dialog.isEmpty)
        }
    }

    func testIntentDiscoverability() {
        XCTAssertFalse(NotLeavingIntent.isDiscoverable)
        XCTAssertFalse(FiveMoreMinutesIntent.isDiscoverable)
        XCTAssertFalse(LeavingNowIntent.isDiscoverable, "ships dark: not in Shortcuts until the flag flip")
        XCTAssertFalse(LeavingNowIntent.openAppWhenRun, "no app launch UI (spec 7.2)")
    }

    func testContentState_carriesPassID_andOldPayloadsStillDecode() throws {
        let state = SpotPassActivityAttributes.ContentState(
            phase: .counting, leaveAt: Date(timeIntervalSince1970: 1_800_000_000),
            startedAt: Date(timeIntervalSince1970: 1_799_999_000), passID: "abc"
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: data), state)
        XCTAssertLessThan(data.count, 4096)
        let legacy = try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: Data(#"{"phase":"thanks"}"#.utf8))
        XCTAssertEqual(legacy.phase, .thanks)
        XCTAssertNil(legacy.passID)
    }
}

// MARK: - 3. Start Driving

@MainActor
final class DriverStartDrivingTests: XCTestCase {

    func testGate_matrix() {
        XCTAssertTrue(SpotPassStartDriving.shouldDepart(enabled: true, hasArmedPass: true))
        XCTAssertFalse(SpotPassStartDriving.shouldDepart(enabled: true, hasArmedPass: false))
        XCTAssertFalse(SpotPassStartDriving.shouldDepart(enabled: false, hasArmedPass: true))
        XCTAssertFalse(SpotPassStartDriving.shouldDepart(enabled: false, hasArmedPass: false))
    }

    func testDepartForStartDriving_sendsOnce_withStartDrivingSource() async {
        let h = DriverHarness()
        await h.armed()
        let first = await h.controller.departForStartDriving()
        XCTAssertTrue(first)
        XCTAssertEqual(h.api.departSources, [.startDriving])
        let second = await h.controller.departForStartDriving()
        XCTAssertFalse(second, "idempotent with other sources")
        XCTAssertEqual(h.api.departSources.count, 1)
    }

    func testDepartForStartDriving_withNoPass_doesNothing() async {
        let h = DriverHarness()
        let result = await h.controller.departForStartDriving()
        XCTAssertFalse(result)
        XCTAssertTrue(h.api.calls.isEmpty)
    }

    func testRuntimeStartDriving_flagOff_neverBuildsTheController() {
        var toasts: [String] = []
        let runtime = SpotPassDriverRuntime(factory: { DriverHarness().controller })
        runtime.showToast = { toasts.append($0) }
        runtime.startDriving(enabled: false)
        XCTAssertFalse(runtime.hasController)
        XCTAssertTrue(toasts.isEmpty)
    }

    func testRuntimeStartDriving_flagOn_withArmedPass_sendsAndToasts() async {
        let h = DriverHarness()
        await h.armed()
        var toasts: [String] = []
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        runtime.showToast = { toasts.append($0) }
        _ = runtime.controller   // build
        runtime.startDriving(enabled: true)
        await h.settle()
        XCTAssertEqual(h.api.departSources, [.startDriving])
        XCTAssertEqual(toasts, [SpotPassStartDriving.toast])
    }

    func testRuntimeStartDriving_flagOn_noPass_isSilent() async {
        let h = DriverHarness()
        var toasts: [String] = []
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        runtime.showToast = { toasts.append($0) }
        runtime.startDriving(enabled: true)
        await h.settle()
        XCTAssertFalse(runtime.hasController, "no pass: never even builds the controller")
        XCTAssertTrue(toasts.isEmpty)
    }
}

// MARK: - 4. Reminders

@MainActor
private final class RecordingNotificationCenter: DriverNotificationCenter {
    var status: UNAuthorizationStatus = .notDetermined
    var grants = true
    private(set) var requested = 0
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        requested += 1
        status = grants ? .authorized : .denied
        return grants
    }
    func add(_ request: UNNotificationRequest) async { added.append(request) }
    func removePending(identifiers: [String]) { removedPending += identifiers }
    func removeDelivered(identifiers: [String]) { removedDelivered += identifiers }
}

@MainActor
final class DriverReminderTests: XCTestCase {

    func testCategory_hasThreeBackgroundNonDestructiveActions() {
        let category = DriverReminderCategory.category()
        XCTAssertEqual(category.identifier, "SPOT_PASS_LEAVING")
        XCTAssertEqual(category.actions.map(\.identifier), [
            HandoffReminderPlan.actionLeavingNow, HandoffReminderPlan.actionExtend, HandoffReminderPlan.actionCancel
        ])
        XCTAssertEqual(category.actions.map(\.title), ["Leaving now", "5 more min", "Not leaving"])
        for action in category.actions {
            XCTAssertFalse(action.options.contains(.foreground), "spec 7.3: the app's actions send WITHOUT opening the app")
            XCTAssertFalse(action.options.contains(.destructive), "red means curb rules")
            XCTAssertFalse(action.options.contains(.authenticationRequired))
        }
        XCTAssertEqual(category.hiddenPreviewsBodyPlaceholder, ClipCopy.reminderHiddenBody)
    }

    func testIsReminderAction_onlyOurCategoryAndActions() {
        XCTAssertTrue(DriverReminderCategory.isReminderAction(
            categoryIdentifier: "SPOT_PASS_LEAVING", actionIdentifier: HandoffReminderPlan.actionLeavingNow))
        XCTAssertTrue(DriverReminderCategory.isReminderAction(
            categoryIdentifier: "SPOT_PASS_LEAVING", actionIdentifier: HandoffReminderPlan.actionCancel))
        XCTAssertFalse(DriverReminderCategory.isReminderAction(
            categoryIdentifier: "SPOT_PASS_LEAVING", actionIdentifier: UNNotificationDefaultActionIdentifier))
        XCTAssertFalse(DriverReminderCategory.isReminderAction(
            categoryIdentifier: "wepark_spot_pass_seeker", actionIdentifier: HandoffReminderPlan.actionLeavingNow))
    }

    func testAvailability_asksOnce_whenUndetermined() async {
        let center = RecordingNotificationCenter()
        let scheduler = DriverReminderScheduler(center: center, registerCategories: { _ in })
        let first = await scheduler.availability()
        XCTAssertEqual(first, .on)
        XCTAssertEqual(center.requested, 1)
        _ = await scheduler.availability()
        XCTAssertEqual(center.requested, 1, "the system prompt is asked at most once")
    }

    func testAvailability_denied_isOff_andNeverAsksAgain() async {
        let center = RecordingNotificationCenter()
        center.status = .denied
        let scheduler = DriverReminderScheduler(center: center, registerCategories: { _ in })
        let result = await scheduler.availability()
        XCTAssertEqual(result, .off)
        XCTAssertEqual(center.requested, 0)
    }

    func testSchedule_registersCategoryMergeSafely_andAddsActionableRequests() async {
        let center = RecordingNotificationCenter()
        center.status = .authorized
        var registered: [[UNNotificationCategory]] = []
        let scheduler = DriverReminderScheduler(center: center, registerCategories: { registered.append($0) })
        let leave = Date(timeIntervalSince1970: 1_800_000_600)
        let plan = HandoffReminderPlan.make(
            passID: driverPassID, name: "Bodega Cat", leaveAt: leave, expiresAt: leave.addingTimeInterval(900),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await scheduler.schedule(plan, passID: driverPassID)
        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(registered.first?.map(\.identifier), ["SPOT_PASS_LEAVING"])
        XCTAssertEqual(center.added.count, 2)
        for request in center.added {
            XCTAssertEqual(request.content.categoryIdentifier, "SPOT_PASS_LEAVING")
            XCTAssertEqual(request.content.threadIdentifier, HandoffReminderPlan.threadID(passID: driverPassID))
            XCTAssertEqual(request.content.interruptionLevel, .active)
            XCTAssertTrue(request.trigger is UNTimeIntervalNotificationTrigger)
            XCTAssertNil(request.content.targetContentIdentifier, "that is the clip's remote-notification mechanism")
            XCTAssertFalse(request.content.body.lowercased().contains("location"))
        }
        XCTAssertEqual(center.added.first?.content.title, "Time to go?")
    }

    func testRequestBuilder_intervalIsAtLeastOneSecond() {
        let reminder = PlannedReminder(
            identifier: "x", fireDate: Date(timeIntervalSince1970: 100), title: "t", body: "b", hiddenPreviewBody: "h"
        )
        let request = DriverReminderScheduler.request(for: reminder, passID: driverPassID, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 1)
    }

    func testCancelAll_removesPendingAndDelivered() {
        let center = RecordingNotificationCenter()
        let scheduler = DriverReminderScheduler(center: center, registerCategories: { _ in })
        scheduler.cancelAll(passID: driverPassID)
        let expected = [HandoffReminderPlan.leaveIdentifier(passID: driverPassID), HandoffReminderPlan.lastCallIdentifier(passID: driverPassID)]
        XCTAssertEqual(center.removedPending, expected)
        XCTAssertEqual(center.removedDelivered, expected)
    }

    func testLaunchCategories_includeTheDriverCategoryOnlyWhenAsked() {
        let none = NotificationCategoryRegistry.launchCategories(addressEnabled: false, spotPassEnabled: true)
        XCTAssertEqual(none.map(\.identifier), [NotificationCategoryRegistry.spotPassSeekerCategoryID])
        let with = NotificationCategoryRegistry.launchCategories(
            addressEnabled: false, spotPassEnabled: true, includeDriverReminders: true)
        XCTAssertEqual(Set(with.map(\.identifier)), [NotificationCategoryRegistry.spotPassSeekerCategoryID, "SPOT_PASS_LEAVING"])
    }

    func testPushTokenProvider_onlyWhenAuthorized() async {
        let on = AppNotificationPushToken(tokenHex: { "abcd" }, status: { .authorized })
        let off = AppNotificationPushToken(tokenHex: { "abcd" }, status: { .denied })
        let undecided = AppNotificationPushToken(tokenHex: { "abcd" }, status: { .notDetermined })
        let onToken = await on.deviceToken()
        let offToken = await off.deviceToken()
        let undecidedToken = await undecided.deviceToken()
        XCTAssertEqual(onToken, "abcd")
        XCTAssertNil(offToken)
        XCTAssertNil(undecidedToken)
    }
}

// MARK: - 5. Notification routing

@MainActor
final class DriverNotificationRoutingTests: XCTestCase {

    func testRoute_actionsAndThanks() {
        XCTAssertEqual(DriverNotificationRoute.route(actionIdentifier: HandoffReminderPlan.actionLeavingNow, userInfo: [:]),
                       .action(.leavingNow(.notification)))
        XCTAssertEqual(DriverNotificationRoute.route(actionIdentifier: HandoffReminderPlan.actionExtend, userInfo: [:]), .action(.extend))
        XCTAssertEqual(DriverNotificationRoute.route(actionIdentifier: HandoffReminderPlan.actionCancel, userInfo: [:]), .action(.cancelNow))
        XCTAssertEqual(DriverNotificationRoute.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["kind": "thanks"]), .thanks)
        XCTAssertEqual(DriverNotificationRoute.route(actionIdentifier: "nope", userInfo: [:]), .ignore)
    }

    func testActionsRunInTheBackground_withoutAnyUI() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionLeavingNow, userInfo: [:])
        XCTAssertEqual(h.api.departSources, [.notification])
        XCTAssertEqual(h.controller.pass?.status, .departed)
    }

    func testExtendAction_andCancelAction() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionExtend, userInfo: [:])
        XCTAssertEqual(h.passes.pass?.extensions, 1)
        await h.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionCancel, userInfo: [:])
        XCTAssertNil(h.passes.pass)
        XCTAssertFalse(h.api.calls.contains("depart"))
    }

    func testThanksNotification_settlesKarma() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut()
        await h.controller.handleNotification(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["kind": "thanks"])
        XCTAssertEqual(h.controller.pass?.thanksReceived, true)
    }

    func testRuntimePush_thanks_toastsWhenTheCoverIsClosed_andIgnoresOtherPasses() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut()
        var toasts: [String] = []
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        runtime.showToast = { toasts.append($0) }

        await runtime.handle(push: SpotPassPushEvent(kind: .thanks, handoffID: UUID(), opened: false))
        XCTAssertTrue(toasts.isEmpty, "a push about someone else's pass must not touch this one")
        XCTAssertEqual(h.controller.pass?.thanksReceived, false)

        await runtime.handle(push: SpotPassPushEvent(kind: .thanks, handoffID: driverPassID, opened: false))
        XCTAssertEqual(toasts.count, 1)
        XCTAssertTrue(toasts.first?.contains("Thanks, neighbor!") ?? false)
        XCTAssertFalse(runtime.coverPresented)
    }

    func testRuntimePush_thanksTapped_opensTheCover_andHandoffEndedEndsThePass() async {
        let h = DriverHarness()
        await h.armed()
        await h.controller.pullOut()
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        await runtime.handle(push: SpotPassPushEvent(kind: .thanks, handoffID: nil, opened: true))
        XCTAssertTrue(runtime.coverPresented)

        let e = DriverHarness()
        await e.armed()
        let ended = SpotPassDriverRuntime(factory: { e.controller })
        await ended.handle(push: SpotPassPushEvent(kind: .handoffEnded, handoffID: nil, opened: false))
        XCTAssertEqual(e.controller.phase, .ended)
    }
}

// MARK: - 6. Welcome + onboarding composition

@MainActor
final class SpotPassWelcomeTests: XCTestCase {

    private func ctx(helped: Int, pending: Int) -> ClipHandoffContext {
        ClipHandoffContext(userId: "u", firstPassAt: Date(), passesHelped: helped, passesPendingKarma: pending, lastAlias: "Bodega Cat")
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "c2-welcome-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testCopy_onePassPending() {
        let c = SpotPassWelcomeContent.make(for: ctx(helped: 0, pending: 1))
        XCTAssertEqual(c.headline, "Welcome, neighbor.")
        XCTAssertEqual(c.body, "You've already helped 1 person park.")
        XCTAssertEqual(c.chipLabel, "+5 karma lands when they say thanks")
        XCTAssertEqual(c.chipStyle, .pending)
        XCTAssertEqual(c.primaryButton, "Show me around")
        XCTAssertEqual(c.skipButton, "Skip")
        XCTAssertEqual(c.accessibilityLabel, "Welcome, neighbor. You've already helped 1 person park. 5 karma pending until they say thanks.")
    }

    func testCopy_onePassSettled() {
        let c = SpotPassWelcomeContent.make(for: ctx(helped: 1, pending: 0))
        XCTAssertEqual(c.body, "You've already helped 1 person park.")
        XCTAssertEqual(c.chipLabel, "+5 karma \u{00B7} yours to keep")
        XCTAssertEqual(c.chipStyle, .settled)
    }

    func testCopy_manyPasses_pluralAndVariants() {
        let settled = SpotPassWelcomeContent.make(for: ctx(helped: 3, pending: 0))
        XCTAssertEqual(settled.body, "You've already helped 3 people park.")
        XCTAssertEqual(settled.chipLabel, "15 karma")
        XCTAssertEqual(settled.chipStyle, .settled)
        let mixed = SpotPassWelcomeContent.make(for: ctx(helped: 2, pending: 1))
        XCTAssertEqual(mixed.body, "You've already helped 3 people park.")
        XCTAssertEqual(mixed.chipStyle, .pending)
        XCTAssertEqual(mixed.chipLabel, "+5 karma lands when they say thanks")
    }

    func testCopy_armedButNeverDeparted_hasNoChip() {
        let c = SpotPassWelcomeContent.make(for: ctx(helped: 0, pending: 0))
        XCTAssertEqual(c.body, "You were ready to pass a spot. That's what this is all about.")
        XCTAssertNil(c.chipLabel)
        XCTAssertNil(c.chipStyle)
    }

    func testCopy_neverMentionsLocation_orBannedWords() {
        for (h, p) in [(0, 0), (0, 1), (1, 0), (4, 2)] {
            let c = SpotPassWelcomeContent.make(for: ctx(helped: h, pending: p))
            let all = [c.headline, c.body, c.chipLabel ?? "", c.primaryButton].joined(separator: " ").lowercased()
            for banned in ["ping", "claim", "token", "hurry", "free spot"] {
                XCTAssertFalse(all.contains(banned), "\(banned) in \(all)")
            }
        }
    }

    func testClassify_matrix() {
        typealias Policy = SpotPassOnboardingPolicy
        XCTAssertEqual(Policy.classify(isFreshInstall: true, hasClipContext: true, adoption: .adopted), .clip)
        XCTAssertEqual(Policy.classify(isFreshInstall: true, hasClipContext: true, adoption: .failed), .clip,
                       "adoption can fail without making the good deed untrue")
        XCTAssertEqual(Policy.classify(isFreshInstall: true, hasClipContext: true, adoption: .keptExistingSession), .organic,
                       "an existing session: no tailored welcome (spec 6.2)")
        XCTAssertEqual(Policy.classify(isFreshInstall: true, hasClipContext: false, adoption: .noContext), .organic)
        XCTAssertEqual(Policy.classify(isFreshInstall: false, hasClipContext: true, adoption: .adopted), .existing)
        XCTAssertEqual(Policy.classify(isFreshInstall: false, hasClipContext: false, adoption: .noContext), .existing)
    }

    func testShouldShowWelcome_matrix() {
        typealias Policy = SpotPassOnboardingPolicy
        func show(_ enabled: Bool = true, _ origin: SpotPassOnboardingOrigin? = .clip, context: Bool = true,
                  seen: Bool = false, link: Bool = false) -> Bool {
            Policy.shouldShowWelcome(enabled: enabled, origin: origin, hasClipContext: context, hasSeenWelcome: seen, linkPending: link)
        }
        XCTAssertTrue(show())
        XCTAssertFalse(show(false), "flag off")
        XCTAssertFalse(show(true, .organic))
        XCTAssertFalse(show(true, .existing))
        XCTAssertFalse(show(true, nil))
        XCTAssertFalse(show(context: false))
        XCTAssertFalse(show(seen: true))
        XCTAssertFalse(show(link: true), "no onboarding on a universal link open")
    }

    func testOrigin_isWrittenOnce() {
        let state = SpotPassOnboardingState(defaults: freshDefaults())
        XCTAssertNil(state.origin)
        XCTAssertEqual(state.recordOriginIfNeeded(.clip), .clip)
        XCTAssertEqual(state.recordOriginIfNeeded(.organic), .clip, "set once at the sentinel check")
        XCTAssertEqual(state.origin, .clip)
    }

    func testFinishWelcome_marksDeckSeen_andLeavesTheCoachAlone() {
        let defaults = freshDefaults()
        SpotPassWelcomeCoordinator.finishWelcome(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: AppConstants.hasSeenClipWelcomeKey))
        XCTAssertTrue(defaults.bool(forKey: AppConstants.hasSeenOnboardingStoryKey), "the 3-card deck never shows afterwards")
        XCTAssertNil(defaults.object(forKey: AppConstants.hasSeenOnboardingCoachKey), "Tier 3 still runs")
    }

    func testPrepare_clipOriginFreshInstall_showsWelcomeOnce() async {
        let defaults = freshDefaults()
        let store = ClipHandoffContextStore(defaults: defaults)
        store.save(ctx(helped: 0, pending: 1))
        let show = await SpotPassWelcomeCoordinator.prepare(
            isFreshInstall: true, enabled: true, adoption: { .adopted }, linkPending: false,
            defaults: defaults, contextStore: store)
        XCTAssertTrue(show)
        XCTAssertEqual(SpotPassOnboardingState(defaults: defaults).origin, .clip)

        SpotPassWelcomeCoordinator.finishWelcome(defaults: defaults)
        let again = await SpotPassWelcomeCoordinator.prepare(
            isFreshInstall: false, enabled: true, adoption: { .adopted }, linkPending: false,
            defaults: defaults, contextStore: store)
        XCTAssertFalse(again, "completed or skipped once: never again")
    }

    func testPrepare_organicFreshInstall_keepsTheDeck() async {
        let defaults = freshDefaults()
        let store = ClipHandoffContextStore(defaults: defaults)
        let show = await SpotPassWelcomeCoordinator.prepare(
            isFreshInstall: true, enabled: true, adoption: { .noContext }, linkPending: false,
            defaults: defaults, contextStore: store)
        XCTAssertFalse(show)
        XCTAssertEqual(SpotPassOnboardingState(defaults: defaults).origin, .organic)
    }

    func testPrepare_existingInstall_andLinkPending_neverShowWelcome() async {
        let defaults = freshDefaults()
        let store = ClipHandoffContextStore(defaults: defaults)
        store.save(ctx(helped: 1, pending: 0))
        let existing = await SpotPassWelcomeCoordinator.prepare(
            isFreshInstall: false, enabled: true, adoption: { .adopted }, linkPending: false,
            defaults: defaults, contextStore: store)
        XCTAssertFalse(existing)
        XCTAssertEqual(SpotPassOnboardingState(defaults: defaults).origin, .existing)

        let other = freshDefaults()
        let otherStore = ClipHandoffContextStore(defaults: other)
        otherStore.save(ctx(helped: 1, pending: 0))
        let withLink = await SpotPassWelcomeCoordinator.prepare(
            isFreshInstall: true, enabled: true, adoption: { .adopted }, linkPending: true,
            defaults: other, contextStore: otherStore)
        XCTAssertFalse(withLink, "the driver flow wins on a universal link")
    }

    func testPrepare_flagOff_isInert_andNeverTouchesAnything() async {
        let defaults = freshDefaults()
        let store = ClipHandoffContextStore(defaults: defaults)
        store.save(ctx(helped: 1, pending: 0))
        var adoptionCalled = false
        let show = await SpotPassWelcomeCoordinator.prepare(
            isFreshInstall: true, enabled: false, adoption: { adoptionCalled = true; return .adopted }, linkPending: false,
            defaults: defaults, contextStore: store)
        XCTAssertFalse(show)
        XCTAssertFalse(adoptionCalled)
        XCTAssertNil(SpotPassOnboardingState(defaults: defaults).origin)
    }

    func testOnboardingStoryDeck_isUnchanged() {
        // The standard deck's pure gating is untouched by C2 (organic installs, replay).
        XCTAssertTrue(onboardingStoryShouldShow(onboardingStoryEnabled: true, driveModeDefaultEnabled: true, gateShouldShow: true))
        XCTAssertFalse(onboardingStoryShouldShow(onboardingStoryEnabled: true, driveModeDefaultEnabled: true, gateShouldShow: false))
        XCTAssertEqual(OnboardingStoryCard.allCases.count, 3)
    }
}

// MARK: - 7. Clip adoption

@MainActor
private final class FakeAdoptionTarget: SpotPassSessionAdoptionTarget {
    var hasStoredSession = false
    var adoptResult = true
    private(set) var adopted: [(String, String)] = []
    func adoptSession(accessToken: String, refreshToken: String) async -> Bool {
        adopted.append((accessToken, refreshToken))
        return adoptResult
    }
}

@MainActor
final class SpotPassClipAdoptionTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "c2-adopt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    nonisolated private func record(userId: String = "user-1") -> ClipSessionRecord {
        ClipSessionRecord(userId: userId, accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
    }

    private func store(_ defaults: UserDefaults, userId: String = "user-1") -> ClipHandoffContextStore {
        let s = ClipHandoffContextStore(defaults: defaults)
        s.save(ClipHandoffContext(userId: userId, firstPassAt: Date(), passesHelped: 0, passesPendingKarma: 1, lastAlias: nil))
        return s
    }

    func testNoContext_nothingToAdopt_andNotPersisted() async {
        let defaults = freshDefaults()
        let target = FakeAdoptionTarget()
        let outcome = await SpotPassClipAdoption.adopt(
            target: target, contextStore: ClipHandoffContextStore(defaults: defaults), loadClipSession: { nil }, defaults: defaults)
        XCTAssertEqual(outcome, .noContext)
        XCTAssertNil(defaults.string(forKey: AppConstants.clipAdoptionOutcomeKey))
        XCTAssertTrue(target.adopted.isEmpty)
    }

    func testNoSession_adoptsTheClipsSession() async {
        let defaults = freshDefaults()
        let target = FakeAdoptionTarget()
        let outcome = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(defaults), loadClipSession: { self.record() }, defaults: defaults)
        XCTAssertEqual(outcome, .adopted)
        XCTAssertEqual(target.adopted.first?.0, "access")
        XCTAssertEqual(target.adopted.first?.1, "refresh")
        XCTAssertEqual(defaults.string(forKey: AppConstants.clipAdoptionOutcomeKey), "adopted")
    }

    func testExistingSession_isKept_clipIdentityLeftAlone() async {
        let defaults = freshDefaults()
        let target = FakeAdoptionTarget()
        target.hasStoredSession = true
        let outcome = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(defaults), loadClipSession: { self.record() }, defaults: defaults)
        XCTAssertEqual(outcome, .keptExistingSession)
        XCTAssertTrue(target.adopted.isEmpty, "MVP never merges identities (merge_anon_identity is Phase 2)")
    }

    func testUnreadableOrMismatchedSession_fails_withoutAdopting() async {
        let unreadableDefaults = freshDefaults()
        let target = FakeAdoptionTarget()
        let unreadable = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(unreadableDefaults), loadClipSession: { nil }, defaults: unreadableDefaults)
        XCTAssertEqual(unreadable, .failed)

        let mismatchDefaults = freshDefaults()
        let mismatch = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(mismatchDefaults, userId: "user-1"),
            loadClipSession: { self.record(userId: "someone-else") }, defaults: mismatchDefaults)
        XCTAssertEqual(mismatch, .failed)
        XCTAssertTrue(target.adopted.isEmpty)
    }

    func testAdoptRejected_isFailed() async {
        let defaults = freshDefaults()
        let target = FakeAdoptionTarget()
        target.adoptResult = false
        let outcome = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(defaults), loadClipSession: { self.record() }, defaults: defaults)
        XCTAssertEqual(outcome, .failed)
    }

    func testDecidedOncePerInstall() async {
        let defaults = freshDefaults()
        let target = FakeAdoptionTarget()
        _ = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(defaults), loadClipSession: { self.record() }, defaults: defaults)
        target.hasStoredSession = true   // by the second launch the full app has (the adopted) session
        let second = await SpotPassClipAdoption.adopt(
            target: target, contextStore: store(defaults), loadClipSession: { self.record() }, defaults: defaults)
        XCTAssertEqual(second, .adopted, "the recorded outcome stands; it is never recomputed against our own session")
        XCTAssertEqual(target.adopted.count, 1)
    }

    func testRun_isMemoized() async {
        let defaults = freshDefaults()
        let target = FakeAdoptionTarget()
        let adoption = SpotPassClipAdoption()
        let s = store(defaults)
        async let a = adoption.run(target: target, contextStore: s, loadClipSession: { self.record() }, defaults: defaults)
        async let b = adoption.run(target: target, contextStore: s, loadClipSession: { self.record() }, defaults: defaults)
        let (first, second) = await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(target.adopted.count, 1, "WeParkApp and ContentView both ask; the work happens once")
    }

    func testClipContextRoundTrip_keepsKarmaFields() {
        let defaults = freshDefaults()
        let s = ClipHandoffContextStore(defaults: defaults)
        s.save(ClipHandoffContext(userId: "u", firstPassAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  passesHelped: 2, passesPendingKarma: 1, lastAlias: "Stoop Pigeon"))
        let loaded = s.load()
        XCTAssertEqual(loaded?.passesHelped, 2)
        XCTAssertEqual(loaded?.passesPendingKarma, 1)
        XCTAssertEqual(loaded?.origin, "clip")
    }
}

// MARK: - 8. Link routing and runtime

@MainActor
final class SpotPassDriverLinkTests: XCTestCase {

    private let url = URL(string: "https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_-")!

    func testRouter_postsANotification_whenAccepted() {
        let inbox = SpotPassLinkInbox()
        let center = NotificationCenter()
        var received = 0
        let observer = center.addObserver(forName: .spotPassLinkReceived, object: nil, queue: nil) { _ in received += 1 }
        defer { center.removeObserver(observer) }
        XCTAssertTrue(SpotPassLinkRouter.handle(url, enabled: true, inbox: inbox, center: center))
        XCTAssertEqual(received, 1)
        XCTAssertNotNil(inbox.pending)
    }

    func testRouter_flagOff_postsNothing() {
        let inbox = SpotPassLinkInbox()
        let center = NotificationCenter()
        var received = 0
        let observer = center.addObserver(forName: .spotPassLinkReceived, object: nil, queue: nil) { _ in received += 1 }
        defer { center.removeObserver(observer) }
        XCTAssertFalse(SpotPassLinkRouter.handle(url, enabled: false, inbox: inbox, center: center))
        XCTAssertEqual(received, 0)
        XCTAssertNil(inbox.pending)
    }

    func testDrainInbox_flagOff_leavesTheBufferAndBuildsNothing() {
        let inbox = SpotPassLinkInbox()
        inbox.pending = SpotPassLink(url: url)
        let runtime = SpotPassDriverRuntime(factory: { DriverHarness().controller })
        runtime.drainInbox(enabled: false, inbox: inbox)
        XCTAssertNotNil(inbox.pending)
        XCTAssertFalse(runtime.hasController)
        XCTAssertFalse(runtime.coverPresented)
    }

    func testDrainInbox_flagOn_presentsTheFlow_andClearsTheBuffer() async {
        let h = DriverHarness()
        let inbox = SpotPassLinkInbox()
        inbox.pending = SpotPassLink(url: url)
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        runtime.drainInbox(enabled: true, inbox: inbox)
        await h.settle()
        XCTAssertNil(inbox.pending)
        XCTAssertTrue(runtime.coverPresented)
        XCTAssertEqual(h.controller.phase, .choosing)
        XCTAssertEqual(h.api.calls, ["peek"])
    }

    func testDrainInbox_emptyBuffer_isANoOp() {
        let runtime = SpotPassDriverRuntime(factory: { DriverHarness().controller })
        runtime.drainInbox(enabled: true, inbox: SpotPassLinkInbox())
        XCTAssertFalse(runtime.hasController)
    }

    func testGenericLanding_withNothingActive_toastsInsteadOfPresenting() {
        let h = DriverHarness()
        var toasts: [String] = []
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        runtime.showToast = { toasts.append($0) }
        guard let landing = SpotPassLink(url: URL(string: "https://getwepark.com/p") ?? url) else { return XCTFail() }
        XCTAssertFalse(runtime.present(link: landing))
        XCTAssertFalse(runtime.coverPresented)
        XCTAssertEqual(toasts, [ClipCopy.landingBody])
    }

    func testReminderBodyTap_opensThePullingOutScreen() async {
        let h = DriverHarness()
        await h.armed()
        let runtime = SpotPassDriverRuntime(factory: { h.controller })
        runtime.presentPullingOut()
        await h.settle()
        XCTAssertTrue(runtime.coverPresented)
        XCTAssertEqual(h.controller.phase, .pullingOut)
        XCTAssertFalse(h.api.calls.contains("depart"), "opening the screen never sends")
    }

    func testReminderBodyTap_withoutAPass_doesNothing() {
        let runtime = SpotPassDriverRuntime(factory: { DriverHarness().controller })
        runtime.presentPullingOut()
        XCTAssertFalse(runtime.coverPresented)
    }

    func testClipStyleDeepActionLink_performsOnAnActivePass() async {
        let h = DriverHarness()
        await h.armed()
        guard let link = SpotPassLink(url: ClipDeepAction.leavingNow(.liveActivity).url) else { return XCTFail() }
        XCTAssertTrue(h.controller.handle(link: link))
        await h.settle()
        XCTAssertEqual(h.api.departSources, [.liveActivity])
    }
}

// MARK: - 9. Secret hygiene

final class DriverSecretHygieneTests: XCTestCase {

    func testKeychainQuery_isLabelledNonSynced_accountScoped_andSeparateFromTheClip() {
        let id = driverPassID
        let attributes = DriverKeychainSecretStore.addAttributes(passID: id, data: Data([1]))
        XCTAssertEqual(attributes[kSecAttrLabel as String] as? String, "wepark-spotpass")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, id.uuidString.lowercased())
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNil(attributes[kSecAttrSynchronizable as String], "never iCloud-synced")
        XCTAssertNotEqual(DriverKeychainSecretStore.service, KeychainHandoffSecretStore.service)
        XCTAssertNotEqual(DriverKeychainSecretStore.label, SpotPassShared.clipKeychainLabel)
    }

    @MainActor
    func testSecretIsNotWrittenToTheStoredPass() async {
        let h = DriverHarness()
        await h.armed()
        let data = (try? JSONEncoder().encode(h.passes.pass)) ?? Data()
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("SECRET-SECRET") ?? true)
    }

    @MainActor
    func testSecretClearedAfterDepartAndCancel() async {
        let departed = DriverHarness()
        await departed.armed()
        await departed.controller.pullOut()
        XCTAssertNil(departed.secrets.secret(for: driverPassID))

        let cancelled = DriverHarness()
        await cancelled.armed()
        await cancelled.controller.confirmCancel()
        XCTAssertNil(cancelled.secrets.secret(for: driverPassID))
    }

    func testClaimerSecretRedacts() {
        XCTAssertFalse("\(ClaimerSecret("SECRET-SECRET"))".contains("SECRET-SECRET"))
    }
}

// MARK: - 10. Flag-off inertness

@MainActor
final class SpotPassDriverFlagOffTests: XCTestCase {

    func testShippedFlags_areOff() {
        XCTAssertFalse(AppConstants.spotHandoffEnabled)
        XCTAssertFalse(AppConstants.spotHandoffAutoDetectEnabled, "C4 stays out of scope")
    }

    func testIntentPerformer_isNotRegisteredByDefault_soEveryIntentIsInert() {
        // The real AppDelegate registers only with the flag on; nothing in the test host does.
        XCTAssertNil(SpotPassIntentRuntime.performer)
    }

    func testDriverKeysAreAbsentUntilUsed() {
        let defaults = UserDefaults.standard
        XCTAssertNil(defaults.object(forKey: AppConstants.hasSeenClipWelcomeKey))
    }

    func testNoAlwaysAuthorization_orBackgroundLocationAnywhereInThisStream() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertFalse(modes.contains("location"), "C4 (auto-detect) is not part of C2")
    }
}
