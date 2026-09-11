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
//    4a. Open-items #16 (Kevin, on-device 2026-09-08; built this session, 2026-09-11):
//        "when does this become not-free" status line for the parked blockface — the
//        sheet's single most valuable fact per Kevin's own framing ("important piece of
//        information to have, even if it's just the sign details for the side of the
//        street we're on"). Derived purely via `ParkingRulesEngine.nextRestriction(for:at:)`
//        + `.nextRestrictionTimeLabel(hours:now:)` — the SAME two engine APIs
//        `NotificationScheduler.buildContent` already consumes for reminder copy — NOT a
//        re-derivation of `engine.safetyLabel(for:at:)`'s text (that headline lives at 3.
//        above and can legitimately say the same thing when currently free; this line's
//        job is specifically "when do I need to move"). Omitted if no resolved segment.
//    4a2. Open-items #16 item 3: explicit "ASP Suspended — <reason>" note, shown when today
//        is an ASP-suspended date AND the parked segment actually carries an ASP rule.
//        Reuses `ASPBanner`'s exact `.todaySuspended` wording and green tone
//        (`Views/ASPBanner.swift`) — no new suspension calendar logic, no new color mapping.
//    4b. Community 2.0 Phase 4a / WP4 rider (S10): "🧹 Swept X ago · N confirms" badge —
//        live only when a `sweeper_passed` pin covers this car's resolved segment.
//    5. [W7] Reminder toggle — "Remind me before parking changes" + (Community 2.0 WP4
//       rider) inline 15m/30m/1h/2h/Night-before offset chips, shown while the toggle is on.
//    6. Rules list — same RuleRow component as BlockDetailView. Open-items #16 item 2:
//       collapses behind a "Rules (N)" DisclosureGroup, collapsed by default, when there are
//       more than 3 rules — keeps the sheet compact. 3 or fewer stay always-visible, matching
//       `BlockDetailView.rulesSection`'s own uncollapsed convention for the common case.
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
//  Scope note (flagged for orchestrator review at the time, since RESOLVED): the spec's
//  Phase 4 section also describes a "claim" button ("I'm heading there" → `claim_pin` RPC)
//  for OTHER users viewing someone else's `leaving_soon` pin. This file never built one —
//  QA pass 1 (PR #98) traced the consumer side and confirmed it's a non-issue: `claim_pin`
//  consumption already shipped in PR #97 (S9, `c581d65f`) via
//  `CrewFeedSection.leavingSoonAction` / `PinDetailSheet.claimSection`. Nothing is missing.
//
//  Identity-gate routing: presented as a nested sheet-on-sheet, local to this file — the
//  SAME pattern `ReportSheet.swift` already uses for its own report-submit identity
//  interception (QA pass 1, PR #96 Finding #2, confirmed safe: nesting one sheet inside an
//  already-presented sheet's own content is the standard SwiftUI shape; only a SECOND,
//  independent TOP-LEVEL `.sheet` competing with ContentView's single `ActiveSheet` presenter
//  would be a risk). `ParkedCarDetailView` is itself presented via `ActiveSheet.parkedCarDetail`
//  in `ContentView.swift`, so this is exactly that same shape — no new `ActiveSheet` case
//  needed for this. (PR #98 QA round 1 DID need one small `ContentView.swift` touch for a
//  DIFFERENT reason — see the WP4 rider paragraph below.)
//
//  WP4 rider — reminder-offset chips sit on top of the EXISTING global-settings offset
//  mechanism (`Services/ReminderOffsets.swift`, edited in `SettingsView.swift`), not a
//  replacement for it (hero-gap-inventory WP4 judgment call #5). This view loads/saves the
//  SAME `UserDefaults`-backed `ReminderOffsets` blob directly and calls
//  `NotificationScheduler.shared` directly — it does NOT thread a `@Binding` through
//  `ContentView`.
//
//  QA pass 1 (PR #98, Finding #2) FIX: the original version of this PR flagged (rather than
//  fixed) a same-session cross-sheet race — `ContentView`'s cached `@State reminderOffsets`
//  (read/written by `SettingsView`) only resynced on `scenePhase == .active`, so editing a
//  chip here, dismissing, then toggling anything in Settings could make Settings write back
//  its stale FULL struct and silently revert the chip edit. This is now closed: `ContentView`'s
//  single `.sheet(item:)` `onDismiss` closure resyncs `reminderOffsets` from `UserDefaults` on
//  EVERY sheet dismiss (one line, `ContentView.swift`), so `SettingsView` can never observe a
//  copy older than whatever this view last wrote. No scheduling-semantics change —
//  `NotificationScheduler.schedule`/`cancelAllThenSchedule` already read
//  `ReminderOffsets.load(from: .standard)` fresh on every call, never a cached copy; this fix
//  only keeps `SettingsView`'s DISPLAY (and its own write-back) honest. Flag-off is
//  unaffected: nothing writes this `UserDefaults` key while `AppConstants.communityEnabled ==
//  false` (this view's chip row never mounts), so the added resync is a no-op re-read of
//  whatever was already there.
//
//  QA pass 1 (PR #98, Finding #1) FIX: the leaving-soon "posted" confirmation state used to
//  be plain view-local `@State` (`leavingSoonPosted`), which reset to `false` on every
//  dismiss/reopen of this sheet — reopening My Car mid-countdown showed the chips/CTA again,
//  letting a user post a second, independent `leaving_soon` pin for the same still-active
//  countdown. Fixed by deriving the card's state from TRUTH, not memory: `ownLiveLeavingSoonPin`
//  reads `pinService.visiblePins` (same source `sweptStatusPin` already used) for a still-live
//  `leaving_soon` pin THIS device authored, anchored to this car (matching segment, or within a
//  tight radius of the car's coordinate when no segment matched). A transient `@State`
//  (`leavingSoonJustPosted`) is kept ONLY to bridge the brief window between a successful post
//  and `visiblePins` reflecting it (normally synchronous — `insertCrowdPin` merges the response
//  before returning — but not guaranteed if response decoding fails).
//
//  Open-items #16 (core-parking-16 session, 2026-09-11): NOT community-flagged. The status
//  line, ASP-suspension note, and rules-collapse behavior all render identically whether
//  `AppConstants.communityEnabled` is `false` or `true` — this is core parking value, ships
//  to everyone, unlike the WP4/Phase 4a rider sections elsewhere in this file.
//
//  No Calendar.current use. No import SwiftUI in Models/ or Services/.
//

import CoreLocation
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

    /// Open-items #16 item 3: source of the "today is ASP-suspended" fact for the parked
    /// segment. **PR #106 QA Finding #2 correction**: `ContentView` already holds
    /// `@State private var aspService = ASPSuspensionService()` (`ContentView.swift:488`,
    /// built for the W7 top banner) and passes THAT instance in at its call site — this
    /// property's original doc comment claimed no such reachable instance existed, which was
    /// simply wrong (it also missed that `ParkingRulesEngine`'s own default init hides a
    /// THIRD copy). The default value below (a fresh instance) exists only so
    /// previews/standalone use and every pre-existing test call site keep compiling without
    /// threading one through — same "inject a real default, override at the real call site"
    /// convention as `scheduler: NotificationScheduler = .shared`, NOT a claim that
    /// `ContentView` needs it.
    let aspService: ASPSuspensionService

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

    // MARK: - Open-items #16 item 2: rules-list disclosure state.

    /// Collapsed by default when the rules list is long (`ParkedCarDetailLogic
    /// .shouldCollapseRules`) — only consulted when that function returns `true`; the
    /// always-visible (≤3 rules) path never reads this.
    @State private var rulesExpanded: Bool = false

    // MARK: - Community 2.0 WP4 rider (S10): per-car reminder-offset chip state.

    /// Local mirror of the GLOBAL `ReminderOffsets` blob (see this file's header note on why
    /// this isn't a `ContentView`-threaded `@Binding`). Loaded fresh at sheet-open time;
    /// saved back to the SAME `UserDefaults` key on every chip toggle.
    @State private var offsets: ReminderOffsets

    // MARK: - Community 2.0 Phase 4a (S10): "Hand your spot to the crew" state.

    @State private var leavingMinutes: Int = 10
    @State private var leavingSoonSubmitting: Bool = false

    /// QA pass 1 (PR #98, Finding #1): transient bridge ONLY, for the brief window between a
    /// successful post and `pinService.visiblePins` reflecting it (normally already true by
    /// the time `performPostLeavingSoon()` returns — `insertCrowdPin` merges the decoded
    /// response before returning — but not guaranteed if response decoding fails). The
    /// durable source of truth for "is there already a live leaving-soon pin for this car" is
    /// `ownLiveLeavingSoonPin`, derived fresh every render from `visiblePins` — NOT this flag.
    /// Resets to `false` on every sheet reconstruct, which is fine: `ownLiveLeavingSoonPin`
    /// alone is what prevents a duplicate post after a dismiss/reopen.
    @State private var leavingSoonJustPosted: Bool = false
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
        aspService: ASPSuspensionService = ASPSuspensionService(),
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
        self.aspService = aspService
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

    /// Open-items #16 item 3: explicit "ASP Suspended — <reason>" note text for the parked
    /// segment, `nil` when today isn't suspended or the segment carries no ASP rule at all
    /// (see `ParkedCarDetailLogic.aspSuspensionNote`'s doc comment for the scoping rationale).
    private var aspSuspensionNoteText: String? {
        guard let seg = resolvedSegment else { return nil }
        return ParkedCarDetailLogic.aspSuspensionNote(
            segmentHasASPRule: ParkedCarDetailLogic.segmentHasASPRule(seg),
            suspensionReason: aspService.reasonForSuspension(now)
        )
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

    /// QA pass 1 fix (PR #98, Finding #1): the still-live `leaving_soon` pin THIS device
    /// already posted for this car, if any — the durable source of truth for whether to show
    /// the leaving-soon CTA or its confirmation state (NOT `leavingSoonJustPosted`, which is
    /// only a transient post-tap bridge — see that property's own doc comment).
    private var ownLiveLeavingSoonPin: CommunityPin? {
        ParkedCarDetailLogic.ownLiveLeavingSoonPin(
            in: pinService?.visiblePins ?? [],
            authorId: pinService?.authService?.currentUserId,
            segmentId: resolvedSegment?.id,
            carLatitude: parkedCar.latitude,
            carLongitude: parkedCar.longitude,
            now: pinService?.nowProvider() ?? now,
            communityEnabled: AppConstants.communityEnabled
        )
    }

    /// `true` when the leaving-soon card should show its confirmation state instead of the
    /// chips/CTA — either because a post is still in flight/just completed this session
    /// (`leavingSoonJustPosted`) or because a live own pin already exists for this car
    /// (`ownLiveLeavingSoonPin`, re-derived on every reopen).
    private var isLeavingSoonPosted: Bool {
        ParkedCarDetailLogic.isLeavingSoonPosted(
            justPosted: leavingSoonJustPosted,
            ownLivePin: ownLiveLeavingSoonPin
        )
    }

    /// Confirmation copy for the leaving-soon card. Shows remaining minutes when a real,
    /// truth-derived pin is available (cheap — `expiresAt` is already decoded); falls back to
    /// the plain confirmation string in the brief just-posted-but-not-yet-merged window.
    private var leavingSoonConfirmationText: String {
        guard let pin = ownLiveLeavingSoonPin, let expiresAt = pin.expiresAt else {
            return "The crew's been told"
        }
        let remainingMinutes = Int(max(0, expiresAt.timeIntervalSince(pinService?.nowProvider() ?? now)) / 60)
        guard remainingMinutes > 0 else { return "The crew's been told" }
        return "The crew's been told \u{2014} \(remainingMinutes) min left"
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

                    // 4a. Open-items #16 item 1: "when does this become not-free" status
                    // line — the sheet's most valuable fact. NOT community-flagged.
                    if let seg = resolvedSegment {
                        statusLineView(for: seg)
                    }

                    // 4a2. Open-items #16 item 3: explicit ASP-suspended-today note.
                    // NOT community-flagged.
                    if let note = aspSuspensionNoteText {
                        aspSuspensionBadge(text: note)
                    }

                    // 4b. Community 2.0 WP4 rider (S10): swept-status badge.
                    // S13c Fix #10: shared `SweptBadgeView` (`Views/BlockDetailView.swift`,
                    // was a per-file duplicate).
                    if let sweptPin = sweptStatusPin {
                        SweptBadgeView(pin: sweptPin, now: pinService?.nowProvider() ?? now)
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

    // MARK: - Open-items #16 item 1: "when does this become not-free" status line

    /// Directly under "Parked Xh ago" — the sheet's single most valuable fact per Kevin's own
    /// framing (open-items #16). Derived purely via `engine.nextRestriction(for:at:)` +
    /// `engine.nextRestrictionTimeLabel(hours:now:)` — the SAME two engine APIs
    /// `NotificationScheduler.buildContent` already consumes for reminder copy, not a
    /// re-derivation of `engine.safetyLabel(for:at:)`'s text. Visually emphasized (bold,
    /// colored via the segment's existing Option B dynamic state color —
    /// `engine.currentStateColor`, no new color mapping invented) since Kevin called this out
    /// as the sheet's most valuable fact.
    ///
    /// PR #106 QA Finding #1 fix: `engine.nextRestriction` intentionally SKIPS `METERED`
    /// rules (correct, pre-existing engine semantics — a meter isn't a move-your-car event).
    /// For a segment whose only rule is `METERED`, that means `restriction.isUnrestricted`
    /// is `true` even while the meter is actively charging, which used to make this line
    /// falsely claim "Free — no restrictions here" directly under the sheet's existing
    /// headline correctly saying "paid until 7pm" (the FT-9 bug class, reintroduced at this
    /// new call site). Fix: when the segment carries a `METERED` rule, pass
    /// `engine.meteredStatus(for:at:)`'s output through as `meteredStatusLabel` — the SAME
    /// source of truth the headline's own FT-9 fix already uses — so
    /// `freeUntilStatusText` can fall back to it instead of the unqualified "free" claim.
    /// `nil` (not computed at all) when the segment has no metered rule, so non-metered
    /// segments pay zero extra cost.
    private func statusLineView(for seg: Segment) -> some View {
        let restriction = engine.nextRestriction(for: seg, at: now)
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)
        let meteredStatusLabel = ParkedCarDetailLogic.segmentHasMeteredRule(seg)
            ? engine.meteredStatus(for: seg, at: now)
            : nil
        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction,
            timeLabel: timeLabel,
            meteredStatusLabel: meteredStatusLabel
        )
        return Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(engine.currentStateColor(for: seg, at: now))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    // MARK: - Open-items #16 item 3: ASP-suspended-today note

    /// "ASP Suspended — <reason>" badge — copy and green tone reused verbatim from
    /// `ASPBanner`'s `.todaySuspended` case (`Views/ASPBanner.swift`), styled as a compact
    /// capsule to match this sheet's existing badge idiom (`SweptBadgeView`) rather than the
    /// top banner's full-width bar.
    private func aspSuspensionBadge(text: String) -> some View {
        Label(text, systemImage: "checkmark.seal.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Color.green, in: Capsule())
            .accessibilityElement(children: .combine)
    }

    // MARK: - Community 2.0 WP4 rider (S10): swept-status badge
    //
    // S13c Fix #10: the badge view itself moved to the shared `SweptBadgeView`
    // (`Views/BlockDetailView.swift`) — this file now only computes WHICH pin to show
    // (`sweptStatusPin` above) and passes it to that shared view at the `body` call site.

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

    /// Open-items #16 item 2: collapses behind a "Rules (N)" `DisclosureGroup`, collapsed by
    /// default, when there are more than 3 rules (`ParkedCarDetailLogic.shouldCollapseRules`)
    /// — keeps the sheet compact. 3 or fewer stay always-visible, matching
    /// `BlockDetailView.rulesSection`'s own uncollapsed convention for the common case (that
    /// view has no collapse idiom to reuse — checked first, per spec).
    @ViewBuilder
    private func rulesSection(for seg: Segment) -> some View {
        let sortedRules = seg.rules.sorted { $0.category.priority < $1.category.priority }
        if ParkedCarDetailLogic.shouldCollapseRules(count: sortedRules.count) {
            DisclosureGroup("Rules (\(sortedRules.count))", isExpanded: $rulesExpanded) {
                rulesList(sortedRules)
                    .padding(.top, 6)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("Rules, \(sortedRules.count) total. \(rulesExpanded ? "Expanded." : "Collapsed.")")
        } else {
            rulesList(sortedRules)
        }
    }

    private func rulesList(_ rules: [ParkingRule]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
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

            if isLeavingSoonPosted {
                Label(leavingSoonConfirmationText, systemImage: "checkmark.circle.fill")
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
    /// coordinate, and only for the duration of its short TTL (stated minutes + 3). QA pass 1
    /// (PR #98, Finding #3) corrected this comment's original overclaim: `insertCrowdPin`
    /// (pre-existing, unchanged by this PR — `CommunityPinService.swift:1552-1572`) DOES
    /// compute and send a client-side `expires_at` in the POST body for every ephemeral type
    /// including `leaving_soon`. What's actually true, and what spec §2.11 guarantees, is
    /// that the server's `derive_pin_expiry` trigger is AUTHORITATIVE — it overrides whatever
    /// `expires_at` the client sent (HANDOFF 2026-08-27 "Gate 1": verified live in prod
    /// against a tampered client value, delta 0s). So: client sends a value, server ignores
    /// it and derives its own — not "the client never sends one."
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

    // MARK: - Open-items #16: "when does this become not-free" status line
    //
    // NOT community-flagged — unlike everything else in this enum, these three functions back
    // core parking value that ships in the flag-off binary too.

    /// The status-line WORDING for `restriction` — item 1 of open-items #16. Pure wording
    /// decision over `ParkingRulesEngine.nextRestriction(for:at:)`'s output; no calendar or
    /// ASP-suspension logic is reimplemented here. The engine's own walker already skips
    /// ASP-suspended days when computing `restriction.hours`
    /// (`ParkingRulesEngine.nextRestriction`'s doc comment), so this function only chooses
    /// which of three established phrasings fits the shape of that answer:
    ///   - `restriction.isActiveNow` (hours == 0): a restriction is already in effect right
    ///     now — "free until" doesn't apply. Reuses `restriction.label` verbatim (e.g. "No
    ///     parking active now", "ASP Mon/Thu active now" — the SAME strings
    ///     `ParkingRulesEngine.nextRestriction` already produces for this case) rather than
    ///     inventing new wording.
    ///   - `restriction.isUnrestricted` (hours >= 168, the sentinel): no NON-METERED
    ///     restriction exists on this block within the 14-day window.
    ///     **PR #106 QA Finding #1**: `nextRestriction` intentionally SKIPS `METERED` rules
    ///     (correct, pre-existing engine semantics — a meter isn't a move-your-car event), so
    ///     this sentinel is reached for a metered-only segment even while its meter is
    ///     actively charging. `meteredStatusLabel` is the caller's own
    ///     `engine.meteredStatus(for:at:)` output — the SAME source of truth the sheet's
    ///     existing headline already uses for this exact case (its own FT-9 fix) — passed
    ///     only when the segment carries a metered rule (`nil` otherwise). When present, this
    ///     branch falls back to it (stripped of its "Metered (...)" wrapper via
    ///     `stripMeteredWrapper` below) instead of the unqualified "free" claim.
    ///   - otherwise: "Free until <timeLabel>" — `timeLabel` is the caller's own
    ///     `engine.nextRestrictionTimeLabel(hours:now:)` output (e.g. "Thursday 9:30 AM"),
    ///     passed in as a plain `String` so this function stays engine-free and pure. A
    ///     segment with BOTH an ASP-family rule and a metered rule reaches this branch (the
    ///     ASP rule is virtually always found within 14 days), so the ASP-derived line
    ///     renders here unaffected by the metered-only fix above.
    nonisolated static func freeUntilStatusText(
        restriction: NextRestriction,
        timeLabel: String,
        meteredStatusLabel: String?
    ) -> String {
        if restriction.isActiveNow {
            return restriction.label ?? "Restricted now"
        }
        if restriction.isUnrestricted {
            if let meteredStatusLabel {
                return stripMeteredWrapper(meteredStatusLabel)
            }
            return "Free \u{2014} no restrictions here"
        }
        return "Free until \(timeLabel)"
    }

    /// **PR #106 QA Finding #1 fix**: strips the "Metered (" / ")" wrapper from
    /// `ParkingRulesEngine.meteredStatus(for:at:)`'s output, e.g. "Metered (paid until 7pm)"
    /// → "paid until 7pm" — byte-identical logic to the engine's own PRIVATE
    /// `stripMeteredWrapper(_:)` (`Services/ParkingRulesEngine.swift`), intentionally
    /// duplicated here rather than widening that method's access level. Same "duplicate
    /// small view-layer formatting helpers rather than expose engine internals" convention
    /// this codebase already documents at `RuleRow.formatMinutes`'s doc comment
    /// (`Views/BlockDetailView.swift`) for the identical reasoning.
    nonisolated static func stripMeteredWrapper(_ label: String) -> String {
        var s = label
        if s.hasPrefix("Metered (") {
            s = String(s.dropFirst("Metered (".count))
        }
        if s.hasSuffix(")") {
            s = String(s.dropLast(1))
        }
        return s
    }

    /// Item 2: whether the sign-details rules list should render collapsed-by-default behind
    /// a disclosure control. 3 or fewer rules stay always-visible (matches
    /// `BlockDetailView.rulesSection`'s own uncollapsed convention for the common case); more
    /// than 3 collapses to keep the sheet compact.
    nonisolated static func shouldCollapseRules(count: Int) -> Bool {
        count > 3
    }

    /// Whether `segment` carries at least one ASP-category rule — the scoping check for item
    /// 3's suspension note (surfacing "ASP Suspended" on a block with no ASP restriction at
    /// all would be noise unrelated to this car).
    nonisolated static func segmentHasASPRule(_ segment: Segment) -> Bool {
        segment.rules.contains { $0.category.isASP }
    }

    /// **PR #106 QA Finding #1**: whether `segment` carries at least one `METERED` rule —
    /// the scoping check for the metered-aware status-line fallback in
    /// `freeUntilStatusText` above.
    nonisolated static func segmentHasMeteredRule(_ segment: Segment) -> Bool {
        segment.rules.contains { $0.category == .metered }
    }

    /// Item 3: the explicit "ASP Suspended — <reason>" note text, `nil` unless BOTH the
    /// segment carries an ASP rule AND today is a suspended date. `suspensionReason` is the
    /// caller's own `ASPSuspensionService.reasonForSuspension(_:)` result — no suspension
    /// calendar logic is reimplemented here. Copy reuses `ASPBanner`'s exact `.todaySuspended`
    /// wording (`Views/ASPBanner.swift`) verbatim.
    nonisolated static func aspSuspensionNote(segmentHasASPRule: Bool, suspensionReason: String?) -> String? {
        guard segmentHasASPRule, let suspensionReason else { return nil }
        return "ASP Suspended \u{2014} \(suspensionReason)"
    }

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

    // MARK: - Own-pin dedupe (QA pass 1, PR #98 Finding #1)

    /// The still-live `leaving_soon` pin THIS device already posted for `carLatitude`/
    /// `carLongitude`, if any — the durable "have I already posted for this car" check that
    /// replaces trusting transient view `@State` across a sheet dismiss/reopen.
    ///
    /// `nil` whenever: `communityEnabled` is `false` (flag-off parity); `authorId` is `nil`
    /// (no authenticated session to compare against — can't safely claim ownership of
    /// anything); or no pin in `pins` matches ALL of: type `leaving_soon`, `authorId` equal,
    /// not resolved, not expired, AND anchored to this car (either the SAME `segmentId` when
    /// both the pin and the car have one, or — the fallback for a car with no resolved
    /// segment, or a pin whose own `segmentId` didn't survive the write — within
    /// `tightRadiusMeters` of the car's raw coordinate).
    ///
    /// Same expiry defense-in-depth reasoning as `liveSweeperPin` above: re-checks
    /// `resolvedAt`/`expiresAt` independently rather than trusting an upstream filter, so an
    /// injected expired/resolved fixture exercises a REAL test case here.
    nonisolated static func ownLiveLeavingSoonPin(
        in pins: [CommunityPin],
        authorId: UUID?,
        segmentId: String?,
        carLatitude: Double,
        carLongitude: Double,
        now: Date,
        communityEnabled: Bool,
        tightRadiusMeters: Double = 30.0
    ) -> CommunityPin? {
        guard communityEnabled, let authorId else { return nil }
        return pins.first { pin in
            guard pin.pinType == .leavingSoon,
                  pin.authorId == authorId,
                  pin.resolvedAt == nil,
                  (pin.expiresAt.map { $0 > now } ?? true)
            else { return false }

            if let segmentId, let pinSegmentId = pin.segmentId, pinSegmentId == segmentId {
                return true
            }
            let carLocation = CLLocation(latitude: carLatitude, longitude: carLongitude)
            let pinLocation = CLLocation(latitude: pin.lat, longitude: pin.lng)
            return carLocation.distance(from: pinLocation) <= tightRadiusMeters
        }
    }

    /// Whether the leaving-soon card should show its confirmation state. `true` if EITHER a
    /// post just completed this session (`justPosted` — the transient post-tap bridge) OR a
    /// live own pin already exists (`ownLivePin`, re-derived every render from truth).
    nonisolated static func isLeavingSoonPosted(justPosted: Bool, ownLivePin: CommunityPin?) -> Bool {
        justPosted || ownLivePin != nil
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

    /// The `positionFraction`/`leavingMinutes`/`segmentId`/`lat`/`lng` params THIS view's
    /// "Leaving in N min" button passes into `CommunityPinService.insertCrowdPin` — extracted
    /// so that wiring is unit-testable without a live network call. `positionFraction` is
    /// derived via the same `CandidateSegmentSearch.nearestSegmentSnap` helper the
    /// `open_spot` placement flow uses, `nil` when there's no resolved segment to project
    /// onto.
    ///
    /// QA pass 1 (PR #98, Finding #3) correction: this struct having no `expires_at` field
    /// is a fact about THIS EXTRACTED PARAMETER TYPE, not a claim about the real
    /// `insertCrowdPin` network payload — that call (one layer up, pre-existing/unchanged by
    /// this session) DOES compute and send a client-side `expires_at` for every ephemeral
    /// type including `leaving_soon` (`CommunityPinService.swift:1552-1572`). The server's
    /// `derive_pin_expiry` trigger is what makes that harmless (spec §2.11, verified live —
    /// HANDOFF 2026-08-27 "Gate 1"): it overrides the client's value unconditionally. Tests
    /// on this struct verify THIS view's payload shape, not the network wire format.
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
