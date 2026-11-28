//
//  WPDriveV2.swift
//  WePark
//
//  Phase 3 of the design system rollout: Drive mode (docs/design/wepark-round2, B5). Mounted by
//  `ContentView` ONLY while `AppConstants.designSystemV2Enabled && AppConstants.driveModeDefaultEnabled`
//  and Drive Mode is active. Flag off never reaches this file.
//
//  Pure presentation. The verdict per side comes from `WPDriveVerdict` (which only maps the label
//  and goal-aware color `DrivingContextService` already resolved from the direction of travel and
//  the map's single green gate). Nothing here decides what is parkable or which side is left.
//
//  Rules in force:
//    - Left and right are spelled out ("LEFT SIDE" / "RIGHT SIDE"), never an icon alone.
//    - One glance: one verdict per side, no paragraphs. Roomy targets (72 to 80 pt).
//    - Dynamic Type through AX5: nothing truncates; the bottom stack scrolls when it must.
//    - Drive Mode is always dark (the window is forced dark), so the drive colors are the fixed
//      dark tokens, not the adaptive ones.
//

import CoreLocation
import SwiftUI

// MARK: - Palette (drive is always dark)

private enum WPDrivePalette {
    static let surface = Color(wpHex: WP.Hex.darkSurface)
    static let text = Color(wpHex: WP.Hex.darkText)
    static let noParkText = Color(wpHex: WP.Hex.darkNoParkText)
    static let white = Color.white
    static let ink = Color(wpHex: WP.Hex.ink)
}

// MARK: - Button styles (white on the dark ground, like the mock)

/// White capsule with an ink label. `minHeight` keeps every drive target roomy.
struct WPDrivePillStyle: ButtonStyle {
    var minHeight: CGFloat = WP.Target.driveMin
    var fontSize: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WP.Font.fredoka(fontSize, .semibold, relativeTo: .title3))
            .multilineTextAlignment(.center)
            .foregroundStyle(WPDrivePalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WP.Space.s5)
            .padding(.vertical, WP.Space.s2)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(Capsule().fill(configuration.isPressed ? Color(wpHex: WP.Hex.divider) : WPDrivePalette.white))
            .contentShape(Capsule())
    }
}

/// 72 pt white circle ("Report", "Voice on").
struct WPDriveRoundStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WP.Font.fredoka(14, .semibold, relativeTo: .callout))
            .multilineTextAlignment(.center)
            .foregroundStyle(WPDrivePalette.ink)
            .minimumScaleFactor(0.7)
            .padding(WP.Space.s2)
            .frame(width: WP.Control.roundDiameter, height: WP.Control.roundDiameter)
            .background(Circle().fill(configuration.isPressed ? Color(wpHex: WP.Hex.divider) : WPDrivePalette.white))
            .contentShape(Circle())
    }
}

// MARK: - One side's block

/// One side of the street: "LEFT SIDE" over a big verdict and one short line.
struct WPDriveSideCard: View {
    let side: WPDriveSide
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var kind: WPDriveKind { side.kind }

    private var fill: Color { kind == .park ? WP.park : WPDrivePalette.surface }
    private var textColor: Color { kind == .park ? WPDrivePalette.ink : WPDrivePalette.text }
    private var overColor: Color { kind == .dont ? WPDrivePalette.noParkText : textColor }

    private var outlineColor: Color? {
        switch kind {
        case .park: return nil
        case .soon: return WP.detailSoon
        case .dont: return WP.noParkLine
        case .meter: return WP.detailMetered
        case .nodata, .checking: return WP.hairline
        }
    }

    private var outlineStyle: StrokeStyle {
        switch kind {
        case .soon, .dont: return StrokeStyle(lineWidth: 3, dash: [10, 8])
        case .meter: return StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0, 6])
        case .nodata: return StrokeStyle(lineWidth: 2)
        case .checking: return StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0, 5])
        case .park: return StrokeStyle(lineWidth: 0)
        }
    }

    var body: some View {
        let alignment: HorizontalAlignment = side.isLeft ? .leading : .trailing
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        VStack(alignment: alignment, spacing: WP.Space.s1) {
            Text(side.name.uppercased())
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .kerning(1.2)
                .foregroundStyle(overColor)
            Text(side.big)
                .font(WP.Font.fredoka(kind == .park ? 56 : 30, .bold, relativeTo: .largeTitle))
                .foregroundStyle(textColor)
                // Never break inside a word: shrink a little first (standard sizes), wrap by words
                // at accessibility sizes where the cards are stacked full width.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.55)
                .fixedSize(horizontal: false, vertical: true)
            if let sub = side.sub {
                Text(sub)
                    .font(WP.Font.fredoka(kind == .park ? 22 : 17, .medium, relativeTo: .body))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(side.isLeft ? .leading : .trailing)
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: side.isLeft ? .leading : .trailing)
        .background(shape.fill(fill))
        .overlay {
            if let outlineColor {
                shape.strokeBorder(outlineColor, style: outlineStyle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side.spoken)
    }
}

// MARK: - Compact accessibility row

/// One side at accessibility sizes: a single row, "LEFT SIDE" over the verdict line
/// ("Park until Mon 9:00 AM", "No parking"). Secondary text is dropped; the verdict itself wraps by
/// words and is never truncated or scaled away, so both sides always fit on screen together.
struct WPDriveSideRowAX: View {
    let side: WPDriveSide

    private var kind: WPDriveKind { side.kind }
    private var fill: Color { kind == .park ? WP.park : WPDrivePalette.surface }
    private var textColor: Color { kind == .park ? WPDrivePalette.ink : WPDrivePalette.text }
    private var nameColor: Color { kind == .dont ? WPDrivePalette.noParkText : textColor }

    private var outlineColor: Color? {
        switch kind {
        case .park: return nil
        case .soon: return WP.detailSoon
        case .dont: return WP.noParkLine
        case .meter: return WP.detailMetered
        case .nodata, .checking: return WP.hairline
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text(side.name.uppercased())
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .kerning(1.2)
                .foregroundStyle(nameColor)
            Text(WPDriveVerdict.compactLine(for: side))
                .font(WP.Font.fredoka(28, .bold, relativeTo: .title))
                .foregroundStyle(textColor)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(fill))
        .overlay {
            if let outlineColor {
                shape.strokeBorder(outlineColor, style: StrokeStyle(lineWidth: 3, dash: kind == .dont || kind == .soon ? [10, 8] : []))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side.spoken)
    }
}

// MARK: - Weighted two-column layout

/// Two columns whose widths follow weights (the green side is the wider card, mock B5.2 to B5.4).
/// Children align to the bottom so the cards sit on the same baseline.
private struct WPDriveColumns: Layout {
    var weights: [Double]
    var spacing: CGFloat

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let usable = max(0, total - spacing * CGFloat(max(0, weights.count - 1)))
        let sum = weights.reduce(0, +)
        return weights.map { usable * CGFloat($0 / sum) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 360
        let w = widths(total)
        var height: CGFloat = 0
        for (i, sub) in subviews.enumerated() where i < w.count {
            height = max(height, sub.sizeThatFits(ProposedViewSize(width: w[i], height: nil)).height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() where i < w.count {
            let size = sub.sizeThatFits(ProposedViewSize(width: w[i], height: nil))
            sub.place(
                at: CGPoint(x: x, y: bounds.maxY - size.height), anchor: .topLeading,
                proposal: ProposedViewSize(width: w[i], height: size.height)
            )
            x += w[i] + spacing
        }
    }
}

// MARK: - Sides

/// Both sides. Side by side normally; stacked (left over right) at accessibility sizes.
struct WPDriveSidesV2: View {
    let left: WPDriveSide
    let right: WPDriveSide
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: WP.Space.s2) {
                WPDriveSideRowAX(side: left)
                WPDriveSideRowAX(side: right)
            }
        } else {
            WPDriveColumns(
                weights: [
                    WPDriveVerdict.widthShare(of: left, other: right),
                    WPDriveVerdict.widthShare(of: right, other: left),
                ],
                spacing: WP.Space.s3
            ) {
                WPDriveSideCard(side: left)
                WPDriveSideCard(side: right)
            }
        }
    }
}

// MARK: - Actions

/// Report, Park here, Voice. The raised yellow Park here appears only when a side is green.
struct WPDriveActionsV2: View {
    let primary: WPDriveVerdict.Primary
    let muted: Bool
    let onReport: () -> Void
    let onPark: () -> Void
    let onToggleVoice: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: WP.Space.s2) {
                parkButton
                HStack(spacing: WP.Space.s2) {
                    reportButton(pill: true)
                    voiceButton(pill: true)
                }
            }
        } else {
            HStack(alignment: .center, spacing: WP.Space.s3) {
                reportButton(pill: false)
                parkButton
                voiceButton(pill: false)
            }
        }
    }

    @ViewBuilder
    private func reportButton(pill: Bool) -> some View {
        let button = Button("Report", action: onReport)
            .accessibilityHint("Drops a report at your current location.")
        if pill {
            button.buttonStyle(WPDrivePillStyle())
        } else {
            button.buttonStyle(WPDriveRoundStyle())
        }
    }

    @ViewBuilder
    private func voiceButton(pill: Bool) -> some View {
        let button = Button(WPDriveVerdict.voiceTitle(muted: muted), action: onToggleVoice)
            .accessibilityLabel(muted ? "Voice off" : "Voice on")
            .accessibilityHint(muted ? "Turns spoken parking callouts on." : "Turns spoken parking callouts off.")
        if pill {
            button.buttonStyle(WPDrivePillStyle())
        } else {
            button.buttonStyle(WPDriveRoundStyle())
        }
    }

    @ViewBuilder
    private var parkButton: some View {
        let button = Button(primary.title, action: onPark)
            .accessibilityHint("Opens a safety checklist before saving your parked car.")
        if primary.isRaised {
            button.buttonStyle(.wpPrimary)
        } else {
            button.buttonStyle(WPDrivePillStyle(minHeight: WP.Target.drive, fontSize: 24))
        }
    }
}

// MARK: - Bottom stack

/// Scrolls only when its content is taller than `maxHeight` (AX sizes on a short phone).
private struct WPFitScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Indicators stay visible: if the content ever overflows, the driver can see there is more.
        ScrollView(.vertical, showsIndicators: true) {
            content()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
    }
}

/// The drive card: both sides, then Report / Park here / Voice.
struct WPDriveBottomV2: View {
    let context: DrivingContext?
    let muted: Bool
    let onReport: () -> Void
    let onPark: () -> Void
    let onToggleVoice: () -> Void

    var body: some View {
        let sides = WPDriveVerdict.sides(for: context)
        // Only the verdicts scroll (AX sizes on a short phone); the actions stay pinned in view.
        VStack(spacing: WP.Space.s3) {
            WPFitScroll(maxHeight: UIScreen.main.bounds.height * 0.55) {
                WPDriveSidesV2(left: sides.left, right: sides.right)
            }
            WPDriveActionsV2(
                primary: WPDriveVerdict.primary(left: sides.left, right: sides.right),
                muted: muted, onReport: onReport, onPark: onPark, onToggleVoice: onToggleVoice
            )
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.top, WP.Space.s2)
        .padding(.bottom, WP.Space.s3)
        .dynamicTypeSize(...WPDriveVerdict.maxDriveTypeSize(screenHeight: UIScreen.main.bounds.height))
    }
}

// MARK: - Top chrome

/// Street pill (left), End (right), and the destination line under them.
struct WPDriveTopChromeV2: View {
    let street: String?
    let destinationLine: String?
    let approaching: Bool
    let endAccessibilityLabel: String
    let onEnd: () -> Void
    /// DT35-5: "Eastbound" etc. Nil (default) shows the street alone.
    var direction: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            // One row at every size (street wraps by words, End stays a large pill): at accessibility
            // sizes a stacked street + End row would cost the verdicts a whole row of screen.
            let layout = HStackLayout(alignment: .top, spacing: WP.Space.s3)
            layout {
                if let street {
                    Text(WPDriveDirection.pillText(street: street, direction: direction))
                        .font(WP.Font.fredoka(22, .semibold, relativeTo: .title3))
                        .foregroundStyle(WPDrivePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, WP.Space.s5)
                        .padding(.vertical, WP.Space.s2)
                        .frame(minHeight: 56, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(WPDrivePalette.white))
                        .accessibilityLabel(WPDriveDirection.accessibilityText(street: street, direction: direction))
                }
                Spacer(minLength: 0)
                Button("End", action: onEnd)
                    .buttonStyle(WPDrivePillStyle(minHeight: WP.Control.inkPillHeight, fontSize: 22))
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(endAccessibilityLabel)
            }
            if let destinationLine {
                Text(destinationLine)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .foregroundStyle(approaching ? WPDrivePalette.ink : WPDrivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WP.Space.s4)
                    .padding(.vertical, WP.Space.s2)
                    .frame(minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(approaching ? WP.taxi : WPDrivePalette.surface.opacity(0.92))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(approaching ? WP.ink : WP.hairline.opacity(0.6), lineWidth: 1.5))
                    .accessibilityLabel(destinationLine)
            }
        }
        .padding(.horizontal, WP.Space.s4)
        .dynamicTypeSize(...WPDriveVerdict.maxDriveTypeSize(screenHeight: UIScreen.main.bounds.height))
    }
}

// MARK: - Arrival prompt (B5.8)

/// "You've arrived. Park here?" on the ink ground. Same two actions as the existing prompt:
/// Park here (drops the pin at the user's current GPS) and Keep looking (Drive Mode stays on).
struct WPArrivalPromptV2: View {
    let context: DrivingContext?
    let arrivalCoordinate: CLLocationCoordinate2D
    let onParkHere: (CLLocationCoordinate2D) -> Void
    let onNotYet: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    private func parkButton(_ primary: WPDriveVerdict.Primary) -> some View {
        let button = Button(primary.title) { onParkHere(arrivalCoordinate) }
            .accessibilityHint("Saves your parked car at your current location and ends Drive Mode.")
        if primary.isRaised {
            button.buttonStyle(.wpPrimary)
        } else {
            button.buttonStyle(WPDrivePillStyle(minHeight: WP.Target.drive, fontSize: 24))
        }
    }

    /// The arrival sheet's detents. At accessibility sizes it opens full height: the decision (both
    /// sides' verdicts, Park here, Keep looking) has to be visible with no scrolling, and at AX the
    /// half-height sheet cannot hold it even with the compact rows and the capped type (PR #206 QA
    /// finding #1). Standard sizes keep the half-height sheet with the option to pull it up.
    static func detents(accessibilitySize: Bool) -> Set<PresentationDetent> {
        accessibilitySize ? [.large] : [.medium, .large]
    }

    var body: some View {
        let sides = WPDriveVerdict.sides(for: context)
        let primary = WPDriveVerdict.primary(left: sides.left, right: sides.right)
        let offered = [sides.left, sides.right].filter { $0.kind.isParkable }
        let others = [sides.left, sides.right].filter { !$0.kind.isParkable && $0.kind != .checking }
        let compact = dynamicTypeSize.isAccessibilitySize
        // The two decision buttons are pinned below the scrolling content so they are always fully
        // visible, even at AX5 on a short phone (PR #203 QA finding #1). Only the text scrolls.
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? WP.Space.s2 : WP.Space.s4) {
                // One heading line at accessibility sizes (two stacked 34 pt lines cost a whole row
                // of a short phone); the two-line heading at standard sizes.
                Group {
                    if compact {
                        Text("You've arrived. Park here?")
                            .font(WP.Font.fredoka(26, .bold, relativeTo: .title))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("You've arrived.")
                            Text("Park here?")
                        }
                        .font(WP.Font.fredoka(34, .bold, relativeTo: .largeTitle))
                    }
                }
                .foregroundStyle(WPDrivePalette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if compact {
                    // The drive card's one-row-per-side layout, in street order (left over right):
                    // both verdicts are always visible together, never a plain line cut by a button.
                    ForEach([sides.left, sides.right].filter { $0.kind != .checking }, id: \.isLeft) { side in
                        WPDriveSideRowAX(side: side)
                    }
                } else {
                    ForEach(offered, id: \.isLeft) { side in
                        WPDriveSideCard(side: side)
                    }
                    ForEach(others, id: \.isLeft) { side in
                        Text(side.plainLine)
                            .font(WP.Font.fredoka(17, .medium, relativeTo: .body))
                            .foregroundStyle(WPDrivePalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, WP.Space.s5)
            .padding(.top, compact ? WP.Space.s4 : WP.Space.s5)
            .padding(.bottom, WP.Space.s3)
        }
        .scrollBounceBehavior(.basedOnSize)

        VStack(spacing: WP.Space.s3) {
            parkButton(primary)
            Button("Keep looking", action: onNotYet)
                .buttonStyle(WPDrivePillStyle(minHeight: WP.Target.drive, fontSize: 22))
                .accessibilityHint("Closes this prompt. Drive Mode stays on.")
        }
        .padding(.horizontal, WP.Space.s5)
        .padding(.bottom, WP.Space.s5)
        }
        .dynamicTypeSize(...WPDriveVerdict.maxDriveTypeSize(screenHeight: UIScreen.main.bounds.height))
        .background(Color(wpHex: WP.Hex.darkBackground))
    }
}

// MARK: - Park Until pill in the Stoop drive stack (DT35-8)

extension View {
    /// Stoop drive only: caps the Park Until pill's type at AX1 and lets it grow to its wrapped
    /// height. At AX5 the pill was squeezed into a one-line frame while its text rendered three
    /// lines tall, overlapping the street pill and the Apple Maps attribution. With `stoop`
    /// false this is a no-op (range up to AX5, no fixed size), so flag-off layout is unchanged.
    func wpDrivePillLayout(stoop: Bool) -> some View {
        self
            .dynamicTypeSize(...(stoop ? DynamicTypeSize.accessibility1 : DynamicTypeSize.accessibility5))
            .fixedSize(horizontal: false, vertical: stoop)
    }
}
