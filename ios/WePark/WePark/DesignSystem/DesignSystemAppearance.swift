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
//  OPEN ITEM for the flag-flip phase: the build-setting key is compile-time and cannot follow the
//  flag. With the flag on, Drive Mode's explicit `.dark` is unaffected, but browse's `.unspecified`
//  may still resolve to the build-setting's Dark instead of the system / light default. Resolving that
//  (drop the key and force dark at the window when the flag is off) changes flag-off launch
//  behavior, so it is deliberately NOT done in the foundation PR.
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
