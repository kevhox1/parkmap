//
//  WPClipScreens.swift
//  Shared/Stoop
//
//  Stoop Phase 5b (round-2 B11): the App Clip screens as pure views. `Clip/ClipRootViewV2` feeds
//  them from `ClipFlowController`; the DEBUG showcase feeds them fixtures.
//
//    B11.2 intro      WPClipIntroView        B11.7 countdown  WPClipCountdownView
//    B11.3 reminder   WPClipReminderView     B11.8 finished   WPClipFinishedView
//    B11.4 time       WPClipTimeView         B11.9 get app    WPClipFinishedView(showsInstall:)
//    B11.5 armed      WPClipArmedView        (calm errors)    WPClipMessageView
//
//  B11.6 (block rules inside the clip) is not part of the Phase 5b match: DECISIONS marks it
//  "needs backend". The armed screen has a slot (`extra`) where the clip's existing on-demand
//  "This block" lookup card is mounted.
//

import SwiftUI

// MARK: - B11.2 First screen

struct WPClipIntroView: View {
    let name: String?
    let glyph: String
    let alias: String
    let isLoaded: Bool
    let onLeavingSoon: () -> Void
    let onNotLeaving: () -> Void
    /// "Report this pass": kept from the shipping clip (a safety path), a quiet text link under the card.
    let onReport: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WPClipPage(onBack: nil) {
            HStack(spacing: WP.Space.s3) {
                WPClipGlyph(glyph: glyph, alias: alias, size: typeSize.isAccessibilitySize ? 56 : 72)
                    .redacted(reason: isLoaded ? [] : .placeholder)
                Text(name ?? "A neighbor")
                    .font(WP.Font.fredoka(26, .semibold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .redacted(reason: isLoaded ? [] : .placeholder)
            }
            .accessibilityElement(children: .combine)
            WPClipHeadline(text: WPClipCopy.headline(name: name))
            WPClipSubline(text: WPClipCopy.subline)
            WPClipCard {
                WPClipCardText(title: WPClipCopy.privacyTitle, detail: WPClipCopy.privacyBody)
            }
            if let onReport {
                Button(action: onReport) {
                    Text(ClipCopy.reportTitle)
                        .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                        .frame(minHeight: WP.Target.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } bottom: {
            WPClipPrimaryButton(title: WPClipCopy.leavingSoon, action: onLeavingSoon)
            WPClipTextButton(title: WPClipCopy.notLeaving, action: onNotLeaving)
        }
    }
}

// MARK: - B11.3 Reminder permission

struct WPClipReminderView: View {
    let name: String?
    /// "4:45" (see `WPClipClock.bare`); nil falls back to a generic title.
    let around: String?
    let onAllow: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void

    var body: some View {
        WPClipPage(onBack: onBack) {
            WPClipHeadline(text: WPClipCopy.reminderHeadline)
            WPClipSubline(text: WPClipCopy.reminderSub)
            // A preview of the single notification the clip will send.
            VStack(alignment: .leading, spacing: 2) {
                Text(WPClipCopy.appName)
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .caption))
                    .foregroundStyle(WP.muted)
                Text(around.map(WPClipCopy.reminderTitle(around:)) ?? ClipCopy.timeToGo)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                Text(ClipCopy.reminderBody(name: name ?? "A neighbor"))
                    .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                    .foregroundStyle(WP.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WP.Space.s4)
            .background(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).fill(WP.card))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .accessibilityElement(children: .combine)
            Text(WPClipCopy.reminderOnly)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
        } bottom: {
            WPClipPrimaryButton(title: WPClipCopy.allowReminder, action: onAllow)
            WPClipTextButton(title: WPClipCopy.skip, action: onSkip)
        }
    }
}

// MARK: - B11.4 Pick a leave time

struct WPClipTimeView: View {
    let name: String?
    let choice: LeaveChoice
    let isArming: Bool
    let failure: ClipArmFailure?
    let onSelect: (LeaveChoice) -> Void
    let onPickTime: () -> Void
    let onTell: () -> Void
    let onBack: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WPClipPage(onBack: onBack) {
            WPClipHeadline(text: WPClipCopy.timeTitle)
            chips.disabled(isArming)
        } bottom: {
            if let failure {
                Text(failure == .busy ? ClipCopy.busyBody : ClipCopy.offlineBody)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.noParkText)
                    .multilineTextAlignment(.center)
            }
            WPClipPrimaryButton(
                title: WPClipCopy.tell(name: name), isBusy: isArming, hint: ClipCopy.consent, action: onTell
            )
        }
    }

    private var chips: some View {
        VStack(spacing: WP.Space.s3) {
            if typeSize.isAccessibilitySize {
                chip(.now); chip(.minutes(10)); chip(.minutes(30)); chip(.minutes(60))
            } else {
                HStack(spacing: WP.Space.s3) { chip(.now); chip(.minutes(10)) }
                HStack(spacing: WP.Space.s3) { chip(.minutes(30)); chip(.minutes(60)) }
            }
            customChip
        }
        .padding(.bottom, WP.Raise.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WPClipCopy.timeTitle)
    }

    private func chip(_ option: LeaveChoice) -> some View {
        WPClipChip(
            title: WPClipCopy.chipTitle(option), accessibilityLabel: ClipCopy.chipAccessibilityLabel(option),
            isSelected: choice == option
        ) { onSelect(option) }
    }

    private var customChip: some View {
        let title: String
        if case .custom(let date) = choice { title = ClipCopy.clockTime(date) } else { title = WPClipCopy.pickTime }
        return WPClipChip(
            title: title, accessibilityLabel: ClipCopy.chipAccessibilityLabel(.custom(Date())),
            isSelected: choice.isCustom, action: onPickTime
        )
    }
}

/// The wheel sheet for "Pick a time" (up to 4 hours from now).
struct WPClipPickerSheet: View {
    @Binding var date: Date
    let onSet: () -> Void

    var body: some View {
        VStack(spacing: WP.Space.s4) {
            Text(WPClipCopy.pickTime)
                .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .accessibilityAddTraits(.isHeader)
            DatePicker("", selection: $date, in: LeaveChoice.pickableRange(from: Date()), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
            Text(ClipCopy.pickTimeHelper)
                .font(WP.Font.fredoka(14, .regular, relativeTo: .footnote))
                .foregroundStyle(WP.muted)
            WPClipPrimaryButton(title: ClipCopy.pickTimeSet, action: onSet)
        }
        .padding(WP.Space.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WP.paper.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

// MARK: - B11.5 Armed

struct WPClipArmedView<Extra: View>: View {
    let name: String
    /// "4:45 PM"; nil when reminders and the countdown are both off.
    let around: String?
    let isTimeToGo: Bool
    let activityStarted: Bool
    let remindersOn: Bool
    let showsSettingsLink: Bool
    let showsOtherPassNote: Bool
    let onLeavingNow: () -> Void
    let onNotLeaving: () -> Void
    let onOpenSettings: () -> Void
    @ViewBuilder var extra: () -> Extra

    private var bothOff: Bool { !remindersOn && !activityStarted }

    var body: some View {
        WPClipPage(onBack: nil) {
            if showsOtherPassNote {
                WPClipCard { Text(ClipCopy.oneNeighborNote)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout)).foregroundStyle(WP.text) }
            }
            WPClipHeadline(text: isTimeToGo ? WPClipCopy.timeToGo : WPClipCopy.armedHeadline)
            WPClipSubline(text: isTimeToGo ? ClipCopy.pullingOutSafety : WPClipCopy.armedSub(name: name, around: around))
            lockCard
            extra()
        } bottom: {
            WPClipPrimaryButton(
                title: WPClipCopy.leavingNow,
                hint: "Tells \(name) you are leaving. Only tap right before you go.", action: onLeavingNow
            )
            WPClipTextButton(
                title: WPClipCopy.notLeavingAfterAll,
                hint: "Cancels your pass. \(name) will not be told.", action: onNotLeaving
            )
        }
    }

    private var lockCard: some View {
        WPClipCard {
            if bothOff {
                Text(ClipCopy.bothOff)
                    .font(WP.Font.fredoka(16, .regular, relativeTo: .body)).foregroundStyle(WP.text)
            } else if activityStarted {
                WPClipCardText(title: WPClipCopy.lockTitle, detail: WPClipCopy.lockBody)
                if !remindersOn {
                    Text(ClipCopy.remindersOff)
                        .font(WP.Font.fredoka(14, .regular, relativeTo: .footnote)).foregroundStyle(WP.muted)
                }
            } else {
                WPClipCardText(title: ClipCopy.activitiesOffTitle, detail: ClipCopy.activitiesOffBody)
                if showsSettingsLink {
                    WPClipTextButton(title: ClipCopy.settingsLink, hint: "Opens Settings so you can turn on Live Activities.", action: onOpenSettings)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - B11.7 Countdown ("Almost time") and the sent state

struct WPClipCountdownView: View {
    enum Mode: Equatable { case counting, timeToGo, sending, sent }

    let name: String
    let leaveAt: Date?
    /// The moment the timer counts from (the live clip passes `Date()` per tick; showcases pass a fixed one).
    let now: Date
    let mode: Mode
    let canExtend: Bool
    let sendFailed: Bool
    let onBack: (() -> Void)?
    let onLeavingNow: () -> Void
    let onFiveMore: () -> Void
    let onNotLeaving: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isSent: Bool { mode == .sent }

    var body: some View {
        WPClipPage(onBack: isSent ? nil : onBack) {
            if isSent {
                sentBlock
            } else {
                WPClipHeadline(text: mode == .timeToGo ? WPClipCopy.timeToGo : WPClipCopy.almostTime)
                if let leaveAt, mode == .counting, leaveAt > now.addingTimeInterval(1) {
                    timerCard(leaveAt: leaveAt)
                }
                buttons
                if sendFailed {
                    Text(ClipCopy.sendFailed)
                        .font(WP.Font.fredoka(16, .semibold, relativeTo: .body)).foregroundStyle(WP.noParkText)
                }
                Text(WPClipCopy.safety)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout)).foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } bottom: {
            if !isSent {
                WPClipPrimaryButton(
                    title: WPClipCopy.leavingNow, isBusy: mode == .sending,
                    hint: "Tells \(name) you are leaving. Only tap right before you go.", action: onLeavingNow
                )
            }
        }
    }

    private func timerCard(leaveAt: Date) -> some View {
        WPClipCard {
            Text(WPClipCopy.leavingIn)
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .headline)).foregroundStyle(WP.text)
            Text(timerInterval: now...leaveAt, countsDown: true)
                .font(WP.Font.fredoka(64, .bold, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(WP.text)
                .minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityLabel("Time until you leave")
            Text(WPClipCopy.isWaiting(name: name))
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .headline)).foregroundStyle(WP.text)
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: WP.Space.s3)) : AnyLayout(HStackLayout(spacing: WP.Space.s3))
        return layout {
            WPClipOutlineButton(title: WPClipCopy.fiveMore, isDisabled: !canExtend || mode == .sending, hint: "Gives you five more minutes", action: onFiveMore)
            WPClipOutlineButton(
                title: WPClipCopy.notLeavingShort, isDisabled: mode == .sending,
                hint: "Cancels your pass. \(name) will not be told.", action: onNotLeaving
            )
        }
    }

    private var sentBlock: some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            WPClipHeadline(text: WPClipCopy.headsUpTitle)
            WPClipSubline(text: WPClipCopy.headsUpSent(name: name))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - B11.8 Finished / B11.9 Get the app

struct WPClipFinishedView: View {
    let name: String
    let thanked: Bool
    let showsInstall: Bool
    let showsLockScreenLine: Bool
    let onDone: () -> Void
    let onGet: () -> Void

    var body: some View {
        WPClipPage(onBack: nil) {
            WPClipHeadline(text: thanked ? WPClipCopy.thanksTitle : WPClipCopy.passedTitle)
            WPClipSubline(text: thanked ? WPClipCopy.thanksSub(name: name) : WPClipCopy.passedSub)
            WPClipStamp()
            if !thanked {
                Text(WPClipCopy.karmaPending)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout)).foregroundStyle(WP.muted)
            }
            if showsInstall {
                WPClipCard {
                    WPClipCardText(
                        title: WPClipCopy.keepKarmaTitle,
                        detail: showsLockScreenLine
                            ? WPClipCopy.keepKarmaBody + " " + ClipCopy.installSecondary
                            : WPClipCopy.keepKarmaBody
                    )
                }
            }
        } bottom: {
            if showsInstall {
                WPClipInstallBar(onGet: onGet)
            }
            Button(action: onDone) {
                Text(WPClipCopy.done)
                    .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(showsInstall ? WP.text : WP.taxi)
                    .frame(maxWidth: .infinity, minHeight: showsInstall ? WP.Target.minimum : WP.Target.standard)
                    .background(showsInstall ? AnyShapeStyle(Color.clear) : AnyShapeStyle(WP.ink), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Calm terminal / error screens (restyled; no mock, same words)

struct WPClipMessageView: View {
    let content: ClipMessageContent
    let onRetry: () -> Void
    let onWhatsWePark: () -> Void

    var body: some View {
        WPClipPage(onBack: nil) {
            Image(systemName: content.symbol)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(WP.text)
                .frame(width: 72, height: 72)
                .background(Circle().fill(WP.card))
                .overlay(Circle().strokeBorder(WP.line, lineWidth: WP.Border.control))
                .accessibilityHidden(true)
            WPClipHeadline(text: content.title)
            if !content.body.isEmpty { WPClipSubline(text: content.body) }
        } bottom: {
            if content.retry { WPClipPrimaryButton(title: ClipCopy.tryAgain, action: onRetry) }
            if content.showsWhatsWePark { WPClipTextButton(title: ClipCopy.whatsWePark, action: onWhatsWePark) }
        }
    }
}
