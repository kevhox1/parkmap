//
//  WPSheetSizing.swift
//  WePark
//
//  R35 PR4 (docs/specs/r35-map-polish-and-trip-destination.md): Stoop sheets that open exactly as
//  tall as their content instead of at a fixed half screen. A fixed `.medium` sheet whose content is
//  shorter than half the screen leaves dead space (the Penn Station card in build 35).
//
//  The content reports its own height (`wpReportHeight`), the sheet turns that into one custom
//  detent clamped to a sensible range, and `.large` stays available so the user can drag up. When
//  the content is taller than the detent, the card's own ScrollView scrolls (it only scrolls when
//  it has to, `.basedOnSize`).
//
//  The pure rules live in `WPSheetSizing` (`nonisolated`: the project defaults to MainActor
//  isolation and the tests call these synchronously).
//

import SwiftUI
import UIKit

nonisolated enum WPSheetSizing {
    /// A sheet never opens shorter than this, so a near-empty card still has a drag handle and room.
    static let defaultMinimum: CGFloat = 260
    /// Tallest content-sized detent, as a share of the screen. Past this the user drags to `.large`.
    static let maxScreenFraction: CGFloat = 0.85
    /// Height changes smaller than this are ignored (layout noise), so the sheet does not jitter.
    static let changeThreshold: CGFloat = 2

    /// Measured content height turned into a detent height: rounded to a whole point, never under
    /// `minimum`, never over 85% of the screen. NaN, infinity or a non-positive measurement fall
    /// back to `minimum` (the sheet never gets an unusable detent).
    static func clamp(measured: CGFloat, screenHeight: CGFloat, minimum: CGFloat = defaultMinimum) -> CGFloat {
        let floorValue = minimum.isFinite ? max(0, minimum) : defaultMinimum
        guard measured.isFinite, measured > 0 else { return floorValue }
        let rounded = measured.rounded()
        guard screenHeight.isFinite, screenHeight > 0 else { return max(floorValue, rounded) }
        let ceiling = max(floorValue, (screenHeight * maxScreenFraction).rounded(.down))
        return min(max(rounded, floorValue), ceiling)
    }

    /// True when a new measurement is different enough from the stored one to store.
    static func shouldUpdate(current: CGFloat, new: CGFloat) -> Bool {
        guard new.isFinite, new >= 0 else { return false }
        return abs(new - current) >= changeThreshold
    }

    /// The screen's height in points (0 when no scene is connected; `clamp` handles that).
    @MainActor
    static var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
            .first ?? 0
    }
}

// MARK: - Reporting a height

extension View {
    /// Reports this view's height into `height` (whole points, changes under 2 pt ignored).
    /// Put it on the content INSIDE a ScrollView (its ideal height) and on any pinned footer.
    func wpReportHeight(into height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
            let rounded = newValue.rounded()
            if WPSheetSizing.shouldUpdate(current: height.wrappedValue, new: rounded) {
                height.wrappedValue = rounded
            }
        }
    }

    /// Reports the bottom safe-area inset (home indicator) the sheet adds below its content.
    func wpReportBottomInset(into inset: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { newValue in
            let rounded = newValue.rounded()
            if WPSheetSizing.shouldUpdate(current: inset.wrappedValue, new: rounded) {
                inset.wrappedValue = rounded
            }
        }
    }

    /// Presents the sheet at its content height plus `.large`. `measured` is the full sheet height
    /// the content wants (content + footer + bottom inset). `largeOnly` (accessibility sizes) skips
    /// the content detent. Map interaction stays on beside the card up to the content detent.
    @ViewBuilder
    func wpContentSizedSheet(
        measured: CGFloat,
        minimum: CGFloat = WPSheetSizing.defaultMinimum,
        largeOnly: Bool = false
    ) -> some View {
        if largeOnly {
            presentationDetents([.large])
        } else {
            let height = WPSheetSizing.clamp(
                measured: measured, screenHeight: WPSheetSizing.screenHeight, minimum: minimum
            )
            presentationDetents([.height(height), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(height)))
        }
    }
}
