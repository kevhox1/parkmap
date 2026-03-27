# WePark — Project Manifest

**Status:** Web MVP v2.13 → Phase 1 (PWA + Deploy)  
**Last Updated:** 2026-03-27 15:44 UTC

## Deploy Status
- **GitHub Repo:** https://github.com/kevhox1/parkmap
- **GitHub Pages (default):** https://kevhox1.github.io/parkmap/
- **Custom Domain:** [NEED TO CONFIRM - Kevin, what's the intended domain?]
- **Current Deployment:** NONE (waiting for Phase 1)

## Data Status
- **Parking Signs:** 17,134 unique (merged ASP + main datasets, c33c6f3)
- **Segments:** 12,560 (976 tiles, 6.39 MB)
- **Coverage:** All Manhattan with ASP-only streets (East 3rd, etc.)
- **Last Refresh:** 2026-03-27 12:52 UTC

## Current Version
- **Code:** Single HTML file + Leaflet + Canvas + tile-based loading
- **Filters:** "Free Today", "Free Between", "Park Until"
- **Features (done):** Category classification, side-of-street rendering, block scoring sketch
- **Features (TODO):** PWA, Smart Move, Route optimizer, My Car pin

## Phase 1 Checklist (Start: 2026-03-27 15:44 UTC)
- [ ] PWA manifest (manifest.json + service worker)
- [ ] GitHub Pages deployment
- [ ] Mobile UI polish (touch targets, readability)
- [ ] Tile compression + lazy-load
- [ ] **Target completion:** 2026-03-29 (2-3 days)

## Phase 2 Checklist
- [ ] Block scoring algorithm
- [ ] Smart Move recommendations
- [ ] Route optimizer
- [ ] My Car pin + localStorage
- [ ] **Target completion:** 2026-04-01 (4-5 days)

## How to Read This
**Every time you start work on WePark:**
1. Open `/root/.openclaw/workspace/parkmap/PROJECT.md` (THIS FILE)
2. Check "Deploy Status" + "Phase _ Checklist"
3. Updates are committed with every change

**Kevin:** If you need something updated, tell me and I'll add it here. This is the single source of truth.
