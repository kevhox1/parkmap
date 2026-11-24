//
//  ClipLiveActivitiesBundle.swift
//  Clip Live Activities widget extension (Live-Activities-only, as Apple requires for App Clips).
//
//  Spot Pass C3: the clip driver's lock-screen countdown (spec 7.2, design 5.1, 5.1b, 5.1c, 5.2,
//  5.3). The clip variant: buttons are `Link`s (App Intents are inert in clips, spec 4), each
//  labelled with a chevron to signal "opens WePark". The whole activity also has a `widgetURL` to the
//  pulling-out screen so a tap anywhere is a fast path. "Not leaving" opens the confirm; opening alone
//  never cancels.
//
//  A Live Activity cannot self-update, so the "Time to go?" layout is driven by `context.isStale`
//  (the app sets staleDate = leaveAt) as well as by the explicit `.timeToGo` phase.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ClipLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        SpotPassClipLiveActivity()
    }
}

struct SpotPassClipLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpotPassActivityAttributes.self) { context in
            ClipLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(SpotPassTheme.ink)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(ClipDeepAction.openPullingOut.url)
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
                        timer(until: leaveAt).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(centerLine(context.state, stale: context.isStale)).font(.footnote)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .counting || context.state.phase == .timeToGo {
                        ClipLinkButton(title: ClipCopy.activityLeavingNow, action: leavingAction(context.state, stale: context.isStale), height: 52)
                    }
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
            .widgetURL(ClipDeepAction.openPullingOut.url)
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

    private func leavingAction(_ state: SpotPassActivityAttributes.ContentState, stale: Bool) -> ClipDeepAction {
        // Counting down: open the pulling-out screen (2 taps). Time to go: perform on open (design 5.2).
        (state.phase == .timeToGo || stale) ? .leavingNow(.liveActivity) : .openPullingOut
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

// MARK: - Link button

/// A `Link` styled as a button: 56 pt, indigo fill, chevron = "opens WePark" (design 5.2).
struct ClipLinkButton: View {
    let title: String
    let action: ClipDeepAction
    var height: CGFloat = 56
    var fill: Color = SpotPassTheme.indigo

    var body: some View {
        Link(destination: action.url) {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.bold))
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(title)
        .accessibilityHint("Opens WePark")
    }
}

// MARK: - Lock screen

struct ClipLockScreenView: View {
    let attributes: SpotPassActivityAttributes
    let state: SpotPassActivityAttributes.ContentState
    let isStale: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    private var showsTimeToGo: Bool { state.phase == .timeToGo || (state.phase == .counting && isStale) }
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

    // Counting down (design 5.1, clip variant 5.2)
    private var counting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !isAX {
                    AliasGlyphDisc(
                        symbolName: SpotPassGlyph.symbolName(for: attributes.glyph),
                        tintIndex: SpotPassGlyph.tintIndex(forAlias: attributes.alias), size: 44
                    )
                    Text(ClipCopy.activityCaption(name: attributes.alias))
                        .font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Link(destination: ClipDeepAction.confirmCancel.url) {
                    Text(ClipCopy.notLeaving).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
                        .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
                }
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
            ClipLinkButton(title: ClipCopy.activityLeavingNow, action: .openPullingOut, height: isAX ? 64 : 56)
        }
    }

    // Time to go (design 5.1b, clip variant: both buttons deep-link and perform on open)
    private var timeToGo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClipCopy.timeToGo).font(.system(.title3, design: .rounded).weight(.bold))
                    Text(ClipCopy.reminderBody(name: attributes.alias)).font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 8)
                Link(destination: ClipDeepAction.confirmCancel.url) {
                    Text(ClipCopy.notLeaving).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
                        .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
                }
            }
            let layout = isAX ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ClipLinkButton(title: ClipCopy.activityLeavingNow, action: .leavingNow(.liveActivity))
                ClipLinkButton(title: ClipCopy.actionFiveMore, action: .extend, fill: Color.white.opacity(0.22))
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
