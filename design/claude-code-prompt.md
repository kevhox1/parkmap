# WePark — Community Network Build (Hero Feature)

Paste everything below the line into Claude Code as the opening prompt for the build conversation. It assumes the repo is `kevhox1/parkmap` and Claude Code has it checked out.

---

## Context

You are building the community/network layer for WePark, an iOS street-parking app for NYC (SwiftUI + MapKit, Supabase backend). The app already ships: a curb-colored map (red/amber/green/orange/gray per blockface, computed from parking rules), Park Here + My Car pin, reminder offsets (15m/30m/1h/2h/night-before), Park Until map recoloring, and an ASP banner.

An interactive design prototype defines the target UX. Match it closely — it encodes deliberate decisions. Where this prompt and the prototype disagree, ask before choosing.

**Design references (committed under `design/`):**
- `design/prototype.html` (+ `support.js`, `ios-frame.jsx` it loads) — the working prototype. You cannot render it; read the source instead. It contains the exact hex values, spacing, corner radii, copy strings, TTL numbers, report-flow steps, and notification-gating logic as working code. Lift values verbatim.
- `design/screenshots/*.png` — how each state must look. Filenames map to surfaces (01-home-collapsed, 04-feed-half, 08-report-grid, 11-spot-confirm, …). View these for visual truth; the HTML for values.

**Before writing any code:** read `PRODUCT.md`, `docs/community-1.0-direction.md`, `docs/nyc-neighbors-incentives-concept.md`, the `CommunityPin` model, `ParkingColors`, and `ReminderOffsets`. Your work must extend these, not parallel them.

## Product rules (non-negotiable)

1. **The curb color encoding is sacred.** Red/amber/green/orange/gray mean legality states and nothing else. Community UI uses blue (self/actions) and per-pin-type ring colors. Never introduce a new color that could be confused with the legality palette.
2. **No spot holding.** "Leaving soon" pins are informational; first come, first served. No reservations, no payments between users, ever. Copy must say this.
3. **Reports are the nouns; chat is commentary.** Every message anchors to a blockface. No free-floating chat, no DMs in v1.
4. **No accounts.** Identity is an opt-in local handle + avatar (device-scoped, e.g. anonymous Supabase auth or device UUID). Asked once, at first contribution — never at launch.
5. **Relevance gates notifications.** Push only when a report touches the user's parked car's blockface. Route-relevant → in-app card. Same-square → feed/map only. Zone-wide (ASP, snow) → top banner. Never push a stranger's report two blocks away.
6. **Reports decay.** Every ephemeral report has a TTL (enforcement ~45m, sweeper ~2h, open spot ~3m, leaving-soon = stated minutes + 3). Confirms extend within a cap; "gone" votes accelerate expiry. Closures/notes are durable until removed.
7. **Don't regress the core app.** The solo experience (map, park, remind) must work identically with zero community data. Every community surface must degrade gracefully to empty.

## Architecture guardrails

- Feature-flag the entire layer behind `communityEnabled` (remote config or local constant) so it can ship dark.
- All community features live in their own module/folder (`Community/`), touching existing views only at defined seams: bottom sheet content, map overlay layer, notification router.
- Zones ("squares") are fixed named polygons seeded from NYC NTA boundaries (~15–30 blocks). Schema keys on `zone_id`. Do not build dynamic/radius-based grouping — splitting zones is a data operation, not a code path.
- One Supabase Realtime channel per zone. Reports, confirms, and chat all flow through it. Design the tables so a zone split is a row update.
- Reputation is server-computed (accuracy of confirmed vs. disputed reports, tenure, helped count). The client only displays it. Never trust client-supplied rep.
- Rate-limit contributions server-side (e.g. N reports/hour/device) from day one.

## Build phases — one PR each, in order, with my review between

**Phase 0 — Schema + plumbing (no UI).** Tables: `zones`, `reports` (type, blockface_id, position_fraction, note, heading_toward, ttl, created_by, expires_at), `report_votes` (confirm/gone), `messages` (blockface-anchored), `profiles` (handle, avatar, device id). RLS policies. TTL expiry via scheduled function. Seed 3 zones (Nolita, SoHo, LES). Acceptance: CRUD + realtime round-trip from a test script; zero app changes.

**Phase 1 — Read-only network.** Community pins render on the map (ringed dots, per-type icon; fresh pins pulse, expiring pins fade). Crew feed section in the bottom sheet (zone name, parker count, report cards + chatter, newest first). Zone switcher chips. Map key entry point. Acceptance: a report inserted server-side appears on-map and in-feed live; empty zones look intentional, not broken.

**Phase 2 — Contribution.** Report flow: type grid (enforcement / sweeper passed / spot open / closure) → confirm-the-street step (guessed blockface + opposite side + neighbors) → direction picker for sweeper/enforcement (toward cross-street A/B/not sure). Spot-open uses map pin placement: sheet drops, "tap the curb," pin snaps to nearest curbline at the tapped fraction, confirm card auto-names the position (nearest storefront via MapKit POI, else "near {cross street}" / "mid-block"). First contribution triggers the handle/avatar sheet (skippable → post anonymously). Acceptance: two devices — a report placed on one appears correctly positioned on the other in <2s.

**Phase 3 — Trust loop.** Confirm/gone buttons on ephemeral reports (in feed + block detail). Parked-on-that-block users get the confirm prompt card. Rep changes (+5 report, +2 confirm, penalties on disputed) computed server-side. Profile row (handle, tenure, accuracy, helped count, rep) in the sheet. Weekly zone leaderboard. Acceptance: confirms extend TTL, gone-votes shorten it, rep updates propagate.

**Phase 4 — Notifications + handoff.** The relevance router (rule 5). Sweeper-passed push for parked users with confirm action. "Leaving soon" flow from My Car (5/10/15/20 min → posts a leaving pin at the car's position). Claim = "I'm heading there" dims the pin for others (informational only). Acceptance: the Tuesday ASP morning sequence from the prototype plays end-to-end on-device.

**Do not build in v1:** photos on reports, DMs, cross-zone posting, karma redemption/incentive payouts, Android, spotter-only mode. Park them in `docs/community-backlog.md` if tempted.

## Working agreement

- Ask before: adding dependencies, touching existing screens beyond the named seams, altering schema after Phase 0, or any deviation from the prototype's UX.
- Every PR: what changed, how to test on-device, screenshots, and which acceptance criteria pass.
- If a phase is estimated to exceed ~1.5k lines of diff, propose a split before starting.
