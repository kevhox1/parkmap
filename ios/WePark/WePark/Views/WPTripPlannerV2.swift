//
//  WPTripPlannerV2.swift
//  Views
//
//  Stoop Phase 6b (round-2 B14): Plan a Trip in the Stoop design system. Shown only while
//  `AppConstants.designSystemV2Enabled` (and, as before, `AppConstants.planTripEnabled`).
//
//    - `WPTripPlannerV2`: B14.2 planner and B14.3 validation (plain values and closures).
//    - `WPTripMapCard`: B14.4 / B14.7 bottom card of the trip map ("free for your whole trip, until").
//    - `WPTripTopTag`: the persistent "TRIP PLAN · NOT LIVE" tag at the top of the trip map.
//
//  Live vs not-live must be unmistakable: the dashed violet frame (`wpTripFrame`), the striped tag and
//  the card all say "plan", and the live controls are not drawn while a plan shows (the existing
//  `TripModeGating` rules, unchanged). The verdict is the SAME green gate as the matching live map
//  (Stoop on: `WPCurbVerdict.isParkable`; flag off: `engine.isFree`) over [arrival, departure],
//  via `TripPlanning.isFree(strictSigns:)`; nothing here decides parkability.
//

import MapKit
import SwiftUI

// MARK: - B14.2 / B14.3 Planner

struct WPTripPlannerV2: View {
    /// Prefill when editing an active plan; `nil` for a fresh plan.
    let initialPlan: TripPlan?
    /// R35 F-1: where the map is centred when the planner opens. A fresh plan starts with this as
    /// its destination ("Where to?"), which is the searched place right after a search and the
    /// user right after Locate. `nil` (tests, showcases): no default destination.
    var mapCenter: CLLocationCoordinate2D? = nil
    /// Used only for the "0.3 mi away" line under the destination.
    var userLocation: CLLocationCoordinate2D? = nil
    let onConfirm: (TripPlan) -> Void
    let onCancel: () -> Void

    @State private var arrival: Date
    @State private var departure: Date
    /// The quick pick the user tapped and the window it set; it stays "chosen" only while the dates
    /// still equal that window.
    @State private var picked: (pick: TripQuickPick, plan: TripPlan)?
    /// Which date row's wheel is open (one at a time).
    @State private var editing: WPTripCopy.Problem.Field?
    /// R35 F-1: the destination (nil = the old whole-map trip), whether the user picked it (so it
    /// goes to Recents on "Show trip map"), and whether the address picker is showing.
    @State private var destination: TripDestination?
    @State private var destinationChosen = false
    @State private var picking = false
    @State private var recents = RecentDestinationsStore()

    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        initialPlan: TripPlan?,
        mapCenter: CLLocationCoordinate2D? = nil,
        userLocation: CLLocationCoordinate2D? = nil,
        onConfirm: @escaping (TripPlan) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialPlan = initialPlan
        self.mapCenter = mapCenter
        self.userLocation = userLocation
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        if let initialPlan {
            _arrival = State(initialValue: initialPlan.arrival)
            _departure = State(initialValue: initialPlan.departure)
            // Editing keeps the saved place; it never swaps in the map centre.
            _destination = State(initialValue: initialPlan.destination)
            _destinationChosen = State(initialValue: initialPlan.destination != nil)
        } else {
            _destination = State(initialValue: mapCenter.map {
                WPTripDestinationPickerLogic.defaultDestination(center: $0, label: nil)
            })
            // Default: arrive at the top of the next hour, stay four hours (as before).
            let now = Date.nowET
            let hour: TimeInterval = 3600
            let nextHour = Date(timeIntervalSinceReferenceDate:
                (now.timeIntervalSinceReferenceDate / hour).rounded(.down) * hour + hour)
            _arrival = State(initialValue: nextHour)
            _departure = State(initialValue: nextHour.addingTimeInterval(4 * hour))
        }
    }

    /// The dates alone: what a quick pick sets (a quick pick never carries a destination).
    private var datesOnlyPlan: TripPlan { TripPlan(arrival: arrival, departure: departure) }

    private var currentPlan: TripPlan {
        TripPlan(arrival: arrival, departure: departure, destination: destination)
    }

    /// Recents are saved when the user confirms a place they chose, not on mere selection.
    private func confirm() {
        if destinationChosen, let destination {
            recents.add(RecentDestination(
                id: UUID(), name: destination.name,
                latitude: destination.latitude, longitude: destination.longitude
            ))
        }
        onConfirm(currentPlan)
    }

    private var isOutsideCoverage: Bool {
        guard let destination else { return false }
        return !AppConstants.isInManhattanCoverage(destination.coordinate)
    }

    private var validation: TripPlanValidation {
        TripPlanning.validate(arrival: arrival, departure: departure, now: .nowET)
    }

    var body: some View {
        if picking {
            WPTripDestinationPickerV2(
                region: mapCenter.map {
                    MKCoordinateRegion(center: $0, latitudinalMeters: 5_000, longitudinalMeters: 5_000)
                },
                userLocation: userLocation,
                recents: recents.destinations,
                onPick: { picked in
                    destination = picked
                    destinationChosen = true
                    picking = false
                },
                onBack: { picking = false }
            )
        } else {
            planner
        }
    }

    private var planner: some View {
        let problem = WPTripCopy.problem(for: validation)
        return WPScreenScaffold(
            onClose: onCancel,
            title: WPTripCopy.title,
            sub: WPTripCopy.sub,
            primary: (title: WPTripCopy.showMap, kind: .navigation, action: { confirm() }),
            primaryDisabled: validation != .valid
        ) {
            destinationCard
            quickPicks
            datesCard(problem: problem)
            if let problem {
                problemBox(problem)
            } else {
                Text(WPTripCopy.planNote)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(WPTripCopy.caveat)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: arrival) { _, newArrival in
            // Moving Arrive past Leave carries Leave along (as the legacy planner did).
            if departure <= newArrival {
                departure = newArrival.addingTimeInterval(3 * 3600)
            }
        }
        .task {
            // Name the map-centre default ("Near 350 5th Ave"). Best effort: it never blocks the
            // sheet, and it never renames a place the user chose.
            guard initialPlan == nil, let mapCenter,
                  WPTripDestinationPickerLogic.isMapCentreDefault(destination, center: mapCenter),
                  !destinationChosen else { return }
            guard let label = await WPPlaceResolver.nearLabel(for: mapCenter),
                  WPTripDestinationPickerLogic.isMapCentreDefault(destination, center: mapCenter),
                  !destinationChosen else { return }
            destination = WPTripDestinationPickerLogic.defaultDestination(center: mapCenter, label: label)
        }
    }

    // MARK: Where to?

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            WPListCard { destinationRow }
            if isOutsideCoverage { outsideCoverageCard }
            recentChips
        }
        .padding(.top, WP.Space.s2)
    }

    private var destinationRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s1))
            : AnyLayout(HStackLayout(alignment: .center, spacing: WP.Space.s3))
        return layout {
            Button { picking = true } label: {
                let inner = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s1))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: WP.Space.s3))
                inner {
                    Text("Where to?")
                        .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                        .foregroundStyle(WP.text)
                    Spacer(minLength: WP.Space.s2)
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                        Text(destination?.name ?? "Pick a place")
                            .font(WP.Font.fredoka(17, .bold, relativeTo: .body))
                            .foregroundStyle(WP.text)
                        if let line = destinationSubline {
                            Text(line)
                                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                                .foregroundStyle(WP.muted)
                        }
                    }
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, WP.Space.s4)
                .padding(.trailing, destination == nil || typeSize.isAccessibilitySize ? WP.Space.s4 : 0)
                .padding(.vertical, WP.Space.s3)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Where to? \(destination?.name ?? "No place picked")")
            .accessibilityHint("Opens the address search")
            if destination != nil {
                Button {
                    destination = nil
                    destinationChosen = false
                } label: {
                    Text("Clear")
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                        .padding(.horizontal, WP.Space.s3)
                        .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, typeSize.isAccessibilitySize ? 0 : WP.Space.s2)
                .padding(.leading, typeSize.isAccessibilitySize ? WP.Space.s2 : 0)
                .padding(.bottom, typeSize.isAccessibilitySize ? WP.Space.s2 : 0)
                .accessibilityLabel("Clear destination")
                .accessibilityHint("Plans the trip for the whole map")
            }
        }
    }

    /// Address, then how far it is from the user.
    private var destinationSubline: String? {
        guard let destination else { return "Plans the trip for the whole map" }
        var parts: [String] = []
        if let address = destination.address, !address.isEmpty { parts.append(address) }
        if let userLocation {
            let meters = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
                .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
            // "0 ft away" is noise when the place is where the user stands.
            if meters >= 30 { parts.append(WPSearchSheetV2.distanceLabel(meters) + " away") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private var outsideCoverageCard: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: WP.Space.s1) {
            Text(WPTripDestinationPickerLogic.notCoveredTitle)
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .headline))
                .foregroundStyle(WP.text)
            Text(WPTripDestinationPickerLogic.notCoveredDetail)
                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                .foregroundStyle(WP.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }

    /// Up to three recent destinations, one tap to change the place.
    @ViewBuilder private var recentChips: some View {
        let shown = WPTripDestinationPickerLogic.chipRecents(recents.destinations, excluding: destination)
        if !shown.isEmpty {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
                : AnyLayout(HStackLayout(spacing: WP.Space.s2))
            ScrollView(.horizontal, showsIndicators: false) {
                layout {
                    ForEach(shown) { recent in
                        Button {
                            destination = TripDestination(
                                name: recent.name, address: nil,
                                latitude: recent.latitude, longitude: recent.longitude
                            )
                            destinationChosen = true
                        } label: {
                            Text(recent.name)
                                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                                .foregroundStyle(WP.text)
                                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                                .padding(.horizontal, WP.Space.s3)
                                .frame(minHeight: WP.Target.minimum)
                                .background(Capsule().fill(WP.card))
                                .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.fact))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recent place, \(recent.name)")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Quick picks

    @ViewBuilder private var quickPicks: some View {
        ForEach(TripQuickPick.allCases, id: \.title) { pick in
            quickPickRow(pick)
        }
    }

    private func quickPickRow(_ pick: TripQuickPick) -> some View {
        let now = Date.nowET
        let plan = TripPlanning.quickPick(pick, now: now)
        let title = WPTripCopy.quickPickTitle(pick)
        let range = WPTripCopy.quickPickRange(pick, plan: plan, now: now)
        let isSelected = picked.map { $0.pick == pick && $0.plan == datesOnlyPlan } ?? false
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s1))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: WP.Space.s3))
        return Button {
            guard let plan else { return }
            // Leave first, so the Arrive onChange never bumps it.
            departure = plan.departure
            arrival = plan.arrival
            picked = (pick, plan)
        } label: {
            layout {
                Text(title)
                    .font(WP.Font.fredoka(18, .bold, relativeTo: .body))
                Spacer(minLength: WP.Space.s2)
                Text(range)
                    .font(WP.Font.fredoka(16, .medium, relativeTo: .callout))
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(WPChoiceChipStyle(isSelected: isSelected))
        .disabled(plan == nil)
        .opacity(plan == nil ? 0.5 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(title), \(range)")
    }

    // MARK: Arrive / Leave

    private func datesCard(problem: WPTripCopy.Problem?) -> some View {
        WPListCard {
            dateRow(
                field: .arrive, label: WPTripCopy.arrive, selection: $arrival,
                range: Date.nowET.addingTimeInterval(-TripPlanning.arrivalGrace)...Date.distantFuture,
                isBad: problem?.field == .arrive
            )
            WPListDivider()
            dateRow(field: .leave, label: WPTripCopy.leave, selection: $departure, range: nil, isBad: problem?.field == .leave)
        }
        .environment(\.timeZone, .easternTime)
        .padding(.top, WP.Space.s2)
    }

    private func dateRow(field: WPTripCopy.Problem.Field, label: String, selection: Binding<Date>, range: ClosedRange<Date>?, isBad: Bool) -> some View {
        let isOpen = editing == field
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { editing = isOpen ? nil : field }
            } label: {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s1))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: WP.Space.s3))
                layout {
                    Text(label)
                        .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                        .foregroundStyle(WP.text)
                    Spacer(minLength: WP.Space.s2)
                    Text(WPTripCopy.rowStamp(selection.wrappedValue))
                        .font(WP.Font.fredoka(17, .bold, relativeTo: .body))
                        .foregroundStyle(isBad ? WP.noParkText : WP.text)
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, WP.Space.s4)
                .padding(.vertical, WP.Space.s3)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label), \(WPTripCopy.rowStamp(selection.wrappedValue))")
            .accessibilityHint(isOpen ? "Closes the date and time picker" : "Opens the date and time picker")
            if isOpen {
                picker(label: label, selection: selection, range: range)
                    .padding(.horizontal, WP.Space.s4)
                    .padding(.bottom, WP.Space.s2)
            }
        }
    }

    @ViewBuilder
    private func picker(label: String, selection: Binding<Date>, range: ClosedRange<Date>?) -> some View {
        if let range {
            DatePicker(label, selection: selection, in: range, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.wheel)
        } else {
            DatePicker(label, selection: selection, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.wheel)
        }
    }

    // MARK: Problem

    /// B14.3: dashed coral box, bold line then detail. Words carry the meaning, not just the red.
    private func problemBox(_ problem: WPTripCopy.Problem) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            Text(problem.title)
                .font(WP.Font.fredoka(16, .bold, relativeTo: .callout))
            Text(problem.detail)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
        }
        .foregroundStyle(WP.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(WP.noParkLine, style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [10, 8])))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - B14.4 / B14.7 Trip map card

struct WPTripMapCard: View {
    let plan: TripPlan
    let now: Date
    let arrivalCovered: Bool
    let departureCovered: Bool
    /// R35 F-1: "Near 350 5th Ave: 12 curbs free for your whole trip. ..." (nil: no destination).
    var destinationSummary: String? = nil
    let onChangeDates: () -> Void
    let onBackToLive: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isAX: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            if isAX {
                // R35 F-1: at accessibility sizes the text block may scroll (buttons stay pinned) so
                // the card never covers more than about half the screen. It scrolls only when the
                // text does not fit, so nothing is ever truncated.
                ViewThatFits(in: .vertical) {
                    textBlock
                    WPMoreBelowScroll { textBlock }
                }
                .frame(maxHeight: WPTripMapCard.axTextMaxHeight)
            } else {
                textBlock
            }
            buttons
                .padding(.top, WP.Space.s1)
        }
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        // Three lines of copy over two buttons: past AX1 it would cover the map it explains.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
    }

    /// The share of the screen the text block may use at accessibility sizes (buttons are extra).
    @MainActor private static var axTextMaxHeight: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first ?? 0
        return screen > 0 ? screen * 0.27 : 220
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            Text(WPTripCopy.mapHeadline)
                .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(WPTripCopy.untilLabel(plan))
                .font(WP.Font.fredoka(40, .bold, relativeTo: .largeTitle))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(WPTripCopy.fromLabel(plan))
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let destinationSummary {
                // After "From ...", so the headline and the time it finishes stay together.
                // Wraps by words; never truncated.
                Text(destinationSummary)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tripDestinationSummary")
            }
            if let notice = WPTripCopy.calendarNotice(plan, arrivalCovered: arrivalCovered, departureCovered: departureCovered) {
                noticeBox(title: notice.title, detail: notice.detail)
            }
            // Dropped at accessibility sizes: the dashed frame and the "TRIP PLAN · NOT LIVE" tag
            // already say this is a plan.
            if !isAX {
                Text(WPTripCopy.caveat)
                    .font(WP.Font.fredoka(14, .regular, relativeTo: .footnote))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// B14.7: a flat 1.5pt box (a fact, not a warning): bold line, then the detail.
    private func noticeBox(title: String, detail: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(WP.Font.fredoka(15, .bold, relativeTo: .callout))
            Text(detail).font(WP.Font.fredoka(14, .regular, relativeTo: .footnote))
        }
        .foregroundStyle(WP.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, WP.Space.s3)
        .padding(.vertical, WP.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        let layout = isAX
            ? AnyLayout(VStackLayout(spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s2))
        return layout {
            Button(action: onChangeDates) {
                Text(WPTripCopy.changeDates)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .lineLimit(isAX ? 2 : 1).minimumScaleFactor(0.7)
            }
            .buttonStyle(.wpSecondary)
            Button(action: onBackToLive) {
                Text(WPTripCopy.backToLive)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .lineLimit(isAX ? 2 : 1).minimumScaleFactor(0.7)
            }
            .buttonStyle(InkPillButtonStyle(labelColor: .white))
        }
    }
}

// MARK: - Top tag

/// The tag stays on every trip map screen: the one thing that says "this is a plan".
struct WPTripTopTag: View {
    let plan: TripPlan
    let now: Date

    var body: some View {
        HStack {
            WPTripPlanTag(dates: WPTripCopy.tagDates(plan, now: now))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, WP.Space.s2)
        // Readable at AX5 for the tag itself, small enough to leave the map beside the card.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: - Trip map card with the destination summary (R35 F-1)

/// Wraps `WPTripMapCard` and works out its destination line. The count is computed here, off the
/// card's own body, and recomputed when tiles load or the plan changes (`WPTripSummaryKey`). While
/// the tiles are not all loaded it says it is checking (never a number), and after 10 seconds that
/// the count is not available.
struct WPTripMapCardHost: View {
    let plan: TripPlan
    let now: Date
    let arrivalCovered: Bool
    let departureCovered: Bool
    let segments: [Segment]
    let tileCoverage: WPTileCoverage?
    let engine: ParkingRulesEngine
    let onChangeDates: () -> Void
    let onBackToLive: () -> Void

    /// The outcome and the destination it was computed for (a stale one is never shown).
    @State private var outcome: (destination: TripDestination, value: WPTripDestinationSummary.Outcome)?
    @State private var gaveUp = false

    private var summaryLine: String? {
        guard let destination = plan.destination else { return nil }
        if let outcome, outcome.destination == destination {
            return WPTripDestinationSummary.line(for: outcome.value, destination: destination)
        }
        return gaveUp
            ? WPTripDestinationSummary.unavailableLine
            : WPTripDestinationSummary.checkingLine(destination: destination)
    }

    var body: some View {
        WPTripMapCard(
            plan: plan, now: now, arrivalCovered: arrivalCovered, departureCovered: departureCovered,
            destinationSummary: summaryLine,
            onChangeDates: onChangeDates, onBackToLive: onBackToLive
        )
        .task(id: summaryKey) { await refresh() }
    }

    private var summaryKey: WPTripSummaryKey? {
        guard let destination = plan.destination else { return nil }
        return WPTripSummaryKey(
            destination: destination, plan: plan, segments: segments.count,
            loadedTiles: tileCoverage?.loadedTiles ?? []
        )
    }

    private func refresh() async {
        guard let destination = plan.destination else { outcome = nil; gaveUp = false; return }
        let result = WPTripDestinationSummary.outcome(
            destination: destination, plan: plan, segments: segments, coverage: tileCoverage,
            engine: engine, isInsideCoverage: { AppConstants.isInManhattanCoverage($0) },
            strictSigns: AppConstants.designSystemV2Enabled
        )
        if let result {
            outcome = (destination, result)
            gaveUp = false
            return
        }
        gaveUp = false
        try? await Task.sleep(for: .seconds(WPTripDestinationSummary.giveUpSeconds))
        if !Task.isCancelled { gaveUp = true }
    }
}


// MARK: - Scroll cue (R35-13)

/// A vertical ScrollView that says when there is more below: a soft fade at the bottom edge and a
/// small "More below" arrow while content is hidden, and the scroll indicator flashes on appear.
/// Both vanish once the end is reached. Used where a card scrolls only at the largest text sizes.
struct WPMoreBelowScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var contentBottom: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0

    private var hasMoreBelow: Bool {
        WPScrollCue.hasMoreBelow(contentBottom: contentBottom, visibleHeight: visibleHeight)
    }

    var body: some View {
        ScrollView {
            content()
                // The content's bottom edge in the scroll view's own space: it moves up as the user
                // scrolls and reaches `visibleHeight` when the end is in view.
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("wpMoreBelowScroll")).maxY }) {
                    contentBottom = $0
                }
        }
        .coordinateSpace(name: "wpMoreBelowScroll")
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicatorsFlash(onAppear: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { visibleHeight = $0 }
        .overlay(alignment: .bottom) {
            if hasMoreBelow {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [WP.card.opacity(0), WP.card], startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(WP.muted)
                        .padding(.bottom, 2)
                        .accessibilityHidden(true)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hasMoreBelow)
    }
}

nonisolated enum WPScrollCue {
    /// True when part of the content is hidden below the visible area (more than 1 pt, so layout
    /// rounding never shows a cue for nothing).
    /// `contentBottom` is the content's bottom edge measured from the top of the visible area.
    static func hasMoreBelow(contentBottom: CGFloat, visibleHeight: CGFloat) -> Bool {
        guard contentBottom.isFinite, visibleHeight.isFinite, visibleHeight > 0 else { return false }
        return contentBottom - visibleHeight > 1
    }
}
