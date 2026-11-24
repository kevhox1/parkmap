//
//  ClipPresentationRules.swift
//  Shared/SpotPass/Driver
//
//  Pure, unit-tested presentation rules for the clip's screens (the views only apply them):
//    - which CTAs stay pinned at the bottom of the choosing screen (never more than ~30% of the
//      screen, so the scrolled content is never squeezed or covered at accessibility sizes), and
//    - when the armed screen flips to "Time to go?".
//

import SwiftUI

nonisolated enum ClipCTAPinning {

    /// What stays pinned under the scroll content.
    enum Plan: Equatable, Sendable {
        /// Primary CTA, the one-line reassurance and "Not leaving soon".
        case full
        /// Primary CTA only; the rest moves into the scroll content (like the seeker badge's
        /// `pinsStopButton` fix in PR #165).
        case primaryOnly
    }

    /// The pinned area may take at most this share of the screen height.
    static let maxPinnedFraction: CGFloat = 0.30

    /// The pinned label is clamped to this size so the primary CTA stays bounded
    /// (the scroll content keeps scaling to the user's real size).
    static let pinnedTypeSizeCap: DynamicTypeSize = .xxxLarge

    static func plan(
        screenHeight: CGFloat, dynamicTypeSize: DynamicTypeSize, hasInlineError: Bool, hasReassurance: Bool = true
    ) -> Plan {
        // Accessibility sizes: the primary CTA only. The secondary action scrolls with the content.
        if dynamicTypeSize.isAccessibilitySize { return .primaryOnly }
        let height = estimatedPinnedHeight(
            .full, screenHeight: screenHeight, dynamicTypeSize: dynamicTypeSize, hasInlineError: hasInlineError,
            hasReassurance: hasReassurance
        )
        return height <= screenHeight * maxPinnedFraction ? .full : .primaryOnly
    }

    /// Conservative height estimate (points) of the pinned stack for a plan.
    static func estimatedPinnedHeight(
        _ plan: Plan, screenHeight: CGFloat, dynamicTypeSize: DynamicTypeSize, hasInlineError: Bool,
        hasReassurance: Bool = true
    ) -> CGFloat {
        let isShort = screenHeight < SpotPassTheme.shortScreenHeight
        let base = isShort ? SpotPassTheme.compactHeroButtonHeight : SpotPassTheme.heroButtonHeight
        let capped = min(dynamicTypeSize, pinnedTypeSizeCap)
        let lines: CGFloat
        switch capped {
        case .xSmall, .small, .medium, .large: lines = 1
        case .xLarge, .xxLarge: lines = 2
        default: lines = isShort ? 3 : 2          // xxxLarge
        }
        let primary = max(base, lines * 26 + 32)
        let error: CGFloat = hasInlineError ? 40 : 0
        let padding: CGFloat = 16
        switch plan {
        case .primaryOnly:
            return primary + error + padding
        case .full:
            let reassurance: CGFloat = hasReassurance ? 18 : 0
            let secondary: CGFloat = 56
            return primary + error + reassurance + secondary + 3 * 6 + padding
        }
    }
}

nonisolated enum ClipArmedPresentation {

    /// The armed screen shows "You're on" until the chosen leave time, then "Time to go?".
    static func isTimeToGo(leaveAt: Date, now: Date) -> Bool { now >= leaveAt }
}
