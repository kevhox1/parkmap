//
//  BlockDetailView.swift
//  WePark
//
//  W4: Block detail sheet shown when the user taps a colored polyline on the map.
//
//  Sheet content (top to bottom):
//    1. Severity color band (6pt, decorative, accessibilityHidden)
//    2. Block header — "<StreetName> — <SideLabel>" + "between X and Y"
//    3. Primary safety label (first focusable a11y element)
//    3b. FT-15/TF2-15 (§9.2): "Temporary restriction reported" banner, shown only when
//        pinService is non-nil and CommunityPinService.blockScopedRestriction(forBlockfaceKey:)
//        finds a match for this segment's blockfaceKey. Tap opens PinDetailSheet.
//    4. Rules list, ordered by Category.priority (most restrictive first)
//    5. "Park here →" stub button (disabled, W5 entry point)
//
//  No Calendar.current use anywhere. No import SwiftUI in Models/ or Services/.
//  All view-level helpers (side label, days compact string) live in this file.
//
//  AC-W4.4 parity: safetyLabel(for:at:).text is byte-identical to the PWA's
//  actionableSafetyLabel() for the same segment and wall-clock time.
//
//  S13b (build 20, docs/design/community-2.0-hero-gap-inventory.md WP3) additions — the block
//  detail redesign's missing sections, ALL flag-gated behind `AppConstants.communityEnabled`:
//  flag off, this sheet renders and behaves byte-identically to the pre-S13b shipped version.
//  Visual truth: design/screenshots/07-block-detail.png. Exact structure/copy:
//  design/prototype.html:218-279 (block detail), :261-275 (chatter specifics), :881 (verbatim
//  empty-chatter copy).
//   6. Swept badge — "🧹 Swept X ago · N confirms". Same DECISION logic as
//      `ParkedCarDetailView`'s S10 badge, reused directly (not forked):
//      `ParkedCarDetailLogic.liveSweeperPin`/`confirmCountLabel` are already `internal`, called
//      here unchanged. Only the small color literal + `Text` composition is duplicated, per
//      this codebase's own established house style of duplicating small view-layer literals
//      across files rather than sharing them (see `RuleRow.formatMinutes`'s doc comment for the
//      same reasoning already applied once in this file).
//   7. "LIVE ON THIS BLOCK" — ephemeral/crowd pins anchored to this exact block
//      (`pin.segmentId == segment.id`, the raw tile-segment id — see `BlockDetailLogic
//      .liveBlockPins`'s doc comment for why this never collides with the DIFFERENT
//      `blockfaceKey`-keyed id shape the block-scoped restriction banner above already uses).
//      Rendered via `CrewFeedSection.PinFeedRow` (widened from `private` to `internal` this
//      session) — reactions route through the SAME `CommunityPin.reactionsRowKind
//      (currentUserId:)` the crew feed already uses, so the two surfaces can't disagree about
//      which pins get which action.
//   8. "BLOCK CHATTER" — segment-anchored `zone_messages` thread + a "Message this block…"
//      compose bar, backed by the net-new `ZoneMessageService.sendMessage`/
//      `fetchMessages(segmentId:)` write/read paths (see that file's header for the RLS/
//      RETURNING verdict). Identity-gated via the SAME local nested sheet-on-sheet pattern
//      `ParkedCarDetailView`/`ReportSheet` already use (this view is itself presented via
//      `ActiveSheet.blockDetail` — a `.sheet(item:)`-presented context exactly like those two,
//      NOT the top-level, non-nested `ActiveSheet.identityPrompt` case that path is reserved
//      for — see `ContentView.swift`'s own comment distinguishing the two).
//

import CoreLocation
import SwiftUI

// MARK: - BlockDetailView

struct BlockDetailView: View {

    let segment: Segment
    let engine: ParkingRulesEngine
    let onDismiss: () -> Void

    /// W5: Called when the user taps "Park here →". When nil, the button stays
    /// disabled with the "Coming next" caption (preview / standalone use).
    let onParkHere: (() -> Void)?

    /// FT-15/TF2-15 (§9.2): Pin service used to look up an active/upcoming block-scoped
    /// restriction covering this segment. `nil` in previews/standalone use — the banner
    /// simply doesn't render (same optional-service pattern as `onParkHere`).
    /// NOTE (`var`, not `let`): a `let` property WITH a default value is excluded from the
    /// synthesized memberwise initializer — Swift reasons a constant already holds its value.
    /// Declared `let` here, this compiled locally but made `BlockDetailView(… pinService:
    /// onOpenRestriction:)` fail at the ContentView call site with "extra arguments at
    /// positions #5, #6". `var` keeps the default AND admits the parameter. Caught by Kevin's
    /// Mac compile, 2026-08-18.
    var pinService: CommunityPinService? = nil

    /// FT-15/TF2-15 (§9.2): Called when the user taps the restriction banner. Passes the
    /// matched `CommunityPin` so the caller can present `PinDetailSheet` (reuses the
    /// existing `activeSheet = .pinDetail(pin)` pattern in ContentView — no new sheet
    /// case needed). `nil` in previews/standalone use, matching `onParkHere`'s convention.
    var onOpenRestriction: ((CommunityPin) -> Void)? = nil

    /// S13b: zone-chat read/write service backing the "BLOCK CHATTER" section. `nil` in
    /// previews/standalone use — the section simply doesn't render (same optional-service
    /// pattern as `pinService`). `var` (not `let`), same reason as `pinService` above: a `let`
    /// property with a default value is excluded from Swift's synthesized memberwise
    /// initializer.
    var zoneMessageService: ZoneMessageService? = nil

    // Evaluate once at sheet-open time (stable reference time for the whole sheet).
    private let now: Date = .nowET

    /// FT-15/TF2-15 (§9.2): the block-scoped restriction pin covering this segment, if any.
    private var blockScopedRestriction: CommunityPin? {
        pinService?.blockScopedRestriction(forBlockfaceKey: segment.blockfaceKey)
    }

    // MARK: - S13b: swept badge + "LIVE ON THIS BLOCK" state

    /// The live `sweeper_passed` pin covering this segment, if any — SAME decision logic as
    /// `ParkedCarDetailView`'s S10 badge (`ParkedCarDetailLogic.liveSweeperPin`, reused
    /// directly, not forked).
    private var liveSweeperPin: CommunityPin? {
        ParkedCarDetailLogic.liveSweeperPin(
            in: pinService?.visiblePins ?? [],
            segmentId: segment.id,
            now: pinService?.nowProvider() ?? now,
            communityEnabled: AppConstants.communityEnabled
        )
    }

    /// `pinService.authService`, exposed for `CrewFeedSection.PinFeedRow`'s (non-optional)
    /// `authService` parameter. In production this is non-nil whenever `pinService` is
    /// non-nil — `ContentView` always constructs `pinService` with a real `authService`
    /// (`CommunityPinService(authService: authService, ...)`); only previews/standalone use
    /// can hit the `nil` case, where `liveOnThisBlockSection` simply doesn't render.
    private var authService: SupabaseAuthService? {
        pinService?.authService
    }

    /// Ephemeral/crowd pins anchored to this exact block, newest-first.
    private var liveBlockPins: [CommunityPin] {
        BlockDetailLogic.liveBlockPins(
            in: pinService?.visiblePins ?? [],
            segmentId: segment.id,
            communityEnabled: AppConstants.communityEnabled
        )
    }

    // MARK: - S13b: "BLOCK CHATTER" state

    @State private var chatMessages: [ZoneMessage] = []
    @State private var isLoadingChat = false
    @State private var chatDraft: String = ""
    @State private var isSendingChat = false
    @State private var chatSendError: String? = nil

    /// Holds the "resume posting" closure while the local identity sheet is up — mirrors
    /// `ParkedCarDetailView.pendingIdentityAction` exactly (see this file's header note on why
    /// the local nested sheet, not `ActiveSheet.identityPrompt`, is the correct precedent here).
    @State private var pendingIdentityAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Severity color band — decorative, not a focusable a11y element.
            severityBand

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header row: close button + block title
                    headerRow

                    // 3. Primary safety label (first focusable element per §3.5 / palette §5.1).
                    safetyLabelView

                    // 3c. S13b: swept-status badge (same decision logic as ParkedCarDetailView).
                    if AppConstants.communityEnabled, let sweptPin = liveSweeperPin {
                        sweptBadgeView(for: sweptPin)
                    }

                    // 3b. FT-15/TF2-15 (§9.2): temporary restriction banner.
                    if let restriction = blockScopedRestriction {
                        TemporaryRestrictionBanner(pin: restriction, now: pinService?.nowProvider() ?? now) {
                            onOpenRestriction?(restriction)
                        }
                    }

                    // 4. Rules list
                    if !segment.rules.isEmpty {
                        rulesSection
                    }

                    // 4b. S13b: "LIVE ON THIS BLOCK" — ephemeral/crowd pins on this segment.
                    liveOnThisBlockSection

                    // 4c. S13b: "BLOCK CHATTER" — segment-anchored chat thread + compose bar.
                    blockChatterSection

                    // 5. Park here stub button
                    parkHereStub
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        // S13b: local nested identity-sheet interception — see `pendingIdentityAction`'s doc
        // comment for why this (not `ActiveSheet.identityPrompt`) is the correct precedent.
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
                            print("[BlockDetailView] upsertProfile failed: \(error)")
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
        let color = engine.currentStateColor(for: segment, at: now)
        return Rectangle()
            .fill(color)
            .frame(height: 6)
            .accessibilityHidden(true)
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                // "<StreetName> — <SideLabel>"
                // Marked accessibilityHidden so that VoiceOver's sequential focus
                // order skips the title and subtitle, making the safety label below
                // the first announced element per spec §3.5 / palette §5.1 point 2.
                // Sighted users see the text normally. (QA finding #1.)
                Text(blockHeaderTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                // "between <from> and <to>"
                Text(blockHeaderSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            // ✕ close button (44pt tap target per HIG)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close block details")
        }
    }

    // MARK: - Safety label

    private var safetyLabelView: some View {
        let label = engine.safetyLabel(for: segment, at: now)
        return Text(label.text)
            .font(.title.bold())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            // This is the first focusable accessibility element in the sheet
            // per spec §3.5 and palette doc §5.1. The band above is hidden.
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Rules list

    private var rulesSection: some View {
        let sortedRules = segment.rules.sorted { lhs, rhs in
            lhs.category.priority < rhs.category.priority
        }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sortedRules.enumerated()), id: \.offset) { _, rule in
                RuleRow(rule: rule)
            }
        }
    }

    // MARK: - S13b: Swept badge

    /// "🧹 Swept X ago · N confirms" — identical copy/decision-logic to
    /// `ParkedCarDetailView.sweptBadgeView(for:)` (S10). Only the color literal + `Text`
    /// composition are duplicated here (see this file's header note on why that duplication,
    /// not a shared type, is this codebase's established convention).
    private static let sweptBadgeColor = Color(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)

    private func sweptBadgeView(for pin: CommunityPin) -> some View {
        let age = PinMarkerAnnotation.ageString(since: pin.createdAt, now: pinService?.nowProvider() ?? now)
        let confirms = ParkedCarDetailLogic.confirmCountLabel(pin.confirmCount)
        return Text("🧹 Swept \(age) \u{00B7} \(confirms)")
            .font(.caption.weight(.bold))
            .foregroundStyle(Self.sweptBadgeColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Self.sweptBadgeColor.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.sweptBadgeColor.opacity(0.35), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sweeper reported \(age), confirmed by \(pin.confirmCount) neighbors")
    }

    // MARK: - S13b: "LIVE ON THIS BLOCK"

    /// Renders nothing when there's nothing to show — matches the prototype's own `bHasReports`
    /// gate (`design/prototype.html:246`: the section header itself is omitted, not shown
    /// empty, when zero pins match this block).
    @ViewBuilder
    private var liveOnThisBlockSection: some View {
        if AppConstants.communityEnabled, let pinService, let authService, !liveBlockPins.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE ON THIS BLOCK")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                ForEach(liveBlockPins) { pin in
                    PinFeedRow(pin: pin, authService: authService, pinService: pinService)
                    Divider()
                }
            }
        }
    }

    // MARK: - S13b: "BLOCK CHATTER"

    @ViewBuilder
    private var blockChatterSection: some View {
        if AppConstants.communityEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("BLOCK CHATTER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                if isLoadingChat && chatMessages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else if BlockDetailLogic.showsEmptyChatterState(messages: chatMessages, isLoading: isLoadingChat) {
                    emptyChatterView
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(chatMessages) { message in
                            BlockChatRow(message: message)
                        }
                    }
                }

                chatComposeRow

                if let chatSendError {
                    Text(chatSendError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .task { await loadChat() }
        }
    }

    /// Copy VERBATIM, `design/prototype.html:881`.
    private var emptyChatterView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No chatter yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Be the first \u{2014} crews form block by block.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var chatComposeRow: some View {
        HStack(spacing: 8) {
            TextField("Message this block…", text: $chatDraft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.systemGray6), in: Capsule())
                .accessibilityLabel("Message this block")

            Button {
                submitChat()
            } label: {
                if isSendingChat {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.accentColor, in: Circle())
            .foregroundStyle(.white)
            .disabled(isSendingChat || !ZoneMessageComposeLogic.canSend(draft: chatDraft) || zoneMessageService == nil)
            .accessibilityLabel("Send message")
        }
    }

    // MARK: - S13b: BLOCK CHATTER — network calls

    private func loadChat() async {
        guard AppConstants.communityEnabled, let zoneMessageService else { return }
        isLoadingChat = true
        if let fetched = try? await zoneMessageService.fetchMessages(segmentId: segment.id) {
            chatMessages = fetched
        }
        isLoadingChat = false
    }

    private var identitySheetPresented: Binding<Bool> {
        Binding(
            get: { pendingIdentityAction != nil },
            set: { isPresented in
                if !isPresented { pendingIdentityAction = nil }
            }
        )
    }

    /// Entry point for "Message this block…"'s send button — routes through the SAME identity
    /// gate every other contribution path uses (`ReportSheet.submitReport()`,
    /// `ParkedCarDetailView.submitLeavingSoon()`, `CrewFeedSection.submitCrewMessage()`).
    private func submitChat() {
        let trimmed = ZoneMessageComposeLogic.trimmedBody(chatDraft)
        guard !trimmed.isEmpty else { return }
        if BlockDetailLogic.shouldGateChatSend(identityGateShouldShow: CommunityIdentityGate().shouldShow()) {
            pendingIdentityAction = { Task { await performSendChat(trimmed) } }
            return
        }
        Task { await performSendChat(trimmed) }
    }

    /// The actual network write — split out of `submitChat()` so the identity gate can defer
    /// it, matching `ReportSheet.performSubmit(type:)`'s / `ParkedCarDetailView
    /// .performPostLeavingSoon()`'s own split.
    private func performSendChat(_ body: String) async {
        guard let zoneMessageService else { return }
        chatSendError = nil
        guard let zoneId = BlockDetailLogic.resolvedZoneId(forSegmentMidpoint: segment.midpoint) else {
            // zone_messages.zone_id is NOT NULL (01-mvp-schema.sql:74) — a block outside all
            // three known zone boxes genuinely cannot post a message today. Surfaced as an
            // honest, block-specific error rather than attempting an insert that would 23502
            // server-side.
            chatSendError = "Can't post here yet \u{2014} this block is outside a supported neighborhood."
            return
        }
        isSendingChat = true
        do {
            let sent = try await zoneMessageService.sendMessage(zoneId: zoneId, segmentId: segment.id, body: body)
            chatMessages.append(sent)
            chatDraft = ""
        } catch {
            chatSendError = "Couldn't send. Check your connection and try again."
        }
        isSendingChat = false
    }

    // MARK: - Park here button (W5: live when onParkHere is non-nil)

    private var parkHereStub: some View {
        VStack(spacing: 4) {
            Button {
                onParkHere?()
            } label: {
                Text("Park here \u{2192}")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(onParkHere == nil)
            .accessibilityLabel(
                onParkHere == nil
                    ? "Park here. Coming in next update."
                    : "Park here. Confirm your parking spot."
            )
            .accessibilityHint(onParkHere == nil ? "Disabled." : "")

            if onParkHere == nil {
                Text("Coming next")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Block header helpers (view-file only, not engine domain)

    /// "<StreetName> — <SideLabel>"
    private var blockHeaderTitle: String {
        let street = StreetNameNormalizer.canonical(segment.street)
        let side = sideLabel(segment.side)
        return "\(street) \u{2014} \(side)"
    }

    /// "between <from> and <to>"
    private var blockHeaderSubtitle: String {
        let from = StreetNameNormalizer.canonical(segment.fromStreet)
        let to   = StreetNameNormalizer.canonical(segment.to)
        return "between \(from) and \(to)"
    }

    /// Converts a single-letter side code to a sentence-cased label.
    ///   "N" → "North side", "S" → "South side", "E" → "East side", "W" → "West side"
    /// Any other value falls back to "<X> side".
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

// MARK: - RuleRow

/// Shared rule-row component used by BlockDetailView and ParkedCarDetailView.
/// Internal (not private) so both views in the same module can access it.
///
/// W7 (§3.D): Tap-to-expand. `isExpanded` starts false. Tapping the row toggles
/// `.lineLimit(1)` ↔ `.lineLimit(nil)`. Badge moves below the text when expanded.
/// Animation: `.easeInOut(duration: 0.18)`.
struct RuleRow: View {

    let rule: ParkingRule

    /// W7: Expansion state — starts collapsed.
    @State private var isExpanded: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            ruleRowContent
        }
        .buttonStyle(.plain)
        // Each rule row is one accessibility announcement.
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Tap to collapse." : "Tap to expand full sign text.")
    }

    @ViewBuilder
    private var ruleRowContent: some View {
        if isExpanded {
            // Expanded: text flows freely; badge below the text for long content.
            VStack(alignment: .leading, spacing: 6) {
                Text(rowText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                HStack {
                    Spacer()
                    badgeView
                }
            }
        } else {
            // Collapsed: single truncated line with badge trailing.
            HStack(alignment: .center, spacing: 8) {
                Text(rowText)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                Spacer()

                badgeView
            }
        }
    }

    private var badgeView: some View {
        Text(rule.category.label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(categoryBadgeColor.opacity(0.18))
            )
            .foregroundStyle(categoryBadgeColor)
    }

    // MARK: - Row text

    private var rowText: String {
        // If the rule has a non-empty description, use it.
        let desc = rule.description.trimmingCharacters(in: .whitespaces)
        if !desc.isEmpty {
            return desc
        }

        // Fall back to a generated string: "<days> <timeRange> · <category-label>"
        if rule.anytime {
            return "Anytime \u{00B7} \(rule.category.label)"
        }

        let daysStr = compactDaysString(rule.days)
        let timeStr = compactTimeRange(rule.timeRanges)

        if daysStr.isEmpty && timeStr.isEmpty {
            return rule.category.label
        }
        if timeStr.isEmpty {
            return "\(daysStr) \u{00B7} \(rule.category.label)"
        }
        if daysStr.isEmpty {
            return "\(timeStr) \u{00B7} \(rule.category.label)"
        }
        return "\(daysStr) \(timeStr) \u{00B7} \(rule.category.label)"
    }

    // MARK: - Days helper

    /// Converts [Int] day-of-week array (0=Sun…6=Sat) to a compact range string.
    ///   [1,2,3,4]   → "Mon-Thu"
    ///   [2,5]       → "Tue,Fri"
    ///   [1,2,3,4,5] → "Mon-Fri"
    ///   [0,6]       → "Sun,Sat"
    ///   []          → ""
    private func compactDaysString(_ days: [Int]) -> String {
        guard !days.isEmpty else { return "" }

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        // Sort and deduplicate, keeping valid day indices.
        let sorted = Array(Set(days.filter { $0 >= 0 && $0 <= 6 })).sorted()
        guard !sorted.isEmpty else { return "" }

        // Build consecutive range groups.
        var groups: [[Int]] = []
        var current: [Int] = [sorted[0]]

        for i in 1..<sorted.count {
            if sorted[i] == sorted[i - 1] + 1 {
                current.append(sorted[i])
            } else {
                groups.append(current)
                current = [sorted[i]]
            }
        }
        groups.append(current)

        // Format each group: single day → "Mon"; two or more consecutive → "Mon-Thu".
        let parts = groups.map { group -> String in
            if group.count == 1 {
                return dayNames[group[0]]
            } else {
                return "\(dayNames[group[0]])-\(dayNames[group[group.count - 1]])"
            }
        }

        return parts.joined(separator: ",")
    }

    // MARK: - Time range helper

    /// Formats an array of TimeRanges as "7am-9:30am" or "7am-9:30am, 11pm-1am".
    /// Uses the same lowercase am/pm, no-space, omit-:00 format as the engine's formatMinutes.
    private func compactTimeRange(_ ranges: [TimeRange]) -> String {
        guard !ranges.isEmpty else { return "" }
        return ranges.map { tr in
            "\(formatMinutes(tr.start))-\(formatMinutes(tr.end))"
        }.joined(separator: ", ")
    }

    /// Formats a minute-of-day value as "7am", "9:30am", "7pm".
    /// Same format as ParkingRulesEngine.formatMinutes (view-file copy per spec §3.3).
    /// Do not remove this in favor of calling the private engine method — it's intentionally
    /// duplicated in the view layer so formatting stays consistent without a public engine API change.
    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        let ampm = h >= 12 ? "pm" : "am"
        let h12 = ((h + 11) % 12) + 1
        if m > 0 {
            return "\(h12):\(String(format: "%02d", m))\(ampm)"
        } else {
            return "\(h12)\(ampm)"
        }
    }

    // MARK: - Badge color

    /// Returns a SwiftUI color representing the category's severity for the badge.
    /// Uses the same semantic mapping as the state colors but keyed on static category,
    /// since the badge is a category label (not a live-state indicator).
    private var categoryBadgeColor: Color {
        switch rule.category {
        case .noStanding, .noParking, .special:
            return .red
        case .truckLoading:
            return .orange
        case .metered:
            return Color(red: 0.92, green: 0.76, blue: 0.0)
        case .aspMonThu, .aspTueFri, .aspOvernightMWF, .aspOvernightTTHS, .aspDaily:
            return .orange
        case .free:
            return .green
        case .unknown:
            return .gray
        }
    }
}

// MARK: - BlockChatRow (S13b)

/// One "BLOCK CHATTER" row: author, relative age, and message text
/// (`design/prototype.html:262-270`'s shape). A separate, compact view rather than reusing
/// `CrewFeedSection.ChatFeedRow` directly — that type is `private` to `CrewFeedSection.swift`
/// and laid out for the zone-wide feed's dense list (fixed 36×36 icon circle, confirm-badge
/// column), not this section's simpler author/age/text row (matches
/// `CrewFeedSection.PinFeedRow`'s own doc comment on why a shaped-differently row is a
/// separate type, not a shared one, in this codebase).
private struct BlockChatRow: View {
    let message: ZoneMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(message.authorUsername ?? "Neighbor")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\u{00B7} \(PinMarkerAnnotation.ageString(since: message.createdAt, now: .now))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - BlockDetailLogic (S13b): pure, testable decision logic

/// Pure decision/formatting logic extracted from `BlockDetailView` so it's unit-testable
/// without SwiftUI/view-lifecycle machinery — same house style as
/// `ParkedCarDetailLogic`/`CrewFeedMerge`.
enum BlockDetailLogic {

    /// Ephemeral/crowd pins anchored to THIS block, via `segment_id == segment.id` — the raw
    /// tile-segment id `ReportSheet`'s crowd-report write path stamps
    /// (`Views/ReportSheet.swift`'s `segmentId: effectiveSegment?.id` call site;
    /// `Views/CrewFeedSection.swift`'s header note on this being a DIFFERENT id shape than the
    /// 4-part `STREET|LO|HI|SIDE` `blockfaceKey` format `blockScopedRestriction(forBlockfaceKey:)`
    /// matches against). Because the two id shapes never collide, a block-scoped
    /// filming/construction restriction (already surfaced separately via
    /// `TemporaryRestrictionBanner`) can never double-appear in this list — verified by
    /// construction, not by an explicit exclusion filter.
    ///
    /// `nil`/empty whenever `communityEnabled` is `false` (flag-off parity — this section never
    /// renders regardless of what's in `pins`).
    nonisolated static func liveBlockPins(
        in pins: [CommunityPin],
        segmentId: String,
        communityEnabled: Bool
    ) -> [CommunityPin] {
        guard communityEnabled else { return [] }
        return pins
            .filter { $0.segmentId == segmentId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Resolves the `zone_id` a segment-anchored chat message must carry.
    /// `zone_messages.zone_id` is `not null` (`supabase/01-mvp-schema.sql:74`), so a block
    /// outside all three known `CommunityZoneBounds` boxes genuinely cannot post a message —
    /// the caller must show an error rather than attempt an insert that would 23502
    /// (not-null violation) server-side.
    nonisolated static func resolvedZoneId(forSegmentMidpoint midpoint: CLLocationCoordinate2D?) -> String? {
        guard let midpoint else { return nil }
        return CommunityZoneBounds.zoneId(forLat: midpoint.latitude, lng: midpoint.longitude)
    }

    /// Whether the identity sheet must be shown before the block-chat send proceeds — routes
    /// through the SAME shared gate every other contribution path uses
    /// (`ReportSheet.submitReport()`, `ParkedCarDetailView.shouldGateLeavingSoonPost`,
    /// `CrewFeedSection.submitCrewMessage()`), not a parallel one-off check. `communityEnabled`
    /// defaults to the real flag (mirrors `ParkedCarDetailLogic.shouldGateLeavingSoonPost`'s
    /// own testability convention); tests pass both `true`/`false` explicitly.
    nonisolated static func shouldGateChatSend(
        communityEnabled: Bool = AppConstants.communityEnabled,
        identityGateShouldShow: Bool
    ) -> Bool {
        CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: communityEnabled,
            identitySheetShouldShow: identityGateShouldShow
        )
    }

    /// AC-parity with `CrewFeedMerge.showsEmptyState`: an intentional empty state only when
    /// there is genuinely nothing to show AND no fetch is in flight — never a blank section
    /// mid-load.
    nonisolated static func showsEmptyChatterState(messages: [ZoneMessage], isLoading: Bool) -> Bool {
        messages.isEmpty && !isLoading
    }
}

// MARK: - TemporaryRestrictionBanner (FT-15 / TF2-15 §9.2)

/// "Temporary restriction reported" banner shown in `BlockDetailView` and
/// `ParkedCarDetailView` when the viewed segment's `blockfaceKey` matches an active or
/// upcoming crowd-reported block-scoped restriction (filming or construction, §9.3's
/// shared primitive).
///
/// Shared between both views the same way `RuleRow` is (internal, not private, so both
/// view files in this module can use it) — the highest-value consumption point per §9.2
/// is telling someone whose car is *already parked on* an affected block, which is exactly
/// what `ParkedCarDetailView` needs this for.
///
/// Tapping opens `PinDetailSheet` for full detail + confirm/dispute — reuses the existing
/// `ReactionsRow` pattern (AC-C4's widened gate), no new voting UI (§9.2).
struct TemporaryRestrictionBanner: View {

    let pin: CommunityPin

    /// Reference time for the Upcoming/Active badge (AC-C2). Defaults to `Date()` for
    /// previews/standalone use; callers with a `CommunityPinService` in scope should pass
    /// `pinService.nowProvider()` so this stays deterministic under test injection rather
    /// than reading the wall clock directly (QA nit #6,
    /// docs/qa/ft15-b4-fetch-channel-qa.md — `isUpcoming` display sites were the one
    /// asymmetric spot in this feature that didn't thread the service's injectable time).
    /// Declared before `onTap` so trailing-closure call syntax keeps binding to `onTap`.
    var now: Date = Date()

    let onTap: () -> Void

    private var isUpcoming: Bool { pin.isUpcoming(now: now) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(iconColor)
                        .frame(width: 30, height: 30)
                    Image(systemName: iconSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(typeLabel)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        statusBadge
                    }
                    Text("Temporary restriction reported \u{00B7} \(windowText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(typeLabel) reported, \(isUpcoming ? "upcoming" : "active"). \(windowText). Tap for details."
        )
    }

    // MARK: - Style helpers

    private var typeLabel: String {
        switch pin.pinType {
        case .construction: return "Construction"
        default:             return "Film shoot"  // .filming is the only other block-scoped type today (§9.3)
        }
    }

    private var iconSymbol: String {
        pin.pinType == .construction ? "hammer.fill" : "video.fill"
    }

    private var iconColor: Color {
        pin.pinType == .construction
            ? ParkingColors.constructionOrange
            : .purple
    }

    private var statusBadge: some View {
        Text(isUpcoming ? "Upcoming" : "Active")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isUpcoming ? Color.blue : Color.green).opacity(0.18), in: Capsule())
            .foregroundStyle(isUpcoming ? .blue : .green)
    }

    /// "<start> – <end>" — same format as `PinDetailSheet.windowSummary`, duplicated here
    /// per this file's own established convention of view-file-local formatting helpers
    /// (see `RuleRow.formatMinutes`'s doc comment on why duplication is intentional).
    private var windowText: String {
        let startText = pin.startsAt.map(Self.dateFormatter.string(from:)) ?? "now"
        guard let expiresAt = pin.expiresAt else {
            return "Starts \(startText), no end date set"
        }
        return "\(startText) \u{2013} \(Self.dateFormatter.string(from: expiresAt))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = .easternTime
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()
}

// MARK: - Preview

#Preview {
    // Sample segment for preview — uses a NO_STANDING anytime rule.
    let rule = ParkingRule(
        category: .noStanding,
        description: "NO STANDING ANYTIME",
        days: [0, 1, 2, 3, 4, 5, 6],
        timeRanges: [],
        anytime: true,
        arrow: "both"
    )
    let engine = ParkingRulesEngine()

    // Build a minimal segment via JSON round-trip (mirrors the test helper pattern).
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
        "dominantCategory": "NO_STANDING"
    ]
    let segData = try! JSONSerialization.data(withJSONObject: segDict)
    let segment = try! JSONDecoder().decode(Segment.self, from: segData)

    return BlockDetailView(segment: segment, engine: engine, onDismiss: {}, onParkHere: nil)
        .presentationDetents([.medium, .large])
}
