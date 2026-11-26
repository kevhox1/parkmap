//
//  ClipDebugSupport.swift
//  Shared/SpotPass/Driver
//
//  DEBUG-only QA tooling for the App Clip (compiled out of Release entirely).
//
//  Launch arguments / environment (all DEBUG):
//    -spotPassUseFakeAPI YES            use `FakeHandoffDriverAPI` + fake location/tile/session/push token
//    -spotPassFakeScenario <name>       open (default) | unavailable | offline | disabled | slowPeek |
//                                       claimOffline | noID | departFails
//    -spotPassClipURL <https url>       inject an invocation URL at launch (works with the fake OR the real API)
//    _XCAppClipURL=<https url>          env var (also via SIMCTL_CHILD__XCAppClipURL): same injection, because
//                                       simctl launch sets the variable but never delivers the browsing activity
//    -spotPassFakeLeaveSeconds <n>      fake claim returns leave_at = now + n s (test reminders without waiting)
//    -spotPassFakeThanksAfter <n>       n seconds after a successful depart, simulate the seeker's thanks
//
//  The real ActivityKit controller, and the real reminder scheduler stay in use in fake
//  mode (the claimer secret is held in memory, since the unsigned simulator keychain write fails).
//

#if DEBUG
import Foundation
import UserNotifications

nonisolated enum ClipFakeScenario: String, Sendable {
    case open, unavailable, offline, disabled, slowPeek, claimOffline, noID, departFails
}

nonisolated struct ClipLaunchOptions: Equatable, Sendable {
    var useFakeAPI = false
    var scenario: ClipFakeScenario = .open
    var injectedURL: URL?
    var fakeLeaveSeconds: TimeInterval?
    var fakeThanksAfter: TimeInterval?

    init() {}

    init(arguments: [String], environment: [String: String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        useFakeAPI = ["YES", "true", "1"].contains(value(after: "-spotPassUseFakeAPI") ?? "")
        scenario = value(after: "-spotPassFakeScenario").flatMap(ClipFakeScenario.init(rawValue:)) ?? .open
        injectedURL = (value(after: "-spotPassClipURL") ?? environment["_XCAppClipURL"]).flatMap(URL.init(string:))
        fakeLeaveSeconds = value(after: "-spotPassFakeLeaveSeconds").flatMap(TimeInterval.init)
        fakeThanksAfter = value(after: "-spotPassFakeThanksAfter").flatMap(TimeInterval.init)
    }
}

// MARK: - Fake API

@MainActor
final class FakeHandoffDriverAPI: HandoffDriverAPI {

    static let fakeSecret = ClaimerSecret("FAKEFAKEFAKEFAKEFAKE12")
    static let fakePassID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

    var scenario: ClipFakeScenario
    var leaveSecondsOverride: TimeInterval?
    private(set) var calls: [String] = []
    private var departAttempts = 0
    private let now: () -> Date

    init(scenario: ClipFakeScenario = .open, leaveSecondsOverride: TimeInterval? = nil, now: @escaping () -> Date = { Date() }) {
        self.scenario = scenario
        self.leaveSecondsOverride = leaveSecondsOverride
        self.now = now
    }

    func peek(token: String) async throws -> HandoffPeekResult {
        calls.append("peek")
        switch scenario {
        case .offline: throw HandoffAPIError.offline
        case .disabled: throw HandoffAPIError.disabled
        case .unavailable: return .unavailable
        case .slowPeek: try? await Task.sleep(nanoseconds: 3_500_000_000)
        default: break
        }
        return .open(HandoffPassPreview(alias: "Bodega Cat", glyph: "bodega_cat", displayName: nil))
    }

    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult {
        calls.append("claim")
        if scenario == .claimOffline { throw HandoffAPIError.offline }
        let leaveAt = leaveSecondsOverride.map { now().addingTimeInterval($0) } ?? request.leaveAt
        return .armed(HandoffArmedGrant(
            passID: scenario == .noID ? nil : Self.fakePassID,
            leaveAt: leaveAt, expiresAt: leaveAt.addingTimeInterval(15 * 60), secret: Self.fakeSecret
        ))
    }

    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool {
        calls.append("depart:\(source.rawValue)")
        departAttempts += 1
        if scenario == .departFails, departAttempts == 1 { throw HandoffAPIError.offline }
        return departAttempts == 1
    }

    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult {
        calls.append("extend")
        let base = now().addingTimeInterval(5 * 60)
        return HandoffExtendResult(ok: true, leaveAt: base, expiresAt: base.addingTimeInterval(15 * 60))
    }

    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool {
        calls.append("cancel")
        return true
    }

    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool {
        calls.append("report:\(reason.rawValue)")
        return true
    }
}

// MARK: - Secret store for fake mode

/// In-memory claimer-secret store so the whole fake flow is reachable in an UNSIGNED simulator build,
/// where the real keychain write fails (-34018). Used only when `-spotPassUseFakeAPI YES` is passed
/// (see `ClipLaunchOptions.makeSecretStore()`); the fake secret is a constant, never a real one.
@MainActor
final class DebugInMemoryHandoffSecretStore: HandoffSecretStoring {
    /// DEBUG-only (compiled out of Release): fake mode also mirrors the constant fake secret here so a
    /// relaunched armed pass can still act. Never a real secret.
    nonisolated static let defaultsKey = "spotPassDebugFakeSecret"
    private let defaults: UserDefaults
    private var stored: (UUID, ClaimerSecret)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultsKey) {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = UUID(uuidString: parts[0]) { stored = (id, ClaimerSecret(parts[1])) }
        }
    }

    @discardableResult func save(_ secret: ClaimerSecret, passID: UUID) -> Bool {
        stored = (passID, secret)
        defaults.set("\(passID.uuidString)|\(secret.rawValue)", forKey: Self.defaultsKey)
        return true
    }
    func secret(for passID: UUID) -> ClaimerSecret? { stored?.0 == passID ? stored?.1 : nil }
    func clear() {
        stored = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

extension ClipLaunchOptions {
    /// The in-memory store ONLY in fake-API mode; the real keychain store otherwise.
    @MainActor func makeSecretStore() -> any HandoffSecretStoring {
        useFakeAPI ? DebugInMemoryHandoffSecretStore() : KeychainHandoffSecretStore()
    }
}

// MARK: - Other fakes used in fake mode

@MainActor
final class FakeClipSession: ClipSessionProviding {
    func session() async -> ClipSessionRecord? {
        ClipSessionRecord(userId: "00000000-0000-0000-0000-00000000fa4e", accessToken: "fake", refreshToken: "fake",
                          expiresAt: Date().addingTimeInterval(3600))
    }
}

@MainActor
final class FakePushTokenProvider: HandoffPushTokenProviding {
    func deviceToken() async -> String? { nil }
}

@MainActor
final class FakeClipLocation: ClipLocationProviding {
    /// West 55th Street between 11th and 12th Avenue (inside `tile_30_12`).
    func requestCoordinate() async throws -> ClipCoordinate {
        ClipCoordinate(latitude: 40.76912, longitude: -73.99242)
    }
}

@MainActor
final class FakeClipTileFetcher: ClipTileFetching {
    /// A two-curb block with Tue/Fri sweeping on the north side and Mon/Thu on the south.
    static let json = """
    [{"id":"A","street":"WEST 55TH STREET","from":"11TH AVENUE","to":"12TH AVENUE","side":"N",
      "line":[[40.76911,-73.99239],[40.769137,-73.992454]],
      "rules":[{"category":"ASP_TUE_FRI","description":"x","days":[2,5],"timeRanges":[{"start":600,"end":690}],"anytime":false,"arrow":"both"}]},
     {"id":"B","street":"WEST 55TH STREET","from":"11TH AVENUE","to":"12TH AVENUE","side":"S",
      "line":[[40.76905,-73.99239],[40.769077,-73.992454]],
      "rules":[{"category":"ASP_MON_THU","description":"x","days":[1,4],"timeRanges":[{"start":540,"end":630}],"anytime":false,"arrow":"both"}]}]
    """

    func tile(row: Int, col: Int) async throws -> Data? { Data(Self.json.utf8) }
}

/// Real scheduler, but in fake mode on a simulator the ephemeral status never appears, so ask for
/// ordinary permission once. DEBUG only: production clips never prompt (spec 5.1).
@MainActor
final class DebugAuthorizingReminderScheduler: HandoffReminderScheduling {
    private let inner = UNHandoffReminderScheduler()

    func availability() async -> HandoffReminderAvailability {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        return await inner.availability()
    }

    func schedule(_ reminders: [PlannedReminder], passID: UUID) async { await inner.schedule(reminders, passID: passID) }
    func cancelAll(passID: UUID) { inner.cancelAll(passID: passID) }
}
#endif
