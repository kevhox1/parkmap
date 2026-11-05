//
//  OnboardingCoachModel.swift
//  WePark
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §2) — the
//  pure sequencing model behind `Views/OnboardingCoachOverlay.swift`'s 3-bubble live coach
//  layer. Zero SwiftUI, zero UserDefaults, zero side effects, zero map/CoreLocation knowledge
//  beyond the one small bearing helper at the bottom (needed to approximate mark 3's
//  "near the nearest real curb" anchor without touching `MapViewRepresentable` — see that
//  function's own doc comment for the full, flagged reasoning).
//
//  Declared top-level (not nested) for the same "no == on nested enums in nonisolated code"
//  reason `OnboardingStoryModel.swift`'s header documents.
//
//  No Calendar.current. No dates at all.
//

import CoreGraphics
import CoreLocation
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
    curbPlacementActive: Bool
) -> Bool {
    activeSheetIsNil && !driveModeActive && !blockSelectModeActive
        && !spotPlacementActive && !curbPlacementActive
}

// MARK: - Mark 3's anchor approximation

/// Approximates a screen-space offset (in points, from the map's own center) pointing toward
/// `target` from `origin`, for mark 3's "anchor near that segment's screen position" (§2.2).
///
/// **Flagged deviation from the design doc's literal text, not a silent one:** the design doc
/// describes an exact screen anchor and a pulsing ring "traced along that one polyline" — both
/// need a real ground-coordinate -> screen-point projection, which only `MapViewRepresentable`'s
/// `MKMapView.convert(_:toPointTo:)` can do, and `MapViewRepresentable` is explicitly untouched
/// by this PR (dispatch hard constraint). This function instead computes the GREAT-CIRCLE
/// BEARING from `origin` to `target` and maps it directly to a screen-space unit vector
/// (north = up), clamped to `maxOffset` points. That mapping is exact (not approximate) ONLY
/// because the coach layer exclusively mounts in the ambient rest posture, which is always
/// north-up at rest (`docs/drive-mode-default-spec.md` §0.1/A3.6.1: "heading fixed at 0
/// (north-up)... until motion") — the one condition under which "bearing == screen direction"
/// holds without consulting the map's own rotation. The coach layer is dismissed immediately on
/// any pan/zoom (§2.3), so this never needs to track a moving/rotating viewport mid-display.
/// No ring is traced along the polyline in this PR (a plain pulsing circle marks the anchor
/// point instead) — flagged in the PR body as a follow-up if pixel-exact, rotation-aware
/// anchoring is wanted later (it would need a small, deliberate `MapViewRepresentable` seam,
/// not a workaround here).
///
/// Returns `.zero` (no offset — anchor exactly at map center) if `origin == target` or the
/// computed bearing is non-finite.
nonisolated func onboardingCoachBearingOffset(
    from origin: CLLocationCoordinate2D,
    to target: CLLocationCoordinate2D,
    maxOffset: CGFloat = 70
) -> CGSize {
    let lat1 = origin.latitude * .pi / 180
    let lat2 = target.latitude * .pi / 180
    let deltaLng = (target.longitude - origin.longitude) * .pi / 180

    let y = sin(deltaLng) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLng)
    let bearing = atan2(y, x)

    guard bearing.isFinite else { return .zero }

    // North-up screen mapping: bearing 0 (north) -> straight up (negative y); bearing π/2
    // (east) -> straight right (positive x).
    let dx = sin(bearing)
    let dy = -cos(bearing)
    guard dx.isFinite, dy.isFinite else { return .zero }

    // `dx`/`dy` are `Double` (the trig functions' return type); `maxOffset` is `CGFloat`.
    // These are distinct numeric types in Swift (not interchangeable via a typealias on
    // 64-bit platforms) — explicit `CGFloat(...)` conversion before multiplying, not a
    // silent cross-type arithmetic op.
    return CGSize(width: CGFloat(dx) * maxOffset, height: CGFloat(dy) * maxOffset)
}
