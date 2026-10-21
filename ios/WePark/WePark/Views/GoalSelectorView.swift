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

import SwiftUI

// MARK: - EmptyMapGuardKind

/// The two empty-map-guard banner states (§0.8.10, design doc §3.2). `nil` (no case shown)
/// means Park & Forget's viewport resolution cleared its top rung cleanly, or the active
/// goal isn't Park & Forget at all — no banner either way.
enum EmptyMapGuardKind: Equatable {
    /// The ladder stepped down from the top rung but still found SOME match at a lower rung.
    /// Design doc §3.2: "Nothing clear for a full week nearby — showing the best available."
    case steppedDown
    /// Even the bottom (easiest) rung found zero matches anywhere in the viewport — the
    /// true-empty state. Design doc §3.2: "No clear spots found very nearby — try Overnight,
    /// or pan the map."
    case empty
}

// MARK: - GoalSelectorView

struct GoalSelectorView<ReportPill: View>: View {

    /// The currently active goal (always has a value — "no goal" isn't a state this dock
    /// represents; `fullPaletteMode` is the orthogonal "goal-first vs. full-palette" switch).
    let selectedGoal: ParkingGoal

    /// True once the user has toggled OUT of goal-first (§0.8.8). The goal-tile row hides
    /// entirely in this state; the toggle row and "Start Driving" row stay visible and
    /// functional (design doc §2.3's note, §2.4).
    let fullPaletteMode: Bool

    /// Non-nil only when `selectedGoal == .parkAndForget` and the viewport-wide ladder walk
    /// (`ContentView.resolveParkAndForgetViewport`) had to step down or came up fully empty
    /// (§0.8.10). `nil` for every other goal, and for Park & Forget when the top rung clears
    /// cleanly — no banner in either of those cases.
    let emptyMapGuardKind: EmptyMapGuardKind?

    /// Fired when the user taps one of the three goal tiles. The caller sets the goal and
    /// re-runs the EXISTING `rebuildOverlays()` path (§0.8.6) — no sheet, no confirm (AC-22).
    let onSelectGoal: (ParkingGoal) -> Void

    /// Fired by the toggle row. Caller flips `fullPaletteMode` and either re-applies
    /// `selectedGoal` or calls the existing `clearParkUntilFilter()` (§0.8.8/AC-27).
    let onToggleFullPalette: () -> Void

    /// Fired by "Start Driving". Caller calls the EXISTING `enterCruiseMode()` — this view
    /// never escalates on its own; picking a goal never does either (AC-30, §0.8.7).
    let onStartDriving: () -> Void

    /// Addendum 2 (A2.1 item 2): the persistent Report pill button — `ContentView`'s OWN
    /// `reportPillButton`, unchanged component, handed down as a trailing `@ViewBuilder`
    /// closure rather than rebuilt here, so this file never needs to know what tapping
    /// Report actually does (same "caller owns the gate/state" convention every other
    /// closure on this view already follows). Evaluated once, in `init`, matching the
    /// standard SwiftUI "generic container + @ViewBuilder content" idiom.
    let reportPill: ReportPill

    init(
        selectedGoal: ParkingGoal,
        fullPaletteMode: Bool,
        emptyMapGuardKind: EmptyMapGuardKind?,
        onSelectGoal: @escaping (ParkingGoal) -> Void,
        onToggleFullPalette: @escaping () -> Void,
        onStartDriving: @escaping () -> Void,
        @ViewBuilder reportPill: () -> ReportPill
    ) {
        self.selectedGoal = selectedGoal
        self.fullPaletteMode = fullPaletteMode
        self.emptyMapGuardKind = emptyMapGuardKind
        self.onSelectGoal = onSelectGoal
        self.onToggleFullPalette = onToggleFullPalette
        self.onStartDriving = onStartDriving
        self.reportPill = reportPill()
    }

    var body: some View {
        // Design doc §2.1 (amended by Addendum 2 A2.1 item 2): bottom-anchored VStack,
        // top-to-bottom code order = closest-to-thumb LAST. `topRow` (Report + full-palette
        // toggle, sharing one line) is quietest/farthest from thumb; goalTileRow is the
        // centerpiece, closest to thumb.
        VStack(spacing: 10) {
            topRow
            if let kind = emptyMapGuardKind {
                EmptyMapGuardBanner(kind: kind)
            }
            startDrivingRow
            if !fullPaletteMode {
                goalTileRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Top row: Report pill + full-palette toggle (Addendum 2, A2.1 item 2)

    /// Report pill leading, full-palette toggle trailing, sharing one line — both controls
    /// keep their existing sizes untouched (Report: `.frame(minHeight: 48)`, carried in via
    /// `reportPillButton` itself; toggle: `.frame(minHeight: 44)`, unchanged below) — only
    /// their CONTAINER changed, per the addendum's own framing.
    private var topRow: some View {
        HStack {
            reportPill
            Spacer()
            fullPaletteToggleButton
        }
    }

    /// Full-palette toggle (§2.4) — the button content itself, unchanged from the pre-Addendum-2
    /// `fullPaletteToggleRow`. Its own `HStack { Spacer(); Button }` wrapper is gone (that
    /// `Spacer()` was for right-aligning a LONE row; `topRow` above now supplies the shared-line
    /// layout instead), but the button's own look/size/accessibility label are byte-identical.
    private var fullPaletteToggleButton: some View {
        Button(action: onToggleFullPalette) {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette.fill")
                    .font(.caption)
                Text(fullPaletteMode ? "Back to goal picker" : "Show all parking rules")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fullPaletteMode ? "Back to goal picker" : "Show all parking rules")
    }

    // MARK: - "Start Driving" row (§2.3)

    /// Live-smoke fix (Kevin, 2026-10-20, PR #133 flag-on cold launch): design doc §2.3 calls
    /// for `.buttonStyle(.bordered)` alone, no explicit background. On a live map that style's
    /// own tinted fill read as "blue text straight on the dark map, barely readable" — not a
    /// visible control. Adding an explicit `.regularMaterial` backdrop (same mechanism §2.4
    /// already mandates for `fullPaletteToggleRow`, and the same family every other floating
    /// control in this app uses per that section's own rationale) guarantees a legible
    /// backdrop regardless of map color underneath, independent of `.bordered`'s own fill
    /// rendering. `.buttonStyle(.bordered)` is kept — this is additive, not a style swap — so
    /// the outline-not-filled "demoted" visual weight §2.3 specifies is unchanged, it just now
    /// sits on a guaranteed-visible backdrop instead of a possibly-invisible one. Flagged as a
    /// one-line deviation from the design doc's literal §2.3 text, not a silent one.
    private var startDrivingRow: some View {
        Button(action: onStartDriving) {
            Label("Start Driving", systemImage: "location.north.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.bordered)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Start Driving")
        .accessibilityHint("Enters the full heading-up driving view, lit up for whichever goal is currently selected.")
    }

    // MARK: - Goal tile row (§2.2)

    private var goalTileRow: some View {
        HStack(spacing: 10) {
            // `id: \.rawValue` rather than `\.self` — `ParkingGoal` (`Services/ParkingGoals
            // .swift`, DM-2e, untouched by this stream) declares `Equatable` but not
            // `Hashable`, and `ForEach(_:id:)` only needs the KEY PATH'S VALUE type to be
            // `Hashable`, not the element type itself. `rawValue` (`String`) is Hashable for
            // free, so this avoids adding a conformance to a file this stream must not touch.
            ForEach(ParkingGoal.allCases, id: \.rawValue) { goal in
                GoalTile(
                    goal: goal,
                    isSelected: goal == selectedGoal,
                    onTap: { onSelectGoal(goal) }
                )
            }
        }
    }
}

// MARK: - GoalTile

/// One of the three big square-ish goal tiles (§2.2). Selected-state idiom ported from
/// `ReportSheet.sweeperDirectionRow`/`CrewFeedSection.zoneChip` (filled `Color.blue` +
/// white text when selected, `Color(.systemGray6)` + secondary when not — no separate
/// checkmark glyph, the fill itself IS the selected state).
///
/// Deliberately NOT green for the selected state, even though green reads as "good/active"
/// elsewhere in this app — green/red on THIS screen already mean something sacred (the
/// map's binary filtered answer); reusing it for button-selection chrome would blur two
/// different channels that must stay visually separate (design doc §2.2).
private struct GoalTile: View {
    let goal: ParkingGoal
    let isSelected: Bool
    let onTap: () -> Void

    /// Copy/icons locked by `docs/design/goal-first-ambient-design.md` §1 — "Free" is
    /// deliberately dropped from both ambiguous primary labels (§0 of that doc); the actual
    /// promise is stated plainly in each sub-label instead.
    private var icon: String {
        switch goal {
        case .freeOvernight: return "moon.stars.fill"
        case .freeFewHours: return "hourglass"
        case .parkAndForget: return "parkingsign.circle.fill"
        }
    }

    private var primary: String {
        switch goal {
        case .freeOvernight: return "Overnight"
        case .freeFewHours: return "A Few Hours"
        case .parkAndForget: return "Park & Forget"
        }
    }

    private var subLabel: String {
        switch goal {
        case .freeOvernight: return "Won't need to move it"
        case .freeFewHours: return "No meter, no cost"
        case .parkAndForget: return "Go days without moving it"
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(primary)
                    .font(.headline.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(subLabel)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isSelected ? Color.blue : Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(primary), \(subLabel.lowercased())")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

    private var icon: String {
        switch kind {
        case .steppedDown: return "info.circle.fill"
        case .empty: return "mappin.slash"
        }
    }

    private var copy: String {
        switch kind {
        case .steppedDown:
            return "Nothing clear for a full week nearby — showing the best available."
        case .empty:
            return "No clear spots found very nearby — try Overnight, or pan the map."
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(copy)
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
                onToggleFullPalette: {},
                onStartDriving: {}
            ) {
                Label("Report", systemImage: "flag.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(Color.orange)
            }
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
