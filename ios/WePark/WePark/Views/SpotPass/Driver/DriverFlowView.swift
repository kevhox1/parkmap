//
//  DriverFlowView.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C2: the full app's driver flow, presented as a full-screen cover over the map
//  (`SpotPassDriverLayer`). One screen at a time, human words, nothing asked before value
//  (spec 6): peek -> card + chips -> CTA -> armed -> pulling out -> celebration. Phases are
//  rendered from `DriverFlowController`; this file owns no logic beyond layout.
//

import SwiftUI
import UserNotifications

// MARK: - Copy that exists only in the full app

nonisolated enum DriverCopy {
    /// Under the CTA while the app has not yet asked for notification permission: the system prompt
    /// that follows the tap is explained BEFORE it appears (spec 6.3, "earned, not front-loaded").
    static let reminderPermissionNote = "WePark will ask to remind you at your leave time."
    static let closeLabel = "Close"
    static let done = "Done"
    /// "heads-up", never "ping" (voice rules). The hyphen is a non-breaking one (U+2011) so large Dynamic
    /// Type never splits the word across lines.
    static let autoPingRowTitle = "Auto heads\u{2011}up when you start your car"
    static let autoPingRowSub = "Tell your neighbor the moment your phone connects to your car."
    /// Entry back to an armed pass once the cover is closed (More sheet row, map chip).
    static let yourSpotPass = "Your Spot Pass"
    static let yourSpotPassHint = "Opens the pass you have set up."
    /// Footnote when the claimer secret could not be saved (the clip's "Get WePark" line does not fit
    /// a user who is already in the app). Nothing was armed.
    static let saveFailedFootnote = "We couldn't save this on your phone, so nothing was set up. Try scanning the pass again."
    static let startDrivingNote = "Tapping Start Driving also tells them you're leaving."

    // MARK: Armed-window auto-detect (C4, design 5.4). "auto heads-up", never "ping".
    static let autoDetectOffToast = "Auto heads-up is off."
    static let autoDetectOnTitle = "Auto heads-up is on"
    static func autoDetectOnSub(name: String) -> String {
        "We'll tell \(name) when you drive off. This stops after 60 minutes or when you cancel."
    }
    static let autoDetectTurnOff = "Turn off"
    static let autoDetectTurnOffHint = "Stops auto heads-up. You can still tap Leaving now."
    static let autoDetectOfferTitle = "Let WePark tell them when you drive off"
    static let autoDetectOfferSub = "Uses your location on this phone only while this pass is active."
    static let autoDetectWaitingTitle = "Auto heads-up is ready"
    static let autoDetectWaitingSub = "It starts when you open WePark within 30 minutes of your leave time."
    static let autoDetectNeedsCarTitle = "Auto heads-up needs your car"
    static let autoDetectNeedsCarSub = "Save your car's spot on the map first, then come back."
    static let autoDetectDeniedTitle = "Auto heads-up needs location"
    static let autoDetectDeniedSub = "Turn on location for WePark in Settings."

    // Purpose screen (one-time second opt-in, spec 9 item 1).
    static let purposeTitle = "Let WePark tell your neighbor for you"
    static let purposeBullet1Lead = "Only while a Spot Pass is active."
    static let purposeBullet1Rest = "Up to 60 minutes, then it stops."
    static let purposeBullet2Lead = "Your location stays on your phone."
    static let purposeBullet2Rest = "WePark only sends \u{201C}leaving\u{201D}, never where."
    static let purposeBullet3Lead = "You'll see a blue pill at the top"
    static let purposeBullet3Rest = "while it's on. Cancel anytime."
    static let purposePrimary = "Turn on auto heads-up"
    static let purposeSecondary = "Not now"
    static let purposeNoCarPrimary = "Save your car's spot first"
    static let purposeNoCarHelper = "Auto heads-up needs to know where your car is parked."
    static let purposeDeniedHelper = "Location is off for WePark. Turn it on in Settings to use auto heads-up."
    static let purposeSettings = "Open Settings"
}

// MARK: - Terminal / error screens (pure content)

nonisolated struct DriverMessageContent: Equatable, Sendable {
    let symbol: String
    let title: String
    let body: String
    var retry = false

    static func content(for phase: DriverPhase) -> DriverMessageContent {
        switch phase {
        case .unavailable:
            return .init(symbol: "clock.badge.xmark", title: ClipCopy.unavailableTitle, body: ClipCopy.unavailableBody)
        case .offline:
            return .init(symbol: "wifi.slash", title: ClipCopy.offlineTitle, body: ClipCopy.offlineBody, retry: true)
        case .busy:
            return .init(symbol: "hourglass", title: ClipCopy.busyTitle, body: ClipCopy.busyBody, retry: true)
        case .disabled:
            return .init(symbol: "clock", title: ClipCopy.disabledTitle, body: ClipCopy.disabledBody)
        case .openApp:
            // The full app is already open: this only happens against an old backend (no pass id).
            return .init(symbol: "exclamationmark.arrow.triangle.2.circlepath", title: "We couldn't finish setting this up.",
                         body: "Please scan the code again in a minute.")
        case .cancelled:
            return .init(symbol: "xmark.circle", title: ClipCopy.cancelledLine, body: "")
        case .ended:
            return .init(symbol: "clock.badge.checkmark", title: ClipCopy.passEnded, body: "")
        default:
            return .init(symbol: "parkingsign.circle", title: ClipCopy.landingTitle, body: ClipCopy.landingBody)
        }
    }
}

// MARK: - Root

struct DriverFlowView: View {
    @Bindable var controller: DriverFlowController
    var onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DriverBackdrop()
                content
                    .transition(.opacity)
            }
            .environment(\.driverIsShortScreen, proxy.size.height < SpotPassTheme.shortScreenHeight)
            .environment(\.driverScreenHeight, proxy.size.height)
        }
        .preferredColorScheme(.dark)
        .tint(SpotPassTheme.indigo)
        .animation(.easeInOut(duration: 0.25), value: controller.phase)
        .onChange(of: controller.phase) { _, phase in
            if phase == .dismissed { onClose() }
        }
        .alert(ClipCopy.cancelMyPass + "?", isPresented: $controller.showCancelConfirm) {
            // Not `.destructive`: red means curb rules in this app (design 6).
            Button(ClipCopy.cancelMyPass) { Task { await controller.confirmCancel() } }
            Button(ClipCopy.keepIt, role: .cancel) {}
        } message: {
            Text("\(controller.displayName ?? "Your neighbor") won't be told.")
        }
        .overlay(alignment: .top) { toastView }
        .task(id: controller.toast) {
            guard controller.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            controller.toast = nil
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .choosing, .arming:
            DriverChoosingView(controller: controller, onClose: onClose)
        case .armed:
            DriverArmedView(controller: controller, onClose: onClose)
        case .pullingOut, .sending, .sent:
            DriverPullingOutView(controller: controller)
        case .celebration:
            DriverCelebrationView(controller: controller, onDone: onClose)
        case .landing, .dismissed, .unavailable, .offline, .busy, .disabled, .openApp, .cancelled, .ended:
            DriverMessageView(
                content: DriverMessageContent.content(for: controller.phase),
                onRetry: { controller.retry() },
                onDone: onClose
            )
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = controller.toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.thinMaterial, in: Capsule())
                // Below the pinned header row (44 pt + status bar) so it never covers Report / Close.
                .padding(.top, 64)
                .transition(.opacity)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Message

struct DriverMessageView: View {
    let content: DriverMessageContent
    var onRetry: () -> Void
    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack { DriverWordmark(); Spacer() }.frame(minHeight: 44)
                Spacer(minLength: 40)
                Image(systemName: content.symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(Color.gray.opacity(0.45), in: Circle())
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.title.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if !content.body.isEmpty {
                    Text(content.body).font(.body).foregroundStyle(SpotPassTheme.lavender).multilineTextAlignment(.center)
                }
                if content.retry {
                    Button(ClipCopy.tryAgain, action: onRetry)
                        .buttonStyle(DriverHeroButtonStyle(minHeight: SpotPassTheme.buttonHeight))
                }
                SpotPassTextButton(title: DriverCopy.done, minHeight: 56, action: onDone)
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Choosing (beat 1)

struct DriverChoosingView: View {
    @Bindable var controller: DriverFlowController
    var onClose: () -> Void

    @Environment(\.driverIsShortScreen) private var isShort
    @Environment(\.driverScreenHeight) private var screenHeight
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showPicker = false
    @State private var showReport = false
    @State private var pickedDate = Date()
    @State private var willAskForNotifications = false

    private var isArming: Bool { controller.phase == .arming }

    /// What stays pinned (capped at ~30% of the screen, the clip's rule); the rest scrolls with the content.
    private var pinning: ClipCTAPinning.Plan {
        ClipCTAPinning.plan(screenHeight: screenHeight, dynamicTypeSize: typeSize, hasInlineError: controller.armFailure != nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: isShort ? 14 : 20) {
                DriverGlyphDisc(
                    glyph: controller.glyph, alias: controller.alias,
                    size: typeSize.isAccessibilitySize ? 72 : (isShort ? 64 : 96), floats: true
                )
                .redacted(reason: controller.preview == nil ? .placeholder : [])
                headline
                Text(ClipCopy.subline)
                    .font(isShort ? .callout : .title3)
                    .foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                chipsSection
                Text(ClipCopy.consent)
                    .font(.footnote)
                    .foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
                if pinning == .primaryOnly {
                    // Overflow from the pinned area (large text sizes): one scroll away, never covered.
                    if !typeSize.isAccessibilitySize {
                        Text(willAskForNotifications ? DriverCopy.reminderPermissionNote : ClipCopy.underCTA)
                            .font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                            .multilineTextAlignment(.center)
                    }
                    notLeavingSoonButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Pinned (not in the scroll) with an opaque backing: the header never slides under the status bar.
            topRow
                .padding(.horizontal, 20)
                .driverPinnedBarBackground(edge: .top)
        }
        .safeAreaInset(edge: .bottom) { pinnedCTA }
        .sheet(isPresented: $showPicker) { pickerSheet }
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

    // MARK: Pieces

    private var topRow: some View {
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
        }
        .frame(minHeight: 44)
    }

    private var headline: some View {
        Text(ClipCopy.headline(name: controller.preview?.name))
            .font(isShort ? .system(.title, design: .rounded).weight(.bold) : .driverHeadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 0 : (isShort ? 68 : 88), alignment: .top)
            .accessibilityAddTraits(.isHeader)
            .animation(.easeInOut(duration: 0.25), value: controller.preview?.name)
    }

    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ClipCopy.chipsLabel)
                .font(.headline)
                .foregroundStyle(.white)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 10) { allChips }
                } else {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) { chip(.now); chip(.minutes(10)); chip(.minutes(30)) }
                        HStack(spacing: 10) { chip(.minutes(60)); customChip }
                    }
                }
            }
            .disabled(isArming)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ClipCopy.chipsLabel)
    }

    @ViewBuilder private var allChips: some View {
        chip(.now); chip(.minutes(10)); chip(.minutes(30)); chip(.minutes(60)); customChip
    }

    private func chip(_ option: LeaveChoice) -> some View {
        DriverChip(
            title: ClipCopy.chipTitle(option), accessibilityLabel: ClipCopy.chipAccessibilityLabel(option),
            isSelected: controller.choice == option
        ) { controller.select(option) }
    }

    private var customChip: some View {
        let title: String
        if case .custom(let date) = controller.choice {
            title = ClipCopy.clockTime(date)
        } else {
            title = ClipCopy.pickTimeTitle
        }
        return DriverChip(
            title: title, accessibilityLabel: ClipCopy.chipAccessibilityLabel(.custom(Date())),
            isSelected: controller.choice.isCustom, wide: true
        ) {
            pickedDate = max(pickedDate, Date())
            showPicker = true
        }
    }

    private static func armFailureMessage(_ failure: DriverArmFailure) -> String {
        switch failure {
        case .busy: return ClipCopy.busyBody
        case .offline: return ClipCopy.offlineBody
        case .saveFailed: return DriverCopy.saveFailedFootnote
        }
    }

    private var notLeavingSoonButton: some View {
        SpotPassTextButton(title: ClipCopy.notLeavingSoon) { controller.notLeavingSoon() }
            .disabled(isArming)
    }

    private var pinnedCTA: some View {
        let plan = pinning
        return VStack(spacing: 6) {
            if let failure = controller.armFailure {
                Text(Self.armFailureMessage(failure))
                    .font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
            }
            Button {
                Task { await controller.arm() }
            } label: {
                if isArming {
                    ProgressView().tint(SpotPassTheme.ink)
                } else {
                    Text(ClipCopy.cta(choice: controller.choice, name: controller.preview?.name))
                }
            }
            .buttonStyle(DriverHeroButtonStyle())
            .disabled(isArming)
            .accessibilityLabel(ClipCopy.cta(choice: controller.choice, name: controller.preview?.name))
            .accessibilityHint(ClipCopy.consent)
            if plan == .full {
                Text(willAskForNotifications ? DriverCopy.reminderPermissionNote : ClipCopy.underCTA)
                    .font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
                notLeavingSoonButton
            }
        }
        // Bounded: the pinned stack never grows past the cap, whatever the user's text size.
        .dynamicTypeSize(...ClipCTAPinning.pinnedTypeSizeCap)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // Opaque scrim so scrolled text can never show through or collide with the CTAs.
        .driverPinnedBarBackground(edge: .bottom)
    }

    private var pickerSheet: some View {
        let range = LeaveChoice.pickableRange(from: Date())
        return VStack(spacing: 16) {
            Text(ClipCopy.pickTimeTitle).font(.title2.bold()).foregroundStyle(.white)
            DatePicker("", selection: $pickedDate, in: range, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
            Text(ClipCopy.pickTimeHelper).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
            Button(ClipCopy.pickTimeSet) {
                controller.select(.custom(pickedDate))
                showPicker = false
            }
            .buttonStyle(SpotPassButtonStyle(kind: .paper))
        }
        .padding(20)
        .presentationDetents([.medium])
        .background(SpotPassTheme.ink)
        .preferredColorScheme(.dark)
    }
}
