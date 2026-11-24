//
//  GoalSelectorView.swift
//  WePark
//
//  DM-2 (`docs/drive-mode-default-spec.md` §0.8, `docs/design/goal-first-ambient-design.md`)
//  — the goal-first ambient home screen's centerpiece bottom dock: the full-palette toggle,
//  the demoted "Start Driving" escalation affordance, the empty-map guard banner (§0.8.10),
//  and the three big goal tiles (§0.8.1).
//
//  Pure presentation. Every piece of real decision-making (which goal is active, what the
//  empty-map guard state should be, whether to escalate into Cruise) lives in `ContentView`
//  and is handed down as plain values + closures — this file never reads `AppConstants`,
//  never touches `ParkingRulesEngine`/`ParkingGoals` directly, and owns zero persistent
//  state of its own. Matches this codebase's `LocationPrimingCard`/`ParkUntilPill` convention
//  of "caller owns the gate/state, this view is pure presentation."
//
//  Copy/icons/layout are @designer's, verbatim from `docs/design/goal-first-ambient-design.md`
//  §1/§2 — not improvised here. The one deliberate departure from this codebase's existing
//  fixed-`.system(size:)` icon convention (§2.5 of that doc) is intentional: every font here
//  is a semantic, Dynamic-Type-scalable style (`.headline`, `.caption`, `.title2`, etc.),
//  because Kevin's own bar for this screen ("anyone who boots it up should get it") is
//  undermined if a Large-Text accessibility user is the one person these "biggest,
//  unmistakable" buttons don't scale for.
//
//  Mounted ONLY via `ContentView.bottomSafeAreaContent`'s new goal-dock row — ambient-only
//  (§0.8.7), gated on `goalSelectorDockVisible(...)` (`ContentView.swift`), which already
//  excludes Drive Mode / block-select / spot-placement / any other sheet being presented —
//  same "one bottom dock at a time" discipline that file's own `bottomSafeAreaContent` VStack
//  already enforces between ITS rows (design doc §6 flag #4).
//
//  No Calendar.current. No new map-rendering code — this view only calls back into
//  `ContentView`'s EXISTING `parkUntilMode`/`parkUntilTarget` → `rebuildOverlays()` path via
//  its closures (§0.8.6).
//
//  Live-smoke fix (Kevin, 2026-10-20, PR #133 flag-on cold launch, iPhone 17 sim): this
//  struct's own `body` was already ONE `VStack` mounted through `ContentView`'s single
//  `.safeAreaInset(edge: .bottom)` on `mapRepresentable` — not loose overlays — so no
//  restructuring of ITS mounting was needed here. The real bugs were (1) `startDrivingRow`
//  relying solely on `.buttonStyle(.bordered)`'s implicit fill, which read as unreadable text
//  on a live map (fixed below, added an explicit `.regularMaterial` backdrop) and (2) a
//  SEPARATE, pre-existing floating layer in `ContentView` — the persistent Report pill / "?"
//  map-key button (`communityMapChromeOverlay`) — using a fixed clearance sized for the FT-20
//  browse sheet's peek detent, which never accounted for THIS dock's height and drew on top
//  of its tile row.
//
//  Addendum 2 (2026-10-21 smoke revisions, A2.1 item 2): PR #134's fix above (a hand-maintained
//  clearance constant in `ContentView.swift`) is superseded here. The Report pill now lives
//  INSIDE this view's own `VStack`, sharing its top row with the full-palette toggle — a true
//  sibling the `VStack` lays out top-to-bottom same as every other row, so it rides the dock's
//  real rendered height for free (Dynamic Type growth, the empty-map guard banner appearing,
//  the tile row hiding in full-palette mode all just push/pull this row the normal SwiftUI
//  way — no clearance constant to go stale). `ContentView` still owns the Report pill's
//  button (`reportPillButton` — unchanged component, same action/styling/accessibility) and
//  hands it to this view via the generic `reportPill` trailing-closure parameter below, same
//  "caller owns the gate/state, this view is pure presentation" convention this file's header
//  already commits to — `GoalSelectorView` never needs to know what Report actually DOES.
//
//  Addendum 2 (A2.2): also adds `GoalParkUntilPill` — a parallel, NEW view (not a change to
//  the existing `ParkUntilPill` in `Views/ParkUntilSheet.swift`) that renders the icon +
//  short-name + "Good through <day>"/time clause content the addendum specs for the
//  escalated-Cruise pill slot, when the active filter came from a goal tap. Pure presentation,
//  same as everything else in this file — it takes the already-resolved `icon`/`shortName`/
//  `trailingClause` strings as plain input; `ContentView.goalPillContent(for:target:now:)` is
//  the one place that actually touches `ParkingGoals.relativeDayLabel`/`ParkUntilSheet
//  .formatTime` to produce them, keeping those engine/formatter touches in `ContentView.swift`
//  (which already owns the parallel per-segment case, `goalGoodThroughLabel`) rather than in
//  this file. Built as a separate view here, rather than adding a parameter to `ParkUntilPill`
//  itself (the addendum's own literal suggestion), specifically so this change stays inside
//  this stream's file allowlist (`ContentView.swift`/`GoalSelectorView.swift`/tests) without
//  touching `ParkUntilSheet.swift` — flagged explicitly in this PR's description, not a silent
//  substitution. `ContentView`'s call site picks between this view and the untouched
//  `ParkUntilPill` based on whether the active filter came from a goal (§ "activeGoal" below).
//

//  Addendum 3 (2026-10-23 minimal ambient screen, A3.3, flag-on only — this view never mounts
//  flag-off): Kevin's smoke verdict on the Addendum 2 screen was "too many buttons and icons."
//  The Report + full-palette top row is DELETED from this dock (Report and the "Show all
//  parking rules" toggle now live in `MoreMenuSheet`, opened from the rail's More button), so
//  the dock is exactly: [empty-map guard] -> Start Driving -> goal tiles. The `reportPill`
//  generic slot Addendum 2 added is gone with it (this struct is no longer generic). Tiles grow
//  to a 128pt minimum height with bigger type and reflow to a vertical stack at accessibility
//  Dynamic Type sizes; a selection haptic confirms a goal pick. In full-palette mode the tile
//  row is replaced by a "Pick a parking goal" row so the user is never stranded.
//

//  Addendum 4 (2026-11-23, open item #37 6, `docs/design/goal-first-ambient-design.md`
//  "Addendum - accessibility-size goal dock"): at `dynamicTypeSize >= .accessibility1` the
//  three-tile row collapses to ONE full-width current-goal card (`GoalCard`) that opens a
//  LOCAL goal sheet (`GoalPickerSheet`, state lives here, NOT in `ContentView.activeSheet`,
//  because `goalSelectorDockVisible` hides the dock whenever `activeSheet != nil`). The dock's
//  own content is capped at `.accessibility3`; the sheet scales to AX5. Below
//  `.accessibility1` nothing here changes.
//

import SwiftUI

// MARK: - Accessibility-size dock rules (Addendum 4)

/// True when the dock should render the collapsed two-row layout (Start Driving + goal card).
/// Full-palette mode keeps its own "Pick a parking goal" row at every size.
nonisolated func goalDockUsesGoalCard(dynamicTypeSize: DynamicTypeSize, fullPaletteMode: Bool) -> Bool {
    dynamicTypeSize.isAccessibilitySize && !fullPaletteMode
}

/// The card shows its sub-label at AX1/AX2 only; `>= .accessibility3` drops it from the CARD
/// (it stays in the sheet and in the card's accessibility label). Dropping is not truncation.
nonisolated func goalCardShowsSubLabel(dynamicTypeSize: DynamicTypeSize) -> Bool {
    dynamicTypeSize < .accessibility3
}

/// Budget fallback #2 (design addendum section 4): the card's "Change" word goes at the same
/// threshold as the sub-label; the `chevron.up` stays so it still reads as a picker. Measured:
/// with the word, "Park & Forget" wraps to two lines at AX3 and the dock lands at 40.5% of an
/// 874pt screen (over the 40% budget); without it, 29.5%.
///
/// Follow-up (design amendment section 3): at AX2 with the banner chip showing, the word also
/// goes (dock ~344pt + 48pt chip would sit on the 45% limit). AX1 with a chip keeps it (~38.7%).
nonisolated func goalCardShowsChangeWord(
    dynamicTypeSize: DynamicTypeSize,
    bannerChipShowing: Bool = false
) -> Bool {
    guard dynamicTypeSize < .accessibility3 else { return false }
    return !(bannerChipShowing && dynamicTypeSize >= .accessibility2)
}

/// Amendment section 3: at AX1+ the empty-map banner collapses to a one-line chip (the full
/// sentence moves to the goal sheet's first row). Below AX1 the full banner is unchanged.
/// Tied to the goal-card layout because the chip opens the same local sheet the card does.
nonisolated func goalDockUsesBannerChip(dynamicTypeSize: DynamicTypeSize, fullPaletteMode: Bool) -> Bool {
    goalDockUsesGoalCard(dynamicTypeSize: dynamicTypeSize, fullPaletteMode: fullPaletteMode)
}

/// Gap between the chip and Start Driving (amendment section 3).
nonisolated let goalBannerChipGapAboveStartDriving: CGFloat = 4

/// Minimum chip height (big touch target; amendment section 3).
nonisolated let goalBannerChipMinHeight: CGFloat = 44

/// QA #5 (PR #152): the medium detent shows one full tile at AX4+, so the sheet opens at
/// `.large` there. Pure so it is testable.
nonisolated func goalSheetOpensLarge(dynamicTypeSize: DynamicTypeSize) -> Bool {
    dynamicTypeSize >= .accessibility4
}

extension ParkingGoal {
    /// Dock copy/icons, locked by `docs/design/goal-first-ambient-design.md` section 1 (hoisted
    /// out of `GoalTile` so the card, the sheet and tests share ONE source).
    nonisolated var dockIcon: String {
        switch self {
        case .freeOvernight: return "moon.stars.fill"
        case .freeFewHours: return "hourglass"
        case .parkAndForget: return "parkingsign.circle.fill"
        }
    }

    nonisolated var dockPrimary: String {
        switch self {
        case .freeOvernight: return "Overnight"
        case .freeFewHours: return "A Few Hours"
        case .parkAndForget: return "Park & Forget"
        }
    }

    nonisolated var dockSubLabel: String {
        switch self {
        case .freeOvernight: return "Won't need to move it"
        case .freeFewHours: return "No meter, no cost"
        case .parkAndForget: return "Go days without moving it"
        }
    }

    /// The goal card's VoiceOver label (Addendum 4 flag 3). Always carries the sub-label, even
    /// when the card hides it visually.
    nonisolated var goalCardAccessibilityLabel: String {
        "\(dockPrimary), \(dockSubLabel). Selected. Double tap to change goal."
    }
}

/// Frame report from the AX goal card. Carries the selected goal so a selection change with an
/// unchanged frame still re-fires `onGeometryChange` (the tile dictionary key must follow the
/// selection).
private nonisolated struct GoalCardFrameReport: Equatable {
    let frame: CGRect
    /// `ParkingGoal.rawValue` (a plain `String`) rather than the enum, so this value type is
    /// freely `Sendable`/`Equatable` for `onGeometryChange` under MainActor default isolation.
    let goalRawValue: String
}

// MARK: - EmptyMapGuardKind

/// The two empty-map-guard banner states (§0.8.10, design doc §3.2). `nil` (no case shown)
/// means Park & Forget's viewport resolution cleared its top rung cleanly, or the active
/// goal isn't Park & Forget at all — no banner either way.
enum EmptyMapGuardKind: Equatable {
    /// The ladder stepped down from the top rung but still found SOME match at a lower rung.
    /// Design doc §3.2: "Nothing clear for a full week nearby — showing the best available."
    case steppedDown
    /// Density-only sub-case (design doc addendum 2026-11-22): the top rung was KEPT but only a
    /// few blocks clear it. Must not claim a step-down happened. Same icon/styling as
    /// `.steppedDown`.
    case sparse
    /// Even the bottom (easiest) rung found zero matches anywhere in the viewport — the
    /// true-empty state. Design doc §3.2: "No clear spots found very nearby — try Overnight,
    /// or pan the map."
    case empty

    /// Banner icon (SF Symbol). `nonisolated` so sync XCTests can read it.
    nonisolated var bannerIcon: String {
        switch self {
        case .steppedDown, .sparse: return "info.circle.fill"
        case .empty: return "mappin.slash"
        }
    }

    /// One-line chip copy for the AX dock (amendment section 3). Complete short phrases, not
    /// clipped sentences; the full sentence (`bannerCopy`) is the chip's VoiceOver label and the
    /// goal sheet's first row.
    nonisolated var chipCopy: String {
        switch self {
        case .steppedDown: return "Showing best available"
        case .sparse: return "Only a few blocks clear"
        case .empty: return "No clear spots nearby"
        }
    }

    /// Banner copy, locked in `docs/design/goal-first-ambient-design.md` (§3.2 + 2026-11-22
    /// addendum).
    nonisolated var bannerCopy: String {
        switch self {
        case .steppedDown:
            return "Nothing clear for a full week nearby — showing the best available."
        case .sparse:
            return "Only a few blocks nearby are clear for a full week."
        case .empty:
            return "No clear spots found very nearby — try Overnight, or pan the map."
        }
    }
}

// MARK: - GoalSelectorView

struct GoalSelectorView: View {

    /// The currently active goal (always has a value — "no goal" isn't a state this dock
    /// represents; `fullPaletteMode` is the orthogonal "goal-first vs. full-palette" switch).
    let selectedGoal: ParkingGoal

    /// True once the user has toggled OUT of goal-first (§0.8.8, via the More sheet's
    /// "Show all parking rules" row). The goal-tile row hides entirely in this state and is
    /// replaced by the "Pick a parking goal" row; "Start Driving" stays visible and functional
    /// (design doc §2.3's note; Addendum 3 A3.3).
    let fullPaletteMode: Bool

    /// Non-nil only when `selectedGoal == .parkAndForget` and the viewport-wide ladder walk
    /// (`ContentView.resolveParkAndForgetViewport`) had to step down or came up fully empty
    /// (§0.8.10). `nil` for every other goal, and for Park & Forget when the top rung clears
    /// cleanly — no banner in either of those cases.
    let emptyMapGuardKind: EmptyMapGuardKind?

    /// Fired when the user taps one of the three goal tiles. The caller sets the goal and
    /// re-runs the EXISTING `rebuildOverlays()` path (§0.8.6) — no sheet, no confirm (AC-22).
    let onSelectGoal: (ParkingGoal) -> Void

    /// Fired by full-palette mode's "Pick a parking goal" row (Addendum 3 A3.3). Caller
    /// leaves full-palette mode and re-applies `selectedGoal` (`ContentView
    /// .toggleFullPaletteMode()`'s turn-OFF branch, AC-27).
    let onReturnToGoals: () -> Void

    /// Fired by "Start Driving". Caller calls the EXISTING `enterCruiseMode()` — this view
    /// never escalates on its own; picking a goal never does either (AC-30, §0.8.7).
    let onStartDriving: () -> Void

    /// First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §2.2,
    /// "do not hand-compute screen offsets against sibling views"): live frame readouts of the
    /// goal-tile row and the currently-selected tile, in the shared
    /// `onboardingCoachCoordinateSpaceName` coordinate space, for `OnboardingCoachOverlay`'s
    /// mark 1/mark 2 bubble anchors. Defaulted no-ops so every existing call site (and the
    /// `#Preview`s below) compiles unchanged — this view still never knows WHY its frame
    /// matters, same "pure presentation, caller owns everything" contract this file's header
    /// already commits to. Zero-cost while onboarding is flag-off: the closures simply never
    /// get read by anything.
    let onTileRowFrameChange: (CGRect) -> Void
    /// QA #5 (PR #149 follow-up): EVERY tile reports its own frame, keyed by goal; the caller
    /// picks the selected one. The old "only the selected tile reports" design went stale:
    /// `onGeometryChange`'s action fires only when the measured value CHANGES, so tapping a
    /// different tile (selection changes, geometry doesn't) never re-fired anything and the
    /// ring kept framing the previously-selected tile.
    let onTileFrameChange: (ParkingGoal, CGRect) -> Void

    /// Addendum 4: fires when the LOCAL goal sheet opens/closes, so the caller can hide the
    /// onboarding coach bubble while it is up. Defaulted no-op.
    let onGoalSheetPresentedChange: (Bool) -> Void

    /// Addendum 4: local sheet state (deliberately NOT `ContentView.activeSheet`).
    @State private var goalSheetPresented = false
    /// QA #5: current sheet detent; set to `.large` on open at AX4+ (`goalSheetOpensLarge`).
    @State private var goalSheetDetent: PresentationDetent = .medium

    /// Addendum 3 A3.3: at accessibility Dynamic Type sizes the three tiles reflow from a
    /// row to a vertical stack so labels never truncate.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Explicit init (rather than the synthesized memberwise one) so the private `@Environment`
    // property can never make the call site in `ContentView` inaccessible; parameter order =
    // property declaration order. The two onboarding frame callbacks are appended LAST, both
    // defaulted, so the existing positional/labeled call site in `ContentView` needs no change.
    init(
        selectedGoal: ParkingGoal,
        fullPaletteMode: Bool,
        emptyMapGuardKind: EmptyMapGuardKind?,
        onSelectGoal: @escaping (ParkingGoal) -> Void,
        onReturnToGoals: @escaping () -> Void,
        onStartDriving: @escaping () -> Void,
        onTileRowFrameChange: @escaping (CGRect) -> Void = { _ in },
        onTileFrameChange: @escaping (ParkingGoal, CGRect) -> Void = { _, _ in },
        onGoalSheetPresentedChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.selectedGoal = selectedGoal
        self.fullPaletteMode = fullPaletteMode
        self.emptyMapGuardKind = emptyMapGuardKind
        self.onSelectGoal = onSelectGoal
        self.onReturnToGoals = onReturnToGoals
        self.onStartDriving = onStartDriving
        self.onTileRowFrameChange = onTileRowFrameChange
        self.onTileFrameChange = onTileFrameChange
        self.onGoalSheetPresentedChange = onGoalSheetPresentedChange
    }

    private var usesGoalCard: Bool {
        goalDockUsesGoalCard(dynamicTypeSize: dynamicTypeSize, fullPaletteMode: fullPaletteMode)
    }

    var body: some View {
        // Design doc §2.1 (as amended by Addendum 3 A3.3): bottom-anchored VStack, code order
        // top-to-bottom = closest-to-thumb LAST. Start Driving sits above the tiles (engaging
        // has real side effects, so it earns the extra reach); the tiles / the full-palette
        // "Pick a parking goal" row are the centerpiece, closest to the thumb.
        VStack(spacing: 10) {
            if let kind = emptyMapGuardKind,
               goalDockUsesBannerChip(dynamicTypeSize: dynamicTypeSize, fullPaletteMode: fullPaletteMode) {
                // Amendment section 3: chip + Start Driving share a 4pt gap.
                VStack(spacing: goalBannerChipGapAboveStartDriving) {
                    EmptyMapGuardChip(kind: kind, onTap: presentGoalSheet)
                    startDrivingRow
                }
            } else {
                if let kind = emptyMapGuardKind {
                    EmptyMapGuardBanner(kind: kind)
                        // Addendum 4: banner text capped at AX2 inside the dock cap.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                }
                startDrivingRow
            }
            if fullPaletteMode {
                pickGoalRow
            } else if usesGoalCard {
                goalCard
            } else {
                goalTileRow
                    .onGeometryChange(for: CGRect.self, of: { proxy in
                        proxy.frame(in: .named(onboardingCoachCoordinateSpaceName))
                    }) { onTileRowFrameChange($0) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        // Addendum 4: dock type cap. Reads of `dynamicTypeSize` above/below use the REAL
        // environment size (this modifier only changes what the children see); the sheet is
        // attached AFTER this modifier so it inherits the uncapped size and scales to AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        // Addendum 3 A3.3: the one haptic on this screen. Picking a goal is a mode change a
        // driver may make without looking; a light tick confirms it. None on Start Driving,
        // Search, or More.
        .sensoryFeedback(.selection, trigger: selectedGoal)
        .sheet(isPresented: $goalSheetPresented) {
            GoalPickerSheet(
                selectedGoal: selectedGoal,
                guardKind: emptyMapGuardKind,
                onSelect: { goal in
                    onSelectGoal(goal)
                    goalSheetPresented = false
                },
                onDone: { goalSheetPresented = false }
            )
            .presentationDetents([.medium, .large], selection: $goalSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: goalSheetPresented) { _, presented in onGoalSheetPresentedChange(presented) }
        // The card (and so the sheet) disappears if Dynamic Type drops below AX1 or the dock
        // unmounts: never strand a presented sheet or a "sheet is up" flag in the caller.
        .onChange(of: usesGoalCard) { _, uses in if !uses { goalSheetPresented = false } }
        .onDisappear { if goalSheetPresented { onGoalSheetPresentedChange(false) } }
    }

    // MARK: - Accessibility-size goal card (Addendum 4)

    private var startDrivingRow: some View {
        StartDrivingRow(accessibilityLayout: dynamicTypeSize.isAccessibilitySize, action: onStartDriving)
    }

    /// Opens the local goal sheet (card tap or chip tap). At AX4+ it opens at `.large`.
    private func presentGoalSheet() {
        goalSheetDetent = goalSheetOpensLarge(dynamicTypeSize: dynamicTypeSize) ? .large : .medium
        goalSheetPresented = true
    }

    private var goalCard: some View {
        GoalCard(
            goal: selectedGoal,
            showsSubLabel: goalCardShowsSubLabel(dynamicTypeSize: dynamicTypeSize),
            showsChangeWord: goalCardShowsChangeWord(
                dynamicTypeSize: dynamicTypeSize,
                bannerChipShowing: emptyMapGuardKind != nil
            ),
            onTap: presentGoalSheet
        )
        // The card IS both the "row" and the "selected tile" for the coach: one tile exists.
        .onGeometryChange(for: GoalCardFrameReport.self, of: { [selectedGoal] proxy in
            GoalCardFrameReport(
                frame: proxy.frame(in: .named(onboardingCoachCoordinateSpaceName)),
                goalRawValue: selectedGoal.rawValue
            )
        }) { report in
            onTileRowFrameChange(report.frame)
            if let goal = ParkingGoal(rawValue: report.goalRawValue) {
                onTileFrameChange(goal, report.frame)
            }
        }
    }

    // MARK: - Goal tile row (§2.2)

    /// Addendum 3 A3.3: HStack of three tiles normally; a vertical VStack of three full-width
    /// tiles at accessibility Dynamic Type sizes.
    @ViewBuilder
    private var goalTileRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) { goalTiles(horizontalLayout: true) }
        } else {
            HStack(spacing: 10) { goalTiles(horizontalLayout: false) }
        }
    }

    /// The three tiles. `horizontalLayout` is the TILE's own internal layout (icon leading,
    /// text trailing — used by the full-width accessibility stack), not the row's.
    @ViewBuilder
    private func goalTiles(horizontalLayout: Bool) -> some View {
        // `id: \.rawValue` rather than `\.self` — `ParkingGoal` (`Services/ParkingGoals
        // .swift`, DM-2e, untouched by this stream) declares `Equatable` but not
        // `Hashable`, and `ForEach(_:id:)` only needs the KEY PATH'S VALUE type to be
        // `Hashable`, not the element type itself. `rawValue` (`String`) is Hashable for
        // free, so this avoids adding a conformance to a file this stream must not touch.
        ForEach(ParkingGoal.allCases, id: \.rawValue) { goal in
            let isSelected = goal == selectedGoal
            GoalTile(
                goal: goal,
                isSelected: isSelected,
                horizontalLayout: horizontalLayout,
                onTap: { onSelectGoal(goal) }
            )
            .onGeometryChange(for: CGRect.self, of: { proxy in
                proxy.frame(in: .named(onboardingCoachCoordinateSpaceName))
            }) { onTileFrameChange(goal, $0) }
        }
    }

    // MARK: - "Pick a parking goal" row (Addendum 3 A3.3, full-palette mode only)

    /// Replaces the tile row in full-palette mode so the user is never stranded: tap
    /// re-applies the last-selected goal and brings the tiles back. Replaces the old
    /// reverse-direction toggle label (§2.4 "Back to goal picker"). Blue, never
    /// green/orange/red.
    private var pickGoalRow: some View {
        Button(action: onReturnToGoals) {
            Label("Pick a parking goal", systemImage: "rectangle.split.3x1.fill")
                .font(.headline)
                .modifier(DockButtonFrame(accessibilityLayout: dynamicTypeSize.isAccessibilitySize))
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .accessibilityLabel("Pick a parking goal")
        .accessibilityHint("Go back to the three parking goals")
    }
}

// MARK: - GoalTile

/// One of the three big square-ish goal tiles (§2.2). Selected-state idiom ported from
/// `ReportSheet.sweeperDirectionRow`/`CrewFeedSection.zoneChip` (filled `Color.blue` +
/// white text when selected, `Color(.systemGray6)` + secondary when not).
///
/// Deliberately NOT green for the selected state, even though green reads as "good/active"
/// elsewhere in this app — green/red on THIS screen already mean something sacred (the
/// map's binary filtered answer); reusing it for button-selection chrome would blur two
/// different channels that must stay visually separate (design doc §2.2).
private struct GoalTile: View {
    /// Addendum 4: extra trailing content for the horizontal layout.
    enum Accessory: Equatable {
        case none
        /// Sheet tile: `checkmark.circle.fill` when selected, so color is never the only signal.
        case selectedCheckmark
        /// AX goal card: "Change" + `chevron.up`, so it reads as a picker, not a status.
        case changeChevron
    }

    let goal: ParkingGoal
    let isSelected: Bool
    /// Addendum 3 A3.3: true for the accessibility-size full-width stack (icon leading, text
    /// trailing, no line limits); false for the normal three-across square-ish tile.
    let horizontalLayout: Bool
    var accessory: Accessory = .none
    /// Addendum 4: the card drops its sub-label at `>= .accessibility3`.
    var showsSubLabel: Bool = true
    /// Addendum 4 section 4 fallback: the word "Change" is dropped (chevron stays) at >= AX3.
    var showsChangeWord: Bool = true
    var minHeight: CGFloat = 128
    /// Addendum 4: the card's own label ("..., Selected. Double tap to change goal.").
    var accessibilityLabelOverride: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            tileContent
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? Color.blue : (accessory == .selectedCheckmark ? Color(.systemGray5) : Color(.systemGray6)))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabelOverride ?? "\(goal.dockPrimary), \(goal.dockSubLabel.lowercased())")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var tileContent: some View {
        if accessory == .selectedCheckmark {
            // Sheet tile (full Dynamic Type to AX5): icon + checkmark share a top row so the
            // name gets the FULL tile width and wraps only at word boundaries (a leading icon
            // plus a trailing checkmark left ~200pt, which broke "Overnight" mid-word at AX3).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: goal.dockIcon)
                        .font(.title)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .accessibilityHidden(true)
                    }
                }
                Text(goal.dockPrimary)
                    .font(.headline.bold())
                    .multilineTextAlignment(.leading)
                Text(goal.dockSubLabel)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        } else if horizontalLayout {
            HStack(spacing: 16) {
                Image(systemName: goal.dockIcon)
                    .font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    horizontalTitle
                    if showsSubLabel {
                        Text(goal.dockSubLabel)
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                switch accessory {
                case .none:
                    EmptyView()
                case .selectedCheckmark:
                    EmptyView()  // handled by the stacked sheet layout above
                case .changeChevron:
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                        if showsChangeWord {
                            Text("Change")
                                .font(.footnote)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        } else {
            // Addendum 3 A3.3 sizes: icon `.title` (was `.title2`), primary `.headline` bold up
            // to 2 lines, sub-label `.footnote` up to 3 lines (was `.caption` / 2 — too small
            // for a glance at a stoplight).
            VStack(spacing: 6) {
                Image(systemName: goal.dockIcon)
                    .font(.title)
                tileTitle
                Text(goal.dockSubLabel)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
    }
}


extension GoalTile {
    /// The title of the full-width horizontal layout (the AX1+ goal card). A single-word name
    /// ("Overnight") must never break INSIDE the word ("Overnigh / t" at AX3, QA
    /// docs/qa/pr156-preflip-polish.md #1): it gets exactly one line and shrinks (to 0.6x) when the
    /// icon and the Change chevron leave it too little width. A multi-word name keeps its natural
    /// wrapping unchanged (it can only break at a space). The line count never grows, so the
    /// dock height budget (docs/design/goal-first-ambient-design.md AX dock addenda) is unchanged
    /// or smaller.
    @ViewBuilder
    fileprivate var horizontalTitle: some View {
        if goalTitleLines(goal.dockPrimary).count == 1 {
            Text(goal.dockPrimary)
                .font(.headline.bold())
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Text(goal.dockPrimary)
                .font(.headline.bold())
                .multilineTextAlignment(.leading)
        }
    }

    /// The three-across tile title. Below `.xxLarge` it is the original `lineLimit(2)` Text,
    /// byte-for-byte (the dock's measured height at `.large` is pinned by a test). From `.xxLarge`
    /// up a goal name must never break INSIDE a word ("Overnig / ht" on an SE at XXXL): the name
    /// is pre-broken at a word boundary (`goalTitleLines`) and the line limit equals the line
    /// count, so an over-wide line shrinks (down to 0.6x) instead of wrapping mid-word.
    @ViewBuilder
    fileprivate var tileTitle: some View {
        if dynamicTypeSize < .xxLarge {
            Text(goal.dockPrimary)
                .font(.headline.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
        } else {
            let lines = goalTitleLines(goal.dockPrimary)
            Text(lines.joined(separator: "\n"))
                .font(.headline.bold())
                .multilineTextAlignment(.center)
                .lineLimit(lines.count)
                .minimumScaleFactor(0.6)
        }
    }
}

/// Splits a goal name into at most two lines at a WORD boundary (never inside a word), choosing
/// the boundary that best balances the character counts. A single-word name stays one line.
nonisolated func goalTitleLines(_ name: String) -> [String] {
    let words = name.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count > 1 else { return [name] }
    var best = 1
    var bestDiff = Int.max
    for split in 1..<words.count {
        let left = words[..<split].joined(separator: " ").count
        let right = words[split...].joined(separator: " ").count
        let diff = abs(left - right)
        if diff < bestDiff {
            bestDiff = diff
            best = split
        }
    }
    return [
        words[..<best].joined(separator: " "),
        words[best...].joined(separator: " ")
    ]
}

// MARK: - Addendum 4 pieces

/// Full-width dock button frame: 56pt below AX1 (unchanged), a 64pt MINIMUM at AX that the
/// content grows past with Dynamic Type. Deliberately not `@ScaledMetric`: scaling 64pt (and the
/// card's 112pt) by the AX3 factor (~2.35x) put the dock at ~51% of an 874pt screen, over the
/// 40% budget the addendum makes testable.
private struct DockButtonFrame: ViewModifier {
    let accessibilityLayout: Bool
    private let scaledMinHeight: CGFloat = 64

    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, minHeight: accessibilityLayout ? scaledMinHeight : 56)
    }
}

/// "Start Driving" (§2.3).
///
/// Live-smoke fix (Kevin, 2026-10-20, PR #133 flag-on cold launch): design doc §2.3 calls for
/// `.buttonStyle(.bordered)` alone. On a live map that style's own tinted fill read as "blue
/// text straight on the dark map" — so an explicit `.regularMaterial` backdrop is added (same
/// mechanism §2.4 mandates for floating controls). Additive, not a style swap.
///
/// Addendum 4: at AX the label wraps and the minimum height is 64pt scaled.
private struct StartDrivingRow: View {
    let accessibilityLayout: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .modifier(DockButtonFrame(accessibilityLayout: accessibilityLayout))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Start Driving")
        .accessibilityHint("Enters the full heading-up driving view, lit up for whichever goal is currently selected.")
    }

    @ViewBuilder
    private var label: some View {
        if accessibilityLayout {
            Label("Start Driving", systemImage: "location.north.circle.fill")
                .font(.headline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Start Driving", systemImage: "location.north.circle.fill")
                .font(.headline)
        }
    }
}

/// The AX-size current-goal card: the SELECTED goal as one full-width tile (blue + white),
/// `minHeight` 112pt (NOT `@ScaledMetric`, see `DockButtonFrame`; the content itself still
/// grows with Dynamic Type up to the AX3 cap), tapping opens the goal sheet.
private struct GoalCard: View {
    let goal: ParkingGoal
    let showsSubLabel: Bool
    let showsChangeWord: Bool
    let onTap: () -> Void
    private let scaledMinHeight: CGFloat = 112

    var body: some View {
        GoalTile(
            goal: goal,
            isSelected: true,
            horizontalLayout: true,
            accessory: .changeChevron,
            showsSubLabel: showsSubLabel,
            showsChangeWord: showsChangeWord,
            minHeight: scaledMinHeight,
            accessibilityLabelOverride: goal.goalCardAccessibilityLabel,
            onTap: onTap
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// The LOCAL goal sheet: three horizontal tiles at full Dynamic Type in a `ScrollView`.
/// Selecting fires the selection through `onSelect` (caller dismisses), Done just closes.
private struct GoalPickerSheet: View {
    let selectedGoal: ParkingGoal
    /// Amendment section 3: the AX chip's full original sentence + icon, repeated as the first
    /// row at the sheet's own (uncapped) Dynamic Type. `nil` = no banner showing.
    let guardKind: EmptyMapGuardKind?
    let onSelect: (ParkingGoal) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let guardKind {
                        EmptyMapGuardBanner(kind: guardKind)
                    }
                    ForEach(ParkingGoal.allCases, id: \.rawValue) { goal in
                        GoalTile(
                            goal: goal,
                            isSelected: goal == selectedGoal,
                            horizontalLayout: true,
                            accessory: .selectedCheckmark,
                            onTap: { onSelect(goal) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("Pick a parking goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

// MARK: - GoalParkUntilPill (Addendum 2, A2.2)

/// Escalated-Cruise's named-goal content upgrade for the `ParkUntilPill` slot
/// (`ContentView.bottomSafeAreaContent`'s row 3) — rendered INSTEAD of the generic
/// `ParkUntilPill` only when the active filter came from a goal tap (`ContentView`'s
/// `activeGoal` derivation, non-nil exactly when `AppConstants.driveModeDefaultEnabled &&
/// !fullPaletteMode`). Same slot, same size class, same material/background, same ✕-clears
/// semantics as `ParkUntilPill` — content upgrade ONLY, per the addendum.
///
/// Pure presentation, same discipline as the rest of this file: `icon`/`shortName`/
/// `trailingClause` arrive ALREADY RESOLVED (`ContentView.goalPillContent(for:target:now:)`,
/// which is the one place in this stream that touches `ParkingGoals`/`ParkUntilSheet` — this
/// view never does). A parallel view rather than a new parameter on `ParkUntilPill` itself
/// (the addendum's own literal suggestion) — see this file's header for why: it keeps this
/// change inside this stream's file allowlist without touching `Views/ParkUntilSheet.swift`.
struct GoalParkUntilPill: View {
    /// SF Symbol name identifying the active goal (`moon.stars.fill` / `hourglass` /
    /// `parkingsign.circle.fill`).
    let icon: String

    /// The goal's short display name ("Overnight" / "A Few Hours" / "Park & Forget").
    let shortName: String

    /// The resolved trailing clause — "Good through <day>" for Overnight/Park & Forget, or
    /// "until <time>" for A Few Hours (`ContentView.goalPillContent`'s own doc comment has
    /// the full per-goal breakdown).
    let trailingClause: String

    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Icon + text grouped into ONE VoiceOver element with the addendum's own richer
            // sentence (so a VoiceOver user gets "this is a goal, not a raw time" context) —
            // kept SEPARATE from the Clear button below, which keeps its own distinct,
            // unchanged accessibility label/action. Grouping the whole pill (icon + text +
            // Clear) into one combined element would make the Clear button unreachable as
            // its own focusable VoiceOver stop — "same ✕-clear semantics" means the button
            // stays exactly as discoverable as it is on today's `ParkUntilPill`.
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.primary)
                Text("\(shortName) · \(trailingClause)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(shortName) goal active, \(trailingClause.lowercased()). " +
                "Clears the filter and shows all parking rules."
            )
            Spacer()
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Clear Park Until filter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - EmptyMapGuardBanner

/// The empty-map-guard inline banner (§0.8.10, design doc §3.2). Both states share identical
/// NEUTRAL styling, differentiated only by icon + copy — deliberately NOT color-coded by
/// severity (red/orange are reserved for the sacred 5-color palette's "you can't park here,"
/// and reusing either here would teach the wrong association).
private struct EmptyMapGuardBanner: View {
    let kind: EmptyMapGuardKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.bannerIcon)
            Text(kind.bannerCopy)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// The AX one-line banner chip (amendment section 3): `.footnote` capped at `.xxxLarge`, one
/// line, banner icon + trailing `chevron.right`, 44pt minimum height. Tapping opens the goal
/// sheet, whose first row repeats the full sentence. VoiceOver reads the FULL sentence.
private struct EmptyMapGuardChip: View {
    let kind: EmptyMapGuardKind
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: kind.bannerIcon)
                Text(kind.chipCopy)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: goalBannerChipMinHeight, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(kind.bannerCopy)
        .accessibilityHint("Opens goal options")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - OnboardingSelectedTileFrameReporter

// MARK: - Preview

#Preview {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        VStack {
            Spacer()
            GoalSelectorView(
                selectedGoal: .freeOvernight,
                fullPaletteMode: false,
                emptyMapGuardKind: nil,
                onSelectGoal: { _ in },
                onReturnToGoals: {},
                onStartDriving: {}
            )
        }
    }
}

#Preview("GoalParkUntilPill") {
    GoalParkUntilPill(
        icon: "moon.stars.fill",
        shortName: "Overnight",
        trailingClause: "Good through tomorrow",
        onClear: {}
    )
}
