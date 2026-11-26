//
//  WPPhase5bActivityShowcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp5bActivity <name>`
//  ContentView mounts the REAL Stoop Live Activity views (`Shared/Stoop/WPActivityViews`) in their
//  own window over a lock-screen-like backdrop, with fixture state:
//
//    counting timetogo sent passed thanks ended cancelled island
//
//  `island` lays out the compact / minimal / expanded islands from the same token, pill and timer
//  parts (the system `DynamicIsland` type cannot be hosted in an ordinary view, so this is the
//  layout approximation; the real one is `wpDynamicIsland`). `-wpLight` only changes the backdrop.
//

#if DEBUG
import ActivityKit
import SwiftUI

struct WPPhase5bActivityShowcase: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp5bActivity"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var window: UIWindow?

    /// `-wp5bActivity real`: starts a REAL counting Live Activity (the system renders the lock screen and
    /// the Dynamic Island with `wpDynamicIsland`), so expanded-island height can be measured on a
    /// simulator instead of approximated. Only the flag-on build draws the Stoop layout.
    private static func startRealActivity(_ phase: SpotPassActivityAttributes.Phase = .counting) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = SpotPassActivityAttributes(alias: "Bodega Cat", glyph: "bodega_cat", isClip: false)
        let leaveAt = phase == .counting ? Date.now.addingTimeInterval(12 * 60 + 48) : Date.now.addingTimeInterval(-30)
        let state = WPActivityState(phase: phase, leaveAt: leaveAt, startedAt: Date.now, passID: UUID().uuidString.lowercased())
        // End any activity a previous launch left running, so each launch shows exactly the asked state.
        Task {
            for old in Activity<SpotPassActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
            _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        }
    }

    var body: some View {
        Color.clear.allowsHitTesting(false).onAppear {
            // `real` = counting; `real-timetogo|sent|passed|thanks|cancelled|ended` = that state.
            if name.hasPrefix("real") {
                let raw = name.dropFirst("real-".count)
                let phases: [String: SpotPassActivityAttributes.Phase] = [
                    "timetogo": .timeToGo, "sent": .sent, "passed": .passed,
                    "thanks": .thanks, "cancelled": .cancelled, "ended": .ended]
                Self.startRealActivity(phases[String(raw)] ?? .counting)
                return
            }
            guard Self.window == nil,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.overrideUserInterfaceStyle = ProcessInfo.processInfo.arguments.contains("-wpLight") ? .light : .dark
            window.rootViewController = UIHostingController(rootView: WPPhase5bActivityShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

private struct WPPhase5bActivityShowcaseContent: View {
    let name: String

    private let attributes = SpotPassActivityAttributes(alias: "Bodega Cat", glyph: "bodega_cat", isClip: false)

    private func state(_ phase: SpotPassActivityAttributes.Phase) -> WPActivityState {
        WPActivityState(phase: phase, leaveAt: Date.now.addingTimeInterval(12 * 60 + 48), startedAt: Date.now)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.17).ignoresSafeArea()
            VStack {
                Text("Wednesday, November 25").font(.headline).foregroundStyle(.white).padding(.top, 90)
                Text("4:32").font(.system(size: 96, weight: .semibold)).foregroundStyle(.white)
                Spacer()
            }
            if name == "island" {
                island
            } else {
                card.padding(.horizontal, 12).padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder private var card: some View {
        let phase: SpotPassActivityAttributes.Phase = {
            switch name {
            case "timetogo": return .timeToGo
            case "sent": return .sent
            case "passed": return .passed
            case "thanks": return .thanks
            case "ended": return .ended
            case "cancelled": return .cancelled
            default: return .counting
            }
        }()
        WPActivityLockView(attributes: attributes, state: state(phase), isStale: false) { _, label in label }
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
    }

    private var island: some View {
        VStack(spacing: 18) {
            HStack {
                WPActivityToken(size: 24)
                Spacer()
                Text("12:48").font(WP.Font.fredoka(14, .bold, relativeTo: .caption)).monospacedDigit().foregroundStyle(WP.taxi)
            }
            .padding(.horizontal, 12).frame(width: 240, height: 38)
            .background(Capsule().fill(Color.black))
            HStack(spacing: 12) {
                WPActivityToken(size: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text(WPActivityCopy.isWaiting(name: "Bodega Cat")).font(WP.Font.fredoka(17, .bold, relativeTo: .headline))
                    Text(WPActivityCopy.leavingAround("4:45 PM")).font(WP.Font.fredoka(13, .regular, relativeTo: .footnote))
                }
                Spacer()
                Text("12:48").font(WP.Font.fredoka(26, .bold, relativeTo: .title2)).monospacedDigit().foregroundStyle(WP.taxi)
            }
            .overlay(alignment: .bottom) {
                WPActivityPill(title: WPActivityCopy.leavingNow, height: 52, fillsWidth: true).offset(y: 66)
            }
            .padding(.bottom, 66)
            .foregroundStyle(.white)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Color.black))
            .padding(.horizontal, 12)
            WPActivityToken(size: 28).padding(8).background(Circle().fill(Color.black))
        }
        .padding(.bottom, 200)
    }
}
#endif
