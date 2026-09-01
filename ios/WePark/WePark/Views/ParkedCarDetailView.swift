//
//  ParkedCarDetailView.swift
//  WePark
//
//  W5: Sheet shown when the user taps the car-pin annotation on the map.
//
//  Content (top to bottom):
//    1. Severity color band (6pt, decorative, accessibilityHidden) — gray when no segment.
//    2. Header row — "My Car" + block label (or "Location saved (no parking data)") + ✕ button.
//    3. Safety label — first focusable a11y element. Omitted if no segment.
//    3b. FT-15/TF2-15 (§9.2): "Temporary restriction reported" banner — this is the
//        highest-value consumption point in the whole spec: telling someone whose car is
//        already parked on an affected block. Requires a resolved segment (no segment ==
//        no blockfaceKey to match against). Tap opens PinDetailSheet.
//    4. Parked-at relative timestamp — "Parked 3h ago".
//    4b. Community 2.0 Phase 4a / WP4 rider (S10): "🧹 Swept X ago · N confirms" badge —
//        live only when a `sweeper_passed` pin covers this car's resolved segment.
//    5. [W7] Reminder toggle — "Remind me before parking changes" + (Community 2.0 WP4
//       rider) inline 15m/30m/1h/2h/Night-before offset chips, shown while the toggle is on.
//    6. Rules list — same RuleRow component as BlockDetailView.
//    6b. Community 2.0 Phase 4a (S10): "Hand your spot to the crew" — leaving-soon handoff
//        card (5/10/15/20-min chips + post button).
//    7. "I left — clear pin" button (red tint) — UNCHANGED by this session.
//
//  Segment re-lookup: detectedSegmentID is resolved at sheet-open time by searching
//  the TileLoader segments array. If the tile has been evicted from the LRU cache,
//  lookup may return nil — the view shows "No parking data at this location" (AC-W5.9).
//
//  W7: Added per-pin reminder toggle (§3.C / §4.A). Flipping the toggle calls
//  ParkPinService.updateNotifyOnRestriction and re-evaluates notification scheduling.
//
//  Community 2.0 Phase 4a + WP4 rider (build 20 S10). Spec:
//  docs/community-2.0-reconciliation-spec.md §3 Phase 4 (the 4a slice: leaving-soon UI +
//  claim UX — NOT the APNs pipeline, which is 4b/S11-12 and is untouched here) +
//  docs/design/community-2.0-hero-gap-inventory.md WP4 (offset chips + swept badge, folded
//  into this same session because this file is already open for the leaving-soon section).
//  Visual truth: design/screenshots/15-my-car.png. Copy/values verbatim from
//  design/prototype.html:281-335.
//
//  Everything new in this session is gated behind `AppConstants.communityEnabled` — while
//  the flag is `false` this sheet renders and behaves byte-identically to the pre-S10 shipped
//  version (plain reminder toggle, no offset chips, no swept badge, no leaving-soon card).
//
//  Scope note (flagged for orchestrator review, not silently decided): the spec's Phase 4
//  section also describes a "claim" button ("I'm heading there" → `claim_pin` RPC) for
//  OTHER users viewing someone else's `leaving_soon` pin. That surface lives wherever other
//  users see pins they didn't post (map annotation callout / crew feed row) — not this car's
//  own detail sheet, and this session's file scope is `ParkedCarDetailView.swift` only among
//  Views (no `BrowseNavigationSheet`/`MapViewRepresentable`/`ReportSheet` changes). The claim
//  button is therefore NOT built in this PR; only the posting side (this car's own "Hand your
//  spot to the crew" card) is. `claim_pin` (spec §2.10) and `CommunityPin.claimedBy` already
//  exist server/model-side, unconsumed, ready for that follow-up.
//
//  Identity-gate routing: presented as a nested sheet-on-sheet, local to this file — the
//  SAME pattern `ReportSheet.swift` already uses for its own report-submit identity
//  interception (QA pass 1, PR #96 Finding #2, confirmed safe: nesting one sheet inside an
//  already-presented sheet's own content is the standard SwiftUI shape; only a SECOND,
//  independent TOP-LEVEL `.sheet` competing with ContentView's single `ActiveSheet` presenter
//  would be a risk). `ParkedCarDetailView` is itself presented via `ActiveSheet.parkedCarDetail`
//  in `ContentView.swift`, so this is exactly that same shape — no new `ActiveSheet` case, no
//  `ContentView.swift` changes needed at all for this feature.
//
//  WP4 rider — reminder-offset chips sit on top of the EXISTING global-settings offset
//  mechanism (`Services/ReminderOffsets.swift`, edited in `SettingsView.swift`), not a
//  replacement for it (hero-gap-inventory WP4 judgment call #5). This view loads/saves the
//  SAME `UserDefaults`-backed `ReminderOffsets` blob directly and calls
//  `NotificationScheduler.shared` directly — it does NOT thread a `@Binding` through
//  `ContentView` (which would need new constructor params on an existing `ActiveSheet` case,
//  outside this session's approved file scope). Known, deliberate limitation from that
//  choice: if a user edits chips here and then opens Settings in the SAME foreground session
//  (no backgrounding/relaunch in between), Settings' own toggles read `ContentView`'s cached
//  `@State reminderOffsets` and may show stale values until the next foreground-resync
//  (`ContentView`'s existing `scenePhase == .active` handler already reloads it). The actual
//  scheduled notifications are always correct regardless — `NotificationScheduler.schedule`
//  reads `ReminderOffsets.load(from: .standard)` fresh on every call, never a cached copy —
//  this is a display-only edge case in a DIFFERENT sheet, not a functional bug. Flagged
//  explicitly rather than silently fixed by touching `ContentView.swift` outside this
//  session's stated scope; a one-line resync in `ContentView`'s sheet-dismiss handler would
//  close it if wanted.
//
//  No Calendar.current use. No import SwiftUI in Models/ or Services/.
//

import SwiftUI

// MARK: - ParkedCarDetailView

struct ParkedCarDetailView: View {

    // MARK: - Inputs

    let parkedCar: ParkedCar
    let engine: ParkingRulesEngine
    /// All currently-loaded segments — used to re-resolve the detectedSegmentID.
    let loadedSegments: [Segment]
    let onDismiss: () -> Void
    let onClearPin: () -> Void

    // MARK: - W7: Services for toggle actions

    /// W7: Reference to ParkPinService for updating notifyOnRestriction.
    /// Passed in from ContentView (same instance that owns parkedCar).
    let parkPinService: ParkPinService

    /// W7: Scheduler reference — needed to cancel/reschedule when toggle is flipped.
    let scheduler: NotificationScheduler

    // MARK: - FT-15 / TF2-15 (§9.2): Temporary restriction banner

    /// Pin service used to look up an active/upcoming block-scoped restriction covering
    /// the resolved segment. `nil` in previews/standalone use — the banner simply doesn't
    /// render (same optional-service pattern as `BlockDetailView.pinService`).
    ///
    /// Community 2.0 Phase 4a (S10): also the read source for the swept-status badge and
    /// the write path for the leaving-soon post — same instance, no second service injected.
    let pinService: CommunityPinService?

    /// Called when the user taps the restriction banner. Passes the matched `CommunityPin`
    /// so the caller can present `PinDetailSheet` (reuses `activeSheet = .pinDetail(pin)`
    /// in ContentView). `nil` in previews/standalone use.
    let onOpenRestriction: ((CommunityPin) -> Void)?

    // MARK: - W7: Toggle state — initialized from the current car's persisted value.

    @State private var remindMe: Bool

    // MARK: - Community 2.0 WP4 rider (S10): per-car reminder-offset chip state.

    /// Local mirror of the GLOBAL `ReminderOffsets` blob (see this file's header note on why
    /// this isn't a `ContentView`-threaded `@Binding`). Loaded fresh at sheet-open time;
    /// saved back to the SAME `UserDefaults` key on every chip toggle.
    @State private var offsets: ReminderOffsets

    // MARK: - Community 2.0 Phase 4a (S10): "Hand your spot to the crew" state.

    @State private var leavingMinutes: Int = 10
    @State private var leavingSoonSubmitting: Bool = false
    @State private var leavingSoonPosted: Bool = false
    @State private var leavingSoonError: String? = nil

    /// Holds the "resume posting" closure while the local identity sheet is up. Mirrors
    /// `ReportSheet.pendingIdentityAction` exactly (see this file's header note) — entirely
    /// local to this view, no `ContentView` state involved.
    @State private var pendingIdentityAction: (() -> Void)? = nil

    // MARK: - Init

    init(
        parkedCar: ParkedCar,
        engine: ParkingRulesEngine,
        loadedSegments: [Segment],
        parkPinService: ParkPinService,
        scheduler: NotificationScheduler = .shared,
        pinService: CommunityPinService? = nil,
        onDismiss: @escaping () -> Void,
        onClearPin: @escaping () -> Void,
        onOpenRestriction: ((CommunityPin) -> Void)? = nil
    ) {
        self.parkedCar = parkedCar
        self.engine = engine
        self.loadedSegments = loadedSegments
        self.parkPinService = parkPinService
        self.scheduler = scheduler
        self.pinService = pinService
        self.onDismiss = onDismiss
        self.onClearPin = onClearPin
        self.onOpenRestriction = onOpenRestriction
        _remindMe = State(initialValue: parkedCar.notifyOnRestriction)
        _offsets = State(initialValue: ReminderOffsets.load(from: .standard))
    }

    // MARK: - Private

    /// Resolved segment at sheet-open time. Nil if detectedSegmentID is nil or tile evicted.
    private var resolvedSegment: Segment? {
        guard let sid = parkedCar.detectedSegmentID else { return nil }
        return loadedSegments.first { $0.id == sid }
    }

    /// FT-15/TF2-15 (§9.2): the block-scoped restriction pin covering the resolved segment,
    /// if any. Nil when there's no resolved segment (no blockfaceKey to match against) or
    /// no pinService injected (preview/standalone use).
    private var blockScopedRestriction: CommunityPin? {
        guard let seg = resolvedSegment else { return nil }
        return pinService?.blockScopedRestriction(forBlockfaceKey: seg.blockfaceKey)
    }

    /// Community 2.0 Phase 4a / WP4 rider (S10): the live `sweeper_passed` pin covering this
    /// car's resolved segment, if any. Flag-gated even though `sweeper_passed` itself
    /// predates Community 2.0 (Tier 3, always in `visiblePins`) — this BADGE is new
    /// Community 2.0 UI and stays dark with the rest of this session while the flag is off.
    private var sweptStatusPin: CommunityPin? {
        ParkedCarDetailLogic.liveSweeperPin(
            in: pinService?.visiblePins ?? [],
            segmentId: resolvedSegment?.id,
            now: pinService?.nowProvider() ?? now,
            communityEnabled: AppConstants.communityEnabled
        )
    }

    /// Evaluate once at sheet-open time.
    private let now: Date = .nowET

    /// Community 2.0 Phase 4a (S10): search radius for deriving the leaving-soon pin's
    /// `positionFraction` from the car's raw lat/lng against its resolved segment's
    /// polyline. Matches the W5 pin-drop candidate-search radius
    /// (`ContentView.pinDropRadiusMeters`) already used to resolve this same car's
    /// `detectedSegmentID` at drop time — reusing that tolerance rather than inventing a new
    /// one.
    private static let positionFractionSearchRadiusMeters: Double = 35.0

    /// Community 2.0 Phase 4a / WP4 rider (S10): fill/stroke color for the swept-status
    /// badge — matches `sweeper_passed`'s canonical `#30D158` (spec §6 appendix), same
    /// literal `IdentitySheet.swift`'s avatar-selection ring already uses. Duplicated rather
    /// than shared, per this codebase's established house style (see `ReportSheet.gridColor`'s
    /// own doc comment for the same reasoning).
    private static let sweptBadgeColor = Color(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Severity color band.
            severityBand

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 2. Header row.
                    headerRow

                    // 3. Safety label (first focusable a11y element).
                    if let seg = resolvedSegment {
                        safetyLabelView(for: seg)
                    }

                    // 3b. FT-15/TF2-15 (§9.2): temporary restriction banner — the highest-
                    // value consumption point per the spec: telling someone whose car is
                    // already parked on an affected block.
                    if let restriction = blockScopedRestriction {
                        TemporaryRestrictionBanner(pin: restriction, now: pinService?.nowProvider() ?? now) {
                            onOpenRestriction?(restriction)
                        }
                    }

                    // 4. Parked-at relative timestamp.
                    parkedAtRow

                    // 4b. Community 2.0 WP4 rider (S10): swept-status badge.
                    if let sweptPin = sweptStatusPin {
                        sweptBadgeView(for: sweptPin)
                    }

                    // 5. W7: Reminder toggle + (Community 2.0 WP4 rider) offset chips.
                    reminderToggle
                    if AppConstants.communityEnabled, remindMe {
                        offsetChipsRow
                    }

                    // 6. Rules list (only if we have a segment with rules).
                    if let seg = resolvedSegment, !seg.rules.isEmpty {
                        rulesSection(for: seg)
                    }

                    // 6b. Community 2.0 Phase 4a (S10): "Hand your spot to the crew".
                    if AppConstants.communityEnabled {
                        leavingSoonCard
                    }

                    // 7. "I left" button.
                    iLeftButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        // Community 2.0 Phase 4a (S10): local identity-sheet interception, nested sheet-on-
        // sheet — see this file's header note for why this is safe here and needs no
        // ContentView.swift change.
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
                            print("[ParkedCarDetailView] upsertProfile failed: \(error)")
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

    // MARK: - Severity band

    private var severityBand: some View {
        let color: Color = {
            if let seg = resolvedSegment {
                return engine.currentStateColor(for: seg, at: now)
            }
            return Color(.systemGray4)
        }()
        return Rectangle()
            .fill(color)
            .frame(height: 6)
            .accessibilityHidden(true)
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Car")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                Text(blockSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            // ✕ close button (44pt tap target).
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close parked car details")
        }
    }

    /// Block subtitle line: "Bowery — North side · between Hester and Grand"
    /// Falls back to "Location saved (no parking data)" if no segment cached.
    private var blockSubtitle: String {
        guard let seg = resolvedSegment else {
            // Try to use cached street metadata from the ParkedCar itself.
            if let street = parkedCar.street, let side = parkedCar.detectedSide {
                let canonical = StreetNameNormalizer.canonical(street)
                let sideStr = sideLabel(side)
                if let from = parkedCar.fromStreet, let to = parkedCar.toStreet {
                    let fromStr = StreetNameNormalizer.canonical(from)
                    let toStr = StreetNameNormalizer.canonical(to)
                    return "\(canonical) \u{2014} \(sideStr) · between \(fromStr) and \(toStr)"
                }
                return "\(canonical) \u{2014} \(sideStr)"
            }
            return "Location saved (no parking data)"
        }
        let street = StreetNameNormalizer.canonical(seg.street)
        let side = sideLabel(seg.side)
        let from = StreetNameNormalizer.canonical(seg.fromStreet)
        let to = StreetNameNormalizer.canonical(seg.to)
        return "\(street) \u{2014} \(side) · between \(from) and \(to)"
    }

    // MARK: - Safety label

    private func safetyLabelView(for seg: Segment) -> some View {
        let label = engine.safetyLabel(for: seg, at: now)
        return Text(label.text)
            .font(.title.bold())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            // First focusable a11y element (same discipline as BlockDetailView).
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Parked-at timestamp

    private var parkedAtRow: some View {
        Text("Parked \(relativeTime(from: parkedCar.parkedAt))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Formats the parked-at date as a human-readable relative string.
    /// Examples: "just now", "5m ago", "3h ago", "2d ago".
    /// Uses the ET calendar implicitly — parkedAt is a UTC wall-clock Date so
    /// the difference is calendar-agnostic.
    private func relativeTime(from date: Date) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 60 {
            return "just now"
        } else if diff < 3600 {
            let minutes = Int(diff / 60)
            return "\(minutes)m ago"
        } else if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(diff / 86400)
            return "\(days)d ago"
        }
    }

    // MARK: - Community 2.0 WP4 rider (S10): swept-status badge

    /// "🧹 Swept X ago · N confirms" — matches `design/prototype.html:872,894`'s `cSwept`
    /// content, minus the demo mockup's hardcoded "— clear at 9:30" clause (that clause has
    /// no real data source: it would require computing the segment's next legal end time and
    /// wasn't in this session's spec'd copy).
    ///
    /// Age formatting reuses `PinMarkerAnnotation.ageString(since:now:)` — the SAME
    /// formatter every other pin-age surface in the app uses (crew feed, map callouts),
    /// per spec §0 OQ-2's "every surface that renders these pins MUST show relative age,
    /// [with] the SAME age-display convention."
    private func sweptBadgeView(for pin: CommunityPin) -> some View {
        let age = PinMarkerAnnotation.ageString(since: pin.createdAt, now: pinService?.nowProvider() ?? now)
        let confirms = ParkedCarDetailLogic.confirmCountLabel(pin.confirmCount)
        return Text("🧹 Swept \(age) · \(confirms)")
            .font(.caption.weight(.bold))
            .foregroundStyle(Self.sweptBadgeColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Self.sweptBadgeColor.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.sweptBadgeColor.opacity(0.35), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sweeper reported \(age), confirmed by \(pin.confirmCount) neighbors")
    }

    // MARK: - W7: Reminder toggle

    private var reminderToggle: some View {
        Toggle(isOn: $remindMe) {
            Text("Remind me before parking changes")
                .font(.body)
        }
        .accessibilityLabel("Remind me before parking changes")
        .accessibilityHint("When on, you'll get a notification before your parking window ends.")
        .onChange(of: remindMe) { _, newValue in
            // Persist the updated preference.
            parkPinService.updateNotifyOnRestriction(newValue)
            if newValue {
                // Re-schedule notification (subject to global mute check inside scheduler).
                scheduler.schedule(
                    for: parkPinService.parkedCar ?? parkedCar,
                    loadedSegments: loadedSegments,
                    engine: engine
                )
            } else {
                // Cancel any pending notification for this pin.
                scheduler.cancelAll(for: parkedCar)
            }
        }
    }

    // MARK: - Community 2.0 WP4 rider (S10): reminder-offset chips

    /// Inline per-car offset picker — the same 5 presets `SettingsView`'s global toggles
    /// control, rendered as chips instead (`design/prototype.html:300-312`). See this file's
    /// header note for the deliberate choice not to thread `ContentView`'s cached copy of
    /// this same value through as a `@Binding`.
    private var offsetChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(ParkedCarDetailLogic.reminderChipDefinitions.enumerated()), id: \.offset) { _, def in
                    reminderChip(def.label, isOn: $offsets[dynamicMember: def.keyPath])
                }
            }
            // Small leading/trailing breathing room so the first/last chip isn't flush
            // against the scroll edge.
            .padding(.vertical, 1)
        }
        .onChange(of: offsets) { _, newOffsets in
            ReminderOffsets.save(newOffsets, to: .standard)
            // Mirrors ContentView.handleReminderOffsetsChange's reschedule call.
            // `NotificationScheduler.schedule`/`cancelAllThenSchedule` already re-check
            // `car.notifyOnRestriction` and the global mute flag internally — the `remindMe`
            // guard here just avoids a pointless cancel+reschedule round-trip while the
            // reminder toggle above is off (this row isn't even visible then, but `offsets`
            // could in principle still be observed changing via a very fast toggle-off).
            guard remindMe else { return }
            scheduler.cancelAllThenSchedule(
                for: parkedCar,
                oldCarID: parkedCar.id,
                loadedSegments: loadedSegments,
                engine: engine
            )
        }
    }

    private func reminderChip(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
        .background(isOn.wrappedValue ? Color.accentColor : Color(.systemGray5), in: Capsule())
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
        .accessibilityLabel(label)
    }

    // MARK: - Rules list

    private func rulesSection(for seg: Segment) -> some View {
        let sortedRules = seg.rules.sorted { $0.category.priority < $1.category.priority }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sortedRules.enumerated()), id: \.offset) { _, rule in
                RuleRow(rule: rule)
            }
        }
    }

    // MARK: - Community 2.0 Phase 4a (S10): "Hand your spot to the crew"

    /// Copy verbatim, `design/prototype.html:323-325`.
    private var leavingSoonCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand your spot to the crew")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text("Posts a \"leaving soon\" pin here. Spots can't be held — first come, first served.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if leavingSoonPosted {
                Label("The crew's been told", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 7) {
                    ForEach(ParkedCarDetailLogic.leavingSoonChipMinutes, id: \.self) { minutes in
                        leavingMinuteChip(minutes)
                    }
                }

                if let leavingSoonError {
                    Text(leavingSoonError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await submitLeavingSoon() }
                } label: {
                    Group {
                        if leavingSoonSubmitting {
                            ProgressView()
                        } else {
                            Text(ParkedCarDetailLogic.leavingSoonCTALabel(minutes: leavingMinutes))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(leavingSoonSubmitting)
                .padding(.top, 2)
                .accessibilityLabel("Leaving in \(leavingMinutes) minutes. Tell the crew.")
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func leavingMinuteChip(_ minutes: Int) -> some View {
        let isSelected = minutes == leavingMinutes
        return Button {
            leavingMinutes = minutes
        } label: {
            Text("\(minutes) min")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color(.systemGray5), in: Capsule())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(minutes) minutes")
    }

    /// Binding driving the local identity sheet's presentation — mirrors
    /// `ReportSheet.swift`'s own identical pattern.
    private var identitySheetPresented: Binding<Bool> {
        Binding(
            get: { pendingIdentityAction != nil },
            set: { isPresented in
                if !isPresented { pendingIdentityAction = nil }
            }
        )
    }

    /// Entry point for the "Leaving in N min — tell the crew" button. Routes through the
    /// SAME show-once identity gate every other contribution path uses
    /// (`ReportSheet.submitReport()`, `ContentView.submitSpotPlacement()`) — see
    /// `ParkedCarDetailLogic.shouldGateLeavingSoonPost`.
    private func submitLeavingSoon() async {
        leavingSoonError = nil
        if ParkedCarDetailLogic.shouldGateLeavingSoonPost(
            identityGateShouldShow: CommunityIdentityGate().shouldShow()
        ) {
            // Defer the actual post until the identity sheet resolves (save or skip) —
            // same shape as ReportSheet.submitReport()'s pendingIdentityAction closure.
            pendingIdentityAction = { Task { await performPostLeavingSoon() } }
            return
        }
        await performPostLeavingSoon()
    }

    /// The actual network write — split out of `submitLeavingSoon()` so the identity gate
    /// can defer it, matching `ReportSheet.performSubmit(type:)`'s own split.
    ///
    /// Privacy note: a `leaving_soon` pin is posted at the car's EXACT parked position
    /// (`parkedCar.latitude`/`longitude`, unsnapped — same coordinate W5 stored at pin-drop
    /// time). This is consistent with the standing pin-visibility rule (HANDOFF 2026-08-24,
    /// "STANDING PRIVACY RULE for pin visibility"): personal-location pins are private
    /// (the `parked_car` precedent — no write path, RLS-excluded from anon reads);
    /// COMMUNITY REPORTS are public. `leaving_soon` is a new, intentionally public,
    /// user-INITIATED type — the reconciliation spec is explicit that this is a
    /// **deliberate disclosure, not an ambient leak** (spec §2.1: "posts at the car's exact
    /// position, but only via an explicit, user-initiated 'Hand your spot to the crew' tap
    /// ... it does not need the `parked_car` precedent's lockdown"). The car's own
    /// `parked_car` local pin (W5's `ParkedCar` model) is never itself uploaded by this or
    /// any other call — only this ONE explicit, opt-in leaving-soon post shares the
    /// coordinate, and only for the duration of its short TTL (stated minutes + 3, server-
    /// derived per spec §2.11 — this client never sends its own `expires_at`).
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
            leavingSoonPosted = true
        } catch {
            leavingSoonSubmitting = false
            // Same wording as ReportSheet.submitError — one error string for every
            // contribution-path network failure across the app.
            leavingSoonError = "Couldn't submit. Check your connection and try again."
        }
    }

    // MARK: - "I left" button

    private var iLeftButton: some View {
        Button {
            onClearPin()
        } label: {
            Text("I left \u{2014} clear pin")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityLabel("I left. Clear my parked car pin.")
        .padding(.top, 8)
    }

    // MARK: - Side label helper

    private func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default:  return "\(code) side"
        }
    }
}

// MARK: - Community 2.0 Phase 4a + WP4 rider (S10): pure, testable decision logic

/// Pure decision/formatting logic extracted from `ParkedCarDetailView` so it's unit-testable
/// without SwiftUI/view-lifecycle machinery — same house style as
/// `ReportSheet.destination(forTapping:...)`/`CandidateSegmentSearch`.
enum ParkedCarDetailLogic {

    // MARK: - Swept-status badge

    /// The live (unresolved, unexpired) `sweeper_passed` pin covering `segmentId`, if any.
    ///
    /// `nil` whenever: `communityEnabled` is `false` (flag-off parity — the badge never
    /// renders regardless of what's in `pins`); `segmentId` is `nil` (no resolved segment to
    /// match against); or no pin in `pins` both matches type+segment AND is still live.
    ///
    /// Defense-in-depth on expiry: in production, `pins` (from
    /// `CommunityPinService.visiblePins`) has already had expired rows dropped by
    /// `clientSideFilter` before reaching this function — but `CommunityPinService.inject(_:)`
    /// (the test fixture seam) bypasses that filter entirely, so this function re-checks
    /// `resolvedAt`/`expiresAt` independently. That means a directly-injected expired fixture
    /// exercises a REAL "expired" test case here, not just "absent."
    nonisolated static func liveSweeperPin(
        in pins: [CommunityPin],
        segmentId: String?,
        now: Date,
        communityEnabled: Bool
    ) -> CommunityPin? {
        guard communityEnabled, let segmentId else { return nil }
        return pins.first { pin in
            pin.pinType == .sweeperPassed &&
            pin.segmentId == segmentId &&
            pin.resolvedAt == nil &&
            (pin.expiresAt.map { $0 > now } ?? true)
        }
    }

    /// "1 confirm" / "N confirms" grammar for the swept badge's confirm count.
    nonisolated static func confirmCountLabel(_ count: Int) -> String {
        count == 1 ? "1 confirm" : "\(count) confirms"
    }

    // MARK: - Reminder-offset chips (WP4 rider)

    /// The 5 reminder-offset chips, prototype order (`design/prototype.html:307-311`):
    /// 15 min / 30 min / 1 hr / 2 hr / Night before. Each entry pairs the chip's display
    /// label with a `WritableKeyPath` into the matching `ReminderOffsets` field, so the SAME
    /// list drives both rendering (`ParkedCarDetailView.offsetChipsRow`) and is directly
    /// assertable in tests (order, label text, and label-to-field wiring) without mounting
    /// the view.
    static let reminderChipDefinitions: [(label: String, keyPath: WritableKeyPath<ReminderOffsets, Bool>)] = [
        ("15 min",       \ReminderOffsets.remind15Min),
        ("30 min",       \ReminderOffsets.remind30Min),
        ("1 hr",         \ReminderOffsets.remind1Hour),
        ("2 hr",         \ReminderOffsets.remind2Hours),
        ("Night before", \ReminderOffsets.remindNightBefore),
    ]

    // MARK: - Leaving-soon handoff

    /// The 4 leaving-soon countdown chips, prototype order (`design/prototype.html:963`):
    /// 5 / 10 / 15 / 20 minutes.
    static let leavingSoonChipMinutes: [Int] = [5, 10, 15, 20]

    /// "Leaving in N min — tell the crew" — copy verbatim, `design/prototype.html:331`
    /// (em dash, not a hyphen).
    nonisolated static func leavingSoonCTALabel(minutes: Int) -> String {
        "Leaving in \(minutes) min \u{2014} tell the crew"
    }

    /// Whether the identity sheet must be shown before the leaving-soon post proceeds. A
    /// thin, testable wrapper over `CommunityIdentityInterception.shouldShowIdentitySheet`
    /// (the SAME gate `ReportSheet.submitReport()`/`ContentView.submitSpotPlacement()` use)
    /// — asserts the new leaving-soon path is wired through the shared gate, not a parallel
    /// one-off check. `communityEnabled` defaults to the real flag (mirrors
    /// `AppConstants.communityPhase1PinTypes(enabled:)`'s own testability convention); tests
    /// pass both `true`/`false` explicitly.
    nonisolated static func shouldGateLeavingSoonPost(
        communityEnabled: Bool = AppConstants.communityEnabled,
        identityGateShouldShow: Bool
    ) -> Bool {
        CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: communityEnabled,
            identitySheetShouldShow: identityGateShouldShow
        )
    }

    /// The exact `CommunityPinService.insertCrowdPin` params the "Leaving in N min" button
    /// sends — extracted so the payload SHAPE (a `leavingMinutes` value; no client-supplied
    /// `expires_at` of any kind, by construction — this struct has no such field) is
    /// unit-testable without a live network call. `positionFraction` is derived via the same
    /// `CandidateSegmentSearch.nearestSegmentSnap` helper the `open_spot` placement flow
    /// uses, `nil` when there's no resolved segment to project onto.
    struct LeavingSoonInsertParams: Equatable {
        let lat: Double
        let lng: Double
        let segmentId: String?
        let positionFraction: Double?
        let leavingMinutes: Int
    }

    nonisolated static func leavingSoonInsertParams(
        parkedCar: ParkedCar,
        resolvedSegment: Segment?,
        leavingMinutes: Int,
        positionFractionSearchRadiusMeters: Double
    ) -> LeavingSoonInsertParams {
        let fraction: Double?
        if let seg = resolvedSegment {
            fraction = CandidateSegmentSearch.nearestSegmentSnap(
                lat: parkedCar.latitude,
                lng: parkedCar.longitude,
                in: [seg],
                radius: positionFractionSearchRadiusMeters
            )?.positionFraction
        } else {
            fraction = nil
        }
        return LeavingSoonInsertParams(
            lat: parkedCar.latitude,
            lng: parkedCar.longitude,
            segmentId: resolvedSegment?.id,
            positionFraction: fraction,
            leavingMinutes: leavingMinutes
        )
    }
}

// MARK: - Preview

#Preview {
    let rule = ParkingRule(
        category: .aspMonThu,
        description: "NO PARKING 8-9:30AM MON & THUR",
        days: [1, 4],
        timeRanges: [TimeRange(start: 480, end: 570)],
        anytime: false,
        arrow: "both"
    )
    let ruleData = try! JSONEncoder().encode([rule])
    let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
    let segDict: [String: Any] = [
        "id": "PREVIEW_SEG",
        "street": "BOWERY",
        "from": "HESTER STREET",
        "to": "GRAND STREET",
        "side": "N",
        "line": [[40.7183, -73.9942], [40.7190, -73.9940]],
        "rules": rulesJSON,
        "dominantCategory": "ASP_MON_THU"
    ]
    let segData = try! JSONSerialization.data(withJSONObject: segDict)
    let segment = try! JSONDecoder().decode(Segment.self, from: segData)

    let car = ParkedCar(
        id: UUID(),
        latitude: 40.7186,
        longitude: -73.9941,
        detectedSegmentID: "PREVIEW_SEG",
        detectedSide: "N",
        street: "BOWERY",
        fromStreet: "HESTER STREET",
        toStreet: "GRAND STREET",
        parkedAt: Date().addingTimeInterval(-3 * 3600),
        notifyOnRestriction: true
    )

    return ParkedCarDetailView(
        parkedCar: car,
        engine: ParkingRulesEngine(),
        loadedSegments: [segment],
        parkPinService: ParkPinService(),
        onDismiss: {},
        onClearPin: {}
    )
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
}
