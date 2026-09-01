//
//  PinDetailSheet.swift
//  WePark
//
//  Tier 1 Pin Display — read-only detail sheet for community pins.
//  Tier 3 Sub-PR #1 additions: reactions row for ephemeral crowd pins.
//  FT-15 / TF2-15 Stream B4 additions: block-scoped restriction detail view, widened
//  reactions gate, construction glyph/color.
//  FT-2 addition: own-pin delete affordance ("I reported this by mistake") replaces the
//  vote buttons when the current user is the pin's author.
//  Community 2.0 Phase 3 (build 20 S9) additions: `open_spot` reuses the existing
//  confirm/dispute `voteSection` unchanged (already covered by `showsReactionsRow`'s
//  crowd+ephemeral gate — no code change needed there, verified not assumed); `leaving_soon`
//  is special-cased to a claim-only `claimSection` ("I'm heading there" — no confirm/dispute
//  row at all).
//  Spec: docs/tier1-pin-display-spec.md §8, docs/tier3-auth-and-reactions-spec.md §3.10,
//  docs/ft15-tf215-temporary-block-restrictions-spec.md §9.2/§9.3,
//  docs/ft2-delete-own-pin-spec.md §4.2,
//  docs/community-2.0-reconciliation-spec.md §2.10, §3 Phase 3.
//
//  Surfaces:
//   - filming (open_data, reportGroupId == nil): type icon + label, open-data badge,
//     production name, expiry, NYC Film Office link (if filmOfficeUrl non-nil).
//   - special_event: type icon + label, open-data badge, event name, event type, expiry.
//   - filming / construction, block-scoped (reportGroupId != nil, FT-15/TF2-15 §9.2/§9.3):
//     Upcoming/Active badge, covered block (parsed from the 4-part blockfaceKey
//     segment_id), starts_at–expires_at window, multi-blockface extent if >1 sibling
//     shares the reportGroupId, notes.
//   - enforcement_active / sweeper_passed (Tier 3 ephemeral crowd pins):
//       reactions row with "Still there?" (confirm + extend) and "Gone" (dispute) buttons
//       for other users' pins, or a delete affordance (FT-2) for the caller's own pin.
//
//  Reactions row (sub-PR #1; widened FT-15/TF2-15 AC-C4; FT-2 own-pin branch):
//   - Shown when pin.source == .crowd AND (pin.lifespan == .ephemeral OR
//     pin.reportGroupId != nil) — see `CommunityPin.showsReactionsRow`
//     (Views/PinMarkerAnnotation.swift).
//   - A1 own-pin guard (`isOwnPin`): pin.authorId == authService.currentUserId.
//   - FT-2: when `isOwnPin`, the "Community Check" header, confirm-count badge, and both
//     vote buttons are replaced entirely by a single destructive "I reported this by
//     mistake" button. Tapping it presents a `.confirmationDialog` before calling
//     `CommunityPinService.deleteCrowdPin(id:)`. Own pins never show vote buttons — there
//     is no more "greyed-out dead end" state (docs/field-testing-log.md FT-3 note).
//   - "Still there?" disabled (non-own pins only) when pin.lifespan == .ephemeral AND pin
//     is within 5min of the 2h TTL cap — see `isStillHereDisabled`'s doc comment for why
//     this check is scoped to ephemeral pins only (non-ephemeral pins never hit it).
//   - Confirm count badge reads from pin.confirmCount (updated in real time via Realtime).
//   - Loading state: ProgressView while async calls are in-flight.
//
//  Invariants:
//   - No Calendar.current (AC-D19, AC-I5). All time arithmetic uses Date() + TimeInterval,
//     or a plain DateFormatter with `.easternTime` (no Calendar involved).
//   - No force-unwraps.
//   - CommunityPin.swift is NOT modified BY THIS FILE (AC-D20, AC-I2) — display logic
//     lives here, model shape lives in Models/CommunityPin.swift. That was a
//     diff-minimization discipline scoped to the Tier 3 sub-PR #1 PR this comment
//     originates from, not a standing freeze on the model file itself.
//   - No setRegion, updateUIView mutation, or headlessWindow guard (AC-I3).
//

import SwiftUI

// MARK: - PinDetailSheet

struct PinDetailSheet: View {

    let pin: CommunityPin
    let onDismiss: () -> Void

    /// Auth service for the A1 own-pin guard and write-path identity.
    /// Passed from ContentView (same shared instance as WeParkApp root).
    var authService: SupabaseAuthService

    /// Pin service for reaction write calls (upsertVote, callExtendPinExpiry).
    var pinService: CommunityPinService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    Divider()
                    detailSection
                    // Tier 3 sub-PR #1: reactions row for ephemeral crowd pins.
                    // FT-15/TF2-15 AC-C4 widened this from `pin.lifespan == .ephemeral` only
                    // to also cover block-scoped session/durable reports — see
                    // `CommunityPin.showsReactionsRow` (PinMarkerAnnotation.swift) for the
                    // exact widened condition. Lives on the model (not this view) so it's
                    // directly unit-testable.
                    if pin.showsReactionsRow {
                        Divider()
                        ReactionsRow(
                            pin: pin,
                            authService: authService,
                            pinService: pinService,
                            onDismiss: onDismiss
                        )
                    }
                }
                .padding()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Navigation title

    private var navigationTitle: String {
        switch pin.pinType {
        case .filming:       return "Filming"
        case .specialEvent:  return "Special Event"
        default:             return pin.pinType.displayLabel
        }
    }

    // MARK: - Header section (icon + label + badge)

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            // Type icon in colored circle (matches PinMarkerAnnotation style).
            ZStack {
                Circle()
                    .fill(iconColor)
                    .frame(width: 48, height: 48)
                Image(systemName: iconSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(pin.displayTitle ?? pin.pinType.displayLabel)
                    .font(.headline)
                    .foregroundStyle(.primary)

                // Open-data source badge.
                Text(sourceBadgeLabel)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(iconColor, in: Capsule())
            }
        }
    }

    // MARK: - Detail section (per-type fields)

    @ViewBuilder
    private var detailSection: some View {
        // FT-15/TF2-15 §9.2/§9.3: block-scoped reports (filming or construction, produced
        // by the map-tap-select report flow) always have `reportGroupId != nil` and get a
        // dedicated detail view — richer than genericDetails (shows the covered block +
        // the report's start/end window + multi-blockface extent), and shared between
        // filming and construction per §9.3's "same primitive" design. This check runs
        // BEFORE the pinType switch so it also catches crowd `filming` reports (which
        // would otherwise fall into the open-data-oriented `filmingDetails` below).
        if pin.reportGroupId != nil {
            blockScopedDetails
        } else {
            switch pin.pinType {
            case .filming:
                filmingDetails
            case .specialEvent:
                specialEventDetails
            default:
                genericDetails
            }
        }
    }

    // MARK: block-scoped restriction details (FT-15 / TF2-15 §9.2, §9.3, AC-C5)

    @ViewBuilder
    private var blockScopedDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusBadge

            if let segmentId = pin.segmentId {
                detailRow(label: "Block", value: blockfaceSummary(for: segmentId))
            }

            detailRow(label: "Window", value: windowSummary)

            // AC-C5 (nice-to-have, not required for AC pass): if other blockfaces share
            // this report's reportGroupId, surface the full extent so the user
            // understands this marker is one of several covering the same report.
            if let groupId = pin.reportGroupId {
                let siblingCount = pinService.visiblePins.filter { $0.reportGroupId == groupId }.count
                if siblingCount > 1 {
                    detailRow(label: "Extent", value: "Part of a \(siblingCount)-blockface report")
                }
            }

            if let notes = pin.notes {
                detailRow(label: "Notes", value: notes)
            }
        }
    }

    /// "Upcoming" (window hasn't started yet) vs. "Active now" badge — AC-C2.
    ///
    /// Uses `pinService.nowProvider()` (not a bare `Date()`) so this stays deterministic
    /// under test injection, matching every other time comparison in this feature (QA nit
    /// #6, docs/qa/ft15-b4-fetch-channel-qa.md). `pinService` is a required, non-optional
    /// property on this view (unlike `BlockDetailView`/`ParkedCarDetailView`'s optional
    /// `pinService?`), so no fallback is needed here.
    private var statusBadge: some View {
        let upcoming = pin.isUpcoming(now: pinService.nowProvider())
        return Text(upcoming ? "Upcoming" : "Active now")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((upcoming ? Color.blue : Color.green).opacity(0.15), in: Capsule())
            .foregroundStyle(upcoming ? .blue : .green)
    }

    /// Parses a `Segment.blockfaceKey`-shaped `segment_id` ("STREET|LO|HI|SIDE") into a
    /// human-readable summary, e.g. "E 2nd St, 1st Ave–3rd Ave (North side)". Falls back to
    /// the raw string if the shape doesn't match 4 parts (e.g. a legacy 3-part key) —
    /// display-only; this never re-derives block identity (§4.3: matching stays
    /// string-equality only, on the exact `segmentId` value already decoded from the row).
    private func blockfaceSummary(for segmentId: String) -> String {
        let parts = segmentId.components(separatedBy: "|")
        guard parts.count == 4 else { return segmentId }
        let street = StreetNameNormalizer.canonical(parts[0])
        let lo = StreetNameNormalizer.canonical(parts[1])
        let hi = StreetNameNormalizer.canonical(parts[2])
        let side = sideLabel(parts[3])
        return "\(street), \(lo)\u{2013}\(hi) (\(side) side)"
    }

    /// Converts a single-letter side code to a capitalized label ("N" → "North").
    /// Any other value passes through unchanged. Mirrors the sideLabel helper already
    /// duplicated per-view in BlockDetailView/ParkedCarDetailView (view-file-local by
    /// existing project convention — see RuleRow's own duplicated formatMinutes comment).
    private func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North"
        case "S": return "South"
        case "E": return "East"
        case "W": return "West"
        default:  return code
        }
    }

    /// "<start> – <end>" window summary, e.g. "Aug 13, 6:00 AM – Aug 14, 6:00 AM".
    /// `startsAt == nil` means "active immediately" (§5.1) — rendered as "now".
    /// `expiresAt == nil` means no end time was set — rendered as "no end date set".
    private var windowSummary: String {
        let startText = pin.startsAt.map(Self.windowDateFormatter.string(from:)) ?? "now"
        guard let expiresAt = pin.expiresAt else {
            return "Starts \(startText) \u{2013} no end date set"
        }
        return "\(startText) \u{2013} \(Self.windowDateFormatter.string(from: expiresAt))"
    }

    /// Eastern-time formatter for the block-scoped window summary. No `Calendar.current`
    /// (AC-D19) — a plain `DateFormatter` with `.easternTime` timeZone, same pattern as
    /// `CommunityPin.formatExpiry`.
    private static let windowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = .easternTime
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    // MARK: filming details

    @ViewBuilder
    private var filmingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meta = pin.meta, case .filming(let m) = meta {
                if let name = m.productionName {
                    detailRow(label: "Production", value: name)
                }
                // Block / address: show segment street name if segmentId is set,
                // else lat/lng fallback. Full reverse-geocode is a TF2 enhancement.
                if let segmentId = pin.segmentId {
                    let streetName = segmentId.components(separatedBy: "|").first ?? segmentId
                    detailRow(label: "Block", value: streetName)
                }

                if let urlString = m.filmOfficeUrl, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("NYC Film Office Permit", systemImage: "link")
                            .font(.subheadline)
                    }
                }
            }

            if let expiresAt = pin.expiresAt {
                detailRow(label: "Until", value: expiresAtFormatted(expiresAt))
            }
        }
    }

    // MARK: special_event details

    @ViewBuilder
    private var specialEventDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meta = pin.meta, case .specialEvent(let m) = meta {
                detailRow(label: "Event", value: m.eventName)
                detailRow(label: "Type", value: m.eventType.humanReadable)
            }
            if let expiresAt = pin.expiresAt {
                detailRow(label: "Until", value: expiresAtFormatted(expiresAt))
            }
        }
    }

    // MARK: generic details (fallback)

    @ViewBuilder
    private var genericDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let expiresAt = pin.expiresAt {
                detailRow(label: "Until", value: expiresAtFormatted(expiresAt))
            }
            if let notes = pin.notes {
                detailRow(label: "Notes", value: notes)
            }
        }
    }

    // MARK: - Detail row helper

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Time formatting

    /// Formats an expiry Date for the detail sheet.
    /// Uses Calendar.easternTime (AC-D19 — no Calendar.current).
    private func expiresAtFormatted(_ date: Date) -> String {
        CommunityPin.formatExpiry(date)
    }

    // MARK: - Style helpers

    private var iconSymbol: String {
        switch pin.pinType {
        case .filming:           return "video.fill"
        case .specialEvent:      return "star.fill"
        case .construction:      return "hammer.fill"
        case .enforcementActive: return "exclamationmark.triangle.fill"
        case .sweeperPassed:     return "truck.box.fill"
        case .brokenMeter:       return "parkingsign.circle.fill"
        default:                 return "mappin.fill"
        }
    }

    private var iconColor: Color {
        switch pin.pinType {
        case .filming:           return .purple
        case .specialEvent:      return .orange
        case .construction:      return ParkingColors.constructionOrange
        case .enforcementActive: return .red
        case .sweeperPassed:     return Color(red: 0.0, green: 0.55, blue: 0.27)
        case .brokenMeter:       return .gray
        default:                 return .gray
        }
    }

    private var sourceBadgeLabel: String {
        switch pin.pinType {
        case .filming:      return "Open Data — NYC Film Permits"
        case .specialEvent: return "Open Data"
        default:            return pin.source == .openData ? "Open Data" : "Community"
        }
    }
}

// MARK: - ReactionsRow

/// Reactions row for Tier 3 ephemeral crowd pins.
///
/// Non-own pins show "Still there?" (confirm + extend TTL) and "Gone" (dispute) buttons,
/// with the live confirm count from `pin.confirmCount`. The caller's own pin (FT-2) shows
/// a single destructive delete affordance instead — see `deleteSection`.
///
/// Design (community-1.0-direction.md §6.1):
///   - One-tap, binary, no confirmation sheet for votes.
///   - Tap targets are 44pt minimum (HIG).
///   - A1 guard: vote buttons hidden (not just disabled — FT-2) when
///     pin.authorId == authService.currentUserId.
private struct ReactionsRow: View {

    let pin: CommunityPin
    var authService: SupabaseAuthService
    var pinService: CommunityPinService

    /// Closes the parent `PinDetailSheet`. FT-2: called after a successful delete
    /// (`docs/ft2-delete-own-pin-spec.md` §4.2 step 3) before the toast fires.
    var onDismiss: () -> Void

    /// True while a reaction/delete call is in-flight. Replaces the confirm count (or the
    /// delete button) with a spinner and disables further taps (AC-FT2.10 double-tap guard).
    @State private var isLoading: Bool = false

    /// Last error from a reaction/delete call. Cleared on next successful call.
    @State private var errorMessage: String? = nil

    /// Drives the FT-2 delete confirmation `.confirmationDialog` presentation.
    @State private var showDeleteConfirmation: Bool = false

    /// Community 2.0 Phase 3 (build 20 S9): the "someone beat you to it" race-safe outcome of
    /// a failed `claim_pin` call (spec §2.10/§3 Phase 4 — `claimPin(pinId:)` returning `false`).
    /// Kept deliberately SEPARATE from `errorMessage` (below) and rendered without the red
    /// error styling — this is the EXPECTED outcome of a race two neighbors both lost/won,
    /// not a failure. Cleared on the next claim attempt.
    @State private var claimMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // FT-2 (AC-FT2.2, AC-FT2.12): own pins get a delete affordance instead of the
            // "Community Check" header / confirm badge / vote buttons — there is no more
            // "greyed out, nothing to do" dead end (docs/field-testing-log.md FT-3 note).
            //
            // Community 2.0 Phase 3 (build 20 S9): routes through the shared, pure
            // `CommunityPin.reactionsRowKind(currentUserId:)` (`Views/PinMarkerAnnotation.swift`)
            // rather than re-deriving this branching inline, so this view and
            // `CrewFeedSection.PinFeedRow.actionRow` can never disagree about which row a pin
            // gets. `.hidden` never reaches this view in practice (the parent
            // `PinDetailSheet.body` only instantiates `ReactionsRow` when
            // `pin.showsReactionsRow` is already true) — the `EmptyView()` fallback is
            // defensive, not a real code path.
            switch pin.reactionsRowKind(currentUserId: authService.currentUserId) {
            case .delete: deleteSection
            case .claim:  claimSection
            case .vote:   voteSection
            case .hidden: EmptyView()
            }

            // Error display (non-blocking — user can retry). Genuine failures only —
            // `claimMessage` (the race-safe "someone beat you to it" outcome) is rendered
            // separately inside `claimSection`, never here.
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Delete this report?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await handleDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove your pin. This cannot be undone.")
        }
    }

    // MARK: - Own-pin delete section (FT-2)

    @ViewBuilder
    private var deleteSection: some View {
        if isLoading {
            HStack {
                ProgressView()
                    .frame(width: 20, height: 20)
                Spacer()
            }
        } else {
            Button {
                showDeleteConfirmation = true
            } label: {
                Label("I reported this by mistake", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isLoading)
            .accessibilityLabel("Delete this report — tap to remove your accidental pin")
        }
    }

    // MARK: - leaving_soon claim section (Community 2.0 Phase 3, build 20 S9)

    /// `leaving_soon`'s reactions row is claim-only — no "Still there? / Gone" pair (spec §3
    /// Phase 3, `design/prototype.html:203-208`). Three states:
    ///   1. `pin.claimedBy != nil` — already claimed (by anyone, including this viewer): show
    ///      the informational tag, no button. `claimedBy` is decode-only and reflects real
    ///      server state (never client-writable) — always trustworthy the instant it decodes.
    ///      QA pass 1 Finding #3 (PR #97): the tag's COPY distinguishes the viewer's own
    ///      successful claim from anyone else's via the shared
    ///      `CommunityPin.claimStatusCopy(currentUserId:)`.
    ///   2. Unclaimed, not loading: the "I'm heading there" button.
    ///   3. Loading: spinner, matching every other in-flight state in this view.
    @ViewBuilder
    private var claimSection: some View {
        if let statusCopy = pin.claimStatusCopy(currentUserId: authService.currentUserId) {
            Label(statusCopy, systemImage: "car.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.blue)
        } else if isLoading {
            HStack {
                ProgressView()
                    .frame(width: 20, height: 20)
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await handleClaim() }
                } label: {
                    Label("I'm heading there", systemImage: "car.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isLoading)
                .accessibilityLabel("I'm heading there — claim this spot")

                // Race-safe "someone beat you to it" outcome (spec §2.10/§3 Phase 4) —
                // deliberately NOT styled as an error (see `claimMessage`'s doc comment).
                if let claimMessage {
                    Text(claimMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Non-own-pin vote section

    @ViewBuilder
    private var voteSection: some View {
        // Section header
        Text("Community Check")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

        // Confirm count badge or loading spinner
        HStack {
            if isLoading {
                ProgressView()
                    .frame(width: 20, height: 20)
            } else {
                Label(
                    pin.confirmCount == 1
                        ? "1 confirm"
                        : "\(pin.confirmCount) confirms",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }

        // Reaction buttons
        HStack(spacing: 12) {
            // "Still there?" button — confirm + extend TTL.
            Button {
                Task { await handleStillHere() }
            } label: {
                Label("Still there?", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(isStillHereDisabled)
            .accessibilityLabel("Still there? Confirm this pin and extend its time")

            // "Gone" button — dispute.
            Button {
                Task { await handleGone() }
            } label: {
                Label("Gone", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isGoneDisabled)
            .accessibilityLabel("Gone — dispute this pin")
        }
    }

    // MARK: - Button enable logic

    /// True when the user's own pin (A1 own-pin guard, iOS-side, decision A1 per spec OQ-1).
    /// FT-2 reuses this unchanged guard to route to `deleteSection` instead of `voteSection`.
    private var isOwnPin: Bool {
        guard let authorId = pin.authorId,
              let currentId = authService.currentUserId else { return false }
        return authorId == currentId
    }

    /// "Still there?" is disabled when:
    ///   1. It is the user's own pin (A1 guard) — dead code post-FT-2 since own pins never
    ///      render `voteSection` at all, but kept as a defensive second guard.
    ///   2. The pin is `ephemeral` AND within 5 minutes of the 2h TTL cap
    ///      (expires_at > now + 115 min). No point extending — the cap is close.
    ///      Uses Date() + TimeInterval (no Calendar.current).
    ///   3. A reaction call is in-flight.
    ///
    /// FT-15/TF2-15 fix (AC-C4 widened this row to also cover block-scoped `session`/
    /// `durable` reports, whose `expires_at` sits days out, not minutes): the TTL-cap
    /// proximity check in rule 2 is now scoped to `pin.lifespan == .ephemeral` only.
    /// Without this guard, a construction report with `expires_at` 14 days out would
    /// satisfy `expiresAt > now + 115min` for essentially its entire lifetime, permanently
    /// disabling the button — not because extending would be destructive (the underlying
    /// `extend_pin_expiry` RPC already no-ops server-side for non-ephemeral pins via its own
    /// `where lifespan = 'ephemeral'` guard, `supabase/02-pins-schema.sql:262`), but because
    /// the client-side disable check was written assuming every pin here is ephemeral. This
    /// widen makes the confirm vote (the part that matters for non-ephemeral reports) always
    /// reachable, while the harmless-but-pointless extend-RPC call underneath still fires —
    /// it just no-ops for these pin types.
    private var isStillHereDisabled: Bool {
        if isOwnPin || isLoading { return true }
        guard pin.lifespan == .ephemeral else { return false }
        if let expiresAt = pin.expiresAt {
            // 115 minutes = 2h cap - 5min buffer.
            return expiresAt > Date().addingTimeInterval(115 * 60)
        }
        return false
    }

    /// "Gone" is disabled when it is the user's own pin (A1 guard) or a call is in-flight.
    /// Dead code post-FT-2 for the same reason as `isStillHereDisabled`'s rule 1 — kept as
    /// a defensive second guard, not the primary mechanism (that's `isOwnPin` routing).
    private var isGoneDisabled: Bool {
        isOwnPin || isLoading
    }

    // MARK: - Action handlers

    /// "Still there?" tap: confirm vote + extend TTL.
    ///
    /// AC-V2: both `upsertVote(.confirm)` AND `callExtendPinExpiry` are called.
    private func handleStillHere() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.upsertVote(pinId: pin.id, vote: .confirm)
            try await pinService.callExtendPinExpiry(pinId: pin.id)
        } catch {
            errorMessage = "Couldn't confirm — please try again."
        }
        isLoading = false
    }

    /// "Gone" tap: dispute vote only (AC-V3: does NOT call callExtendPinExpiry).
    private func handleGone() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.upsertVote(pinId: pin.id, vote: .dispute)
        } catch {
            errorMessage = "Couldn't report — please try again."
        }
        isLoading = false
    }

    /// "I'm heading there" tap (Community 2.0 Phase 3, build 20 S9): calls `claim_pin`. A
    /// `false` return is the expected, race-safe "someone beat you to it" outcome (spec
    /// §2.10/§3 Phase 4) — routed to `claimMessage`, NOT `errorMessage`. A thrown error
    /// (network/auth failure) is a genuine failure and routes to `errorMessage` as usual. No
    /// local optimistic patch of `pin.claimedBy` on success — that field is decode-only
    /// (`CommunityPin.claimedBy`'s doc comment) and the RPC's own `UPDATE public.pins` already
    /// flows through the existing Realtime pipeline, same precedent as `handleStillHere`/
    /// `handleGone` never locally patching `confirmCount`/`disputeCount` either.
    private func handleClaim() async {
        isLoading = true
        errorMessage = nil
        claimMessage = nil
        do {
            let claimed = try await pinService.claimPin(pinId: pin.id)
            if !claimed {
                claimMessage = "Someone beat you to it — first come, first served."
            }
        } catch {
            // QA pass 1 Finding #4 (PR #97): unified with CrewFeedSection.PinFeedRow's
            // handleClaim wording — both claim call sites now show identical copy.
            errorMessage = "Couldn't claim — try again."
        }
        isLoading = false
    }

    /// Delete-confirmed tap (FT-2, spec §4.2): calls `deleteCrowdPin`, which itself performs
    /// the optimistic local removal before the network call. On success, dismisses the sheet
    /// and shows the "Report deleted." toast (spec AC-FT2.7, AC-FT2.8). On failure, keeps the
    /// sheet open and shows an inline error (AC-FT2.9) — `deleteCrowdPin` itself restores the
    /// pin to the map before rethrowing (unless Realtime already confirmed the delete really
    /// went through server-side), so the inline error here and what the map shows agree: the
    /// pin is back, matching "the delete didn't work."
    private func handleDelete() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.deleteCrowdPin(id: pin.id)
            onDismiss()
            await MainActor.run {
                ToastService.shared.show(message: "Report deleted.")
            }
        } catch {
            isLoading = false
            errorMessage = "Couldn't delete — please try again."
        }
    }
}

// MARK: - SpecialEventMeta.EventType human-readable label

private extension SpecialEventMeta.EventType {
    var humanReadable: String {
        switch self {
        case .parade:        return "Parade"
        case .marathon:      return "Marathon"
        case .snowEmergency: return "Snow Emergency"
        case .fair:          return "Fair"
        case .other:         return "Special Event"
        }
    }
}

// MARK: - Preview

#Preview {
    // Filming pin fixture for preview only.
    let fixtureJSON = """
    {
      "id": "B0000000-0000-0000-0000-000000000001",
      "pin_type": "filming",
      "source": "open_data",
      "lifespan": "session",
      "lat": 40.7505,
      "lng": -73.9965,
      "segment_id": "7th Ave|W 32nd St|W 33rd St",
      "zone_id": null,
      "author_id": null,
      "author_username": null,
      "created_at": "2026-06-01T10:00:00+00:00",
      "updated_at": "2026-06-01T10:00:00+00:00",
      "expires_at": "2026-06-02T20:00:00+00:00",
      "resolved_at": null,
      "confirm_count": 3,
      "dispute_count": 0,
      "meta": { "permit_id": "NYC-2026-001", "production_name": "The Lincoln Tunnel", "film_office_url": "https://www.nyc.gov/filmnyc" },
      "notes": null
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string) ?? Date()
    }

    let pin = try! decoder.decode(CommunityPin.self, from: fixtureJSON)
    return PinDetailSheet(
        pin: pin,
        onDismiss: {},
        authService: SupabaseAuthService(),
        pinService: CommunityPinService()
    )
    .presentationDetents([.medium, .large])
}
