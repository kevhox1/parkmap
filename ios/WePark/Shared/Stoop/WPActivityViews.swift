//
//  WPActivityViews.swift
//  Shared/Stoop
//
//  Stoop Phase 5b (round-2 B12): the Live Activity lock screen and Dynamic Island in the Stoop
//  design system. Compiled into every target; the full-app and clip Live Activity extensions mount
//  these ONLY when `StoopFlag.designSystemV2Enabled` is true (compile-time, shared), and the DEBUG
//  showcase renders them with fixtures.
//
//  Buttons are injected: the full-app extension wraps each in `Button(intent:)` (LeavingNowIntent,
//  FiveMoreMinutesIntent, NotLeavingIntent: a true one-tap on a locked phone, unchanged), the clip
//  extension wraps each in a `Link` (App Intents are inert in clips), the showcase leaves them plain.
//
//  Surfaces are black like the mock; Fredoka comes from each extension's UIAppFonts.
//

import ActivityKit
import SwiftUI
import WidgetKit

enum WPActivityAction { case leavingNow, fiveMore, notLeaving }

typealias WPActivityState = SpotPassActivityAttributes.ContentState

// MARK: - Parts

/// The car token: a taxi disc (waiting), a park-green disc (heads-up sent), or a dashed ring (ended).
struct WPActivityToken: View {
    enum Tone { case taxi, park, dashed }
    var tone: Tone = .taxi
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            switch tone {
            case .taxi: Circle().fill(WP.taxi)
            case .park: Circle().fill(WP.park)
            case .dashed:
                Circle().strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            if tone != .dashed {
                Image(systemName: "car.fill")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.ink)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The pill label. `.taxi` = the one primary action (ink label); `.dark` = secondary (white label).
struct WPActivityPill: View {
    enum Style { case taxi, dark }
    let title: String
    var style: Style = .taxi
    var height: CGFloat = 56
    var fillsWidth = false

    var body: some View {
        Text(title)
            .font(WP.Font.fredoka(18, .bold, relativeTo: .headline))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(style == .taxi ? WP.ink : Color.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height)
            .background(Capsule().fill(style == .taxi ? WP.taxi : Color(wpHex: WP.Hex.darkSurface)))
            .contentShape(Capsule())
    }
}

/// The quiet secondary "Not leaving": plain text, much smaller than the taxi pill, 44 pt tall target.
struct WPActivityQuietLink: View {
    var title = WPActivityCopy.notLeaving
    var body: some View {
        Text(title)
            .font(WP.Font.fredoka(14, .semibold, relativeTo: .footnote))
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 12)
            .frame(minWidth: 96, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private func wpTimer(until leaveAt: Date, size: CGFloat, color: Color) -> some View {
    Text(timerInterval: Date.now...max(leaveAt, Date.now.addingTimeInterval(1)), countsDown: true)
        .font(WP.Font.fredoka(size, .bold, relativeTo: .title))
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1).minimumScaleFactor(0.6)
        .accessibilityLabel("Time until you leave")
}

// MARK: - Lock screen

struct WPActivityLockView<Wrapper: View>: View {
    let attributes: SpotPassActivityAttributes
    let state: WPActivityState
    let isStale: Bool
    @ViewBuilder var wrap: (WPActivityAction, AnyView) -> Wrapper

    @Environment(\.dynamicTypeSize) private var typeSize

    private var name: String { attributes.alias }
    private var isAX: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            switch WPActivityCopy.layout(phase: state.phase, isStale: isStale) {
            case .counting: counting
            case .timeToGo: timeToGo
            case .sent: line(token: .park, title: WPActivityCopy.headsUpSent, sub: WPActivityCopy.knowsPullingOut(name: name))
            case .passed: line(token: .taxi, title: WPActivityCopy.passedTitle, sub: WPActivityCopy.karmaLands)
            case .thanks: line(token: .taxi, title: WPActivityCopy.thanksTitle, sub: WPActivityCopy.from(name: name), chip: WPActivityCopy.karmaChip)
            case .cancelled: line(token: .dashed, title: WPActivityCopy.cancelledTitle, sub: WPActivityCopy.cancelledSub)
            case .ended: line(token: .dashed, title: WPActivityCopy.endedTitle, sub: WPActivityCopy.stoppedWaiting(name: name))
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)   // 160 pt is a hard OS limit
    }

    private func pill(_ action: WPActivityAction, _ title: String, style: WPActivityPill.Style, fills: Bool = false) -> some View {
        wrap(action, AnyView(WPActivityPill(title: title, style: style, fillsWidth: fills)))
    }

    private var counting: some View {
        let layout = isAX ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .trailing, spacing: 0) {
            layout {
                HStack(spacing: 12) {
                    WPActivityToken()
                    VStack(alignment: .leading, spacing: 0) {
                        if let leaveAt = state.leaveAt { wpTimer(until: leaveAt, size: 30, color: .white) }
                        Text(WPActivityCopy.isWaiting(name: name))
                            .font(WP.Font.fredoka(14, .regular, relativeTo: .footnote)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                if !isAX { Spacer(minLength: 4) }
                pill(.leavingNow, WPActivityCopy.leavingNow, style: .taxi, fills: isAX)
            }
            // A driver who changes their mind can still cancel from the lock screen (shipping behavior).
            wrap(.notLeaving, AnyView(WPActivityQuietLink()))
        }
    }

    private var timeToGo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                WPActivityToken()
                VStack(alignment: .leading, spacing: 0) {
                    Text(WPActivityCopy.stillLeaving).font(WP.Font.fredoka(26, .bold, relativeTo: .title2))
                    Text(WPActivityCopy.isWaiting(name: name)).font(WP.Font.fredoka(14, .regular, relativeTo: .footnote))
                }
            }
            pill(.leavingNow, WPActivityCopy.leavingNow, style: .taxi, fills: true)
            let layout = isAX ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                pill(.fiveMore, WPActivityCopy.fiveMore, style: .dark, fills: true)
                pill(.notLeaving, WPActivityCopy.notLeaving, style: .dark, fills: true)
            }
        }
    }

    private func line(token: WPActivityToken.Tone, title: String, sub: String, chip: String? = nil) -> some View {
        HStack(spacing: 12) {
            WPActivityToken(tone: token)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(WP.Font.fredoka(24, .bold, relativeTo: .title3)).lineLimit(2).minimumScaleFactor(0.8)
                Text(sub).font(WP.Font.fredoka(14, .regular, relativeTo: .footnote)).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let chip {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").foregroundStyle(WP.noParkText)
                    Text(chip).font(WP.Font.fredoka(16, .bold, relativeTo: .headline)).foregroundStyle(WP.ink)
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(Capsule().fill(WP.taxi))
                .rotationEffect(.degrees(-6))
                .accessibilityLabel("Plus 5 karma")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dynamic Island

/// Compact: token left, countdown right (taxi). Minimal: the token. Expanded (long press): token,
/// "<name> is waiting", "Leaving around 4:45 PM", countdown, Leaving now.
func wpDynamicIsland<Wrapper: View>(
    context: ActivityViewContext<SpotPassActivityAttributes>,
    @ViewBuilder wrap: @escaping (WPActivityAction, AnyView) -> Wrapper
) -> DynamicIsland {
    let state = context.state
    let layout = WPActivityCopy.layout(phase: state.phase, isStale: context.isStale)
    let name = context.attributes.alias
    let counting = layout == .counting
    return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { WPActivityToken(tone: wpTone(layout), size: 44) }
        DynamicIslandExpandedRegion(.center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(wpIslandTitle(layout, name: name)).font(WP.Font.fredoka(17, .bold, relativeTo: .headline)).lineLimit(1)
                Text(wpIslandSub(layout, state: state, name: name)).font(WP.Font.fredoka(13, .regular, relativeTo: .footnote)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.trailing) {
            if counting, let leaveAt = state.leaveAt { wpTimer(until: leaveAt, size: 26, color: WP.taxi) }
        }
        DynamicIslandExpandedRegion(.bottom) {
            if counting {
                // Side by side, not stacked: measured on a simulator, the expanded island (84-160 pt tall
                // per the HIG) clipped a 52 pt pill + 44 pt link stack and dropped "Not leaving".
                HStack(spacing: 4) {
                    wrap(.leavingNow, AnyView(WPActivityPill(title: WPActivityCopy.leavingNow, height: 52, fillsWidth: true)))
                    wrap(.notLeaving, AnyView(WPActivityQuietLink()))
                }
            } else if layout == .timeToGo {
                VStack(spacing: 6) {
                    wrap(.leavingNow, AnyView(WPActivityPill(title: WPActivityCopy.leavingNow, height: 52, fillsWidth: true)))
                    HStack(spacing: 6) {
                        wrap(.fiveMore, AnyView(WPActivityPill(title: WPActivityCopy.fiveMore, style: .dark, height: 44, fillsWidth: true)))
                        wrap(.notLeaving, AnyView(WPActivityPill(title: WPActivityCopy.notLeaving, style: .dark, height: 44, fillsWidth: true)))
                    }
                }
            }
        }
    } compactLeading: {
        WPActivityToken(tone: wpTone(layout), size: 24)
    } compactTrailing: {
        if counting, let leaveAt = state.leaveAt {
            wpTimer(until: leaveAt, size: 14, color: WP.taxi).frame(maxWidth: 52)
        }
    } minimal: {
        WPActivityToken(tone: wpTone(layout), size: 24)
    }
    .keylineTint(WP.taxi)
}

private func wpTone(_ layout: WPActivityCopy.Layout) -> WPActivityToken.Tone {
    switch layout {
    case .sent: return .park
    case .cancelled, .ended: return .dashed
    default: return .taxi
    }
}

private func wpIslandTitle(_ layout: WPActivityCopy.Layout, name: String) -> String {
    switch layout {
    case .counting: return WPActivityCopy.isWaiting(name: name)
    case .timeToGo: return WPActivityCopy.stillLeaving
    case .sent: return WPActivityCopy.headsUpSent
    case .passed: return WPActivityCopy.passedTitle
    case .thanks: return WPActivityCopy.thanksTitle
    case .cancelled: return WPActivityCopy.cancelledTitle
    case .ended: return WPActivityCopy.endedTitle
    }
}

private func wpIslandSub(_ layout: WPActivityCopy.Layout, state: WPActivityState, name: String) -> String {
    switch layout {
    case .counting: return state.leaveAt.map { WPActivityCopy.leavingAround(ClipCopy.clockTime($0)) } ?? ""
    case .timeToGo: return WPActivityCopy.isWaiting(name: name)
    case .sent: return WPActivityCopy.knowsPullingOut(name: name)
    case .passed: return WPActivityCopy.karmaLands
    case .thanks: return WPActivityCopy.from(name: name)
    case .cancelled: return WPActivityCopy.cancelledSub
    case .ended: return WPActivityCopy.stoppedWaiting(name: name)
    }
}
