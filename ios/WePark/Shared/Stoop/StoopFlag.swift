//
//  StoopFlag.swift
//  Shared/Stoop: compiled into the full app, the App Clip and both Live Activities extensions.
//
//  The single source of truth for the Stoop redesign flag. The clip and the Live Activity
//  extensions are separate processes that cannot read the app's runtime state, so the flag is a
//  COMPILE-TIME constant shared by every target (one edit flips all four, and a clip / activity
//  can never disagree with the app about which design is live). `AppConstants.designSystemV2Enabled`
//  forwards here; the guard test `DesignSystemV01Tests.testFlag_defaultsFalse` pins it to false.
//
//  Isolation: `nonisolated` so extensions, tests and background code can read it under the
//  project's MainActor default isolation.
//

import Foundation

nonisolated enum StoopFlag {
    /// Default false: the shipping design. Flip only when Kevin has compared the two.
    static let designSystemV2Enabled = false
}
