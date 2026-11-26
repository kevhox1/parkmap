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
//  `TripModeGating` rules, unchanged). The verdict is the SAME green gate as every live goal
//  (`TripPlanning.isFree` over [arrival, departure]); nothing here decides parkability.
//

import SwiftUI

// MARK: - B14.2 / B14.3 Planner

struct WPTripPlannerV2: View {
    /// Prefill when editing an active plan; `nil` for a fresh plan.
    let initialPlan: TripPlan?
    let onConfirm: (TripPlan) -> Void
    let onCancel: () -> Void

    @State private var arrival: Date
    @State private var departure: Date
    /// The quick pick the user tapped and the window it set; it stays "chosen" only while the dates
    /// still equal that window.
    @State private var picked: (pick: TripQuickPick, plan: TripPlan)?
    /// Which date row's wheel is open (one at a time).
    @State private var editing: WPTripCopy.Problem.Field?

    @Environment(\.dynamicTypeSize) private var typeSize

    init(initialPlan: TripPlan?, onConfirm: @escaping (TripPlan) -> Void, onCancel: @escaping () -> Void) {
        self.initialPlan = initialPlan
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        if let initialPlan {
            _arrival = State(initialValue: initialPlan.arrival)
            _departure = State(initialValue: initialPlan.departure)
        } else {
            // Default: arrive at the top of the next hour, stay four hours (as before).
            let now = Date.nowET
            let hour: TimeInterval = 3600
            let nextHour = Date(timeIntervalSinceReferenceDate:
                (now.timeIntervalSinceReferenceDate / hour).rounded(.down) * hour + hour)
            _arrival = State(initialValue: nextHour)
            _departure = State(initialValue: nextHour.addingTimeInterval(4 * hour))
        }
    }

    private var currentPlan: TripPlan { TripPlan(arrival: arrival, departure: departure) }

    private var validation: TripPlanValidation {
        TripPlanning.validate(arrival: arrival, departure: departure, now: .nowET)
    }

    var body: some View {
        let problem = WPTripCopy.problem(for: validation)
        WPScreenScaffold(
            onClose: onCancel,
            title: WPTripCopy.title,
            sub: WPTripCopy.sub,
            primary: (title: WPTripCopy.showMap, kind: .navigation, action: { onConfirm(currentPlan) }),
            primaryDisabled: validation != .valid
        ) {
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
        let isSelected = picked.map { $0.pick == pick && $0.plan == currentPlan } ?? false
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
    let onChangeDates: () -> Void
    let onBackToLive: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isAX: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
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
            if let notice = WPTripCopy.calendarNotice(plan, arrivalCovered: arrivalCovered, departureCovered: departureCovered) {
                noticeBox(title: notice.title, detail: notice.detail)
            }
            Text(WPTripCopy.caveat)
                .font(WP.Font.fredoka(14, .regular, relativeTo: .footnote))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
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
