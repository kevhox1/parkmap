//
//  WPPhase5aShowcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp5aShowcase <name>`
//  ContentView mounts the REAL Stoop Spot Pass leaf views (`WPSeekerIntroV2`, `WPSeekerBadgeV2`,
//  `WPDriverChoosingV2`, ...) over fixture values in their own window, so screenshots are
//  repeatable without a Supabase session or a scanned pass:
//
//    intro intro-name failed qr armed departed settled nolack ended paused
//    choose choose-custom pick driver-armed driver-armed-auto pull sent done done-pending message offline
//
//  `-wpLight` forces light (default dark window style matches the flag-off app). Nothing here runs
//  in a Release build or without the launch argument.
//

#if DEBUG
import SwiftUI

struct WPPhase5aShowcase: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp5aShowcase"), i + 1 < args.count else { return nil }
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
            window.rootViewController = UIHostingController(rootView: WPPhase5aShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

private struct WPPhase5aShowcaseContent: View {
    let name: String

    @State private var showFirstName = false
    @State private var choice: LeaveChoice = .default
    @State private var autoOn = false

    private let glyph = "cat.fill"
    private let token = "AAAAAAAAAAAAAAAAAAAAAA"

    private func badge(armed: Bool) -> WPBadgeModel {
        let now = Date()
        return WPBadgeModel(
            token: token, shownName: "Bodega Cat", glyphSymbol: glyph, tintIndex: 0,
            karmaLabel: "Helped 10+", isArmed: armed,
            createdAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(19 * 60 + 44),
            armedLine: { _ in "Leaving in about 10 min" }
        )
    }

    private func slots() -> [Date] { WPPassLogic.leaveSlots(from: Date()) }

    var body: some View {
        switch name {
        case "intro", "intro-name":
            WPSeekerIntroV2(firstName: name == "intro-name" ? "Sam" : nil, showFirstName: $showFirstName, onCreate: {}, onClose: {})
        case "failed":
            WPSeekerMessageV2(
                title: SpotPassCopy.offline,
                primary: (title: SpotPassCopy.tryAgain, action: {}),
                secondary: (title: SpotPassCopy.done, action: {}), onClose: {}
            )
        case "qr", "armed":
            WPSeekerBadgeV2(
                model: badge(armed: name == "armed"), night: false, showsBrightness: name == "qr",
                notificationsDenied: false, showsNightTip: false, pinsStop: true, shareURL: nil,
                onDone: {}, onToggleNight: {}, onStop: {}
            )
        case "departed":
            WPSeekerDepartedV2(glyphSymbol: glyph, tintIndex: 0, isSubmitting: false, submitFailed: false, onGotIt: {}, onDidntWorkOut: {})
        case "settled":
            WPSeekerSettledV2(gotSpot: true, karmaReceipt: SpotPassCopy.karmaReceipt(3), onKeepLooking: {}, onDone: {})
        case "nolack":
            WPSeekerSettledV2(gotSpot: false, karmaReceipt: SpotPassCopy.noLuckKarmaReceipt(1), onKeepLooking: {}, onDone: {})
        case "ended", "paused":
            WPSeekerEndedV2(isPaused: name == "paused", onMakeNew: {}, onDone: {})
        case "choose", "choose-custom":
            WPDriverChoosingV2(
                name: "Bodega Cat", glyphSymbol: glyph, tintIndex: 0,
                choice: name == "choose-custom" ? .custom(Date().addingTimeInterval(45 * 60)) : choice,
                isArming: false, armFailureMessage: nil, willAskForNotifications: true,
                ctaTitle: ClipCopy.cta(choice: choice, name: "Bodega Cat"),
                onSelect: { choice = $0 }, onArm: {}, onNotLeaving: {}, onReport: {}, onClose: {}
            )
        case "pick":
            WPLeaveTimeSheetV2(slots: slots(), selected: slots().dropFirst(2).first, onUse: { _ in })
        case "driver-armed", "driver-armed-auto":
            WPDriverArmedV2(
                name: "Bodega Cat",
                subline: ClipCopy.armedSub(name: "Bodega Cat", reminderTime: "4:35 PM"),
                showsOtherPassNote: false, bothOff: false, activityStarted: true, remindersOff: false,
                onPullingOut: {}, onNotLeaving: {}, onCarGuide: {}, onReport: {}, onClose: {},
                autoRow: {
                    WPListCard {
                        WPListToggleRow(
                            title: WPPassCopy.autoRowTitle,
                            subtitle: autoOn || name == "driver-armed-auto"
                                ? DriverCopy.autoDetectOnSub(name: "Bodega Cat") : DriverCopy.autoDetectOfferSub,
                            isOn: name == "driver-armed-auto" ? .constant(true) : $autoOn
                        )
                    }
                }
            )
        case "pull", "sent":
            WPDriverPullingOutV2(
                name: "Bodega Cat", leaveAt: Date().addingTimeInterval(4 * 60 + 12),
                isSending: false, isSent: name == "sent", sendFailed: false, canExtend: true,
                onBack: {}, onLeavingNow: {}, onFiveMore: {}, onNotLeaving: {}
            )
        case "done", "done-pending":
            WPDriverCelebrationV2(
                thanked: name == "done", name: "Bodega Cat",
                karmaLabel: name == "done" ? ClipCopy.karmaSettled : ClipCopy.karmaPending, onDone: {}
            )
        case "message", "offline":
            WPDriverMessageV2(
                title: name == "offline" ? ClipCopy.offlineTitle : ClipCopy.unavailableTitle,
                body_: name == "offline" ? ClipCopy.offlineBody : ClipCopy.unavailableBody,
                retry: name == "offline", onRetry: {}, onDone: {}
            )
        default:
            Text("Unknown wp5aShowcase: \(name)")
        }
    }
}
#endif
