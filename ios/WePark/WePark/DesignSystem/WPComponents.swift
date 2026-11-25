//
//  WPComponents.swift
//  WePark
//
//  Design system v0.1 components (spec "Parts"): goal tile, chips, switch, rows, sheet surface.
//  (Stickers: WPCoachTripParts.swift.) Verdict blocks are in WPVerdictBlocks.swift, map markers in WPMarkers.swift.
//
//  Fixed-size pieces use `minHeight`, never `height`, so Dynamic Type can grow them; text wraps.
//

import SwiftUI

// MARK: - Goal tile

/// Goal tile (3 equal columns, gap 8, height 76, radius 20; name 15/600, "until ..." 13/400).
/// Selected: taxi, raised 4 and lifted 4 (translate Y -4). Unselected: paper, flat, 2pt line.
struct WPGoalTile: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                Text(subtitle)
                    .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, WP.Space.s2)
            .padding(.vertical, WP.Space.s2)
            .frame(maxWidth: .infinity, minHeight: WP.Control.goalTileHeight)
        }
        .buttonStyle(WPGoalTileStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WPGoalTileStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, isSelected: isSelected)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
            Group {
                if isSelected {
                    WPRaisedPiece(
                        shape: shape,
                        fill: WP.taxi,
                        border: WP.Border.control,
                        borderColor: WP.ink,
                        raise: WP.Raise.md,
                        lift: WP.Raise.md,
                        isPressed: configuration.isPressed
                    ) {
                        configuration.label.foregroundStyle(WP.ink)
                    }
                } else {
                    configuration.label
                        .foregroundStyle(WP.text)
                        .background(shape.fill(configuration.isPressed ? WP.lifted : WP.paper))
                        .overlay(shape.strokeBorder(WP.line, lineWidth: 2))
                        .contentShape(shape)
                        // Match the selected tile's lift + raise so a row of tiles stays aligned.
                        .padding(.top, WP.Raise.md)
                        .padding(.bottom, WP.Raise.md)
                }
            }
            .animation(reduceMotion ? nil : WPMotion.press, value: isSelected)
        }
    }
}

// MARK: - Chips

/// Info chip: flat, card fill, 1.5pt line, height 48, 14/500. Not tappable.
struct WPInfoChip: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: WP.Space.s2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
        }
        .foregroundStyle(WP.text)
        .padding(.horizontal, 14)
        .padding(.vertical, WP.Space.s2)
        .frame(minHeight: WP.Control.chipHeight)
        .background(RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous).fill(WP.card))
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
                .strokeBorder(WP.line, lineWidth: WP.Border.fact)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Option chip. Selected: ink fill, white 14/600. Unselected: card fill, 2pt line.
/// (Dark: the selected fill is `lifted` #3F3870 because ink would vanish on the dark surface.)
struct WPOptionChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WP.Font.fredoka(14, isSelected ? .semibold : .medium, relativeTo: .callout))
                .multilineTextAlignment(.center)
                .padding(.horizontal, WP.Space.s4)
                .padding(.vertical, WP.Space.s2)
                .frame(minHeight: WP.Control.chipHeight)
        }
        .buttonStyle(WPOptionChipStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WPOptionChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        configuration.label
            .foregroundStyle(isSelected ? Color.white : WP.text)
            .background(
                shape.fill(
                    isSelected
                        ? Color.wpAdaptive(light: WP.Hex.ink, dark: WP.Hex.darkLifted)
                        : (configuration.isPressed ? WP.lifted : WP.card)
                )
            )
            .overlay(shape.strokeBorder(isSelected ? WP.ink : WP.line, lineWidth: isSelected ? WP.Border.fact : 2))
            .contentShape(shape)
    }
}

/// Karma chip: taxi, 2.5pt line, raised 3, 15/700, heart in #B8322A. Earned, so it is raised.
struct WPKarmaChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(wpHex: WP.Hex.noParkText))
                    .accessibilityHidden(true)
                Text(text)
                    .font(WP.Font.fredoka(15, .bold, relativeTo: .callout))
            }
            .foregroundStyle(WP.ink)
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s2)
            .frame(minHeight: WP.Control.chipHeight)
        }
        .buttonStyle(WPKarmaChipStyle())
    }
}

struct WPKarmaChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WPRaisedPiece(
            shape: RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous),
            fill: WP.taxi,
            border: WP.Border.control,
            borderColor: WP.ink,
            raise: WP.Raise.sm,
            isPressed: configuration.isPressed
        ) {
            configuration.label
        }
    }
}

// MARK: - Switch

/// Switch: 56 x 34, 2.5pt line, knob 22 with 2.5pt line. On = park green, off = #E4E3EC.
/// The knob slides 23 in 180 ms. The row is at least 48 tall for the touch target.
struct WPSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: WP.Space.s3) {
                    configuration.label
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: WP.Space.s2)
                    track
                }
                .frame(minHeight: WP.Target.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
        }

        private var track: some View {
            let size = WP.Control.switchSize
            let inset = (size.height - WP.Control.switchKnob) / 2
            return ZStack(alignment: .leading) {
                Capsule().fill(configuration.isOn ? WP.park : WP.divider)
                Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .frame(width: WP.Control.switchKnob, height: WP.Control.switchKnob)
                    .offset(x: inset + (configuration.isOn ? WP.Control.switchTravel : 0))
            }
            .frame(width: size.width, height: size.height)
            .animation(reduceMotion ? nil : WPMotion.knob, value: configuration.isOn)
        }
    }
}

extension ToggleStyle where Self == WPSwitchStyle {
    static var wp: WPSwitchStyle { WPSwitchStyle() }
}

// MARK: - Rows

/// Row: min height 60, padding 8 x 16, title 16/600, subtitle 13/400 muted.
struct WPRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: WP.Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WP.Font.fredoka(16, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                if let subtitle {
                    Text(subtitle)
                        .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                        .foregroundStyle(WP.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, WP.Space.s2)
        .padding(.horizontal, WP.Space.s4)
        .frame(minHeight: WP.Control.rowMinHeight)
    }
}

extension WPRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// 1pt row divider (#E4E3EC).
struct WPRowDivider: View {
    var body: some View {
        Rectangle().fill(WP.divider).frame(height: 1)
    }
}

/// Row group: card fill, 1.5pt line, radius 20. Put `WPRowDivider()` between rows.
struct WPRowGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        VStack(spacing: 0, content: content)
            .background(shape.fill(WP.card))
            .clipShape(shape)
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }
}

// MARK: - Sheet surface

private struct WPSheetSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: WP.Radius.sheet,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: WP.Radius.sheet,
            style: .continuous
        )
        content
            .background(shape.fill(WP.card).ignoresSafeArea(edges: .bottom))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))   // no shadow
    }
}

extension View {
    /// Sheet surface: card fill, top radius 30, 1.5pt top line, no shadow.
    func wpSheetSurface() -> some View {
        modifier(WPSheetSurfaceModifier())
    }
}
