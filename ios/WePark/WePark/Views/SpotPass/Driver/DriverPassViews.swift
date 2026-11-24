//
//  DriverPassViews.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C2: the armed screen ("You're on", design 3.4), the pulling-out screen (3.6) and the
//  celebration / thank-you (7.1, 7.2) of the full-app driver flow. "Not leaving after all" is
//  ALWAYS visible while armed (spec 9 items 3, 12, 15).
//

import SwiftUI

// MARK: - Armed

struct DriverArmedView: View {
    @Bindable var controller: DriverFlowController
    var onClose: () -> Void

    @Environment(\.driverIsShortScreen) private var isShort
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stamped = false
    @State private var showAutoPingGuide = false
    @State private var showReport = false

    private var bothOff: Bool { controller.reminderAvailability == .off && !controller.activityStarted }

    var body: some View {
        ScrollView {
            VStack(spacing: isShort ? 14 : 20) {
                HStack {
                    DriverWordmark()
                    Spacer()
                    Button { showReport = true } label: {
                        Image(systemName: "flag")
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Report this pass")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(DriverCopy.closeLabel)
                    .accessibilityHint("Your pass stays on.")
                }
                .frame(minHeight: 44)
                if controller.showsOtherPassNote {
                    Text(ClipCopy.oneNeighborNote)
                        .font(.footnote).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                DriverGlyphDisc(
                    glyph: controller.glyph, alias: controller.alias,
                    size: typeSize.isAccessibilitySize ? 72 : (isShort ? 64 : 96), showsSeal: true
                )
                .scaleEffect(stamped || reduceMotion ? 1 : 1.08)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.spring(duration: 0.4)) { stamped = true }
                }
                Text(ClipCopy.armedHeadline)
                    .font(.driverHeadline).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(subline)
                    .font(.title3).foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
                lockScreenCard
                if bothOff {
                    Button(ClipCopy.pullingOut) { controller.showPullingOut() }
                        .buttonStyle(DriverHeroButtonStyle())
                } else {
                    Button(ClipCopy.pullingOut) { controller.showPullingOut() }
                        .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                        .accessibilityHint("Tells \(controller.displayName ?? "your neighbor") you are leaving. Only tap right before you go.")
                }
                AutoDetectRow(controller: controller)
                autoPingRow
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
        .task {
            // Expires a lapsed pass and (C4) opens the auto-detect window once the leave time is near.
            while !Task.isCancelled {
                await controller.tick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .sheet(isPresented: $showAutoPingGuide) { CarAutoPingGuideView() }
        .confirmationDialog(ClipCopy.reportTitle, isPresented: $showReport, titleVisibility: .visible) {
            ForEach(ClipCopy.reportReasons, id: \.0) { reason, title in
                Button(title) { Task { await controller.report(reason) } }
            }
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
                    Text(DriverCopy.startDrivingNote).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
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

    private var autoPingRow: some View {
        Button { showAutoPingGuide = true } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    // AX sizes: icon and chevron share a top line and the text gets the FULL row width, so the
                    // title wraps only at word boundaries (the narrow beside-the-icon column split "heads-up").
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            autoPingIcon
                            Spacer(minLength: 0)
                            autoPingChevron
                        }
                        autoPingText
                    }
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        autoPingIcon
                        autoPingText
                        Spacer(minLength: 0)
                        autoPingChevron
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var autoPingIcon: some View {
        // `minWidth`, not a fixed width: the glyph grows with Dynamic Type and must never touch the text.
        Image(systemName: "car.fill")
            .foregroundStyle(SpotPassTheme.lavender)
            .frame(minWidth: 32, alignment: .center)
            .accessibilityHidden(true)
    }

    private var autoPingChevron: some View {
        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true)
    }

    private var autoPingText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DriverCopy.autoPingRowTitle)
                .font(.headline).foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                // Shrinks a long word a little before it would ever need to break; wraps at spaces otherwise.
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(DriverCopy.autoPingRowSub)
                .font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pulling out

struct DriverPullingOutView: View {
    @Bindable var controller: DriverFlowController

    @Environment(\.driverIsShortScreen) private var isShort
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
                    DriverGlyphDisc(glyph: controller.glyph, alias: controller.alias, size: typeSize.isAccessibilitySize ? 48 : 72)
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
                    .buttonStyle(DriverHeroButtonStyle(minHeight: typeSize.isAccessibilitySize ? 120 : (isShort ? 96 : 120)))
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
                        .font(.driverHeadline).foregroundStyle(.white)
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

// MARK: - Celebration

struct DriverCelebrationView: View {
    @Bindable var controller: DriverFlowController
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.driverIsShortScreen) private var isShort
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stamped = false
    @State private var confettiStart = Date()

    private var thanked: Bool { controller.pass?.thanksReceived == true }
    private var name: String { controller.displayName ?? "A neighbor" }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: isShort ? 14 : 22) {
                    stamp
                    Text(thanked ? ClipCopy.thanksHeadline : ClipCopy.passedHeadline)
                        .font(.driverHeadline).foregroundStyle(.white).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(thanked ? ClipCopy.thanksSub(name: name) : ClipCopy.passedSub)
                        .font(.title3).foregroundStyle(SpotPassTheme.lavender).multilineTextAlignment(.center)
                    VStack(spacing: 6) {
                        KarmaChip(label: thanked ? ClipCopy.karmaSettled : ClipCopy.karmaPending,
                                  style: thanked ? .settled : .pending)
                        if !thanked {
                            Text(ClipCopy.karmaPendingCaption).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                        }
                    }
                    SpotPassTextButton(title: DriverCopy.done, minHeight: 56) {
                        controller.dismissCelebration()
                        onDone()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            if !reduceMotion && !thanked {
                DriverConfettiView(start: confettiStart).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task {
            confettiStart = Date()
            if !reduceMotion { withAnimation(.spring(duration: 0.35)) { stamped = true } } else { stamped = true }
        }
    }

    private var stamp: some View {
        VStack(spacing: 8) {
            Text("SPOT PASSED")
                .font(.system(.headline, design: .rounded).weight(.heavy)).tracking(2)
                .foregroundStyle(SpotPassTheme.lavender)
            DriverGlyphDisc(glyph: controller.glyph, alias: controller.alias, size: typeSize.isAccessibilitySize ? 64 : 88)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(SpotPassTheme.lavender, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
        .rotationEffect(.degrees(-6))
        .scaleEffect(stamped || reduceMotion ? 1 : 1.25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spot passed")
    }
}
