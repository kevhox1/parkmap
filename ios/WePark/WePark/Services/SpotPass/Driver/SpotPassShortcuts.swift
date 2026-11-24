//
//  SpotPassShortcuts.swift
//  Services/SpotPass/Driver
//
//  Spot Pass C2 (spec 7.5): exposes `LeavingNowIntent` to Siri and the Shortcuts app so the user can
//  build "when my phone connects to my car" themselves (the app only GUIDES: `CarAutoPingGuideView`).
//
//  Metadata caveat (flagged in the PR): App Intents metadata is generated at BUILD time and cannot be
//  gated by the runtime `spotHandoffEnabled` constant. With the flag off the action is therefore
//  listed in Shortcuts, but running it is inert: nothing registers the performer
//  (`SpotPassIntentRuntime.performer` is nil), so it answers "No active Spot Pass" and touches nothing.
//

import AppIntents

nonisolated struct WeParkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LeavingNowIntent(),
            phrases: [
                "I'm leaving, \(.applicationName)",
                "Tell my neighbor I'm leaving with \(.applicationName)"
            ],
            shortTitle: "I'm leaving",
            systemImageName: "car.fill"
        )
    }
}
