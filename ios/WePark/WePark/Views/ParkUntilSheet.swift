//
//  ParkUntilSheet.swift
//  WePark
//
//  W7.5: "Parking until when?" sheet — presented via standalone toolbar button (clock.fill).
//  Pass-2 pivot: filter-first UX — user enters Park Until mode, sees matching blocks,
//  then chooses where to park. Sheet is car-agnostic; no ParkedCar dependency.
//
//  Design spec: docs/w7.5-park-until-x-spec.md §3.C
//
//  Layout:
//    - Header: "Parking until when?" (navigation title, sheet is presented not pushed)
//    - Preset pill row: 6 presets in a horizontal ScrollView
//    - Custom time picker: DatePicker(.compact) for non-preset targets
//    - Confirm button: full-width .borderedProminent, disabled until a target is selected
//    - Skip button: text-style, dismisses without activating the filter
//
//  All time math via Calendar.easternTime. Zero Calendar.current references.
//

import SwiftUI

struct ParkUntilSheet: View {

    // MARK: - Inputs

    /// Called when user confirms a target. ContentView wires this to set parkUntilTarget.
    let onConfirm: (Date) -> Void

    /// Called when user taps "Skip for now". ContentView dismisses the sheet.
    let onSkip: () -> Void

    // MARK: - State

    @State private var selectedPreset: PresetID? = nil
    @State private var customDate: Date = Self.defaultCustomDate()
    @State private var customDateWasChanged: Bool = false

    // MARK: - Preset definitions

    private enum PresetID: Equatable {
        case thirtyMin, oneHour, twoHour, fourHour, tonight, tomorrowNineAM
    }

    private struct Preset {
        let id: PresetID
        let label: String
        let date: () -> Date
    }

    private static var presets: [Preset] {
        [
            Preset(id: .thirtyMin,     label: "30 min",         date: { .nowET.addingTimeInterval(30 * 60) }),
            Preset(id: .oneHour,       label: "1 hr",           date: { .nowET.addingTimeInterval(1 * 3600) }),
            Preset(id: .twoHour,       label: "2 hr",           date: { .nowET.addingTimeInterval(2 * 3600) }),
            Preset(id: .fourHour,      label: "4 hr",           date: { .nowET.addingTimeInterval(4 * 3600) }),
            Preset(id: .tonight,       label: "Tonight",        date: { Self.tonightMidnight() }),
            Preset(id: .tomorrowNineAM, label: "Tomorrow 9am", date: { Self.tomorrowNineAM() }),
        ]
    }

    // MARK: - Computed

    /// The currently chosen target date (preset or custom picker).
    private var targetDate: Date? {
        if let preset = selectedPreset,
           let p = Self.presets.first(where: { $0.id == preset }) {
            return p.date()
        }
        if customDateWasChanged {
            return customDate
        }
        return nil
    }

    /// Formatted time string for the Confirm button label and toast.
    private var formattedTargetTime: String {
        guard let target = targetDate else { return "" }
        return Self.formatTime(target)
    }

    /// Max selectable date: 24h from now (spec §4.A 24h cap).
    private var maxDate: Date { .nowET.addingTimeInterval(24 * 3600) }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Preset pill row
                Text("Quick picks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Self.presets, id: \.label) { preset in
                            Button {
                                selectPreset(preset)
                            } label: {
                                Text(preset.label)
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedPreset == preset.id ? .green : .secondary)
                            .accessibilityLabel("Park for \(preset.label)")
                        }
                    }
                    .padding(.horizontal)
                }

                // MARK: Custom time picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom time")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    DatePicker(
                        "Custom departure time",
                        selection: $customDate,
                        in: .nowET...maxDate,
                        displayedComponents: [.hourAndMinute, .date]
                    )
                    .datePickerStyle(.compact)
                    .padding(.horizontal)
                    .accessibilityLabel("Custom departure time")
                    .onChange(of: customDate) { _, _ in
                        customDateWasChanged = true
                        selectedPreset = nil
                    }
                }

                Spacer()

                // MARK: Confirm + Skip buttons
                VStack(spacing: 12) {
                    Button {
                        guard let target = targetDate else { return }
                        onConfirm(target)
                    } label: {
                        Text(targetDate != nil
                             ? "Confirm — until \(formattedTargetTime)"
                             : "Confirm")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(targetDate == nil)
                    .accessibilityLabel(targetDate != nil
                        ? "Confirm park until \(formattedTargetTime)"
                        : "Confirm, no time selected")
                    .padding(.horizontal)

                    Button("Skip for now", role: .cancel) {
                        onSkip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Skip, keep normal map view")
                }
                .padding(.bottom, 8)
            }
            .padding(.top, 20)
            .navigationTitle("Parking until when?")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Actions

    private func selectPreset(_ preset: Preset) {
        selectedPreset = preset.id
        customDate = preset.date()
        customDateWasChanged = false
    }

    // MARK: - Time helpers (all Calendar.easternTime)

    /// Default value for the custom DatePicker: 1 hour from now in ET.
    private static func defaultCustomDate() -> Date {
        .nowET.addingTimeInterval(3600)
    }

    /// Midnight ET at the start of the next ET calendar day (i.e., "tonight").
    private static func tonightMidnight() -> Date {
        Date.nowET.startOfDayET(offsetDays: 1)
    }

    /// 9:00 AM ET on the next calendar day (i.e., "tomorrow 9am").
    private static func tomorrowNineAM() -> Date {
        let midnight = tonightMidnight()
        return midnight.addingTimeInterval(9 * 3600)
    }

    /// Formats a Date as "h:mm a" in Eastern Time (e.g., "5:00 PM").
    /// Matches the format used in nextRestrictionTimeLabel (ParkingRulesEngine.swift:570).
    static func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = .easternTime
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}

// MARK: - ParkUntilPill

/// Filter-active indicator pill rendered at the bottom of the map via .safeAreaInset(edge: .bottom).
/// Spec §3.D: shows "Until [time]" with a green dot and a "Clear" button.
/// Mirrors the ASPBanner's .safeAreaInset(edge: .top) pattern.
struct ParkUntilPill: View {

    let targetDate: Date
    let onClear: () -> Void

    private var formattedTime: String {
        ParkUntilSheet.formatTime(targetDate)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            Text("Until \(formattedTime)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
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

// MARK: - Preview (Sheet)

#Preview("ParkUntilSheet") {
    ParkUntilSheet(onConfirm: { _ in }, onSkip: {})
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(20)
}

// MARK: - Preview (Pill)

#Preview("ParkUntilPill") {
    ParkUntilPill(
        targetDate: .nowET.addingTimeInterval(2 * 3600),
        onClear: {}
    )
}
