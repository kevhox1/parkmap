//
//  WPPhase6aShowcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp6aShowcase <name>`
//  ContentView mounts the REAL Stoop Phase 6a views (onboarding story, location priming, More,
//  Settings and its sub-screens) over fixture values in their own window, so screenshots are
//  repeatable without flipping any flag:
//
//    story1 story2 story3 location more settings reminders reminders-off colors help help-topic
//    about sources delete suggest
//
//  `-wpDark` forces dark (default is light, the Stoop default). Nothing here runs in a Release
//  build or without the launch argument.
//

#if DEBUG
import SwiftUI

struct WPPhase6aShowcase: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp6aShowcase"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var window: UIWindow?

    var body: some View {
        Color.clear.allowsHitTesting(false).onAppear {
            guard Self.window == nil,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.overrideUserInterfaceStyle = ProcessInfo.processInfo.arguments.contains("-wpDark") ? .dark : .light
            window.rootViewController = UIHostingController(rootView: WPPhase6aShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

/// A deleter that never runs (the confirmation screen is only drawn, never confirmed).
private final class WPShowcaseDeleter: AccountDeleting {
    func deleteAccount() async throws {}
}

private struct WPPhase6aShowcaseContent: View {
    let name: String

    @State private var muted = false
    @State private var offsets = ReminderOffsets.default
    @State private var signDetails = false
    @State private var voice = DrivingVoice()
    @State private var regulars = RegularsService()

    var body: some View {
        switch name {
        case "story1", "story2", "story3":
            WPOnboardingStoryV2(onFinish: {}, startIndex: Int(name.dropFirst(5)).map { $0 - 1 } ?? 0)
        case "location":
            WPLocationPrimingV2(onAllow: {}, onNotNow: {})
        case "more":
            WPMoreSheetV2(
                rows: moreMenuVisibleRows(
                    communityEnabled: true, onboardingReplayAvailable: true, hasParkedCar: true,
                    fullPaletteMode: false, spotPassEnabled: true, planTripEnabled: true
                ),
                signDetailsOn: signDetails, onSelect: { _ in },
                onToggleSignDetails: { signDetails.toggle() }, onDone: {}
            )
        case "settings":
            WPSettingsV2(
                notificationsMuted: $muted, offsets: $offsets, drivingVoice: voice, regularsService: regulars,
                onUnmute: {}, onOffsetsChange: {}, appVersion: "1.0", buildNumber: "42"
            )
        case "reminders", "reminders-off":
            WPReminderSettingsV2(
                notificationsMuted: name == "reminders-off" ? .constant(true) : $muted,
                offsets: $offsets, onUnmute: {}, onBack: {}
            )
        case "colors":
            WPColorsMeanV2()
        case "help":
            NavigationStack { WPHelpV2(onBack: {}, onOpenTopic: { _ in }).toolbar(.hidden, for: .navigationBar) }
        case "help-topic":
            WPHelpTopicV2(topicID: "disagree", onBack: {})
        case "about":
            WPAboutV2(version: "1.0 (42)", onBack: {}, onSources: {})
        case "sources":
            WPRulesSourcesV2(onBack: {})
        case "delete":
            DeleteAccountConfirmView(model: AccountDeletionModel(deleter: WPShowcaseDeleter()), onFinished: {})
        case "suggest":
            SuggestNeighborhoodSheet(viewedLatitude: nil, viewedLongitude: nil)
        default:
            Text("Unknown wp6aShowcase: \(name)")
        }
    }
}
#endif
