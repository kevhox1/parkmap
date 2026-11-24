//
//  ClipRootView.swift
//  WePark Clip
//
//  Renders `ClipFlowController.phase`. Owns the cross-screen pieces: the cancel confirmation, the
//  toast, the once-per-launch install overlay (SKOverlay), and the expiry tick.
//

import SwiftUI
import StoreKit

struct ClipRootView: View {
    @Bindable var controller: ClipFlowController
    let block: ClipBlockController

    @State private var installOverlay = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ClipBackdrop()
                content
            }
            .environment(\.clipIsShortScreen, geometry.size.height < SpotPassTheme.shortScreenHeight)
            .environment(\.clipScreenHeight, geometry.size.height)
        }
        .preferredColorScheme(.dark)
        .tint(SpotPassTheme.indigo)
        .overlay(alignment: .bottom) { toastView }
        .confirmationDialog(
            ClipCopy.notLeavingAfterAll, isPresented: $controller.showCancelConfirm, titleVisibility: .visible
        ) {
            Button(ClipCopy.cancelMyPass) { Task { await controller.confirmCancel() } }
            Button(ClipCopy.keepIt, role: .cancel) {}
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
            ClipChoosingView(controller: controller) { reason in Task { await controller.report(reason) } }
        case .armed:
            ClipArmedView(controller: controller, block: block)
        case .pullingOut, .sending, .sent:
            ClipPullingOutView(controller: controller)
        case .celebration:
            ClipCelebrationView(controller: controller) {
                controller.dismissInstallCard()
                installOverlay = true
            }
        default:
            ClipMessageView(
                content: ClipMessageContent.content(for: controller.phase),
                onRetry: { controller.retry() },
                onWhatsWePark: { installOverlay = true }
            )
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = controller.toast {
            Text(toast)
                .font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(.thinMaterial, in: Capsule())
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
