//
//  SpotPassDriverLayer.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C2: the ONE attachment point of the full-app driver flow on `ContentView`. Everything
//  the driver flow needs from the view tree lives in this modifier so `ContentView.body` gains a
//  single line:
//    - the universal-link inbox drain (cold launch, link arrived before mount, foreground),
//    - the driver full-screen cover (its own presentation layer, like the seeker cover and the
//      onboarding deck: a second `.sheet` next to `ContentView`'s `.sheet(item: $activeSheet)` host
//      silently never presents, see `routeRegularsInviteRedemption`),
//    - the clip-origin Welcome cover.
//
//  FLAG-OFF: with `AppConstants.spotHandoffEnabled == false` the modifier returns `content`
//  untouched, so the view hierarchy is identical to before this PR.
//

import SwiftUI

struct SpotPassDriverLayer: ViewModifier {
    @Bindable var runtime: SpotPassDriverRuntime
    let authService: SupabaseAuthService
    /// The APNs token the push-registration service holds (for the thank-you alert).
    let pushTokenHex: () -> String?
    /// The seeker's own full-screen cover: only one cover can present at a time.
    @Binding var seekerCoverPresented: Bool
    /// After the Welcome finishes (the caller schedules the unchanged Tier 3 coach).
    let onWelcomeFinished: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    @ViewBuilder
    func body(content: Content) -> some View {
        if AppConstants.spotHandoffEnabled {
            content
                .fullScreenCover(isPresented: $runtime.coverPresented) {
                    DriverFlowView(controller: runtime.controller, onClose: { runtime.coverPresented = false })
                }
                .fullScreenCover(isPresented: $runtime.welcomeRequested, onDismiss: {
                    SpotPassWelcomeCoordinator.finishWelcome()
                    onWelcomeFinished()
                }) {
                    welcomeCover
                }
                .onReceive(NotificationCenter.default.publisher(for: .spotPassLinkReceived)) { _ in
                    runtime.drainInbox()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    runtime.drainInbox()
                    Task { await runtime.foregrounded() }
                }
                .onChange(of: runtime.coverPresented) { _, presented in
                    // A seeker cover on screen would swallow this presentation: close it first.
                    guard presented, seekerCoverPresented else { return }
                    seekerCoverPresented = false
                    runtime.coverPresented = false
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        runtime.coverPresented = true
                    }
                }
                .task {
                    runtime.accessTokenProvider = { [authService] in await authService.validAccessToken() }
                    runtime.pushTokenProvider = pushTokenHex
                    #if DEBUG
                    runtime.injectDebugLinkIfRequested()
                    #endif
                    runtime.drainInbox()
                    await runtime.foregrounded()
                }
        } else {
            content
        }
    }

    @ViewBuilder private var welcomeCover: some View {
        if let context = ClipHandoffContextStore().load() {
            SpotPassWelcomeView(
                content: SpotPassWelcomeContent.make(for: context),
                alias: context.lastAlias,
                onFinish: { runtime.welcomeRequested = false }
            )
        } else {
            Color.clear.onAppear { runtime.welcomeRequested = false }
        }
    }
}

extension View {
    /// Attaches the Spot Pass driver flow (links, cover, Welcome). Inert while the feature flag is off.
    func spotPassDriverLayer(
        runtime: SpotPassDriverRuntime = .shared,
        authService: SupabaseAuthService,
        pushTokenHex: @escaping () -> String?,
        seekerCoverPresented: Binding<Bool>,
        onWelcomeFinished: @escaping () -> Void
    ) -> some View {
        modifier(SpotPassDriverLayer(
            runtime: runtime, authService: authService, pushTokenHex: pushTokenHex,
            seekerCoverPresented: seekerCoverPresented, onWelcomeFinished: onWelcomeFinished
        ))
    }
}
