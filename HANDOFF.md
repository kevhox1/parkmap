# WePark — Handoff

This document is the operating manual for any future Claude session working on WePark. **Read this first, then any spec doc in `docs/` for the feature in flight, then continue.** Don't reload chat history — the docs + git log are the source of truth.

## Session opening protocol

When Kevin starts a new session, default response:
> "Read `HANDOFF.md`, then `docs/<current-feature>.md`, then continue building."

Don't re-derive specs from chat memory. The docs are the source.

## Project Overview

WePark is **a community-driven parking app for NYC street parkers**. The product has three layers, in order of importance to the user:

1. **Parked-car management** (daily-active hook) — Smart Move, ASP-suspension banner, My Car pin, sign verification. Replaces the user's reliance on Twitter (for ASP suspensions) and Calendar (for "move your car" alarms).
2. **Community** (the moat) — pseudonymous neighborhood chat per zone, structured tracker reports (sweeper / ticket-agent / block-cleaned), reputation scoring, real-time alerts.
3. **Driving Mode** (the in-car experience, _NEW priority as of 2026-04-26_) — full-screen, glanceable, voice-narrated. Tells the driver what parking is on the LEFT and RIGHT of the street they're currently on, framed as "free until X" actionable answers.

**Distribution:** PWA (live at https://kevhox1.github.io/parkmap/) → Capacitor wrap for iOS App Store → eventual native iOS rewrite. Repo: https://github.com/kevhox1/parkmap.

## Current MVP roadmap (state-of-world)

**Shipped:**
- ✅ Phase 1 (PWA + tile-based map + ASP suspension data load)
- ✅ Phase 2 (Smart Score, Smart Move, My Car, Find Parking Near Me with one-way-aware coverage sweep)
- ✅ Phase 3 (Threat Tracker UI, mock provider, Supabase-ready provider with connectivity probe)
- ✅ ASP suspension banner (kills Twitter dependency)
- ✅ PWA install hint (iOS Add-to-Home-Screen prompt)
- ✅ Email magic-link auth + pseudonymous username + `profiles` table
- ✅ SOHO/LES zone chat with Supabase Realtime
- ✅ Self-healing service worker (auto-update + version chip + one-tap escape hatch)

**Live blockers / waiting on Kevin:**
- ⏳ Kevin needs to **end-to-end test sign-in + chat on real device** (was wedged on cache; v19 ships self-healing SW, should now work after one final clear)

**In flight:**
- 🚧 **Driving Mode v1** (the active feature). See `docs/driving-mode.md` for spec.

**Backlog (not started, ordered by priority):**
- Cross-pollination: tracker reports auto-post to zone chat as `system_tracker` messages (requires applying full `SUPABASE_MVP_SCHEMA.md` for tracker tables + flipping provider to `'supabase'`)
- Reputation scoring (+/− on confirms/retracts)
- Local "move your car" notifications (Web Notifications API)
- "Generate QR code for my zone" feature (cold-start distribution)
- First-time user landing page with seeded zone preview
- Capacitor wrap → TestFlight → App Store

## Live infrastructure

- **GitHub Pages:** https://kevhox1.github.io/parkmap (auto-deploys on push to `main`)
- **Supabase project:** `https://jiispshyqerscdoferaw.supabase.co` (created 2026-04-22, free tier)
  - Tables: `profiles`, `zones`, `zone_messages` (chat schema)
  - Tracker tables NOT yet applied — `SUPABASE_MVP_SCHEMA.md` is the spec but unapplied
  - Realtime publication includes `zone_messages`
  - Auth Site URL: `https://kevhox1.github.io/parkmap/`
- **Tracker provider:** still `'mock'` (localStorage). Flip to `'supabase'` after applying tracker schema.
- **Mapbox token (Drive Mode v3):** stored at runtime in `localStorage.wepark_mapbox_token`. Created 2026-05-01, public token, URL-restricted to `kevhox1.github.io` + `localhost:8765`. **NOT committed to source** — GitHub's push protection blocks `pk.*` Mapbox tokens even though they're designed to be public, so we read from localStorage instead. The Drive Mode v3 build (per `docs/drive-mode-routing.md`) will surface a "🗝️ Set Mapbox token" UI flow on first use; in the meantime Kevin can preset it via `localStorage.setItem('wepark_mapbox_token', '<the_pk_string>')` in DevTools.

## How to work in this repo

- **Single-file architecture.** `index.html` contains the HTML, CSS, and all application JS. Don't split it into modules without an explicit conversation with Kevin. The file is ~186KB and that's fine.
- **Service worker cache version must be bumped on every asset change.** Edit `CACHE_VERSION` at the top of `sw.js` AND `APP_VERSION` in index.html (currently both `wepark-v23`). The two should match — the page compares them to detect updates and auto-reload. SW now self-heals: on activation it broadcasts to all clients which auto-reload to pick up fresh code. No more manual cache-clearing. Without a bump, users get stale versions via the cache-first strategy on tiles and stale static assets on intermittent network.
- **Tile data is pre-built and committed.** The `tiles/` directory holds 976 pre-generated JSON tiles (~6.39 MB). Don't regenerate unless Kevin has changed upstream NYC source data or the tiling algorithm — regeneration is expensive and the churn is large.
- **No automated test suite exists.** QA is done via:
  - Independent QA subagent review (see `TRACKER_QA_VERIFY.md` for the pattern)
  - Manual smoke on the live site after deploy
  - Code review in PRs
  Never let the agent that built a feature also sign off on it — spawn a separate QA subagent.
- **Deploy target: GitHub Pages, auto-deploy on push to `main`.** There is no build step. `.nojekyll` is present so GitHub Pages serves files as-is.
- **Specs live at the repo root.** Key docs:
  - `PROJECT.md` — current status, phase checklist
  - `PRODUCT.md` — product vision
  - `TRACKER_MVP_SPEC.md` — tracker feature spec (read before touching tracker code)
  - `SUPABASE_MVP_SCHEMA.md` — backend tables + RPC functions (the Supabase provider in `index.html` calls the RPC names defined here)
  - `BACKEND_OPTIONS.md` — backend trade-off notes
  - `TRACKER_QA_PASS_2.md` — latest independent QA verification (2026-04-17, against `main` post PR #5/#6). Supersedes the earlier `TRACKER_QA_VERIFY.md` (dated 2026-04-07, pre-PR-#6), which is retained for history only.
- **Branch and PR conventions.**
  - Work on a topic branch off `main`, never push to `main` directly (except docs/PROJECT/handoff updates and SW cache bumps).
  - PR titles follow Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `style:`.
  - Merges to `main` are **squash merges** via `gh pr merge <n> --squash --delete-branch`. The squashed commit ends with ` (#N)`.
  - Separate `chore: bump SW cache to vN` commits are OK and have happened historically.

## Tech stack

- **Frontend:** vanilla JS in a single `index.html`, Leaflet 1.9.4 (loaded from unpkg CDN)
- **PWA:** `manifest.json` + `sw.js` service worker with separate static/tile caches
- **Backend (in progress):** Supabase (Postgres + PostgREST + Realtime + Anonymous Auth). Provider is loaded dynamically as an ESM import from jsdelivr when `tracker-config.js` is set to `provider: 'supabase'`.
- **Tracker provider config:** `tracker-config.js` at repo root — empty creds by default, falls back to local mock
- **Hosting:** GitHub Pages, auto-deploy on push to `main`
- **Data sources:** NYC parking sign data (merged ASP + main), pre-tiled into 976 JSON tiles under `tiles/`

## Changelog

### 2026-05-01 — Drive Mode v2.1 (visual polish)
- Replaced the blue dot user marker with an Apple-Maps-style **🚗 car emoji** in a white circle with a blue ring + pulse outline. Rotates with GPS heading (offset −90° because the car emoji's natural orientation faces east, not north).
- Bumped Drive Mode zoom from 17 → **18** so the current block dominates the view, like Apple Maps in turn-by-turn mode.
- New **side-of-street highlight overlay**: when the current block is detected, both LEFT and RIGHT side polylines are drawn extra-thick (weight 9) on top of the regular map, with a white underglow (weight 14) for legibility, and colored by parking severity (free=green, metered=yellow/orange, restricted=red, unknown=grey). Driver can immediately see which side of the road they should be looking at, with the colors matching the bottom-card text.
- Highlights cleared + redrawn only when the block changes (no per-tick churn).
- Cleanup on Drive Mode exit: highlights removed and pre-entry map view restored.
- New spec file `docs/drive-mode-routing.md` for the v3 build (destination input + Mapbox routing + parking-aware path selection). Build deferred — needs Kevin to create a Mapbox account first.
- SW cache bumped to `wepark-v23`.

### 2026-04-26 — Drive Mode v2 (map-centric, Waze/Google Maps-style)
- v1 missed the mark per first user — black-screen text-card UI lost spatial context. v2 rebuilds Drive Mode as a transparent overlay *on top* of the existing Leaflet map, so the map IS the interface.
- `body.driving-mode` class hides `#controlPanel`, `#startScreen`, `#pwaInstallHint`, `#weparkVersionChip`, and Leaflet zoom controls so the map fills the whole screen.
- `#drivingMode` is now `pointer-events: none` so map gestures pass through; only the floating top bar (✕ Exit, 🔊/🔇 mute) and the floating bottom card opt back into pointer events.
- On entry: stash current map view (center+zoom), set zoom 17, attach a pulsing custom user marker (`L.divIcon` blue dot + heading-rotated arrow + animated pulse ring). On exit: remove marker, restore the prior view.
- `onDrivingGeoUpdate` now `setView`s the map (not just panTo) so zoom stays locked at 17 and the user pin remains centered. Marker icon is rebuilt every tick with the current heading rotation.
- Bottom card replaces the v1 card layout — compact glanceable strip with street name + LEFT/RIGHT actionable rows + speed/accuracy meta. Border-left color band uses the worse-severity of L vs R.
- Voice unchanged from v1 (street-change announcements, rate-limited, mutable).
- Out of v2 scope: map auto-rotation by heading (Leaflet doesn't natively rotate; would need a plugin or CSS transform — deferred to v3 if user wants it). Streets are colored by parking category via the existing rules layer; no extra current-street highlight in v2.
- SW cache bumped to `wepark-v22`.

### 2026-04-26 — Driving Mode v1 (PoC, abandoned same day)
- After real user feedback ("incredibly difficult to use live in the car"), introduced a separate full-screen **Driving Mode** view optimized for a phone propped on a dashboard mount. Spec: `docs/driving-mode.md`.
- Entry: 🚗 Driving Mode button at the top of the panel body. Tap → request GPS + screen wake-lock → full-screen overlay takes over.
- UI strips everything except the actionable info: giant street name, color band (green/yellow/red), LEFT side label, RIGHT side label. No map, no tabs, no chat — read-only, glanceable.
- LEFT/RIGHT computed from GPS heading (`coords.heading`) vs each side polyline's compass bearing (W/E/N/S). Falls back to N/W=Left, S/E=Right if heading unavailable (e.g., user stopped).
- New `actionableSafetyLabel(seg)` returns `{ text, severity }`. Reuses `computeNextRestrictionHours` and `meteredStatusLabel`. Examples: "Free until Thu 9:30am", "Metered until 7pm", "Free until 9am" (overnight metered), "No parking", "No standing".
- New `getCurrentDrivingContext(lat, lng, heading)` resolves the user's current block (street + from + to) via `findClosestSegment`, then both side segments via `findSegmentByBlock`, then assigns LEFT/RIGHT.
- Voice via `window.speechSynthesis`, fired only on block change (not every GPS tick), rate-limited to once per 12s, mutable via 🔊/🔇 button (preference persisted in localStorage). Format: "Bowery. Left side, free until Thursday 9:30am. Right side, metered until 7pm."
- Wake lock acquired on entry (`navigator.wakeLock`); re-acquired on tab visibility change; released on exit.
- Map auto-pans to user's GPS location while in driving mode so tiles for the current area keep loading.
- Out of v1 scope: turn-by-turn navigation, pre-set "intent" mode, voice commands, "Park here now" auto-detect.
- SW cache bumped to `wepark-v20`.

### 2026-04-22 — Park-pin & route polish
- **Park pin no longer snaps.** The "Park My Car Here" flow used to snap the marker onto the side polyline of the auto-detected segment after the user confirmed N/S/E/W. At corners and intersections this could move the marker 30-50m away from where the user actually tapped (and onto the wrong street). The marker now stays at the exact lat/lng the user picked. The detected segment is still used for parking-rules lookup but no longer for visual placement.
- **"Wrong street?" alternatives in the park modal.** New `findCandidateSegments(lat, lng, radius=35, max=4)` returns the closest unique blocks within 35m of the pin. The park modal renders any non-default candidate as a button ("Wrong street? Pick another nearby block: 1ST AVENUE (33m)"). Clicking switches `_parkDetectedSeg` and re-renders side options. Fixes the corner-detection ambiguity Kevin flagged.
- **Route excludes the block you're already parked on.** `scoreEdgeCoverage(edgeId, skipBlockKey)` now accepts a skip key built from `parkedBlock.street|from|to`. The route generator passes it in so the algorithm doesn't say "scan this block at 0m" for the spot you're already in.
- **Metered status label fix.** `computeNextRestrictionHours` intentionally `continue`s on METERED rules ("not a move-your-car restriction"), so pure-metered blocks returned the default `168h`. The route sidebar now uses a new helper `meteredStatusLabel(seg)` that shows: `Metered (paid until 7pm)` when active, `Metered (free until 9am)` when not, `Metered (free for Nd)` if next activation is far. No more 168h on any metered block.
- **`attachBlockFacesToEdges` cache fix.** First-route runtime was 2.8s due to rebuilding the canonical-name index on every call. Now built once per session into `streetGraph._edgesByCanonStreet`, then reused. Subsequent route requests run in ~235ms even when segmentLayers grows.
- SW cache bumped to `wepark-v11`.

### 2026-04-22 — Coverage-sweep route planner (replaces TSP)
- The "Find Parking Near Me" route now uses a **greedy coverage sweep** instead of held-karp TSP on top-10 candidates. Reasoning: the TSP-on-waypoints model produced routes that backtracked oddly and over-weighted metered blocks (`168h × 1` was beating `48h × 3` ASP scores). Real parking-search behavior is a coverage sweep — drive a logical loop, scan whatever's good along the way.
- New flow:
  1. `attachBlockFacesToEdges()` matches loaded block-face segments to the directed graph edges they cover (canonical street name + midpoint distance ≤ 60m). Cached on `segmentLayers.length`; the canonical-name index `_edgesByCanonStreet` is built once and reused.
  2. `scoreEdgeCoverage(edgeId)` returns a coverage value: ASP-done blocks get +10 each, ASP-soon scaled +1 to +8, **metered blocks get +0.5** (intentionally bottom-of-the-rank). Active restrictions and No Standing/Truck/Special blocks score 0.
  3. Greedy walk: at each intersection, pick the highest-scoring unvisited outgoing edge; ban immediate U-turns; heavily penalize revisits (-100 × visit count); past 60% of distance budget, bias toward edges that close the gap to the start point. Stops at 2.5 km total OR when within 90m of start after ≥600m driven.
- Rendered as a **single drawn polyline** (green path with white underglow) following actual streets, plus colored highlights on every scanned block face: `#15803d` for ASP done, `#65a30d` for ASP soon, `#0ea5e9` for metered. Start pin is a small green dot. No more numbered destination markers.
- Sidebar info shows: total distance + drive time, summary count of ASP-done / ASP-soon / metered blocks, collapsed turn-by-turn (consecutive same-street steps merged), and a collapsible "Scanned blocks" list. Google Maps / Apple Maps deep-link uses every Nth intersection along the path so the external map traces the same route.
- **Smoke test from 217 Bowery**: 14 blocks scanned (3 ASP done ✅, 11 ASP soon, 0 metered), 1.0 km / ~4 min drive, loop closes 85m from start. Path: Stanton → Chrystie → Houston → Forsyth → Chrystie → Rivington → Bowery → Spring → Bowery. Initial route ~2.8s due to 17K-edge canonical-name index build; subsequent calls are fast since `_edgesByCanonStreet` is cached.
- SW cache bumped to `wepark-v10`.
- **Known gaps** to revisit: (a) the algorithm should drop "current parking block" from candidates so it doesn't say "scan this block you're already on" at 0m; (b) `computeNextRestrictionHours` returning 168h for some metered blocks looks suspicious — needs a check on weekend/holiday boundary cases; (c) cache could be invalidated incrementally as tiles load (right now we wait until full route request to attach).

### 2026-04-21 — One-way aware parking route with mini-TSP
- `osm_oneway.json` added (1.25 MB): Manhattan street geometry + per-segment direction (`FT`/`TF`/`TW`) pulled from NYC DOT Centerline (CSCL) dataset `inkn-q76z`. 12,203 rows → 1,088 unique streets, 12,245 way-segments after excluding non-vehicular (NV). Build script at `scripts/build-oneway-data.js` — re-run when NYC updates the centerline (quarterly).
- Street-name canonicalizer added. `canonicalStreetName` converts both tile-data names (`1ST AVENUE`, `CHRYSTIE STREET`) and centerline names (`1 AVE`, `CHRYSTIE ST`) to a single canonical form (`1 AVE`, `CHRYSTIE ST`). Known alias: `AVE OF THE AMERICAS` → `6 AVE`. Join rate to tile data: ~97.5%.
- `loadStreetGraph()` runs in parallel with `loadTileIndex` and `loadASPSuspensions` during init. Builds a directed graph: nodes = intersections snapped to 4-decimal grid (~11m), edges = directed street segments based on `oneway` flag. Current numbers: 17,326 intersections, 26,474 directed edges.
- `driveDistance(from, to)` computes meters of drive distance respecting one-ways. Backed by A* search (binary-heap priority queue, haversine heuristic). Capped at 4km / 3000 nodes per query to prevent runaway. Falls back to crow-flies if graph isn't loaded, or crow × 1.5 if the query is within-budget unreachable. Per-query runtime ~1-5ms.
- `generateParkingRoute()` replaces polar-angle sort with held-karp mini-TSP on the top 10 candidates (open path starting from the user, ending anywhere). 11×11 drive-distance matrix built via `driveDistance`. TSP DP is O(2^N · N²) = ~10k ops, runs in <5ms. Full route generation (including rendering) measured at ~170ms.
- Pass-count bonus added: pre-TSP, any two candidates on the same street within 250m boost each other's routeScore by 1.25×. Encourages the router to pick "two-for-one" scan opportunities.
- Verified end-to-end: going north on 1 AVE (one-way uptown) = 2054m; going south (must detour via 2 AVE) = 2550m. One-way honored. Fallback verified by stubbing `streetGraph = null`: app falls back to crow-flies without error.
- SW cache bumped to `wepark-v9`; `osm_oneway.json` added to static-asset precache.

### 2026-04-17 — Tracker production hardening (pre-Supabase)
- Mock provider output now routes through `normalizeTrackerReport` / `normalizeTrackerDetail` for every read and write path (`getActiveReportsForBounds`, `getBlockFaceDetail`, `getNearbyFeed`, `createReport`, `confirmReport`, `retractReport`). Mock and Supabase now return identical shapes — `trackerDetailCache` and downstream UI can't diverge between the two.
- Supabase provider `init()` now runs a connectivity probe (one lightweight `tracker_get_active_reports_in_bbox` RPC with a 4-second timeout). Bogus creds, unreachable URLs, missing schema, or bad anon keys now throw during init instead of silently passing and failing on every runtime call. `initTracker()` catches the throw and falls back to the mock provider when `allowMockFallback` is true. Verified end-to-end in local smoke: bogus `https://*.supabase.co` URL + bogus anon key → probe throws `supabase_unreachable` in ~130ms → mock takes over cleanly.
- RPC name / signature cross-check between `index.html` Supabase provider and `SUPABASE_MVP_SCHEMA.md` — all 7 RPCs match (names and parameter names). No schema doc changes required.
- SUPABASE_MVP_SCHEMA.md now flags the JS mock as the reference implementation for merge/conflict/dedupe semantics; SQL RPCs must match its behavior.
- SW cache bumped to `wepark-v7`.

### 2026-04-17 — Post-merge QA audit of threat tracker
- `TRACKER_QA_PASS_2.md` added. Fresh QA pass against `main` at `1f8b005` (post PR #5 + PR #6). All six previously-open issues from `TRACKER_QA_VERIFY.md` verified as structurally resolved in code. 10 new low-severity observations logged (provider shape divergence between mock and Supabase; legacy config shim; mock-only `seedReports`; etc.). Verdict: qualified yes for real Supabase wire-up, pending two live smoke checks (mock-vs-Supabase detail-shape normalization + Supabase-bad-creds → mock-fallback).

### 2026-04-17 — Supabase-ready tracker provider + QA fixes
- PR #5 (`a45098b`): real Supabase tracker provider with dynamic `supabase-js` import, auth gate state API, RPC wrappers for `tracker_get_active_reports_in_bbox` / `tracker_get_block_face_detail` / `tracker_get_nearby_feed` / `tracker_create_report` / `tracker_mark_block_cleaned` / `tracker_confirm_report` / `tracker_retract_report`, optional realtime channel. `tracker-config.js` introduced to select provider and hold creds. Graceful fallback to local mock if init fails. SW now bypasses Supabase hosts (never cache `*.supabase.co` / `/rest/v1/` / `/auth/v1/` / `/realtime/v1/` / `/functions/v1/` / `/storage/v1/`). SW cache bumped to `wepark-v6`. Tile cache state changed from boolean to `'loading' | 'loaded'` with cleanup on fetch failure so failed tiles can retry within a session.
- PR #6 (`aa7c5bd`): tracker QA follow-ups. Park My Car CTA now wired to `parkCarHere()` (one-tap pin flow) instead of the modal. Block-face nearest-segment detection now uses projected point-to-polyline distance (`getClosestPointOnSegmentGeometry`) instead of nearest vertex only. `block_cleaned` aging respects `asp_window_end_at` instead of generic 10-minute stale rule. ASP next-restriction timing walks 14 future days, skips `isASPSuspended` dates, and honors `rule.days`. Smart Move button and panel now share `computeSmartMove()` output. Narrow-phone bottom-sheet coordination via `isCompactBottomSheetLayout()` / `syncResponsivePanels()` so only one sheet is visible at a time on small screens. `showBlockInfo` wraps tracker detail + auth fetch in try/catch so backend failures don't crash the block popup.

### 2026-04-07 — Initial threat tracker slice
- PR #4 (`f8ba00b`): first tracker slice. Mock provider with localStorage persistence, auth gate, tracker overlay on the map, feed panel with nearby reports, report composer for sweeper / ticket-agent / block-cleaned events, confirm / retract actions. Provider-abstracted so the Supabase one can drop in later. SW cache bumped to `wepark-v5` (commit `8720a3a`).

### 2026-04-02 — Street-based Park My Car + cross-street normalization + Top Blocks
- PR #3 (`d6788b0`): Park My Car reworked to take a street name with smart side confirmation.
- PR #2 (`211a73c`): normalized spelled-out cross streets (`FIRST AVENUE` ↔ `1ST AVENUE`, etc.) so block-face matching stops dropping entire sides of the street.
- PR #1 (`5746e1d`): Top Blocks ranked panel for Smart Score mode.
- SW cache bumped to `wepark-v4` (commit `179904c`) and `wepark-v3` earlier.

### Pre-April 2026 — Phase 1 & Phase 2 foundations
- Phase 1 (2026-03-27): PWA manifest, service worker, GitHub Pages deploy, mobile UI polish, tile-based lazy load.
- Phase 2 (through 2026-04-02): Smart Move, Smart Score, My Car pin with localStorage, route optimizer.
- Data pipeline fixes along the way: dedup bug dropping ~50% of signs (`dc16002`), sub-segmentation bug dropping ~75% (`f65d08f`), merging ASP-only streets into the main dataset (`c33c6f3`), Jekyll bypass via `.nojekyll` (`ac76cde`).

## Open questions / known gaps

- **Supabase not provisioned.** `tracker-config.js` still has empty `supabaseUrl` / `supabaseAnonKey`. Before flipping `provider` to `'supabase'`, Kevin needs to: create the Supabase project, apply `SUPABASE_MVP_SCHEMA.md`, enable anonymous auth, and populate the config. RPC names are already verified to match between provider and schema.
- **No automated tests.** If behavior-critical work lands, consider what lightweight in-browser smoke coverage would be worth adding (e.g., a manual QA checklist per PR, or a small hand-written test harness loaded behind a URL flag).
- **PROJECT.md freshness cadence is manual.** It gets stale unless updated as part of the PR that changes things. Consider making it a checklist item in PR descriptions.
- **SW cache discipline.** Tile freshness depends on bumping `CACHE_VERSION` when tile data changes. No automatic invalidation on content hash. TRACKER_QA_VERIFY flagged this as an unresolved concern.
- **Tracker QA gaps that were closed in PR #6 but not independently re-verified post-merge.** The QA agent that wrote `TRACKER_QA_VERIFY.md` reviewed an older snapshot. A fresh QA pass against `main` post-#6 would be worth doing before the real Supabase wire-up.

## Quick start for a new session

Tell a new Claude:

> Read `HANDOFF.md`, `PROJECT.md`, and `TRACKER_MVP_SPEC.md` at the repo root. Then ask me what we're working on. Don't push to `main`; use a topic branch and a squash-merged PR. Bump `CACHE_VERSION` in `sw.js` on any asset change.
