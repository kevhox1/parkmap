//
//  TripPlannerSheet.swift
//  WePark
//
//  Plan a Trip (docs/specs/goals-rework.md section 3): the arrival/departure picker, quick
//  picks, inline validation, and the always-visible "rules can change" caveat. Pure
//  presentation over `TripPlanning` (Services/TripPlanning.swift); ContentView owns state.
//

import SwiftUI

/// The trip accent. Deliberately NOT the live blue, and not a curb color (green/red/orange are
/// curb meaning), so a trip plan can never read as "now".
enum TripPlanStyle {
    static let accent = Color.purple
}

struct TripPlannerSheet: View {

    /// Prefill when editing an active plan; `nil` for a fresh plan.
    let initialPlan: TripPlan?

    /// Whether the bundled street-cleaning calendar covers the whole plan (drives the notice).
    let calendarCovers: (TripPlan) -> Bool

    let onConfirm: (TripPlan) -> Void
    let onCancel: () -> Void

    @State private var arrival: Date
    @State private var departure: Date

    init(
        initialPlan: TripPlan?,
        calendarCovers: @escaping (TripPlan) -> Bool,
        onConfirm: @escaping (TripPlan) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialPlan = initialPlan
        self.calendarCovers = calendarCovers
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        if let initialPlan {
            _arrival = State(initialValue: initialPlan.arrival)
            _departure = State(initialValue: initialPlan.departure)
        } else {
            // Default: arrive at the top of the next hour, stay four hours.
            let now = Date.nowET
            let hour: TimeInterval = 3600
            let nextHour = Date(timeIntervalSinceReferenceDate:
                (now.timeIntervalSinceReferenceDate / hour).rounded(.down) * hour + hour)
            _arrival = State(initialValue: nextHour)
            _departure = State(initialValue: nextHour.addingTimeInterval(4 * hour))
        }
    }

    private var validation: TripPlanValidation {
        TripPlanning.validate(arrival: arrival, departure: departure, now: .nowET)
    }

    private var currentPlan: TripPlan { TripPlan(arrival: arrival, departure: departure) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(TripPlanning.plannerPrompt, systemImage: "suitcase.fill")
                        .font(.headline)
                        .foregroundStyle(TripPlanStyle.accent)
                        .padding(.vertical, 6)
                }

                Section("Quick picks") {
                    ForEach(TripQuickPick.allCases, id: \.title) { pick in
                        quickPickRow(pick)
                    }
                }

                Section {
                    DatePicker("Arrive", selection: $arrival, in: Date.nowET.addingTimeInterval(-TripPlanning.arrivalGrace)...,
                               displayedComponents: [.date, .hourAndMinute])
                        .frame(minHeight: 48)
                    DatePicker("Leave", selection: $departure, in: arrival...,
                               displayedComponents: [.date, .hourAndMinute])
                        .frame(minHeight: 48)
                } header: {
                    Text("Your visit")
                } footer: {
                    Text("Times are New York time. Up to 7 days.")
                }
                .environment(\.timeZone, .easternTime)

                if let message = validation.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .accessibilityElement(children: .combine)
                } else if !calendarCovers(currentPlan) {
                    Section {
                        Label(TripPlanning.calendarUnavailableNotice, systemImage: "calendar.badge.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                Section {
                    Button {
                        onConfirm(currentPlan)
                    } label: {
                        Text("Show where I can park")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TripPlanStyle.accent)
                    .disabled(validation != .valid)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(TripPlanning.caveat)
                }
            }
            .navigationTitle("Plan a trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onChange(of: arrival) { _, newArrival in
                if departure <= newArrival {
                    departure = newArrival.addingTimeInterval(3 * 3600)
                }
            }
        }
    }

    private func quickPickRow(_ pick: TripQuickPick) -> some View {
        let plan = TripPlanning.quickPick(pick, now: .nowET)
        return Button {
            guard let plan else { return }
            // Set departure first so the arrival onChange never bumps it.
            departure = plan.departure
            arrival = plan.arrival
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.title).font(.headline).foregroundStyle(.primary)
                    Text(pick.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(plan == nil)
        .opacity(plan == nil ? 0.4 : 1)
        .accessibilityLabel("\(pick.title), \(pick.subtitle)")
    }
}

// MARK: - TripPlanBanner

/// The persistent TRIP PLAN banner. Shown for as long as a plan is active, in the bottom inset
/// where the live goal dock normally sits. Purple accent + "not live" + exit.
struct TripPlanBanner: View {
    let plan: TripPlan
    let calendarCovered: Bool
    let onEdit: () -> Void
    let onExit: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var notesExpanded = false

    /// Accessibility sizes get a compact layout so the banner never grows over the map controls.
    private var compact: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder
    private var notes: some View {
        if !calendarCovered {
            Text(TripPlanning.calendarUnavailableNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(TripPlanning.caveat)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "suitcase.fill")
                    .accessibilityHidden(true)
                Text("TRIP PLAN")
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .lineLimit(1)
            }
            .foregroundStyle(TripPlanStyle.accent)

            Text(TripPlanning.bannerLine(for: plan))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if compact {
                // The notes sit behind a disclosure so they never push the banner over the
                // map's controls.
                Button {
                    withAnimation { notesExpanded.toggle() }
                } label: {
                    Label(notesExpanded ? "Hide notes" : "Notes",
                          systemImage: notesExpanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
                .tint(TripPlanStyle.accent)
                .accessibilityHint("Shows the trip plan caveat")
                if notesExpanded {
                    notes
                }
            } else {
                notes
            }

            HStack(spacing: 10) {
                Button(action: onEdit) {
                    if compact {
                        Image(systemName: "pencil")
                            .font(.headline)
                            .frame(minWidth: 48, minHeight: 48)
                    } else {
                        Text("Edit")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .buttonStyle(.bordered)
                .tint(TripPlanStyle.accent)
                .accessibilityLabel(compact ? "Edit trip plan" : "Edit")

                Button(action: onExit) {
                    if compact {
                        Label("Exit", systemImage: "xmark")
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        Text("Exit trip plan")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TripPlanStyle.accent)
                .accessibilityLabel("Exit trip plan")
            }
        }
        .padding(compact ? 12 : 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(TripPlanStyle.accent, lineWidth: 2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

#Preview("TripPlanBanner") {
    let now = Date.nowET
    TripPlanBanner(
        plan: TripPlan(arrival: now.addingTimeInterval(86_400), departure: now.addingTimeInterval(2 * 86_400)),
        calendarCovered: false,
        onEdit: {},
        onExit: {}
    )
}
