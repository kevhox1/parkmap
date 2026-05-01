# Drive Mode v3 — Destination Input + Parking-Aware Routing

**Status:** spec drafted 2026-04-26 (post v2.1 ship). Build deferred to a future session.
**Owner:** Kevin (product), Claude (build)

## Why this spec exists separately from `driving-mode.md`

v1 = text-card UI (abandoned).
v2 = map-centric overlay with current-block info (shipped 2026-04-26).
v2.1 = car icon, emphasized side highlights, closer zoom (shipped 2026-04-26).

**v3 is a substantially bigger scope** — destination input, real routing, voice turn-by-turn, parking-aware path selection. Belongs in its own spec doc so the build can be staged carefully without exploding the main driving-mode doc.

## Vision (Kevin's words, paraphrased)

> "I should be able to enter Drive Mode and input a destination. The app loads a path I can follow that maximizes the number of free parking spots I cross or loop through near that destination. As I drive, the live map updates, and the voice tells me 'left side free parking until X, right side no parking, turn left on Prince…'"

Two coupled jobs:
1. **Get me to my destination.** Real navigation with turn-by-turn.
2. **Maximize free-parking exposure along the way and once near.** This is what makes us different from Apple Maps.

## High-level approach: Mapbox + our parking layer (hybrid)

Per Kevin's call:
- **Mapbox Directions API** for the actual route (production-quality routes, real turn-by-turn voice, real ETAs, traffic-aware). Costs money beyond the free tier (free: 100k requests/month for Directions; ~$0.50/1k after that). Free tier easily covers single-user testing.
- **Our parking layer on top.** Once we have a Mapbox route, we score every block face along the route + within a configurable radius near the destination, and:
  - Rate the route on "parking exposure" (how many free blocks does this route pass?)
  - Optionally bias the route toward better-exposure paths (Mapbox supports waypoints, so we can re-route through parking-rich blocks)
  - Generate the parking voice cues that overlay the Mapbox turn voice ("left side free until 7pm")

## Architecture

### 1. Inputs (entry to Drive Mode)
- Prompt: "Where are you headed?" with skip option
- Address autocomplete via Mapbox Geocoding API (or Nominatim free fallback)
- Recent destinations stored in localStorage
- Map long-press to drop a pin (later)

### 2. Initial route planning (when destination set)
- Call Mapbox Directions API: from = current GPS, to = destination
- Receive route geometry (LineString of lat/lngs) + step list (turns + distances)
- Evaluate the route against our parking layer:
  - Buffer the route polyline by ~30m
  - Find all block-face segments that intersect the buffer
  - Score each via existing `actionableSafetyLabel` + ASP-done preference
  - Sum to a "parking exposure score"
- If we have time/budget, ask Mapbox for ALTERNATE routes (`alternatives=true`) and pick the one with the highest parking-exposure score
- Render the chosen route as a thick blue polyline on the map (Apple-Maps style)
- Render the destination as a red pin
- Render the "park-here" target block (highest-scoring block within 300m of destination) with a green pulse

### 3. During driving
- Mapbox Voice Instructions API speaks turns: "Turn left on Prince Street in 200 feet."
- Our parking voice speaks side-of-street info: "Left side free until 7pm. Right side no parking."
- Combined timing: Mapbox turn cues take priority within ~150m of a turn; otherwise our parking cues fire on block change.
- If user deviates from the route by >30m for >5s → re-route via Mapbox.

### 4. On arrival
- When user is within 50m of the park-here target block AND speed = 0 for >10s, prompt: "Park here? (auto-marks My Car pin)"

## Data flow (sequence)

```
[user enters dest] → [Mapbox Geocoding] → [destination latlng]
   → [Mapbox Directions w/ alternatives=true] → [routes[]]
   → [for each route, compute parking-exposure-score using our segmentLayers]
   → [pick highest-score route]
   → [render route + destination pin + park-here-target on map]
   → [start GPS watch]
   → [for each GPS tick]:
        ↓
        [if off-route by >30m for >5s] → [re-route via Mapbox]
        ↓
        [advance step pointer in Mapbox steps[]]
        ↓
        [voice: turn cues from Mapbox + our parking cues from current block]
```

## Cost / rate-limit model

- Mapbox Directions: 100k free requests/month. We hit this only on initial-route + re-route, not per-tick. For a single user driving 5 trips/day = 150 Directions calls/month. We're fine.
- Mapbox Geocoding: 100k free/month. One call per destination entry. Tiny.
- Mapbox Tile API: 50k tile loads/month free. Currently we use OpenStreetMap CARTO tiles (free, no key) — leave them as is unless we want Mapbox's tiles for visual consistency.
- Mapbox API key needed: stored at runtime in `localStorage.wepark_mapbox_token`. **NOT in source** because GitHub's secret scanner blocks `pk.*` Mapbox tokens at push time even though they're designed to be public. The v3 build will add a "🗝️ Set Mapbox token" entry UI that prompts the user once and saves to localStorage. Public token, URL-restricted to `kevhox1.github.io` + `localhost:8765` — safe.

## What we already have (reuse)

- `segmentLayers` — block-face data with rules
- `actionableSafetyLabel(seg)` — parking status formatter
- `streetGraph` + `directedShortestPath()` — A* on directed graph (fallback router if Mapbox is unavailable)
- `osm_oneway.json` — directed graph data
- Voice synthesis infrastructure (`speakDrivingContext`)
- Wake lock + GPS watch + driving-mode overlay (v2.1)
- Bottom card layout

## What's new in v3

- Mapbox Directions API integration (~80 lines of fetch + parsing)
- Mapbox Geocoding API integration (~30 lines)
- Destination input modal/UI (~50 lines + CSS)
- Route polyline rendering + destination pin (~40 lines)
- Parking-exposure scorer (~60 lines)
- Re-route on deviation (~30 lines)
- Combined voice cue scheduling (turn cues + parking cues) (~50 lines)
- Park-here target detection + arrival prompt (~30 lines)

Estimated total: ~370 lines + tests + drive-test iterations.

## Phased delivery

**Phase 3a — Destination input + simple route render** (~half day)
- Modal on Drive Mode entry with destination input + skip
- Mapbox Geocoding wired
- Mapbox Directions called once
- Route drawn on map; destination pinned; target block highlighted
- No turn-by-turn voice yet; user just sees the path

**Phase 3b — Turn-by-turn voice** (~half day)
- Parse Mapbox steps[] and trigger voice on approach
- Coordinate with existing parking voice (turn cues take priority within 150m)

**Phase 3c — Parking-aware route selection** (~half day)
- Request `alternatives=true` from Mapbox
- Score each alternate route by parking exposure
- Pick best route

**Phase 3d — Re-routing on deviation** (~half day)
- Off-route detection
- Auto re-route call to Mapbox

**Phase 3e — Arrival logic** (~quarter day)
- Detect arrival at park-here target
- Prompt to set My Car pin

Total: ~2-3 days of focused work for a working v3.

## Open questions to resolve before build

1. **Mapbox API key sourcing.** Kevin needs to create a Mapbox account (free) and provide a public access token. This is a 5-minute step but blocks the build.
2. **Free-parking exposure scoring weight.** When we score routes, what weighs more — total free blocks crossed, or proximity of best block to actual destination? Kevin's intuition: max blocks crossed. Worth confirming.
3. **Park-here target distance threshold.** How far from destination is "good enough"? My default: 300m (~3-min walk). Kevin to confirm.
4. **Voice priority.** When a turn cue and a block-status cue collide within 5s of each other, which wins? My default: turn cue wins; block cue suppressed for that one block.

## Out of v3 scope

- Multi-stop trips ("first stop here, then there")
- Saved destinations / favorites (just localStorage of recent for now)
- Sharing route with another user via the chat
- Real-time traffic visualization (Mapbox provides it, but adds noise to a parking-focused UI)
- Lane-level guidance ("merge right two lanes")
