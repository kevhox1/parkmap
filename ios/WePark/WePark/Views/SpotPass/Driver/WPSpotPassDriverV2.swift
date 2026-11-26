//
//  WPSpotPassDriverV2.swift
//  Views/SpotPass/Driver
//
//  Stoop Phase 5a: the round-2 skin (B10) of the full app's Spot Pass DRIVER screens. Shown only
//  while `AppConstants.designSystemV2Enabled` (and, as before, `spotHandoffEnabled`).
//
//  Two layers:
//    - `WPDriver*V2` leaf views: plain values and closures, no controller. The DEBUG showcase draws
//      these directly.
//    - `WPDriver*Stoop` wrappers: read `DriverFlowController` and call its existing methods. They
//      add NO behavior: arm, pull out, extend, cancel, report, auto heads-up and the 20 s tick are
//      exactly what the legacy screens call.
//
//  Rules: "About 10 min" wording; "Pick a time" in 15-minute slots up to 4 h; the auto heads-up is
//  an opt-in switch, OFF by default (turning it on still goes through the purpose screen); privacy
//  line intact ("They won't see who you are"); controls >= 48 pt; wraps through AX5.
//

import SwiftUI
import UserNotifications

// MARK: - B10.1 / B10.2 choosing

struct WPDriverChoosingV2: View {
    let name: String?
    let glyphSymbol: String
    let tintIndex: Int
    let choice: LeaveChoice
    let isArming: Bool
    let armFailureMessage: String?
    let willAskForNotifications: Bool
    let ctaTitle: String
    let onSelect: (LeaveChoice) -> Void
    let onArm: () -> Void
    let onNotLeaving: () -> Void
    let onReport: () -> Void
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showPicker = false
    @State private var slotsNow = Date()

    private var pickedClock: String? {
        if case .custom(let date) = choice { return ClipCopy.clockTime(date) }
        return nil
    }

    var body: some View {
        WPScreenScaffold(
            onClose: onClose,
            title: WPPassCopy.driverTitle(name: name),
            sub: WPPassCopy.driverSub,
            primary: wpPassPrimary(isArming ? "Telling \(name ?? "your neighbor")..." : ctaTitle, .commitment, onArm),
            secondary: wpPassSecondary(WPPassCopy.notLeaving, onNotLeaving)
        ) {
            HStack(spacing: WP.Space.s3) {
                AliasGlyphDisc(symbolName: glyphSymbol, tintIndex: tintIndex, size: typeSize.isAccessibilitySize ? 48 : 56)
                Text(name ?? "A neighbor")
                    .font(WP.Font.fredoka(20, .semibold, relativeTo: .title3))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(.bottom, WP.Space.s2)

            Text(ClipCopy.chipsLabel)
                .font(WP.Font.fredoka(12, .semibold, relativeTo: .caption))
                .kerning(0.8)
                .foregroundStyle(WP.muted)
                .accessibilityAddTraits(.isHeader)
            chips
                .disabled(isArming)

            Text(ClipCopy.consent)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WP.Space.s2)
            if let armFailureMessage {
                Text(armFailureMessage)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if willAskForNotifications {
                Text(DriverCopy.reminderPermissionNote)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(WPPassCopy.reportPass, action: onReport)
                .buttonStyle(.wpTextLink)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showPicker) {
            WPLeaveTimeSheetV2(
                slots: WPPassLogic.leaveSlots(from: slotsNow),
                selected: { if case .custom(let d) = choice { return d }; return nil }(),
                onUse: { date in
                    onSelect(.custom(date))
                    showPicker = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(WP.Radius.sheet)
        }
    }

    @ViewBuilder private var chips: some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: WP.Space.s2), GridItem(.flexible(), spacing: WP.Space.s2)]
        LazyVGrid(columns: columns, spacing: WP.Space.s1) {
            ForEach(Array(LeaveChoice.presets.enumerated()), id: \.offset) { _, option in
                WPChoiceChip(title: WPPassCopy.chipTitle(option), isSelected: choice == option) { onSelect(option) }
                    .accessibilityLabel(WPPassCopy.chipAccessibilityLabel(option))
            }
        }
        WPChoiceChip(
            title: WPPassCopy.chipTitle(.custom(Date()), clock: pickedClock),
            isSelected: choice.isCustom,
            height: 56
        ) {
            slotsNow = Date()
            showPicker = true
        }
        .accessibilityLabel(pickedClock.map { "Leaving around \($0)" } ?? "Pick a time")
    }
}

/// B10.2: a sheet of quarter-hour times, up to 4 hours from now.
struct WPLeaveTimeSheetV2: View {
    let slots: [Date]
    let selected: Date?
    let onUse: (Date) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choice: Date?

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: WP.Space.s2),
            count: typeSize.isAccessibilitySize ? 2 : 4
        )
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s2) {
                    Text(WPPassCopy.pickTitle)
                        .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                        .foregroundStyle(WP.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(WPPassCopy.pickSub)
                        .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: columns, spacing: WP.Space.s1) {
                        ForEach(slots, id: \.self) { slot in
                            WPChoiceChip(title: ClipCopy.clockTime(slot), isSelected: choice == slot, height: 56) {
                                choice = slot
                            }
                        }
                    }
                    .padding(.top, WP.Space.s2)
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button(choice.map { WPPassCopy.useTime(ClipCopy.clockTime($0)) } ?? "Pick a time") {
                if let choice { onUse(choice) }
            }
            .buttonStyle(.wpInkPill)
            .disabled(choice == nil)
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.vertical, WP.Space.s2)
        }
        .background(WP.paper.ignoresSafeArea())
        .onAppear { choice = selected }
    }
}

// MARK: - B10.3 / B10.4 armed

struct WPDriverArmedV2<AutoRow: View>: View {
    let name: String
    let subline: String
    let showsOtherPassNote: Bool
    let bothOff: Bool
    let activityStarted: Bool
    let remindersOff: Bool
    let onPullingOut: () -> Void
    let onNotLeaving: () -> Void
    let onCarGuide: () -> Void
    let onReport: () -> Void
    let onClose: () -> Void
    @ViewBuilder var autoRow: () -> AutoRow

    var body: some View {
        WPScreenScaffold(
            onClose: onClose,
            title: ClipCopy.armedHeadline,
            sub: subline,
            primary: wpPassPrimary(WPPassCopy.leavingNow, .commitment, onPullingOut),
            secondary: wpPassSecondary(WPPassCopy.notLeavingAfterAll, onNotLeaving)
        ) {
            if showsOtherPassNote {
                WPPassNote(title: ClipCopy.oneNeighborNote)
            }
            if bothOff {
                WPPassNote(title: ClipCopy.bothOff)
            } else {
                WPPassBox {
                    Text(ClipCopy.lockScreenTitle)
                        .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                        .foregroundStyle(WP.text)
                    Text(activityStarted ? ClipCopy.lockScreenBody : ClipCopy.activitiesOff)
                        .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                    if activityStarted {
                        Text(DriverCopy.startDrivingNote)
                            .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                            .foregroundStyle(WP.muted)
                    }
                    if remindersOff {
                        Text(ClipCopy.remindersOff)
                            .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                            .foregroundStyle(WP.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            autoRow()
            WPListCard {
                WPListRow(
                    title: DriverCopy.autoPingRowTitle,
                    subtitle: DriverCopy.autoPingRowSub,
                    trailing: .chevron,
                    action: onCarGuide
                )
            }
            Button(WPPassCopy.reportPass, action: onReport)
                .buttonStyle(.wpTextLink)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - B10.6 pulling out ("Leaving now")

struct WPDriverPullingOutV2: View {
    let name: String
    let leaveAt: Date?
    let isSending: Bool
    let isSent: Bool
    let sendFailed: Bool
    let canExtend: Bool
    /// "Back" is only offered before the tap, while the pass can still return to the armed screen.
    let onBack: (() -> Void)?
    let onLeavingNow: () -> Void
    let onFiveMore: () -> Void
    let onNotLeaving: () -> Void

    var body: some View {
        WPScreenScaffold(
            closeLabel: "Back",
            onClose: onBack,
            title: isSent ? ClipCopy.sentLine(name: name) : WPPassCopy.leavingNow,
            primary: isSent ? nil : wpPassPrimary(isSending ? "Telling \(name)..." : ClipCopy.pullingOut, .commitment, onLeavingNow),
            secondary: isSent ? nil : wpPassSecondary(WPPassCopy.notLeaving, onNotLeaving)
        ) {
            if !isSent {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WPPassBox {
                        if let leaveAt, leaveAt > context.date.addingTimeInterval(1) {
                            Text("Leaving in")
                                .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                            Text(timerInterval: context.date...leaveAt, countsDown: true)
                                .font(WP.Font.fredoka(44, .bold, relativeTo: .largeTitle))
                                .monospacedDigit()
                        } else {
                            Text(ClipCopy.timeToGo)
                                .font(WP.Font.fredoka(32, .bold, relativeTo: .largeTitle))
                        }
                    }
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
                Button(ClipCopy.fiveMore, action: onFiveMore)
                    .buttonStyle(.wpSecondary)
                    .disabled(!canExtend || isSending)
                    .accessibilityLabel("Five more minutes")
            }
            if sendFailed {
                Text(ClipCopy.sendFailed)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ClipCopy.pullingOutSafety)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - B10.7 finished

struct WPDriverCelebrationV2: View {
    let thanked: Bool
    let name: String
    let karmaLabel: String
    let onDone: () -> Void

    var body: some View {
        WPScreenScaffold(
            title: thanked ? ClipCopy.thanksHeadline : ClipCopy.passedHeadline,
            sub: thanked ? ClipCopy.thanksSub(name: name) : ClipCopy.passedSub,
            primary: wpPassPrimary(DriverCopy.done, .navigation, onDone)
        ) {
            WPSpotPassedStamp().padding(.vertical, WP.Space.s3)
            WPPassKarmaTag(label: karmaLabel)
            if !thanked {
                Text(ClipCopy.karmaPendingCaption)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - B10.8 / B10.9 / B10.10 unavailable, offline, not live

struct WPDriverMessageV2: View {
    let title: String
    let body_: String
    let retry: Bool
    let onRetry: () -> Void
    let onDone: () -> Void

    var body: some View {
        WPScreenScaffold(
            title: title,
            sub: body_.isEmpty ? nil : body_,
            primary: retry
                ? wpPassPrimary(ClipCopy.tryAgain, .navigation, onRetry)
                : wpPassPrimary(DriverCopy.done, .navigation, onDone),
            secondary: retry ? wpPassSecondary(DriverCopy.done, onDone) : nil
        ) {
            WPHollowToken().frame(maxWidth: .infinity, minHeight: 96)
        }
    }
}

// MARK: - Controller-bound wrappers (no new behavior)

struct WPDriverChoosingStoop: View {
    @Bindable var controller: DriverFlowController
    var onClose: () -> Void

    @State private var showReport = false
    @State private var willAskForNotifications = false

    private var armFailureMessage: String? {
        switch controller.armFailure {
        case .busy: return ClipCopy.busyBody
        case .offline: return ClipCopy.offlineBody
        case .saveFailed: return DriverCopy.saveFailedFootnote
        case nil: return nil
        }
    }

    var body: some View {
        WPDriverChoosingV2(
            name: controller.preview?.name,
            glyphSymbol: SpotPassGlyph.symbolName(for: controller.glyph),
            tintIndex: SpotPassGlyph.tintIndex(forAlias: controller.alias),
            choice: controller.choice,
            isArming: controller.phase == .arming,
            armFailureMessage: armFailureMessage,
            willAskForNotifications: willAskForNotifications,
            ctaTitle: ClipCopy.cta(choice: controller.choice, name: controller.preview?.name),
            onSelect: { controller.select($0) },
            onArm: { Task { await controller.arm() } },
            onNotLeaving: { controller.notLeavingSoon() },
            onReport: { showReport = true },
            onClose: onClose
        )
        .confirmationDialog(ClipCopy.reportTitle, isPresented: $showReport, titleVisibility: .visible) {
            ForEach(ClipCopy.reportReasons, id: \.0) { reason, title in
                Button(title) { Task { await controller.report(reason) } }
            }
        }
        .task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            willAskForNotifications = status == .notDetermined
        }
    }
}

struct WPDriverArmedStoop: View {
    @Bindable var controller: DriverFlowController
    var onClose: () -> Void

    @State private var showCarGuide = false
    @State private var showReport = false

    private var bothOff: Bool { controller.reminderAvailability == .off && !controller.activityStarted }

    private var subline: String {
        guard let pass = controller.pass else { return "" }
        let reminder = controller.reminderAvailability == .on ? ClipCopy.clockTime(pass.leaveAt) : nil
        return ClipCopy.armedSub(name: pass.name, reminderTime: reminder)
    }

    var body: some View {
        WPDriverArmedV2(
            name: controller.displayName ?? "your neighbor",
            subline: subline,
            showsOtherPassNote: controller.showsOtherPassNote,
            bothOff: bothOff,
            activityStarted: controller.activityStarted,
            remindersOff: controller.reminderAvailability == .off,
            onPullingOut: { controller.showPullingOut() },
            onNotLeaving: { controller.requestCancel() },
            onCarGuide: { showCarGuide = true },
            onReport: { showReport = true },
            onClose: onClose,
            autoRow: { WPDriverAutoSwitchRowV2(controller: controller) }
        )
        .task {
            // Expires a lapsed pass and (C4) opens the auto-detect window once the leave time is near.
            while !Task.isCancelled {
                await controller.tick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .sheet(isPresented: $showCarGuide) { CarAutoPingGuideView() }
        .confirmationDialog(ClipCopy.reportTitle, isPresented: $showReport, titleVisibility: .visible) {
            ForEach(ClipCopy.reportReasons, id: \.0) { reason, title in
                Button(title) { Task { await controller.report(reason) } }
            }
        }
    }
}

/// The opt-in switch. OFF unless the driver already opted in; flipping it ON opens the purpose
/// screen (the second explicit opt-in), flipping it OFF turns auto heads-up off at once.
struct WPDriverAutoSwitchRowV2: View {
    @Bindable var controller: DriverFlowController
    @State private var showPurpose = false
    /// True once this row has shown an opt-in offer. A row that first appears already on means the
    /// opt-in carried over from an earlier pass, which the note makes unmistakable.
    @State private var offeredHere = false

    var body: some View {
        if let autoDetect = controller.autoDetect {
            let state = WPPassLogic.autoSwitch(offer: autoDetect.offer, name: controller.displayName ?? "your neighbor")
            if state.isVisible {
                VStack(alignment: .leading, spacing: WP.Space.s2) {
                    WPListCard {
                        WPListToggleRow(
                            title: WPPassCopy.autoRowTitle,
                            subtitle: state.subtitle,
                            isOn: Binding(
                                get: { state.isOn },
                                set: { newValue in
                                    switch WPPassLogic.switchAction(currentlyOn: state.isOn, newValue: newValue) {
                                    case .openPurpose: showPurpose = true
                                    case .turnOff: controller.turnOffAutoDetect()
                                    case .none: break
                                    }
                                }
                            )
                        )
                    }
                    if state.isOn && !offeredHere {
                        Text(DriverCopy.autoDetectCarriedNote)
                            .font(WP.Font.fredoka(13, .semibold, relativeTo: .caption))
                            .foregroundStyle(WP.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: autoDetect.offer, initial: true) { _, offer in
                    switch offer {
                    case .canEnable, .needsSavedCar, .locationDenied: offeredHere = true
                    case .hidden, .waiting, .on: break
                    }
                }
                .sheet(isPresented: $showPurpose) {
                    AutoDetectPurposeView(controller: controller, onClose: { showPurpose = false })
                }
                .task { autoDetect.refreshOffer() }
            }
        }
    }
}

struct WPDriverPullingOutStoop: View {
    @Bindable var controller: DriverFlowController

    var body: some View {
        WPDriverPullingOutV2(
            name: controller.displayName ?? "A neighbor",
            leaveAt: controller.pass?.leaveAt,
            isSending: controller.phase == .sending,
            isSent: controller.phase == .sent,
            sendFailed: controller.sendFailed,
            canExtend: (controller.pass?.extensions ?? 0) < HandoffActivePass.maxExtensions,
            onBack: controller.phase == .pullingOut ? { controller.backToArmed() } : nil,
            onLeavingNow: { Task { await controller.pullOut() } },
            onFiveMore: { Task { await controller.extendFiveMinutes() } },
            onNotLeaving: { controller.requestCancel() }
        )
    }
}

struct WPDriverCelebrationStoop: View {
    @Bindable var controller: DriverFlowController
    var onDone: () -> Void

    private var thanked: Bool { controller.pass?.thanksReceived == true }

    var body: some View {
        WPDriverCelebrationV2(
            thanked: thanked,
            name: controller.displayName ?? "A neighbor",
            karmaLabel: thanked ? ClipCopy.karmaSettled : ClipCopy.karmaPending,
            onDone: {
                controller.dismissCelebration()
                onDone()
            }
        )
    }
}
