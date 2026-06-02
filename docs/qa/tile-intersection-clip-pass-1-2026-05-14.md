# Tile Intersection Clip QA Pass 1 — 2026-05-14

**Reviewed:** branch `data/tile-intersection-clip` at `ff93fb2` (algorithm: `7b7be02`), against `docs/tile-geometry-investigation.md` §4.1

**Verdict: SHIP CLEAN**

---

## Summary

PR #21 adds a 6-meter longitudinal setback to each end of every block-face polyline during the tile build, exactly as specified in `docs/tile-geometry-investigation.md` §4.1. The algorithm change in `build/preprocess.js` is a faithful translation of the spec's illustrative code with one additional null-guard (`if (!blockGeo) return blockGeo`). The tile rebuild is consistent: `totalTiles` and `totalSegments` match the engineer's reported figures, the `tiles[]` sum cross-checks, all sampled tile JSON files preserve the unchanged segment/rule schema, and the two problem-coordinate samples both show ~6m endpoint displacement away from the intersection centerline. No iOS Swift code was modified. The only mandatory post-merge action is a `sw.js` `CACHE_VERSION` bump — see manual verification gap.

---

## Acceptance criteria checklist

- [x] **INTERSECTION_SETBACK_M = 6 constant present.** Both `INTERSECTION_SETBACK_M = 6` and the derived `INTERSECTION_SETBACK_FT = INTERSECTION_SETBACK_M * 3.28084` are present.
- [x] **`trimIntersectionSetback()` helper defined correctly** — uses `extractSubSegment(blockGeo, INTERSECTION_SETBACK_FT, blockLenFt - INTERSECTION_SETBACK_FT)` and `cumulativeDists()`, both pre-existing helpers. No new geometry code introduced.
- [x] **Called from `getBlockPolyline()` after raw line construction.**
- [x] **Very-short-block guard** — `if (blockLenFt < INTERSECTION_SETBACK_FT * 3) return blockGeo;` present. Blocks shorter than ~59 ft (~18m) are skipped.
- [x] **Trim-failure guard** — `if (!trimmedLine || trimmedLine.length < 2) return blockGeo;` present.
- [x] **Null-guard on blockGeo itself** — `if (!blockGeo) return blockGeo;` added at function entry. Defensive bonus; not a defect.
- [x] **No unintended changes elsewhere in `build/preprocess.js`** — diff is 27 lines: 26 added, 1 removed. No other functions touched.
- [x] **`tiles/index.json` schema unchanged** — top-level keys identical to main.
- [x] **`tiles/index.json` totals match engineer's claims** — `totalTiles: 1029`, `totalSegments: 40121`, `len(tiles[]): 1029`, `sum(tiles[].segmentCount): 40121`. All four self-consistent.
- [x] **Segment schema unchanged** — verified in `tile_0_3.json`, `tile_9_10.json`, `tile_24_20.json`, `tile_50_30.json`. All segments have exactly `{id, street, from, to, side, line, rules, dominantCategory}`. All rules entries have exactly `{category, description, days, timeRanges, anytime, arrow}`.
- [x] **Problem coord sample — E 72nd St / Park Ave S-side** — `EAST_72ND_STREET_PARK_AVENUE_LEXINGTON_AVENUE_S_1` first point shifted from `[40.770932, -73.963517]` (main) to `[40.770906, -73.963455]` (branch). **6.0m east**, exact match to spec's target lng.
- [x] **Problem coord sample — Mott St / Spring St W-side** — `MOTT_STREET_PRINCE_STREET_SPRING_STREET_W_5` terminal shifted from `[40.72162, -73.9955]` (at Spring St centerline) to `[40.721672, -73.995483]` (branch). **6.0m north**, off centerline.
- [x] **No iOS Swift code changed** — 1033 changed files are exactly `build/preprocess.js` + `tiles/index.json` + 1031 tile JSON files.
- [x] **SW cache version not bumped in this PR** — `sw.js` unchanged between branch and main; both carry `CACHE_VERSION = 'wepark-v32'`. Intentional; see finding #1.

---

## Findings

### Blocking

None.

### Significant

None.

### Minor / nit

**#1: SW cache not bumped — must happen post-merge before deploying to production.**
`sw.js` `CACHE_VERSION` is `wepark-v32` on both `main` and this branch. After merging, existing PWA clients with cached tile data will NOT automatically fetch the new tiles. Bump to `wepark-v33` (or equivalent) and redeploy the PWA before/alongside merging. Owner: `@pwa-maintainer`. Severity 🟡 if PWA actively serving users; 🟢 in current TF1-pre-launch context. Must not be forgotten when PWA is back in active deployment.

**#2: Lex Ave 50th-49th W-side — spot-check diffed confusingly due to sign data drift.**
Sub-seg count dropped from 3 to 2 between main and branch. First sub-seg start coordinate appears to have moved ~30m. Root cause: a sign near the E50th end of the block was removed from the live NYC Socrata dataset since the prior tile build, collapsing the first sub-seg boundary. Consistent with documented "live NYC Socrata sign-data drift" cause in the PR description. Not a defect.

### Out of scope (logged, not fixed)

- **OOS-1:** Duplicate terminal coordinates (zero-length tails in `extractSubSegment()` output) — documented in investigation doc §4.2 as deferred cleanup.
- **OOS-2:** Round line cap rendering amplification — investigation doc §4.3 noted as partial rendering workaround only, explicitly deferred.

---

## Sample geometry comparisons

| Location | Main (before) line[0] | Branch (after) line[0] | Shift |
|---|---|---|---|
| E72nd St Park→Lex South side (`_S_1`) | `[40.770932, -73.963517]` | `[40.770906, -73.963455]` | **6.0m** east |
| Mott St Prince→Spring West side (`_W_5` end) | `[40.72162, -73.9955]` | `[40.721672, -73.995483]` | **6.0m** north |

Both shifts are exactly the expected 6-meter setback at NYC latitude (111,320 m/deg lat, ~84,700 m/deg lng at 40.75N).

---

## Smoke tests run

| Test | Outcome |
|---|---|
| `git diff 70cca9a..7b7be02 -- build/preprocess.js` — read full algorithm diff | Pass — matches spec §4.1 exactly plus one extra null-guard |
| `git diff origin/main..origin/data/tile-intersection-clip --name-only` filtered for non-tile/non-build files | Pass — empty; no iOS, no sw.js, no html |
| `tiles/index.json` top-level key set vs. main | Pass — identical schema |
| `tiles/index.json` totals self-consistency | Pass — totalTiles=1029, totalSegments=40121, all four counts match |
| Segment schema in 4 sampled tiles | Pass — no schema drift |
| Rule schema in same 4 tiles | Pass |
| E72nd S_1 start coord shift | Pass — 6.0m, target lng exact match |
| Mott W_5 end coord shift | Pass — 6.0m, moved off Spring St centerline |
| `sw.js` `CACHE_VERSION` unchanged from main | Pass (intentional; see finding #1) |

---

## Manual verification gap

**iOS simulator smoke (Kevin — required before declaring visual artifact resolved):**
1. Pull `data/tile-intersection-clip` or build from `main` post-merge
2. Open iOS app in Simulator
3. Set simulated location to `40.7720, -73.9620` (Park Ave & E 72nd St)
4. Pan and zoom to z16–z17; confirm polylines terminate visibly at the curb, no overshoot into intersection boxes
5. Set simulated location to `40.7224, -73.9966` (Mott & Spring St)
6. Confirm same at the tight grid intersection

**PWA SW cache bump (`@pwa-maintainer` — required before PWA deploy/redeploy):**
- Bump `CACHE_VERSION` from `wepark-v32` to `wepark-v33` in `sw.js` and redeploy PWA to force clients to fetch new tile data. Without this bump, existing PWA sessions will serve stale tiles from `wepark-v32-tiles` indefinitely.

---

## What's working

- Algorithm change is a clean, minimal implementation of exactly what the spec specified
- The null-guard on `blockGeo` is a sensible defensive bonus
- Tile rebuild correctly scoped: 1,033 files, no schema changes, totals self-consistent
- Commit separation (algorithm vs. regenerated tiles) makes bisecting easy
- Both problem coordinates verified at exactly 6.0m displacement
- No code outside `build/preprocess.js` and `tiles/` was modified
- The -543 segment delta is accounted for by two documented causes (short-block skip threshold + live Socrata drift)
- The Lex Ave spot-check confirms that apparent-large-shifts in sub-seg coordinates are explainable by sign-data drift, not geometry errors

---

**Verdict: SHIP CLEAN. PR is mergeable as-is.**

The only required follow-up is the `sw.js` cache bump (separate file, separate owner, separate PR), which is documented in this report's findings and in the PR #21 description.
