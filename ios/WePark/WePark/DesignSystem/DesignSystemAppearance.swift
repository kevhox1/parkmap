//
//  DesignSystemAppearance.swift
//  WePark
//
//  Design system v0.1 appearance rule (README "Colour"): light by default, dark for Drive Mode
//  and system dark. Applies ONLY while `AppConstants.designSystemV2Enabled` is true; with the
//  flag off this type does nothing and the app keeps today's forced-dark behavior
//  (`INFOPLIST_KEY_UIUserInterfaceStyle = Dark` in the app target's build settings plus
//  `.preferredColorScheme(.dark)` at the root; both pre-date this design system).
//
//  Phase 2a resolved the open item: the app target's `INFOPLIST_KEY_UIUserInterfaceStyle = Dark`
//  build setting is REMOVED (it was compile-time and could not follow the flag). Today's forced
//  dark is now applied at the window, synchronously when the window is attached (before the first
//  frame), by `WindowAppearanceApplier`: flag off -> `.dark` (same as the old key, which forced
//  system alerts, the keyboard and share sheets dark); flag on -> `.unspecified` (follows the
//  system). The launch screen (the one thing that exists before any window) is pinned to black via
//  Info.plist `UILaunchScreen.UIColorName = LaunchBackground` (a black color set), which is
//  what the dark launch screen was. FLAG-FLIP TODO: give that color set a light variant (cream)
//  when the flag ships on, so light-mode users don't see a black launch.
//
//  Mechanism: set `overrideUserInterfaceStyle` on the app's windows. Drive Mode forces `.dark`;
//  otherwise `.unspecified` hands the window back to the system setting. Called from
//  ContentView's existing `.onChange(of: driveModeActive)` / appear handlers, never from
//  `MapViewRepresentable.updateUIView` (no UIKit mutation inside the SwiftUI update cycle).
//

import SwiftUI
import UIKit

enum DesignSystemAppearance {

    /// The root `.preferredColorScheme`. Flag off: `.dark`, exactly today's FT-20 forced dark.
    /// Flag on: nil, so the per-window override in `apply` (light browse / dark Drive Mode) decides.
    nonisolated static func preferredColorScheme(
        enabled: Bool = AppConstants.designSystemV2Enabled
    ) -> ColorScheme? {
        enabled ? nil : .dark
    }

    /// Pure decision: Drive Mode is always dark; browse follows the system (light by default).
    nonisolated static func interfaceStyle(driveModeActive: Bool) -> UIUserInterfaceStyle {
        driveModeActive ? .dark : .unspecified
    }

    /// The window style the app starts with and returns to outside Drive Mode.
    /// Flag off: `.dark` (today's forced dark). Flag on: `.unspecified` (system light / dark).
    nonisolated static func baseInterfaceStyle(
        enabled: Bool = AppConstants.designSystemV2Enabled
    ) -> UIUserInterfaceStyle {
        enabled ? .unspecified : .dark
    }

    /// Applies the style to every window of every connected scene. No-op while the flag is off.
    @MainActor
    static func apply(driveModeActive: Bool, enabled: Bool = AppConstants.designSystemV2Enabled) {
        guard enabled else { return }
        let style = interfaceStyle(driveModeActive: driveModeActive)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

// MARK: - Window attach hook

/// Sets the base interface style on the window the moment it is attached, before the first frame.
/// Put it in the root view's `.background`. This replaces the removed Info.plist
/// `UIUserInterfaceStyle = Dark` key for flag-off builds.
struct WindowAppearanceApplier: UIViewRepresentable {
    func makeUIView(context: Context) -> ApplierView { ApplierView() }
    func updateUIView(_ uiView: ApplierView, context: Context) {}

    final class ApplierView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.overrideUserInterfaceStyle = DesignSystemAppearance.baseInterfaceStyle()
        }
    }
}
