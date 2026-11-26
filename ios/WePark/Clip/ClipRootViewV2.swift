//
//  ClipRootViewV2.swift
//  WePark Clip
//
//  Stoop Phase 5b (round-2 B11): the clip's screens in the Stoop design system. Mounted by
//  `ClipRootView` only when `StoopFlag.designSystemV2Enabled` is true; with the flag off this file
//  is never reached and the shipping dark clip is untouched. Same `ClipFlowController`, same phases:
//  this layer only chooses which pure `WPClip*` view renders each phase and wires its closures.
//
//  The scheme follows the system (paper by day, ink-violet at night), like the full app under Stoop.
//

import SwiftUI
import StoreKit

struct ClipRootViewV2: View {
    @Bindable var controller: ClipFlowController
    let block: ClipBlockController

    @State private var installOverlay = false

    var body: some View {
        content
            .tint(WP.ink)
            .overlay(alignment: .bottom) { toastView }
            .sheet(isPresented: $controller.showCancelConfirm) {
                WPClipCancelSheet(
                    onCancelPass: { Task { await controller.confirmCancel() } },
                    onKeep: { controller.showCancelConfirm = false }
                )
            }
            .appStoreOverlay(isPresented: $installOverlay) {
                SKOverlay.AppClipConfiguration(position: .bottom)
            }
            .task {
                // While foregrounded, notice an expired pass.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await controller.tick()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .choosing, .arming:
            WPClipChoosingFlow(controller: controller)
        case .armed:
            WPClipArmedFlow(controller: controller, block: block)
        case .pullingOut, .sending, .sent:
            WPClipCountdownFlow(controller: controller)
        case .celebration:
            WPClipFinishedFlow(controller: controller) {
                controller.dismissInstallCard()
                installOverlay = true
            }
        default:
            WPClipMessageView(
                content: ClipMessageContent.content(for: controller.phase),
                onRetry: { controller.retry() },
                onWhatsWePark: { installOverlay = true }
            )
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = controller.toast {
            Text(toast)
                .font(WP.Font.fredoka(16, .semibold, relativeTo: .body))
                .foregroundStyle(WP.taxi)
                .padding(.horizontal, 18).frame(minHeight: WP.Target.minimum)
                .background(Capsule().fill(WP.ink))
                .padding(.bottom, 12)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    controller.toast = nil
                }
        }
    }
}

// MARK: - Cancel confirmation

/// A sheet rather than a system dialog so "Keep it" is a visible, full-size button.
struct WPClipCancelSheet: View {
    var onCancelPass: () -> Void
    var onKeep: () -> Void

    var body: some View {
        VStack(spacing: WP.Space.s3) {
            Text(ClipCopy.notLeavingAfterAll)
                .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, WP.Space.s2)
            WPClipPrimaryButton(title: ClipCopy.keepIt, action: onKeep)
            WPClipOutlineButton(title: ClipCopy.cancelMyPass, action: onCancelPass)
            Spacer(minLength: 0)
        }
        .padding(WP.Space.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WP.paper.ignoresSafeArea())
        .presentationDetents([.height(300), .large])
    }
}

// MARK: - B11.2 / B11.3 / B11.4

/// Intro -> time -> (reminder) -> arm. The steps are view state; the controller still sees one
/// `.choosing` phase and one `arm()`, so nothing about the pass semantics changes.
private struct WPClipChoosingFlow: View {
    @Bindable var controller: ClipFlowController

    private enum Step { case intro, time, reminder }

    @State private var step: Step = .intro
    @State private var showPicker = false
    @State private var showReport = false
    @State private var pickedDate = Date()

    private var isArming: Bool { controller.phase == .arming }

    var body: some View {
        Group {
            switch step {
            case .intro:
                WPClipIntroView(
                    name: controller.preview?.name, glyph: controller.glyph, alias: controller.alias,
                    isLoaded: controller.preview != nil,
                    onLeavingSoon: { step = .time },
                    onNotLeaving: { controller.notLeavingSoon() },
                    onReport: { showReport = true }
                )
            case .time:
                WPClipTimeView(
                    name: controller.preview?.name, choice: controller.choice, isArming: isArming,
                    failure: controller.armFailure,
                    onSelect: { controller.select($0) },
                    onPickTime: { pickedDate = max(pickedDate, Date()); showPicker = true },
                    onTell: { tell() },
                    onBack: { step = .intro }
                )
            case .reminder:
                WPClipReminderView(
                    name: controller.preview?.name,
                    around: WPClipClock.bare(controller.choice.leaveAt(from: controller.now)),
                    onAllow: { arm(wantsReminder: true) },
                    onSkip: { arm(wantsReminder: false) },
                    onBack: { step = .time }
                )
            }
        }
        .sheet(isPresented: $showPicker) {
            WPClipPickerSheet(date: $pickedDate) {
                controller.select(.custom(pickedDate))
                showPicker = false
            }
        }
        .confirmationDialog(ClipCopy.reportTitle, isPresented: $showReport, titleVisibility: .visible) {
            ForEach(ClipCopy.reportReasons, id: \.0) { reason, title in
                Button(title) { Task { await controller.report(reason) } }
            }
        }
    }

    /// "Now" skips the reminder step (a "Now" pass schedules no reminder); otherwise the step is shown only
    /// when reminders are already available (ephemeral grant). It never triggers a system prompt.
    private func tell() {
        Task {
            if !controller.choice.isNow, await controller.shouldOfferReminder() {
                step = .reminder
            } else {
                controller.chooseReminder(true)   // not offered: the default plan applies
                await controller.arm()
            }
        }
    }

    private func arm(wantsReminder: Bool) {
        step = .time   // an arm failure lands back on the time screen with its message
        Task {
            controller.chooseReminder(wantsReminder)
            await controller.arm()
        }
    }
}

// MARK: - B11.5

private struct WPClipArmedFlow: View {
    @Bindable var controller: ClipFlowController
    let block: ClipBlockController

    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let past = controller.pass.map { ClipArmedPresentation.isTimeToGo(leaveAt: $0.leaveAt, now: context.date) } ?? false
            WPClipArmedView(
                name: controller.displayName ?? "your neighbor",
                around: controller.pass.map { ClipCopy.clockTime($0.leaveAt) },
                isTimeToGo: past,
                activityStarted: controller.activityStarted,
                remindersOn: controller.reminderAvailability == .on,
                showsSettingsLink: !controller.activitiesEnabled,
                showsOtherPassNote: controller.showsOtherPassNote,
                onLeavingNow: { controller.showPullingOut() },
                onNotLeaving: { controller.requestCancel() },
                onOpenSettings: {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            ) {
                if ClipFeatureFlags.showBlockEnabled { WPClipBlockCard(block: block) }
            }
        }
    }
}

// MARK: - B11.7

private struct WPClipCountdownFlow: View {
    @Bindable var controller: ClipFlowController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let leaveAt = controller.pass?.leaveAt
            let past = leaveAt.map { $0 <= context.date.addingTimeInterval(1) } ?? true
            WPClipCountdownView(
                name: controller.displayName ?? "Your neighbor",
                leaveAt: leaveAt, now: context.date,
                mode: mode(past: past),
                canExtend: (controller.pass?.extensions ?? 0) < HandoffActivePass.maxExtensions,
                sendFailed: controller.sendFailed,
                onBack: controller.phase == .pullingOut ? { controller.backToArmed() } : nil,
                onLeavingNow: { Task { await controller.pullOut() } },
                onFiveMore: { Task { await controller.extendFiveMinutes() } },
                onNotLeaving: { controller.requestCancel() }
            )
        }
    }

    private func mode(past: Bool) -> WPClipCountdownView.Mode {
        switch controller.phase {
        case .sending: return .sending
        case .sent: return .sent
        default: return past ? .timeToGo : .counting
        }
    }
}

// MARK: - B11.8 / B11.9

private struct WPClipFinishedFlow: View {
    @Bindable var controller: ClipFlowController
    let onGetApp: () -> Void

    var body: some View {
        WPClipFinishedView(
            name: controller.displayName ?? "A neighbor",
            thanked: controller.pass?.thanksReceived == true,
            showsInstall: controller.showInstallCard,
            showsLockScreenLine: ClipInstallCardRules.showsLockScreenLine(activityStarted: controller.activityStarted),
            onDone: { controller.dismissCelebration() },
            onGet: onGetApp
        )
        .task {
            // The install ask lands ~1.5 s after the payoff, once per launch (design F8).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            controller.celebrationLanded()
        }
    }
}
