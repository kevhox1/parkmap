//
//  WPMapParts.swift
//  WePark
//
//  Round-2 shared parts for the map screen (docs/design/wepark-round2/README.md, "Parts added in
//  round 2"): the map toolbar and the end-time lever (A1). Values come from WPGoalSheet.dc.html and
//  the "WePark Round 2 - 1 Map" A1 section. Nothing here is mounted in a real screen yet.
//
//  Rules: toolbar pieces are map chrome (flat, white, 1.5 line). The lever's "Change" is a flat
//  control (2.5 line); "Done" is an ink pill. Nothing here is raised: it neither earns nor commits.
//

import SwiftUI

// MARK: - Map toolbar

/// Search field (flexible), More and Locate (48 circles). White, 1.5 line. The caller places it 12pt
/// above the sheet with 14pt side margins (mock: `left:14 right:14 bottom:100% margin-bottom:12`).
struct WPMapToolbar: View {
    var searchPlaceholder: String = "Search an address"
    let onSearch: () -> Void
    let onMore: () -> Void
    let onLocate: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the field takes the full row and More / Locate sit below it,
        // so "Search an address" never wraps into a tall narrow column.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s2))
        layout {
            Button(action: onSearch) {
                HStack(spacing: WP.Space.s2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .accessibilityHidden(true)
                    Text(searchPlaceholder)
                        .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(WP.muted)
                .padding(.horizontal, WP.Space.s4)
                .padding(.vertical, WP.Space.s2)
                .frame(maxWidth: .infinity, minHeight: WP.Target.minimum, alignment: .leading)
            }
            .buttonStyle(WPToolbarFieldStyle())
            .accessibilityLabel(searchPlaceholder)
            .accessibilityHint("Opens search")

            HStack(spacing: WP.Space.s2) {
                WPToolbarCircle(title: "More", accessibilityLabel: "More", action: onMore)
                WPToolbarCircle(title: "Locate", accessibilityLabel: "Locate me", action: onLocate)
            }
        }
    }
}

/// 48pt white circle, 1.5 line, with a text label (More, Locate), as in the mock. The words are
/// 12/700 and never truncate: at accessibility sizes the circle grows into a capsule.
struct WPToolbarCircle: View {
    let title: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WP.Font.fredoka(12, .bold, relativeTo: .caption))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
        }
        .buttonStyle(WPToolbarCircleStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct WPToolbarFieldStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        configuration.label
            .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .contentShape(shape)
    }
}

struct WPToolbarCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WP.text)
            .background(Capsule().fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .contentShape(Capsule())
    }
}

// MARK: - End-time lever (A1)

/// What the control beside the end-time headline is doing.
enum WPLeverState: Equatable {
    /// Goal is not Overnight: no lever.
    case hidden
    /// Overnight chosen, hour chips closed: "Change".
    case change
    /// Hour chips open: "Done".
    case done
}

/// The sheet's headline block: lead line (13/500), end time (34/600), sub line (13/400) and, only
/// while Overnight is chosen, the lever ("Change", 2.5 line, 48 tall; "Done" while open).
struct WPEndTimeHeadline: View {
    let lead: String
    let end: String
    var sub: String? = nil
    var lever: WPLeverState = .hidden
    var onLever: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 6))
        VStack(alignment: .leading, spacing: 2) {
            Text(lead)
                .font(WP.Font.fredoka(13, .medium, relativeTo: .caption))
                .foregroundStyle(WP.text)
            layout {
                Text(end)
                    .font(WP.Font.fredoka(34, .semibold, relativeTo: .title))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if lever != .hidden {
                    Button(lever == .change ? "Change" : "Done", action: onLever)
                        .buttonStyle(WPLeverButtonStyle(isDone: lever == .done))
                        .accessibilityHint(lever == .change ? "Choose a different morning end time" : "Closes the end time chips")
                }
            }
            if let sub {
                Text(sub)
                    .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                    .foregroundStyle(WP.text)
            }
        }
        .padding(.horizontal, WP.Space.s1)
        .accessibilityElement(children: .contain)
    }
}

/// "Change": flat, 2.5 line, 48 tall, 15/600. "Done": ink fill, white label.
struct WPLeverButtonStyle: ButtonStyle {
    let isDone: Bool
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        // "Done" in dark: the same lifted + line pill as `InkPillButtonStyle` (ink would vanish).
        let palette = InkPillButtonStyle.Palette.resolve(dark: scheme == .dark)
        configuration.label
            .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
            .foregroundStyle(isDone ? (palette.label.map { Color(wpHex: $0) } ?? Color.white) : WP.text)
            .padding(.horizontal, isDone ? WP.Space.s4 : WP.Space.s3)
            .frame(minHeight: WP.Target.minimum)
            .frame(minWidth: WP.Target.minimum)
            .background(
                shape.fill(
                    isDone
                        ? Color(wpHex: configuration.isPressed ? palette.pressedFill : palette.fill)
                        : (configuration.isPressed ? WP.lifted : Color.clear)
                )
            )
            .overlay(
                shape.strokeBorder(
                    isDone ? (palette.outline.map { Color(wpHex: $0) } ?? Color.clear) : WP.line,
                    lineWidth: WP.Border.control
                )
            )
            .contentShape(shape)
    }
}

/// A1 hour chips: 6 to 10 AM, 52 tall, 2pt line, radius 16, 15/600. Chosen = ink fill, white label.
/// Five equal columns (gap 6); at accessibility text sizes they wrap to two columns so a label never
/// truncates. Fires `onSelect` per tap so the caller can update the map and headline immediately.
struct WPHourChipRow: View {
    var title: String = "Overnight ends at"
    var footnote: String? = "A later morning can only remove green curbs."
    var hours: [Int] = WPHourChipRow.morningHours
    let selectedHour: Int
    let onSelect: (Int) -> Void

    /// 6 to 10 AM (A1; DECISIONS "A1 Overnight lever").
    nonisolated static let morningHours: [Int] = [6, 7, 8, 9, 10]
    nonisolated static let chipHeight: CGFloat = 52

    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func label(forHour hour: Int) -> String { "\(hour) AM" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(WP.Font.fredoka(13, .medium, relativeTo: .caption))
                .foregroundStyle(WP.text)
                .padding(.horizontal, WP.Space.s1)
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 6),
                count: typeSize.isAccessibilitySize ? 2 : hours.count
            )
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(hours, id: \.self) { hour in
                    Button(Self.label(forHour: hour)) { onSelect(hour) }
                        .buttonStyle(WPHourChipStyle(isSelected: hour == selectedHour))
                        .accessibilityAddTraits(hour == selectedHour ? .isSelected : [])
                }
            }
            if let footnote {
                Text(footnote)
                    .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                    .foregroundStyle(WP.muted)
                    .padding(.horizontal, WP.Space.s1)
            }
        }
    }
}

struct WPHourChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        configuration.label
            .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
            .foregroundStyle(isSelected ? Color.white : WP.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: WPHourChipRow.chipHeight)
            .background(
                shape.fill(
                    isSelected
                        ? Color.wpAdaptive(light: WP.Hex.ink, dark: WP.Hex.darkLifted)
                        : (configuration.isPressed ? WP.lifted : Color.clear)
                )
            )
            .overlay(shape.strokeBorder(isSelected ? Color.clear : WP.line, lineWidth: 2))
            .contentShape(shape)
    }
}
