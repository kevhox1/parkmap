//
//  OnboardingCoachModel.swift
//  WePark
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §2) — the
//  pure sequencing model behind `Views/OnboardingCoachOverlay.swift`'s 3-bubble live coach
//  layer. Zero SwiftUI, zero UserDefaults, zero side effects, zero map/CoreLocation knowledge.
//  (Mark 3's anchor is a real ground->screen projection via
//  `MapViewRepresentable.CoordinatorActions.screenPointForCoordinate`; the old bearing
//  approximation was removed in the QA follow-up.)
//
//  Declared top-level (not nested) for the same "no == on nested enums in nonisolated code"
//  reason `OnboardingStoryModel.swift`'s header documents.
//
//  No Calendar.current. No dates at all.
//

import CoreGraphics
import Foundation

/// The named `.coordinateSpace` both `GoalSelectorView`'s dock/tile-row/selected-tile geometry
/// readouts and `OnboardingCoachOverlay`'s bubble positioning share, so a frame measured on one
/// side of `ContentView`'s view tree means the same thing read on the other side. Declared once,
/// here, so the two files can never silently drift to different string literals.
let onboardingCoachCoordinateSpaceName = "OnboardingCoachSpace"

// MARK: - OnboardingCoachMark

/// One of the 3 anchored coach bubbles, in display order (design doc §2.2).
enum OnboardingCoachMark: Int, CaseIterable, Equatable {
    /// Target: the goal tile row. "Pick what you need." / "The map will only show spots that
    /// match."
    case goalTiles = 0
    /// Target: the selected (Overnight) tile + the map's green/red cast. "Green means you're
    /// covered. Red means you'll have to move it."
    case colorMeaning = 1
    /// Target: the nearest real curb segment to the user's blue dot (or the map's visual
    /// center fallback). "Tap any block to see why."
    case tapABlock = 2

    /// Exact bubble headline, §2.2 — verbatim, not paraphrased.
    nonisolated var title: String {
        switch self {
        case .goalTiles: return "Pick what you need."
        case .colorMeaning: return "Green means you're covered. Red means you'll have to move it."
        case .tapABlock: return "Tap any block to see why."
        }
    }

    /// Exact bubble sub-copy, §2.2. `nil` for marks with no second line (mark 3 is one line).
    nonisolated var subtitle: String? {
        switch self {
        case .goalTiles: return "The map will only show spots that match."
        case .colorMeaning: return nil
        case .tapABlock: return nil
        }
    }

    /// The bubble's one primary action label — "Got it" on marks 1-2, "Done" on mark 3 (§2.3).
    nonisolated var primaryActionLabel: String {
        switch self {
        case .goalTiles, .colorMeaning: return "Got it"
        case .tapABlock: return "Done"
        }
    }

    /// Whether tapping a goal tile counts as "tapping the real control this bubble points at"
    /// (§2.3): true for marks 1 AND 2 — the goal-tile row IS mark 1's target, and the selected
    /// tile IS mark 2's target, and both are the same physical control family.
    nonisolated var dismissedByGoalTileTap: Bool {
        switch self {
        case .goalTiles, .colorMeaning: return true
        case .tapABlock: return false
        }
    }
}

// MARK: - Pure sequencing (§2.2/§2.3)

/// The first mark shown when the coach layer (re)appears — always mark 1, both for a fresh
/// first-run sequence and for a manual "How WePark works" replay (§3.2).
nonisolated func onboardingCoachFirstMark() -> OnboardingCoachMark { .goalTiles }

/// The mark that follows `mark`, or `nil` if `mark` is already the last mark (meaning its
/// primary action / a matching real-control tap finishes the whole layer instead of advancing).
nonisolated func onboardingCoachNextMark(after mark: OnboardingCoachMark) -> OnboardingCoachMark? {
    OnboardingCoachMark(rawValue: mark.rawValue + 1)
}

// MARK: - Pure gating (design doc §6 / §2.3)

/// Whether the coach layer should mount at all on this launch (or replay path): both onboarding
/// flags are on AND the one-shot gate has never fired. Mirrors `onboardingStoryShouldShow`
/// exactly — see that function's own doc comment.
nonisolated func onboardingCoachShouldShow(
    onboardingStoryEnabled: Bool,
    driveModeDefaultEnabled: Bool,
    gateShouldShow: Bool
) -> Bool {
    AppConstants.onboardingExperienceEnabled(
        onboardingStoryEnabled: onboardingStoryEnabled,
        driveModeDefaultEnabled: driveModeDefaultEnabled
    ) && gateShouldShow
}

/// Rest-posture-only mount eligibility (§2.3: "mount only when `!driveModeActive &&
/// !blockSelectModeActive && !spotPlacementActive`" — the identical exclusion list the ambient
/// dock itself already uses, `goalSelectorDockVisible` in `ContentView.swift`). Also excludes
/// curb-pin placement mode and any other sheet being presented, for the same z-order/focused-
/// task reasons `goalSelectorDockVisible` itself documents — the coach layer anchors to the
/// ambient dock, so it has no reason to exist whenever the dock itself wouldn't be mounted.
///
/// `nonisolated` for the same sync-XCTest reason every pure gating function in this file is.
nonisolated func onboardingCoachOverlayVisible(
    activeSheetIsNil: Bool,
    driveModeActive: Bool,
    blockSelectModeActive: Bool,
    spotPlacementActive: Bool,
    curbPlacementActive: Bool,
    primingCardShowing: Bool = false
) -> Bool {
    // QA #1: order is cards -> priming -> coach; the coach never mounts over LocationPrimingCard.
    activeSheetIsNil && !driveModeActive && !blockSelectModeActive
        && !spotPlacementActive && !curbPlacementActive && !primingCardShowing
}

// MARK: - Selected-tile frame (QA #5)

/// The selected goal tile's frame, derived from EVERY tile's last-reported frame so it can
/// never go stale when only the selection (not the geometry) changes. `.zero` ("not measured")
/// when the selected tile has not reported yet.
nonisolated func onboardingSelectedTileFrame(
    tileFrames: [String: CGRect],
    selectedGoalRawValue: String
) -> CGRect {
    tileFrames[selectedGoalRawValue] ?? .zero
}

// MARK: - Bubble layout (QA #3/#4)

/// Horizontal margin kept between a bubble and the safe-area edges.
nonisolated let onboardingCoachBubbleHorizontalMargin: CGFloat = 20

/// Maximum bubble width (matches the pre-fix `.frame(maxWidth: 320)`).
nonisolated let onboardingCoachBubbleMaxWidth: CGFloat = 320

/// The bubble's width: capped at `onboardingCoachBubbleMaxWidth`, and never wider than the
/// safe-area width minus both margins.
nonisolated func onboardingCoachBubbleWidth(safeWidth: CGFloat) -> CGFloat {
    max(0, min(onboardingCoachBubbleMaxWidth, safeWidth - 2 * onboardingCoachBubbleHorizontalMargin))
}

/// The bubble's horizontal CENTER: `anchorX` clamped so the whole bubble (width `bubbleWidth`)
/// stays inside `[safeMinX + margin, safeMaxX - margin]`. A `nil` anchor centers it.
nonisolated func onboardingCoachBubbleCenterX(
    anchorX: CGFloat?,
    bubbleWidth: CGFloat,
    safeMinX: CGFloat,
    safeMaxX: CGFloat
) -> CGFloat {
    let lower = safeMinX + onboardingCoachBubbleHorizontalMargin + bubbleWidth / 2
    let upper = safeMaxX - onboardingCoachBubbleHorizontalMargin - bubbleWidth / 2
    guard let anchorX else { return (safeMinX + safeMaxX) / 2 }
    guard lower <= upper else { return (safeMinX + safeMaxX) / 2 }
    return min(max(anchorX, lower), upper)
}

/// Whether mark 3's bubble sits ABOVE its anchor (true) or below it (false): above when there
/// are at least `minimumHeight` points between `topLimit` and the gap above the anchor.
nonisolated func onboardingCoachBubbleFitsAbove(
    anchorY: CGFloat,
    topLimit: CGFloat,
    gap: CGFloat,
    minimumHeight: CGFloat
) -> Bool {
    anchorY - gap - topLimit >= minimumHeight
}

/// Whether a projected screen point lies inside `bounds` (inset by `inset`) - mark 3 draws a
/// ring only for an on-screen curb point; otherwise the bubble is placed with no ring.
nonisolated func onboardingCoachPointIsOnScreen(_ point: CGPoint, in bounds: CGRect, inset: CGFloat = 24) -> Bool {
    bounds.insetBy(dx: inset, dy: inset).contains(point)
}
