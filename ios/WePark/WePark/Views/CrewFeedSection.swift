//
//  CrewFeedSection.swift
//  WePark
//
//  Community 2.0 Phase 1 (S4) — the crew feed: zone chips + a merged, newest-first list of
//  `ZoneMessageService` chat messages and `CommunityPinService` crowd pins, scoped to one
//  selected zone at a time.
//  Community 2.0 Phase 3 (build 20 S9) additions — the trust loop: the "I'm heading there"
//  claim button now calls the real `claim_pin` RPC (was a disabled stub through Phase 1); a
//  profile row (avatar/handle/tenure/accuracy/helped-count/rep); a live-queried "THIS WEEK"
//  leaderboard, both net-new to this file.
//  Spec: docs/community-2.0-reconciliation-spec.md §1 delta table ("Crew feed"), §2.3
//  (zones), §2.5/§2.6 (profile/rep columns + triggers), §2.10 (claim_pin), §3 Phase 1 / Phase
//  3, §6 (verbatim design values). Visual reference:
//  design/prototype.html:842-859 (feed construction), :931 (zone chips), :834 (sheet model),
//  :161-173 (profile row), :179-189 (leaderboard), design/screenshots/05-feed-full.png.
//
//  Mounted ONLY inside `BrowseNavigationSheet`'s `.large`-detent `crewFeed` slot, and only
//  when `AppConstants.communityEnabled == true` (`ContentView.browseNavigationSheetContent`) —
//  with the flag `false` (today's shipped default) this file is never instantiated at all.
//  Every new Phase 3 surface (profile row, leaderboard, claim button) is therefore ALSO
//  flag-gated for free — none of it can render with `communityEnabled == false` (verified,
//  not assumed: there is no separate mount path for any of this file's content).
//
//  Community 2.0 S14 (`docs/community-2.0-s14-execution-spec.md`) additions: the fixed 3-case
//  `CommunityZone` enum is GONE, replaced by the fetched `Models/Zone.swift` list
//  (`Services/ZoneStore.swift`) — the zone chip row is now data-driven (nearest-first, home
//  zone pinned first, max 8 chips + a "More" search sheet for overflow), and every zone lookup
//  here takes an explicit `zones: [Zone]` parameter instead of switching over a compiled enum.
//
//  What lives here:
//   - `CrewFeedItem` — a chat message or a pin, unified into one `Identifiable`, timestamped
//     type so the two can be sorted into a single newest-first list.
//   - `CrewFeedMerge` — pure, view-free merge/format/empty-state logic (mirrors this
//     codebase's `RealtimeMergeGate`/`BrowseSheetDetentMath` house style of separating
//     testable decision logic from the view that consumes it). Directly unit-testable
//     without hosting any SwiftUI view.
//   - `ProfileRowFormatting` (S9) — pure tenure/accuracy formatting for the profile row.
//   - `LeaderboardEntry` / `CommunityLeaderboard` (S9) — pure ranking logic for the "THIS
//     WEEK" leaderboard, same house style as `CrewFeedMerge`.
//   - `CrewFeedSection` — the view: zone chips, zone header, profile row, leaderboard, and the
//     merged feed list (or an intentional "no reports yet" empty state — AC-P1.2/AC-P1.4,
//     never a blank list).
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
//   - (S9) Tenure copy is duration-based ("Member for N months"), NOT the prototype's literal
//     "On {street} since {month}" — see `ProfileRowFormatting.tenure`'s doc comment for why
//     (no per-user home-street column exists anywhere in the schema).
//   - (S9) "Tickets dodged this month" (`prototype.html:175-178`) is DELIBERATELY NOT
//     implemented — no honest derivation exists from live data (no schema field or query
//     represents "a ticket that would have been issued but wasn't"); fabricating one would be
//     exactly the engagement-bait number this codebase's product principle rejects. Flagged
//     in the PR body per this session's explicit dispatch instruction to skip and say so
//     rather than fake it.
//   - (S9) Leaderboard avatars: `pins_with_author` (the only per-author read path this session
//     verified) does not expose `profiles.avatar` for any author besides the current user's
//     own profile fetch — other neighbors' leaderboard rows show a plain rank/handle/count,
//     no avatar glyph (`prototype.html:184`'s `{{ l.e }}` emoji is demo-fixture data with no
//     live equivalent here), rather than fabricating one.
//
//  S13c (hero-parity pass, docs/design/community-2.0-final-parity-audit.md) additions:
//   - Fix #2: `CrewFeedMerge.icon(for:)`'s enforcement/sweeper cases now match
//     `MapKeyLegendView.livePinEntries`/`PinMarkerAnnotation.markerStyle(for:)` exactly
//     (SF Symbols + teal/cyan), not the prototype's literal emoji/orange-green rings.
//   - Fix #5: `ProfileRowFormatting.accuracyLabel` now returns "—" whenever `accurate == 0`
//     (not just `total == 0`) — a poster with reports but zero CONFIRMS no longer sees a
//     punitive false "0%".
//   - Fix #12: `awayZoneNote` — "you're browsing this square" note, gated on the CORRECTED
//     Fix #1 home-zone derivation. Copy deviates from the screenshot's literal
//     "posting stays in your home square" claim — flagged in this session's PR body, since
//     `crewComposeRow` actually posts to whichever zone is currently selected, not
//     unconditionally to the user's home zone.
//   - Garage-savings stat (`garageSavingsCard`): new build, not a fix — §3's Option A. See
//     `Services/GarageSavingsService.swift`.
//
//  PR #105 Mac-gate fix (post-S13c, live-smoke found by Kevin): Fix #12's away-note NEVER
//  rendered live despite the pure gating logic (`homeZoneId != selectedZone.id`) being
//  correct in isolation and the static QA pass approving the wiring. Root cause: `homeZoneId`
//  was threaded down as a PLAIN VALUE (`ContentView.communityHomeZoneId` → the `crewFeed:`
//  closure → `CrewFeedSection`'s stored `var homeZoneId: String?`), captured at whatever
//  moment `BrowseNavigationSheet.body` last happened to reconstruct `CrewFeedSection` (which
//  only happens when `detentKind` changes or an Observable property READ during THAT specific
//  render changes — a much rarer event than this view's own re-renders). Tapping a zone chip
//  is `CrewFeedSection`'s OWN local `@State` (`selectedZone`) — it does NOT ask the parent to
//  reconstruct the view, so `homeZoneId` never refreshed relative to the zone the user was
//  actually looking at. Contrast `pinService.visiblePins`/`zoneMessageService.messages`, read
//  DIRECTLY inside this view's OWN body (`feedContent`, `contributorCountLabel`) — those
//  correctly self-update because the Observable read happens within THIS view's own render,
//  not a distant ancestor's. Fix: `homeZoneId` is now a COMPUTED property that reads
//  `parkPinService`/`locationService` DIRECTLY (both passed in as references, same pattern as
//  `pinService`/`zoneMessageService`/`authService` above) and calls the exact same
//  `ContentView.resolveHomeZoneId` priority rule Fix #1 already established (car > device
//  location > nil) — so this view re-evaluates its own home zone on every one of its own body
//  passes, the same way the feed/contributor-count already did. `ContentView` no longer
//  passes `homeZoneId:` into this view's initializer at all.
//

import SwiftUI
// PR #105 wiring fix: `homeZoneId` below reads `locationService.userLocation` directly
// (`CLLocationCoordinate2D?.latitude`/`.longitude`) — SwiftUI does not re-export CoreLocation
// (unlike MapKit, which `ContentView.swift` relies on for the same member access), so this
// file needs its own explicit import for that member access to resolve.
import CoreLocation

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

// MARK: - CrewFeedMerge (pure, view-free logic)

/// Pure decision/formatting helpers for the crew feed — no SwiftUI, no networking, no
/// mutable state. Mirrors this codebase's `RealtimeMergeGate` / `BrowseSheetDetentMath`
/// convention of keeping testable logic separate from the view that renders it.
enum CrewFeedMerge {

    // MARK: Merge + zone filter

    /// The zone a pin counts toward for feed filtering: its own `zoneId` if set (and still
    /// present in `zones`), else a `ZoneGeometry.zoneId(forLat:lng:in:)` lookup by `(lat, lng)`
    /// (S4 QA pass 1 Finding #3 fix; Community 2.0 S14: also the "stored id wins over geometry"
    /// rule — a stored id that's since dropped out of `zones` degrades exactly like a `nil`
    /// one). `nil` if neither resolves (a pin with no recognized `zoneId` outside every known
    /// box).
    static func resolvedZoneId(for pin: CommunityPin, zones: [Zone]) -> String? {
        if let zoneId = pin.zoneId, zones.contains(where: { $0.id == zoneId }) {
            return zoneId
        }
        return ZoneGeometry.zoneId(forLat: pin.lat, lng: pin.lng, in: zones)
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
    /// bearing, not defensive. Pins filter through `resolvedZoneId(for:zones:)` (bounding-box
    /// fallback for a `nil`/unrecognized `zone_id`), not raw `pin.zoneId`, so pre-existing
    /// enforcement/sweeper reports (which no write path stamps with a zone yet) still
    /// surface in the correct zone's feed.
    static func merge(messages: [ZoneMessage], pins: [CommunityPin], zoneId: String, zones: [Zone]) -> [CrewFeedItem] {
        let chatItems = messages
            .filter { $0.zoneId == zoneId }
            .map(CrewFeedItem.chat)
        let pinItems = pins
            .filter { resolvedZoneId(for: $0, zones: zones) == zoneId }
            .map(CrewFeedItem.pin)
        return (chatItems + pinItems).sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: Away-zone note (S13c Fix #12 / PR #105 wiring fix)

    /// Pure decision for `CrewFeedSection.awayZoneNote`: `nil` when no note should render
    /// (no resolvable home zone, or the currently-selected zone chip already IS home);
    /// otherwise the `Zone` to name as "home" in the note's copy. Extracted so the exact
    /// gating rule that shipped broken in S13c (never observed the live home-zone value — see
    /// this file's header comment) has a directly-testable pure form independent of the
    /// SwiftUI view-update mechanics that caused the live failure. Community 2.0 S14: `Zone`
    /// (fetched) replaces the old fixed `CommunityZone` enum — works identically for any zone
    /// name, no gating-rule change.
    static func awayZoneNote(homeZoneId: String?, selectedZoneId: String, zones: [Zone]) -> Zone? {
        guard let homeZoneId, homeZoneId != selectedZoneId else { return nil }
        return zones.first { $0.id == homeZoneId }
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

    /// Icon + ring color for a pin type.
    ///
    /// S13c Fix #2 (`docs/design/community-2.0-final-parity-audit.md` §2 item 2):
    /// `enforcementActive`/`sweeperPassed` now match `MapKeyLegendView.livePinEntries` and
    /// `PinMarkerAnnotation.markerStyle(for:)` EXACTLY (`person.badge.clock.fill`/`.teal` and
    /// `truck.box.fill`/`.cyan`) — previously this returned the prototype's literal
    /// 🎫 orange / 🧹 green emoji rings, which disagreed with the "?" map-key legend a user
    /// might open seconds before seeing this exact pin type rendered differently in the feed.
    /// `symbolName` is non-nil for an SF Symbol treatment (rendered via `Image(systemName:)`);
    /// `glyph` is non-nil for the emoji-glyph treatment `openSpot`/`leavingSoon`/`construction`/
    /// `filming`/`blockNote` still use (those four aren't map-key-legend-covered map markers in
    /// the same all-symbol way, or — for `openSpot`/`leavingSoon` — already match the map
    /// marker's own glyph choice per spec §6, so they're unchanged here). Exactly one of the
    /// two is non-nil for every case.
    static func icon(for pinType: PinType) -> (symbolName: String?, glyph: String?, color: Color) {
        switch pinType {
        case .enforcementActive: return ("person.badge.clock.fill", nil, .teal)
        case .sweeperPassed:     return ("truck.box.fill", nil, .cyan)
        case .openSpot:          return (nil, "P",  Self.color(hex: 0x0A84FF))
        case .leavingSoon:       return (nil, "🚙", Self.color(hex: 0x0A84FF))
        case .construction:      return (nil, "🚧", Self.color(hex: 0xE8730D))
        case .filming:           return (nil, "🎬", Self.color(hex: 0xE8730D))
        case .blockNote:         return (nil, "📌", Self.color(hex: 0x9BA1AF))
        // Every other type is not expected to appear in the crew feed (not a crowd/ephemeral
        // or block-scoped closure type) — a neutral fallback keeps this switch exhaustive-safe
        // without ever failing to render a row.
        default:                 return (nil, "📍", Color(.systemGray))
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

// MARK: - ProfileRowFormatting (Community 2.0 Phase 3, build 20 S9)

/// Pure formatting helpers for the crew-feed profile row — mirrors `CrewFeedMerge`'s house
/// style of view-free, directly-testable logic. Spec: §2.5/§3 Phase 3,
/// `design/prototype.html:161-173`.
///
/// `nonisolated` throughout (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — these are
/// pure functions with no actor-isolated state, and must stay callable from a plain
/// synchronous `XCTestCase` without `await`.
enum ProfileRowFormatting {

    /// Elapsed-time tenure string derived from `profiles.created_at` — spec §3 Phase 3's own
    /// wording: "tenure (`now() - profiles.created_at`, already available)".
    ///
    /// Deliberately NOT the prototype's literal "On {street} since {month}" copy
    /// (`prototype.html:939`, `"On Mott St since March"`) — no per-user home-street column
    /// exists anywhere in `profiles` or the `pins_with_author`/`profiles` read path this
    /// session verified, and a user's profile isn't anchored to any one blockface (they can
    /// post/react anywhere across all three zones). Fabricating a street would misrepresent
    /// data the app doesn't have. This is a deliberate substitution of the AUTHORITATIVE
    /// spec's own duration-based definition for the dispatch's prototype-quoted phrasing —
    /// flagged in the PR body per this session's fidelity discipline, not silently swapped.
    nonisolated static func tenure(createdAt: Date, now: Date) -> String {
        let days = max(0, Int(now.timeIntervalSince(createdAt) / 86400))
        if days < 7 {
            return "New this week"
        }
        if days < 30 {
            let weeks = max(1, days / 7)
            return weeks == 1 ? "Member for 1 week" : "Member for \(weeks) weeks"
        }
        if days < 365 {
            let months = max(1, days / 30)
            return months == 1 ? "Member for 1 month" : "Member for \(months) months"
        }
        let years = max(1, days / 365)
        return years == 1 ? "Member for 1 year" : "Member for \(years) years"
    }

    /// Accuracy percentage — "—" whenever `accurate == 0` (S13c Fix #5,
    /// `docs/design/community-2.0-final-parity-audit.md` §2 item 5 / open-items #12⑤):
    /// previously the em-dash guard only checked `total == 0`, so a brand-new poster with 1
    /// report and 0 confirms got a literal "0%" — arithmetically honest but reads punitive,
    /// since a percentage needs at least one CONFIRMED report before it means anything.
    /// Rounds to the nearest whole percent once `accurate > 0`.
    nonisolated static func accuracyLabel(accurate: Int, total: Int) -> String {
        guard accurate > 0, total > 0 else { return "—" }
        let pct = Int((Double(accurate) / Double(total) * 100).rounded())
        return "\(pct)%"
    }
}

// MARK: - LeaderboardEntry (Community 2.0 Phase 3, build 20 S9)

/// One row of the "THIS WEEK" leaderboard (`design/prototype.html:179-189`).
struct LeaderboardEntry: Identifiable {
    /// The author's `auth.uid()`.
    let id: UUID
    /// 1-based rank across every qualifying author in the zone this week, or `nil` when the
    /// current user has a profile but zero qualifying reports this week (AC-P3.3-style honest
    /// "—" rather than a fabricated rank — see `CommunityLeaderboard.build`'s doc comment).
    let rank: Int?
    let username: String
    let confirmedCount: Int
    let isCurrentUser: Bool
}

// MARK: - CommunityLeaderboard (pure, view-free logic; Community 2.0 Phase 3, build 20 S9)

/// Pure ranking logic for the Phase 3 "THIS WEEK" leaderboard — mirrors `CrewFeedMerge`'s
/// house style of keeping testable decision logic separate from the view that renders it.
///
/// Spec §3 Phase 3: "Top 5 authors in the selected zone by count of pins they authored with
/// confirm_count > 0 in the trailing 7 days — a live query against existing columns, no new
/// table." The zone/window/confirm-count filtering already happened server-side
/// (`CommunityPinService.fetchLeaderboardPins(zoneId:)`) — this only groups the already-
/// filtered pins by author, counts, and ranks.
///
/// Deliberately counts by REPORT COUNT (`confirm_count > 0` pins authored), NOT by the
/// prototype's literal `pts` column (`prototype.html:942-945`, which is total `rep` points —
/// a different, unbounded-lifetime metric). The authoritative spec's own wording (§3 Phase 3)
/// specifies the report-count metric; the prototype's `pts`/rep-points display is its own
/// demo-data shorthand, not a separate requirement this implementation needs to also satisfy.
///
/// `nonisolated` (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — pure, no actor state.
enum CommunityLeaderboard {

    /// Builds the ranked top-5 + (conditionally) a trailing "You" row.
    ///
    /// - Parameters:
    ///   - pins: Pre-filtered pins — the direct result of `fetchLeaderboardPins(zoneId:)`
    ///     (source=crowd, confirm_count>0, within the trailing 7-day window, within the
    ///     zone's bounding box). This function does not re-filter by zone or date.
    ///     QA pass 1 Finding #2 (PR #97): `fetchLeaderboardPins` now bounds its own request
    ///     to `order=confirm_count.desc&limit=200` — for a zone with more than 200 qualifying
    ///     pins in a week, `pins` here is the top-200-by-confirm_count subset, not the full
    ///     trailing-week set. Accepted v1 semantics: an author whose reports individually have
    ///     LOWER confirm counts (but there are many of them) could rank slightly lower here
    ///     than an unbounded full-scan would show, since some of their qualifying pins might
    ///     fall outside the 200-row cutoff. `build` itself makes no full-data assumption — it
    ///     purely groups/ranks whatever `pins` it's handed — so no code change was needed here
    ///     beyond this note; only the query's own bound (§ `buildLeaderboardRequest`) changed.
    ///   - currentUserId: The signed-in user's id (`authService.currentUserId`), or `nil`.
    ///   - hasProfile: Whether the current user has a `profiles` row
    ///     (`CrewFeedSection.currentProfile != nil`). Matches `prototype.html:945`'s
    ///     `profileOn` gate — no "You" row at all until a profile exists.
    /// - Returns: Up to 5 top entries (by confirmed-report count, ties broken by username for
    ///   deterministic ordering), PLUS a trailing "You" row when `hasProfile` is true and the
    ///   current user isn't already inside the top 5 (no duplicate row for someone who's
    ///   already visibly ranked). A user with a profile but zero qualifying reports this week
    ///   gets a "You" row with `rank: nil` (renders as "—") and `confirmedCount: 0` — an
    ///   honest zero, not the prototype's fabricated demo rank (`rank: 9`/`14`,
    ///   `prototype.html:945`; product principle: real data or nothing).
    nonisolated static func build(
        pins: [CommunityPin],
        currentUserId: UUID?,
        hasProfile: Bool
    ) -> [LeaderboardEntry] {
        // Group by author. Pins with no author_id are excluded — an unattributed report
        // can't credit anyone (shouldn't occur for source=crowd in practice; every
        // `insertCrowdPin` call sets `author_id`, but this stays defensive).
        var countsByAuthor: [UUID: (username: String, count: Int)] = [:]
        for pin in pins {
            guard let authorId = pin.authorId else { continue }
            let username = pin.authorUsername ?? "Neighbor"
            if let existing = countsByAuthor[authorId] {
                countsByAuthor[authorId] = (existing.username, existing.count + 1)
            } else {
                countsByAuthor[authorId] = (username, 1)
            }
        }

        // Deterministic sort: count desc, then username asc (stable tie-break, both for
        // tests and for two neighbors who genuinely tie in a real week).
        let ranked = countsByAuthor
            .map { (id: $0.key, username: $0.value.username, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.username < $1.username
            }

        var entries: [LeaderboardEntry] = ranked.prefix(5).enumerated().map { index, row in
            LeaderboardEntry(
                id: row.id,
                rank: index + 1,
                username: row.username,
                confirmedCount: row.count,
                isCurrentUser: row.id == currentUserId
            )
        }

        guard hasProfile, let currentUserId else { return entries }
        // Already visible in the top 5 above — no duplicate "You" row.
        if entries.contains(where: { $0.id == currentUserId }) { return entries }

        if let ownIndex = ranked.firstIndex(where: { $0.id == currentUserId }) {
            let own = ranked[ownIndex]
            entries.append(LeaderboardEntry(
                id: own.id,
                rank: ownIndex + 1,
                username: "You",
                confirmedCount: own.count,
                isCurrentUser: true
            ))
        } else {
            // Has a profile, zero qualifying reports this week — honest zero, no rank.
            entries.append(LeaderboardEntry(
                id: currentUserId,
                rank: nil,
                username: "You",
                confirmedCount: 0,
                isCurrentUser: true
            ))
        }
        return entries
    }
}

// MARK: - LeaderboardPublishGuard (QA pass 1 Finding #1, PR #97)

/// Pure "should this fetch's result actually reach the UI" decision, factored out of
/// `CrewFeedSection.loadLeaderboard(zone:)` so the race-safety logic is directly
/// unit-testable without spinning up a real, cancellable `Task` — mirrors this file's
/// `CrewFeedMerge`/`CommunityLeaderboard` convention of pure, view-adjacent logic.
///
/// `loadLeaderboard(zoneId:)` is driven by `.task(id: selectedZoneId)` (not a manual `Task {}`
/// in `onChange`), which auto-cancels an in-flight fetch for the OLD zone the instant
/// `selectedZoneId` changes. This guard is defense-in-depth on top of that cancellation, not a
/// replacement for it: `Task.isCancelled` alone can lag by the tiny window between
/// cancellation firing and an already-in-flight `await` actually observing it, and checking
/// the fetched zone against the CURRENTLY selected zone catches that window directly rather
/// than relying on cancellation propagation timing.
///
/// Community 2.0 S14: takes `Zone` (fetched) rather than the old fixed `CommunityZone` enum —
/// no gating-rule change, works identically for any zone name.
///
/// `nonisolated` (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — pure, no actor state.
enum LeaderboardPublishGuard {

    /// - Parameters:
    ///   - fetchedZone: The zone this now-resolved fetch was FOR.
    ///   - currentZone: The currently-selected zone AT THE MOMENT the fetch resolved (read
    ///     fresh, not captured at fetch-start — a zone switch mid-flight must change this).
    ///     `nil` when nothing is currently selected (e.g. the zone list is still empty).
    ///   - isCancelled: `Task.isCancelled`, checked at the same moment.
    /// - Returns: `true` only when the fetch's own zone still matches what's currently
    ///   selected AND the task wasn't cancelled — i.e. this result is still relevant.
    nonisolated static func shouldPublish(
        fetchedZone: Zone,
        currentZone: Zone?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && currentZone == fetchedZone
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

    /// PR #105 wiring fix (see this file's header comment): passed in as references, exactly
    /// like `pinService`/`zoneMessageService`/`authService` above, so `homeZoneId` below can
    /// read them DIRECTLY inside this view's own body/computed-property evaluation — the
    /// same "Observable read happens in the consuming view's own render" pattern that already
    /// made `feedContent`/`contributorCountLabel` correctly self-update, rather than relying
    /// on a plain value threaded down through a distant ancestor that only reconstructs this
    /// view on its own, much rarer, schedule.
    var parkPinService: ParkPinService
    var locationService: LocationService

    /// Community 2.0 S14: the fetch-at-launch zone list backing the nearest-first picker.
    /// Passed in as a reference, same "read directly in this view's own body" pattern as
    /// `pinService`/`zoneMessageService`/`parkPinService`/`locationService` above.
    var zoneStore: ZoneStore

    /// S13c garage-savings stat (`docs/design/community-2.0-final-parity-audit.md` §3,
    /// Option A): device-local running total, read fresh on every appearance rather than
    /// held as long-lived `@State` — this card has no write path of its own (accrual happens
    /// in `ContentView`'s "I left — clear pin" action), so there's nothing to keep in sync
    /// beyond re-reading `UserDefaults` when the card becomes visible again.
    @State private var garageSavingsTotal: Double = 0

    /// Community 2.0 S14: the currently-selected zone chip's id. `nil` only when `zoneStore`
    /// hasn't resolved any zone yet (first-launch-and-offline cold start with no cache — see
    /// `ZoneStore`'s own doc comment) — every view below tolerates `nil` gracefully (no zone
    /// selected, not a crash), matching every other consumer's "empty `zones` is a real,
    /// supported state" contract.
    @State private var selectedZoneId: String? = nil

    /// Community 2.0 S14: whether the "More" overflow sheet (all zones, searchable) is
    /// presented. Only ever reachable when `zoneStore.zones.count > 8` (`zoneChipsRow`'s own
    /// gate) — at today's 3-zone table this stays permanently unreachable, byte-identical UX.
    @State private var isMoreZonesSheetPresented = false

    /// Search text for the "More" overflow sheet's zone list. Reset is not needed on dismiss —
    /// a user reopening the sheet mid-search resuming their last query is reasonable, matches
    /// standard `.searchable(text:)` conventions elsewhere in iOS.
    @State private var moreZonesSearchText = ""

    /// Community 2.0 Phase 3 (build 20 S9): the current user's own `profiles` row, or `nil`
    /// when none exists yet (an anonymous device that's never authored/voted/chatted — see
    /// `CommunityPinService.fetchOwnProfile(userId:)`'s doc comment). Drives `profileRow`
    /// (renders nothing when `nil`) and `CommunityLeaderboard.build`'s `hasProfile` gate.
    @State private var currentProfile: CommunityProfile? = nil

    /// This zone's "THIS WEEK" leaderboard — recomputed on every zone switch (AC-P3.4).
    @State private var leaderboardEntries: [LeaderboardEntry] = []

    /// Guards `loadProfileIfNeeded()` against refetching on every zone switch — the profile
    /// isn't zone-scoped, so once an attempt has been made (successful or not), subsequent
    /// `.task(id: selectedZoneId)` invocations skip straight to the leaderboard load. Stays
    /// `false` if `authService.currentUserId` was nil at attempt time (shouldn't happen given
    /// anonymous auth, but this lets a later invocation retry rather than permanently give up).
    @State private var hasAttemptedProfileLoad = false

    // MARK: - S13b (build 20, hero-gap-inventory WP3 rider): zone-level compose bar

    /// "Say something to the square…" (`design/prototype.html:151-157`) — the zone-wide
    /// counterpart to `BlockDetailView`'s segment-anchored "Message this block…" compose bar.
    /// Both call the SAME `ZoneMessageService.sendMessage`; this one passes `segmentId: nil`.
    @State private var crewDraft: String = ""
    @State private var isSendingCrewMessage = false
    @State private var crewSendError: String? = nil

    /// Holds the "resume posting" closure while the local identity sheet is up — mirrors
    /// `ParkedCarDetailView.pendingIdentityAction` / `ReportSheet.pendingIdentityAction`
    /// exactly (local nested sheet-on-sheet, no `ContentView` wiring — this view is itself
    /// mounted inside `BrowseNavigationSheet`'s already-presented sheet, the same "presented
    /// context" shape those two files' own header comments document as the safe precedent).
    @State private var pendingIdentityAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneChipsRow
            zoneHeaderRow
            awayZoneNote
            crewComposeRow

            Divider()

            garageSavingsCard
            profileRow
            leaderboardSection

            feedContent
        }
        .padding(.top, 6)
        .onAppear {
            // Community 2.0 S14: (re)derive the selection from whatever `zoneStore.zones`
            // already holds at mount time — the fetch itself ran unconditionally at cold
            // launch (`ContentView.performLaunchSetup()`), so this is very often already
            // populated by the time a user opens the crew feed. `.onChange(of:
            // selectedZoneId)` below (not a direct `selectZone(...)` call here) is what
            // actually pushes the resolved id into `pinService`/`zoneMessageService` — see
            // that modifier's own comment for why a single path is correct.
            selectedZoneId = ZoneSelectionDefaulting.defaultSelection(
                currentSelection: selectedZoneId,
                orderedZones: orderedZones
            )
            garageSavingsTotal = GarageSavingsService().currentMonthTotal()
        }
        .onChange(of: selectedZoneId) { _, newZoneId in selectZone(newZoneId) }
        // Community 2.0 S14: re-defaults the selection if `zoneStore.zones` changes after this
        // view has already mounted (the fetch resolving WHILE the crew feed is open — rare,
        // since the fetch fires once at cold launch, but possible if the sheet is opened
        // before it settles). Keeps a still-valid selection untouched (ids are stable across
        // the fetch completing — `docs/community-2.0-manhattan-zones.md`'s id-stability
        // decision) and only re-defaults when the current selection genuinely vanished.
        .onChange(of: zoneStore.zones) { _, _ in
            let defaulted = ZoneSelectionDefaulting.defaultSelection(
                currentSelection: selectedZoneId,
                orderedZones: orderedZones
            )
            if defaulted != selectedZoneId { selectedZoneId = defaulted }
        }
        // QA pass 1 fix (PR #97, Finding #1 — AC-P3.4): `.task(id: selectedZoneId)` replaces
        // the old manual `Task {}` fired from `onAppear`/`onChange`. SwiftUI automatically
        // cancels the in-flight task for the PREVIOUS zone the instant `selectedZoneId`
        // changes, closing the out-of-order-completion race where a slower earlier zone's
        // response could overwrite a faster later zone's already-rendered result. Also folds
        // in the one-time profile load (`loadProfileIfNeeded()` no-ops after its first
        // successful attempt), so the "profile known before the leaderboard's hasProfile
        // decision" sequencing the old onAppear/onChange split needed is now just "await it
        // first, every time" — cheap and race-free rather than a bespoke double-load.
        .task(id: selectedZoneId) {
            await loadProfileIfNeeded()
            if let selectedZoneId {
                await loadLeaderboard(zoneId: selectedZoneId)
            } else {
                leaderboardEntries = []
            }
        }
        // S13b: local nested identity-sheet interception — see `pendingIdentityAction`'s doc
        // comment for why this is the correct precedent to mirror here.
        .sheet(isPresented: identitySheetPresented) {
            IdentitySheet(
                onSave: { username, avatar in
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    Task {
                        do {
                            try await pinService.upsertProfile(username: username, avatar: avatar)
                        } catch {
                            #if DEBUG
                            print("[CrewFeedSection] upsertProfile failed: \(error)")
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
        // Community 2.0 S14: the "More" overflow sheet — only ever reachable via `moreChip`,
        // which itself only renders when `zoneStore.zones.count > 8` (§3.4's byte-identical-
        // at-3-zones requirement).
        .sheet(isPresented: $isMoreZonesSheetPresented) {
            moreZonesSheet
        }
    }

    // MARK: - S13b: zone-level compose bar

    private var crewComposeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Say something to the square…", text: $crewDraft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(white: 0.46).opacity(0.16), in: Capsule())
                    .accessibilityLabel("Say something to the square")

                Button {
                    submitCrewMessage()
                } label: {
                    if isSendingCrewMessage {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
                .disabled(isSendingCrewMessage || selectedZoneId == nil || !ZoneMessageComposeLogic.canSend(draft: crewDraft))
                .accessibilityLabel("Send")
            }

            if let crewSendError {
                Text(crewSendError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var identitySheetPresented: Binding<Bool> {
        Binding(
            get: { pendingIdentityAction != nil },
            set: { isPresented in
                if !isPresented { pendingIdentityAction = nil }
            }
        )
    }

    /// Entry point for the compose bar's send button — routes through the SAME identity gate
    /// every other contribution path uses (`ReportSheet.submitReport()`,
    /// `ParkedCarDetailView.submitLeavingSoon()`, `BlockDetailView.submitChat()`).
    private func submitCrewMessage() {
        guard selectedZoneId != nil else { return }
        let trimmed = ZoneMessageComposeLogic.trimmedBody(crewDraft)
        guard !trimmed.isEmpty else { return }
        if CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: AppConstants.communityEnabled,
            identitySheetShouldShow: CommunityIdentityGate().shouldShow()
        ) {
            pendingIdentityAction = { Task { await performSendCrewMessage(trimmed) } }
            return
        }
        Task { await performSendCrewMessage(trimmed) }
    }

    private func performSendCrewMessage(_ body: String) async {
        guard let selectedZoneId else { return }
        isSendingCrewMessage = true
        crewSendError = nil
        do {
            // segmentId: nil — zone-wide message, the crew feed's own scope (as opposed to
            // BlockDetailView's segment-anchored send, which passes a real Segment.id).
            try await zoneMessageService.sendMessage(zoneId: selectedZoneId, segmentId: nil, body: body)
            crewDraft = ""
        } catch {
            // Same wording as every other contribution-path network-failure string in this
            // codebase (`ReportSheet.submitError`, `ParkedCarDetailView.leavingSoonError`).
            crewSendError = "Couldn't send. Check your connection and try again."
        }
        isSendingCrewMessage = false
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
    ///
    /// Community 2.0 Phase 3 (build 20 S9): does NOT itself trigger the leaderboard reload —
    /// that's `body`'s separate `.task(id: selectedZoneId)` modifier, since the leaderboard is
    /// a one-shot, independently-cancellable network fetch, not part of the two services' own
    /// zone-filter state (QA pass 1, PR #97: `.task(id:)` replaced the original manual
    /// `Task {}` this comment used to describe here — see `loadLeaderboard`'s own doc comment).
    ///
    /// `nil` clears both services' selection (empty feed, no chat fetch) — the same "no zone
    /// selected" degrade `ZoneMessageService.setSelectedZone(nil)` already documents.
    private func selectZone(_ zoneId: String?) {
        pinService.setSelectedZone(zoneId)
        zoneMessageService.setSelectedZone(zoneId)
    }

    // MARK: - Profile + leaderboard loading (Community 2.0 Phase 3, build 20 S9)

    /// Loads the current user's own profile once — `hasAttemptedProfileLoad` makes every
    /// invocation after the first a no-op, so calling this unconditionally from
    /// `.task(id: selectedZoneId)` on every zone switch doesn't refetch a profile that isn't
    /// zone-scoped in the first place. A fetch failure (network hiccup) leaves `currentProfile`
    /// at its previous value (`nil` on first load) rather than crashing or showing an error —
    /// the profile row simply doesn't render, same degrade as "no profile exists yet." Does
    /// NOT set `hasAttemptedProfileLoad` when `authService.currentUserId` is nil, so a later
    /// call can retry rather than permanently give up (defensive; shouldn't occur given
    /// anonymous auth's silent on-launch session).
    private func loadProfileIfNeeded() async {
        guard !hasAttemptedProfileLoad, let userId = authService.currentUserId else { return }
        currentProfile = try? await pinService.fetchOwnProfile(userId: userId)
        hasAttemptedProfileLoad = true
    }

    /// Fetches + ranks this zone's "THIS WEEK" leaderboard (AC-P3.4: recomputed on every zone
    /// switch — no stale cross-zone data).
    ///
    /// QA pass 1 fix (PR #97, Finding #1): clears `leaderboardEntries` to `[]` BEFORE the
    /// await, not after a failure — so a zone switch (or a network hiccup mid-switch) never
    /// leaves the PREVIOUS zone's rows on screen under the NEW zone's header. An empty section
    /// (`leaderboardSection`'s own `if !leaderboardEntries.isEmpty` guard renders nothing) is
    /// now the explicit "loading or failed" state, never a stale one. This replaces the old
    /// "keep prior zone's entries showing on failure" choice the original doc comment described
    /// — QA correctly flagged that choice as having the same stale-cross-zone-data effect the
    /// race did.
    ///
    /// `LeaderboardPublishGuard.shouldPublish` is checked immediately before the final publish
    /// as defense-in-depth alongside `.task(id: selectedZoneId)`'s own cancellation (see that
    /// type's doc comment for why both checks matter) — belt-and-braces, not a replacement for
    /// `.task(id:)` doing the actual cancellation. `nil` for either the fetched or current zone
    /// (e.g. `zoneId` dropped out of `zoneStore.zones` between the call and the fetch
    /// resolving) safely no-ops rather than publishing.
    private func loadLeaderboard(zoneId: String) async {
        leaderboardEntries = []
        guard let pins = try? await pinService.fetchLeaderboardPins(zoneId: zoneId) else { return }
        let built = CommunityLeaderboard.build(
            pins: pins,
            currentUserId: authService.currentUserId,
            hasProfile: currentProfile != nil
        )
        guard let fetchedZone = zoneStore.zones.first(where: { $0.id == zoneId }) else { return }
        let currentZone = selectedZoneId.flatMap { id in zoneStore.zones.first { $0.id == id } }
        guard LeaderboardPublishGuard.shouldPublish(
            fetchedZone: fetchedZone,
            currentZone: currentZone,
            isCancelled: Task.isCancelled
        ) else { return }
        leaderboardEntries = built
    }

    // MARK: - Zone chips (Community 2.0 S14: data-driven, nearest-first)

    /// Origin for both the chip ordering and home-zone pinning — parked car, else device
    /// location, else neither. Mirrors `ContentView.resolveHomeZoneId`'s own priority so the
    /// home zone and the "nearest" top-of-list zone are almost always the same thing by
    /// construction (spec §3.4).
    private var originLat: Double? {
        parkPinService.parkedCar?.latitude ?? locationService.userLocation?.latitude
    }
    private var originLng: Double? {
        parkPinService.parkedCar?.longitude ?? locationService.userLocation?.longitude
    }

    private var orderedZones: [Zone] {
        ZoneOrdering.orderedZones(
            zones: zoneStore.zones,
            homeZoneId: homeZoneId,
            originLat: originLat,
            originLng: originLng
        )
    }

    /// The zone object for `selectedZoneId`, or `nil` if unresolved (empty `zones`, or a
    /// selection that hasn't been defaulted yet).
    private var selectedZone: Zone? {
        guard let selectedZoneId else { return nil }
        return zoneStore.zones.first { $0.id == selectedZoneId }
    }

    /// Nearest-first chip row (spec §3.4): the `limit` nearest zones plus the currently-selected
    /// one if it fell outside that window, plus a trailing "More" chip when there are more than
    /// 8 zones total. At today's 3-zone table `zoneStore.zones.count > 8` is always false, so
    /// the "More" chip never renders and every zone shows as a chip — byte-identical UX to the
    /// pre-refactor fixed 3-chip row. An empty `zoneStore.zones` (first-launch-and-offline, no
    /// cache) shows an explicit "Couldn't load squares" note rather than a blank row.
    @ViewBuilder
    private var zoneChipsRow: some View {
        if zoneStore.zones.isEmpty {
            Text("Couldn't load squares")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    let visible = ZoneOrdering.visibleChipZones(
                        ordered: orderedZones,
                        selectedZoneId: selectedZoneId,
                        limit: 8
                    )
                    ForEach(visible) { zone in
                        zoneChip(zone)
                    }
                    if zoneStore.zones.count > 8 {
                        moreChip
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func zoneChip(_ zone: Zone) -> some View {
        let isSelected = zone.id == selectedZoneId
        let isHome = zone.id == homeZoneId
        return Button {
            selectedZoneId = zone.id
        } label: {
            HStack(spacing: 4) {
                if isHome {
                    Image(systemName: "house.fill")
                        .font(.system(size: 9))
                }
                Text(zone.name)
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(isSelected ? Color.blue : Color(white: 0.46).opacity(0.16))
        )
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .accessibilityLabel(isHome ? "\(zone.name) zone, home" : "\(zone.name) zone")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Only rendered when `zoneStore.zones.count > 8` (`zoneChipsRow`'s own gate) — opens
    /// `moreZonesSheet`, a flat nearest-first + search list of every zone (spec §3.4:
    /// grouped-by-area browsing is a deferred designer-facing enhancement, not this session).
    private var moreChip: some View {
        Button {
            isMoreZonesSheetPresented = true
        } label: {
            Text("More")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color(white: 0.46).opacity(0.16)))
        .foregroundStyle(Color.secondary)
        .accessibilityLabel("More squares")
    }

    /// Zones matching `moreZonesSearchText` (substring, case-insensitive), nearest-first when
    /// the search field is empty — flat, not grouped-by-area (spec §3.4's explicit v1 default).
    private var moreZonesSearchResults: [Zone] {
        let trimmed = moreZonesSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return orderedZones }
        return orderedZones.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var moreZonesSheet: some View {
        NavigationStack {
            List(moreZonesSearchResults) { zone in
                Button {
                    selectedZoneId = zone.id
                    isMoreZonesSheetPresented = false
                } label: {
                    HStack {
                        if zone.id == homeZoneId {
                            Image(systemName: "house.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(zone.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if zone.id == selectedZoneId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .searchable(text: $moreZonesSearchText, prompt: "Search squares")
            .navigationTitle("All Squares")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isMoreZonesSheetPresented = false }
                }
            }
        }
    }

    // MARK: - Zone header

    private var zoneHeaderRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text((selectedZone?.name ?? "").uppercased())
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

    // MARK: - S13c Fix #12: away-zone note

    /// The user's OWN zone id — car's zone if parked, else device location's zone, else
    /// `nil`. Same priority rule Fix #1 already established for the map's zone box
    /// (`ContentView.resolveHomeZoneId`), called here directly rather than threaded down as a
    /// plain value (PR #105 wiring fix — see this file's header comment for the live bug this
    /// replaced: a plain value only refreshed when this view's PARENT happened to reconstruct
    /// it, which tapping a zone chip — this view's own local `@State` — never triggers).
    /// Evaluated fresh on every one of THIS view's own body passes, so it stays correct across
    /// zone-chip taps without depending on an ancestor's render schedule. Community 2.0 S14:
    /// reads `zoneStore.zones` directly (the same list `orderedZones`/`zoneChip` above use).
    private var homeZoneId: String? {
        guard AppConstants.communityEnabled else { return nil }
        return ContentView.resolveHomeZoneId(
            parkedCarLat: parkPinService.parkedCar?.latitude,
            parkedCarLng: parkPinService.parkedCar?.longitude,
            deviceLocationLat: locationService.userLocation?.latitude,
            deviceLocationLng: locationService.userLocation?.longitude,
            zones: zoneStore.zones
        )
    }

    /// `design/screenshots/06-away-zone.png`'s intent — lets a browsing user know the zone
    /// chip they're currently viewing ISN'T their own. Gated via `CrewFeedMerge.awayZoneNote`
    /// (pure, directly testable), fed by the CORRECTED Fix #1 home-zone derivation above.
    ///
    /// Copy note (flagged in this PR's body, not silently decided): the screenshot's literal
    /// copy is "posting stays in your home square" — but `crewComposeRow`'s compose bar
    /// actually posts to whichever zone chip is currently SELECTED
    /// (`performSendCrewMessage`'s `zoneId: selectedZoneId`), not unconditionally to the
    /// user's home zone. Asserting the screenshot's literal claim here would be false given
    /// today's actual send behavior, so this note states only what's true (which square is
    /// "home") rather than a claim about where a post will land.
    @ViewBuilder
    private var awayZoneNote: some View {
        if let selectedZoneId,
           let homeZone = CrewFeedMerge.awayZoneNote(homeZoneId: homeZoneId, selectedZoneId: selectedZoneId, zones: zoneStore.zones) {
            HStack(spacing: 6) {
                Image(systemName: "location.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("You're browsing \(selectedZone?.name ?? "") \u{2014} your home square is \(homeZone.name).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - S13c garage-savings stat

    /// "$X back in your pocket this month — no garage needed" (audit copy option #3,
    /// `docs/design/community-2.0-final-parity-audit.md` §3, Option A). Accrued on
    /// "I left — clear pin" (`ContentView`'s `.parkedCarDetail` → `onClearPin`) via
    /// `GarageSavingsService`; device-local, month-boundary reset. Renders nothing when the
    /// running total is 0 — a fresh install, or a user who hasn't cleared a pin this month,
    /// sees no card (never a "$0" placeholder).
    @ViewBuilder
    private var garageSavingsCard: some View {
        if garageSavingsTotal > 0 {
            HStack(spacing: 10) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(CrewFeedMerge.color(hex: 0x30D158))
                Text(GarageSavingsCopy.summary(total: garageSavingsTotal))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: 0.46).opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Profile row (Community 2.0 Phase 3, build 20 S9)

    /// `design/prototype.html:161-173`: avatar, handle, tenure/accuracy/helped-count line,
    /// rep badge. Renders NOTHING when `currentProfile` is `nil` (matches the prototype's own
    /// `profileOn = !!handle` gate — an anonymous-no-profile user sees no row at all, not an
    /// empty/placeholder one).
    @ViewBuilder
    private var profileRow: some View {
        if let profile = currentProfile {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.16))
                        .frame(width: 42, height: 42)
                    if let avatar = profile.avatar {
                        Text(avatar)
                            .font(.system(size: 20))
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.username)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(profileSubLine(for: profile))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(profile.reputation)")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(CrewFeedMerge.color(hex: 0x30D158))
                    Text("REP")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: 0.46).opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }

    /// "<tenure> · <accuracy>% accurate · helped <N> neighbors" (`prototype.html:166`'s shape;
    /// see `ProfileRowFormatting.tenure`'s doc comment for the tenure-copy deviation).
    private func profileSubLine(for profile: CommunityProfile) -> String {
        let tenure = ProfileRowFormatting.tenure(createdAt: profile.createdAt, now: .now)
        let accuracy = ProfileRowFormatting.accuracyLabel(
            accurate: profile.accurateReportCount,
            total: profile.totalReportCount
        )
        return "\(tenure) · \(accuracy) accurate · helped \(profile.helpedCount) neighbors"
    }

    // MARK: - Leaderboard (Community 2.0 Phase 3, build 20 S9)

    /// `design/prototype.html:179-189`'s "THIS WEEK" card. Renders nothing when there are no
    /// qualifying entries — no fabricated placeholder rows (product principle: real data or
    /// nothing).
    @ViewBuilder
    private var leaderboardSection: some View {
        if !leaderboardEntries.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("THIS WEEK")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)

                ForEach(leaderboardEntries) { entry in
                    leaderboardRow(entry)
                }
            }
            .padding(12)
            .background(Color(white: 0.46).opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
        }
    }

    private func leaderboardRow(_ entry: LeaderboardEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.rank.map(String.init) ?? "—")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .leading)

            Text(entry.username)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text("\(entry.confirmedCount)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(entry.isCurrentUser ? CrewFeedMerge.color(hex: 0x30D158) : .secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Feed content

    @ViewBuilder
    private var feedContent: some View {
        let feed = selectedZoneId.map {
            CrewFeedMerge.merge(
                messages: zoneMessageService.messages,
                pins: pinService.visiblePins,
                zoneId: $0,
                zones: zoneStore.zones
            )
        } ?? []

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
///
/// `internal` (not `private`) as of S13b (build 20,
/// docs/design/community-2.0-hero-gap-inventory.md WP3): `Views/BlockDetailView.swift`'s "LIVE
/// ON THIS BLOCK" section reuses this exact type for its own segment-filtered pin list, so the
/// two surfaces' confirm/dispute/claim affordances can never drift apart — both route through
/// the same `reactionsRowKind(currentUserId:)`-driven `actionRow` below. Nothing about this
/// type's behavior changed; only its access level widened.
struct PinFeedRow: View {
    let pin: CommunityPin
    let authService: SupabaseAuthService
    let pinService: CommunityPinService

    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Community 2.0 Phase 3 (build 20 S9): the "someone beat you to it" race-safe outcome
    /// of a failed `claim_pin` call — deliberately separate from `errorMessage` (see
    /// `handleClaim`'s doc comment) so it never renders with error-red styling.
    @State private var claimMessage: String?

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

    private var icon: (symbolName: String?, glyph: String?, color: Color) {
        CrewFeedMerge.icon(for: pin.pinType)
    }

    /// S13c Fix #2: renders the SF-Symbol treatment when `icon.symbolName` is set
    /// (`enforcementActive`/`sweeperPassed`, matching the map marker + map-key legend
    /// exactly), else falls back to the emoji-glyph `Text` this view always used.
    @ViewBuilder
    private var iconBadge: some View {
        ZStack {
            Circle()
                .strokeBorder(icon.color, lineWidth: 2)
                .background(Circle().fill(Color(white: 0.14)))
            if let symbolName = icon.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(icon.color)
            } else if let glyph = icon.glyph {
                Text(glyph)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(icon.color)
            }
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Own-pin guard (mirrors `ReactionsRow.isOwnPin`)

    private var isOwnPin: Bool {
        guard let authorId = pin.authorId, let currentId = authService.currentUserId else { return false }
        return authorId == currentId
    }

    // MARK: - Action row

    /// Community 2.0 Phase 3 (build 20 S9): routes through the shared, pure
    /// `CommunityPin.reactionsRowKind(currentUserId:)` (`Views/PinMarkerAnnotation.swift`)
    /// rather than re-deriving this branching inline, so this compact feed row and
    /// `PinDetailSheet.ReactionsRow` can never disagree about which pins get which action.
    /// `.delete` maps to no action row here (unchanged Phase 1 behavior — the feed's compact
    /// row has never shown a delete affordance for the caller's own pin; that lives only in
    /// the full `PinDetailSheet`, reached by tapping the pin).
    @ViewBuilder
    private var actionRow: some View {
        switch pin.reactionsRowKind(currentUserId: authService.currentUserId) {
        case .claim:
            leavingSoonAction
        case .vote:
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
        case .delete, .hidden:
            EmptyView()
        }
    }

    /// `leaving_soon` special case (spec §3 Phase 3, `design/prototype.html:203-208`): no
    /// confirm/dispute row — a claim-only affordance instead. Community 2.0 Phase 3 (build 20
    /// S9): wired to the real `CommunityPinService.claimPin(pinId:)` RPC call — this was a
    /// disabled "Coming soon" stub through Phase 1 (read-only scope had no write path yet).
    /// `pin.claimedBy != nil` already reflects a real server-side claim (decoded, never
    /// client-writable — `Models/CommunityPin.swift`).
    @ViewBuilder
    private var leavingSoonAction: some View {
        // QA pass 1 Finding #3 (PR #97): distinguishes the viewer's own successful claim
        // ("You're heading there...") from anyone else's, via the shared
        // `CommunityPin.claimStatusCopy(currentUserId:)` — same function
        // `PinDetailSheet.ReactionsRow.claimSection` uses, so the two surfaces agree.
        if let statusCopy = pin.claimStatusCopy(currentUserId: authService.currentUserId) {
            Text(statusCopy)
                .font(.caption.weight(.medium))
                .foregroundStyle(icon.color)
                .padding(.top, 4)
        } else if !isOwnPin {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    Task { await handleClaim() }
                } label: {
                    Text("I'm heading there")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(icon.color)
                .disabled(isLoading)
                .accessibilityLabel("I'm heading there — claim this spot")

                // Race-safe "someone beat you to it" outcome (spec §2.10/§3 Phase 4) —
                // deliberately not styled as an error; see `claimMessage`'s doc comment.
                if let claimMessage {
                    Text(claimMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    /// "I'm heading there" tap (Community 2.0 Phase 3, build 20 S9) — mirrors
    /// `PinDetailSheet.ReactionsRow.handleClaim` exactly: `false` routes to `claimMessage`
    /// (expected, race-safe outcome), a thrown error routes to `errorMessage` (genuine
    /// failure). No local optimistic patch of `pin.claimedBy` — decode-only field, relies on
    /// the existing Realtime pipeline, same precedent as `handleStillThere`/`handleGone`
    /// above never locally patching `confirmCount`/`disputeCount` either.
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
            errorMessage = "Couldn't claim — try again."
        }
        isLoading = false
    }
}
