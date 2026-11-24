//
//  AutoDetectViews.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C4 (design 5.4): the armed-state indicator row on the driver's armed screen and the
//  one-time purpose screen (the second explicit opt-in, spec 9 item 1). Voice: "auto heads-up",
//  never "ping". The Leaving now button is never displaced or shrunk by anything here.
//
//  Nothing renders with `AppConstants.spotHandoffAutoDetectEnabled == false`: the controller's
//  `autoDetect` is nil and the offer is `.hidden`.
//

import SwiftUI

// MARK: - Row

struct AutoDetectRow: View {
    @Bindable var controller: DriverFlowController
    @State private var showPurpose = false

    var body: some View {
        if let autoDetect = controller.autoDetect {
            AutoDetectRowBody(
                autoDetect: autoDetect, name: controller.displayName ?? "your neighbor",
                onOpenPurpose: { showPurpose = true }, onTurnOff: { controller.turnOffAutoDetect() }
            )
            .sheet(isPresented: $showPurpose) {
                AutoDetectPurposeView(controller: controller, onClose: { showPurpose = false })
            }
            .task { autoDetect.refreshOffer() }
        }
    }
}

private struct AutoDetectRowBody: View {
    var autoDetect: any AutoDetectControlling
    let name: String
    var onOpenPurpose: () -> Void
    var onTurnOff: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    /// True once this row has shown an opt-in offer. A row that first appears already on/ready means
    /// the opt-in carried over from an earlier pass, which the note makes unmistakable.
    @State private var offeredHere = false

    private var carriedOver: Bool {
        !offeredHere && (autoDetect.offer == .on || autoDetect.offer == .waiting)
    }

    var body: some View {
        content
            .onChange(of: autoDetect.offer, initial: true) { _, offer in
                switch offer {
                case .canEnable, .needsSavedCar, .locationDenied: offeredHere = true
                case .hidden, .waiting, .on: break
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch autoDetect.offer {
        case .hidden:
            EmptyView()
        case .on:
            withCarriedNote(stateRow(title: DriverCopy.autoDetectOnTitle, sub: DriverCopy.autoDetectOnSub(name: name), symbol: "location.fill", showsTurnOff: true))
        case .waiting:
            withCarriedNote(stateRow(title: DriverCopy.autoDetectWaitingTitle, sub: DriverCopy.autoDetectWaitingSub, symbol: "location", showsTurnOff: true))
        case .canEnable:
            offerRow(title: DriverCopy.autoDetectOfferTitle, sub: DriverCopy.autoDetectOfferSub)
        case .needsSavedCar:
            offerRow(title: DriverCopy.autoDetectNeedsCarTitle, sub: DriverCopy.autoDetectNeedsCarSub)
        case .locationDenied:
            offerRow(title: DriverCopy.autoDetectDeniedTitle, sub: DriverCopy.autoDetectDeniedSub)
        }
    }

    private func withCarriedNote(_ row: some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            if carriedOver {
                Text(DriverCopy.autoDetectCarriedNote)
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    // On / ready: a status row with a Turn off button (44 pt minimum; 56 here).
    private func stateRow(title: String, sub: String, symbol: String, showsTurnOff: Bool) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) { icon(symbol); texts(title: title, sub: sub) }
                    if showsTurnOff { turnOffButton }
                }
            } else {
                HStack(spacing: 16) {
                    icon(symbol)
                    texts(title: title, sub: sub)
                    Spacer(minLength: 0)
                    if showsTurnOff { turnOffButton }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var turnOffButton: some View {
        Button(action: onTurnOff) {
            Text(DriverCopy.autoDetectTurnOff)
                .font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minWidth: 56, minHeight: 56)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(DriverCopy.autoDetectTurnOffHint)
    }

    private func offerRow(title: String, sub: String) -> some View {
        Button(action: onOpenPurpose) {
            HStack(spacing: 16) {
                icon("location")
                texts(title: title, sub: sub)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true)
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

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(SpotPassTheme.lavender)
            .frame(minWidth: 32, alignment: .center)
            .accessibilityHidden(true)
    }

    private func texts(title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(.white)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Text(sub).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Purpose screen

/// What the purpose screen's primary action does for each offer state (pure; the view applies it).
nonisolated enum AutoDetectPurposePlan: Equatable, Sendable {
    case enable
    case saveCarFirst
    case openSettings

    static func plan(for offer: AutoDetectOffer) -> AutoDetectPurposePlan {
        switch offer {
        case .needsSavedCar: return .saveCarFirst
        case .locationDenied: return .openSettings
        default: return .enable
        }
    }
}

struct AutoDetectPurposeView: View {
    @Bindable var controller: DriverFlowController
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var deniedAfterAsk = false

    private var offer: AutoDetectOffer { controller.autoDetect?.offer ?? .hidden }
    private var plan: AutoDetectPurposePlan { deniedAfterAsk ? .openSettings : AutoDetectPurposePlan.plan(for: offer) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "location.fill")
                    .font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(SpotPassTheme.indigo, in: Circle())
                    .accessibilityHidden(true)
                Text(DriverCopy.purposeTitle)
                    .font(.driverHeadline).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 16) {
                    bullet("clock", DriverCopy.purposeBullet1Lead, DriverCopy.purposeBullet1Rest)
                    bullet("iphone", DriverCopy.purposeBullet2Lead, DriverCopy.purposeBullet2Rest)
                    bullet("capsule.fill", DriverCopy.purposeBullet3Lead, DriverCopy.purposeBullet3Rest)
                }
                if plan == .saveCarFirst {
                    Text(DriverCopy.purposeNoCarHelper).font(.callout).foregroundStyle(SpotPassTheme.lavender)
                }
                if plan == .openSettings {
                    Text(DriverCopy.purposeDeniedHelper).font(.callout).foregroundStyle(SpotPassTheme.lavender)
                }
                primaryButton
                SpotPassTextButton(title: DriverCopy.purposeSecondary, minHeight: 56, action: onClose)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DriverBackdrop())
        .preferredColorScheme(.dark)
        .tint(SpotPassTheme.indigo)
        .presentationDetents([.large])
        .onAppear { controller.autoDetect?.refreshOffer() }
    }

    @ViewBuilder private var primaryButton: some View {
        switch plan {
        case .enable:
            Button { Task { await enable() } } label: {
                if working { ProgressView().tint(SpotPassTheme.ink) } else { Text(DriverCopy.purposePrimary) }
            }
            .buttonStyle(DriverHeroButtonStyle(minHeight: 64))
            .disabled(working)
        case .saveCarFirst:
            // Disabled, per design: the helper above says why.
            Button {} label: { Text(DriverCopy.purposeNoCarPrimary) }
                .buttonStyle(DriverHeroButtonStyle(minHeight: 64))
                .disabled(true).opacity(0.5)
        case .openSettings:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: { Text(DriverCopy.purposeSettings) }
            .buttonStyle(DriverHeroButtonStyle(minHeight: 64))
        }
    }

    private func enable() async {
        working = true
        let result = await controller.enableAutoDetect()
        working = false
        switch result {
        case .enabled: onClose()
        case .locationDenied: deniedAfterAsk = true
        case .needsSavedCar, .unavailable: break
        }
    }

    private func bullet(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .foregroundStyle(SpotPassTheme.lavender)
                .frame(minWidth: 32, minHeight: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(lead).font(.headline).foregroundStyle(.white)
                Text(rest).font(.body).foregroundStyle(SpotPassTheme.lavender)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
