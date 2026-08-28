# Community 2.0 hero-design gap inventory — build 20

**Date:** 2026-08-28
**Scope:** `design/prototype.html` + `design/screenshots/01–17` (target state) vs. the iOS app as it
exists on `main` today, projected forward through every session currently scheduled in
`docs/community-2.0-roadmap.md` (S6–S13).
**Method:** Every code claim below was verified by reading the actual Swift file cited (or the named
QA doc for work already built on an unmerged branch). Every visual claim was verified against the
named screenshot via the Read tool, not inferred from the HTML alone. Where I could not verify
something in code, it's marked "inferred" explicitly. I did not modify any file — this is a review
document only.

**What's already merged and live (verified in code, not the roadmap's word):**
- Phase 0 schema (S1/S2) — applied to production, confirmed via `docs/qa/pr93-community-phase0-schema.md`.
- Phase 1 model + service layer (S3) and UI (S4/S5) — `Views/CrewFeedSection.swift`,
  `Services/ZoneMessageService.swift` exist and are wired into `Views/BrowseNavigationSheet.swift`'s
  `.large` detent, gated on `AppConstants.communityEnabled`.
- Phase 2a (S6) — **not yet merged**, but a real branch (`ios/community-phase2a`) with a MERGE-AFTER-
  MAC-GATE QA verdict exists (`docs/qa/pr95-community-phase2a.md`). I read that branch's actual diff
  description, not just the roadmap row, and treat its contents as "about to land."

---

## Screenshot-by-screenshot table

| # | Prototype surface | App today (flag-on) | Scheduled session that adds it | Residual gap after S12 | Classification |
|---|---|---|---|---|---|
| 01 | Home/collapsed: top-right rail (locate / find-car / Park Until), bottom-left "Report" pill (persistent), bottom-right "?" map-key button, ASP banner | Top-right rail and ASP banner **match structurally** (`ContentView.recenterButtonStack`, `Views/ASPBanner.swift` — same 3 buttons, same trigger logic). Report is long-press-only or Drive-Mode-only (`ReportSheet.swift` header comment: two entry points, neither is a resting persistent button). No "?" button/map-key anywhere in `ContentView.swift`. | None schedules a persistent Report button or a map-key button. | Two floating controls never appear. | 🔴 UNSCHEDULED RE-SKIN WORK |
| 02 | Map-key popover: curb-color legend (5 rows) + live-pin legend (6 rows) + caption, triggered by the "?" button, floats above the sheet | No on-map popover exists. The closest analog is `ParkingGuideView` (full-screen sheet, reached via Settings/FAQ/"New to parking?" link) — different interaction model, and it has no live-pin legend section at all. | None. | Entire surface absent. | 🔴 UNSCHEDULED RE-SKIN WORK |
| 03 | Dashed "YOUR SQUARE · NOLITA" polygon + label drawn directly on the map, live pins clustered inside it | `Views/MapViewRepresentable.swift` has no zone-boundary overlay code (grepped; only match is an unrelated purple dashed search-radius circle). Live pins themselves (rings, icons) do render (Phase 1, S4/S5 merged). | None schedules a zone-boundary map overlay. `CommunityZoneBounds` (S4) already has the exact box coordinates this overlay would need. | The "which zone am I standing in" glanceable cue never appears on the map itself — only in the sheet's zone chips. | 🔴 UNSCHEDULED RE-SKIN WORK |
| 04 | At the sheet's **half/medium** detent: zone chips + full crew feed already visible, plus a "Say something to the square…" compose bar | Crew feed mounts **only** at `.large`, not `.medium` — confirmed in `BrowseNavigationSheet.swift`'s `crewFeedBuilder()` call site (`if detentKind == .large, AppConstants.communityEnabled`). No compose bar exists anywhere (`ZoneMessageService.swift` has `fetchMessages`, no send/insert function). | S4/S5 (merged) intentionally placed the feed at `.large`, not medium — this was a QA-driven **correction** of a spec misreading, not an oversight (spec's own §1 delta table: "QA ruled this correct — the spec had mischaracterized FT-20 as two-detent"). No session adds a compose bar. | The detent placement is a **named, already-litigated decision** (see Judgment Calls). The missing compose bar is a real, unscheduled gap. | 🔴 UNSCHEDULED (compose bar) / decision already made (detent) |
| 05 | At `.large`: "Tickets dodged this month" banner, weekly leaderboard, profile row (handle/avatar/tenure/accuracy/helped/rep), zone chat compose bar, feed | None of the banner/leaderboard/profile row exist yet. Feed itself (confirm/gone/claim rows) exists and works. | **Phase 3 (S9)** builds profile row + leaderboard (live-query v1, not a persistent ledger) per spec §3 Phase 3. Tickets-dodged banner is not explicitly itemized in S9's touches but is copy-only, low-risk, reasonable to fold in. Compose bar: unscheduled anywhere. | Compose bar still missing after S9/S12. | 🟡 CONVERGES WHEN S9 lands (leaderboard/profile) / 🔴 UNSCHEDULED (compose bar, same gap as row 4) |
| 06 | Browsing a non-home zone (SoHo): "you're browsing this square — posting stays in your home square" note, feed still shows leaderboard | Zone-switching itself works (`CrewFeedSection`'s `zoneChipsRow`). The "away" copy note does not exist in `CrewFeedSection.swift` (no matching string). Leaderboard is S9-gated (see row 5). | Zone switching: merged (S4/S5). Away-note copy + leaderboard: S9 is the closest scheduled work, but the away-note string itself isn't itemized anywhere. | Copy gap is small but currently orphaned — no session explicitly owns it. | 🟡 CONVERGES WHEN S9 lands (partial) — flag the away-note copy for S13's copy pass explicitly, it isn't self-evidently in S9's scope |
| 07 | Block detail: color band, big status line, rules — **plus** "LIVE ON THIS BLOCK" (ephemeral pin list with confirm buttons) and "BLOCK CHATTER" (segment-anchored chat thread + compose bar) | `Views/BlockDetailView.swift` has the color band / title / big status line / rules / "Park here →" button — these match closely. It has **only** the durable-closure `TemporaryRestrictionBanner` (filming/construction). No ephemeral-pin list, no chat thread, no compose bar. | **None.** `docs/community-2.0-reconciliation-spec.md`'s own "Extends / touches" file list (top of doc) does **not include `BlockDetailView.swift` at all**, across any of Phases 0–4. | This entire section of the prototype's most important detail surface is absent from the plan, not just unbuilt yet. | 🔴 UNSCHEDULED RE-SKIN WORK (highest-value single gap in this inventory) |
| 08 | "Report to the crew": 2×2 icon-card grid (Enforcement / Sweeper / Spot open / Street closure), colored hairline borders per type | `Views/ReportSheet.swift` (main) is a **vertical list** of icon+label+sublabel rows with a trailing checkmark, native `Button`/row style — structurally a SwiftUI settings-list, not a card grid. PR #95 (`ios/community-phase2a`, not yet merged) adds a 3rd row (Street closure) gated on the flag — still a list row, not a card. | S6 (PR #95, imminent) adds the 3rd type as a **list row**. S7 (Phase 2b) adds the 4th type ("Spot open") — also presumably a list row, per the file's established pattern. | All 4 types will exist functionally, but the **visual layout never becomes a grid** — nothing in any session redesigns `ReportSheet`'s layout. | 🔴 UNSCHEDULED RE-SKIN WORK (visual only — functional coverage converges via S6/S7) |
| 09 | "Confirm the street" step: current + opposite-side + 2 neighbor candidates as bordered list rows, "HEADING TOWARD" chip row, "Post to the crew" button | Not yet merged, but PR #95's QA doc confirms this exact structure is built and MERGE-AFTER-MAC-GATE, with a test that reproduces the screenshot's row ordering verbatim. Visual style (bordered rows, not cards) already matches the prototype's own confirm-street step (which is itself list-style, unlike the type-picker grid). | **S6.** | None once S6 merges — QA doc flags only a header-casing nit (sentence-case vs. ALL-CAPS labels), disclosed and low-priority. | 🟡 CONVERGES WHEN S6 lands |
| 10 | "Tap the curb where the spot is" hint banner + tap-to-place + confirm card with auto-derived "near X" / "mid-block" naming | Does not exist. `Views/ReportSheet.swift` has no map-tap placement mode; `SpotPlacementView.swift` doesn't exist yet. | **S7 (Phase 2b).** Spec explicitly scopes this down: ships the "near {cross street}"/"mid-block" naming, **defers** MapKit POI storefront naming ("in front of The Elk") to a fast-follow. | The storefront-name upgrade (`fronts()` lookup in the prototype) stays deferred past S13 — a named, deliberate cut, not an oversight. | 🟡 CONVERGES WHEN S7 lands (with one deliberately-deferred sub-feature) |
| 11 | Spot-open confirm card: "P Spot open — {street} (side)" + near-label + "Post it"/"Cancel" + "Expires in ~3 min · tap elsewhere to move the pin · first come, first served" caption | Does not exist (same file as row 10). | **S7.** | Copy is lifted verbatim in spec §3 Phase 2 — should converge closely once built. | 🟡 CONVERGES WHEN S7 lands |
| 12 | "Say hi to the crew" identity sheet: 8-avatar picker + handle field + "Join the board & post" / "Post anonymously" | `Views/IdentitySheet.swift` doesn't exist. No `profiles` upsert path from iOS exists anywhere (confirmed in spec §1 delta table: "No `profiles` row is ever created from iOS today"). | **S7.** Spec explicitly fixes a real UX bug in the prototype's own logic here: the prototype's `needIdentity()` would re-prompt on every contribution because `skipIdentity` never latches a "seen" flag. Spec's fix (gate on a `UserDefaults` "has this device ever seen the sheet" bool) is a genuine improvement over the prototype, not a compromise. | None expected once S7 lands — this is one of the cleaner scheduled items in the whole plan. | 🟡 CONVERGES WHEN S7 lands |
| 13 | Floating "🧹 Sweeper reported on your block / You're parked here. Did it pass? / Confirm — it passed / Didn't see it" card, appears proactively while the app is open and the user's car is on the affected segment | No such card exists. `Views/ArrivalPromptSheet.swift` is a **different** feature (Drive Mode arrival, not sweeper-confirm). `ContentView.swift` has no matching string or trigger for "did it pass." | **None explicitly.** Phase 4b (S11/S12) builds the *push notification* relevance-gate pipeline (silent push → on-device segment match → local notification), but a push notification is a different UI surface than this always-visible in-app card, and iOS does not banner a push while the app is foregrounded by default — the two need separate trigger paths even though they'd share the same "does this pin's segment match my parked segment" predicate. | The proactive in-app confirm card itself is never built by any current session. | 🔴 UNSCHEDULED (but shares its core logic with S12 — see recommendation) |
| 14 | In-app "You're clear until Friday" banner: green "P" square icon, title, body, "now" timestamp, drops from under the status bar | Doesn't exist as a custom in-app banner; `NotificationScheduler.swift` is 100% local `UNCalendarNotificationTrigger` today, no APNs. | **S11/S12 (Phase 4b)** builds the APNs pipeline + on-device relevance gate + local notification. This will produce a **system** notification banner, not the prototype's custom rounded card — iOS renders system notification banners with its own chrome (app icon, not an arbitrary colored square). | The exact custom visual (colored square icon per pin type) is not achievable through standard `UNUserNotificationCenter` without a `UNNotificationServiceExtension` with rich media, which no session scopes. | 🟡 CONVERGES WHEN S12 lands (system banner, not literal visual match — see Judgment Calls) |
| 15 | My Car sheet: reminder toggle **+ inline 5-chip offset picker** (15 min/30 min/1 hr/2 hr/Night before), "Swept 33 min ago · 6 confirms — clear at 9:30" live status banner, "Hand your spot to the crew" (leaving-soon chips + button) | `Views/ParkedCarDetailView.swift` has a **boolean toggle only** (no inline offset chips — offsets are a separate, pre-existing global setting, not surfaced here). No ephemeral-pin "Swept X ago" banner (only the durable `TemporaryRestrictionBanner` for filming/construction, same gap pattern as row 7). No leaving-soon section at all. | **S10 (Phase 4a)** adds the leaving-soon chip picker + "Leaving in X min" button — confirmed in spec §3 Phase 4 and roadmap S10 row (`ParkedCarDetailView.swift` is its named touch point). Neither the offset-chip redesign nor the "Swept X ago" banner is itemized anywhere. | Two real sub-gaps survive S10: the reminder-offset UI staying a single toggle, and no live sweeper-status banner. | 🔴 UNSCHEDULED (offset chips + swept banner) / 🟡 CONVERGES WHEN S10 lands (leaving-soon section) |
| 16 | "Parking until when?" sheet: 6 quick-pick chips (30 min/1 hr/2 hr/4 hr/Tonight/Thu 9 AM), full-width Confirm, "Skip for now" | `Views/ParkUntilSheet.swift` matches closely: 6 presets (30 min/1 hr/2 hr/4 hr/Tonight/Tomorrow 9am — 6th preset's label differs slightly, "Thu 9 AM" vs. "Tomorrow 9am," a cosmetic difference from a day-of-week vs. relative label, not a functional gap), same confirm/skip structure. This is a **pre-existing W7.5 feature**, unrelated to Community 2.0. | N/A — already shipped, not part of this initiative. | Negligible (one preset label). | ✅ CONVERGED |
| 17 | Map showing the full pin-type variety (enforcement/sweeper/closure/leaving-soon/open-spot) simultaneously + car pin + a confirm-prompt overlay | Pin rendering itself (rings, colors per type on the actual map annotations) is live — Phase 1 (S4/S5, merged) plus the pre-existing Tier 3 enforcement/sweeper markers. The confirm-prompt overlay shown in this screenshot is row 13's gap; the zone boundary is row 3's gap. | Pin rendering: merged. Confirm-prompt + zone boundary: unscheduled (rows 3, 13). | Same two gaps as rows 3 and 13, visible together here. | 🔴 UNSCHEDULED (inherits rows 3 + 13's gaps; base pin rendering itself is ✅) |

---

## Consolidated 🔴 list — work packages

Eight distinct 🔴 findings above consolidate into **five coherent work packages**, plus two smaller
items best folded into already-scheduled sessions rather than spun up alone. Sizes use this repo's
session unit (~one PR-sized 2–4h block, per `docs/community-2.0-roadmap.md`'s own definition).

### WP1 — Map chrome parity: persistent Report pill + Map-key ("?") button
- **Covers:** rows 01, 02.
- **Touches:** `ContentView.swift` (🚩 risky — the single most-contended file in the repo per the
  reconciliation spec's own file-contention ranking; every phase already does "some wiring here").
  New: a small `MapKeyLegendView` (or similar), following `recenterButtonStack`'s existing
  `.regularMaterial`/44×44 pattern rather than the prototype's custom rgba pill styling.
- **Estimate:** ~1 session. Low logical complexity (the Report pill reuses the existing
  `ActiveSheet.reportPin(coord:)` path with the user's current/last-known location; the legend content
  is static data, already fully specified in `prototype.html`'s `legend`/`pinLegend` arrays).
  The risk is entirely in touching `ContentView.swift` cleanly, not in the feature logic itself.

### WP2 — Zone-boundary map overlay
- **Covers:** row 03 (and the residual half of row 17).
- **Touches:** `Views/MapViewRepresentable.swift` (🚩 risky — this file owns curb-color polyline
  rendering; any overlay-drawing change here should get a targeted live-smoke check even though it
  isn't in the file's documented "3 regressions" history the way `BrowseNavigationSheet.swift` is) +
  `ContentView.swift` (wiring).
- **Estimate:** ~1 session. The box coordinates already exist verbatim in `CommunityZoneBounds`
  (`CrewFeedSection.swift`) — this is a rendering task, not a new-data task.

### WP3 — Block detail redesign: live reports + block chatter + chat compose write path
- **Covers:** rows 07 (primary), and half of rows 04/05/06 (the "Say something to the square" /
  "Message this block" compose bars share one missing capability: `ZoneMessageService` has no
  send/insert function at all today).
- **Touches:** `Views/BlockDetailView.swift` (not touched by ANY current phase — confirmed against
  the spec's own file list), `Services/ZoneMessageService.swift` (new write method), possibly
  `Views/CrewFeedSection.swift` (zone-level compose bar reuses the same write path).
- **Estimate:** ~1.5–2 sessions. This is the single highest-value gap in the inventory: it's a
  complete section of the prototype's most-used detail surface that no session anywhere claims.
  Rep math already has a live trigger for "+1 per chat message" (`award_chat_reputation`,
  `03-community-2.0-schema.sql`) waiting on a write path that doesn't exist yet on iOS — the backend
  is ready and idle.

### WP4 — My Car sheet: inline reminder-offset chips + live "Swept X ago" status banner
- **Covers:** row 15 (the two sub-gaps that survive S10).
- **Touches:** `Views/ParkedCarDetailView.swift` — **already** the named touch point for S10's
  leaving-soon UI, so this is a same-file addition, not a new contention point.
- **Estimate:** ~1 session, best absorbed into S10 rather than run standalone (see recommendation).

### WP5 — Proactive in-app "did it pass?" confirm-prompt card
- **Covers:** row 13 (and half of row 17).
- **Touches:** `ContentView.swift` (new overlay component, same layer as `ArrivalPromptSheet`'s
  presentation pattern, which is a reasonable structural precedent to reuse even though it's a
  different feature).
- **Estimate:** ~1 session, best absorbed into S12 rather than run standalone (see recommendation) —
  it needs the exact same "does this pin's segment match my parked segment" relevance-gate logic
  S12 is already writing for the silent-push case.

### Smaller items, fold into existing sessions rather than a new package
- **Report-grid visual restyle** (row 08): list rows → a native `LazyVGrid` card treatment. ~0.5
  session. `Views/ReportSheet.swift` is already mid-surgery across S6/S7/S8 — restyle in S7/S8 rather
  than touching this file a fourth time later.
- **Crew-feed icon palette fix**: `CrewFeedSection.icon(for:)` uses the prototype's literal
  `#FF9F0A` orange for `enforcement_active`, while `PinMarkerAnnotation.markerStyle(for:)` deliberately
  uses `systemTeal`/`systemCyan` SF Symbols for the same types on the actual map (a documented,
  pre-Community-2.0 decision — see Judgment Calls). These two Community-2.0-era surfaces currently
  disagree with each other. ~0.25 session, fold into S13's already-scheduled copy/parity pass.

---

## Recommendation: expanded S13 vs. pull-forward

**Pull forward into already-scheduled sessions (do this, don't wait for S13):**
- **My Car redesign (WP4) → fold into S10.** `ParkedCarDetailView.swift` is already open for surgery
  in S10 for the leaving-soon section. Touching it twice (once for leaving-soon, once later for the
  offset chips/swept banner) is strictly worse than one slightly larger S10 — same file, same QA pass,
  half the review overhead.
- **Confirm-prompt card (WP5) → fold into S12.** S12 is already writing the on-device relevance-gate
  predicate (silent push → does this pin match my parked segment). The in-app foregrounded card needs
  the identical predicate on a different trigger (realtime insert instead of push payload). Building
  it as a separate, later session means re-deriving and re-testing the same match logic twice.
- **Report-grid visual restyle → fold into S7 or S8.** `ReportSheet.swift` is the single most
  actively-edited file in this entire roadmap (S6, S7, S8 all touch it in sequence). Restyling its
  layout while it's already open avoids a fourth touch later and avoids the file drifting further from
  its own establishe header-casing/sublabel conventions (already flagged as a live inconsistency by
  PR #95's QA, Finding #3) before anyone circles back to fix it.
- **Crew-feed icon palette fix → fold into S13's existing copy pass** (it's already scoped to do a
  copy/dark-state/empty-state audit; a one-line palette consistency fix belongs in the same PR).

**Expand into new sessions (S13a/b/c), because their files aren't already open elsewhere:**
- **S13a — Map chrome parity (WP1 + WP2).** ~2 sessions. Lower risk than S13b (no file has a
  documented regression history the way `BrowseNavigationSheet.swift` does), high glanceability
  payoff — these are exactly the "1–2 second stoplight glance" surfaces the product's whole design
  bias is built around. Do this before S13b if sequencing one at a time.
- **S13b — Block detail redesign (WP3).** ~1.5–2 sessions. This is the **highest-value single
  recommendation in this entire inventory** — it's not a polish gap, it's a complete missing section
  of the app's most-used detail sheet, currently invisible to every planning document because no spec
  ever listed `BlockDetailView.swift` as a touch point. Recommend explicitly adding it to the roadmap
  rather than discovering it during the S13 hero-parity pass itself.
- **S13c — the roadmap's existing hero-parity pass**, now carrying two additional small riders (the
  report-grid restyle if not pulled into S7/S8, and the palette fix) on top of its original scope
  (screenshot-by-screenshot audit, copy verbatim-check, empty/dark states).

**Net effect on the roadmap:** the plan grows from S6–S13 (7 remaining sessions) to roughly S6–S15
(9–10 remaining sessions) if WP1–WP3 are run as genuinely new sessions, with WP4/WP5/the two smaller
items absorbed at near-zero marginal session count into S7/S8/S10/S12/S13 as currently planned.

---

## Judgment calls — where the prototype should NOT be matched literally

1. **Map-marker treatment for `enforcement_active`/`sweeper_passed`: keep the shipped SF-Symbol/
   teal-cyan treatment, do not retrofit the prototype's orange emoji-in-ring.**
   `PinMarkerAnnotation.markerStyle(for:)` deliberately uses `person.badge.clock.fill` (systemTeal) and
   `truck.box.fill` (systemCyan) instead of the prototype's `#FF9F0A` orange + 🎫/🧹 emoji, per an
   existing, documented decision (`docs/design/tier3-marker-icons.md`, cited in-file: "Recessive color
   keeps Tier 3 crowd pins subordinate to Tier 1... Teal/cyan are intentionally cooler/recessive so
   crowd pins don't compete with the Tier 1 orange/purple authoritative pins"). This is the correct
   call on two independent grounds: it avoids a real palette collision (the prototype's `#FF9F0A` for
   `enforcement_active` sits uncomfortably close to the sacred curb palette's orange, "free now, but a
   restriction starts within 6 hours" — a driver glancing at the map for one second should never have
   to disambiguate a pin color from a curb-legality color), and it follows this review's own bias
   against emoji-as-icon in favor of SF Symbols. **Action: fix `CrewFeedSection.icon(for:)` to match
   this precedent instead** (see the smaller-items list) — the inconsistency is between two
   Community-2.0-era surfaces, not between the app and the prototype, and that's the part worth fixing.

2. **Crew feed at `.large`, not `.medium` — keep as shipped, do not chase 04-feed-half's detent
   height.** This is not an accidental gap; it's a decision already made and documented (spec §1 delta
   table, roadmap S4 row: "QA ruled this correct — the spec had mischaracterized FT-20 as
   two-detent"). It also directly serves Kevin's §0f minimal-chrome ruling
   (`BrowseNavigationSheet.swift`'s own extensive doc comments on this ruling) by keeping the medium/
   resting detent exactly as fought-for. Do not re-open this.

3. **The persistent Report pill and "?" map-key button (WP1) are a genuine open call, not a settled
   one — flag explicitly rather than silently building or silently dropping.** Kevin's §0f ruling
   rejected a three-equal-control row **inside the sheet's resting action column** ("I think cruise is
   more important than settings or parking 101"). WP1's two buttons are a different chrome surface —
   floating directly on the map, the same layer `recenterButtonStack`'s three existing buttons already
   occupy — so §0f doesn't strictly forbid them, but the underlying design tension (don't clutter the
   resting view with equal-weight controls) is the same one. My recommendation is to build both: a
   long-press-only report entry point is a real discoverability gap on a "phone-in-the-car" product
   (a driver who doesn't already know the gesture exists has no way to discover it), and the PWA's
   maintenance-mode status doesn't provide cover here since this is squarely iOS. But this is Kevin's
   call to make explicitly before WP1 starts, not mine to assume by silently scheduling it.

4. **Report-grid layout: restyle toward native cards, don't copy the prototype's card treatment
   verbatim.** The prototype's 2×2 grid uses emoji glyphs and hairline colored borders — restyle using
   SF Symbols (reusing the same icon choices `PinMarkerAnnotation` already made: shield/truck/etc.,
   consistent with judgment call #1) inside a `LazyVGrid` of `.bordered`-style cards, not a pixel port
   of the web card styling. This resolves the D/palette inconsistency in the same pass.

5. **Reminder-offset UI (My Car sheet): the inline per-car chip picker is worth building (it's better
   UX at the point of decision), but it sits on top of the existing global-settings offset mechanism,
   not a replacement for it.** No schema or notification-scheduling change needed — this is UI-layer
   only, correctly scoped as part of WP4's ~1 session, not a larger rework.

---

## Summary

**8 named 🔴 findings, consolidating into 5 work packages (WP1–WP5) plus 2 smaller riders**, against
7 remaining scheduled sessions (S6–S13). Recommend pulling WP4 (My Car redesign), WP5 (proactive
confirm-prompt card), and both smaller riders (report-grid restyle, feed-icon palette fix) into
sessions that already touch the same files (S7/S8, S10, S12, S13) at near-zero marginal session cost,
and running WP1 (map chrome: Report pill + map key, ~2 sessions) and WP3 (block detail redesign +
chat compose, ~1.5–2 sessions) as genuinely new work — WP2 (zone-boundary overlay, ~1 session) can go
either as part of S13a or standalone. Net roadmap growth: **roughly 4–5 additional sessions**, taking
the plan from S6–S13 to approximately S6–S15. **My top recommendation is WP3 (block detail redesign):**
it's the single gap in this entire inventory that isn't a matter of degree or polish — `BlockDetailView.swift`
is not listed as a touch point in any phase of the reconciliation spec, so the prototype's "LIVE ON
THIS BLOCK" reports list and "BLOCK CHATTER" thread (the app's most-tapped detail surface, per the
product's own block-by-block design) will silently not exist even after S13 unless it's explicitly
added to the roadmap now, not discovered during the hero-parity pass itself.
