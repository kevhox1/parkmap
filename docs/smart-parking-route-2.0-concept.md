# Smart Parking Route — "Parking Hunt" (2.0 Concept)

**Status:** Concept / planning doc — NOT a build order. Living document.
**Origin:** Kevin's idea, discussed 2026-06-09.
**Roadmap placement:** flagship feature of a future **2.0 — Smart Parking** release. Sits *after* the
current map rebuild + the hard-TF2 supabase-swift real-time work. Do NOT start before the dependency
foundations (below) are solid.

---

## 1. Vision

Instead of routing the driver point-to-point to a destination, plan a driving path that **maximizes
the odds of landing a good free spot** near the destination (or near the driver's current location).
This is WePark's potential signature differentiator: not "here's your destination," but "here's the
smartest loop to *find free parking* around it."

## 2. What it optimizes (two objectives, jointly)

1. **Coverage** — route through the **most free-parking curb possible** in the target area, so the
   driver passes the maximum number of candidate blocks. More legal-free curb seen = higher chance an
   actual open spot appears. Coverage is the proxy for real-world availability when we don't (yet) know
   physical occupancy.
2. **Durability** — bias toward free curb whose **free window lasts longest**: segments whose *next*
   restriction (ASP sweeping, metered hours, no-parking) is furthest in the future. Park where it stays
   legal for hours, not where it flips to a tow-away at 8 AM.

Both anchored to either the **destination** OR the **current location** (same algorithm, different anchor),
and bounded by a **detour budget** (no circling for 20 minutes).

## 3. Formal framing

A **prize-collecting / orienteering route** over a **directed** street graph (one-ways = directed edges):

- Per curb-segment **reward** ≈ `P(free now)` × `f(minutes until next restriction)` × `g(proximity to anchor)`
  [× `P(physically open)` once an occupancy signal exists].
- **Objective:** find the path from origin → (within walking distance of) the anchor that **maximizes
  total collected reward**, subject to one-way directions and a max-detour (time/distance) budget.
- NP-hard in exact form; tractable with heuristics (greedy + local search, or beam search over the graph).

## 4. Data foundation — what we already own vs. net-new

| Input | Status |
|---|---|
| Per-segment "free until X" (durability metric) | ✅ Rules engine already computes it (hardened in FT-9) |
| One-way directions / directed street graph | ✅ `osm_oneway.json` + tiles |
| Free/metered/restricted classification | ✅ Rules engine |
| **Orienteering solver over the directed graph** | 🔴 Net-new (the core of this feature) |
| **Physical occupancy signal** (is a spot actually open?) | 🔴 Net-new — Tier 3 `open_spot` crowd data |
| Drivable native map + smooth nav (to *drive* the hunt route) | ✅ Map rebuild (build 6) |

## 5. Phasing within the feature

- **v1 — legality + durability + coverage heuristic.** Ships on data we have *today*: optimize purely on
  legal-free + durability + coverage + detour budget. No occupancy. Already genuinely useful.
- **v2 — add live occupancy.** Once Tier 3 `open_spot` exists, fold `P(physically open)` into the reward
  so it routes toward spots that are *actually* open, not just legally free.

## 6. Dependency chain (gates before this starts)

1. Core app + **supabase-swift real-time** (hard TF2 requirement) — needed for any live signal.
2. Native map + smooth nav follow — ✅ done (map rebuild Phase 1/2, build 5/6).
3. Tier 3 **`open_spot`** occupancy signal — for the v2 occupancy layer (v1 can ship without it).
4. A proper **tech-lead feasibility spec** (scoring function, heuristic choice, detour-budget UX,
   integration with Mapbox/MapKit routing + the rules engine) before any code.

## 7. Open scoping questions (Kevin — for when we spec it)

- **OQ-A — Detour budget:** how much extra driving is acceptable in a hunt? A hard cap (e.g. "≤5 min /
  ≤0.5 mi of circling") shapes the entire optimization. (Unanswered.)
- **OQ-B — Walk-vs-drive tradeoff:** is a longer-lasting free spot 3 blocks away better than a
  soon-to-restrict spot right out front? Defines how durability is weighed against walking distance.
  (Unanswered.)
- **OQ-C — Occupancy timing:** ship coverage-only first (v1, maximize exposure, no occupancy), or wait
  for the crowd `open_spot` signal to make it "route to an actually-open spot" (v2)? Leaning: ship v1
  early on data we have, layer occupancy later. (Unanswered.)

## 8. Notes / risks

- Occupancy is the hard, unsolved part of all parking apps; v1 sidesteps it by optimizing *exposure*
  (coverage) rather than claiming to know open spots. Set user expectations accordingly.
- Turn restrictions / legal turns may not be in our data — the directed graph covers one-ways but not
  turn bans; the heuristic should tolerate approximate routing.
- This is R&D-flavored; budget for iteration on the scoring function with real drive data.
