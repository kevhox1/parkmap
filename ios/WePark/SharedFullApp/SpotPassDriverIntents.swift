//
//  SpotPassDriverIntents.swift
//  SharedFullApp: compiled into the full app AND the full-app Live Activities extension only
//  (never the App Clip targets: App Intents are inert in clips, spec section 4, and the clip
//  size budget is tight).
//
//  Spot Pass C2 (docs/specs/qr-spot-handoff.md 7.2, 7.5; design 5.1): the interactive Live
//  Activity buttons and the Shortcuts action.
//
//  WHY THE BRIDGE: a `LiveActivityIntent` runs in the APP process, but the type must exist in the
//  widget extension too (`Button(intent:)` renders it). The extension therefore compiles these
//  structs without any app services. `perform()` forwards to `SpotPassIntentRuntime.performer`,
//  which only the app registers (`AppDelegate`, flag-gated). Nothing registered (flag off, or the
//  extension process) means every intent answers "No active Spot Pass" and touches nothing.
//
//  ISOLATION: the project defaults to MainActor isolation. The intent structs stay MainActor (a type-level
//  `nonisolated` makes the @Parameter macro emit "nonisolated cannot be applied to mutable stored
//  properties", an error in Swift 6 mode); their static metadata and inits are `nonisolated` to satisfy
//  AppIntents requirements, and `perform()` (which touches the main-actor performer) is `@MainActor`.
//
//  PRIVACY: an intent carries a pass id (a random UUID) at most. No location, no secret (the
//  claimer secret stays in the app's keychain).
//

import AppIntents
import Foundation

// MARK: - Outcome (pure)

/// What an intent run did. The dialog is what Shortcuts speaks/shows; Live Activity buttons ignore it.
nonisolated enum SpotPassIntentOutcome: Equatable, Sendable {
    case sent
    case alreadySent
    case extended
    case cancelled
    case noActivePass
    case failed

    var dialog: String {
        switch self {
        case .sent: return "Told your neighbor you're pulling out. Drive safe."
        case .alreadySent: return "Your neighbor already knows you're pulling out."
        case .extended: return "Done. Five more minutes."
        case .cancelled: return "Pass cancelled. Your neighbor won't be told."
        case .noActivePass: return "No active Spot Pass."
        case .failed: return "Couldn't send. Open WePark and try again."
        }
    }
}

// MARK: - Bridge

/// Implemented by the app (`SpotPassDriverIntentPerformer`). `passID` is the pass the button was
/// rendered for (nil from Shortcuts: "whatever pass is armed"). A mismatching id is a no-op, so a
/// stale lock-screen button can never act on a newer pass.
@MainActor
protocol SpotPassIntentPerforming: AnyObject {
    func leavingNow(passID: String?) async -> SpotPassIntentOutcome
    func fiveMoreMinutes(passID: String?) async -> SpotPassIntentOutcome
    func notLeaving(passID: String?) async -> SpotPassIntentOutcome
}

@MainActor
enum SpotPassIntentRuntime {
    /// Set by `AppDelegate.didFinishLaunching` when `AppConstants.spotHandoffEnabled`. nil elsewhere.
    static var performer: (any SpotPassIntentPerforming)?
}

// MARK: - Intents

/// "Leaving now". The Live Activity / lock-screen button AND the Shortcuts action ("when my phone
/// connects to my car", spec 7.5): the pass id is present from the Live Activity, absent from Shortcuts.
struct LeavingNowIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "I'm leaving"
    nonisolated static let description = IntentDescription(
        "Tells the neighbor waiting for your Spot Pass spot that you are pulling out. Does nothing if you have no active Spot Pass."
    )
    /// A one-bit event with no personal data: allowed from a locked phone (spec 7.2; device test
    /// whether the OS still asks to unlock, unlock-then-send is the accepted degraded path).
    /// Ships DARK: not offered as a Shortcuts action until the Spot Pass flag flips (re-enable
    /// together with `SpotPassShortcuts.swift` and the car auto-ping guide). Live Activity buttons
    /// and notification actions still work: they instantiate the intent directly.
    nonisolated static let isDiscoverable = false
    nonisolated static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "Pass")
    var passID: String?

    nonisolated init() {}

    nonisolated init(passID: String?) {
        self.passID = passID
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SpotPassIntentRuntime.performer?.leavingNow(passID: passID) ?? .noActivePass
        return .result(dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

/// "5 more min" on the Time-to-go state. Live Activity only (not offered in Shortcuts).
struct FiveMoreMinutesIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Five more minutes"
    nonisolated static let description = IntentDescription("Gives your Spot Pass five more minutes.")
    nonisolated static let isDiscoverable = false
    nonisolated static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "Pass")
    var passID: String?

    nonisolated init() {}

    nonisolated init(passID: String?) {
        self.passID = passID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await SpotPassIntentRuntime.performer?.fiveMoreMinutes(passID: passID)
        return .result()
    }
}

/// "Not leaving". Silent to the neighbor (spec 3, 9 item 3). Live Activity only.
struct NotLeavingIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Not leaving"
    nonisolated static let description = IntentDescription("Cancels your Spot Pass. The neighbor is not told.")
    nonisolated static let isDiscoverable = false
    nonisolated static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "Pass")
    var passID: String?

    nonisolated init() {}

    nonisolated init(passID: String?) {
        self.passID = passID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await SpotPassIntentRuntime.performer?.notLeaving(passID: passID)
        return .result()
    }
}
