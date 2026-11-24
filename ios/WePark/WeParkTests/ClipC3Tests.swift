//
//  ClipC3Tests.swift
//  Spot Pass C3 (docs/specs/qr-spot-handoff.md sections 3, 5, 6, 7.2, 7.3, 8, 9;
//  docs/design/spot-pass-design.md section 3, 5, 6, 7, 8): the App Clip's pure logic and state
//  machine, against fakes only. No network, no real notification center, no ActivityKit, no keychain.
//
//  Groups: 1 chip math, 2 requests and wire, 3 secret hygiene, 4 reminders, 5 Live Activity state,
//  6 flow controller, 7 carry-over, 8 block insight, 9 fakes and launch options, 10 copy lint.
//

import XCTest
import UserNotifications
@testable import WePark

// MARK: - Test doubles

@MainActor
private final class ScriptedHandoffAPI: HandoffDriverAPI {
    var peekResult: Result<HandoffPeekResult, HandoffAPIError> =
        .success(.open(HandoffPassPreview(alias: "Bodega Cat", glyph: "bodega_cat", displayName: nil)))
    var claimResult: Result<HandoffClaimResult, HandoffAPIError>?
    var departResults: [Result<Bool, HandoffAPIError>] = [.success(true)]
    var extendResult: Result<HandoffExtendResult, HandoffAPIError> = .success(HandoffExtendResult(ok: true, leaveAt: nil, expiresAt: nil))
    var cancelResult: Result<Bool, HandoffAPIError> = .success(true)
    var reportResult = true

    let passID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()
    var grantLeaveAt: Date?
    private(set) var calls: [String] = []
    private(set) var lastClaim: HandoffClaimRequest?
    private(set) var lastClaimJWT: String?
    private(set) var lastDepartSource: HandoffDepartSource?
    private(set) var lastReport: HandoffReportTarget?
    var now: () -> Date = { Date() }

    func peek(token: String) async throws -> HandoffPeekResult {
        calls.append("peek")
        return try peekResult.get()
    }

    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult {
        calls.append("claim")
        lastClaim = request
        lastClaimJWT = userJWT
        if let claimResult { return try claimResult.get() }
        let leave = grantLeaveAt ?? request.leaveAt
        return .armed(HandoffArmedGrant(passID: passID, leaveAt: leave, expiresAt: leave.addingTimeInterval(900),
                                        secret: ClaimerSecret("SECRETSECRETSECRETSEC1")))
    }

    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool {
        calls.append("depart")
        lastDepartSource = source
        let next = departResults.isEmpty ? .success(true) : departResults.removeFirst()
        return try next.get()
    }

    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult {
        calls.append("extend")
        return try extendResult.get()
    }

    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool {
        calls.append("cancel")
        return try cancelResult.get()
    }

    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool {
        calls.append("report")
        lastReport = target
        return reportResult
    }
}

@MainActor
private final class RecordingReminders: HandoffReminderScheduling {
    var available: HandoffReminderAvailability = .on
    private(set) var scheduled: [PlannedReminder] = []
    private(set) var cancelledPassIDs: [UUID] = []
    func availability() async -> HandoffReminderAvailability { available }
    func schedule(_ reminders: [PlannedReminder], passID: UUID) async { scheduled = reminders }
    func cancelAll(passID: UUID) { cancelledPassIDs.append(passID) }
}

@MainActor
private final class RecordingActivity: HandoffActivityControlling {
    var areActivitiesEnabled = true
    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)?
    var token: String? = "ab12cd34ef56ab12cd34ef56ab12cd34ef56"
    private(set) var started = 0
    private(set) var updates: [SpotPassActivityAttributes.Phase] = []
    private(set) var ended: [SpotPassActivityAttributes.Phase] = []

    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?) {
        guard areActivitiesEnabled else { return (false, nil) }
        started += 1
        return (true, token)
    }
    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?) async { updates.append(phase) }
    func end(phase: SpotPassActivityAttributes.Phase, now: Date) async { ended.append(phase) }
}

@MainActor
private final class StubSession: ClipSessionProviding {
    var record: ClipSessionRecord? = ClipSessionRecord(userId: "user-1", accessToken: "jwt-1", refreshToken: "r", expiresAt: .distantFuture)
    func session() async -> ClipSessionRecord? { record }
}

@MainActor
private final class StubPushToken: HandoffPushTokenProviding {
    var token: String? = "00112233445566778899aabbccddeeff00112233"
    func deviceToken() async -> String? { token }
}

@MainActor
private final class RecordingFeedbackC3: HandoffFeedback {
    private(set) var events: [String] = []
    func selection() { events.append("selection") }
    func armImpact() { events.append("arm") }
    func success() { events.append("success") }
    func lightImpact() { events.append("light") }
    func announce(_ message: String) { events.append("announce:\(message)") }
}

private let c3Token = "AbCdEfGhIjKlMnOpQrSt_-"
private let c3URL = URL(string: "https://getwepark.com/p#t=\(c3Token)") ?? URL(fileURLWithPath: "/")

@MainActor
private final class Harness {
    let api = ScriptedHandoffAPI()
    let secrets = InMemoryHandoffSecretStore()
    let passes = InMemoryHandoffPassStore()
    let session = StubSession()
    let reminders = RecordingReminders()
    let activity = RecordingActivity()
    let push = StubPushToken()
    let feedback = RecordingFeedbackC3()
    let defaults: UserDefaults
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var controller: ClipFlowController!

    init() {
        let suite = "c3-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        controller = makeController()
    }

    func makeController() -> ClipFlowController {
        ClipFlowController(dependencies: ClipDependencies(
            api: api, secrets: secrets, passStore: passes, session: session, reminders: reminders,
            activity: activity, pushToken: push, feedback: feedback,
            carryOver: ClipHandoffContextStore(defaults: defaults),
            now: { [unowned self] in self.clock }, sentDwell: 0
        ))
    }

    var carryOver: ClipHandoffContextStore { ClipHandoffContextStore(defaults: defaults) }

    /// Scan + peek settled.
    func scan() async {
        controller.handle(url: c3URL)
        await settle()
    }

    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func armed(_ choice: LeaveChoice = .minutes(10)) async {
        await scan()
        controller.select(choice)
        await controller.arm()
    }
}

// MARK: - 1. Chip math

final class ClipLeaveChoiceTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)   // on a 5-minute boundary

    func testDefaultIsTenMinutes() {
        XCTAssertEqual(LeaveChoice.default, .minutes(10))
    }

    func testNow_isNowExactly_notRounded() {
        let now = base.addingTimeInterval(97)
        XCTAssertEqual(LeaveChoice.now.leaveAt(from: now), now)
    }

    func testPresets_roundToNearestFiveMinutes() {
        let now = base.addingTimeInterval(7 * 60)   // 7 min past a boundary
        XCTAssertEqual(LeaveChoice.minutes(10).leaveAt(from: now), base.addingTimeInterval(15 * 60))   // 17 -> 15
        XCTAssertEqual(LeaveChoice.minutes(30).leaveAt(from: now), base.addingTimeInterval(35 * 60))   // 37 -> 35
        XCTAssertEqual(LeaveChoice.minutes(60).leaveAt(from: now), base.addingTimeInterval(65 * 60))   // 67 -> 65
    }

    func testCustom_pastTimeClampsToNow() {
        let now = base.addingTimeInterval(120)
        let result = LeaveChoice.custom(base.addingTimeInterval(-3600)).leaveAt(from: now)
        XCTAssertGreaterThanOrEqual(result, now.addingTimeInterval(-150))
        XCTAssertLessThanOrEqual(result, now.addingTimeInterval(150))
    }

    func testCustom_neverExceedsFourHours_forAnyClockOffset() {
        for seconds in stride(from: 0, to: 600, by: 7) {
            let now = base.addingTimeInterval(Double(seconds))
            for picked in [4, 5, 9, 24].map({ now.addingTimeInterval(Double($0) * 3600) }) {
                let result = LeaveChoice.custom(picked).leaveAt(from: now)
                XCTAssertLessThanOrEqual(result.timeIntervalSince(now), 240 * 60, "offset \(seconds)")
                XCTAssertGreaterThanOrEqual(result, now)
            }
        }
    }

    func testCustomAtExactlyFourHours_staysWithinServerWindow() {
        let now = base.addingTimeInterval(61)
        let result = LeaveChoice.custom(now.addingTimeInterval(240 * 60)).leaveAt(from: now)
        // Server accepts up to now + 240 min 30 s.
        XCTAssertLessThanOrEqual(result.timeIntervalSince(now), 240 * 60 + 30)
        XCTAssertEqual(result.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
    }

    func testAllPresetsAreWithinCap() {
        let now = base.addingTimeInterval(299)
        for choice in LeaveChoice.presets {
            XCTAssertLessThanOrEqual(choice.leaveAt(from: now), LeaveChoice.latest(from: now))
        }
    }

    func testPickableRange_isNowToFourHours() {
        let range = LeaveChoice.pickableRange(from: base)
        XCTAssertEqual(range.lowerBound, base)
        XCTAssertEqual(range.upperBound, base.addingTimeInterval(4 * 3600))
    }

    func testChipCopy() {
        XCTAssertEqual(ClipCopy.chipTitle(.minutes(60)), "1 hr")
        XCTAssertEqual(ClipCopy.chipTitle(.minutes(10)), "10 min")
        XCTAssertEqual(ClipCopy.cta(choice: .minutes(10), name: "Bodega Cat"), "Tell Bodega Cat when I leave")
        XCTAssertEqual(ClipCopy.cta(choice: .now, name: "Bodega Cat"), "Tell Bodega Cat I'm on my way")
        XCTAssertEqual(ClipCopy.headline(name: nil), "A neighbor is waiting for your spot.")
        XCTAssertEqual(ClipCopy.headline(name: "Maya"), "Maya is waiting for your spot.")
    }
}

// MARK: - 2. Requests and wire

@MainActor
final class ClipRequestWireTests: XCTestCase {

    private let base = URL(string: "https://proj.supabase.co") ?? URL(fileURLWithPath: "/")
    private let passUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()

    private func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    func testPeekRequest_shape() throws {
        let request = try URLSessionHandoffDriverAPI.request(
            baseURL: base, anonKey: "anon", function: "handoff-peek", body: ["token": c3Token], userJWT: nil)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://proj.supabase.co/functions/v1/handoff-peek")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body(request)["token"] as? String, c3Token)
    }

    func testClaimRequest_carriesUserJWTOnlyWhenPresent() throws {
        let withJWT = try URLSessionHandoffDriverAPI.request(
            baseURL: base, anonKey: "anon", function: "handoff-claim", body: [:], userJWT: "jwt")
        XCTAssertEqual(withJWT.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        let without = try URLSessionHandoffDriverAPI.request(
            baseURL: base, anonKey: "anon", function: "handoff-claim", body: [:], userJWT: nil)
        XCTAssertNil(without.value(forHTTPHeaderField: "Authorization"))
    }

    func testClaimBody_withTokens_includesClipTopic() {
        let leave = Date(timeIntervalSince1970: 1_800_000_900)
        let request = HandoffClaimRequest(token: c3Token, leaveAt: leave, pushToken: "aa", activityToken: "bb",
                                          topic: SpotPassShared.clipBundleID)
        let json = HandoffWire.claimBody(request)
        XCTAssertEqual(json["token"] as? String, c3Token)
        XCTAssertEqual(json["push_token"] as? String, "aa")
        XCTAssertEqual(json["activity_token"] as? String, "bb")
        XCTAssertEqual(json["topic"] as? String, "com.kevinhoxha.wepark.Clip")
        XCTAssertEqual(json["leave_at"] as? String, HandoffWire.isoString(leave))
    }

    func testClaimBody_withoutTokens_omitsTokensAndTopic() {
        let json = HandoffWire.claimBody(HandoffClaimRequest(
            token: c3Token, leaveAt: Date(), pushToken: nil, activityToken: nil, topic: SpotPassShared.clipBundleID))
        XCTAssertNil(json["push_token"])
        XCTAssertNil(json["activity_token"])
        XCTAssertNil(json["topic"])
    }

    func testDepartBody_hasIdSecretSource() {
        let json = HandoffWire.securedBody(id: passUUID, secret: ClaimerSecret("S"),
                                           extra: ["source": HandoffDepartSource.liveActivity.rawValue])
        XCTAssertEqual(json["id"] as? String, passUUID.uuidString.lowercased())
        XCTAssertEqual(json["claimer_secret"] as? String, "S")
        XCTAssertEqual(json["source"] as? String, "live_activity")
    }

    func testSecretNeverInURLOrHeaders() throws {
        let body = HandoffWire.securedBody(id: passUUID, secret: ClaimerSecret("TOPSECRETVALUE"))
        let request = try URLSessionHandoffDriverAPI.request(
            baseURL: base, anonKey: "anon", function: "handoff-cancel", body: body, userJWT: nil)
        XCTAssertFalse(request.url?.absoluteString.contains("TOPSECRETVALUE") ?? true)
        XCTAssertFalse((request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("TOPSECRETVALUE") })
    }

    func testDepartSources_matchServerEnum() {
        XCTAssertEqual(Set(HandoffDepartSource.allCases.map(\.rawValue)),
                       ["manual", "live_activity", "notification", "auto", "start_driving", "shortcut"])
    }

    func testDecodePeek() throws {
        let open = Data(#"{"status":"open","alias":"Bodega Cat","glyph":"bodega_cat","display_name":null}"#.utf8)
        XCTAssertEqual(try HandoffWire.decodePeek(open),
                       .open(HandoffPassPreview(alias: "Bodega Cat", glyph: "bodega_cat", displayName: nil)))
        let named = Data(#"{"status":"open","alias":"Bodega Cat","glyph":"bodega_cat","display_name":"Maya"}"#.utf8)
        if case .open(let preview) = try HandoffWire.decodePeek(named) { XCTAssertEqual(preview.name, "Maya") } else { XCTFail() }
        XCTAssertEqual(try HandoffWire.decodePeek(Data(#"{"status":"unavailable"}"#.utf8)), .unavailable)
        XCTAssertThrowsError(try HandoffWire.decodePeek(Data("nope".utf8)))
    }

    func testDecodeClaim_withId() throws {
        let json = #"{"status":"armed","id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","leave_at":"2026-11-23T20:15:00Z","expires_at":"2026-11-23T20:30:00.123456+00:00","claimer_secret":"abcdefghijklmnopqrstuv"}"#
        guard case .armed(let grant) = try HandoffWire.decodeClaim(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(grant.passID, passUUID)
        XCTAssertEqual(grant.secret.rawValue, "abcdefghijklmnopqrstuv")
        XCTAssertEqual(grant.expiresAt.timeIntervalSince(grant.leaveAt), 900, accuracy: 1)
    }

    func testDecodeClaim_oldBackendWithoutId_hasNilPassID() throws {
        let json = #"{"status":"armed","leave_at":"2026-11-23T20:15:00Z","expires_at":"2026-11-23T20:30:00Z","claimer_secret":"abcdefghijklmnopqrstuv"}"#
        guard case .armed(let grant) = try HandoffWire.decodeClaim(Data(json.utf8)) else { return XCTFail() }
        XCTAssertNil(grant.passID)
    }

    func testDecodeClaim_unavailable() throws {
        XCTAssertEqual(try HandoffWire.decodeClaim(Data(#"{"status":"unavailable"}"#.utf8)), .unavailable)
    }

    func testDecodeOKAndExtend() throws {
        XCTAssertTrue(try HandoffWire.decodeOK(Data(#"{"ok":true}"#.utf8)))
        XCTAssertFalse(try HandoffWire.decodeOK(Data(#"{"ok":false}"#.utf8)))
        let extend = try HandoffWire.decodeExtend(Data(#"{"ok":true,"leave_at":"2026-11-23T20:20:00Z","expires_at":"2026-11-23T20:35:00Z"}"#.utf8))
        XCTAssertTrue(extend.ok)
        XCTAssertNotNil(extend.leaveAt)
    }

    func testStatusMapping_disabledAndRateLimited() {
        XCTAssertEqual(HandoffWire.error(forStatus: 503, body: Data(#"{"error":"disabled"}"#.utf8)), .disabled)
        XCTAssertEqual(HandoffWire.error(forStatus: 503, body: Data("x".utf8)), .server(statusCode: 503))
        XCTAssertEqual(HandoffWire.error(forStatus: 429, body: Data()), .rateLimited)
        XCTAssertEqual(HandoffWire.error(forStatus: 500, body: Data()), .server(statusCode: 500))
    }

    func testReportBodies() {
        XCTAssertEqual(HandoffWire.reportBody(target: .token(c3Token), reason: .spam)["token"] as? String, c3Token)
        let claimed = HandoffWire.reportBody(target: .claimed(id: passUUID, secret: ClaimerSecret("S")), reason: .unsafe)
        XCTAssertEqual(claimed["reason"] as? String, "unsafe")
        XCTAssertEqual(claimed["claimer_secret"] as? String, "S")
    }

    func testGoTrueRequestAndDecode() throws {
        let request = try XCTUnwrap(GoTrueClipSession.request(
            baseURL: base, anonKey: "anon", path: "auth/v1/signup", query: nil, body: ["data": [String: String]()]))
        XCTAssertEqual(request.url?.absoluteString, "https://proj.supabase.co/auth/v1/signup")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon")
        let now = Date(timeIntervalSince1970: 100)
        let record = GoTrueClipSession.decode(
            Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u-1"}}"#.utf8), now: now)
        XCTAssertEqual(record?.userId, "u-1")
        XCTAssertEqual(record?.expiresAt, now.addingTimeInterval(3600))
        XCTAssertNil(GoTrueClipSession.decode(Data("{}".utf8), now: now))
    }
}

// MARK: - 3. Secret hygiene

@MainActor
final class ClipSecretHygieneTests: XCTestCase {

    func testSecretRedactsEverywhere() {
        let secret = ClaimerSecret("SUPERSECRETSUPERSECRET")
        let grant = HandoffArmedGrant(passID: UUID(), leaveAt: Date(), expiresAt: Date(), secret: secret)
        var dumped = ""
        dump(grant, to: &dumped)
        let renderings = ["\(secret)", String(describing: secret), String(reflecting: secret),
                          "\(grant)", String(describing: grant), String(reflecting: grant), dumped]
        for text in renderings {
            XCTAssertFalse(text.contains("SUPERSECRETSUPERSECRET"), text)
        }
        XCTAssertEqual(secret.rawValue, "SUPERSECRETSUPERSECRET")
    }

    func testKeychainQuery_isLabelledNonSyncedAndAccountScoped() {
        let id = UUID()
        let attributes = KeychainHandoffSecretStore.addAttributes(passID: id, data: Data("s".utf8))
        XCTAssertEqual(attributes[kSecAttrLabel as String] as? String, SpotPassShared.clipKeychainLabel)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, KeychainHandoffSecretStore.service)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, id.uuidString.lowercased())
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNil(attributes[kSecAttrSynchronizable as String])
    }

    func testSecretIsNotWrittenToTheSharedDefaultsOrPassStore() async {
        let harness = Harness()
        await harness.armed()
        let stored = harness.defaults.dictionaryRepresentation().description
        XCTAssertFalse(stored.contains("SECRETSECRETSECRETSEC1"))
        let passJSON = (try? JSONEncoder().encode(harness.passes.pass)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(passJSON.contains("SECRETSECRETSECRETSEC1"))
        XCTAssertNotNil(harness.secrets.secret(for: harness.api.passID))
    }

    func testSecretClearedAfterDepartAndCancel() async {
        let departed = Harness()
        await departed.armed()
        await departed.controller.pullOut()
        XCTAssertNil(departed.secrets.secret(for: departed.api.passID))

        let cancelled = Harness()
        await cancelled.armed()
        await cancelled.controller.confirmCancel()
        XCTAssertNil(cancelled.secrets.secret(for: cancelled.api.passID))
    }
}

// MARK: - 4. Reminders

final class ClipReminderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()

    func testPlan_schedulesLeaveAtAndLastCall() {
        let leave = now.addingTimeInterval(600)
        let plan = HandoffReminderPlan.make(passID: id, name: "Bodega Cat", leaveAt: leave,
                                            expiresAt: leave.addingTimeInterval(900), now: now)
        XCTAssertEqual(plan.map(\.fireDate), [leave, leave.addingTimeInterval(600)])
        XCTAssertEqual(plan[0].title, "Time to go?")
        XCTAssertEqual(plan[0].body, "Bodega Cat is waiting for your spot.")
        XCTAssertEqual(plan[1].title, "Still leaving?")
        XCTAssertEqual(plan[1].body, "Bodega Cat's pass wraps up in 5 minutes.")
        XCTAssertEqual(plan[0].hiddenPreviewBody, "A neighbor is waiting for your spot.")
        XCTAssertEqual(plan[0].identifier, HandoffReminderPlan.leaveIdentifier(passID: id))
    }

    func testPlan_nowPass_skipsImmediateReminder() {
        let plan = HandoffReminderPlan.make(passID: id, name: "X", leaveAt: now,
                                            expiresAt: now.addingTimeInterval(900), now: now)
        XCTAssertEqual(plan.map(\.title), ["Still leaving?"])
    }

    func testPlan_nothingAtOrAfterExpiry() {
        let leave = now.addingTimeInterval(600)
        let plan = HandoffReminderPlan.make(passID: id, name: "X", leaveAt: leave, expiresAt: leave.addingTimeInterval(300), now: now)
        XCTAssertEqual(plan.count, 1)
    }

    func testCategory_hasThreeForegroundNonDestructiveActions() {
        let category = HandoffReminderPlan.category()
        XCTAssertEqual(category.identifier, "SPOT_PASS_LEAVING")
        XCTAssertEqual(category.actions.map(\.title), ["Leaving now", "5 more min", "Not leaving"])
        for action in category.actions {
            XCTAssertTrue(action.options.contains(.foreground), "clips cannot run background actions")
            XCTAssertFalse(action.options.contains(.destructive))
        }
    }

    func testDeepActionMapping() {
        XCTAssertEqual(HandoffReminderPlan.deepAction(forActionIdentifier: HandoffReminderPlan.actionLeavingNow), .leavingNow(.notification))
        XCTAssertEqual(HandoffReminderPlan.deepAction(forActionIdentifier: HandoffReminderPlan.actionExtend), .extend)
        XCTAssertEqual(HandoffReminderPlan.deepAction(forActionIdentifier: HandoffReminderPlan.actionCancel), .cancelNow)
        XCTAssertEqual(HandoffReminderPlan.deepAction(forActionIdentifier: UNNotificationDefaultActionIdentifier), .openPullingOut)
        XCTAssertNil(HandoffReminderPlan.deepAction(forActionIdentifier: "other"))
    }

    func testAvailability_ephemeralCountsAsOn() {
        XCTAssertEqual(HandoffReminderAvailability(status: .ephemeral), .on)
        XCTAssertEqual(HandoffReminderAvailability(status: .authorized), .on)
        XCTAssertEqual(HandoffReminderAvailability(status: .denied), .off)
        XCTAssertEqual(HandoffReminderAvailability(status: .notDetermined), .off)
    }

    func testNotificationRouting() {
        XCTAssertEqual(ClipNotificationRoute.route(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                   userInfo: ["kind": "thanks", "handoff_id": "x"]), .thanks)
        XCTAssertEqual(ClipNotificationRoute.route(actionIdentifier: HandoffReminderPlan.actionExtend, userInfo: [:]), .action(.extend))
        XCTAssertEqual(ClipNotificationRoute.route(actionIdentifier: "zzz", userInfo: [:]), .ignore)
    }

    func testTargetContentIdentifier_matchesRegisteredExperiencePrefix() {
        XCTAssertEqual(UNHandoffReminderScheduler.targetContentID, "https://getwepark.com/p")
    }
}

// MARK: - 5. Live Activity state and links

final class ClipActivityStateTests: XCTestCase {

    func testContentState_decodesBackendEndPayloads() throws {
        let thanks = try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: Data(#"{"phase":"thanks"}"#.utf8))
        XCTAssertEqual(thanks.phase, .thanks)
        XCTAssertNil(thanks.leaveAt)
        let ended = try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: Data(#"{"phase":"ended"}"#.utf8))
        XCTAssertEqual(ended.phase, .ended)
    }

    func testContentState_unknownOrMissingPhase_endsRatherThanCrashes() throws {
        let unknown = try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: Data(#"{"phase":"mystery"}"#.utf8))
        XCTAssertEqual(unknown.phase, .ended)
        let missing = try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.phase, .ended)
    }

    func testContentState_roundTripAndSize() throws {
        let state = SpotPassActivityAttributes.ContentState(phase: .counting, leaveAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                           startedAt: Date(timeIntervalSince1970: 1_799_999_000))
        let data = try JSONEncoder().encode(state)
        XCTAssertLessThan(data.count, 4096)
        XCTAssertEqual(try JSONDecoder().decode(SpotPassActivityAttributes.ContentState.self, from: data), state)
        let attributes = try JSONEncoder().encode(SpotPassActivityAttributes(alias: "Bodega Cat", glyph: "cat.fill", isClip: true))
        XCTAssertLessThan(attributes.count, 4096)
    }

    func testStaleDate_onlyWhileCounting() {
        let leave = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(HandoffActivityContent.staleDate(phase: .counting, leaveAt: leave), leave)
        XCTAssertNil(HandoffActivityContent.staleDate(phase: .passed, leaveAt: leave))
    }

    func testHexToken() {
        XCTAssertEqual(HandoffActivityContent.hex(Data([0x00, 0xAB, 0xFF])), "00abff")
    }

    func testDismissal_thanksLingersTenMinutes() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(HandoffActivityContent.dismissal(for: .thanks, now: now), now.addingTimeInterval(600))
        XCTAssertEqual(HandoffActivityContent.dismissal(for: .ended, now: now), now)
    }

    func testDeepActionLinks_roundTripThroughSpotPassLink() {
        for action in [ClipDeepAction.openPullingOut, .extend, .confirmCancel] {
            XCTAssertEqual(SpotPassLink(url: action.url)?.action, action)
            XCTAssertNil(SpotPassLink(url: action.url)?.token)
        }
        XCTAssertEqual(SpotPassLink(url: ClipDeepAction.leavingNow(.notification).url)?.action, .leavingNow(.liveActivity))
        XCTAssertNil(SpotPassLink(url: URL(string: "https://getwepark.com/p?a=bogus") ?? c3URL)?.action)
        XCTAssertNil(SpotPassLink(url: c3URL)?.action)
    }

    func testGlyphTint_isStableForAlias() {
        XCTAssertEqual(SpotPassGlyph.tintIndex(forAlias: "Bodega Cat"), SpotPassGlyph.tintIndex(forAlias: "Bodega Cat"))
        XCTAssertTrue((0..<4).contains(SpotPassGlyph.tintIndex(forAlias: "Stoop Pigeon")))
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "bodega_cat"), "cat.fill")
    }
}

// MARK: - 6. Flow controller

@MainActor
final class ClipFlowControllerTests: XCTestCase {

    func testNoToken_staysOnLanding() {
        let h = Harness()
        h.controller.handle(url: URL(string: "https://getwepark.com/p") ?? c3URL)
        XCTAssertEqual(h.controller.phase, .landing)
    }

    func testForeignURL_isIgnored() {
        let h = Harness()
        h.controller.handle(url: URL(string: "https://example.com/p#t=\(c3Token)") ?? c3URL)
        XCTAssertEqual(h.controller.phase, .landing)
    }

    func testScan_peeksAndShowsAlias_withTenMinutePreselected() async {
        let h = Harness()
        await h.scan()
        XCTAssertEqual(h.controller.phase, .choosing)
        XCTAssertEqual(h.controller.preview?.alias, "Bodega Cat")
        XCTAssertEqual(h.controller.choice, .minutes(10))
        XCTAssertEqual(h.api.calls, ["peek"])
        XCTAssertNil(h.passes.pass, "nothing is armed by a scan")
    }

    func testPeekUnavailable_offline_disabled_busy() async {
        let unavailable = Harness()
        unavailable.api.peekResult = .success(.unavailable)
        await unavailable.scan()
        XCTAssertEqual(unavailable.controller.phase, .unavailable)

        let offline = Harness()
        offline.api.peekResult = .failure(.offline)
        await offline.scan()
        XCTAssertEqual(offline.controller.phase, .offline)

        let disabled = Harness()
        disabled.api.peekResult = .failure(.disabled)
        await disabled.scan()
        XCTAssertEqual(disabled.controller.phase, .disabled)
        XCTAssertEqual(ClipMessageContent.content(for: .disabled).title, "Spot Pass isn't live yet.")

        let busy = Harness()
        busy.api.peekResult = .failure(.rateLimited)
        await busy.scan()
        XCTAssertEqual(busy.controller.phase, .busy)
    }

    func testRetryAfterOffline_peeksAgain() async {
        let h = Harness()
        h.api.peekResult = .failure(.offline)
        await h.scan()
        h.api.peekResult = .success(.open(HandoffPassPreview(alias: "Stoop Pigeon", glyph: "stoop_pigeon", displayName: nil)))
        h.controller.retry()
        await h.settle()
        XCTAssertEqual(h.controller.phase, .choosing)
        XCTAssertEqual(h.controller.preview?.alias, "Stoop Pigeon")
    }

    func testSameURLTwice_peeksOnce() async {
        let h = Harness()
        await h.scan()
        h.controller.handle(url: c3URL)
        await h.settle()
        XCTAssertEqual(h.api.calls.filter { $0 == "peek" }.count, 1)
    }

    func testArm_happyPath() async {
        let h = Harness()
        await h.armed(.minutes(30))
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertEqual(h.api.calls, ["peek", "claim"])
        let claim = h.api.lastClaim
        XCTAssertEqual(claim?.token, c3Token)
        XCTAssertEqual(claim?.topic, SpotPassShared.clipBundleID)
        XCTAssertEqual(claim?.activityToken, h.activity.token)
        XCTAssertEqual(claim?.pushToken, h.push.token)
        XCTAssertEqual(claim?.leaveAt, LeaveChoice.minutes(30).leaveAt(from: h.clock))
        XCTAssertEqual(h.api.lastClaimJWT, "jwt-1")
        XCTAssertEqual(h.activity.started, 1)
        XCTAssertEqual(h.activity.updates, [.counting])
        XCTAssertEqual(h.reminders.scheduled.count, 2)
        XCTAssertEqual(h.passes.pass?.status, .armed)
        XCTAssertEqual(h.controller.pass?.leaveAt, claim?.leaveAt)
        XCTAssertTrue(h.feedback.events.contains("arm"))
    }

    func testArm_remindersOff_skipsPushTokenAndScheduling() async {
        let h = Harness()
        h.reminders.available = .off
        await h.armed()
        XCTAssertNil(h.api.lastClaim?.pushToken)
        XCTAssertTrue(h.reminders.scheduled.isEmpty)
        XCTAssertEqual(h.controller.reminderAvailability, .off)
        XCTAssertEqual(h.controller.phase, .armed)
    }

    func testArm_liveActivitiesOff_stillArms() async {
        let h = Harness()
        h.activity.areActivitiesEnabled = false
        await h.armed()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertNil(h.api.lastClaim?.activityToken)
        XCTAssertFalse(h.controller.activityStarted)
        XCTAssertEqual(h.reminders.scheduled.count, 2)
    }

    func testArm_anonymousSignInFailure_doesNotBlockClaim() async {
        let h = Harness()
        h.session.record = nil
        await h.armed()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertNil(h.api.lastClaimJWT)
    }

    func testNowChip_opensTimeToGo_andNeverDeparts() async {
        let h = Harness()
        await h.armed(.now)
        XCTAssertEqual(h.controller.phase, .pullingOut)
        XCTAssertFalse(h.api.calls.contains("depart"))
        XCTAssertEqual(h.controller.pass?.leaveAt, h.clock)
    }

    func testClaimUnavailable_endsActivityAndShowsUnavailable() async {
        let h = Harness()
        h.api.claimResult = .success(.unavailable)
        await h.armed()
        XCTAssertEqual(h.controller.phase, .unavailable)
        XCTAssertEqual(h.activity.ended, [.ended])
        XCTAssertNil(h.passes.pass)
    }

    func testClaimOffline_returnsToChoosingWithInlineError() async {
        let h = Harness()
        h.api.claimResult = .failure(.offline)
        await h.armed()
        XCTAssertEqual(h.controller.phase, .choosing)
        XCTAssertEqual(h.controller.armFailure, .offline)
        XCTAssertEqual(h.activity.ended, [.ended])
    }

    func testClaimDisabled_showsNotLive() async {
        let h = Harness()
        h.api.claimResult = .failure(.disabled)
        await h.armed()
        XCTAssertEqual(h.controller.phase, .disabled)
    }

    func testClaimWithoutPassID_oldBackend_showsOpenAppFallback() async {
        let h = Harness()
        h.api.claimResult = .success(.armed(HandoffArmedGrant(
            passID: nil, leaveAt: h.clock.addingTimeInterval(600), expiresAt: h.clock.addingTimeInterval(1500),
            secret: ClaimerSecret("SECRETSECRETSECRETSEC1"))))
        await h.armed()
        XCTAssertEqual(h.controller.phase, .openApp)
        XCTAssertEqual(h.activity.ended, [.ended])
        XCTAssertNil(h.passes.pass)
        XCTAssertTrue(h.reminders.scheduled.isEmpty)
        XCTAssertEqual(ClipMessageContent.content(for: .openApp).title, "Open the WePark app to finish.")
    }

    func testDepart_celebratesAndRecordsPendingKarma() async {
        let h = Harness()
        await h.armed()
        await h.controller.pullOut()
        XCTAssertEqual(h.controller.phase, .celebration)
        XCTAssertEqual(h.api.lastDepartSource, .manual)
        XCTAssertEqual(h.controller.pass?.status, .departed)
        XCTAssertEqual(h.activity.updates, [.counting, .sent, .passed])
        XCTAssertTrue(h.reminders.cancelledPassIDs.contains(h.api.passID))
        let context = h.carryOver.load()
        XCTAssertEqual(context?.passesPendingKarma, 1)
        XCTAssertEqual(context?.passesHelped, 0)
        XCTAssertEqual(context?.userId, "user-1")
        XCTAssertEqual(context?.lastAlias, "Bodega Cat")
        XCTAssertEqual(context?.origin, "clip")
        XCTAssertTrue(h.feedback.events.contains("success"))
    }

    func testDepart_networkFailure_staysOnScreenWithRetry_thenRetryFalseCountsAsSent() async {
        let h = Harness()
        await h.armed()
        h.api.departResults = [.failure(.offline), .success(false)]
        await h.controller.pullOut()
        XCTAssertEqual(h.controller.phase, .pullingOut)
        XCTAssertTrue(h.controller.sendFailed)
        await h.controller.pullOut()
        XCTAssertEqual(h.controller.phase, .celebration, "ok:false on a retry means it may already be sent")
    }

    func testDepart_firstAttemptRejected_endsThePass() async {
        let h = Harness()
        await h.armed()
        h.api.departResults = [.success(false)]
        await h.controller.pullOut()
        XCTAssertEqual(h.controller.phase, .ended)
        XCTAssertNil(h.passes.pass)
    }

    func testDepart_isIdempotentOnceDeparted() async {
        let h = Harness()
        await h.armed()
        await h.controller.pullOut()
        await h.controller.pullOut()
        XCTAssertEqual(h.api.calls.filter { $0 == "depart" }.count, 1)
    }

    func testCancel_confirmedCancelsSilently() async {
        let h = Harness()
        await h.armed()
        h.controller.requestCancel()
        XCTAssertTrue(h.controller.showCancelConfirm)
        await h.controller.confirmCancel()
        XCTAssertEqual(h.controller.phase, .cancelled)
        XCTAssertTrue(h.api.calls.contains("cancel"))
        XCTAssertEqual(h.activity.ended.last, .cancelled)
        XCTAssertNil(h.passes.pass)
        XCTAssertTrue(h.reminders.cancelledPassIDs.contains(h.api.passID))
    }

    func testCancel_networkFailureKeepsPassAndToasts() async {
        let h = Harness()
        await h.armed()
        h.api.cancelResult = .failure(.offline)
        await h.controller.confirmCancel()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertEqual(h.controller.toast, ClipCopy.cancelFailed)
    }

    func testExtend_updatesTimesRemindersAndActivity() async {
        let h = Harness()
        await h.armed()
        let newLeave = h.clock.addingTimeInterval(900)
        h.api.extendResult = .success(HandoffExtendResult(ok: true, leaveAt: newLeave, expiresAt: newLeave.addingTimeInterval(900)))
        await h.controller.extendFiveMinutes()
        XCTAssertEqual(h.controller.pass?.leaveAt, newLeave)
        XCTAssertEqual(h.controller.pass?.extensions, 1)
        XCTAssertEqual(h.controller.toast, "Done. +5 minutes.")
        XCTAssertEqual(h.reminders.scheduled.first?.fireDate, newLeave)
        XCTAssertEqual(h.activity.updates.last, .counting)
    }

    func testExtend_capsAtThree() async {
        let h = Harness()
        await h.armed()
        for _ in 0..<3 { await h.controller.extendFiveMinutes() }
        h.controller.toast = nil
        await h.controller.extendFiveMinutes()
        XCTAssertEqual(h.api.calls.filter { $0 == "extend" }.count, 3)
        XCTAssertEqual(h.controller.toast, ClipCopy.extendFailed)
    }

    func testNotLeavingSoon_beforeArming_makesNoServerCall() async {
        let h = Harness()
        await h.scan()
        h.controller.notLeavingSoon()
        XCTAssertEqual(h.controller.phase, .dismissed)
        XCTAssertEqual(h.api.calls, ["peek"])
    }

    func testTick_expiresArmedPass() async {
        let h = Harness()
        await h.armed()
        h.clock = h.clock.addingTimeInterval(3600)
        await h.controller.tick()
        XCTAssertEqual(h.controller.phase, .ended)
        XCTAssertNil(h.passes.pass)
        XCTAssertEqual(h.activity.ended.last, .ended)
    }

    func testRestore_armedPass_backOnArmedScreen_noURLNeeded() async {
        let h = Harness()
        await h.armed()
        let restored = h.makeController()
        XCTAssertEqual(restored.phase, .armed)
        XCTAssertEqual(restored.pass?.alias, "Bodega Cat")
    }

    func testRestore_expiredPass_isEnded() async {
        let h = Harness()
        await h.armed()
        h.clock = h.clock.addingTimeInterval(7200)
        XCTAssertEqual(h.makeController().phase, .ended)
        XCTAssertNil(h.passes.pass)
    }

    func testRestore_departedPass_showsCelebration() async {
        let h = Harness()
        await h.armed()
        await h.controller.pullOut()
        XCTAssertEqual(h.makeController().phase, .celebration)
    }

    func testDeepActions_openPullingOutDoesNotSend_orCancel() async {
        let h = Harness()
        await h.armed()
        h.controller.handle(url: ClipDeepAction.openPullingOut.url)
        XCTAssertEqual(h.controller.phase, .pullingOut)
        h.controller.backToArmed()
        h.controller.handle(url: ClipDeepAction.confirmCancel.url)
        XCTAssertEqual(h.controller.phase, .pullingOut)
        XCTAssertTrue(h.controller.showCancelConfirm)
        XCTAssertFalse(h.api.calls.contains("depart"))
        XCTAssertFalse(h.api.calls.contains("cancel"), "opening alone must not cancel")
    }

    func testDeepActions_leavingNowFromLinkDeparts_withLiveActivitySource() async {
        let h = Harness()
        await h.armed()
        h.controller.handle(url: ClipDeepAction.leavingNow(.liveActivity).url)
        await h.settle()
        XCTAssertEqual(h.api.lastDepartSource, .liveActivity)
        XCTAssertEqual(h.controller.phase, .celebration)
    }

    func testNotificationActions_performImmediately() async {
        let notification = Harness()
        await notification.armed()
        notification.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionLeavingNow, userInfo: [:])
        await notification.settle()
        XCTAssertEqual(notification.api.lastDepartSource, .notification)

        let extend = Harness()
        await extend.armed()
        extend.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionExtend, userInfo: [:])
        await extend.settle()
        XCTAssertTrue(extend.api.calls.contains("extend"))

        let cancel = Harness()
        await cancel.armed()
        cancel.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionCancel, userInfo: [:])
        await cancel.settle()
        XCTAssertEqual(cancel.controller.phase, .cancelled)
    }

    func testActionsWithNoPass_areIgnored() {
        let h = Harness()
        h.controller.handle(url: ClipDeepAction.leavingNow(.liveActivity).url)
        h.controller.handleNotification(actionIdentifier: HandoffReminderPlan.actionCancel, userInfo: [:])
        XCTAssertEqual(h.controller.phase, .landing)
        XCTAssertTrue(h.api.calls.isEmpty)
    }

    func testActivePass_ignoresAnotherTokenScan() async {
        let h = Harness()
        await h.armed()
        h.controller.handle(url: URL(string: "https://getwepark.com/p#t=ZZZZZZZZZZZZZZZZZZZZZZ") ?? c3URL)
        await h.settle()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertEqual(h.api.calls.filter { $0 == "peek" }.count, 1)
    }

    func testThanks_settlesKarma_once() async {
        let h = Harness()
        await h.armed()
        await h.controller.pullOut()
        h.controller.receiveThanks()
        XCTAssertEqual(h.controller.pass?.thanksReceived, true)
        let context = h.carryOver.load()
        XCTAssertEqual(context?.passesPendingKarma, 0)
        XCTAssertEqual(context?.passesHelped, 1)
        h.controller.receiveThanks()
        XCTAssertEqual(h.carryOver.load()?.passesHelped, 1, "idempotent")
    }

    func testThanks_fromNotificationAndFromLiveActivityPush() async {
        let viaNotification = Harness()
        await viaNotification.armed()
        await viaNotification.controller.pullOut()
        viaNotification.controller.handleNotification(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                      userInfo: ["kind": "thanks"])
        XCTAssertEqual(viaNotification.controller.pass?.thanksReceived, true)

        let viaActivity = Harness()
        await viaActivity.armed()
        await viaActivity.controller.pullOut()
        viaActivity.activity.onRemotePhase?(.thanks)
        XCTAssertEqual(viaActivity.controller.pass?.thanksReceived, true)
    }

    func testThanksBeforeDeparture_isIgnored() async {
        let h = Harness()
        await h.armed()
        h.controller.receiveThanks()
        XCTAssertEqual(h.controller.pass?.thanksReceived, false)
    }

    func testRemoteEnd_whileArmed_endsThePass() async {
        let h = Harness()
        await h.armed()
        h.activity.onRemotePhase?(.ended)
        await h.settle()
        XCTAssertEqual(h.controller.phase, .ended)
    }

    func testInstallCard_onceAfterCelebration_neverTwiceInALaunch() async {
        let h = Harness()
        await h.armed()
        await h.controller.pullOut()
        XCTAssertFalse(h.controller.showInstallCard, "never before the 1.5 s beat")
        h.controller.celebrationLanded()
        XCTAssertTrue(h.controller.showInstallCard)
        h.controller.dismissInstallCard()
        h.controller.receiveThanks()
        h.controller.celebrationLanded()
        XCTAssertFalse(h.controller.showInstallCard)
    }

    func testInstallPolicy_isOncePerLaunch() {
        var policy = ClipInstallPromptPolicy()
        XCTAssertTrue(policy.shouldPresent())
        XCTAssertFalse(policy.shouldPresent())
    }

    func testReport_beforeClaim_usesToken_afterClaim_usesSecret() async {
        let before = Harness()
        await before.scan()
        await before.controller.report(.spam)
        XCTAssertEqual(before.api.lastReport, .token(c3Token))
        XCTAssertEqual(before.controller.phase, .unavailable)

        let after = Harness()
        await after.armed()
        await after.controller.report(.unsafe)
        if case .claimed(let id, _) = after.api.lastReport { XCTAssertEqual(id, after.api.passID) } else { XCTFail() }
        XCTAssertEqual(after.controller.phase, .ended)
    }

    func testSelect_firesSelectionHaptic() async {
        let h = Harness()
        await h.scan()
        h.controller.select(.minutes(30))
        XCTAssertEqual(h.controller.choice, .minutes(30))
        XCTAssertTrue(h.feedback.events.contains("selection"))
    }
}

// MARK: - 7. Carry-over

final class ClipCarryOverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstDeparture_createsContext_withPendingKarma() {
        let context = ClipCarryOver.afterDeparture(existing: nil, userId: "u", alias: "Bodega Cat", now: now)
        XCTAssertEqual(context.passesPendingKarma, 1)
        XCTAssertEqual(context.passesHelped, 0)
        XCTAssertEqual(context.firstPassAt, now)
        XCTAssertEqual(context.origin, "clip")
        XCTAssertEqual(context.v, 1)
    }

    func testSecondDeparture_keepsFirstPassAt() {
        let first = ClipCarryOver.afterDeparture(existing: nil, userId: "u", alias: "A", now: now)
        let second = ClipCarryOver.afterDeparture(existing: first, userId: "u", alias: "B", now: now.addingTimeInterval(99))
        XCTAssertEqual(second.firstPassAt, now)
        XCTAssertEqual(second.passesPendingKarma, 2)
        XCTAssertEqual(second.lastAlias, "B")
    }

    func testThanks_movesPendingToHelped_neverNegative() {
        let departed = ClipCarryOver.afterDeparture(existing: nil, userId: "u", alias: "A", now: now)
        let settled = ClipCarryOver.afterThanks(existing: departed)
        XCTAssertEqual(settled?.passesPendingKarma, 0)
        XCTAssertEqual(settled?.passesHelped, 1)
        XCTAssertEqual(ClipCarryOver.afterThanks(existing: settled)?.passesPendingKarma, 0)
        XCTAssertNil(ClipCarryOver.afterThanks(existing: nil))
    }

    func testStoreRoundTrip_viaAppGroupShapedDefaults() {
        let suite = "c3-carry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipHandoffContextStore(defaults: defaults)
        let context = ClipCarryOver.afterDeparture(existing: nil, userId: "u", alias: "A", now: now)
        store.save(context)
        XCTAssertEqual(store.load(), context)
    }

    func testPassStoreRoundTrip_andNoSecretFieldExists() {
        let suite = "c3-pass-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MainActorBox.run { UserDefaultsHandoffPassStore(defaults: defaults) }
        let pass = HandoffActivePass(id: UUID(), alias: "A", glyph: "g", displayName: nil, armedAt: now, leaveAt: now,
                                     expiresAt: now.addingTimeInterval(900), extensions: 0, status: .armed,
                                     departedAt: nil, thanksReceived: false, userId: "u")
        MainActorBox.run {
            store.save(pass)
            XCTAssertEqual(store.load(), pass)
            store.clear()
            XCTAssertNil(store.load())
        }
    }
}

/// Runs main-actor work from a nonisolated XCTestCase method.
private enum MainActorBox {
    static func run<T>(_ work: @MainActor () -> T) -> T {
        MainActor.assumeIsolated(work)
    }
}

// MARK: - 8. Block insight

@MainActor
final class ClipBlockInsightTests: XCTestCase {

    // 2026-12-01 is a Tuesday. 14:00 UTC = 9:00 AM ET (EST).
    private func et(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f.date(from: string) ?? Date()
    }

    private let tueFri = ClipTileRule(category: "ASP_TUE_FRI", days: [2, 5], timeRanges: [.init(start: 600, end: 690)], anytime: false)

    func testTileGrid_matchesPWAMath() {
        let cell = ClipTileGrid.tile(latitude: 40.76912, longitude: -73.99242)
        XCTAssertEqual(cell?.row, 30)
        XCTAssertEqual(cell?.col, 12)
        XCTAssertNil(ClipTileGrid.tile(latitude: 51.5, longitude: -0.12))
        XCTAssertNil(ClipTileGrid.tile(latitude: .nan, longitude: 0))
        XCTAssertEqual(ClipTileGrid.url(row: 30, col: 12)?.absoluteString, "https://kevhox1.github.io/parkmap/tiles/tile_30_12.json")
    }

    func testNextWindow_inProgress() {
        let now = et("2026-12-01T10:15:00-05:00")   // Tuesday, inside 10:00-11:30
        let window = StreetCleaningEvaluator.nextWindow(rules: [tueFri], now: now)
        XCTAssertEqual(window?.isInEffect(at: now), true)
        XCTAssertEqual(window?.end, et("2026-12-01T11:30:00-05:00"))
    }

    func testNextWindow_nextOccurrence() {
        let now = et("2026-12-01T12:00:00-05:00")   // Tuesday after the window -> Friday
        let window = StreetCleaningEvaluator.nextWindow(rules: [tueFri], now: now)
        XCTAssertEqual(window?.start, et("2026-12-04T10:00:00-05:00"))
        XCTAssertEqual(window?.isInEffect(at: now), false)
    }

    func testNextWindow_ignoresNonCleaningRules() {
        let metered = ClipTileRule(category: "METERED", days: [1, 2], timeRanges: [], anytime: true)
        XCTAssertNil(StreetCleaningEvaluator.nextWindow(rules: [metered], now: Date()))
    }

    func testAspDays_matchTheAppCategoryTable() {
        for category in WePark.Category.allCases where category.isASP {
            let mine = StreetCleaningEvaluator.aspDays(category: category.rawValue)
            let theirs = Set((0...6).filter { category.isASPDay($0) })
            XCTAssertEqual(mine, theirs, category.rawValue)
        }
    }

    func testLookup_snapsToNearestCurb_andOffersTheOtherSide() {
        let segments = ClipBlockLookup.decode(Data(FakeClipTileFetcher.json.utf8)) ?? []
        XCTAssertEqual(segments.count, 2)
        let now = et("2026-12-01T12:00:00-05:00")
        let result = ClipBlockLookup.lookup(latitude: 40.76911, longitude: -73.99239, segments: segments, now: now)
        XCTAssertEqual(result?.sides.map(\.side), ["N", "S"])
        XCTAssertNotNil(result?.sides.first?.window)
    }

    func testLookup_farFromAnyCurb_isNil() {
        let segments = ClipBlockLookup.decode(Data(FakeClipTileFetcher.json.utf8)) ?? []
        XCTAssertNil(ClipBlockLookup.lookup(latitude: 40.78, longitude: -73.97, segments: segments, now: Date()))
    }

    func testFormat_windowAndNextLines() {
        let window = CleaningWindow(start: et("2026-12-02T08:00:00-05:00"), end: et("2026-12-02T09:30:00-05:00"))
        XCTAssertEqual(ClipBlockFormat.windowLine(window), "Wednesday, 8:00 - 9:30 AM")
        XCTAssertEqual(ClipBlockFormat.nextLine(window), "Next: Wed, Dec 2")
    }

    func testController_resultThenSwitchSide() async {
        let controller = ClipBlockController(location: FakeClipLocation(), tiles: FakeClipTileFetcher())
        await controller.show()
        guard case .result(_, let first) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(first, 0)
        controller.switchSide()
        guard case .result(_, let second) = controller.state else { return XCTFail() }
        XCTAssertEqual(second, 1)
        controller.switchSide()
        guard case .result(_, let third) = controller.state else { return XCTFail() }
        XCTAssertEqual(third, 0)
    }

    private final class DeniedLocation: ClipLocationProviding {
        func requestCoordinate() async throws -> ClipCoordinate { throw ClipLocationError.denied }
    }

    func testController_denied_leavesNoNag() async {
        let controller = ClipBlockController(location: DeniedLocation(), tiles: FakeClipTileFetcher())
        await controller.show()
        XCTAssertEqual(controller.state, .denied)
        await controller.show()
        XCTAssertEqual(controller.state, .denied)
    }

    private final class MissingTile: ClipTileFetching {
        func tile(row: Int, col: Int) async throws -> Data? { nil }
    }
    private final class BrokenTile: ClipTileFetching {
        func tile(row: Int, col: Int) async throws -> Data? { throw HandoffAPIError.offline }
    }

    func testController_noTile_isNoRule_andFetchFailureIsFailed() async {
        let none = ClipBlockController(location: FakeClipLocation(), tiles: MissingTile())
        await none.show()
        XCTAssertEqual(none.state, .noRule)
        let broken = ClipBlockController(location: FakeClipLocation(), tiles: BrokenTile())
        await broken.show()
        XCTAssertEqual(broken.state, .failed)
    }
}

// MARK: - 9. Fakes and launch options

@MainActor
final class ClipFakeAndLaunchTests: XCTestCase {

    func testLaunchOptions_parseFlagsAndEnvironmentFallback() {
        let options = ClipLaunchOptions(
            arguments: ["app", "-spotPassUseFakeAPI", "YES", "-spotPassFakeScenario", "offline",
                        "-spotPassFakeLeaveSeconds", "20", "-spotPassFakeThanksAfter", "5"],
            environment: ["_XCAppClipURL": "https://getwepark.com/p#t=\(c3Token)"])
        XCTAssertTrue(options.useFakeAPI)
        XCTAssertEqual(options.scenario, .offline)
        XCTAssertEqual(options.fakeLeaveSeconds, 20)
        XCTAssertEqual(options.fakeThanksAfter, 5)
        XCTAssertEqual(options.injectedURL, c3URL)
    }

    func testLaunchOptions_argumentURLBeatsEnvironment_andDefaultsAreOff() {
        let explicit = ClipLaunchOptions(arguments: ["-spotPassClipURL", "https://getwepark.com/p"],
                                         environment: ["_XCAppClipURL": "https://getwepark.com/other"])
        XCTAssertEqual(explicit.injectedURL?.absoluteString, "https://getwepark.com/p")
        let none = ClipLaunchOptions(arguments: [], environment: [:])
        XCTAssertFalse(none.useFakeAPI)
        XCTAssertNil(none.injectedURL)
        XCTAssertEqual(none.scenario, .open)
    }

    func testFakeAPI_returnsIdAndSecret_andDepartRetrySemantics() async throws {
        let api = FakeHandoffDriverAPI()
        let claim = try await api.claim(
            HandoffClaimRequest(token: c3Token, leaveAt: Date(), pushToken: nil, activityToken: nil, topic: nil), userJWT: nil)
        guard case .armed(let grant) = claim else { return XCTFail() }
        XCTAssertNotNil(grant.passID)
        let first = try await api.depart(id: FakeHandoffDriverAPI.fakePassID, secret: grant.secret, source: .manual)
        let retry = try await api.depart(id: FakeHandoffDriverAPI.fakePassID, secret: grant.secret, source: .manual)
        XCTAssertTrue(first)
        XCTAssertFalse(retry)
    }

    func testFakeAPI_noIDScenario_returnsNilPassID() async throws {
        let api = FakeHandoffDriverAPI(scenario: .noID)
        let claim = try await api.claim(
            HandoffClaimRequest(token: c3Token, leaveAt: Date(), pushToken: nil, activityToken: nil, topic: nil), userJWT: nil)
        guard case .armed(let grant) = claim else { return XCTFail() }
        XCTAssertNil(grant.passID)
    }

    func testFakeAPI_leaveSecondsOverride() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let api = FakeHandoffDriverAPI(leaveSecondsOverride: 20, now: { now })
        let claim = try await api.claim(
            HandoffClaimRequest(token: c3Token, leaveAt: now.addingTimeInterval(600), pushToken: nil, activityToken: nil, topic: nil),
            userJWT: nil)
        guard case .armed(let grant) = claim else { return XCTFail() }
        XCTAssertEqual(grant.leaveAt, now.addingTimeInterval(20))
    }

    func testFakeFlow_endToEnd_throughTheController() async {
        let h = Harness()
        let controller = ClipFlowController(dependencies: ClipDependencies(
            api: FakeHandoffDriverAPI(), secrets: h.secrets, passStore: h.passes, session: FakeClipSession(),
            reminders: h.reminders, activity: h.activity, pushToken: FakePushTokenProvider(), feedback: h.feedback,
            carryOver: h.carryOver, now: { h.clock }, sentDwell: 0))
        controller.handle(url: c3URL)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(controller.preview?.alias, "Bodega Cat")
        await controller.arm()
        XCTAssertEqual(controller.phase, .armed)
        await controller.pullOut()
        XCTAssertEqual(controller.phase, .celebration)
    }
}

// MARK: - 10. Copy lint

final class ClipCopyLintTests: XCTestCase {

    private var allCopy: [String] {
        var strings: [String] = [
            ClipCopy.subline, ClipCopy.consent, ClipCopy.underCTA, ClipCopy.dismissedLine, ClipCopy.armedHeadline,
            ClipCopy.lockScreenBody, ClipCopy.tapWhenOut, ClipCopy.activitiesOff, ClipCopy.remindersOff, ClipCopy.bothOff,
            ClipCopy.timeToGo, ClipCopy.pullingOutSafety, ClipCopy.passedHeadline, ClipCopy.passedSub,
            ClipCopy.karmaPendingCaption, ClipCopy.installHeadline, ClipCopy.installBody, ClipCopy.installSecondary,
            ClipCopy.unavailableTitle, ClipCopy.unavailableBody, ClipCopy.offlineTitle, ClipCopy.offlineBody,
            ClipCopy.disabledTitle, ClipCopy.disabledBody, ClipCopy.openAppTitle, ClipCopy.openAppBody,
            ClipCopy.blockTeaserTitle, ClipCopy.blockTeaserSub, ClipCopy.blockFootnote, ClipCopy.blockForwardLink,
            ClipCopy.blockHappeningNow, ClipCopy.blockNoRule, ClipCopy.blockCheckSigns, ClipCopy.blockDenied,
            ClipCopy.reminderHiddenBody, ClipCopy.passEnded, ClipCopy.activityEnded,
            ClipCopy.headline(name: "Bodega Cat"), ClipCopy.sentLine(name: "Bodega Cat"),
            ClipCopy.thanksSub(name: "Bodega Cat"), ClipCopy.reminderBody(name: "Bodega Cat"),
            ClipCopy.lastCallBody(name: "Bodega Cat"), ClipCopy.armedSub(name: "Bodega Cat", reminderTime: "4:15 PM")
        ]
        strings += LeaveChoice.presets.map { ClipCopy.cta(choice: $0, name: "Bodega Cat") }
        return strings
    }

    func testNoBannedWords() {
        let banned = ["ping", "claim", "token", "free spot", "hurry", "rush", "grab", "steal", "snatch", "ticket", "fine"]
        for text in allCopy {
            for word in banned {
                let pattern = "\\b\(word)\\b"
                XCTAssertNil(text.lowercased().range(of: pattern, options: .regularExpression),
                             "\"\(text)\" contains \"\(word)\"")
            }
        }
    }

    func testAtMostOneExclamationMark_onlyOnThanks() {
        for text in allCopy where text.contains("!") {
            XCTAssertTrue(text.contains("Thanks, neighbor!"), text)
        }
        XCTAssertEqual(ClipCopy.thanksHeadline.filter { $0 == "!" }.count, 1)
    }

    func testNoLocationWordsInReminderCopy() {
        let reminder = [ClipCopy.reminderBody(name: "X"), ClipCopy.reminderHiddenBody, ClipCopy.lastCallBody(name: "X")]
        for text in reminder {
            XCTAssertFalse(text.lowercased().contains("location"))
            XCTAssertFalse(text.lowercased().contains("address"))
        }
    }

    func testKarmaCopyPromisesNothing() {
        XCTAssertEqual(ClipCopy.karmaPendingCaption, "lands when they say thanks")
        XCTAssertFalse(ClipCopy.passedHeadline.lowercased().contains("earned"))
    }
}
