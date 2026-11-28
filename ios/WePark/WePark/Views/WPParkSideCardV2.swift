//
//  WPParkSideCardV2.swift
//  WePark
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1 section 1C): the Stoop park card that
//  replaces `ParkConfirmView` when `AppConstants.designSystemV2Enabled`. All state and copy live in
//  `DesignSystem/WPParkSideLogic.swift`; this file only draws them.
//
//    ask       "Which side did you park on?", a mini map with both curbs tappable, and two big
//              buttons ("Curb on my right" / "Curb on my left", or "This side" with no usable
//              course). No verdict, no free-until, no green or red until a side is chosen.
//    picked    address, side line, verdict, "Park here", and "Other side of the street".
//    weakFix   "Waiting for a better GPS signal" (nothing is picked).
//    noCurb    today's no-data wording and a plain save.
//
//  Targets are roomy on purpose (Kevin's rule, and this is a drive surface): choice buttons and
//  the switch are 72 pt tall at default size and grow with text.
//

import CoreLocation
import SwiftUI

struct WPParkSideCardV2: View {

    let segments: [Segment]
    /// Observed here (not in the owner) so hints and the address update this view directly.
    let addresses: ParkingAddressCoordinator
    /// The verdict for a curb (engine, clock, window, trip and neighbor reports are the owner's).
    let verdict: (Segment) -> WPCurbSheetModel
    /// Reports what the card is about, so the owner can resolve addresses for it.
    let onFocus: (WPParkSideFocus) -> Void
    let onPark: (ParkSidePick) -> Void
    /// noCurb: save the car at the raw position with no street (the legacy "no parking info" save).
    let onSaveWithoutCurb: () -> Void
    /// weakFix "Try again": a fresh decision from the latest fix.
    let onRetry: () -> ParkSideDecision
    /// weakFix "Place it on the map".
    let onPlaceOnMap: () -> Void
    let onCancel: () -> Void

    @State private var model: WPParkSideCardModel
    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        decision: ParkSideDecision,
        segments: [Segment],
        addresses: ParkingAddressCoordinator,
        verdict: @escaping (Segment) -> WPCurbSheetModel,
        onFocus: @escaping (WPParkSideFocus) -> Void,
        onPark: @escaping (ParkSidePick) -> Void,
        onSaveWithoutCurb: @escaping () -> Void,
        onRetry: @escaping () -> ParkSideDecision,
        onPlaceOnMap: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.segments = segments
        self.addresses = addresses
        self.verdict = verdict
        self.onFocus = onFocus
        self.onPark = onPark
        self.onSaveWithoutCurb = onSaveWithoutCurb
        self.onRetry = onRetry
        self.onPlaceOnMap = onPlaceOnMap
        self.onCancel = onCancel
        _model = State(initialValue: WPParkSideCardModel(decision: decision, segments: segments))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
                switch model.phase {
                case .ask: askContent
                case .picked: pickedContent
                case .weakFix: weakFixContent
                case .noCurb: noCurbContent
                }
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s5)
            .padding(.bottom, WP.Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(WP.card.ignoresSafeArea())
        .presentationDetents(model.phase == .ask || typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .onAppear { onFocus(model.focus) }
        .onChange(of: model.focus) { _, focus in onFocus(focus) }
        // Dismissed any way (save, cancel, swipe): drop the address work done for this card.
        .onDisappear { onFocus(.none) }
    }

    // MARK: Header

    private func header(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .top, spacing: WP.Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(WPParkSideCopy.cancel, action: onCancel)
                .buttonStyle(WPClosePillStyle())
        }
    }

    // MARK: Ask

    @ViewBuilder
    private var askContent: some View {
        header(WPParkSideCopy.askTitle)
        Text(WPParkSideCopy.askHint)
            .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
            .foregroundStyle(WP.muted)
            .fixedSize(horizontal: false, vertical: true)
        let choices = model.askChoices(hints: addresses.sideHints)
        if let choice = model.choice {
            WPParkSideMiniMap(
                choice: choice,
                height: typeSize.isAccessibilitySize ? 120 : 168,
                onChoose: { option in model.choose(option) }
            )
        }
        VStack(spacing: WP.Space.s3) {
            ForEach(choices) { item in
                Button { model.choose(item.option) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(WP.Font.fredoka(20, .semibold, relativeTo: .title3))
                            .foregroundStyle(WP.text)
                        Text(item.detail)
                            .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                            .foregroundStyle(WP.muted)
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WPParkSideChoiceStyle())
                .accessibilityLabel(item.spoken)
            }
        }
    }

    // MARK: Picked

    @ViewBuilder
    private var pickedContent: some View {
        if let current = model.current {
            let verdictModel = verdict(current.segment)
            header(
                addresses.placementAddress.map(ParkingAddressCopy.line)
                    ?? StreetNameFormatter.displayCanonical(current.segment.street),
                subtitle: model.pickedSideLine
            )
            WPVerdictBlock(
                kind: verdictModel.variant.blockKind, over: verdictModel.over, big: verdictModel.big,
                sub: verdictModel.sub,
                fractionLeft: verdictModel.variant == .park ? verdictModel.fractionLeft : nil
            )
            if !verdictModel.offersPrimaryPark {
                Text(WPParkCopy.warning(for: verdictModel.variant))
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.noParkText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            parkButton(verdictModel, pick: current)
            if model.canSwitch {
                Button { model.switchSide() } label: { Text(WPParkSideCopy.otherSide) }
                    .buttonStyle(WPParkSideSecondaryStyle())
            }
        }
    }

    @ViewBuilder
    private func parkButton(_ verdictModel: WPCurbSheetModel, pick: ParkSidePick) -> some View {
        if verdictModel.offersPrimaryPark {
            Button(verdictModel.ctaTitle) { onPark(pick) }
                .buttonStyle(RaisedButtonStyle(size: .commitment))
                .padding(.bottom, WP.Raise.lg)
        } else {
            Button { onPark(pick) } label: {
                Text(verdictModel.ctaTitle)
                    .font(WP.Font.fredoka(19, .semibold, relativeTo: .title3))
                    .foregroundStyle(WP.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WP.Space.s4)
                    .padding(.vertical, WP.Space.s2)
                    .frame(maxWidth: .infinity, minHeight: WP.Control.commitmentHeight)
                    .background(Capsule().fill(WP.card))
                    .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Weak fix

    @ViewBuilder
    private var weakFixContent: some View {
        header(WPParkSideCopy.weakFixTitle)
        Text(WPParkSideCopy.weakFixBody)
            .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
        Button(WPParkSideCopy.tryAgain) {
            model = WPParkSideCardModel(decision: onRetry(), segments: segments)
        }
        .buttonStyle(RaisedButtonStyle(size: .commitment))
        .padding(.bottom, WP.Raise.lg)
        Button(WPParkSideCopy.placeOnMap, action: onPlaceOnMap)
            .buttonStyle(WPParkSideSecondaryStyle())
    }

    // MARK: No curb

    @ViewBuilder
    private var noCurbContent: some View {
        header(CurbPlacementCardCopy.noDataTitle, subtitle: CurbPlacementCardCopy.noDataParkSubtitle)
        Button(WPParkSideCopy.noCurbSave, action: onSaveWithoutCurb)
            .buttonStyle(RaisedButtonStyle(size: .commitment))
            .padding(.bottom, WP.Raise.lg)
    }
}

// MARK: - Mini map

/// Schematic map of the block: both curbs, the road between them, and the car. Not map tiles, so the
/// hit areas are exact: the upper half taps the upper curb, the lower half the lower one. Neutral
/// colors only (no green or red before a choice). Hidden from VoiceOver: the buttons below carry the
/// same choice with full labels.
struct WPParkSideMiniMap: View {
    let choice: ParkSideChoice
    let height: CGFloat
    let onChoose: (ParkSideOption) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = WPParkSideMiniMapLayout.make(
                first: choice.first.segment.coordinates,
                second: choice.second.segment.coordinates,
                car: choice.position,
                travelBearing: choice.travelBearing,
                size: proxy.size
            )
            ZStack {
                if let layout {
                    drawing(layout, size: proxy.size)
                    tapAreas(layout, size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
            .strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WPParkSideCopy.miniMapLabel)
        .accessibilityHidden(true)
    }

    private func drawing(_ layout: WPParkSideMiniMapLayout.Layout, size: CGSize) -> some View {
        ZStack {
            WP.lifted
            // The road surface between the curbs.
            Path { path in
                guard let start = layout.first.first else { return }
                path.move(to: start)
                for point in layout.first.dropFirst() { path.addLine(to: point) }
                for point in layout.second.reversed() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .fill(WP.hairline.opacity(0.35))
            curbLine(layout.first)
            curbLine(layout.second)
            curbLabel(choice.first.segment.side, points: layout.first, upper: layout.firstIsUpper, size: size)
            curbLabel(choice.second.segment.side, points: layout.second, upper: !layout.firstIsUpper, size: size)
            carDot(layout)
        }
    }

    private func curbLine(_ points: [CGPoint]) -> some View {
        Path { path in
            guard let start = points.first else { return }
            path.move(to: start)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(WP.text, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }

    private func curbLabel(_ side: String, points: [CGPoint], upper: Bool, size: CGSize) -> some View {
        let meanY = points.map(\.y).reduce(0, +) / CGFloat(max(points.count, 1))
        let y = upper ? meanY - 14 : meanY + 14
        return Text(WPCurbCopy.sideLabel(side))
            .font(WP.Font.fredoka(12, .semibold, relativeTo: .caption))
            .foregroundStyle(WP.text)
            .position(x: size.width / 2, y: min(max(y, 10), size.height - 10))
    }

    private func carDot(_ layout: WPParkSideMiniMapLayout.Layout) -> some View {
        ZStack {
            Circle().fill(WP.taxi)
            Circle().strokeBorder(WP.ink, lineWidth: 3)
            if layout.showsTravelArrow {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WP.ink)
            }
        }
        .frame(width: 22, height: 22)
        .position(layout.car)
    }

    private func tapAreas(_ layout: WPParkSideMiniMapLayout.Layout, size: CGSize) -> some View {
        let upperOption = layout.firstIsUpper ? choice.first : choice.second
        let lowerOption = layout.firstIsUpper ? choice.second : choice.first
        let divider = min(max(layout.dividerY, 0), size.height)
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: divider)
                .contentShape(Rectangle())
                .onTapGesture { onChoose(upperOption) }
            Color.clear
                .frame(height: max(0, size.height - divider))
                .contentShape(Rectangle())
                .onTapGesture { onChoose(lowerOption) }
        }
    }
}

// MARK: - Button styles

/// A big two-line choice: card fill, line border, 72 pt minimum height.
struct WPParkSideChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        configuration.label
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, minHeight: WP.Target.driveMin, alignment: .leading)
            .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.control))
            .contentShape(shape)
    }
}

/// The "Other side of the street" secondary: a full-width pill, 64 pt minimum, text scales.
struct WPParkSideSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
            .foregroundStyle(WP.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WP.Space.s5)
            .padding(.vertical, WP.Space.s2)
            .frame(maxWidth: .infinity, minHeight: WP.Target.standard)
            .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.control))
            .contentShape(shape)
    }
}
