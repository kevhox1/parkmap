//
//  ClipComposition.swift
//  WePark Clip
//
//  Builds the clip's object graph: live services, or (DEBUG only, `-spotPassUseFakeAPI YES`) the
//  fake API plus fake location / tile / session / push token. The real ActivityKit controller,
//  reminder scheduler stay live in fake mode (secret held in memory) so QA exercises the real surfaces.
//

import Foundation

/// Used when SUPABASE_URL / SUPABASE_ANON_KEY are missing from the bundle: every call fails as
/// "can't reach WePark" instead of crashing.
@MainActor
final class UnconfiguredHandoffAPI: HandoffDriverAPI {
    func peek(token: String) async throws -> HandoffPeekResult { throw HandoffAPIError.offline }
    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult { throw HandoffAPIError.offline }
    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool { throw HandoffAPIError.offline }
    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult { throw HandoffAPIError.offline }
    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool { throw HandoffAPIError.offline }
    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool { throw HandoffAPIError.offline }
}

@MainActor
struct ClipComposition {
    let controller: ClipFlowController
    let block: ClipBlockController
    #if DEBUG
    let options: ClipLaunchOptions
    #endif

    static func make() -> ClipComposition {
        let defaults = SpotPassShared.sharedDefaults() ?? .standard
        #if DEBUG
        let options = ClipLaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        if options.useFakeAPI {
            let dependencies = ClipDependencies(
                api: FakeHandoffDriverAPI(scenario: options.scenario, leaveSecondsOverride: options.fakeLeaveSeconds),
                secrets: options.makeSecretStore(),
                passStore: UserDefaultsHandoffPassStore(defaults: defaults),
                session: FakeClipSession(),
                reminders: DebugAuthorizingReminderScheduler(),
                activity: ActivityKitHandoffActivityController(),
                pushToken: FakePushTokenProvider(),
                feedback: SystemHandoffFeedback(),
                carryOver: ClipHandoffContextStore(defaults: defaults)
            )
            return ClipComposition(
                controller: ClipFlowController(dependencies: dependencies),
                block: ClipBlockController(location: FakeClipLocation(), tiles: FakeClipTileFetcher()),
                options: options
            )
        }
        #endif

        let api: any HandoffDriverAPI = URLSessionHandoffDriverAPI() ?? UnconfiguredHandoffAPI()
        let session: any ClipSessionProviding = GoTrueClipSession() ?? NoClipSession()
        let dependencies = ClipDependencies(
            api: api,
            secrets: KeychainHandoffSecretStore(),
            passStore: UserDefaultsHandoffPassStore(defaults: defaults),
            session: session,
            reminders: UNHandoffReminderScheduler(),
            activity: ActivityKitHandoffActivityController(),
            pushToken: ClipPushTokenBroker.shared,
            feedback: SystemHandoffFeedback(),
            carryOver: ClipHandoffContextStore(defaults: defaults)
        )
        let block = ClipBlockController(location: ClipCoreLocationProvider(), tiles: URLSessionClipTileFetcher())
        #if DEBUG
        return ClipComposition(controller: ClipFlowController(dependencies: dependencies), block: block, options: options)
        #else
        return ClipComposition(controller: ClipFlowController(dependencies: dependencies), block: block)
        #endif
    }
}

@MainActor
final class NoClipSession: ClipSessionProviding {
    func session() async -> ClipSessionRecord? { nil }
}
