//
//  WPPhase5bClipShowcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp5bClip <name>`
//  ContentView mounts the REAL Stoop clip leaf views (`Shared/Stoop/WPClipScreens`) in their own
//  window above everything, over fixture data, so light/dark and Dynamic Type screenshots are
//  repeatable without a live pass:
//
//    intro time reminder armed armed-off timetogo countdown sent thanked passed install message
//
//  `-wpLight` picks the light style (default dark). Nothing here runs without the launch argument.
//

#if DEBUG
import SwiftUI

struct WPPhase5bClipShowcase: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp5bClip"), i + 1 < args.count else { return nil }
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
            window.overrideUserInterfaceStyle = ProcessInfo.processInfo.arguments.contains("-wpLight") ? .light : .dark
            window.rootViewController = UIHostingController(rootView: WPPhase5bClipShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

private struct WPPhase5bClipShowcaseContent: View {
    let name: String

    @State private var choice: LeaveChoice = .minutes(30)
    private let now = Date()
    private var leaveAt: Date { now.addingTimeInterval(90) }
    private var around: Date { now.addingTimeInterval(43 * 60) }

    var body: some View {
        switch name {
        case "time":
            WPClipTimeView(
                name: "Bodega Cat", choice: choice, isArming: false, failure: nil,
                onSelect: { choice = $0 }, onPickTime: {}, onTell: {}, onBack: {}
            )
        case "reminder":
            WPClipReminderView(
                name: "Bodega Cat", around: WPClipClock.bare(around), onAllow: {}, onSkip: {}, onBack: {}
            )
        case "armed", "armed-off", "timetogo":
            WPClipArmedView(
                name: "Bodega Cat", around: ClipCopy.clockTime(around), isTimeToGo: name == "timetogo",
                activityStarted: name != "armed-off", remindersOn: name != "armed-off",
                showsSettingsLink: name == "armed-off", showsOtherPassNote: false,
                onLeavingNow: {}, onNotLeaving: {}, onOpenSettings: {}
            ) { EmptyView() }
        case "countdown":
            WPClipCountdownView(
                name: "Bodega Cat", leaveAt: leaveAt, now: now, mode: .counting, canExtend: true, sendFailed: false,
                onBack: {}, onLeavingNow: {}, onFiveMore: {}, onNotLeaving: {}
            )
        case "sent":
            WPClipCountdownView(
                name: "Bodega Cat", leaveAt: nil, now: now, mode: .sent, canExtend: true, sendFailed: false,
                onBack: nil, onLeavingNow: {}, onFiveMore: {}, onNotLeaving: {}
            )
        case "thanked", "passed":
            WPClipFinishedView(
                name: "Bodega Cat", thanked: name == "thanked", showsInstall: false, showsLockScreenLine: true,
                onDone: {}, onGet: {}
            )
        case "install":
            WPClipFinishedView(
                name: "Bodega Cat", thanked: true, showsInstall: true, showsLockScreenLine: false,
                onDone: {}, onGet: {}
            )
        case "message":
            WPClipMessageView(content: ClipMessageContent.content(for: .unavailable), onRetry: {}, onWhatsWePark: {})
        default:
            WPClipIntroView(
                name: "Bodega Cat", glyph: "bodega_cat", alias: "Bodega Cat", isLoaded: true,
                onLeavingSoon: {}, onNotLeaving: {}, onReport: {}
            )
        }
    }
}
#endif
