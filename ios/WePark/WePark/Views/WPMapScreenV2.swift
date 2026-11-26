//
//  WPMapScreenV2.swift
//  WePark
//
//  Phase 2a of the design system rollout: the main map's chrome (docs/design/wepark-round2,
//  "1 Map", WPGoalSheet / WPMap). Mounted by `ContentView` ONLY while
//  `AppConstants.designSystemV2Enabled` is true (and the goal dock is visible). Flag off never
//  reaches this file.
//
//  Pure presentation: ContentView resolves every time, goal and verdict from the existing engine
//  and hands plain values + closures down. Nothing here decides what is parkable.
//

import SwiftUI

// MARK: - Input

/// Everything the goal sheet shows, already resolved by the caller from the existing engine.
struct WPGoalSheetInput: Equatable {
    var selectedGoal: ParkingGoal
    var now: Date
    var fewHoursEnd: Date
    var overnightEnd: Date
    /// The end the "For days" ladder actually picked (never a hard-coded week).
    var forDaysEnd: Date
    var detailMode: Bool
    var loading: Bool
    var guardKind: EmptyMapGuardKind?
    /// Flat fact line under the headline (e.g. the street-cleaning holiday note).
    var note: String?
    var morningHour: Int

    nonisolated func end(for goal: ParkingGoal) -> Date {
        switch goal {
        case .freeFewHours: return fewHoursEnd
        case .freeOvernight: return overnightEnd
        case .parkAndForget: return forDaysEnd
        }
    }

    var selectedEnd: Date { end(for: selectedGoal) }
    var headlineEnd: String { WPGoalCopy.headlineEnd(goal: selectedGoal, end: selectedEnd, now: now) }
    var countdown: String { WPGoalCopy.countdown(goal: selectedGoal, end: selectedEnd, now: now) }
    var lead: String { WPGoalCopy.lead(detailMode: detailMode, loading: loading) }

    /// The flat fact line shown under the headline: the sparse / stepped-down message (with the
    /// real span), else the caller's note.
    var factLine: String? {
        if selectedGoal == .parkAndForget, let guardKind {
            return WPGoalCopy.guardLine(kind: guardKind, forDaysEnd: forDaysEnd, now: now)
        }
        return note
    }
}

// MARK: - Sheet shell

/// White sheet, 30pt top corners, 1.5 line on top. The toolbar floats 12pt above it. The fill
/// runs under the home indicator.
struct WPSheetShell<Content: View>: View {
    var toolbar: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: WP.Radius.sheet, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: WP.Radius.sheet, style: .continuous
        )
        VStack(spacing: 0) {
            if let toolbar {
                toolbar
                    .padding(.horizontal, 14)
                    .padding(.bottom, WP.Space.s3)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s5)
            .padding(.bottom, WP.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) {
                shape.fill(WP.card).ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .top) {
                shape.strokeBorder(WP.line, lineWidth: WP.Border.fact)
                    .mask(alignment: .top) { Rectangle().frame(height: WP.Radius.sheet + 4) }
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Goal sheet

struct WPGoalSheetV2: View {
    let input: WPGoalSheetInput
    @Binding var leverOpen: Bool
    let onSelectGoal: (ParkingGoal) -> Void
    let onSelectHour: (Int) -> Void
    let onStartDriving: () -> Void
    let onSearch: () -> Void
    let onMore: () -> Void
    let onLocate: () -> Void
    /// Accessibility sizes only: the resting car token is hidden there (the sheet fills the
    /// screen), so this row is the visible way to park without dragging. nil hides it.
    var onParkMyCar: (() -> Void)? = nil
    /// Stoop Phase 6a: the goal tile row's frame in the onboarding coach space, so the first coach
    /// card can ring it. Not reported at accessibility sizes (the tiles become rows there).
    var onTileRowFrame: ((CGRect) -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    private var leverState: WPLeverState {
        guard input.selectedGoal == .freeOvernight else { return .hidden }
        return leverOpen ? .done : .change
    }

    private var toolbar: some View {
        WPMapToolbar(onSearch: onSearch, onMore: onMore, onLocate: onLocate)
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            accessibilityBody
        } else {
            WPSheetShell(toolbar: AnyView(toolbar)) {
                headline
                if leverOpen && input.selectedGoal == .freeOvernight { chips.padding(.top, WP.Space.s3) }
                if let fact = input.factLine, !(leverOpen && input.selectedGoal == .freeOvernight) {
                    factText(fact).padding(.top, WP.Space.s3)
                }
                HStack(spacing: WP.Space.s2) {
                    ForEach(WPGoalCopy.tileOrder, id: \.rawValue) { goal in
                        WPGoalTile(
                            title: WPGoalCopy.goalName(goal),
                            subtitle: WPGoalCopy.tileUntil(goal: goal, end: input.end(for: goal)),
                            isSelected: goal == input.selectedGoal
                        ) { select(goal) }
                    }
                }
                .padding(.top, WP.Space.s3)
                .onGeometryChange(for: CGRect.self, of: { proxy in
                    proxy.frame(in: .named(onboardingCoachCoordinateSpaceName))
                }) { onTileRowFrame?($0) }
                startDriving.padding(.top, WP.Space.s3)
            }
        }
    }

    private func select(_ goal: ParkingGoal) {
        leverOpen = false
        onSelectGoal(goal)
    }

    private var headline: some View {
        WPEndTimeHeadline(
            lead: input.lead,
            end: input.headlineEnd,
            sub: (leverOpen && input.selectedGoal == .freeOvernight) ? nil : input.countdown,
            lever: leverState,
            onLever: { withAnimation(.easeOut(duration: 0.18)) { leverOpen.toggle() } }
        )
    }

    private var chips: some View {
        WPHourChipRow(selectedHour: input.morningHour) { hour in
            onSelectHour(hour)
            leverOpen = false
        }
    }

    private func factText(_ text: String) -> some View {
        Text(text)
            .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WP.Space.s1)
    }

    private var startDriving: some View {
        Button("Start driving", action: onStartDriving)
            .buttonStyle(.wpInkPill)
            .accessibilityHint("Starts Drive Mode")
    }

    // MARK: AX layout (b2-ax5): tiles become full-width rows, Start driving pinned.

    private var accessibilityBody: some View {
        let cap = UIScreen.main.bounds.height * 0.78
        return WPSheetShell {
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    headline
                    if leverOpen && input.selectedGoal == .freeOvernight { chips }
                    if let fact = input.factLine { factText(fact) }
                    ForEach(WPGoalCopy.tileOrder, id: \.rawValue) { goal in
                        Button { select(goal) } label: {
                            Text("\(WPGoalCopy.goalName(goal)), \(WPGoalCopy.tileUntil(goal: goal, end: input.end(for: goal)))")
                                .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(WP.Space.s4)
                                .frame(maxWidth: .infinity, minHeight: WP.Control.goalTileHeight, alignment: .leading)
                        }
                        .buttonStyle(WPGoalTileStyle(isSelected: goal == input.selectedGoal))
                        .accessibilityAddTraits(goal == input.selectedGoal ? .isSelected : [])
                    }
                    if let onParkMyCar {
                        Button(action: onParkMyCar) {
                            Text("Park my car at my location")
                                .frame(maxWidth: .infinity, minHeight: WP.Control.goalTileHeight)
                        }
                        .buttonStyle(.wpSecondary)
                        .accessibilityHint("Places your car on the nearest curb and shows its verdict")
                    }
                    // Search / More / Locate stay reachable, after the goals the sheet is about.
                    toolbar
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The headline caps at AX1 so the three goal rows are on screen at AX5 (b2-ax5):
            // the text still wraps in full, nothing truncates, and the rows scroll if needed.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(maxHeight: cap)
            startDriving.padding(.top, WP.Space.s3)
        }
    }
}

// MARK: - Location off / outside coverage

struct WPLocationOffSheet: View {
    let onOpenSettings: () -> Void
    let onSearch: () -> Void

    var body: some View {
        WPSheetShell {
            WPSheetMessage(
                title: "Location is off",
                message: "WePark can't show where you are or guide you while you drive. You can still look up any address."
            )
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.wpInkPill)
                .padding(.top, WP.Space.s4)
            Button("Search an address", action: onSearch)
                .buttonStyle(.wpSecondary)
                .padding(.top, WP.Space.s3)
        }
    }
}

struct WPOutsideCoverageSheet: View {
    let onShowManhattan: () -> Void
    /// nil hides the secondary button (the coverage-suggestion flow is not live).
    let onSuggestNeighborhood: (() -> Void)?

    var body: some View {
        WPSheetShell {
            WPSheetMessage(
                title: "WePark covers Manhattan today",
                message: "You're outside Manhattan. Curbs here aren't mapped yet, so nothing is marked as free."
            )
            Button("Show Manhattan", action: onShowManhattan)
                .buttonStyle(.wpInkPill)
                .padding(.top, WP.Space.s4)
            if let onSuggestNeighborhood {
                Button("Suggest my neighborhood", action: onSuggestNeighborhood)
                    .buttonStyle(.wpSecondary)
                    .padding(.top, WP.Space.s3)
            }
        }
    }
}

private struct WPSheetMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            Text(title)
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Top chrome

/// What the top-leading pill says.
enum WPTopPill: Equatable {
    case none
    case streetCleaningInEffect
    case streetCleaningSuspended
    case loading
    case info(String)

    var text: String {
        switch self {
        case .none: return ""
        case .streetCleaningInEffect: return "Street cleaning in effect today"
        case .streetCleaningSuspended: return "Street cleaning suspended today"
        case .loading: return "Loading curbs"
        case .info(let s): return s
        }
    }
}

/// Pure decision for the street-cleaning pill from the existing ASP banner state. Street
/// cleaning does not run on Sundays, so "in effect today" is never claimed then.
nonisolated func wpStreetCleaningPill(state: SuspensionBannerState, now: Date) -> WPTopPill {
    switch state {
    case .todaySuspended:
        return .streetCleaningSuspended
    case .aspInEffect, .tomorrowSuspended:
        return now.dayOfWeekET == 0 ? .none : .streetCleaningInEffect
    }
}

/// Top-of-map chrome: pill (street cleaning / loading / info), the offline banner, and the
/// detail-mode legend card. Karma (heart n) is intentionally absent: no karma value is stored
/// on the device today, so there is nothing real to show.
struct WPTopChromeV2: View {
    let pill: WPTopPill
    /// Non-nil while offline: the "as of" clock text, e.g. "10:02 PM".
    let offlineAsOf: String?
    let showLegend: Bool
    let onHideDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            if let offlineAsOf {
                WPOfflineBanner(asOf: offlineAsOf)
            } else if pill != .none {
                WPInfoPill(pill: pill)
            }
            if showLegend {
                WPCurbLegendCard(onHide: onHideDetails)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, WP.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WPInfoPill: View {
    let pill: WPTopPill

    var body: some View {
        let good = pill == .streetCleaningSuspended
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        HStack(spacing: WP.Space.s2) {
            if pill == .loading {
                ProgressView().tint(WP.text).accessibilityHidden(true)
            }
            Text(pill.text)
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(good ? WP.ink : WP.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(minHeight: WP.Target.minimum)
        .background(shape.fill(good ? WP.park : WP.card))
        .overlay(shape.strokeBorder(good ? WP.ink : WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }
}

struct WPOfflineBanner: View {
    let asOf: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text("Offline")
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
            Text("Showing posted signs as of \(asOf). No live reports.")
                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(wpHex: WP.Hex.darkText))
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, minHeight: WP.Target.minimum, alignment: .leading)
        .background(shape.fill(Color(wpHex: WP.Hex.ink)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Legend card (detail mode)

struct WPCurbLegendCard: View {
    let onHide: () -> Void

    private struct Item { let kind: CurbLineKind; let label: String }
    private let items: [Item] = [
        Item(kind: .park, label: "Free"),
        Item(kind: .soon, label: "Changes soon"),
        Item(kind: .metered, label: "Metered"),
        Item(kind: .dont, label: "No parking"),
        Item(kind: .noData, label: "No sign data"),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: WP.Space.s3) {
                    WPCurbSample(kind: item.kind).frame(width: 36, height: 8)
                        .accessibilityHidden(true)
                    Text(item.label)
                        .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Button(action: onHide) {
                Text("Hide details")
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .underline()
                    .foregroundStyle(WP.text)
                    .frame(minHeight: WP.Target.minimum, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(WP.Space.s4)
        .fixedSize(horizontal: true, vertical: false)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }
}

/// A short sample of one curb-line style (same constants as the map renderer).
struct WPCurbSample: View {
    let kind: CurbLineKind

    var body: some View {
        let style = CurbLineStyleV2.style(for: kind)
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(
                path,
                with: .color(Color(wpHex: style.colorHex)),
                style: StrokeStyle(
                    lineWidth: style.width,
                    lineCap: style.roundCaps ? .round : .butt,
                    dash: style.dashPattern ?? []
                )
            )
        }
    }
}
