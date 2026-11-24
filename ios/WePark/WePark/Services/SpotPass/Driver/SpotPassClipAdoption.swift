//
//  SpotPassClipAdoption.swift
//  Services/SpotPass/Driver
//
//  Spot Pass C2 (spec 6.2, 6.3): clip -> full app carry-over.
//
//  ADOPTION (`SpotPassClipAdoption`): on the first full-app launch, if a clip context exists and the
//  full app has NO session of its own, adopt the clip's anonymous Supabase session (read from the
//  keychain item the clip wrote) so the karma and `helped_count` that live server-side on that uid
//  carry over. It runs BEFORE `ensureSession()` can mint a fresh anonymous session (`WeParkApp`
//  awaits it first), and is memoized so ContentView's launch setup can await the same result.
//  Anything that goes wrong falls back to a normal fresh anonymous session: the tailored welcome
//  still reads true (it comes from the context), only the karma would not follow.
//
//  DEVICE-ONLY: whether the clip's keychain item is readable from the full app is an OS behavior
//  (iOS 15.4+) that no unit test or simulator can prove; the unit tests cover the decision logic.
//
//  WELCOME (`SpotPassWelcomeCoordinator`): the launch-time decision "Welcome instead of the story
//  deck", and finishing it. All inert while `spotHandoffEnabled` is false (callers gate).
//

import Foundation

// MARK: - Adoption

/// The slice of `SupabaseAuthService` adoption needs (a protocol so tests fake it).
@MainActor
protocol SpotPassSessionAdoptionTarget: AnyObject {
    var hasStoredSession: Bool { get }
    func adoptSession(accessToken: String, refreshToken: String) async -> Bool
}

extension SupabaseAuthService: SpotPassSessionAdoptionTarget {}

@MainActor
final class SpotPassClipAdoption {

    static let shared = SpotPassClipAdoption()

    private var inFlight: Task<ClipAdoptionOutcome, Never>?

    init() {}

    /// Memoized: the first caller does the work, later callers await the same result.
    func run(
        target: any SpotPassSessionAdoptionTarget,
        contextStore: ClipHandoffContextStore = ClipHandoffContextStore(),
        loadClipSession: @escaping () -> ClipSessionRecord? = { GoTrueClipSession.loadRecord() },
        defaults: UserDefaults = .standard
    ) async -> ClipAdoptionOutcome {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in
            await Self.adopt(target: target, contextStore: contextStore, loadClipSession: loadClipSession, defaults: defaults)
        }
        inFlight = task
        return await task.value
    }

    /// The decision, unmemoized (unit-tested).
    static func adopt(
        target: any SpotPassSessionAdoptionTarget,
        contextStore: ClipHandoffContextStore,
        loadClipSession: () -> ClipSessionRecord?,
        defaults: UserDefaults
    ) async -> ClipAdoptionOutcome {
        // Decided once per install: the session question can only be answered before we mint our own.
        if let raw = defaults.string(forKey: AppConstants.clipAdoptionOutcomeKey),
           let recorded = ClipAdoptionOutcome(rawValue: raw) {
            return recorded
        }
        #if DEBUG
        SpotPassWelcomeDebug.seedIfRequested(into: contextStore)
        #endif
        guard let context = contextStore.load() else { return .noContext }

        let outcome: ClipAdoptionOutcome
        if target.hasStoredSession {
            outcome = .keptExistingSession
        } else if let record = loadClipSession(), record.userId.lowercased() == context.userId.lowercased() {
            outcome = await target.adoptSession(accessToken: record.accessToken, refreshToken: record.refreshToken)
                ? .adopted : .failed
        } else {
            outcome = .failed
        }
        defaults.set(outcome.rawValue, forKey: AppConstants.clipAdoptionOutcomeKey)
        return outcome
    }
}

// MARK: - Welcome coordination

@MainActor
enum SpotPassWelcomeCoordinator {

    /// Called from the launch setup right after the first-launch sentinel. Returns true when the
    /// tailored Welcome should present INSTEAD of the story deck. Records the onboarding origin once.
    static func prepare(
        isFreshInstall: Bool,
        enabled: Bool = AppConstants.spotHandoffEnabled,
        adoption: () async -> ClipAdoptionOutcome,
        linkPending: Bool? = nil,
        defaults: UserDefaults = .standard,
        contextStore: ClipHandoffContextStore = ClipHandoffContextStore()
    ) async -> Bool {
        guard enabled else { return false }
        #if DEBUG
        SpotPassWelcomeDebug.seedIfRequested(into: contextStore)
        #endif
        let linkIsPending = linkPending ?? (SpotPassLinkInbox.shared.pending != nil)
        let outcome = await adoption()
        let hasContext = contextStore.load() != nil
        let state = SpotPassOnboardingState(defaults: defaults)
        let computed = SpotPassOnboardingPolicy.classify(
            isFreshInstall: isFreshInstall, hasClipContext: hasContext, adoption: outcome
        )
        let origin = state.recordOriginIfNeeded(computed)
        return SpotPassOnboardingPolicy.shouldShowWelcome(
            enabled: enabled, origin: origin, hasClipContext: hasContext,
            hasSeenWelcome: state.hasSeenWelcome, linkPending: linkIsPending
        )
    }

    /// "Show me around" or "Skip": the deck never shows afterwards; Tier 2 and the Tier 3 coach follow unchanged.
    static func finishWelcome(defaults: UserDefaults = .standard) {
        SpotPassOnboardingState(defaults: defaults).markWelcomeFinished()
    }
}

#if DEBUG
/// DEBUG: `-spotPassSeedCarryOver YES` writes a fake clip context so the Welcome can be exercised
/// without running the clip. `-spotPassSeedHelped N` (default 1) and `-spotPassSeedPending N`
/// (default 1) shape the copy matrix. Never overwrites a real context.
enum SpotPassWelcomeDebug {
    static func seedIfRequested(into store: ClipHandoffContextStore, arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard ["YES", "true", "1"].contains(value(after: "-spotPassSeedCarryOver") ?? ""), store.load() == nil else { return }
        let helped = value(after: "-spotPassSeedHelped").flatMap(Int.init) ?? 0
        let pending = value(after: "-spotPassSeedPending").flatMap(Int.init) ?? 1
        store.save(ClipHandoffContext(
            userId: "00000000-0000-0000-0000-00000000fa4e", firstPassAt: Date(),
            passesHelped: helped, passesPendingKarma: pending, lastAlias: "Bodega Cat"
        ))
    }
}
#endif
