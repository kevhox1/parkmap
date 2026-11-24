//
//  ClipPullingOutView.swift
//  WePark Clip
//
//  The pulling-out screen (design 3.6): the target of the Live Activity link, the reminder, and
//  the "Now" chip. One huge decision, a calm safety line, and two secondary buttons.
//

import SwiftUI

struct ClipPullingOutView: View {
    @Bindable var controller: ClipFlowController

    @Environment(\.clipIsShortScreen) private var isShort
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isSending: Bool { controller.phase == .sending }
    private var isSent: Bool { controller.phase == .sent }

    var body: some View {
        ScrollView {
            VStack(spacing: isShort ? 14 : 22) {
                HStack {
                    if controller.phase == .pullingOut {
                        Button { controller.backToArmed() } label: {
                            Label("Back", systemImage: "chevron.left")
                                .foregroundStyle(.white)
                                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: 44)
                header
                HStack(spacing: 12) {
                    ClipGlyphDisc(glyph: controller.glyph, alias: controller.alias, size: typeSize.isAccessibilitySize ? 48 : 72)
                    Text(ClipCopy.activityCaption(name: controller.displayName ?? "A neighbor"))
                        .font(.title3).foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)

                if isSent {
                    sentSeal
                } else {
                    Button { Task { await controller.pullOut() } } label: {
                        if isSending { ProgressView().tint(SpotPassTheme.ink) } else { Text(ClipCopy.pullingOut).font(.title.bold()) }
                    }
                    .buttonStyle(ClipHeroButtonStyle(minHeight: typeSize.isAccessibilitySize ? 120 : (isShort ? 96 : 120)))
                    .disabled(isSending)
                    .accessibilityLabel(ClipCopy.pullingOut)
                    .accessibilityHint("Tells \(controller.displayName ?? "your neighbor") you are leaving. Only tap right before you go.")
                }
                if controller.sendFailed {
                    Text(ClipCopy.sendFailed).font(.headline).foregroundStyle(.white)
                }
                Text(ClipCopy.pullingOutSafety)
                    .font(.footnote).foregroundStyle(SpotPassTheme.lavender).multilineTextAlignment(.center)
                if !isSent {
                    secondaryButtons
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// "Leaving in 4:12" or "Time to go?" at / after leave_at.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let leaveAt = controller.pass?.leaveAt, leaveAt > context.date.addingTimeInterval(1) {
                    VStack(spacing: 4) {
                        Text("Leaving in").font(.headline).foregroundStyle(SpotPassTheme.lavender)
                        Text(timerInterval: context.date...leaveAt, countsDown: true)
                            .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Time until you leave")
                } else {
                    Text(ClipCopy.timeToGo)
                        .font(.clipHeadline).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var sentSeal: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64)).foregroundStyle(.white, SpotPassTheme.indigo)
                .accessibilityHidden(true)
            Text(ClipCopy.sentLine(name: controller.displayName ?? "Your neighbor"))
                .font(.title2.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var secondaryButtons: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button(ClipCopy.fiveMore) { Task { await controller.extendFiveMinutes() } }
                .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                .disabled((controller.pass?.extensions ?? 0) >= HandoffActivePass.maxExtensions || isSending)
                .accessibilityLabel("Five more minutes")
            Button(ClipCopy.notLeaving) { controller.requestCancel() }
                .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                .disabled(isSending)
                .accessibilityHint("Cancels your pass. \(controller.displayName ?? "Your neighbor") will not be told.")
        }
    }
}
