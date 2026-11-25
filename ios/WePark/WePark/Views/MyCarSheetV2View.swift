//
//  MyCarSheetV2View.swift
//  WePark
//
//  The redesigned "My Car" sheet, dark-shipped behind `AppConstants.myCarSheetV2Enabled`
//  (`MyCarSheetVariant.resolve()` picks this or the untouched `ParkedCarDetailView`).
//
//  Owner feedback on the old sheet: "too much going on. We need to clean it up." So the main
//  surface is exactly five things, top to bottom:
//    1. Title (the address, else "E 1st St, North side") + one secondary line + close.
//    2. Hero status card (color = safe / soon / restricted) + one plain-English "Next:" line.
//    3. One reminder row showing the current setting; tap opens a small sheet.
//    4. One big "I'm leaving" button; tap opens a sheet with the hand-off options.
//    5. "See the signs" disclosure (raw sign text, deduped, full, with category tags).
//  Live-only extras (temporary-restriction banner, swept badge) appear under the hero only when
//  real. Everything else moved into the reminder sheet, the leaving sheet, or the signs area.
//
//  All behavior (reminder scheduling, leaving-soon post + identity gate, clear pin) is the same
//  code path the legacy sheet used; only the surface changed. Pure wording lives in
//  `Models/MyCarSheetV2Logic.swift`.
//

import SwiftUI

struct MyCarSheetV2View: View {

    // MARK: - Inputs (same as ParkedCarDetailView, plus the Spot Pass entry)

    let parkedCar: ParkedCar
    let engine: ParkingRulesEngine
    let loadedSegments: [Segment]
    let parkPinService: ParkPinService
    let scheduler: NotificationScheduler
    let aspService: ASPSuspensionService
    let pinService: CommunityPinService?
    let onDismiss: () -> Void
    let onClearPin: () -> Void
    let onOpenRestriction: ((CommunityPin) -> Void)?
    /// Non-nil only when Spot Pass is available (flag on and not in trip mode); the caller dismisses
    /// this sheet and raises the existing driver/seeker cover.
    let onOpenSpotPass: (() -> Void)?
    /// An armed driver pass exists: the leaving sheet says "Your Spot Pass" instead.
    let spotPassArmed: Bool

    // MARK: - State

    @State private var remindMe: Bool
    @State private var offsets: ReminderOffsets
    @State private var signsExpanded = false
    @State private var activeSheet: SubSheet?
    @State private var leavingMinutes: Int = 10
    @State private var leavingSoonSubmitting = false
    @State private var leavingSoonJustPosted = false
    @State private var leavingSoonError: String?
    @State private var pendingIdentityAction: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum SubSheet: String, Identifiable {
        case reminders
        case leaving
        var id: String { rawValue }
    }

    private let now: Date = .nowET
    private static let positionFractionSearchRadiusMeters: Double = 35.0

    init(
        parkedCar: ParkedCar,
        engine: ParkingRulesEngine,
        loadedSegments: [Segment],
        parkPinService: ParkPinService,
        scheduler: NotificationScheduler = .shared,
        aspService: ASPSuspensionService = ASPSuspensionService(),
        pinService: CommunityPinService? = nil,
        onDismiss: @escaping () -> Void,
        onClearPin: @escaping () -> Void,
        onOpenRestriction: ((CommunityPin) -> Void)? = nil,
        onOpenSpotPass: (() -> Void)? = nil,
        spotPassArmed: Bool = false
    ) {
        self.parkedCar = parkedCar
        self.engine = engine
        self.loadedSegments = loadedSegments
        self.parkPinService = parkPinService
        self.scheduler = scheduler
        self.aspService = aspService
        self.pinService = pinService
        self.onDismiss = onDismiss
        self.onClearPin = onClearPin
        self.onOpenRestriction = onOpenRestriction
        self.onOpenSpotPass = onOpenSpotPass
        self.spotPassArmed = spotPassArmed
        _remindMe = State(initialValue: parkedCar.notifyOnRestriction)
        _offsets = State(initialValue: ReminderOffsets.load(from: .standard))
    }

    // MARK: - Derived

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var resolvedSegment: Segment? {
        guard let sid = parkedCar.detectedSegmentID else { return nil }
        return loadedSegments.first { $0.id == sid }
    }

    private var currentNow: Date { pinService?.nowProvider() ?? now }

    private var blockScopedRestriction: CommunityPin? {
        guard let seg = resolvedSegment else { return nil }
        return pinService?.blockScopedRestriction(forBlockfaceKey: seg.blockfaceKey)
    }

    private var sweptStatusPin: CommunityPin? {
        ParkedCarDetailLogic.liveSweeperPin(
            in: pinService?.visiblePins ?? [],
            segmentId: resolvedSegment?.id,
            now: currentNow,
            communityEnabled: AppConstants.communityEnabled
        )
    }

    private var aspSuspensionNoteText: String? {
        guard let seg = resolvedSegment else { return nil }
        return ParkedCarDetailLogic.aspSuspensionNote(
            segmentHasASPRule: ParkedCarDetailLogic.segmentHasASPRule(seg),
            suspensionReason: aspService.reasonForSuspension(now)
        )
    }

    private var ownLiveLeavingSoonPin: CommunityPin? {
        ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: pinService?.visiblePins ?? [],
            authorId: pinService?.authService?.currentUserId,
            segmentId: resolvedSegment?.id,
            carLatitude: parkedCar.latitude,
            carLongitude: parkedCar.longitude,
            now: currentNow,
            communityEnabled: AppConstants.communityEnabled
        )
    }

    private var isLeavingSoonPosted: Bool {
        ParkedCarDetailLogic.isLeavingSoonPosted(justPosted: leavingSoonJustPosted, ownLivePin: ownLiveLeavingSoonPin)
    }

    private var leavingSoonConfirmationText: String {
        guard let pin = ownLiveLeavingSoonPin, let expiresAt = pin.expiresAt else {
            return "Neighbors have been told"
        }
        let remaining = MyCarSheetV2Logic.leavingSoonMinutesLeft(
            expiresAt: expiresAt, now: currentNow, leavingMinutes: pin.leavingMinutes
        )
        guard remaining > 0 else { return "Neighbors have been told" }
        return "Neighbors have been told \u{2014} \(remaining) min left"
    }

    private var showsReminderDetail: Bool { AppConstants.communityEnabled }

    private var reminderSummary: String {
        MyCarSheetV2Logic.reminderSummary(remindMe: remindMe, offsets: offsets, showDetail: showsReminderDetail)
    }

    /// The leaving sheet only exists when it has something besides "clear my car" to offer.
    private var leaveOpensSheet: Bool {
        MyCarSheetV2Logic.leaveButtonOpensSheet(
            communityEnabled: AppConstants.communityEnabled,
            spotPassAvailable: onOpenSpotPass != nil
        )
    }

    // MARK: - Header text

    private var liveAddress: ParkingAddress? {
        guard AppConstants.addressAnchoredParkingEnabled else { return nil }
        return (parkPinService.parkedCar?.id == parkedCar.id ? parkPinService.parkedCar?.address : nil) ?? parkedCar.address
    }

    private var streetName: String? {
        if let seg = resolvedSegment { return StreetNameFormatter.displayCanonical(seg.street) }
        if let street = parkedCar.street { return StreetNameFormatter.displayCanonical(street) }
        return nil
    }

    private var sideName: String? {
        if let seg = resolvedSegment { return Self.sideLabel(seg.side) }
        if let side = parkedCar.detectedSide { return Self.sideLabel(side) }
        return nil
    }

    private var crossStreets: String? {
        if let seg = resolvedSegment {
            return MyCarSheetV2Logic.crossStreetRange(
                from: StreetNameFormatter.displayCanonical(seg.fromStreet),
                to: StreetNameFormatter.displayCanonical(seg.to)
            )
        }
        if let from = parkedCar.fromStreet, let to = parkedCar.toStreet {
            return MyCarSheetV2Logic.crossStreetRange(
                from: StreetNameFormatter.displayCanonical(from),
                to: StreetNameFormatter.displayCanonical(to)
            )
        }
        return nil
    }

    private var addressLine: String? {
        guard let address = liveAddress else { return nil }
        return ParkingAddressCopy.numberAndStreet(address)
    }

    private var titleText: String {
        let base = MyCarSheetV2Logic.title(addressLine: addressLine, street: streetName, side: sideName)
        guard let address = liveAddress, addressLine != nil, address.confidence == .approximate else { return base }
        return "Near \(base)"
    }

    private var titleSpoken: String {
        if let address = liveAddress { return ParkingAddressCopy.spoken(address) }
        return titleText
    }

    private var secondaryText: String {
        MyCarSheetV2Logic.secondaryLine(
            side: sideName,
            sideInTitle: addressLine == nil && streetName != nil && sideName != nil,
            crossStreets: crossStreets,
            parkedAgo: Self.relativeTime(from: parkedCar.parkedAt, now: now),
            hasData: resolvedSegment != nil
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                heroCard
                if let restriction = blockScopedRestriction {
                    TemporaryRestrictionBanner(pin: restriction, now: currentNow) {
                        onOpenRestriction?(restriction)
                    }
                }
                if let sweptPin = sweptStatusPin {
                    SweptBadgeView(pin: sweptPin, now: currentNow)
                }
                reminderRow
                leavingButton
                signsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .onChange(of: remindMe) { _, newValue in
            parkPinService.updateNotifyOnRestriction(newValue)
            if newValue {
                scheduler.schedule(
                    for: parkPinService.parkedCar ?? parkedCar,
                    loadedSegments: loadedSegments,
                    engine: engine
                )
            } else {
                scheduler.cancelAll(for: parkedCar)
            }
        }
        .onChange(of: offsets) { _, newOffsets in
            ReminderOffsets.save(newOffsets, to: .standard)
            guard remindMe else { return }
            scheduler.cancelAllThenSchedule(
                for: parkedCar,
                oldCarID: parkedCar.id,
                loadedSegments: loadedSegments,
                engine: engine
            )
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .reminders:
                remindersSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .leaving:
                leavingSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - 1. Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(titleSpoken)
                    .accessibilityAddTraits(.isHeader)
                Text(secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Close parked car details")
        }
    }

    // MARK: - 2. Hero status card

    private var heroState: CurrentState {
        guard let seg = resolvedSegment else { return .unknown }
        return engine.currentState(for: seg, at: now)
    }

    private var heroIcon: String {
        switch heroState {
        case .freeComfortably: return "checkmark.circle.fill"
        case .freeButRestrictionSoon: return "exclamationmark.triangle.fill"
        case .meteredActive: return "dollarsign.circle.fill"
        case .restrictedNow: return resolvedSegment?.hasNoSignData == true ? "questionmark.circle.fill" : "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var heroHeadline: String {
        guard let seg = resolvedSegment else { return "No parking data at this location" }
        return engine.safetyLabel(for: seg, at: now).text
    }

    private var nextLine: String? {
        guard let seg = resolvedSegment else { return nil }
        // No sign data: the sub-line is the "read the signs" advice, not a "Next:" schedule.
        if seg.hasNoSignData { return seg.noSignDataReason.map { $0 + " " + NoSignData.subline } ?? NoSignData.subline }
        return MyCarSheetV2Logic.nextMoveLine(
            restriction: engine.nextRestriction(for: seg, at: now),
            rules: seg.rules,
            dayOfWeek: now.dayOfWeekET,
            minuteOfDay: now.minuteOfDayET,
            now: now
        )
    }

    private var heroCard: some View {
        let tint = heroState.swiftUIColor
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: heroIcon)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(heroHeadline)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let nextLine {
                    Text(nextLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = aspSuspensionNoteText {
                    Label(note, systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 3. Reminder row

    private var reminderRow: some View {
        Button {
            activeSheet = .reminders
        } label: {
            Group {
                if isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) { reminderRowContent }
                } else {
                    HStack(spacing: 8) { reminderRowContent }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remind me. \(reminderSummary)")
        .accessibilityHint("Opens reminder options.")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var reminderRowContent: some View {
        Label {
            Text("Remind me")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: remindMe ? "bell.fill" : "bell.slash")
                .foregroundStyle(remindMe ? Color.accentColor : Color.secondary)
        }
        if !isAccessibilitySize { Spacer(minLength: 8) }
        HStack(spacing: 4) {
            Text(reminderSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(isAccessibilitySize ? .leading : .trailing)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 4. I'm leaving

    private var leavingButton: some View {
        Button {
            if leaveOpensSheet {
                activeSheet = .leaving
            } else {
                onClearPin()
            }
        } label: {
            Text("I\u{2019}m leaving")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel("I'm leaving")
        .accessibilityHint(leaveOpensSheet ? "Choose how to hand off your spot." : "Clears your parked car pin.")
    }

    // MARK: - 5. See the signs

    @ViewBuilder
    private var signsSection: some View {
        if let seg = resolvedSegment, !seg.rules.isEmpty, !seg.hasNoSignData {
            let rules = MyCarSheetV2Logic.dedupedRules(seg.rules.sorted { $0.category.priority < $1.category.priority })
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { signsExpanded.toggle() }
                } label: {
                    HStack {
                        Text("See the signs")
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(signsExpanded ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See the signs, \(rules.count)")
                .accessibilityValue(signsExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the full sign text for this block.")
                .accessibilityAddTraits(.isButton)

                if signsExpanded {
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        signRow(rule)
                    }
                }
            }
        }
    }

    private func signRow(_ rule: ParkingRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MyCarSheetV2Logic.signText(rule))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(rule.category.label)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reminders sheet

    private var remindersSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Remind me before parking changes", isOn: $remindMe)
                        .frame(minHeight: 44)
                }
                if remindMe && showsReminderDetail {
                    Section {
                        Toggle("15 min before", isOn: $offsets.remind15Min).frame(minHeight: 44)
                        Toggle("30 min before", isOn: $offsets.remind30Min).frame(minHeight: 44)
                        Toggle("1 hr before", isOn: $offsets.remind1Hour).frame(minHeight: 44)
                        Toggle("2 hr before", isOn: $offsets.remind2Hours).frame(minHeight: 44)
                    } header: {
                        Text("How long before")
                    } footer: {
                        Text("Pick any that apply. Each one sends its own reminder.")
                    }
                    Section {
                        Toggle("Night before (\(MyCarSheetV2Logic.clock(AppConstants.nightBeforeHourET * 60)))", isOn: $offsets.remindNightBefore)
                            .frame(minHeight: 44)
                    } footer: {
                        Text("Also remind me the evening before. This is separate from the times above.")
                    }
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
    }

    // MARK: - Leaving sheet

    private var leavingSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if AppConstants.communityEnabled {
                        tellNeighborsSection
                    }
                    if let onOpenSpotPass {
                        spotPassRow(onOpenSpotPass)
                    }
                    clearRow
                }
                .padding(20)
            }
            .navigationTitle("I\u{2019}m leaving")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
        // Identity gate for the leaving-soon post: nested on the leaving sheet itself so it never
        // competes with a second sheet presented from the parent.
        .sheet(isPresented: identitySheetPresented) {
            IdentitySheet(
                onSave: { username, avatar in
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    Task {
                        do {
                            try await pinService?.upsertProfile(username: username, avatar: avatar)
                        } catch {
                            #if DEBUG
                            print("[MyCarSheetV2View] upsertProfile failed: \(error)")
                            #endif
                        }
                    }
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

    /// Four chips in a row at normal sizes; a fixed 2x2 grid at accessibility sizes so each chip
    /// has half the sheet width and never has to break its label.
    private var leavingChipColumns: [GridItem] {
        if isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        }
        return [GridItem(.adaptive(minimum: 76), spacing: 8)]
    }

    private var tellNeighborsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tell neighbors")
                .font(.headline)
            Text("Posts a \u{201C}leaving soon\u{201D} pin here. Spots can\u{2019}t be held \u{2014} first come, first served.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLeavingSoonPosted {
                Label(leavingSoonConfirmationText, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            } else {
                LazyVGrid(columns: leavingChipColumns, spacing: 8) {
                    ForEach(ParkedCarDetailLogic.leavingSoonChipMinutes, id: \.self) { minutes in
                        minuteChip(minutes)
                    }
                }
                if let leavingSoonError {
                    Text(leavingSoonError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    Task { await submitLeavingSoon() }
                } label: {
                    Group {
                        if leavingSoonSubmitting {
                            ProgressView()
                        } else {
                            Text("Tell neighbors \u{2014} leaving in \(leavingMinutes)\u{00A0}min")
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                // Rounded rectangle, not the default capsule: at AX5 the label wraps to several
                // lines and a capsule turns into a large oval.
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .controlSize(.large)
                .disabled(leavingSoonSubmitting)
                .accessibilityLabel("Leaving in \(leavingMinutes) minutes. Tell neighbors.")
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func minuteChip(_ minutes: Int) -> some View {
        let selected = minutes == leavingMinutes
        return Button {
            leavingMinutes = minutes
        } label: {
            // Non-breaking space: "min" can never split from its number, and the chip wraps as
            // a whole unit (2x2 grid at accessibility sizes) rather than mid-word.
            Text("\(minutes)\u{00A0}min")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(minutes) minutes")
    }

    private func spotPassRow(_ open: @escaping () -> Void) -> some View {
        Button {
            open()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spotPassArmed ? DriverCopy.yourSpotPass : "Pass it with Spot Pass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(spotPassArmed ? "Back to the pass you set up" : "Let a neighbor take your spot")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var clearRow: some View {
        Button(role: .destructive) {
            activeSheet = nil
            onClearPin()
        } label: {
            Text("Just clear my car")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .controlSize(.large)
        .accessibilityLabel("Just clear my car")
        .accessibilityHint("Removes your parked car pin without telling anyone.")
    }

    // MARK: - Leaving-soon post (same path as the legacy card)

    private var identitySheetPresented: Binding<Bool> {
        Binding(
            get: { pendingIdentityAction != nil },
            set: { isPresented in
                if !isPresented { pendingIdentityAction = nil }
            }
        )
    }

    private func submitLeavingSoon() async {
        leavingSoonError = nil
        if ParkedCarDetailLogic.shouldGateLeavingSoonPost(
            identityGateShouldShow: CommunityIdentityGate().shouldShow()
        ) {
            pendingIdentityAction = { Task { await performPostLeavingSoon() } }
            return
        }
        await performPostLeavingSoon()
    }

    private func performPostLeavingSoon() async {
        guard let pinService else { return }
        leavingSoonSubmitting = true
        leavingSoonError = nil
        let params = ParkedCarDetailLogic.leavingSoonInsertParams(
            parkedCar: parkedCar,
            resolvedSegment: resolvedSegment,
            leavingMinutes: leavingMinutes,
            positionFractionSearchRadiusMeters: Self.positionFractionSearchRadiusMeters
        )
        do {
            try await pinService.insertCrowdPin(
                type: .leavingSoon,
                meta: nil,
                lat: params.lat,
                lng: params.lng,
                segmentId: params.segmentId,
                zoneId: nil,
                notes: nil,
                positionFraction: params.positionFraction,
                leavingMinutes: params.leavingMinutes
            )
            leavingSoonSubmitting = false
            leavingSoonJustPosted = true
        } catch {
            leavingSoonSubmitting = false
            leavingSoonError = "Couldn't submit. Check your connection and try again."
        }
    }

    // MARK: - Helpers

    private static func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default:  return "\(code) side"
        }
    }

    /// "just now", "5m ago", "3h ago", "2d ago" (same wording as the legacy sheet).
    private static func relativeTime(from date: Date, now: Date) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }
}
