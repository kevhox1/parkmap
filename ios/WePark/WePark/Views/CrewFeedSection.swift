//
//  CrewFeedSection.swift
//  WePark
//
//  Community 2.0 Phase 1 (S4) — the crew feed: zone chips + a merged, newest-first list of
//  `ZoneMessageService` chat messages and `CommunityPinService` crowd pins, scoped to one
//  selected zone at a time.
//  Spec: docs/community-2.0-reconciliation-spec.md §1 delta table ("Crew feed"), §2.3
//  (zones), §3 Phase 1, §6 (verbatim design values). Visual reference:
//  design/prototype.html:842-859 (feed construction), :931 (zone chips), :834 (sheet model),
//  design/screenshots/04-feed-half.png / 05-feed-full.png / 06-feed-away-zone.png.
//
//  Mounted ONLY inside `BrowseNavigationSheet`'s `.large`-detent `crewFeed` slot, and only
//  when `AppConstants.communityEnabled == true` (`ContentView.browseNavigationSheetContent`) —
//  with the flag `false` (today's shipped default) this file is never instantiated at all.
//
//  What lives here:
//   - `CommunityZone` — the three Community 2.0 zones (spec §2.3's seeded rows), a thin
//     Swift-side mirror of `public.zones` ids/names. NOT a general zone model — Phase 1 has
//     exactly three zones and no "all zones" view (spec §1 delta table).
//   - `CrewFeedItem` — a chat message or a pin, unified into one `Identifiable`, timestamped
//     type so the two can be sorted into a single newest-first list.
//   - `CrewFeedMerge` — pure, view-free merge/format/empty-state logic (mirrors this
//     codebase's `RealtimeMergeGate`/`BrowseSheetDetentMath` house style of separating
//     testable decision logic from the view that consumes it). Directly unit-testable
//     without hosting any SwiftUI view.
//   - `CrewFeedSection` — the view: zone chips, zone header, and the merged feed list (or an
//     intentional "no reports yet" empty state — AC-P1.2/AC-P1.4, never a blank list).
//
//  Known, explicitly-flagged simplifications (see PR body for the full list):
//   - Row `sub` text includes "btwn X & Y" only when `pin.segmentId` is the 4-part
//     `STREET|LO|HI|SIDE` blockface-key shape (`Segment.blockfaceKey`'s format, also what
//     Community 2.0 Phase 0's own test fixtures use). Ephemeral crowd pins whose
//     `segmentId` is a raw tile-segment id (a different shape — see
//     `Views/ReportSheet.swift`'s `segment?.id` call site) degrade gracefully to
//     "age · author" with no cross-street clause, rather than mis-parsing the raw id or
//     plumbing a `[Segment]` lookup into this file (would require passing `tileLoader` into
//     `ContentView`'s crew-feed wiring — deferred to keep that file's diff minimal per this
//     session's explicit dispatch constraint).
//   - `open_spot`/`leaving_soon` map-marker PLACEMENT needs no new code at all:
//     `CommunityPinAnnotation.coordinate` (`Views/PinMarkerAnnotation.swift`) already renders
//     directly from `pin.lat`/`pin.lng` for every pin type — there is no existing
//     segment-midpoint-derivation code path on iOS for `positionFraction` to slot into (that
//     concept is unique to the web prototype's synthetic SVG grid, which draws pins along an
//     abstract line rather than real coordinates). `positionFraction` is decoded (S3) and
//     available for a future display-only use, but the map already places these pins at
//     their true reported location with zero placement code in this PR.
//   - "I'm heading there" (leaving_soon claim) is an explicit, disabled stub — `claim_pin`
//     wiring is out of this session's read-only scope (dispatch instruction: "Phase 3 wires
//     claim_pin").
//

import SwiftUI

// MARK: - CommunityZone

/// Community 2.0's three seeded zones (spec §2.3). Raw values are the exact
/// `public.zones.id` strings — passed straight through to `CommunityPinService.setSelectedZone`
/// / `ZoneMessageService.setSelectedZone` / `RealtimeMergeGate.isInZone` without any further
/// translation.
///
/// Deliberately NOT `CaseIterable`-driven from a server fetch — Phase 1 has exactly three
/// fixed zones (spec §1 delta table: "one row exists today... insert three new rows"), and
/// there is no "all zones" view to enumerate beyond these three.
enum CommunityZone: String, CaseIterable, Identifiable {
    case nolita
    case soho
    case les

    var id: String { rawValue }

    /// Display name for the zone chip and the crew-feed header. Matches
    /// `prototype.html:931`'s chip labels and `01-mvp-schema.sql`/§2.3's seeded `name` column
    /// verbatim.
    var displayName: String {
        switch self {
        case .nolita: return "Nolita"
        case .soho:   return "SoHo"
        case .les:    return "LES"
        }
    }
}

// MARK: - CrewFeedItem

/// One row in the merged crew feed — either a zone-chat message or a crowd-reported pin.
/// `Identifiable`/timestamped so `CrewFeedMerge.merge(...)` can interleave the two sources
/// into one newest-first list.
enum CrewFeedItem: Identifiable {
    case chat(ZoneMessage)
    case pin(CommunityPin)

    var id: String {
        switch self {
        case .chat(let message): return "chat-\(message.id)"
        case .pin(let pin):      return "pin-\(pin.id.uuidString)"
        }
    }

    var timestamp: Date {
        switch self {
        case .chat(let message): return message.createdAt
        case .pin(let pin):      return pin.createdAt
        }
    }
}

// MARK: - CommunityZoneBounds (S4 QA pass 1, PR #94 Finding #3 — significant, fixed)

/// Client-side bounding-box fallback for pins whose `zone_id` column is `nil` — every
/// current write path (`Views/ReportSheet.swift:541`'s `zoneId: nil`) never stamps a zone
/// on insert, so a strict `pin.zoneId == selectedZoneId` filter (this file's original
/// behavior) shows ZERO pre-existing `enforcement_active`/`sweeper_passed` reports in any
/// zone, ever — not "fewer than a moved map would produce" (the already-documented
/// AC-P1.2 limitation), but none at all. This is the same box-not-polygon approximation
/// OQ-1 already chose for the zones themselves — matched here client-side rather than
/// waiting on a Phase 2 zone-on-insert story (tracked: `docs/community-2.0-roadmap.md`
/// S6 row).
///
/// Values copied VERBATIM from `supabase/03-community-2.0-schema.sql`'s applied seed rows
/// (§2.3, including the QA-pass-1-corrected `soho` `lat_max`, 40.7237 not the stale
/// 40.7280) — if that migration is ever retuned, this table must be updated in the same
/// commit or this fallback silently drifts from the real zone boundaries.
enum CommunityZoneBounds {
    /// (zoneId, latMin, latMax, lngMin, lngMax) — order doesn't matter for lookup (the
    /// three boxes don't overlap in the applied migration), but is kept in the same
    /// nolita/soho/les order as the seed SQL for easy side-by-side comparison.
    private static let boxes: [(zoneId: String, latMin: Double, latMax: Double, lngMin: Double, lngMax: Double)] = [
        ("nolita", 40.7217, 40.7256, -73.9967, -73.9930),
        ("soho",   40.7220, 40.7237, -74.0050, -73.9970),
        ("les",    40.7145, 40.7230, -73.9920, -73.9800),
    ]

    /// Returns the zone id whose bounding box contains `(lat, lng)`, or `nil` if none does
    /// (e.g. a coordinate outside all three Phase 1 zones — the legacy `soho-les` box has
    /// no bounds recorded here since it's a retired, chat-history-only id, spec §2.3).
    static func zoneId(forLat lat: Double, lng: Double) -> String? {
        boxes.first { lat >= $0.latMin && lat <= $0.latMax && lng >= $0.lngMin && lng <= $0.lngMax }?.zoneId
    }
}

// MARK: - CrewFeedMerge (pure, view-free logic)

/// Pure decision/formatting helpers for the crew feed — no SwiftUI, no networking, no
/// mutable state. Mirrors this codebase's `RealtimeMergeGate` / `BrowseSheetDetentMath`
/// convention of keeping testable logic separate from the view that renders it.
enum CrewFeedMerge {

    // MARK: Merge + zone filter

    /// The zone a pin counts toward for feed filtering: its own `zoneId` if set, else a
    /// `CommunityZoneBounds` lookup by `(lat, lng)` (S4 QA pass 1 Finding #3 fix). `nil` if
    /// neither resolves (a pin with no `zoneId` outside all three known boxes).
    static func resolvedZoneId(for pin: CommunityPin) -> String? {
        pin.zoneId ?? CommunityZoneBounds.zoneId(forLat: pin.lat, lng: pin.lng)
    }

    /// Combines `messages` and `pins` into one newest-first `[CrewFeedItem]`, filtering both
    /// to `zoneId`.
    ///
    /// `messages` is expected to already be scoped to one zone by
    /// `ZoneMessageService.fetchMessages(zoneId:)` (it fetches one zone at a time) — the
    /// filter here is applied anyway so this function's output is correct regardless of what
    /// the caller passes in, and so it stays independently testable with mixed-zone fixtures.
    /// `pins` (`CommunityPinService.visiblePins`) is NEVER zone-scoped on the read path
    /// (viewport-scoped only — spec §1 delta table) — filtering it by `zoneId` here is load-
    /// bearing, not defensive. Pins filter through `resolvedZoneId(for:)` (bounding-box
    /// fallback for a `nil` `zone_id`), not raw `pin.zoneId`, so pre-existing
    /// enforcement/sweeper reports (which no write path stamps with a zone yet) still
    /// surface in the correct zone's feed.
    static func merge(messages: [ZoneMessage], pins: [CommunityPin], zoneId: String) -> [CrewFeedItem] {
        let chatItems = messages
            .filter { $0.zoneId == zoneId }
            .map(CrewFeedItem.chat)
        let pinItems = pins
            .filter { resolvedZoneId(for: $0) == zoneId }
            .map(CrewFeedItem.pin)
        return (chatItems + pinItems).sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: Empty state

    /// AC-P1.2 / AC-P1.4: the feed shows an intentional empty state when there is genuinely
    /// nothing to show — NOT while a fetch is still in flight (that's a loading state, a
    /// different thing) and not just because `feed` happens to be momentarily empty mid-fetch.
    static func showsEmptyState(feed: [CrewFeedItem], isLoadingMessages: Bool) -> Bool {
        feed.isEmpty && !isLoadingMessages
    }

    // MARK: Row content — pins

    /// "btwn X & Y" cross-streets, parsed ONLY from the 4-part `STREET|LO|HI|SIDE`
    /// blockface-key shape (`Segment.blockfaceKey`'s format). Returns `nil` for any other
    /// shape (e.g. a raw tile `segment.id`) rather than guessing — see this file's header
    /// comment for why that's a deliberate, flagged simplification in this session.
    static func crossStreets(for pin: CommunityPin) -> (from: String, to: String)? {
        guard let segmentId = pin.segmentId else { return nil }
        let parts = segmentId.components(separatedBy: "|")
        guard parts.count == 4 else { return nil }
        return (StreetNameNormalizer.canonical(parts[1]), StreetNameNormalizer.canonical(parts[2]))
    }

    /// Row title: "<type label> — <street>" when a street name can be resolved, else just
    /// the type label. Mirrors `prototype.html:850`'s `meta.label + ' — ' + street` shape.
    static func title(for pin: CommunityPin) -> String {
        guard let segmentId = pin.segmentId else { return pin.pinType.displayLabel }
        let parts = segmentId.components(separatedBy: "|")
        guard parts.count == 4 else { return pin.pinType.displayLabel }
        return "\(pin.pinType.displayLabel) — \(StreetNameNormalizer.canonical(parts[0]))"
    }

    /// Row sub-line: "btwn X & Y · <age> · <author>" when cross-streets resolve, else
    /// "<age> · <author>" (see `crossStreets(for:)`'s doc comment). Age uses
    /// `PinMarkerAnnotation.ageString(since:now:)` — spec §0 OQ-2's "every surface shows
    /// relative age" rule, same wording as the map marker's own callout badge.
    static func subLine(for pin: CommunityPin, now: Date) -> String {
        let age = PinMarkerAnnotation.ageString(since: pin.createdAt, now: now)
        let author = pin.authorUsername ?? "Neighbor"
        if let cross = crossStreets(for: pin) {
            return "btwn \(cross.from) & \(cross.to) · \(age) · \(author)"
        }
        return "\(age) · \(author)"
    }

    /// Confirm-count badge, e.g. "✓ 2". `nil` when there are no confirms yet — the row
    /// simply omits the badge (matches `prototype.html:852`'s `r.conf > 0 ? ... : null`).
    static func confirmBadge(for pin: CommunityPin) -> String? {
        pin.confirmCount > 0 ? "✓ \(pin.confirmCount)" : nil
    }

    /// Icon + ring color for a pin type, per spec §6 appendix (verbatim design values) —
    /// DELIBERATELY separate from `PinMarkerAnnotation.markerStyle(for:)`'s SF-Symbol/system-
    /// color map used for the actual map markers (that file's existing tier3-marker-icons.md
    /// convention). The feed matches the prototype's own icon/color choices exactly, per this
    /// session's explicit scope; the map marker's icon choice is a separate, already-shipped
    /// design decision this PR does not touch (except for `.openSpot`/`.leavingSoon`, whose
    /// map glyphs — "P" / 🚙 — happen to already match this table, per spec §6's own row for
    /// those two types).
    static func icon(for pinType: PinType) -> (glyph: String, color: Color) {
        switch pinType {
        case .enforcementActive: return ("🎫", Self.color(hex: 0xFF9F0A))
        case .sweeperPassed:     return ("🧹", Self.color(hex: 0x30D158))
        case .openSpot:          return ("P",  Self.color(hex: 0x0A84FF))
        case .leavingSoon:       return ("🚙", Self.color(hex: 0x0A84FF))
        case .construction:      return ("🚧", Self.color(hex: 0xE8730D))
        case .filming:           return ("🎬", Self.color(hex: 0xE8730D))
        case .blockNote:         return ("📌", Self.color(hex: 0x9BA1AF))
        // Every other type is not expected to appear in the crew feed (not a crowd/ephemeral
        // or block-scoped closure type) — a neutral fallback keeps this switch exhaustive-safe
        // without ever failing to render a row.
        default:                 return ("📍", Color(.systemGray))
        }
    }

    /// Fixed chat-row ring color — `prototype.html:844`'s `'#3E4450'`, not itself part of
    /// spec §6's pin-type table (chat messages aren't a pin type) but taken verbatim from the
    /// same source file for visual consistency with the feed's pin rows.
    static let chatRingColor = Self.color(hex: 0x3E4450)

    /// Chat-row sub-line: "<author> · <age>" — matches `prototype.html:844`'s
    /// `a[0] + ' · ' + ago(atMin)` shape (its own cross-street clause is display-only demo
    /// data this file has no equivalent source for, since `ZoneMessage` carries a nullable
    /// `segmentId` with no guaranteed blockface-key shape — same reasoning as the pin-row
    /// simplification above).
    static func subLine(for message: ZoneMessage, now: Date) -> String {
        let age = PinMarkerAnnotation.ageString(since: message.createdAt, now: now)
        let author = message.authorUsername ?? "Neighbor"
        return "\(author) · \(age)"
    }

    /// Distinct author count across the currently-loaded messages + pins for a zone — a real
    /// (not fabricated) signal for the crew-feed header's parker-count placeholder. Not the
    /// same thing as "how many cars are parked in this zone right now" (no such data exists
    /// yet), but genuinely derived from live contributions rather than a hardcoded demo
    /// number like the prototype's `crewParkers`.
    static func distinctContributorCount(messages: [ZoneMessage], pins: [CommunityPin]) -> Int {
        var ids = Set<UUID>()
        for message in messages {
            if let authorId = message.authorId { ids.insert(authorId) }
        }
        for pin in pins {
            if let authorId = pin.authorId { ids.insert(authorId) }
        }
        return ids.count
    }

    // MARK: - Color helper

    /// Builds a `Color` from a `0xRRGGBB` literal — this file's only consumer of arbitrary
    /// hex design values (spec §6's table); no shared `Color(hex:)` extension exists
    /// elsewhere in the codebase, so this stays `fileprivate`-scoped rather than adding new
    /// shared API surface for a single call site's worth of need.
    fileprivate static func color(hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - CrewFeedSection

/// The crew feed's top-level view: zone chips, zone header, and the merged feed (or its
/// empty state). Mounted only at `BrowseNavigationSheet`'s `.large` detent — see this file's
/// header comment.
struct CrewFeedSection: View {

    var pinService: CommunityPinService
    var zoneMessageService: ZoneMessageService
    var authService: SupabaseAuthService

    @State private var selectedZone: CommunityZone = .nolita

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneChipsRow
            zoneHeaderRow

            Divider()

            feedContent
        }
        .padding(.top, 6)
        .onAppear { selectZone(selectedZone) }
        .onChange(of: selectedZone) { _, newZone in selectZone(newZone) }
    }

    // MARK: - Zone selection

    /// Drives both services' zone filter (spec: zone chips "driving
    /// `CommunityPinService.setSelectedZone` + `ZoneMessageService`'s zone param"). Does NOT
    /// move the map or re-fetch pins by bounding box — `CommunityPinService`'s channels stay
    /// viewport-scoped on the read path (its own `setSelectedZone(_:)` doc comment); the
    /// crew feed's pin half is therefore limited to whatever crowd pins are already in
    /// `visiblePins` for the CURRENT map viewport, filtered further to this zone. A zone far
    /// from where the map is currently centered can show fewer/no pins even if real reports
    /// exist there — this degrades to the empty state (never a broken/blank one), not a
    /// crash, and is flagged in the PR body as a partial completion of AC-P1.2's "map's
    /// crowd-pin fetch bounding filter" clause (explicitly out of this session's stated
    /// scope: "Zone chips: ... driving `CommunityPinService.setSelectedZone` +
    /// `ZoneMessageService`'s zone param" — no map-region change is in that list).
    private func selectZone(_ zone: CommunityZone) {
        pinService.setSelectedZone(zone.id)
        zoneMessageService.setSelectedZone(zone.id)
    }

    // MARK: - Zone chips

    private var zoneChipsRow: some View {
        HStack(spacing: 7) {
            ForEach(CommunityZone.allCases) { zone in
                zoneChip(zone)
            }
        }
        .padding(.horizontal, 2)
    }

    private func zoneChip(_ zone: CommunityZone) -> some View {
        let isSelected = zone == selectedZone
        return Button {
            selectedZone = zone
        } label: {
            Text(zone.displayName)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(isSelected ? Color.blue : Color(white: 0.46).opacity(0.16))
        )
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .accessibilityLabel("\(zone.displayName) zone")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Zone header

    private var zoneHeaderRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selectedZone.displayName.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(contributorCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var contributorCountLabel: String {
        let count = CrewFeedMerge.distinctContributorCount(
            messages: zoneMessageService.messages,
            pins: pinService.visiblePins
        )
        return count == 1 ? "1 neighbor posting" : "\(count) neighbors posting"
    }

    // MARK: - Feed content

    @ViewBuilder
    private var feedContent: some View {
        let feed = CrewFeedMerge.merge(
            messages: zoneMessageService.messages,
            pins: pinService.visiblePins,
            zoneId: selectedZone.id
        )

        if zoneMessageService.isLoading && feed.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else if CrewFeedMerge.showsEmptyState(feed: feed, isLoadingMessages: zoneMessageService.isLoading) {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feed) { item in
                        feedRow(for: item)
                        Divider()
                    }
                }
            }
        }
    }

    /// AC-P1.2 / AC-P1.4: intentional empty state, never a blank list. Copy per this
    /// session's dispatch instruction ("no reports yet — crews form block by block"),
    /// echoing `prototype.html:881`'s block-detail chat empty state's spirit for the
    /// zone-level feed.
    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("No reports yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Crews form block by block — be the first to post here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func feedRow(for item: CrewFeedItem) -> some View {
        switch item {
        case .chat(let message):
            ChatFeedRow(message: message)
        case .pin(let pin):
            PinFeedRow(pin: pin, authService: authService, pinService: pinService)
        }
    }
}

// MARK: - ChatFeedRow

/// One zone-chat row: a generic chat glyph (identity/avatars are Phase 2, `IdentitySheet`),
/// the message body, and "<author> · <age>".
private struct ChatFeedRow: View {
    let message: ZoneMessage

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle()
                    .strokeBorder(CrewFeedMerge.chatRingColor, lineWidth: 2)
                    .background(Circle().fill(Color(white: 0.14)))
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(CrewFeedMerge.chatRingColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.body)
                    .font(.subheadline.weight(.medium))
                Text(CrewFeedMerge.subLine(for: message, now: .now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - PinFeedRow

/// One pin row: icon + ring color, title, sub-line with relative age, confirm-count badge,
/// and (for non-own ephemeral crowd pins) compact "Still there / Gone" buttons, or (for
/// `leaving_soon`) a claim affordance.
///
/// Confirm/dispute wiring reuses the EXISTING `CommunityPinService.upsertVote` /
/// `callExtendPinExpiry` calls (`Views/PinDetailSheet.swift`'s `ReactionsRow` is the
/// precedent this mirrors) — no new write path. This is a separate, compact view rather than
/// reusing `ReactionsRow` directly because that type is `private` to `PinDetailSheet.swift`
/// and shaped for a full detail-sheet layout, not a dense feed row.
private struct PinFeedRow: View {
    let pin: CommunityPin
    let authService: SupabaseAuthService
    let pinService: CommunityPinService

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            iconBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(CrewFeedMerge.title(for: pin))
                    .font(.subheadline.weight(.semibold))
                Text(CrewFeedMerge.subLine(for: pin, now: .now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if isLoading {
                    ProgressView()
                        .padding(.top, 4)
                } else {
                    actionRow
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 0)

            if let badge = CrewFeedMerge.confirmBadge(for: pin) {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(icon.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
        }
        .padding(.vertical, 11)
    }

    private var icon: (glyph: String, color: Color) {
        CrewFeedMerge.icon(for: pin.pinType)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .strokeBorder(icon.color, lineWidth: 2)
                .background(Circle().fill(Color(white: 0.14)))
            Text(icon.glyph)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(icon.color)
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Own-pin guard (mirrors `ReactionsRow.isOwnPin`)

    private var isOwnPin: Bool {
        guard let authorId = pin.authorId, let currentId = authService.currentUserId else { return false }
        return authorId == currentId
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        // `pin.showsReactionsRow` (`Views/PinMarkerAnnotation.swift`) is the SAME model-level
        // gate `PinDetailSheet` uses — reused here rather than re-derived, so the feed and the
        // detail sheet never disagree about which pins get vote buttons.
        if pin.pinType == .leavingSoon {
            leavingSoonAction
        } else if pin.showsReactionsRow && !isOwnPin {
            HStack(spacing: 7) {
                Button {
                    Task { await handleStillThere() }
                } label: {
                    Text("Still there · \(pin.confirmCount)")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .accessibilityLabel("Still there — confirm this report")

                Button {
                    Task { await handleGone() }
                } label: {
                    Text("Gone")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .accessibilityLabel("Gone — dispute this report")
            }
            .padding(.top, 4)
        }
    }

    /// `leaving_soon` special case (spec §3 Phase 3 / this session's explicit dispatch
    /// instruction): no confirm/dispute row — a claim-only affordance instead. The claim
    /// button itself is a DISABLED, explicit stub in this Phase 1 session — `claim_pin`
    /// wiring is out of read-only scope. `pin.claimedBy != nil` already reflects a real
    /// server-side claim (decoded, never client-writable — `Models/CommunityPin.swift`), so
    /// that branch is fully live even though the button that WOULD set it is not.
    @ViewBuilder
    private var leavingSoonAction: some View {
        if pin.claimedBy != nil {
            Text("Someone's heading there — first come, first served")
                .font(.caption.weight(.medium))
                .foregroundStyle(icon.color)
                .padding(.top, 4)
        } else if !isOwnPin {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    // Intentionally a no-op. TODO(Phase 3, spec §2.10/§3): wire to
                    // `CommunityPinService.claimPin(pinId:)` once that RPC call exists —
                    // read-only Phase 1 has no write path for `claim_pin`.
                } label: {
                    Text("I'm heading there")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(icon.color)
                .disabled(true)
                .accessibilityLabel("Claim this spot — coming soon")

                Text("Coming soon")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Action handlers (mirrors `ReactionsRow.handleStillHere` / `.handleGone`)

    private func handleStillThere() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.upsertVote(pinId: pin.id, vote: .confirm)
            try await pinService.callExtendPinExpiry(pinId: pin.id)
        } catch {
            errorMessage = "Couldn't confirm — try again."
        }
        isLoading = false
    }

    private func handleGone() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.upsertVote(pinId: pin.id, vote: .dispute)
        } catch {
            errorMessage = "Couldn't report — try again."
        }
        isLoading = false
    }
}
