//
//  WPMyCarV2View.swift
//  WePark
//
//  Stoop Phase 4, B7: the flag-on My Car screen (docs/design/wepark-round2, WPMyCar). Shown in place
//  of `MyCarSheetV2View` / `ParkedCarDetailView` ONLY while `AppConstants.designSystemV2Enabled`
//  and `AppConstants.myCarSheetV2Enabled` are both true (`MyCarSheetVariant.stoop`). Flag off never
//  reaches this file.
//
//  The job: "am I OK, and until when?" in one glance. Top to bottom:
//    1. "My car" + the address ("In front of 50 E 1st St") + when it was parked + Close.
//    2. The verdict block: "Legal until 9:00 AM" / "Move by 7:00 AM" / "Move your car now" /
//       "Check the posted sign". Times come from the engine through `WPMyCarLogic`.
//    3. One reminder row (switch + next reminder time). Tapping it opens the shared option set.
//    4. "Leaving soon?" (only when there is something to hand off to).
//    5. Pinned: a big "I left" and "See the N signs on this curb" (signs on demand).
//
//  All behavior (reminder scheduling, leaving-soon post + identity gate, clear pin) uses the same
//  code paths as `MyCarSheetV2View`; only the surface and the wording changed. Pure logic lives in
//  `DesignSystem/WPMyCarLogic.swift`.
//

import SwiftUI
import UserNotifications

struct WPMyCarV2View: View {

    // MARK: Inputs (same as MyCarSheetV2View)

    let parkedCar: ParkedCar
    let engine: ParkingRulesEngine
    let loadedSegments: [Segment]
    let parkPinService: ParkPinService
    var scheduler: NotificationScheduler = .shared
    var aspService: ASPSuspensionService = ASPSuspensionService()
    var pinService: CommunityPinService? = nil
    let onDismiss: () -> Void
    let onClearPin: () -> Void
    /// Non-nil only when Spot Pass is available (flag on and not in trip mode).
    var onOpenSpotPass: (() -> Void)? = nil
    var spotPassArmed: Bool = false
    /// The clock. Tests and the DEBUG showcase pass a fixed one.
    var nowProvider: () -> Date = { .nowET }
    /// Whether the address line shows (`AppConstants.addressAnchoredParkingEnabled`; the DEBUG
    /// showcase passes true so the address wording can be shot while the flag is dark).
    var addressesEnabled: Bool = AppConstants.addressAnchoredParkingEnabled
    /// Screenshot aids (DEBUG showcase only): open a sub-sheet on appear.
    var startsWith: StartSheet? = nil

    enum StartSheet: String, Identifiable {
        case reminders, signs, leaving
        var id: String { rawValue }
    }

    // MARK: State

    @State private var remindMe: Bool
    @State private var offsets: ReminderOffsets
    @State private var activeSheet: StartSheet?
    @State private var leavingMinutes: Int = 10
    @State private var leavingSoonSubmitting = false
    @State private var leavingSoonJustPosted = false
    @State private var leavingSoonError: String?
    @State private var pendingIdentityAction: (() -> Void)?
    /// System notification permission, read async on appear; nil until read.
    @State private var notificationStatus: UNAuthorizationStatus?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

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
        onOpenSpotPass: (() -> Void)? = nil,
        spotPassArmed: Bool = false,
        nowProvider: @escaping () -> Date = { .nowET },
        addressesEnabled: Bool = AppConstants.addressAnchoredParkingEnabled,
        startsWith: StartSheet? = nil
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
        self.onOpenSpotPass = onOpenSpotPass
        self.spotPassArmed = spotPassArmed
        self.nowProvider = nowProvider
        self.addressesEnabled = addressesEnabled
        self.startsWith = startsWith
        _remindMe = State(initialValue: parkedCar.notifyOnRestriction)
        _offsets = State(initialValue: ReminderOffsets.load(from: .standard))
        _activeSheet = State(initialValue: startsWith)
    }

    // MARK: Derived

    private var now: Date { pinService?.nowProvider() ?? nowProvider() }

    private var isAX: Bool { typeSize.isAccessibilitySize }

    private var segment: Segment? {
        guard let id = parkedCar.detectedSegmentID else { return nil }
        return loadedSegments.first { $0.id == id }
    }

    private var reports: WPNeighborReports {
        guard let segment else { return WPNeighborReports() }
        let restriction = pinService?.blockScopedRestriction(forBlockfaceKey: segment.blockfaceKey)
        return WPNeighborVerdict.reports(for: restriction, now: now, trip: nil)
    }

    private var verdict: WPMyCarVerdict {
        WPMyCarLogic.verdict(segment: segment, engine: engine, now: now, reports: reports)
    }

    private var signs: [WPSignLine] {
        guard let segment else { return [] }
        return WPSignList.lines(for: segment, engine: engine, now: now)
    }

    private var liveAddress: ParkingAddress? {
        guard addressesEnabled else { return nil }
        return (parkPinService.parkedCar?.id == parkedCar.id ? parkPinService.parkedCar?.address : nil) ?? parkedCar.address
    }

    private var streetName: String? {
        if let segment { return StreetNameFormatter.displayCanonical(segment.street) }
        if let street = parkedCar.street { return StreetNameFormatter.displayCanonical(street) }
        return nil
    }

    private var titleText: String {
        WPMyCarLogic.title(
            addressLine: liveAddress.map { ParkingAddressCopy.line($0) },
            street: streetName
        )
    }

    private var titleSpoken: String {
        if let address = liveAddress { return ParkingAddressCopy.spoken(address) }
        return titleText
    }

    private var suspensionNote: String? {
        WPMyCarLogic.suspensionNote(segment: segment, state: aspService.suspensionState(at: now), now: now,
            variant: verdict.variant
        )
    }

    private var notificationAvailability: WPMyCarLogic.NotificationAvailability {
        WPMyCarLogic.NotificationAvailability.resolve(
            muted: UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey),
            status: notificationStatus
        )
    }

    private var previews: [WPMyCarLogic.ReminderPreview] {
        guard let start = verdict.restrictionStart else { return [] }
        return WPMyCarLogic.reminderPreviews(offsets: offsets, restrictionStart: start, now: now)
    }

    private var leaveOpensSheet: Bool {
        MyCarSheetV2Logic.leaveButtonOpensSheet(
            communityEnabled: AppConstants.communityEnabled,
            spotPassAvailable: onOpenSpotPass != nil
        )
    }

    private var ownLiveLeavingSoonPin: CommunityPin? {
        ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: pinService?.visiblePins ?? [],
            authorId: pinService?.authService?.currentUserId,
            segmentId: segment?.id,
            carLatitude: parkedCar.latitude,
            carLongitude: parkedCar.longitude,
            now: now,
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
            expiresAt: expiresAt, now: now, leavingMinutes: pin.leavingMinutes
        )
        guard remaining > 0 else { return "Neighbors have been told" }
        return "Neighbors have been told. \(remaining) min left."
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    header
                    verdictBlock
                    if let note = suspensionNote { noteCard(note) }
                    if verdict.offersReminders { reminderRow }
                    else if verdict.variant == .nodata || verdict.variant == .unclear { noReminderRow }
                    if showsLeavingSoonCard { leavingSoonCard }
                    // At accessibility sizes the pinned bar keeps only "I left" so the verdict is
                    // never covered; the signs link scrolls with the content.
                    if isAX { signsLink }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s5)
                .padding(.bottom, WP.Space.s3)
            }
            .scrollBounceBehavior(.basedOnSize)
            bottomBar
        }
        .background(WP.paper.ignoresSafeArea())
        // Kevin's design call is pending on this AX3 cap (PR #205 QA finding #2 in
        // docs/qa/pr205-stoop-phase4-mycar-qa.md: AX4/AX5 users get smaller text here). Left as is
        // until decided.
        // Accessibility sizes stay accessibility-sized but stop at AX3: past that the verdict block
        // alone fills a short phone. Everything is reachable by scrolling; nothing truncates.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .task { await refreshNotificationStatus() }
        // Returning from Settings (where the driver may have flipped notifications) re-reads the
        // permission, so the reminder copy never keeps saying the old thing.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationStatus() } }
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
                    .presentationBackground(WP.card)
            case .signs:
                signsSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(WP.card)
            case .leaving:
                leavingSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(WP.card)
            }
        }
    }

    // MARK: 1. Header

    private var header: some View {
        // One row at every size: a stacked Close pill would cost the verdict a whole row at AX.
        return HStack(alignment: .top, spacing: WP.Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("My car")
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                Text(titleText)
                    .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(titleSpoken)
                    .accessibilityAddTraits(.isHeader)
                Text(WPMyCarLogic.parkedLine(parkedAt: parkedCar.parkedAt, now: now))
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
            }
            Spacer(minLength: 0)
            Button("Close", action: onDismiss)
                .buttonStyle(WPClosePillStyle())
                .accessibilityLabel("Close My car")
        }
    }

    // MARK: 2. Verdict

    private var verdictBlock: some View {
        WPVerdictBlock(
            kind: verdict.variant.blockKind,
            over: verdict.over,
            big: verdict.big,
            sub: verdict.sub,
            fractionLeft: verdict.variant == .park ? verdict.fractionLeft : nil
        )
        .accessibilityElement(children: .combine)
    }

    private func noteCard(_ text: String) -> some View {
        Text(text)
            .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous).fill(WP.park.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous).strokeBorder(WP.park, lineWidth: WP.Border.fact))
    }

    // MARK: 3. Reminder row

    private var reminderRow: some View {
        HStack(spacing: WP.Space.s3) {
            Button { activeSheet = .reminders } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remind me before it changes")
                        .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                        .foregroundStyle(WP.text)
                    Text(WPMyCarLogic.reminderRowSub(
                        remindMe: remindMe, previews: previews, now: now, availability: notificationAvailability
                    ))
                        .font(WP.Font.fredoka(14, .regular, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: WP.Target.standard - 2 * WP.Space.s3, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens reminder times.")
            // The custom switch style draws its own label, so the label is empty and VoiceOver
            // gets the name from the modifier.
            Toggle(isOn: $remindMe) { EmptyView() }
                .toggleStyle(WPSwitchStyle())
                .fixedSize()
                .accessibilityLabel("Remind me before it changes")
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(minHeight: WP.Target.standard)
        .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }

    /// B7.5: an unreadable curb has no rules to remind about. Plain statement, never a promise.
    private var noReminderRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No reminders for this curb")
                .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                .foregroundStyle(WP.text)
            Text("We have no rules to remind you about")
                .font(WP.Font.fredoka(14, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, minHeight: WP.Target.standard, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .combine)
    }

    // MARK: 4. Leaving soon

    private var showsLeavingSoonCard: Bool {
        WPMyCarLogic.showsLeavingSoonCard(leaveOpensSheet: leaveOpensSheet)
    }

    private var leavingSoonCard: some View {
        Button { activeSheet = .leaving } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Leaving soon?")
                    .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.ink)
                Text(spotPassArmed ? "Back to your Spot Pass, or tell neighbors." : "Pass your spot to a neighbor.")
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.ink)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, minHeight: WP.Target.standard, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.taxi))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.ink, lineWidth: WP.Border.control))
            .contentShape(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens ways to hand off your spot.")
    }

    // MARK: 5. Pinned actions

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button(verdict.primaryTitle) { onClearPin() }
                .buttonStyle(WPMyCarPrimaryStyle())
                .accessibilityHint("Clears your parked car and turns its reminders off.")
            if !isAX { signsLink }
        }
        .padding(.horizontal, WP.Space.screenMargin)
        .padding(.top, WP.Space.s2)
        .padding(.bottom, WP.Space.s2)
        .background(WP.paper)
    }

    @ViewBuilder
    private var signsLink: some View {
        if signs.isEmpty {
            Text(verdict.variant == .nodata ? "No signs on file for this curb" : "No signs to show")
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: WP.Control.textLinkHeight)
        } else {
            Button(signs.count == 1 ? "See the 1 sign on this curb" : "See the \(signs.count) signs on this curb") {
                activeSheet = .signs
            }
            .buttonStyle(.wpTextLink)
            .frame(maxWidth: .infinity)
            .accessibilityHint("Shows the posted sign text.")
        }
    }

    // MARK: Reminders sheet (B7.6)

    private var remindersSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
                Text("Remind me")
                    .font(WP.Font.fredoka(28, .bold, relativeTo: .title))
                    .foregroundStyle(WP.text)
                    .accessibilityAddTraits(.isHeader)
                if let start = verdict.restrictionStart {
                    Text(WPMyCarLogic.startsLine(name: verdict.restrictionName, start: start, now: now))
                        .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("HOW LONG BEFORE \u{00B7} PICK ANY")
                    .font(WP.Font.fredoka(12, .semibold, relativeTo: .caption))
                    .kerning(0.8)
                    .foregroundStyle(WP.muted)
                    .padding(.top, WP.Space.s2)
                LazyVGrid(columns: leadColumns, spacing: WP.Space.s2) {
                    WPChoiceChip(title: "15 min", isSelected: offsets.remind15Min, height: 56) { offsets.remind15Min.toggle() }
                    WPChoiceChip(title: "30 min", isSelected: offsets.remind30Min, height: 56) { offsets.remind30Min.toggle() }
                    WPChoiceChip(title: "1 hr", isSelected: offsets.remind1Hour, height: 56) { offsets.remind1Hour.toggle() }
                    WPChoiceChip(title: "2 hr", isSelected: offsets.remind2Hours, height: 56) { offsets.remind2Hours.toggle() }
                }
                nightBeforeRow
                if remindMe {
                    Text(WPMyCarLogic.reminderSummary(
                        previews: previews, now: now, availability: notificationAvailability
                    ))
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Reminders are off for this car.")
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                }
                Button("Done") { activeSheet = nil }
                    .buttonStyle(WPMyCarPrimaryStyle())
                    .padding(.top, WP.Space.s2)
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s6)
            .padding(.bottom, WP.Space.s4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var leadColumns: [GridItem] {
        let count = isAX ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: WP.Space.s2), count: count)
    }

    private var nightBeforeRow: some View {
        let sub: String = {
            guard let start = verdict.restrictionStart,
                  let night = WPMyCarLogic.nightBeforeDate(relativeTo: start) else { return "8:00 PM the evening before" }
            return WPMyCarLogic.short(WPCurbCopy.when(night, now: now))
        }()
        return Toggle(isOn: $offsets.remindNightBefore) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The night before")
                    .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                Text(sub)
                    .font(WP.Font.fredoka(14, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
            }
        }
        .toggleStyle(WPSwitchStyle())
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s3)
        .frame(minHeight: WP.Target.standard)
        .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }

    // MARK: Signs sheet (B7.8)

    private var signsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signs on this curb")
                            .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                            .foregroundStyle(WP.text)
                            .accessibilityAddTraits(.isHeader)
                        if let segment {
                            Text(WPCurbCopy.title(for: segment))
                                .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                                .foregroundStyle(WP.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Close") { activeSheet = nil }
                        .buttonStyle(WPClosePillStyle())
                }
                VStack(spacing: 0) {
                    ForEach(Array(signs.enumerated()), id: \.element.id) { index, sign in
                        if index > 0 { Divider().overlay(WP.line) }
                        VStack(alignment: .leading, spacing: WP.Space.s1) {
                            Text(sign.text.uppercased())
                                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                                .foregroundStyle(WP.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(sign.plain)
                                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                                .foregroundStyle(WP.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(WP.Space.s4)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
                .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
                Text("Sign text is from NYC DOT. The sign on the street always wins.")
                    .font(WP.Font.fredoka(14, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s6)
            .padding(.bottom, WP.Space.s4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Leaving sheet (B7.7)

    private var leavingSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
                HStack(alignment: .top) {
                    Text("I\u{2019}m leaving")
                        .font(WP.Font.fredoka(28, .bold, relativeTo: .title))
                        .foregroundStyle(WP.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button("Close") { activeSheet = nil }
                        .buttonStyle(WPClosePillStyle())
                }
                if AppConstants.communityEnabled { tellNeighbors }
                if let onOpenSpotPass { handoffRow(
                    title: spotPassArmed ? DriverCopy.yourSpotPass : "Pass with Spot Pass",
                    sub: spotPassArmed ? "Back to the pass you set up" : "Hand it to one driver who is waiting.",
                    action: onOpenSpotPass
                ) }
                handoffRow(title: "Just clear my car", sub: "No one is told.") {
                    activeSheet = nil
                    onClearPin()
                }
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s6)
            .padding(.bottom, WP.Space.s4)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Identity gate for the leaving-soon post, nested on this sheet so it never competes with
        // a second sheet presented from the parent.
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
                            print("[WPMyCarV2View] upsertProfile failed: \(error)")
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

    private var tellNeighbors: some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            Text("Tell neighbors")
                .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                .foregroundStyle(WP.text)
            Text("A spot opening shows on this block. Spots can\u{2019}t be held. First come, first served. Leaving in:")
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            if isLeavingSoonPosted {
                Text(leavingSoonConfirmationText)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: leadColumns, spacing: WP.Space.s2) {
                    ForEach(ParkedCarDetailLogic.leavingSoonChipMinutes, id: \.self) { minutes in
                        WPChoiceChip(
                            title: "\(minutes)\u{00A0}min", isSelected: minutes == leavingMinutes, height: 56
                        ) { leavingMinutes = minutes }
                    }
                }
                if let leavingSoonError {
                    Text(leavingSoonError)
                        .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                        .foregroundStyle(WP.noParkText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await submitLeavingSoon() }
                } label: {
                    if leavingSoonSubmitting { ProgressView() } else { Text("Tell neighbors") }
                }
                .buttonStyle(.wpPrimary)
                .disabled(leavingSoonSubmitting)
                .accessibilityLabel("Leaving in \(leavingMinutes) minutes. Tell neighbors.")
            }
        }
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }

    private func handoffRow(title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: WP.Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                        .foregroundStyle(WP.text)
                    Text(sub)
                        .font(WP.Font.fredoka(14, .regular, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: WP.Space.s2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WP.text)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, minHeight: WP.Target.standard, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
            .contentShape(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Leaving-soon post (same path as MyCarSheetV2View)

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
            resolvedSegment: segment,
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
}

// MARK: - Primary button

/// "I left" / "Done": the ink pill of the mock (ink fill, white label, 64+ tall). Ink is the dark
/// background color, so in dark mode the pill is the lifted surface with a line instead of
/// vanishing into the ground.
struct WPMyCarPrimaryStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let fill: Color = scheme == .dark
            ? (configuration.isPressed ? WP.card : WP.lifted)
            : (configuration.isPressed ? Color(wpHex: WP.Hex.darkLifted) : Color(wpHex: WP.Hex.ink))
        return configuration.label
            .font(WP.Font.fredoka(24, .semibold, relativeTo: .title2))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, WP.Space.s6)
            .padding(.vertical, WP.Space.s2)
            .frame(maxWidth: .infinity, minHeight: WP.Control.primaryHeight - WP.Space.s2)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(scheme == .dark ? WP.line : Color.clear, lineWidth: WP.Border.control))
            .contentShape(shape)
    }
}
