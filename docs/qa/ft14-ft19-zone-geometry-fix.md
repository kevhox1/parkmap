# FT-14 / FT-19 fix — intersection-setback coordinate mismatch, resolved

**Status:** fixed, measured citywide (live pull), tile regen shipped in this PR.
**Author:** backend-data agent, 2026-08-18.
**Feeds:** `docs/field-testing-log.md` FT-14 (item #15, "1,528/1,621-row zone-construction loss") and
FT-19 ("lines still overshoot into intersections at road ends"). Builds directly on
`docs/qa/ft14-zone-construction-loss-investigation.md`, which root-caused (but did not fix) Symptom A.

## Summary

Both symptoms traced to the same root cause: `createSubSegments()` builds zone boundaries in **raw**,
intersection-relative distance (straight off NYC's `distance_from_intersection` field), but
`trimIntersectionSetback()` returned a `blockGeo` whose internal coordinate axis had already been
re-based to start at the trimmed line's own beginning — with no record of how much was trimmed. Every
downstream consumer of `blockGeo` (`extractSubSegment()`/`interpolateOnBlockLine()`) then interpreted
raw distances directly against that re-based axis.

- **Symptom A (FT-14):** zones whose raw distance range landed past the trimmed block's shortened
  length collapsed to a degenerate (<2m) line and were silently dropped, taking every rule assigned to
  that zone with them.
- **Symptom B (FT-19), confirmed root-caused this pass:** `trimIntersectionSetback()` had a second bug,
  the short-block skip (`if (blockLenFt < INTERSECTION_SETBACK_FT * 3) return blockGeo;`) — any block
  shorter than ~98.4ft was returned **completely untrimmed**, both ends running straight into their
  intersections. Measured citywide: **81 of 10,636 geometry-successful blocks (0.76%)** hit this branch
  in the pre-fix pipeline. Small in count, but exactly the blocks where a driver would notice overshoot
  (short East Village/LES cross-street blocks are common).

## The fix

`build/preprocess.js`, confined to `trimIntersectionSetback()`, `extractSubSegment()`,
`interpolateOnBlockLine()`, and the measurement counters added around the block-processing loop in
`main()`. No change to `createSubSegments()` — it already worked correctly in raw-distance space.

### Symptom A — structural fix, not a patch

`extractSubSegment(blockGeo, startRawFt, endRawFt)` is now the **single** place in the file that
translates raw, intersection-relative distances into a `blockGeo`'s own internal (possibly trimmed)
coordinate axis. `trimIntersectionSetback()` now returns a `setbackFt` field (how much raw distance was
trimmed off the line's start) as part of `blockGeo`'s contract; `extractSubSegment()` subtracts it before
touching `blockGeo.line`/`totalLen`. `interpolateOnBlockLine()`'s contract is now explicitly
documented as trimmed-local-only, with a comment barring direct calls from raw-distance callers.

This was chosen over the alternative of shifting `createSubSegments()`'s own output, because
`createSubSegments()`'s boundary math (including the TF2-13 isolated-`NO_PARKING`-cap logic) is correct
and untouched — the bug was purely in how the already-correct raw distances got **consumed**, not
produced. Concentrating the translation in the one function whose entire job is "take a distance range,
return a line" makes the raw-vs-trimmed confusion structurally impossible to reintroduce at a new call
site — there is no second code path left that touches raw distances against `blockGeo` directly.

Zones that land entirely inside the trimmed-off setback region still correctly collapse to a degenerate
line and get dropped — that remains intentional; hiding that portion of the block is the setback's whole
purpose. Zones that straddle the setback boundary are now clipped to the surviving portion instead of
being dropped wholesale (the actual recovery).

### Symptom B — proportional taper, not all-or-nothing

Replaced the binary skip with a continuous formula:

```js
const setbackFt = Math.min(
  INTERSECTION_SETBACK_FT,
  Math.max(0, (blockLenFt - MIN_USABLE_BLOCK_FT) / 2)
);
```

`MIN_USABLE_BLOCK_FT = 10` (~3m, comfortably above `isDegenerateLine()`'s 2m drop threshold). This
formula is **exactly continuous with the old fixed-setback behavior**: for any block
`blockLenFt >= 2×INTERSECTION_SETBACK_FT + MIN_USABLE_BLOCK_FT` (~75.6ft — below nearly every real
Manhattan block), it evaluates to precisely `INTERSECTION_SETBACK_FT`, byte-identical to today's
behavior. Only genuinely short blocks (< 98.4ft, where the old code skipped trimming outright) see a
different setback, and it's always a smaller-but-nonzero one that never fully erases the block. Blocks
too short to leave `MIN_USABLE_BLOCK_FT` in the middle (`< 10ft` raw) are left untrimmed by necessity —
they're already too short for meaningful overshoot.

**Note on curb-offset tuning:** this fix touches only the along-block (longitudinal) setback trim. It
does **not** touch `offsetPolyline()`, `getStreetCurbOffset()`, `CURB_OFFSET_WIDE_METERS`,
`CURB_OFFSET_DEFAULT_METERS`, or any width-derived offset logic (TF2-5/TF2-10/TF2-12/TF2-14's territory)
— the lateral curb-hugging position of every line is unperturbed. Only where each line's two *ends* land
along the block changes.

## Measurement — citywide, live pull, before/after

Both runs against the **same** live Socrata pull (identical row counts confirm no dataset drift between
runs): 96,226 signs fetched (75,877 main + 20,349 ASP), both completeness-gated OK (main: expected 75877,
fetched 75877, shortfall 0; ASP: expected 20349, fetched 20349, shortfall 0) — 89,946 in Manhattan, 67,889
after dedup, 11,079 blocks, 10,636 geometry-successful (osmHits).

"Before" = unmodified `build/preprocess.js` from `main`, instrumented with the same counters as "after"
(instrumentation added to a scratch copy only, not committed) and run against the identical pull.

### Row-level funnel

| Metric | Before | After | Δ |
|---|---:|---:|---:|
| Rows entering geometry-successful blocks | 53,500 | 53,500 | — |
| Rows surviving to a final tile segment | 51,876 | 53,141 | **+1,265** |
| Rows lost | 1,624 (3.04%) | 359 (0.67%) | **−1,265 (−77.9%)** |

### Zone / block funnel

| Metric | Before | After | Δ |
|---|---:|---:|---:|
| Zones attempted | 46,311 | 46,311 | — |
| Zones dropped (degenerate/invalid) | 3,238 (7.0%) | 2,031 (4.4%) | **−1,207** |
| Blocks with ≥1 zone drop | 3,015 / 10,636 (28.3%) | 1,842 / 10,636 (17.3%) | **−1,173 (−38.9%)** |
| Total tile segments generated | 43,073 | 44,280 | **+1,207** (exact match to zones-recovered — sanity check) |

### Setback-branch hit counts (Symptom B)

| Branch | Before | After |
|---|---:|---:|
| Full setback (`INTERSECTION_SETBACK_FT` at both ends) | 10,555 | 10,578 |
| Tapered (short block, partial setback) | n/a (didn't exist) | 14 |
| Untrimmed (too short for `MIN_USABLE_BLOCK_FT`) | 81 | 44 |

37 blocks that were previously returned **completely untrimmed** (running into both intersections) now
get *some* setback: 23 were long enough (75.6–98.4ft) to get the *full* 32.8ft setback the old code
denied them outright; 14 shorter blocks get a smaller, clamped, non-zero taper. The remaining 44 blocks
are genuinely too short (<10ft) for any trim to make sense.

### Category breakdown (dominant category per segment)

| Category | Before | After | Δ |
|---|---:|---:|---:|
| NO_STANDING | 15,165 | 15,826 | +661 |
| ASP_TUE_FRI | 6,969 | 7,037 | +68 |
| ASP_MON_THU | 6,841 | 6,904 | +63 |
| METERED | 6,176 | 6,453 | +277 |
| NO_PARKING | 3,719 | 3,789 | +70 |
| TRUCK_LOADING | 1,346 | 1,380 | +34 |
| SPECIAL | 1,290 | 1,311 | +21 |
| ASP_DAILY | 807 | 813 | +6 |
| UNKNOWN | 710 | 716 | +6 |
| ASP_OVERNIGHT_MWF | 43 | **42** | **−1 — investigated, see below** |
| ASP_OVERNIGHT_TTHS | 7 | 9 | +2 |

**Every category held or increased except `ASP_OVERNIGHT_MWF` (−1).** Per this task's explicit bar
("zero category decreases... a finding to report, not to accept"), this was investigated rather than
waved through.

**Root cause of the one decrease, confirmed:** `FORSYTH STREET (GRAND STREET to DELANCEY STREET) [W]`
has 6 broom-symbol MWF signs at raw distances 8, 201, 321, 363, 480, 568ft, all `<->` (both-direction).
`createSubSegments()` produces 7 zones; zone 0 is `[0, 8]` (the sign at distance 8 also covers backward
to the block start via `coversBefore`). That zone lies **entirely inside the trimmed-off setback region**
(raw 0–8ft, deep inside the 32.8ft intersection setback). In the buggy pre-fix code, this zone
accidentally rendered anyway — not because it was correct, but because the *uncompensated* raw values
`[0, 8]` got reinterpreted directly against the trimmed line's own axis, producing a real (barely
non-degenerate, ~2.4m) phantom line segment at the **wrong physical location** (trimmed-local 0–8ft,
i.e. physical raw 32.8–40.8ft — nowhere near the true 0–8ft near-intersection sliver it was nominally
representing). After the fix, that same zone correctly clamps to a true zero-length line (both endpoints
land on the trimmed boundary) and is dropped, exactly as intended — the setback's entire purpose is to
hide geometry in that region. **The underlying sign (distance-8 broom-symbol MWF rule) is not lost**: the
same sign object is also assigned into the adjacent zone `[8, 201]` via `coversAfter`, which survives in
both before and after runs with its 2-rule set unchanged (confirmed by diffing final tile segments by
block+category+rule count). Net effect: one wrongly-positioned duplicate artifact segment removed, zero
information lost. This is a **correctness improvement**, not a regression — it's the exact class of
"confidently-wrong curb" artifact this fix exists to eliminate, and it is the kind of change that would
have been invisible without per-category diffing.

### Coverage (`scripts/coverage-report.js`)

| | Before | After |
|---|---:|---:|
| Total curb-miles covered | 351 mi | 354 mi |
| Total % (of 741 CSCL mi) | 47% | 48% |

**Zero neighborhoods regressed** — every neighborhood row held steady or ticked up by 1 point; face
counts increased or held in every neighborhood. Modest, as the original FT-14 investigation predicted
("a low-single-digit-percentage bump," since the maximum recoverable geometry per block is bounded by
the setback itself).

### Worked example — coordinator-requested, `EAST 2ND STREET (2ND AVENUE to 1ST AVENUE)`

This is the block TF2-4 concerns (Kevin: school-zone rule on the "wrong side/position... further down
toward the block edge" — see `docs/field-testing-log.md` TF2-4). Raw block length 751.57ft — well above
the short-block threshold, so this block does **not** hit Symptom B (`setbackFt = 32.8084ft` in both
before and after, full setback either way); it's a pure Symptom A case.

`[N]` side (8 signs), zones identical in both runs (raw distances, `createSubSegments()` unchanged):
zone `[79, 200]` carries `NO STANDING SCHOOL DAYS 7AM-4PM` (dist 79) and `AVO SCHOOL FACULTY ... SCHOOL
DAYS` (dist 200) — the school-zone rules.

- **Before (buggy):** raw `[79, 200]` interpreted directly as trimmed-local distance → physical position
  along the block = trimmed-local-0 (raw 32.8ft) + `[79, 200]` = **raw `[111.8, 232.8]`ft from 2nd
  Avenue**.
- **After (fixed):** raw `[79, 200]` minus `setbackFt` (32.8) → trimmed-local `[46.2, 167.2]` → physical
  position = raw `[79, 200]`ft from 2nd Avenue — **exactly matching the signs' true posted distance.**

**The old code rendered the school-zone rule ~32.8ft (~10m) further from the 2nd Avenue intersection
than its true position — i.e. "further down toward the block edge," verbatim what Kevin reported.** This
is strong, block-specific confirmation that the *position* component of TF2-4 is resolved by this fix.

**What this does NOT resolve:** Kevin's original wording also included "north side... should be west
side, not east side" — E 2nd St is an E-W street, so its sides are N/S, not E/W, meaning that part of
the complaint is still ambiguous (possibly a different block, a genuine curb-side/render-side issue
unrelated to this fix, or a wording mismatch). **Recommendation: do not close TF2-4 outright.** Report
the position-fix as resolved for this block; leave the side-vs-curb question open pending Kevin's
on-device confirmation with build 16+, since a curb-side bug (if real) would be a structurally different
defect (`offsetPolyline`/side-assignment, not `trimIntersectionSetback`) and is out of this fix's scope.

## Regen verification

- `diff -rq tiles ios/WePark/WePark/Resources/tiles` → **identical**, both directories written by the
  same `main()` run (the script's existing sync step, `preprocess.js` §7b) — the #21 lesson is
  structurally unrepeatable here since both dirs come from one script invocation.
- `sw.js` `CACHE_VERSION` bumped `wepark-v39` → `wepark-v40`.
- Completeness gate: MAIN expected 75,877 / fetched 75,877 (shortfall 0, tolerance 380); ASP expected
  20,349 / fetched 20,349 (shortfall 0, tolerance 102). Both OK, captured here per this task's explicit
  ask (a prior regen lost these to an interrupted session).

## Risk assessment

- **Curb-offset (lateral) geometry is completely untouched** — `offsetPolyline()`, width-tier logic, and
  every TF2-5/TF2-10/TF2-12/TF2-14 tuning constant are unmodified. This fix only changes where a line's
  two along-block *ends* land, not how far it sits from the road centerline.
- **For the overwhelming majority of blocks (any block ≥75.6ft, which is nearly every real Manhattan
  block), the setback is byte-identical to before** (`Math.min(INTERSECTION_SETBACK_FT, ...)` saturates
  at the old constant). The behavior change is concentrated in: (a) zones that used to collapse
  degenerate near a block's far end (now correctly clipped instead of dropped), and (b) the 81 blocks
  that were previously fully untrimmed (now get a real, bounded setback).
- **No category regressions** after investigation (one apparent regression traced to a correctness
  improvement, documented above with a reproducible before/after diff).
- Permanent instrumentation left in `build/preprocess.js`'s `main()` (setback-branch counts, zone-drop
  funnel, row-level loss funnel) — cheap, printed every run, and turns any *future* regen into a
  self-verifying one without re-deriving this measurement harness from scratch.

## Files

- `build/preprocess.js` — `trimIntersectionSetback()`, `extractSubSegment()`,
  `interpolateOnBlockLine()`, `main()` (measurement counters).
- `sw.js` — `CACHE_VERSION` bump.
- `tiles/*`, `ios/WePark/WePark/Resources/tiles/*` — full regen, verified identical between the two
  directories.
- `docs/field-testing-log.md` — FT-14, FT-19 status updates.
- `docs/open-items.md` — item #15 closed out.
