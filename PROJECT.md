# WePark — Project Manifest

**Status:** Phase 1 + Phase 2 complete. Tier 3 (Threat Tracker) in progress — Supabase-ready provider layer merged, live backend not yet provisioned.
**Last Updated:** 2026-04-17

## Deploy Status
- **GitHub Repo:** https://github.com/kevhox1/parkmap
- **Live URL:** https://kevhox1.github.io/parkmap/
- **Hosting:** GitHub Pages, auto-deploy on push to `main`
- **Service Worker Cache:** `wepark-v10` (bump on any asset change)

## Data Status
- **Parking Signs:** 17,134 unique (merged ASP + main datasets)
- **Segments:** 12,560 across 976 tiles (~6.39 MB total)
- **Coverage:** All Manhattan including ASP-only streets
- **Tile data:** Pre-built, committed to repo under `tiles/`. Do not regenerate without reason.

## Architecture Snapshot
- Single-file app: `index.html` holds HTML, CSS, JS, and Leaflet bootstrapping
- Service worker at `sw.js` handles offline caching (static + tile caches, network-first for `index.html`, bypass for Supabase hosts)
- `tracker-config.js` selects tracker provider (mock by default, Supabase when credentials supplied)
- Specs and planning docs live at repo root as markdown

## Phase History
- **Phase 1 — PWA & Deploy:** complete 2026-03-27
  - PWA manifest + service worker, GitHub Pages live, mobile UI polish, tile lazy-load
- **Phase 2 — Smart Score / Smart Move / My Car:** complete 2026-04-02
  - Top Blocks ranked panel, Smart Move recommendations, route optimizer, My Car pin + localStorage
- **Tier 3 — Threat Tracker:** in progress
  - [x] Initial tracker slice with mock provider (PR #4, merged 2026-04-07)
  - [x] Supabase-ready provider layer with dynamic supabase-js import, auth gate, realtime hook, SW bypass for live traffic (PR #5, merged 2026-04-17)
  - [x] Tracker QA fixes: Park My Car CTA wire-up, projected point-to-polyline snapping, ASP-window-aware `block_cleaned` aging, narrow-phone bottom-sheet coordination, unified Smart Move engine, future ASP suspensions skipped in next-ASP timing (PR #6, merged 2026-04-17)
  - [x] Production hardening: mock/Supabase shape parity, Supabase init connectivity probe with graceful mock fallback, RPC name cross-check — all 7 match (2026-04-17)
  - [ ] Provision real Supabase project and populate `tracker-config.js` with URL/anon key
  - [ ] Apply `SUPABASE_MVP_SCHEMA.md` in the Supabase SQL editor
  - [ ] Flip `provider` to `supabase` and `authMode` to `anonymous` once anonymous auth is enabled

## Recently Landed
- 2026-04-22 (direct to `main`): replaced TSP with coverage-sweep route planner. Greedy one-way-aware walk through directed graph, ASP prioritized over metered, drawn polyline path + highlighted scanned blocks. SW cache bumped to v10.
- 2026-04-21 (direct to `main`): one-way aware parking route with mini-TSP (held-karp on top 10 candidates, directed street graph from NYC DOT Centerline, A* drive-distance, pass-count bonus). SW cache bumped to v9.
- 2026-04-21 (direct to `main`): fix for `getSegmentMidLatLng` typo blocking all segment rendering since PR #5. SW cache bumped to v8.
- 2026-04-17 (direct to `main`): tracker production hardening — mock/Supabase shape parity, Supabase init connectivity probe, SW cache bumped to v7
- PR #6 (`aa7c5bd`): tracker QA fixes
- PR #5 (`a45098b`): Supabase-ready tracker provider + live-data plumbing, SW cache v6
- PR #4 (`f8ba00b`): initial threat tracker slice (mock provider)

## Source of Truth
- `PROJECT.md` — this file, high-level project status
- `HANDOFF.md` — operating manual for any future Claude session
- `PRODUCT.md` — product vision
- `TRACKER_MVP_SPEC.md` — tracker feature spec
- `SUPABASE_MVP_SCHEMA.md` — backend schema + RPC design
- `BACKEND_OPTIONS.md` — backend trade-offs
- `TRACKER_QA_PASS_2.md` — latest independent QA verification (2026-04-17). Supersedes `TRACKER_QA_VERIFY.md`.
