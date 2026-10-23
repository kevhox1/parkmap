//
//  MoreMenuSheet.swift
//  WePark
//
//  Addendum 3 A3.4 (`docs/design/goal-first-ambient-design.md`, flag-on only): the "More" sheet
//  opened by the ambient rail's ellipsis button — the single door to everything the minimal
//  ambient screen no longer shows on its main surface: Report, "What the colors mean", the
//  "Show all parking rules" toggle, Find my car, and the Park Until clock.
//
//  Why a sheet and not a SwiftUI `Menu`: system `Menu` rows are ~44pt with no room for a
//  one-line explanation. Kevin wants roomy targets and Report needs a sentence of context to be
//  discoverable, so this is a medium-detent sheet of 64pt rows with subtitles — still a plain
//  system `List` (native feel, Dark Mode and Dynamic Type for free).
//
//  Pure presentation, same convention as `GoalSelectorView`/`LocationPrimingCard`: the caller
//  (`ContentView.moreMenuSheetContent`) decides WHICH rows show (`moreMenuVisibleRows`, below,
//  the one pure source of truth) and owns every action; this file never reads `AppConstants`
//  and owns no state. Palette: all icons blue — green/orange/red belong to curb meaning only.
//

import SwiftUI

// MARK: - MoreMenuRow

/// One row of the More sheet, in priority order (Addendum 3 A3.4 table).
enum MoreMenuRow: Equatable {
    case report
    case mapKey
    case showAllRules
    case findMyCar
    case parkUntil

    nonisolated var title: String {
        switch self {
        case .report: return "Report"
        case .mapKey: return "What the colors mean"
        case .showAllRules: return "Show all parking rules"
        case .findMyCar: return "Find my car"
        case .parkUntil: return "Park until a set time"
        }
    }

    nonisolated var subtitle: String {
        switch self {
        case .report: return "Tell neighbors what you see"
        case .mapKey: return "Green, red, and the rest"
        case .showAllRules: return "See every kind of rule, not just one goal"
        case .findMyCar: return "Show where you parked"
        case .parkUntil: return "Pick your own time"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .report: return "flag.fill"
        case .mapKey: return "questionmark.circle.fill"
        case .showAllRules: return "paintpalette.fill"
        case .findMyCar: return "car.fill"
        case .parkUntil: return "clock.fill"
        }
    }
}

// MARK: - Row visibility (pure)

/// Which More-sheet rows show, in priority order (Addendum 3 A3.4 table, "Shown when" column):
///   1. Report                 — `communityEnabled`
///   2. What the colors mean   — always
///   3. Show all parking rules — always (a `Toggle` row bound to `fullPaletteMode`)
///   4. Find my car            — only when a car is parked
///   5. Park until a set time  — only in full-palette mode (the power-user `ParkUntilSheet`
///                               path, §0.8.9)
/// Pure so every gate is directly unit-testable; `nonisolated` for the same sync-XCTest reason
/// as the other pure decision functions in `ContentView.swift`.
nonisolated func moreMenuVisibleRows(
    communityEnabled: Bool,
    hasParkedCar: Bool,
    fullPaletteMode: Bool
) -> [MoreMenuRow] {
    var rows: [MoreMenuRow] = []
    if communityEnabled { rows.append(.report) }
    rows.append(.mapKey)
    rows.append(.showAllRules)
    if hasParkedCar { rows.append(.findMyCar) }
    if fullPaletteMode { rows.append(.parkUntil) }
    return rows
}

// MARK: - MoreMenuSheet

struct MoreMenuSheet: View {

    /// The rows to show, already filtered by `moreMenuVisibleRows`.
    let rows: [MoreMenuRow]

    /// Drives the "Show all parking rules" toggle's on/off state.
    let fullPaletteMode: Bool

    /// Fired by a tappable (non-toggle) row. The caller SWAPS `activeSheet` to the row's
    /// destination — this sheet never presents anything itself.
    let onSelect: (MoreMenuRow) -> Void

    /// Fired when the "Show all parking rules" toggle flips. The caller flips
    /// `fullPaletteMode` AND dismisses, so the user sees the result at once.
    let onToggleFullPalette: () -> Void

    /// Fired by the toolbar's Done button.
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows, id: \.title) { row in
                    if row == .showAllRules {
                        toggleRow(row)
                    } else {
                        buttonRow(row)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    // MARK: Rows

    private func buttonRow(_ row: MoreMenuRow) -> some View {
        Button {
            onSelect(row)
        } label: {
            rowLabel(row)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.title), \(row.subtitle)")
    }

    /// A system `Toggle` (system toggle semantics for VoiceOver) wrapped around the same row
    /// label. The binding's setter reports the flip to the caller; the displayed value always
    /// reads the caller's `fullPaletteMode`, so state has a single owner.
    private func toggleRow(_ row: MoreMenuRow) -> some View {
        Toggle(isOn: Binding(
            get: { fullPaletteMode },
            set: { _ in onToggleFullPalette() }
        )) {
            rowLabel(row)
        }
        .tint(.blue)
    }

    /// Icon in a 44pt rounded square (`.blue.opacity(0.15)` fill, blue symbol), title
    /// `.headline`, subtitle `.subheadline` `.secondary`, 64pt minimum row height.
    private func rowLabel(_ row: MoreMenuRow) -> some View {
        HStack(spacing: 14) {
            Image(systemName: row.symbolName)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(row.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    MoreMenuSheet(
        rows: moreMenuVisibleRows(communityEnabled: true, hasParkedCar: true, fullPaletteMode: false),
        fullPaletteMode: false,
        onSelect: { _ in },
        onToggleFullPalette: {},
        onDone: {}
    )
}
