//
//  WPScreenParts.swift
//  WePark
//
//  Round-2 shared parts for full-screen flows (docs/design/wepark-round2/README.md, "Parts added in
//  round 2"; WPPass.dc.html): the full-screen scaffold, choice chip, list card with rows, and limit
//  row. The switch is `WPSwitchStyle` in WPComponents.swift (`.toggleStyle(.wp)`), which already
//  matches the round-2 values (56 x 34, 2.5 line, knob 22, on = #3CCF7A, off = #E4E3EC).
//
//  Fixed heights are minimums, never fixed, so Dynamic Type through AX5 grows the piece and text
//  wraps instead of truncating. Every control is at least 48pt.
//

import SwiftUI

// MARK: - Full-screen scaffold

/// How the bottom button reads: a commitment (taxi, raised, 72 tall) or navigation (ink, 64 tall).
enum WPPrimaryKind: Equatable {
    case commitment
    case navigation
}

/// Cream ground, wordmark 20/600 with an optional "App Clip" badge and a 48 close pill at the top,
/// headline 32/600, body 17/400, rows with gap 10, primary button pinned to the bottom, optional
/// 56pt text secondary. Used by Spot Pass, the App Clip, onboarding and blocking errors.
struct WPScreenScaffold<Content: View>: View {
    var showsClipBadge: Bool = false
    var closeLabel: String = "Close"
    var onClose: (() -> Void)? = nil
    var over: String? = nil
    let title: String
    var sub: String? = nil
    var primary: (title: String, kind: WPPrimaryKind, action: () -> Void)? = nil
    var secondary: (title: String, action: () -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let over {
                    Text(over)
                        .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                        .padding(.bottom, 2)
                }
                Text(title)
                    .font(WP.Font.fredoka(32, .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let sub {
                    Text(sub)
                        .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WP.Space.s2)
                }
                VStack(alignment: .leading, spacing: 10, content: content)
                    .padding(.top, WP.Space.s4)
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(WP.paper.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: WP.Space.s2) {
            HStack(spacing: WP.Space.s2) {
                Text("WePark")
                    .font(WP.Font.fredoka(20, .semibold, relativeTo: .title3))
                    .foregroundStyle(WP.text)
                if showsClipBadge {
                    Text("App Clip")
                        .font(WP.Font.fredoka(13, .medium, relativeTo: .caption))
                        .foregroundStyle(WP.text)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(WP.line, lineWidth: WP.Border.fact)
                        )
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: WP.Space.s2)
            if let onClose {
                Button(closeLabel, action: onClose)
                    .buttonStyle(WPClosePillStyle())
            }
        }
        .padding(.horizontal, WP.Space.screenMargin)
        .padding(.top, WP.Space.s2)
        .padding(.bottom, WP.Space.s2)
        .background(WP.paper)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if primary != nil || secondary != nil {
            VStack(spacing: 0) {
                if let primary {
                    Button(primary.title, action: primary.action)
                        .buttonStyle(primaryStyle(primary.kind))
                }
                if let secondary {
                    Button(secondary.title, action: secondary.action)
                        .buttonStyle(WPScaffoldSecondaryStyle())
                }
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s2)
            .padding(.bottom, WP.Space.s2)
            // The pinned bar stops at the drive overlay's cap (AX1 on short phones, AX2 otherwise):
            // at AX5 it would take about 45% of an SE and push the content (the privacy promise,
            // the steps) below the fold. Still accessibility-sized, never truncated.
            .dynamicTypeSize(...WPDriveVerdict.maxDriveTypeSize(screenHeight: UIScreen.main.bounds.height))
            .background(WP.paper)
        }
    }

    private func primaryStyle(_ kind: WPPrimaryKind) -> AnyButtonStyle {
        switch kind {
        case .commitment: return AnyButtonStyle(RaisedButtonStyle(size: .commitment))
        case .navigation: return AnyButtonStyle(InkPillButtonStyle(labelColor: .white))
        }
    }
}

/// Type-erased button style so the scaffold can pick between the two primary looks.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// Close pill: at least 48 x 48, white, 1.5 line, label 12/500 (mock `closeLabel`).
struct WPClosePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(WP.Font.fredoka(12, .medium, relativeTo: .caption))
            .foregroundStyle(WP.text)
            .padding(.horizontal, 10)
            .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
            .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .contentShape(shape)
    }
}

/// Text secondary under the primary: 56 tall, 17/600, no fill.
struct WPScaffoldSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
            .foregroundStyle(WP.text)
            .multilineTextAlignment(.center)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(maxWidth: .infinity, minHeight: WP.Control.secondaryHeight)
            .contentShape(Rectangle())
    }
}

// MARK: - Choice chip

/// Choice chip: card fill, 2pt line, radius 20, 56 to 64 tall, label 17 to 18/600. The chosen chip
/// is taxi, 2.5 line, raised 4 and lifted 4 (it is the thing you pressed, so rule 2 applies).
struct WPChoiceChip: View {
    let title: String
    var isSelected: Bool = false
    /// 64 for a row of options, 56 for a lone "Pick a time" style chip.
    var height: CGFloat = 64
    /// A time ("4:15 AM") must never break mid-token: one line, shrinking a little before it would
    /// ever wrap. Words ("About 30 min") keep the default wrap.
    var singleLine: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                .multilineTextAlignment(.center)
                .lineLimit(singleLine ? 1 : nil)
                .minimumScaleFactor(singleLine ? 0.6 : 1)
                .padding(.horizontal, WP.Space.s3)
                .padding(.vertical, WP.Space.s2)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(WPChoiceChipStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WPChoiceChipStyle: ButtonStyle {
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
                        .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
                        .overlay(shape.strokeBorder(WP.line, lineWidth: 2))
                        .contentShape(shape)
                        // Keep a row of chips aligned with the lifted + raised selected one.
                        .padding(.top, WP.Raise.md)
                        .padding(.bottom, WP.Raise.md)
                }
            }
            .animation(reduceMotion ? nil : WPMotion.press, value: isSelected)
        }
    }
}

// MARK: - List card

/// What a list row ends in.
enum WPListTrailing {
    case none
    case chevron
    case value(String)
}

/// List card: card fill, 1.5 line, radius 20. Put `WPListDivider()` between rows.
struct WPListCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        VStack(spacing: 0, content: content)
            .background(shape.fill(WP.card))
            .clipShape(shape)
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }
}

/// Hairline between rows (#E4E3EC; dark #3F3870), inset by the card's 18 padding.
struct WPListDivider: View {
    var body: some View {
        Rectangle()
            .fill(WP.divider)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }
}

/// List row: 56 minimum, horizontal padding 18, label 17/600, optional subtitle 13/400 muted,
/// trailing chevron or value (15/400). Tappable rows wrap the whole row in a Button.
struct WPListRow: View {
    let title: String
    var subtitle: String? = nil
    var trailing: WPListTrailing = .none
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { rowBody }
                .buttonStyle(WPListRowPressStyle())
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: WP.Space.s3) {
            WPListRowLabel(title: title, subtitle: subtitle)
            switch trailing {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.muted)
                    .accessibilityHidden(true)
            case .value(let text):
                Text(text)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, WP.Space.s2)
        .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// List row ending in the switch (56 x 34). The whole row is the 48+ touch target.
struct WPListToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            WPListRowLabel(title: title, subtitle: subtitle)
        }
        .toggleStyle(WPSwitchStyle())
        .padding(.horizontal, 18)
        .padding(.vertical, WP.Space.s2)
        .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
    }
}

private struct WPListRowLabel: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                .foregroundStyle(WP.text)
                .multilineTextAlignment(.leading)
            if let subtitle {
                Text(subtitle)
                    .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                    .foregroundStyle(WP.muted)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum WPListMetrics {
    nonisolated static let rowMinHeight: CGFloat = 56
}

/// Flat press: the row steps to the lifted fill, no movement.
struct WPListRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? WP.lifted : Color.clear)
    }
}

// MARK: - Limit row

/// Limit row: 3pt dashed #E39A90 outline, radius 20, message 15/600, fix button on the right
/// (2.5 line, 48 tall). Goes directly above the feature it limits. At accessibility text sizes
/// the button drops under the message so neither truncates.
struct WPLimitRow: View {
    let message: String
    let fixTitle: String
    let onFix: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: WP.Space.s3))
        layout {
            Text(message)
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(fixTitle, action: onFix)
                .buttonStyle(WPLimitFixStyle())
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .overlay(
            shape.strokeBorder(
                WP.noParkLine,
                style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [10, 8])
            )
        )
        .accessibilityElement(children: .contain)
    }
}

/// Fix button: flat, 2.5 line, 48 tall, 15/600.
struct WPLimitFixStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
            .foregroundStyle(WP.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, WP.Space.s4)
            .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
            .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.control))
            .contentShape(shape)
    }
}
