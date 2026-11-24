//
//  WeParkLiveActivitiesBundle.swift
//  Full-app Live Activities widget extension.
//
//  Spot Pass C2 (spec 7.2, design 5.1, 5.1b, 5.1c, 5.3): the driver's lock-screen countdown with a
//  TRUE one-tap "Leaving now": `Button(intent: LeavingNowIntent(...))`. The App Intent runs in the app
//  process (`LiveActivityIntent`), so tapping sends the depart without opening the app UI. (The App
//  Clip variant, `ClipLiveActivities`, uses deep links instead: App Intents are inert in clips.)
//
//  A Live Activity cannot self-update, so "Time to go?" is driven by `context.isStale` (the app sets
//  staleDate = leaveAt) as well as the explicit `.timeToGo` phase.
//
//  Never green, orange or red here (those mean curb rules): indigo and lavender on ink.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WeParkLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        SpotPassLiveActivity()
    }
}

struct SpotPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpotPassActivityAttributes.self) { context in
            SpotPassLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(SpotPassTheme.ink)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        glyph(context.attributes, size: 44)
                        Text(context.attributes.alias).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let leaveAt = context.state.leaveAt, context.state.phase == .counting, !context.isStale {
                        timer(until: leaveAt)
                            .font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(centerLine(context.state, stale: context.isStale)).font(.footnote)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context)
                }
            } compactLeading: {
                glyph(context.attributes, size: 28)
            } compactTrailing: {
                if let leaveAt = context.state.leaveAt, context.state.phase == .counting, !context.isStale {
                    timer(until: leaveAt)
                        .font(.system(.caption2, design: .rounded).weight(.semibold)).monospacedDigit()
                        .minimumScaleFactor(0.6).frame(maxWidth: 52)
                }
            } minimal: {
                glyph(context.attributes, size: 28)
            }
            .keylineTint(SpotPassTheme.indigo)
        }
    }

    @ViewBuilder
    private func expandedBottom(_ context: ActivityViewContext<SpotPassActivityAttributes>) -> some View {
        let state = context.state
        if state.phase == .counting || state.phase == .timeToGo {
            let timeToGo = state.phase == .timeToGo || context.isStale
            VStack(spacing: 4) {
                if timeToGo {
                    HStack(spacing: 8) {
                        SpotPassActivityButton(
                            title: ClipCopy.activityLeavingNow, height: 52,
                            intent: LeavingNowIntent(passID: state.passID)
                        )
                        SpotPassActivityButton(
                            title: ClipCopy.actionFiveMore, height: 52, fill: Color.white.opacity(0.22),
                            intent: FiveMoreMinutesIntent(passID: state.passID)
                        )
                    }
                } else {
                    SpotPassActivityButton(
                        title: ClipCopy.activityLeavingNow, height: 52,
                        intent: LeavingNowIntent(passID: state.passID)
                    )
                }
                SpotPassTextIntentButton(title: ClipCopy.notLeaving, intent: NotLeavingIntent(passID: state.passID))
            }
        }
    }

    private func glyph(_ attributes: SpotPassActivityAttributes, size: CGFloat) -> some View {
        AliasGlyphDisc(
            symbolName: SpotPassGlyph.symbolName(for: attributes.glyph),
            tintIndex: SpotPassGlyph.tintIndex(forAlias: attributes.alias),
            size: size
        )
    }

    private func timer(until leaveAt: Date) -> Text {
        Text(timerInterval: Date.now...max(leaveAt, Date.now.addingTimeInterval(1)), countsDown: true)
    }

    private func centerLine(_ state: SpotPassActivityAttributes.ContentState, stale: Bool) -> String {
        switch state.phase {
        case .counting: return stale ? ClipCopy.timeToGo : "is waiting for your spot"
        case .timeToGo: return ClipCopy.timeToGo
        case .sent: return "Sent."
        case .passed: return ClipCopy.activityPassed
        case .thanks: return ClipCopy.thanksHeadline
        case .cancelled: return ClipCopy.cancelledLine
        case .ended: return ClipCopy.activityEnded
        }
    }
}

// MARK: - Intent buttons

/// The big indigo button (56 pt on the lock screen). A real `Button(intent:)`: one tap, no app launch.
struct SpotPassActivityButton<Intent: AppIntent>: View {
    let title: String
    var height: CGFloat = 56
    var fill: Color = SpotPassTheme.indigo
    let intent: Intent

    var body: some View {
        Button(intent: intent) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(title == ClipCopy.activityLeavingNow
            ? "Tells your neighbor you are pulling out. They will see only that you are leaving."
            : "")
    }
}

/// "Not leaving": a text button, 44 pt tall and 96 pt wide, lavender (design 5.1).
struct SpotPassTextIntentButton<Intent: AppIntent>: View {
    let title: String
    let intent: Intent

    var body: some View {
        Button(intent: intent) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(SpotPassTheme.lavender)
                .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Cancels your pass. Your neighbor will not be told.")
    }
}

// MARK: - Lock screen

struct SpotPassLockScreenView: View {
    let attributes: SpotPassActivityAttributes
    let state: SpotPassActivityAttributes.ContentState
    let isStale: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isAX: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            switch state.phase {
            case .counting where !isStale: counting
            case .counting, .timeToGo: timeToGo
            case .sent: oneLine(title: ClipCopy.sentLine(name: attributes.alias), subtitle: nil, seal: true)
            case .passed:
                oneLine(title: ClipCopy.activityPassed, subtitle: ClipCopy.karmaPending + " " + ClipCopy.karmaPendingCaption, seal: true)
            case .thanks:
                oneLine(title: ClipCopy.thanksHeadline, subtitle: ClipCopy.thanksSub(name: attributes.alias), seal: true)
            case .cancelled: oneLine(title: ClipCopy.cancelledLine, subtitle: nil, seal: false)
            case .ended: oneLine(title: ClipCopy.activityEnded, subtitle: nil, seal: false)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)   // 160 pt is a hard OS limit
    }

    // Counting down (design 5.1)
    private var counting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !isAX {
                    AliasGlyphDisc(
                        symbolName: SpotPassGlyph.symbolName(for: attributes.glyph),
                        tintIndex: SpotPassGlyph.tintIndex(forAlias: attributes.alias), size: 44
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ClipCopy.activityCaption(name: attributes.alias))
                            .font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        if state.autoDetect == true {
                            // C4 (design 5.4): visible-by-design while the armed-window auto-detect runs.
                            Label(ClipCopy.autoDetectCaption, systemImage: "location.fill")
                                .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                Spacer(minLength: 8)
                SpotPassTextIntentButton(title: ClipCopy.notLeaving, intent: NotLeavingIntent(passID: state.passID))
            }
            if let leaveAt = state.leaveAt {
                let start = state.startedAt ?? Date.now
                Text(timerInterval: Date.now...max(leaveAt, Date.now.addingTimeInterval(1)), countsDown: true)
                    .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("Time until you leave")
                ProgressView(timerInterval: min(start, leaveAt)...max(leaveAt, start.addingTimeInterval(1)), countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(SpotPassTheme.indigo)
                    .accessibilityHidden(true)
            }
            SpotPassActivityButton(
                title: ClipCopy.activityLeavingNow, height: isAX ? 64 : 56,
                intent: LeavingNowIntent(passID: state.passID)
            )
        }
    }

    // Time to go (design 5.1b)
    private var timeToGo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClipCopy.timeToGo).font(.system(.title3, design: .rounded).weight(.bold))
                    Text(ClipCopy.reminderBody(name: attributes.alias)).font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 8)
                SpotPassTextIntentButton(title: ClipCopy.notLeaving, intent: NotLeavingIntent(passID: state.passID))
            }
            let layout = isAX ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                SpotPassActivityButton(title: ClipCopy.activityLeavingNow, intent: LeavingNowIntent(passID: state.passID))
                SpotPassActivityButton(
                    title: ClipCopy.actionFiveMore, fill: Color.white.opacity(0.22),
                    intent: FiveMoreMinutesIntent(passID: state.passID)
                )
            }
        }
    }

    private func oneLine(title: String, subtitle: String?, seal: Bool) -> some View {
        HStack(spacing: 12) {
            if seal {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 32)).foregroundStyle(.white, SpotPassTheme.indigo)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.headline, design: .rounded))
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}
