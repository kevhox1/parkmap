//
//  ClipArmedView.swift
//  WePark Clip
//
//  The armed state of the first screen (design 3.4 "You're on") plus the earned "Show me this
//  block" reveal (design 3.5). "Not leaving after all" is ALWAYS visible (spec 9 items 3, 12, 15).
//

import SwiftUI

struct ClipArmedView: View {
    @Bindable var controller: ClipFlowController
    let block: ClipBlockController

    @Environment(\.clipIsShortScreen) private var isShort
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stamped = false

    private var bothOff: Bool { controller.reminderAvailability == .off && !controller.activityStarted }

    var body: some View {
        ScrollView {
            VStack(spacing: isShort ? 14 : 20) {
                HStack { ClipWordmark(); Spacer() }.frame(minHeight: 44)
                ClipGlyphDisc(
                    glyph: controller.glyph, alias: controller.alias,
                    size: typeSize.isAccessibilitySize ? 72 : (isShort ? 64 : 96), showsSeal: true
                )
                .scaleEffect(stamped || reduceMotion ? 1 : 1.08)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.spring(duration: 0.4)) { stamped = true }
                }
                if controller.showsOtherPassNote {
                    Text(ClipCopy.oneNeighborNote)
                        .font(.footnote).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                headlineBlock
                lockScreenCard
                if bothOff || timeToGo {
                    Button(ClipCopy.pullingOut) { controller.showPullingOut() }
                        .buttonStyle(ClipHeroButtonStyle())
                } else {
                    Button(ClipCopy.pullingOut) { controller.showPullingOut() }
                        .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                        .accessibilityHint("Tells \(controller.displayName ?? "your neighbor") you are leaving. Only tap right before you go.")
                }
                if ClipFeatureFlags.showBlockEnabled { ClipBlockCard(block: block) }
                SpotPassTextButton(
                    title: ClipCopy.notLeavingAfterAll,
                    minHeight: 56,
                    accessibilityHint: "Cancels your pass. \(controller.displayName ?? "Your neighbor") will not be told."
                ) { controller.requestCancel() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Re-evaluated every second while foregrounded; at `leave_at` the screen flips to "Time to go?".
    @State private var timeToGo = false

    private var headlineBlock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let past = controller.pass.map { ClipArmedPresentation.isTimeToGo(leaveAt: $0.leaveAt, now: context.date) } ?? false
            VStack(spacing: isShort ? 14 : 20) {
                Text(past ? ClipCopy.timeToGo : ClipCopy.armedHeadline)
                    .font(.clipHeadline).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(past ? ClipCopy.pullingOutSafety : subline)
                    .font(.title3).foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: past, initial: true) { _, newValue in timeToGo = newValue }
        }
    }

    private var subline: String {
        guard let pass = controller.pass else { return "" }
        let reminder = controller.reminderAvailability == .on ? ClipCopy.clockTime(pass.leaveAt) : nil
        return ClipCopy.armedSub(name: pass.name, reminderTime: reminder)
    }

    private var lockScreenCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bothOff {
                Text(ClipCopy.bothOff).font(.body).foregroundStyle(.white)
            } else {
                Text(ClipCopy.lockScreenTitle).font(.headline).foregroundStyle(.white)
                if let pass = controller.pass, controller.activityStarted {
                    HStack(spacing: 12) {
                        Text(timerInterval: controller.now...max(pass.leaveAt, controller.now.addingTimeInterval(1)), countsDown: true)
                            .font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                        Text(ClipCopy.activityLeavingNow)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .background(SpotPassTheme.indigo, in: Capsule())
                    }
                    .accessibilityHidden(true)
                    Text(ClipCopy.lockScreenBody).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
                    Text(ClipCopy.tapWhenOut).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                } else {
                    Text(ClipCopy.activitiesOff).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
                }
                if controller.reminderAvailability == .off {
                    Text(ClipCopy.remindersOff).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Block card

struct ClipBlockCard: View {
    let block: ClipBlockController
    @Environment(\.clipIsShortScreen) private var isShort

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch block.state {
            case .idle:
                teaser
            case .locating, .loading:
                HStack(spacing: 10) { ProgressView().tint(.white); Text(ClipCopy.blockTitle).foregroundStyle(.white) }
                    .frame(minHeight: 64)
                    .accessibilityLabel("Looking up this block")
            case .result(let result, let index):
                resultCard(result, index: index)
            case .noRule:
                note(ClipCopy.blockNoRule, symbol: "questionmark.circle")
            case .denied:
                note(ClipCopy.blockDenied, symbol: nil)
            case .failed:
                note(ClipCopy.blockFailed, symbol: nil)
                SpotPassTextButton(title: ClipCopy.tryAgain) { Task { await block.show() } }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: block.state)
    }

    private var teaser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ClipCopy.blockTeaserTitle).font(.headline).foregroundStyle(.white)
            Text(ClipCopy.blockTeaserSub).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
            Button(ClipCopy.blockShowMe) { Task { await block.show() } }
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: SpotPassTheme.buttonHeight)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white, lineWidth: 1.5))
                .contentShape(Rectangle())
                .accessibilityLabel("Show me this block")
                .accessibilityHint("Uses your location once to look up street cleaning.")
            Text(ClipCopy.blockFootnote).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
        }
    }

    private func note(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.gray) }
            Text(text).font(.subheadline).foregroundStyle(.white)
        }
    }

    private func resultCard(_ result: ClipBlockResult, index: Int) -> some View {
        let side = result.sides[min(index, result.sides.count - 1)]
        let now = Date()
        return VStack(alignment: .leading, spacing: 8) {
            Text(ClipCopy.blockTitle).font(.title3.bold()).foregroundStyle(.white)
            if let window = side.window {
                if window.isInEffect(at: now) {
                    Label(ClipCopy.blockHappeningNow, systemImage: "exclamationmark.octagon.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(10)
                        .background(ParkingColors.restricted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(ClipCopy.blockSideLine).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
                Text(ClipBlockFormat.windowLine(window)).font(.title2.bold()).foregroundStyle(.white)
                Text(ClipBlockFormat.nextLine(window)).font(.subheadline).foregroundStyle(SpotPassTheme.lavender)
            } else {
                note(ClipCopy.blockNoRule, symbol: "questionmark.circle")
            }
            Text(ClipCopy.blockNearestCurb).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
            if result.sides.count > 1 {
                SpotPassTextButton(title: ClipCopy.blockWrongSide) { block.switchSide() }
            }
            Divider().overlay(.white.opacity(0.2))
            Text(ClipCopy.blockCheckSigns).font(.footnote).foregroundStyle(.white)
            Text(ClipCopy.blockForwardLink).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ClipBlockFormat.accessibilitySummary(side.window, now: now))
    }
}

/// Sub-flags for clip features (kill switch for the hosted-tile dependency).
enum ClipFeatureFlags {
    /// "Show me this block" (hosted single-tile fetch + minimal evaluator).
    static let showBlockEnabled = true
}
