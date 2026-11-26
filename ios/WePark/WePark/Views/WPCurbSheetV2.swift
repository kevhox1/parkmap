//
//  WPCurbSheetV2.swift
//  WePark
//
//  Phase 2b, B4: the flag-on curb detail sheet (docs/design/wepark-round2, WPCurbSheet).
//  Presented in place of `BlockDetailView` ONLY while `AppConstants.designSystemV2Enabled` is
//  true. Flag off never reaches this file.
//
//  Pure presentation: `WPCurbSheetBuilder` (engine) decides the verdict, `WPNeighborVerdict`
//  decides how a neighbor report may change it (stricter only), `WPSignList` writes the sign
//  lines. This view draws them.
//
//  Layout: header (street, side, between X and Y, Close), verdict block, neighbor notes,
//  "See the N signs on this curb", then Report + Park here. The action row is pinned; at
//  accessibility sizes Report moves into the scrolling content so "Park here" keeps the room.
//

import CoreLocation
import SwiftUI

// MARK: - Sheet

struct WPCurbSheetV2: View {
    let model: WPCurbSheetModel
    let signs: [WPSignLine]
    /// Reported restriction (filming / construction) covering this curb, if any.
    var reportedRestriction: CommunityPin? = nil
    /// Live sweeper-passed pin covering this curb, if any (info only, never changes the verdict).
    var sweeperPin: CommunityPin? = nil
    /// Pins anchored to this curb ("ON THIS BLOCK NOW").
    var livePins: [CommunityPin] = []
    var now: Date = .nowET
    var segmentID: String = ""
    var segmentMidpoint: CLLocationCoordinate2D? = nil
    var zoneMessageService: ZoneMessageService? = nil
    var zoneStore: ZoneStore? = nil
    var pinService: CommunityPinService? = nil
    var planTag: String? = nil
    let onClose: () -> Void
    let onPark: () -> Void
    var onReport: (() -> Void)? = nil
    var onOpenPin: ((CommunityPin) -> Void)? = nil
    /// Start expanded (screenshots / tests only; the real sheet starts collapsed).
    var startsWithSignsOpen = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var signsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    header
                    if model.variant.isPlan, let planTag {
                        WPTripPlanTag(dates: planTag)
                    }
                    verdictBlock
                    notes
                    signsSection
                    if !model.variant.isPlan { liveSection }
                    if !model.variant.isPlan, AppConstants.communityEnabled {
                        WPBlockChatter(
                            segmentID: segmentID, midpoint: segmentMidpoint,
                            service: zoneMessageService, zoneStore: zoneStore
                        )
                    }
                    if typeSize.isAccessibilitySize, !model.variant.isPlan, let onReport {
                        reportButton(onReport)
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s5)
                .padding(.bottom, WP.Space.s3)
            }
            .scrollBounceBehavior(.basedOnSize)

            if !model.variant.isPlan { actions }
        }
        .background(WP.card.ignoresSafeArea())
        .onAppear { signsOpen = startsWithSignsOpen }
    }

    // MARK: Header

    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s3))
            : AnyLayout(HStackLayout(alignment: .top, spacing: WP.Space.s3))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let cross = model.cross {
                    Text(cross)
                        .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button(action: onClose) {
                Text("Close")
                    .font(WP.Font.fredoka(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(WP.text)
                    .padding(.horizontal, WP.Space.s2)
                    .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
                    .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close curb details")
        }
    }

    // MARK: Verdict

    private var verdictBlock: some View {
        WPVerdictBlock(
            kind: model.variant.blockKind,
            over: model.over,
            big: model.big,
            sub: model.sub,
            fractionLeft: model.variant == .park ? model.fractionLeft : nil
        )
        .padding(.top, WP.Space.s1)
        .padding(model.variant == .planpark ? WP.Space.s2 : 0)
    }

    // MARK: Neighbor notes (B4.8 / B4.9). Flat facts: they add information, never change the verdict.

    @ViewBuilder
    private var notes: some View {
        if let pin = reportedRestriction, !model.variant.isPlan {
            reportedRestrictionNote(pin)
        }
        if let pin = sweeperPin, !model.variant.isPlan {
            sweptNote(pin)
        }
    }

    private func reportedRestrictionNote(_ pin: CommunityPin) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        let kind = pin.pinType == .construction ? "Construction" : "Film shoot"
        let age = PinMarkerAnnotation.ageString(since: pin.createdAt, now: now)
        let author = AuthorDisplayName.name(for: pin)
        var line = "Reported \(age.lowercased()) by \(author)."
        if let expires = pin.expiresAt {
            line += " Expires \(WPCurbCopy.when(expires, now: now))."
        }
        return Button { onOpenPin?(pin) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind) reported by neighbors")
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                Text(line)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
            }
            .foregroundStyle(WP.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(WP.Space.s4)
            .frame(maxWidth: .infinity, minHeight: WP.Target.minimum, alignment: .leading)
            .background(shape.fill(WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the report")
    }

    private func sweptNote(_ pin: CommunityPin) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        let age = PinMarkerAnnotation.ageString(since: pin.createdAt, now: now)
        let confirms = ParkedCarDetailLogic.confirmCountLabel(pin.confirmCount)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Swept \(age.lowercased())")
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
            Text("\(confirms). The sign still applies; check it before you rely on the sweep.")
                .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                .foregroundStyle(WP.muted)
        }
        .foregroundStyle(WP.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }

    // MARK: Signs (B4.11): the real sign text is always reachable

    @ViewBuilder
    private var signsSection: some View {
        if model.signCount > 0 || !signs.isEmpty {
            VStack(alignment: .leading, spacing: WP.Space.s2) {
                if signsOpen {
                    ForEach(signs) { sign in
                        signRow(sign)
                    }
                }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { signsOpen.toggle() }
                } label: {
                    Text(signsOpen ? "Hide the signs" : signsLabel)
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .underline()
                        .foregroundStyle(WP.text)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: WP.Target.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(signsOpen ? "Collapses the sign list" : "Shows the full posted text")
            }
        }
    }

    private var signsLabel: String {
        model.signCount == 1 ? "See the 1 sign on this curb" : "See the \(model.signCount) signs on this curb"
    }

    private func signRow(_ sign: WPSignLine) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            Text(sign.text)
                .font(WP.Font.fredoka(14, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.text)
            Text(sign.plain)
                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                .foregroundStyle(WP.muted)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(WP.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WP.paper))
        .overlay(shape.strokeBorder(WP.divider, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }

    // MARK: Live pins (B4.10)

    @ViewBuilder
    private var liveSection: some View {
        let pins = livePins
        if AppConstants.communityEnabled, !pins.isEmpty {
            VStack(alignment: .leading, spacing: WP.Space.s2) {
                Text("ON THIS BLOCK NOW")
                    .wpText(.label)
                    .foregroundStyle(WP.muted)
                    .accessibilityAddTraits(.isHeader)
                ForEach(pins) { pin in
                    livePinRow(pin)
                }
            }
        }
    }

    private func livePinRow(_ pin: CommunityPin) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        let isLeaving = pin.pinType == .leavingSoon
        // An open-spot report on a curb that is not green never reads as a spot.
        let notGreen = pin.pinType == .openSpot && model.variant != .park
        let sub = notGreen ? WPOpenSpotGate.listLine : CrewFeedMerge.subLine(for: pin, now: now)
        return Button { onOpenPin?(pin) } label: {
            HStack(spacing: WP.Space.s3) {
                Image(systemName: isLeaving ? "figure.walk.departure" : "exclamationmark.bubble.fill")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.ink)
                    .frame(width: WP.Marker.report, height: WP.Marker.report)
                    .background(
                        RoundedRectangle(cornerRadius: WP.Radius.marker, style: .continuous)
                            .fill(isLeaving ? WP.taxi : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: WP.Radius.marker, style: .continuous)
                            .strokeBorder(WP.ink, lineWidth: WP.Border.control)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.pinType.displayLabel)
                        .font(WP.Font.fredoka(16, .semibold, relativeTo: .body))
                        .foregroundStyle(WP.text)
                    Text(sub)
                        .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, WP.Space.s2)
            .frame(minHeight: WP.Control.rowMinHeight)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: WP.Space.s3) {
            if !typeSize.isAccessibilitySize, let onReport {
                Button(action: onReport) { Text("Report") }
                    .buttonStyle(.wpRound)
                    .accessibilityHint("Opens the report form for this curb")
            }
            parkButton
        }
        .padding(.horizontal, WP.Space.screenMargin)
        .padding(.top, WP.Space.s2)
        .padding(.bottom, WP.Space.s4)
        .background(WP.card)
    }

    @ViewBuilder
    private var parkButton: some View {
        if model.offersPrimaryPark {
            Button(model.ctaTitle, action: onPark)
                .buttonStyle(RaisedButtonStyle(size: .commitment))
                .padding(.bottom, WP.Raise.lg)
                .accessibilityHint("Saves your car on this curb")
        } else {
            // Don't, unclear, no data, metered: flat outline. Never the yellow raised button.
            Button(action: onPark) {
                Text(model.ctaTitle)
                    .font(WP.Font.fredoka(19, .semibold, relativeTo: .title3))
                    .foregroundStyle(WP.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WP.Space.s4)
                    .frame(maxWidth: .infinity, minHeight: WP.Control.commitmentHeight)
                    .background(Capsule().fill(WP.card))
                    .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("This curb is not a clear spot. Saves your car here anyway.")
        }
    }

    private func reportButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Report a problem on this curb")
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                .foregroundStyle(WP.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: WP.Control.secondaryHeight)
                .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Block chatter (B4.10)

/// Segment-anchored chat thread with a compose bar. Same service calls and decision logic as
/// `BlockDetailView`'s "BLOCK CHATTER" section (`ZoneMessageService.fetchMessages(segmentId:)` /
/// `sendMessage`, `BlockDetailLogic`, `ZoneMessageComposeLogic`, `CommunityIdentityGate`),
/// restyled. Community flag gates the mount at the call site.
struct WPBlockChatter: View {
    let segmentID: String
    let midpoint: CLLocationCoordinate2D?
    let service: ZoneMessageService?
    let zoneStore: ZoneStore?

    @State private var messages: [ZoneMessage] = []
    @State private var isLoading = false
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var pendingIdentityAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            Text("BLOCK CHATTER")
                .wpText(.label)
                .foregroundStyle(WP.muted)
                .accessibilityAddTraits(.isHeader)

            if isLoading && messages.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, WP.Space.s2)
            } else if BlockDetailLogic.showsEmptyChatterState(messages: messages, isLoading: isLoading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No chatter yet")
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                    Text("Be the first. Crews form block by block.")
                        .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                }
                .accessibilityElement(children: .combine)
            } else {
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CrewFeedMerge.subLine(for: message, now: .nowET))
                            .font(WP.Font.fredoka(13, .medium, relativeTo: .caption))
                            .foregroundStyle(WP.muted)
                        Text(message.body)
                            .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                            .foregroundStyle(WP.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, WP.Space.s1)
                    .accessibilityElement(children: .combine)
                }
            }

            compose

            if let sendError {
                Text(sendError)
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.noParkText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
        .onChange(of: service?.lastRealtimeInsertGeneration) { _, _ in appendRealtime() }
        .sheet(isPresented: Binding(
            get: { pendingIdentityAction != nil },
            set: { if !$0 { pendingIdentityAction = nil } }
        )) {
            IdentitySheet(
                onSave: { _, _ in
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    action?()
                },
                onSkip: {
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    action?()
                }
            )
            .presentationDetents([.medium])
        }
    }

    private var compose: some View {
        HStack(spacing: WP.Space.s2) {
            TextField("Say something to the block", text: $draft)
                .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                .padding(.horizontal, WP.Space.s4)
                .frame(minHeight: WP.Target.minimum)
                .background(Capsule().fill(WP.card))
                .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.fact))
                .accessibilityLabel("Message this block")
            Button(action: submit) {
                Group {
                    if isSending { ProgressView() } else { Text("Send") }
                }
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .padding(.horizontal, WP.Space.s4)
                .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
                .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSending || !ZoneMessageComposeLogic.canSend(draft: draft) || service == nil)
        }
    }

    private func load() async {
        guard AppConstants.communityEnabled, let service else { return }
        isLoading = true
        if let fetched = try? await service.fetchMessages(segmentId: segmentID) { messages = fetched }
        isLoading = false
    }

    private func appendRealtime() {
        guard let message = service?.lastRealtimeInsert,
              BlockDetailLogic.shouldAppendRealtimeMessage(
                message, segmentId: segmentID, existingIds: Set(messages.map(\.id))
              ) else { return }
        messages.append(message)
    }

    private func submit() {
        let trimmed = ZoneMessageComposeLogic.trimmedBody(draft)
        guard !trimmed.isEmpty else { return }
        if BlockDetailLogic.shouldGateChatSend(identityGateShouldShow: CommunityIdentityGate().shouldShow()) {
            pendingIdentityAction = { Task { await send(trimmed) } }
            return
        }
        Task { await send(trimmed) }
    }

    private func send(_ body: String) async {
        guard let service else { return }
        sendError = nil
        guard let zoneId = BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: midpoint, zones: zoneStore?.zones ?? []) else {
            sendError = "Can't post here yet. This block is outside a supported neighborhood."
            return
        }
        isSending = true
        do {
            let sent = try await service.sendMessage(zoneId: zoneId, segmentId: segmentID, body: body)
            messages.append(sent)
            draft = ""
        } catch {
            sendError = "Couldn't send. Check your connection and try again."
        }
        isSending = false
    }
}
