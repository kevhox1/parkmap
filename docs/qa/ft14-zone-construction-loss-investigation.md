# FT-14 deferred item — the 1,528/1,621-row zone-construction loss, characterized

**Status:** investigation complete, root cause confirmed with exact numeric reproduction. **No fix
implemented** — see "Why this isn't fixed in this PR" below. No repo files changed by this
investigation (`build/preprocess.js`'s only change in this PR is the unrelated SAINT/ST uniqueness
gate); all instrumentation ran against a scratch copy of the pipeline, same method as the original
FT-14 join-drop investigation.
**Feeds:** open-items board item #15 ("FT-14 deferred — 1,528-row zone-construction loss").
**Author:** backend-data agent, 2026-08-13.

## Summary

The original FT-14 investigation (`docs/qa/ft14-join-drop-investigation.md`) flagged a **separate,
smaller loss** downstream of the name-join fix: ~1,528 rows (3.1% of geometry-successful blocks) that
resolve a real block/street join but never make it into a final tile segment. It offered an unconfirmed
**candidate hypothesis**: "a sign positioned at block distance 0 with only an 'away' arrow direction may
never get assigned to any zone" (a `createSubSegments()` array-indexing edge case).

**That hypothesis is wrong.** I instrumented the real pipeline (post-#68, with this PR's SAINT/ST gate
applied) against a live Socrata pull and found:

- **1,621 rows lost** (3.04% of 53,367 rows entering geometry-successful blocks) — same order of
  magnitude as the original 1,528 figure; the small increase tracks the same organic Socrata dataset
  growth documented in the #68 QA pass, not a new problem.
- **Zero of the 1,621 match the "distance 0 + arrow away" pattern.** I directly counted it: 0.
- **Zero are lost to unclassifiable sign text** (`classifySign()` returning null after the sign has
  already passed the informational-sign filter). Also directly counted: 0.
- **All 1,621 are lost to the same single, different, confirmed root cause**: a coordinate-space
  mismatch between `createSubSegments()` (which computes zone boundaries in **raw**,
  physical-intersection-relative distance, straight from NYC's `distance_from_intersection` field) and
  `extractSubSegment()`/`interpolateOnBlockLine()` (which interpret those same raw distance values
  against `blockGeo`, whose coordinate origin has **already been shifted** by
  `trimIntersectionSetback()`'s 10m/32.8ft intersection setback trim on *both* ends). When a zone's raw
  distance range lands entirely past the trimmed block's shortened length, both of its interpolated
  endpoints collapse onto the same physical point, `isDegenerateLine()` correctly identifies it as a
  zero-length stub, and the **entire zone — and every sign rule assigned to it — is silently dropped**,
  with no log line pointing at the cause.

This is a real, previously-unrecognized bug in `build/preprocess.js`, confined to the interaction
between `trimIntersectionSetback()` and the per-sign-distance sub-segment extraction path. It affects
**~28% of geometry-successful blocks** (3,008 of 10,613) to some degree, though — because the trim is
only ~32.8ft per end — the loss inside each affected block is small (usually just the block's last
sub-segment, and often a sub-segment whose nominal span is mostly speculative end-of-block padding
rather than real curb length; see "Recoverable coverage estimate" below).

## Method

Same approach as the original FT-14 join-drop investigation: instrumented a scratch copy of
`build/preprocess.js` (this PR's version, with the SAINT/ST gate already applied — see the sibling PR
change), pointed at scratch-only output directories, run against a live Socrata pull. No control-flow
logic was changed in the instrumented copy — only counters, debug IDs, and diagnostic `console.log`
calls alongside the existing drop points (`return`/`continue` statements already in the code).

1. Assigned every deduplicated sign row a stable debug ID at ingestion.
2. Tracked a `Set` of debug IDs for every sign whose block resolved real OSM geometry
   (`blockGeo` truthy) — this is the "entering geometry-successful blocks" population (53,367 rows in
   this run, vs. the original investigation's 48,943 — larger because this run already includes the
   SAINT/ST-gate-fixed name-join recovery, so more blocks resolve geometry in the first place).
3. Tracked a second `Set` of debug IDs that actually end up in a `zone.rules` array for a zone that
   survives all the way to a pushed `allSegments` entry (i.e., `extractSubSegment` succeeds,
   `offsetPolyline` succeeds, the result isn't degenerate).
4. `lost = entering - survived`. For every lost row, looked up its original sign object directly (not
   re-derived) and:
   - Called `classifySign()` on it to check for the "unclassifiable" bucket — 0 matches.
   - Called `parseSchedule()` to check its arrow direction and distance for the original "distance 0 +
     away arrow" hypothesis — 0 matches.
   - For the remainder (100% of lost rows), added counters at every `return` point inside the
     `subSegments.forEach` extraction loop (`extractSubSegment` throw, null/short line, null/short
     offset line, non-finite coordinates, degenerate line) to see exactly where the drop happens.
5. For the "degenerate line" drops (100% of the remainder), split by whether `zone.distStart >=
   blockGeo.blockLenFt` (unambiguously "the zone's raw start is already past the trimmed block's
   length") vs. not, to check whether a single root cause explains both.
6. Picked concrete reproduction blocks from the "other/unexplained" sample set and dumped their full
   sign list, computed zones, **both the raw (pre-trim) and trimmed `blockGeo.blockLenFt`**, and the
   exact per-zone drop reason, to get an exact numeric confirmation of the mechanism (not just a
   plausible-sounding theory).

## The numbers

### Row-level funnel (live pull, this PR's candidate pipeline, 2026-08-13)

| Stage | Rows |
|---|---:|
| Rows entering geometry-successful blocks (`blockGeo` resolved) | 53,367 |
| Rows surviving to a final tile segment | 51,746 |
| **Net lost inside geometry-successful blocks** | **1,621 (3.04%)** |

### Where the 1,621 are lost

| Bucket | Rows | Notes |
|---|---:|---|
| Whole-block empty (`createSubSegments()` returns `[]`, block rendered as bare UNKNOWN geometry with zero rules) | 0 | Not observed in this run — every geometry-successful block had at least one classifiable sign. |
| Unclassifiable description (`classifySign()` → null, filtered out of `signData` before zone assignment) | 0 | Not observed — SKIP_PATTERNS already filters non-parking-rule signs at grouping time; nothing reaches `createSubSegments` with an empty/garbage description in this pull. |
| **Original hypothesis: distance===0 && arrow==='away'** (`createSubSegments()`'s `beforeIdx=-1` array-indexing edge case) | **0** | **Directly refuted.** Checked every one of the 1,621 lost rows against this exact condition — zero matches. |
| **Confirmed root cause: zone geometry collapses to a degenerate (<2m) line inside `extractSubSegment()`, entire zone silently dropped** | **1,621 (100%)** | See below. |

### The confirmed root cause, in zone-level terms (across the full pull, all blocks)

| Metric | Count |
|---|---:|
| Total sub-segment zones attempted (`createSubSegments()` output, across all 10,613 geometry-successful blocks) | 46,204 |
| Zones dropped as degenerate | 3,229 (7.0% of zones attempted) |
| — of which: `zone.distStart >= blockGeo.blockLenFt` (raw zone start already past the trimmed block's full length) | 2,481 |
| — of which: boundary-adjacent (raw `distStart` just under `blockLenFt`, `distEnd` far beyond — same mechanism, the sliver of real geometry left is under the 2m degeneracy threshold) | 748 |
| Rule-assignments lost across those 3,229 dropped zones | 3,492+ (higher than the 1,621 unique lost rows because a `both`-arrow sign can be assigned into more than one zone; it only counts as "lost" once, if *none* of its zones survive) |
| Blocks with **at least one** degenerate-zone drop | 3,008 of 10,613 geometry-successful blocks (28.3%) |

Category breakdown of the 1,621 lost rows (roughly proportional to the overall category mix, no
meaningful skew toward any one rule type):

```
NO_STANDING: 633    METERED: 245     ASP_TUE_FRI: 176   NO_PARKING: 150
ASP_MON_THU: 146     ASP_DAILY: 127   UNKNOWN: 54        TRUCK_LOADING: 51
SPECIAL: 37          ASP_OVERNIGHT_TTHS: 1   ASP_OVERNIGHT_MWF: 1
```

### Exact numeric confirmation (one worked example)

Block: `ADAM CLAYTON POWELL JR BOULEVARD (WEST 126TH STREET to WEST 127TH STREET) [E]`. Six signs, at
raw distances 114ft (×3) and 217ft (×3) from the intersection. `createSubSegments()` correctly builds
three zones from these: `[0,114]`, `[114,217]`, `[217,317]` (the last zone extends 100ft past the final
sign as a coverage buffer, per the existing `boundaries.push(lastDist + Math.max(100, lastDist*0.3))`
logic — unrelated to this bug).

- **Raw (untrimmed) block length**: `256.56ft` (confirmed by instrumenting `getBlockPolyline()` directly,
  before `trimIntersectionSetback()` runs).
- **Trimmed `blockGeo.blockLenFt`** (what `extractSubSegment()` actually receives): `190.94ft` —
  exactly `256.56 - 2×32.8` (the 10m/32.8ft setback trimmed off *both* ends), confirming
  `trimIntersectionSetback()`'s own math is correct in isolation.
- Zone `[217, 317]` is passed **as-is** (raw, untrimmed distances) into `extractSubSegment(blockGeo,
  217, 317)` — but `blockGeo` is the **trimmed** 190.94ft geometry, whose own internal distance axis
  starts fresh at 0 (corresponding to raw 32.8ft) and ends at 190.94 (corresponding to raw 223.7ft).
  Both `217` and `317` exceed `190.94`, so `interpolateOnBlockLine()` clamps **both** endpoints to the
  same final point (`[40.80976961222423, -73.94786509470958]`, verified identical to the decimal in the
  instrumented run). `isDegenerateLine()` correctly flags a <2m line and drops it.
- **Result: 3 legitimate, correctly-classified rules — a Tue/Fri sanitation-broom `NO_PARKING`/ASP sign
  and a `METERED` HMP sign — vanish with no trace.** In *trimmed*-space terms, that zone's raw start
  (217ft) would correctly correspond to `217 - 32.8 = 184.2ft`, comfortably inside the 190.94ft trimmed
  length — the zone is not actually beyond the real block; the code is just interpreting an
  untranslated raw distance against a coordinate system that no longer starts at the same origin.

This same pattern reproduced identically (confirmed with the same raw/trimmed blockLenFt inspection) on
every other sample checked (`WEST END AVENUE (W60–W61) [E]`, `PARK AVENUE (E118–E117) [W]`, `ADAM
CLAYTON POWELL BOULEVARD (W125–W126) [E]`, etc.) — all "other/unexplained" samples from the earlier FT-14
join-drop investigation's own list, now fully explained.

## Why the original "distance 0 + away arrow" hypothesis doesn't hold

The theoretical bug it described is real *as a static code-reading observation* —
`createSubSegments()`'s `coversBefore` branch does compute `beforeIdx = zones.findIndex(z =>
z.distEnd === d)`, which is `-1` for `d === 0` (no zone's `distEnd` is ever `0`, since `0` is always
the first zone's `distStart`), and the subsequent `for (let i = beforeIdx; i >= 0; i--)` loop is a
no-op when `beforeIdx === -1` — so a hypothetical sign at distance 0 with `arrow === 'away'` *and no
other arrow interest* (`coversAfter === false`) would indeed be silently dropped by that specific code
path. **It just doesn't happen in the live data**: either no sign is ever posted at literal distance 0
with an isolated "away" arrow reading, or (more likely) such signs are rare enough that none appeared in
this pull. Either way, the empirical count is 0 out of 1,621, so it is not a meaningful contributor to
this loss and should not be the target of a future fix.

## Recoverable coverage estimate

**Modest, and smaller than the raw row count suggests.** The `[217,317]` example zone's *nominal* width
(100ft) is mostly the automatic end-of-block coverage buffer (`Math.max(100, lastDist*0.3)`), not
necessarily real curb length backed by another sign — after a correct fix (see below), that zone would
be re-extracted against the trimmed geometry starting at raw `217ft` (trimmed-equivalent `184.2ft`) and
running to the trimmed block's real end (`190.94ft`), i.e., a genuine but small recovered sliver of
**~6.7ft**, not the full 100ft. Generalizing: the maximum physically recoverable geometry per affected
block is bounded by the intersection setback itself (32.8ft per end, by design — the trim's whole
purpose is to hide that portion of the block near the intersection, and a correct fix must preserve
that, not resurrect it). Across 3,008 affected blocks, a fully-correct fix would therefore recover, at
most, a low-single-digit-percentage bump to citywide coverage-mile figures — meaningfully fewer
`UNKNOWN`/blank block faces (visually helpful, especially for blocks that currently show a truncated or
missing tail with no rule at all), but not a coverage-percentage move on the scale of the SAINT/ST or
alias fixes in #68. This is worth doing for correctness (a driver seeing "no rule shown" at the far end
of a block when a real rule exists there is a legitimate miss, distinct from the wrong-street risk in
item 1), just not as a marquee coverage number.

## Why this isn't fixed in this PR

The diagnosis is complete and confirmed with exact numbers, but the fix itself does **not** meet the
"low-risk, well-understood" bar this task set for a same-PR fix, for three concrete reasons:

1. **The fix touches `trimIntersectionSetback()` / the intersection-setback contract**, which is the
   most heavily-tuned, most-regression-prone region of this file (`INTERSECTION_SETBACK_M`,
   `CURB_OFFSET_WIDE_METERS`/`CURB_OFFSET_DEFAULT_METERS`, `isDegenerateLine()`'s 2m threshold, and the
   TF2-13 isolated-NO_PARKING cap all live in or immediately around this code, each with its own
   tuning history and prior regressions called out in the surrounding comments). A correct fix needs to:
   - Change `getBlockPolyline()`'s return contract to expose *how much* was trimmed (a `setbackFt`
     field, `0` for blocks below the `INTERSECTION_SETBACK_FT × 3` trim threshold that
     `trimIntersectionSetback()` already exempts).
   - Shift `zone.distStart`/`zone.distEnd` by `-setbackFt` (clamped to `[0, blockGeo.blockLenFt]`) at
     the `extractSubSegment()` call site inside the `subSegments.forEach` loop — and *only* there;
     `createSubSegments()`'s own boundary math should stay in raw-distance space, since the TF2-13 cap
     logic and the `uniqueDists`/boundary generation all correctly operate on raw distances today.
   - Preserve the *intentional* clamping for zones that genuinely fall inside the trimmed-off
     intersection box (`distEnd <= setbackFt` or `distStart >= rawBlockLenFt - setbackFt`) — those
     should keep collapsing to nothing, since hiding that portion of the block is the trim's entire
     purpose. Getting this half of the fix wrong would *reintroduce* the exact defect the trim exists to
     prevent (visible geometry poking into an intersection box).
2. **Any fix that changes tile output requires a live-pull regen to verify and ship**, and per this
   task's explicit constraints, running a full regen and committing 1,000+ tile files is Kevin's call,
   not something to do speculatively in a follow-up PR. Unlike item 1's SAINT/ST gate (which I proved
   byte-for-byte identical against a live pull, so it needed no regen decision), this fix would
   *deliberately* change segment geometry for ~3,000 zones across ~28% of blocks — there is no way to
   land it without a real regen, and that regen needs the same before/after coverage-report and
   category-regression rigor the #68 fix got.
3. **The risk profile is different in kind from item 1.** Item 1 (SAINT/ST gate) is a pure safety net —
   it can only ever make the pipeline more conservative, never change today's output. This fix actively
   changes which geometry gets rendered for thousands of block faces. A sign-convention mistake in the
   shift (e.g., shifting the wrong direction, or applying it to blocks that weren't actually trimmed)
   would not just fail to recover rows — it could shift a real rule's rendered position by up to ~33ft,
   which is exactly the "confidently-wrong curb" failure mode this task explicitly warned against for
   item 1. That bar should apply here too, if anything more so, since this fix is more invasive.

**Recommendation for a future dedicated pass:** implement the `setbackFt`-exposing change above, verify
with the same live-pull before/after coverage-report + category-regression methodology used for #68 and
for item 1 in this PR, and treat the regen/ship decision as Kevin's call per the standing tile-regen
policy. This doc, plus the reproduction numbers above, should be enough to scope that work directly
without re-deriving the root cause from scratch.

## Files

- Investigation harness (scratch only, not committed): instrumented copy of `build/preprocess.js` with
  debug-ID tracking, zone-drop-reason counters, and targeted block dumps, run against a live Socrata
  pull — session-scoped scratch, not part of the repo.
- Real files read (unmodified except this PR's separate SAINT/ST gate change, which is unrelated to
  this investigation): `build/preprocess.js` (`trimIntersectionSetback()`, `getBlockPolyline()`,
  `extractSubSegment()`, `interpolateOnBlockLine()`, `createSubSegments()`, `isDegenerateLine()`),
  `docs/qa/ft14-join-drop-investigation.md`, `docs/field-testing-log.md`.
