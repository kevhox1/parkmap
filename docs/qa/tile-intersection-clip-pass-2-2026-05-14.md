# Tile Intersection Clip — QA Pass 2 — 2026-05-14

**Reviewed:** branch `fix/intersection-setback-bump` at `1b8518f`, against the fix description and prior QA context.
**Verdict:** SHIP WITH CAVEATS (one significant finding documented below; does not block merge).

---

## Summary

PR #22 correctly fixes both the 6m-to-10m setback change and the structural iOS dual-path bug. The `preprocess.js` sync block is logically sound, both tile directories are byte-identical on the branch, and the E72nd/Park reference geometry (`[40.770889, -73.963413]`) confirms the 10m setback is present in both the PWA copy and the iOS Resources copy for the first time. The `lineCap = .butt` change is correct on both renderer paths with `lineJoin` left at `.round`. The only finding is a pre-existing quality issue that measurably worsens with the larger setback: approximately 6.8% of segments are degenerate (start coordinate equals end coordinate) and render as invisible points. This was 1.5% on main at 6m. Kevin's visual smoke passed, suggesting the practical impact is acceptable, but it should be tracked.

---

## Acceptance criteria checklist

- [x] `INTERSECTION_SETBACK_M` bumped from 6 to 10 — verified in diff at line 405 of `build/preprocess.js`
- [x] `IOS_TILES_DIR` constant present with correct path and explanatory comment — verified at lines 17-23
- [x] Section 7b sync block present: clean-then-copy logic after `index.json` write — verified at lines 907-919
- [x] Sync block handles missing `IOS_TILES_DIR` (creates it with `mkdirSync`) — verified
- [x] Both `tiles/index.json` and `ios/WePark/WePark/Resources/tiles/index.json` report identical `totalTiles: 1027, totalSegments: 39370`
- [x] File counts identical: 1028 files in each directory (1027 tiles + 1 index.json)
- [x] No filenames present in one directory but not the other
- [x] E72nd/Park reference segment first point `[40.770889, -73.963413]` in both paths — confirmed NOT the W1a point `[40.770932, -73.963517]` and NOT the 6m point
- [x] `renderer.lineCap = .butt` on `TaggedMultiPolyline` path
- [x] `renderer.lineCap = .butt` on `SelectedPolyline` path
- [x] `renderer.lineJoin = .round` on both paths
- [x] Inline comment explaining butt caps rationale present
- [x] Segment schema `{id, street, from, to, side, line, rules, dominantCategory}` unchanged — spot-checked tiles 15_18, 22_12, 31_25
- [x] Rule schema unchanged — spot-checked
- [x] No `index.html`, `sw.js`, or other PWA/Swift files changed
- [x] Kevin's visual smoke: simulator showed `1027 tiles, 39370 segments`, Park/72nd and Mott/Spring artifacts clean

---

## Findings

### Blocking

None.

### Significant

**#1: Degenerate sub-segments increase from ~1.5% to ~6.8% with 10m setback**

- Where: tile data, all tiles — e.g., `tiles/tile_31_25.json` segments `PARK_AVENUE_EAST_72ND_STREET_EAST_73RD_STREET_E_2`, `LEXINGTON_AVENUE_EAST_74TH_STREET_EAST_73RD_STREET_W_2`, `PARK_AVENUE_EAST_74TH_STREET_EAST_73RD_STREET_W_2`; extrapolated ~2,670 degenerate segments across the full dataset.
- What: These segments have `line[0] === line[-1]` (start and end point are the same coordinate). With `.butt` line caps they render as nothing — zero-length strokes. The segments represent sign zones near intersection edges where the sub-zone boundary falls within or past the trimmed region of the block polyline. `extractSubSegment` returns points that coincide because the zone's `distStart` and `distEnd` both map to the same (already-setback) terminus.
- Not a new bug introduced by the sync logic — it pre-existed at 6m (607 estimated degenerate segments) and worsens at 10m. Kevin's visual smoke passed; iOS and PWA both silently skip zero-length polylines.
- Owner: `@backend-data` — consider adding a `trimIntersectionSetback`-aware guard in the sub-segment emission loop that skips or merges degenerate sub-zones rather than emitting them. **Not required to block this PR.**

### Minor / nit

**#2:** Sync block uses `unlinkSync` in a for-loop rather than `fs.rmSync({recursive:true})` + `mkdirSync`. Symmetric with the `TILES_DIR` clean loop above it. Tiles are always flat JSON; no nested dirs expected. Log only.

**#3:** PWA `sw.js` cache bump not included — confirmed out-of-scope, `@pwa-maintainer` post-merge follow-up.

### Out of scope (logged, not fixed)

- W6 / PR #20 notification smoke — Kevin in parallel
- HANDOFF callout about the dual-path — post-merge
- PWA SW cache bump (`wepark-v32` → `wepark-v33`) — `@pwa-maintainer` post-merge

---

## Sample geometry comparisons

| Location | Pre-fix (`main`'s iOS Resources copy) | PR #22 (this branch) | Shift |
|---|---|---|---|
| `EAST_72ND_STREET_PARK_AVENUE_LEXINGTON_AVENUE_S_1` first point | `[40.770932, -73.963517]` (W1a centerline) | `[40.770889, -73.963413]` | **9.1m east** |

`main`'s iOS Resources copy was at W1a baseline (`totalTiles: 1028, totalSegments: 40664`); `main`'s PWA copy was post-PR #21 (`1029 / 40121`); the branch unifies both to `1027 / 39370`. The 5-day dual-path bug is convincingly fixed.

---

## Smoke tests run

| Test | Outcome |
|---|---|
| Read full `build/preprocess.js` diff | Pass — all three changes present and correct |
| Read full `MapViewRepresentable.swift` diff | Pass — both renderer paths updated |
| `git diff main..fix/intersection-setback-bump --stat` | 2066 files; only the expected paths touched |
| `tiles/index.json` vs iOS Resources `index.json` totals | Identical: `1027 / 39370` |
| File count parity between paths | 1028 files in each |
| Sample tile parity (15_18, 22_12, 31_25) | Identical between paths |
| Schema preservation in spot-checked tiles | Pass |
| Reference segment 10m shift verification | Pass — `[40.770889, -73.963413]` in both paths |
| `lineCap` / `lineJoin` grep in `MapViewRepresentable.swift` | Two `.butt`, two `.round`; no stale `.round` lineCaps |
| `main` iOS Resources index | `1028 / 40664` (W1a stale data confirmed) |
| `main` PWA index | `1029 / 40121` (post-PR #21, never reached iOS) |
| Degenerate-segment sampling | ~6.8% on branch (~2,670 segments); ~1.5% on main (~607); pre-existing data quality issue worsened by larger setback |

---

## What's working

The dual-path bug is convincingly fixed. The structural evidence is clear: `main`'s iOS Resources had W1a geometry (`40664` segments), `main`'s PWA had post-PR-#21 geometry (`40121` segments), and the branch unifies both at `39370` — the correct post-10m-setback number. This is the first time the iOS app has had current tile data since W1a. The sync logic is straightforward and correct. The `lineCap = .butt` change is exactly right for preventing round-cap bleed back into the intersection gaps. Kevin's live smoke (clean build, simulator log showing correct counts, visual artifact at Park/72nd clean) is exactly what this fix was intended to achieve.

---

## Lessons — for future data-pipeline PRs

We collectively missed this for 5 days across 4 PRs because QA reviewed the diff without asking "where does this data actually go?" Going forward, for any data-pipeline PR:

1. **Trace all consumer read paths.** For tile data: PWA reads `./tiles/` via `fetch('/tiles/...')`. iOS reads from `Bundle.main.url(forResource:...)`, which Xcode copies from `ios/WePark/WePark/Resources/tiles/` at build time. A `grep -r "Bundle.main.url" ios/` would have surfaced the iOS reader and prompted "where does Xcode pull that resource from?"

2. **Verify at the consumer, not just the emitter.** Checking that `build/preprocess.js` writes to `./tiles/` is necessary but not sufficient.

3. **Add a count assertion to the QA checklist for data PRs.** "Does the iOS console log show the expected tile count?" is a cheap, fast check. Mismatch between `tiles/index.json` and `ios/.../Resources/tiles/index.json` would have failed at PR #21 review.

This isn't blame — the orchestrator and all engineers missed it too, and the HANDOFF never documented the dual-path. Now it will (post-merge HANDOFF update is queued).

---

**Verdict: SHIP WITH CAVEATS. PR is mergeable as-is.**

Most important thing Kevin should know: The structural bug is confirmed fixed; main's iOS Resources had genuine W1a stale geometry, the branch brings it to current. The degenerate-segment finding (~6.8% of segments are zero-length) is a pre-existing data-quality issue that worsens slightly with the larger setback, not a regression from the sync fix. Kevin's visual smoke already passed; iOS and PWA both silently skip zero-length polylines. Track in backlog for a future `@backend-data` cleanup.
