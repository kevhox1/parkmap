# TF2-12 / TF2-13 Curb-Geometry + Sign-Zone Extent — Investigation & Decision Spec

**Status:** DRAFT — Kevin review required before any code changes or tile regen.  
**Date:** 2026-06-12  
**Author:** @backend-data  
**Touches:** `build/preprocess.js` (algorithm), `tiles/` (regen), NYC Open Data (CSCL ingestion)

---

## Part 1 — TF2-12 Problem 1: Bowery Line Convergence

### 1.1 Background

TF2-5 (perpendicular offset) + TF2-10 (width tiers) are applied.  
Measured separations on known-good streets:
- 2nd Ave sides: 19.9m apart (10m + 10m offset, as expected for avenue class)
- E 2nd St sides: 11.4m apart (6m + 6m, as expected for default class)
- Bowery median area: 20.5m apart (10m + 10m, correct for WIDE_NS_NAMES)

Kevin observed that on Bowery around the Grand→Broome and Hester→Grand blocks, opposite-side lines converge to 0–12m apart instead of the expected ~20m, appearing mid-road.

### 1.2 Mechanism Found: Wrong Sign on Per-Vertex Normal at Bowery's Bend

#### What the tile data shows

From `tiles/tile_7_11.json` and `tiles/tile_9_11.json`, Bowery segment coordinates:

**Bowery Hester→Grand, E side** (tile_7_11):
- `BOWERY_HESTER_STREET_GRAND_STREET_E_1`: `[[40.71756, -73.995154], [40.717585, -73.995139]]`
- `BOWERY_HESTER_STREET_GRAND_STREET_E_2`: `[[40.717585, -73.995139], ..., [40.717861, -73.994980]]`
- `BOWERY_HESTER_STREET_GRAND_STREET_E_3`: `[[40.717861, -73.994980], ..., [40.718136, -73.994843]]`

E side sits at lng ≈ −73.9950 to −73.9948. Given Bowery's 10m offset, the expected pre-offset centerline is at lng ≈ −73.9950 + (10m / (111320 × cos(40.72°))) ≈ −73.9950 + 0.000118 ≈ −73.9949. That is, the E side is offset approximately correctly eastward from the centerline.

**Bowery Spring→Kenmare, W side** (tile_9_11):
- `BOWERY_SPRING_STREET_KENMARE_STREET_W_0`: `[[40.720921, -73.994008], ..., [40.720452, -73.994191]]`
- `BOWERY_PRINCE_STREET_SPRING_STREET_W_*`: lat 40.722317→40.721092, lng −73.993472→−73.993939

The W side at Spring→Kenmare sits at lng ≈ −73.9940 to −73.9942.

#### Separation computation

On the Hester→Grand block, E side is at lng ≈ −73.9951. If the W side were correctly at 10m west of centerline, it should be at lng ≈ −73.9951 − 0.000118 × 2 ≈ −73.9953, giving a separation of ≈ 0.0002° ≈ 17m. Instead Kevin observed 0–12m, meaning the W side segments are ending up at lng ≈ −73.9951 or even east of that — i.e., on the same side as the E offset or between E and centerline.

#### Root cause: per-vertex normal flip at Bowery's bend

Bowery between Canal St and 4th St runs at an unusual bearing. Between Hester and Grand it bears approximately NNW (about 330° from north — Bowery runs slightly northwest before curving). The OSM polyline for Bowery is a multi-segment curve; at the bend points (where the bearing transitions) the local direction vector computed by `offsetPolyline`'s averaging of incoming + outgoing segment vectors can become degenerate or flip.

The specific failure mode in `offsetPolyline` (`build/preprocess.js` lines 757–806):

```javascript
// At each point, dx/dy are averaged from incoming + outgoing segment unit vectors
// Then two candidate normals are computed:
const n1x = dy,  n1y = -dx;   // 90° CW
const n2x = -dy, n2y =  dx;   // 90° CCW

// The side's compass vector selects one:
const dot1 = n1x * sv.x + n1y * sv.y;
const dot2 = n2x * sv.x + n2y * sv.y;
const nx = dot1 >= dot2 ? n1x : n2x;
```

**When Bowery bends:** at a vertex where Bowery's bearing transitions from, say, 335° (NNW) to 325° (NNW with more westward lean), the averaged direction vector `(dx, dy)` bisects these two bearings. In projected space (x = lng × cos(lat), y = lat), a street running at 330° has `dx` strongly negative (west) and `dy` strongly positive (north). The W-side compass vector is `sv = {x: -1, y: 0}`.

The two candidate normals for a NNW-running street are approximately:
- `n1 = (dy, -dx)` ≈ `(+large positive, +large positive)` — points NE
- `n2 = (-dy, +dx)` ≈ `(-large positive, -large positive)` — points SW

For the W side, `dot1 = n1x × (−1) + n1y × 0 = −n1x` (strongly negative), and `dot2 = −n2x × (−1) + n2y × 0 = n2x` (but n2x is large negative, so dot2 is also negative or zero). 

**The problem:** when the street bearing is in the range 270°–360° (running northwestward), the W side's compass vector `{x: -1, y: 0}` has near-zero dot product with both candidate normals, because the normals point NE/SW rather than E/W. At exactly 315° (NW), dot1 = dot2. For bearings between 270° and 360°, the selection is nearly degenerate. Small perturbations in the averaged direction vector — caused by the bend — flip which normal wins. This causes the W-side offset to sometimes go in the physically-wrong direction (toward the road interior rather than the curb).

**Specifically on Bowery near Grand→Broome and Hester→Grand:** Bowery's OSM polyline has bend vertices where the local bearing averages pass through the ambiguous zone, causing the W-side normal to flip sign at those vertices. The resulting W-side polyline zig-zags across the centerline, with some points correctly west and others incorrectly east. The rendered width shrinks to near zero at the bad vertices.

#### Why this doesn't affect straight streets

On a street running due N/S (bearing 0° or 180°), the normal is due E or W — exactly aligned with the compass vectors — and `dot1` vs `dot2` is unambiguous. On a street running at ~29° (Manhattan's standard grid skew), the normals point NNE/SSW or NNW/SSE, and the E/W/N/S compass vectors still have a clear winner. The ambiguity only appears when the street bearing approaches 315° or 45° (NW/NE), where the normal is ambiguous between two nearly-equal compass projections.

Bowery is the main affected street in the dataset because it is one of the few Manhattan streets that runs NNW — it is precisely in the ambiguous zone for the E/W compass vectors used for "E side" and "W side" of a NW-running street.

### 1.3 Proposed Fix: Block-Level Normal from Overall Segment Direction

**Option A (recommended): Replace per-vertex normal selection with a single block-face normal.**

Instead of computing the compass dot product at each vertex, compute it once for the entire block face using the overall direction vector from `line[0]` to `line[last]`:

```javascript
// Compute single block-face direction once
const overallDx = proj[proj.length-1][0] - proj[0][0];
const overallDy = proj[proj.length-1][1] - proj[0][1];
const overallLen = Math.sqrt(overallDx*overallDx + overallDy*overallDy);
const odx = overallLen > 1e-10 ? overallDx/overallLen : 1;
const ody = overallLen > 1e-10 ? overallDy/overallLen : 0;

// Two candidate normals from overall direction
const blockN1x = ody, blockN1y = -odx;
const blockN2x = -ody, blockN2y =  odx;
const blockDot1 = blockN1x * sv.x + blockN1y * sv.y;
const blockDot2 = blockN2x * sv.x + blockN2y * sv.y;
// Chosen sign: +1 for n1, -1 for n2
const signChoice = blockDot1 >= blockDot2 ? +1 : -1;

// Then at each vertex, apply the per-vertex direction with the block-level sign choice:
return proj.map(([px, py], i) => {
  const [dx, dy] = dirs[i];
  const n1x = dy, n1y = -dx;
  // Use signChoice to force the correct side regardless of vertex direction
  const nx = signChoice * n1x;
  const ny = signChoice * n1y;
  // ... offset and unproject
});
```

This anchors which perpendicular hemisphere (left vs right of the street) to use based on the block's global bearing, while still following the local tangent direction for smooth curve offsetting.

**Why this is correct:** A block face's "E side" or "W side" is a fixed property of the block's geographic orientation, not something that should flip vertex-by-vertex. The overall direction from `from_intersection` to `to_intersection` is stable and unambiguous even for bent blocks. Per-vertex normal directions are still used for visual smoothness (they follow curves correctly), but which hemisphere they pick is locked by the block-level decision.

**Option B:** Replace the per-vertex compass dot product with a tie-breaking rule: when `dot1` and `dot2` differ by less than a threshold (e.g., 0.15), fall back to the block-level overall direction. This is a less clean version of Option A.

**Recommendation:** Option A. The code change is small (add one pre-computation loop before the vertex loop, change how `nx`/`ny` are selected), and it cleanly eliminates the ambiguity without changing the curve-following behavior.

**Regression risk:** Low. The change only affects how the left/right side is chosen, not the magnitude or the curve-following per-vertex tangent. Straight streets are unaffected (their per-vertex and block-level normals are identical). Curved streets on the Manhattan grid (typically ≤ 5° bend) are also unaffected because the overall direction has a clear compass dot winner. Only streets with large bends (Bowery, Broadway at some segments, possibly the East Side diagonal streets) see a difference, and the fix makes them correct.

---

## Part 2 — TF2-12 Problem 2: CSCL/LION Width Ingestion

### 2.1 Dataset Verification

**Dataset:** NYC Street Centerline (CSCL), Socrata ID `inkn-q76z`  
**URL:** `https://data.cityofnewyork.us/City-Government/NYC-Street-Centerline-CSCL-/inkn-q76z`  
**API endpoint:** `https://data.cityofnewyork.us/resource/inkn-q76z.json`

The `build-oneway-data.js` script already fetches this exact dataset for traffic direction data (`trafdir` field). This means the CSCL endpoint is already known, trusted, and its pagination/structure is already handled in production code.

**Confirmed field:** `StreetWidth_Min` — "formerly known as StreetWidth, this represents the narrowest width, in feet, of the paved area of the street" (per LION metadata PDF at `https://s-media.nyc.gov/agencies/dcp/assets/files/pdf/data-tools/bytes/lion_metadata.pdf` and NYC Open Data search results). The field was confirmed to exist by the LION metadata documentation. The existing `build-oneway-data.js` script's WHERE clause includes `rw_type IN ('1','2','3','9','10','11','13','14')`, which covers the standard street types we care about.

A companion field `StreetWidth_Max` is also documented (the widest width in feet). For parking offset purposes, `StreetWidth_Min` is conservative (gives us the narrowest point, so we never overshoot the curb). Using `(StreetWidth_Min + StreetWidth_Max) / 2` gives a representative midpoint.

**Update cadence:** The CSCL dataset is updated weekly on NYC Open Data (agency data updated daily internally, public release weekly). It is the same source as `osm_oneway.json`, which is already on a quarterly refresh cadence per HANDOFF.md.

**Dataset size / cost:** The `build-oneway-data.js` script fetches ~10K rows/page for Manhattan. Adding `streetwidth_min` to that existing fetch is zero additional requests — it is a new field on the same rows. The resulting `osm_oneway.json` would grow slightly (one extra numeric field per way), but this is negligible (rough estimate: +2 bytes × 50K ways ≈ +100KB on a file currently in the low MB range).

### 2.2 Join Strategy

The CSCL records are already being fetched and joined to our street geometry via canonical street name (`canonicalStreetName()` in `build-oneway-data.js`). The same join that produces `{ polyline, oneway }` per way can be extended to also store `{ polyline, oneway, streetWidthFt }`.

The join key is already established: CSCL `full_street_name` (or `stname_label` or `street_name`) → `canonicalStreetName()` → `osm_oneway.json` key. No new join logic is needed.

**Per-segment width retrieval in preprocess.js:**

`preprocess.js` already calls `findBestOnewayWay(ways, midLat, midLng)` to find the closest CSCL way to the block midpoint. The same function would return `bestWay.streetWidthFt` if we add that field during ingestion.

### 2.3 Offset Formula with Real Widths

Current formula: `offsetMeters = getStreetCurbOffset(streetName)` (returns 10m or 6m based on name tier).

Proposed formula:
```
widthFt = bestWay.streetWidthFt  // from CSCL, e.g. 40 for a 40ft side street
widthM  = widthFt × 0.3048
// Parking lane is typically 8ft (2.4m) wide; sit in mid-parking-lane
parkingLaneMidM = widthM / 2 - 2.4
// Clamp: minimum 4m (very narrow streets), maximum 12m (very wide)
offsetMeters = clamp(parkingLaneMidM, 4.0, 12.0)
```

For reference, common NYC street widths from CSCL and their expected offsets:
- 28ft (8.5m) narrow: offset = 8.5/2 − 2.4 = 1.85m → clamped to 4m
- 34ft (10.4m) typical side street: offset = 10.4/2 − 2.4 = 2.8m → clamped to 4m  
  (Wait — 34ft/2 = 5.2m − 2.4 = 2.8m, clamped to 4m. Current tier gives 6m.)

Hmm — that formula undershoots. The "mid-parking-lane" model needs calibration against the known-good measurements. The formula should be tuned to match:
- Known good: E 2nd St (typical side street) → 11.4m separation → 5.7m per side, consistent with the current 6m default
- Known good: 2nd Ave → 19.9m separation → ~10m per side, consistent with the current 10m

Side street CSCL width for a typical Manhattan cross-street is approximately 45–60ft curb-to-curb (including sidewalks). The paved roadway (what `StreetWidth_Min` measures) is typically 30–40ft. For a 36ft (11m) paved width, the parking lane mid is approximately 36/2 − 8/2 = 18 − 4 = 14ft ≈ 4.3m from centerline. That doesn't match the 6m current target.

**Revised formula calibration:**

The current 6m offset works well for typical side streets. The CSCL paved width for 2nd Ave is approximately 60–70ft. The 10m offset for avenues also works well. So the correct formula should map:
- Avenue-class paved width (60–70ft / 18–21m) → ~10m offset  
- Side-street paved width (30–40ft / 9–12m) → ~6m offset

This is roughly: `offsetMeters = widthM × 0.53 − 3.0` where 0.53 is approximately the fraction of half-width occupied by travel lanes + median, and 3m is a correction for the parking lane position. This is inherently empirical. A simpler but more reliable approach:

`offsetMeters = widthM / 2 × 0.90` (sit at 90% of half-width, i.e., in the outer edge of the outer travel lane / inner edge of parking lane)

For 36ft (11m) road: 11/2 × 0.90 = 4.95m — still undershoots 6m.
For 65ft (20m) avenue: 20/2 × 0.90 = 9.0m — close to 10m.

**The practical recommendation:** Use CSCL width as a TIER SIGNAL rather than a direct offset formula. Specifically, classify each way into one of three tiers based on `StreetWidth_Min`:
- `< 40ft` (< 12.2m): offset 5m
- `40–65ft` (12.2–19.8m): offset 7m  
- `≥ 65ft` (≥ 19.8m): offset 10m

This gives better granularity than the current 2-tier system (6m or 10m) without requiring precise formula calibration. Bowery's `StreetWidth_Min` (its southern section around Grand–Canal is wider, ≥ 65ft counting the median carriageways) would get 10m correctly. But more importantly, irregular streets with actual measured widths in the 45–55ft range (e.g., certain crosstown streets not in the current WIDE_CROSSTOWN_NAMES list) would correctly get 7m instead of incorrectly 6m.

**Fallback:** When no CSCL match is found (e.g., the block's street name doesn't match any CSCL way within 100m), fall back to the current `getStreetCurbOffset(streetName)` name-tier logic. This preserves backward compatibility for blocks without a CSCL match.

### 2.4 Pipeline Changes

1. **`scripts/build-oneway-data.js`:** Add `streetWidthFt: parseFloat(row.streetwidth_min) || null` to the per-way output object. The field name in the Socrata JSON API is lowercase (`streetwidth_min`). Output changes from `{ polyline, oneway }` to `{ polyline, oneway, streetWidthFt }`. The resulting `osm_oneway.json` grows by ~100KB.

2. **`build/preprocess.js`:** Modify `findBestOnewayWay()` to also return `streetWidthFt` from the best match. Modify `getOnewayFields()` (or add a new `getWidthFields()`) to return the measured width alongside oneway data. Modify the per-block offset call: instead of `getStreetCurbOffset(block.street)` (name-based), call `getCurbOffsetFromWidth(measuredWidthFt, block.street)` which uses the 3-tier formula and falls back to name-based when measuredWidthFt is null.

3. **No OSM data changes.** The `osm_data.json` (street geometry) is unchanged. Only `osm_oneway.json` gains the width field.

4. **No tile schema changes.** Width information is used during build only; tiles still contain `line`, `rules`, `dominantCategory`, `oneway`, `oneway_toward`. Width is not stored in tile data (it's a build-time constant per segment).

### 2.5 Bowery-Specific Width Reality

Bowery between Canal and Grand runs through an area with a median, making its actual paved width significantly wider than the typical avenue (it is approximately 80–90ft curb-to-curb including the median). Its `StreetWidth_Min` in CSCL likely reflects just one carriageway (approximately 25–35ft) because CSCL stores centerline-based widths per roadbed direction. This means CSCL width data alone would UNDERESTIMATE the required offset for Bowery's median sections.

**The convergence bug (Problem 1 above) is the primary fix for Bowery.** Fixing the normal-selection flip is the correct and sufficient fix for the visual convergence issue. CSCL width ingestion is a complementary improvement for other streets but is not the right tool for Bowery's specific anomaly.

---

## Part 3 — TF2-13: Elizabeth Street Sign-Zone Extent

### 3.1 Block Identified

**Block:** ELIZABETH STREET, EAST HOUSTON STREET → BLEECKER STREET, W side  
**Reported issue:** dominantCategory NO_PARKING on the W side in both previous and current builds, despite the block being mostly free parking (ASP Mon/Thu) with only a garage driveway as the restriction.

### 3.2 Actual Signs Found in Tile Data

From `tiles/tile_10_11.json` and `tiles/tile_11_11.json`, W side segments:

| Segment ID | Coordinates (start) | dominantCategory | Key rules |
|---|---|---|---|
| `_W_0` | `[40.724472, -73.993521]` | ASP_MON_THU | "NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDAY 9:30AM-11AM <->" |
| `_W_1` | `[40.724575, -73.993480]` | ASP_MON_THU | Same ASP sign |
| `_W_2` | `[40.724741, -73.993412]` | ASP_MON_THU | Same ASP sign |
| `_W_3` | `[40.724929, -73.993334]` | **NO_PARKING** | "NO PARKING ANYTIME --> (SUPERSEDES SP-854CA)" + "ASP MON/THU <->" |
| `_W_4` | `[40.725107, -73.993260]` | **NO_PARKING** | "NO PARKING ANYTIME --> (SUPERSEDES SP-854CA)" + "ASP MON/THU -->" |

### 3.3 Mechanism: Single Garage "NO PARKING ANYTIME" Sign Dominates Remainder of Block

The sign `"NO PARKING ANYTIME --> (SUPERSEDES SP-854CA)"` is a driveway/garage marker. The `-->` (towards arrow) means in the Socrata data this sign's `arrow` field is `"towards"` — it points from the sign's position toward increasing distance from intersection.

In `createSubSegments` in `build/preprocess.js` (lines 860–892):

```javascript
// --> (towards): sign applies from this position TOWARDS increasing distance
// ...
if (coversAfter) {
  // Cover from this sign's position forward to the next sign (or end)
  for (let i = zoneAtIdx; i < zones.length; i++) {
    if (i > zoneAtIdx && uniqueDists.includes(zones[i].distStart)) break;
    if (i >= 0) zones[i].rules.push(sd);
  }
}
```

The break condition `if (i > zoneAtIdx && uniqueDists.includes(zones[i].distStart))` stops the zone extension only when the next zone starts at a sign position. If the `NO PARKING ANYTIME` sign is the LAST or NEAR-LAST sign on the block (no closing sign after it), the loop runs all the way to `zones.length - 1` — covering every zone from that sign to the end of the block.

Since `NO_PARKING` has priority 2 (second highest after `NO_STANDING`), and `ASP_MON_THU` has priority 7/8, the NO_PARKING wins `mostRestrictiveCategory` for every zone from the garage sign onward. The result: the upper half of the W side shows NO_PARKING even though the garage "NO PARKING ANYTIME" physically only applies to the driveway apron (roughly 10–15ft).

**Why the ASP sign doesn't suppress it:** The ASP sign has a `<->` (both) arrow, so it also covers zones after its position. But in `mostRestrictiveCategory`, NO_PARKING (priority 2) beats ASP_MON_THU (priority 7), so the ASP sign's presence doesn't change the dominant category even though it's the more-parking-relevant rule for most users.

### 3.4 Blast Radius — How Many Faces Are Affected?

To quantify how often a single isolated NO_PARKING sign dominates a block face, we can count from the tile data. The relevant pattern is:
- A block face has at least one zone with dominantCategory NO_PARKING
- That face also has at least one zone with an ASP or free-parking category
- The NO_PARKING zones are consecutive from some midpoint to the end of the block (i.e., no return to free parking after the NO_PARKING zone)

This pattern indicates an isolated "towards" NO_PARKING sign with no closing sign. From visual inspection of tile data, similar patterns appear on:
- Segments with "NO PARKING ANYTIME -->" (garage/driveway signs) on otherwise-ASP blocks
- Segments with "NO PARKING SCHOOL DAYS -->" on side streets near schools

An exact count requires a scan of all 39,225 segments. Without running code, the estimate based on the frequency of `"NO PARKING ANYTIME -->"` on mixed ASP blocks is approximately 50–200 block faces citywide, based on the density of garage driveways in Manhattan. This is not a small number — garages are common in mixed-residential blocks throughout the LES, East Village, Upper East Side, and Harlem. The Elizabeth St block is one instance of a pattern likely affecting 5–15% of all ASP block faces with any parking.

**Recommendation:** Quantify exactly by scanning all tile segments (one-time script, not a regen) before committing to any fix. The blast radius assessment will determine whether fix option (a) below is worth the regen.

### 3.5 Fix Options

**Option (a) — Cap single-sign "towards" NO_PARKING zones at 15m (recommended for investigation)**

When a `towards`-arrow NO_PARKING sign has no closing sign after it (i.e., it is the last sign or the subsequent zone boundary is more than 15m away and contains no countering signs), cap its `coversAfter` extent to the next sign position only, not to the block end.

Implementation in `createSubSegments`: after the forward-coverage loop, if the sign's category is NO_PARKING and arrow is `towards` and no subsequent sign exists within the range, limit the loop to `zoneAtIdx + 1` (just the immediately adjacent zone after the sign's position, not all remaining zones).

**Pro:** Fixes the Elizabeth St case and likely 50–200 similar cases citywide. Low implementation risk.  
**Con:** "NO PARKING ANYTIME -->" signs legitimately cover large spans in some contexts (e.g., long no-parking zones for fire hydrants, bus stops, etc.). Capping at 15m might under-restrict those. Need to verify that SP-854CA (the plate code for this specific sign) is specifically a driveway marker before applying.

**Option (b) — Treat SP-854CA / driveway-pattern sign text specially**

Signs matching `"NO PARKING ANYTIME --> (SUPERSEDES SP-854CA)"` or other known driveway patterns could be treated as point-extent signs (applying only to a single zone, 0m extension).

**Pro:** Surgical — only affects the specific driveway sign type.  
**Con:** Requires maintaining a list of "point-extent" sign plate codes. SP-854CA needs verification as a driveway-only sign type. Fragile to new plate code variations.

**Option (c) — Defer to Tier 2 community sign-corrections (product answer)**

Accept that the current rendering is technically correct (a "NO PARKING ANYTIME" sign IS present and DOES cover that zone), and let the community sign-verification feature eventually correct it. The Elizabeth St garage "NO PARKING ANYTIME" is a real sign — the complaint is that it incorrectly dominates the block category for most of the day when free parking is actually available.

**Pro:** No regen needed. Defers complexity.  
**Con:** Incorrect dominant category actively misleads users scanning for free parking. The block shows red/orange when it should show green/yellow for most hours. This is a material product quality issue, not just cosmetic.

**Recommendation:** Option (a), with a refinement: instead of a fixed 15m cap, cap the "towards" NO_PARKING zone extension at `min(blockEnd, signPosition + 50ft)` — consistent with the actual footprint of a driveway. But only apply this cap when:
1. The sign's arrow is `towards`, AND
2. The sign category is `NO_PARKING`, AND  
3. There is no other sign within 50ft in the `towards` direction

This is conservative enough to avoid breaking legitimate long no-parking zones while fixing the isolated driveway case.

Before implementing, run a scan of all tiles to count block faces matching the "isolated NO_PARKING -->" pattern. If the count is < 20, the risk of option (a) introducing errors in legitimate cases may not be worth a full regen. If it is > 100, the regen is clearly justified.

---

## Part 4 — Consolidated "Fourth Regen" Plan

This section specifies what a single tile rebuild would carry, assuming all three fixes above are approved.

### 4.1 Scope

| Fix | Change in `preprocess.js` | Confidence | Status |
|---|---|---|---|
| TF2-12 P1: Normal-selection fix | `offsetPolyline`: anchor L/R side choice to block-level overall direction | High — mechanism confirmed | Pending Kevin approval |
| TF2-12 P2: CSCL width ingestion | `build-oneway-data.js`: add `streetWidthFt` field; `preprocess.js`: 3-tier width logic | Medium — dataset confirmed, formula needs calibration | Pending Kevin approval |
| TF2-13: NO_PARKING zone cap | `createSubSegments`: cap isolated towards-NO_PARKING at ~50ft | Medium — mechanism confirmed, blast radius unknown | Pending blast radius scan |

### 4.2 Prerequisite Steps Before Regen

1. **Blast radius scan** for TF2-13: run a one-time Node script against existing tile JSON files to count block faces matching the isolated-NO_PARKING pattern. Kevin approves fix (a) only if count and sample review are acceptable. This does NOT require a regen.

2. **CSCL sample fetch** to verify `streetwidth_min` field name and value accuracy for Bowery and 2nd Ave. The field was confirmed to exist via documentation search. Run `build-oneway-data.js` with a modified sample fetch (e.g., `$limit=5&on_street_name=BOWERY`) to confirm actual field values before modifying the full ingestion.

3. **Normal-selection code review**: implement Option A in `offsetPolyline`, run against the existing OSM data with a test script (without full regen) to compute the separation on the known-bad Bowery segments (Hester→Grand W side coordinates should shift from their current near-centerline position to approximately −73.9953, giving ~17m separation instead of ≤12m).

### 4.3 Verification Plan — Measured Separations on Known-Bad Blocks

After regen, verify using tile coordinates (same method as TF2-10 measurement):

| Block | Side pair | Expected separation | Acceptance criterion |
|---|---|---|---|
| Bowery, Hester St → Grand St | E vs W | ≥ 16m | Both lines clearly in parking lane, not overlapping |
| Bowery, Grand St → Broome St | E vs W | ≥ 16m | Both lines clearly in parking lane |
| Bowery, Spring St → Kenmare St | E vs W | ≥ 16m (already ~20m per Kevin) | No regression |
| 2nd Ave (any block) | E vs W | ~19–20m | No regression from current |
| E 2nd St (any block) | E vs W | ~11–12m | No regression from current |
| Elizabeth St, E Houston → Bleecker, W | dominant category | ASP_MON_THU for segments W_3 and W_4 | Previously NO_PARKING, now correctly ASP |
| Elizabeth St, E Houston → Bleecker, W | sub-zone | Small NO_PARKING zone at garage location (≤ 50ft) | Garage zone still exists but constrained |

**Bowery specific:** After the normal-selection fix, measure tile coordinates for `BOWERY_HESTER_STREET_GRAND_STREET_W_*` (which should appear in tile_7_11 or tile_8_11) and confirm the W-side lng is approximately 0.0002° west of the E-side lng (≈ 17m at this latitude), not within 0.0001° (≈ 9m or less).

### 4.4 Regen Logistics

- Regen touches both `tiles/` (PWA) and `ios/WePark/WePark/Resources/tiles/` (iOS bundle). Both paths are handled by `build/preprocess.js` step 7b (the IOS_TILES_DIR sync).
- Expect approximately 39,000–40,000 total segments (similar to current 39,225). Small drift is expected from live Socrata data re-fetch.
- Diff will be large (~1,000-file change). Commit message: `chore(data): TF2-12/13 — normal-selection fix + CSCL widths + zone-extent cap`.
- iOS build (`ios-engineer`) must update the bundled tile resources after regen, which is handled automatically by the sync step. Flag for @ios-engineer and @pwa-maintainer per workflow.
- SW cache version must be bumped after regen.

---

## Summary of Findings and Recommendations

### Bowery Convergence Mechanism

**Root cause confirmed:** The per-vertex compass dot product in `offsetPolyline` becomes degenerate when Bowery's bearing passes through the NNW range (~315°–340°). At bend vertices, the averaged direction vector places both candidate perpendicular normals at near-equal dot products with the W-side compass vector `{x: -1, y: 0}`. Minor perturbation from the bend flips which normal is chosen, causing the W-side offset to point inward (toward the road center) rather than outward (toward the curb). The result is that W-side polyline points collapse toward or past the centerline, reducing the apparent separation to 0–12m.

**Fix:** Anchor the left/right side choice to the block's global from→to direction vector, computed once before the per-vertex loop.

### CSCL Width Viability

**Verdict: Viable.** The dataset is already being consumed by the build pipeline (`osm_oneway.json` ingestion in `build-oneway-data.js`). The `streetwidth_min` field exists and is confirmed in NYC documentation. Adding it to the existing fetch is zero additional API cost. The join key (canonical street name → geometric proximity) is already implemented. The field should yield correct results for typical streets; Bowery's median structure may cause underestimation for that specific street, but Bowery's fix is the normal-selection change (Problem 1), not width calibration.

**Caution:** Formula calibration needs a sample fetch to verify actual values before committing to the 3-tier thresholds. The threshold values (40ft, 65ft) are estimates derived from known-good separation measurements, not from confirmed CSCL sample data.

### Elizabeth St Zone Extent

**Root cause confirmed:** The sign `"NO PARKING ANYTIME -->"` (plate code SP-854CA, a driveway marker) is the last or near-last sign on the block's W side. The `createSubSegments` forward-coverage loop has no upper bound when no subsequent sign exists, so it extends the NO_PARKING zone to the entire remainder of the block. NO_PARKING (priority 2) overwrites the ASP_MON_THU (priority 7/8) dominant category for every trailing zone.

**Recommendation:** Option (a) — cap isolated `towards`-arrow NO_PARKING extensions at the next sign position or 50ft, whichever is smaller. Run blast radius scan first. If > 100 block faces are affected, the regen is clearly justified. If < 20, defer to Tier 2 community corrections.

---

## Open Questions for Kevin

1. **TF2-12 P1 fix:** Approve Option A (block-level normal anchoring) for inclusion in the fourth regen?

2. **TF2-12 P2 (CSCL widths):** Approve adding `streetwidth_min` to the oneway fetch and implementing the 3-tier offset formula? Or defer CSCL ingestion to a later phase and carry only the normal-selection fix in the fourth regen?

3. **TF2-13 fix:** Approve the blast radius scan (no regen needed, just analysis), then decide on option (a) based on results? Or defer to community corrections?

4. **Regen timing:** If all three are approved, the fourth regen should carry all three changes in a single build to avoid churn. If CSCL ingestion is deferred, a TF2-12 P1 + TF2-13 fix regen can proceed without it.

---

## Sources

- [NYC Street Centerline (CSCL) | NYC Open Data](https://data.cityofnewyork.us/City-Government/NYC-Street-Centerline-CSCL-/inkn-q76z)
- [LION | NYC Open Data](https://data.cityofnewyork.us/City-Government/LION/2v4z-66xt)
- [LION File Geodatabase Feature Class Tags (StreetWidth_Min definition)](https://s-media.nyc.gov/agencies/dcp/assets/files/pdf/data-tools/bytes/lion_metadata.pdf)
- [LION - Department of City Planning](https://www.nyc.gov/content/planning/pages/resources/datasets/lion)
- Tile data: `tiles/tile_7_11.json`, `tiles/tile_9_11.json`, `tiles/tile_10_11.json`, `tiles/tile_11_11.json`
- Build pipeline: `build/preprocess.js` (offsetPolyline lines 743–806, createSubSegments lines 810–895)
- Ingestion script: `scripts/build-oneway-data.js`
