//
//  WPForDaysPickerV2.swift
//  WePark
//
//  DT35-1 (PR4): the For-days "Free until" picker, Stoop only. Mounted inside the goal sheet
//  (`WPGoalSheetV2`) while For days is selected. Pure presentation: ContentView owns the pick,
//  the clamp and the fallback; this only shows them and reports taps.
//
//  Pieces (reusing the Plan a Trip patterns): a 64 pt tappable row like `dateRow`, day chips and
//  quick-time chips in `WPChoiceChipStyle`, a big minus / plus time stepper (72 pt buttons,
//  30 minute steps, VoiceOver adjustable), and the dashed banner box like `problemBox`.
//

import SwiftUI

// MARK: - Banner box

/// Dashed coral box above the headline: bold line, then the plain detail line. One VoiceOver
/// element reading both sentences. Never collapses, no line limit.
struct WPForDaysBanner: View {
    let state: WPForDaysState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text(WPForDaysCopy.bannerTitle(requested: state.requested))
                .font(WP.Font.fredoka(16, .bold, relativeTo: .callout))
            Text(WPForDaysCopy.bannerDetail(state))
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
        }
        .foregroundStyle(WP.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(WP.noParkLine, style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [10, 8])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WPForDaysCopy.bannerSpoken(state))
    }
}

// MARK: - Row (opens the picker)

/// 64 pt row: "Free until:  Tue 9 AM" (or "You asked for:  Tue 9 AM" in fallback) + "Change".
struct WPForDaysRow: View {
    let isFallback: Bool
    /// The shown value: the pick, or "Auto".
    let value: String
    let spokenValue: String
    let isOpen: Bool
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s1))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: WP.Space.s3))
        let label = WPForDaysCopy.requestRowLabel(isFallback: isFallback)
        Button(action: action) {
            layout {
                Text(label)
                    .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                Spacer(minLength: WP.Space.s2)
                Text(value)
                    .font(WP.Font.fredoka(17, .bold, relativeTo: .body))
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                Text(isOpen ? "Done" : "Change")
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .underline()
            }
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, minHeight: WP.Target.standard, alignment: .leading)
        }
        .buttonStyle(WPChoiceChipStyle(isSelected: false))
        .accessibilityLabel("\(label) \(spokenValue)")
        .accessibilityHint(isOpen ? "Closes the end time picker" : "Opens the end time picker")
    }
}

// MARK: - Picker

struct WPForDaysPicker: View {
    let now: Date
    let morningHour: Int
    /// The end shown as selected: the pick, or the Auto ladder end.
    let value: Date
    let isAuto: Bool
    let showClampNote: Bool
    /// The caller clamps, stores and recolors.
    let onPick: (Date) -> Void
    let onAuto: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var grid: [Date] { ForDaysUntil.grid(now: now, morningHour: morningHour) }
    private var selectedDay: Int { ForDaysUntil.dayIndex(of: value, now: now) }

    var body: some View {
        let grid = grid
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            dayChips(grid: grid)
            stepper(grid: grid)
            quickChips(grid: grid)
            if showClampNote {
                Text(WPForDaysCopy.clampNote)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    // MARK: Days

    private func dayChips(grid: [Date]) -> some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : Array(repeating: GridItem(.flexible(), spacing: WP.Space.s2), count: 4)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0...(ForDaysUntilConstants.lastDayOffset - 1), id: \.self) { offset in
                WPChoiceChip(
                    title: WPForDaysCopy.dayTitle(offset: offset, now: now),
                    isSelected: !isAuto && offset == selectedDay,
                    height: WP.Target.standard,
                    singleLine: !typeSize.isAccessibilitySize
                ) {
                    let picked = ForDaysUntil.retarget(value, toDay: offset, now: now, grid: grid)
                    onPick(picked.date)
                }
            }
        }
    }

    // MARK: Stepper

    private func stepper(grid: [Date]) -> some View {
        let earlier = ForDaysUntil.step(from: value, by: -1, grid: grid)
        let later = ForDaysUntil.step(from: value, by: 1, grid: grid)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .center, spacing: WP.Space.s3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: WP.Space.s3))
        let buttons = HStack(spacing: WP.Space.s4) {
            if typeSize.isAccessibilitySize {
                stepButton(system: "minus", label: "30 minutes earlier", target: earlier)
                stepButton(system: "plus", label: "30 minutes later", target: later)
            }
        }
        return layout {
            if !typeSize.isAccessibilitySize {
                stepButton(system: "minus", label: "30 minutes earlier", target: earlier)
            }
            Text(WPForDaysCopy.stamp(value))
                .font(WP.Font.fredoka(24, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Free until")
                .accessibilityValue(WPForDaysCopy.spokenStamp(value))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if let later { onPick(later) }
                    case .decrement: if let earlier { onPick(earlier) }
                    @unknown default: break
                    }
                }
            if typeSize.isAccessibilitySize {
                buttons
            } else {
                stepButton(system: "plus", label: "30 minutes later", target: later)
            }
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private func stepButton(system: String, label: String, target: Date?) -> some View {
        Button {
            if let target { onPick(target) }
        } label: {
            Image(systemName: system)
                .font(.system(size: 28, weight: .bold))
                .frame(width: WP.Target.driveMin, height: WP.Target.driveMin)
        }
        .buttonStyle(WPStepCircleStyle())
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1)
        // The adjustable value element above is the VoiceOver path; these stay for touch.
        .accessibilityLabel(label)
        .accessibilityHint(target == nil ? "Unavailable, this is the end of the range" : "")
    }

    // MARK: Quick times

    private func quickChips(grid: [Date]) -> some View {
        let cal = Calendar.easternTime
        let valueParts = cal.dateComponents([.hour, .minute], from: value)
        let isMidnightValue = ForDaysUntil.isMidnight(value)
        let options: [Int?] = ForDaysUntilConstants.quickHours.map { Optional($0) } + [nil]
        return WPChipFlowLayout(spacing: WP.Space.s2) {
            ForEach(options.indices, id: \.self) { index in
                let hour = options[index]
                let selected = !isAuto && (hour.map { $0 == valueParts.hour && valueParts.minute == 0 } ?? isMidnightValue)
                WPChoiceChip(
                    title: WPForDaysCopy.quickTitle(hour: hour),
                    isSelected: selected,
                    height: WP.Target.standard,
                    singleLine: true
                ) {
                    onPick(ForDaysUntil.quick(hour: hour, onDay: selectedDay, now: now, grid: grid).date)
                }
                .frame(minWidth: 84)
            }
            WPChoiceChip(
                title: WPForDaysCopy.autoValue,
                isSelected: isAuto,
                height: WP.Target.standard,
                singleLine: true,
                action: onAuto
            )
            .frame(minWidth: 84)
            .accessibilityHint("Goes back to the automatic window")
        }
    }
}

/// Round 72 pt stepper button.
private struct WPStepCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WP.text)
            .background(Circle().fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(Circle().strokeBorder(WP.line, lineWidth: WP.Border.control))
            .contentShape(Circle())
    }
}
