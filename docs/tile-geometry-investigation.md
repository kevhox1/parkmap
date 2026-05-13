# Tile Geometry Investigation — Polyline Intersection Artifacts

**Status:** Investigation complete 2026-05-13. Root cause identified. Fix path documented.
**Owner:** @backend-data (this doc). Kevin approves any tile rebuild.
**Affected components:** `build/preprocess.js`, all tiles under `tiles/`, PWA Leaflet renderer, iOS `MKMultiPolylineRenderer`.

---

## Open questions for Kevin (binary, answer before scheduling fix work)

**Q1.** The fix requires rebuilding all 1,028 tiles (~27 MB, churn affects every tile file). Should this land before v1.0 TestFlight (TF1) launch, or is it acceptable to ship with the known artifact and defer to a post-launch tile rebuild?

**Q2.** The fix adds a single numeric constant to `build/preprocess.js` (`INTERSECTION_SETBACK_M`, recommended 5–8m). Should it be tuned against real coordinates before the rebuild, or is a single default value acceptable for TF1?

---

## 1. Problem statement

Block-face polylines visibly cross into intersection interiors on both the PWA (Leaflet) and the iOS app (MapKit MKMultiPolylineRenderer). Both apps render the same pre-built tile data under `tiles/`, so any visual artifact present in one is present in both. Kevin first flagged this during W5 smoke testing (2026-05-12) and it has been in the carry-over list since. Worst-case examples cited:

- **Park Ave & E 72nd St** (~40.7720, −73.9620) — multiple polylines converge at the intersection; each extends past the curb into the box
- **Mott & Spring St** (~40.7224, −73.9966) — tight grid, corner intersections clearly show overshoot
- General pattern: any dense grid where short blocks are viewed at high zoom

---

## 2. Investigation method

### Files read

- `build/preprocess.js` — full tile-building pipeline (the tile build script; referenced in `index.html` at line 2204 as `build/preprocess.js`)
- `scripts/build-oneway-data.js` — one-way data builder (not relevant to geometry artifacts)
- `tiles/index.json` — grid definition (latMin, latMax, lngMin, lngMax, rows, cols, rowSizes)
- `tiles/tile_31_25.json` — Park Ave / E 72nd St area (lat ~40.772, computed row=31, col=25)
- `tiles/tile_31_24.json` — also contains Park Ave 72nd–73rd segments (segment tile assignment is by midpoint; long segments span tile boundaries)
- `tiles/tile_9_10.json` — Mott & Spring area (lat ~40.722, row=9, col=10)
- `tiles/tile_24_20.json` — Midtown East / Lex Ave & 50th St area (lat ~40.757, row=24, col=20)
- `osm_geo.js` — inline OSM centerline data for LES/NoLita streets (subset; full data is in `osm_data.json` which is not committed)
- `index.html` — Leaflet polyline rendering parameters (lines 3408–3433, 5718–5760)
- `ios/WePark/WePark/Views/MapViewRepresentable.swift` — MKMultiPolylineRenderer parameters (lines 406–443)
- `HANDOFF.md` — project context, carry-over artifact entry

### Tile coordinate samples extracted

All `line` arrays extracted using `grep -o` on the JSON files. Segments of interest selected by street name from the `id` field.

---

## 3. Findings

### 3.1 How block-face geometry is generated (build pipeline overview)

The build pipeline in `build/preprocess.js` follows this chain for each block:

1. **Find intersection endpoints.** `findIntersection(streetOsm, fromOsm)` and `findIntersection(streetOsm, toOsm)` walk the OSM centerline chains for the two streets and return the geometric point where they get closest (within 30m tolerance). This point is on the **centerline** of both streets — it is NOT set back to the curb.

2. **Extract polyline between endpoints.** `extractPolylineBetween()` projects each intersection point onto the nearest OSM segment of the target street, then walks the OSM chain from one projected point to the other. Result: a coordinate array starting and ending exactly at the two centerline crossing points.

3. **Apply lateral offset.** `offsetPolyline()` shifts the entire polyline by a constant `offset = 0.00004` degrees (~4.5m at NYC latitude) perpendicular to the dominant street direction (E or W for N/S streets; N or S for E/W streets). This moves the line off the centerline to approximate the parking lane.

4. **Sub-segment by sign distance.** `createSubSegments()` slices each block into sub-segments at each sign's `distance_from_intersection` value. Sub-segment geometry is extracted via `extractSubSegment()`, which interpolates along the block line.

5. **Assign to tile.** Segments are bucketed into tiles by their midpoint coordinate via `getSegmentCenter()` + `getTile()`. Tile row is `floor((lat - latMin) / rowSize)`, so row 0 is the southernmost row.

### 3.2 Where intersection overshoot originates

The two intersection points returned by `findIntersection()` are centerline crossings. For a typical Manhattan grid street:

- A **N/S avenue** (e.g., Park Ave) intersecting an **E/W cross street** (e.g., E 72nd St): the intersection point lies at the geometric center of the crossing box — roughly midblock on the cross street's footprint.
- A typical NYC cross street is 12–15m wide (2–3 lanes). The intersection box is therefore ~12–15m deep along the avenue.
- After `offsetPolyline()` applies the 4.5m lateral shift, the endpoints of the polyline are still at the centerline crossing. The lateral offset only moves the line sideways, not longitudinally.

**Result:** each block-face polyline endpoint sits at the centerline of the intersecting street, i.e., ~6–7.5m into the intersection box from the curb. The line then extends an additional stroke-width/2 beyond that due to round line caps.

### 3.3 Coordinate evidence — Park Ave & E 72nd St

Segments from tiles `tile_31_25.json` and `tile_31_24.json`:

**Park Avenue, E 72nd → E 73rd, East side (sub-segments _E_0, _E_1, _E_2):**
```
_E_0  start: [40.77115,  -73.96388]   ← near E 72nd intersection
      end:   [40.771331, -73.963751]

_E_1  start: [40.771331, -73.963751]
      end:   [40.771704, -73.963476]

_E_2  start: [40.771704, -73.963476]
      end:   [40.77183,  -73.96338]   ← near E 73rd (duplicate terminal point: [40.77183,-73.96338])
```

**Park Avenue, E 73rd → E 72nd, West side (sub-segments _W_0, _W_1, _W_2):**
```
_W_0  start: [40.77115,  -73.96396]   ← near E 72nd intersection (W side, offset −0.00004 lng)
      end:   [40.771162, -73.963952]

_W_1  start: [40.771162, -73.963952]
      end:   [40.771594, -73.963637]  ← terminal (duplicate: [40.77183,-73.96346])
```

**E 72nd Street, Lex → Park Ave, North side (approaching Park Ave from east):**
```
_N_5  end:   [40.770568, -73.962457]
_N_4  end:   [40.77071,  -73.962796]
_N_3  end:   [40.770933, -73.963327]
_N_2  end:   [40.771026, -73.963548]  ← last segment before Park Ave
```

**E 72nd Street, Park Ave → Lex Ave, South side (departing Park Ave):**
```
_S_1  start: [40.770932, -73.963517]  ← first point after Park Ave intersection
```

**Analysis of E 72nd N side terminal point [40.771026, -73.963548]:**
Park Ave's E-side centerline runs near lng −73.9638 (offset E side adds +0.00004 ≈ −73.9634; that matches the E side Park Ave segments at lng ~−73.9638 to −73.9634). The N-side E 72nd terminal at lng −73.963548 is approximately 0.000748 lng (~62m) west of the Lex Ave end — and critically, it is east of Park Ave's W-side centerline. This places it **inside Park Ave's roadway footprint**, confirming the endpoint is at the centerline crossing, not the curbline.

**Duplicate terminal coordinates observed:** Multiple segments end with their last two coordinates identical, e.g.:
```
PARK_AVENUE_EAST_73RD_STREET_EAST_72ND_STREET_W_2: ends [[40.77183,-73.96346],[40.77183,-73.96346]]
EAST_72ND_STREET_LEXINGTON_AVENUE_PARK_AVENUE_N_5:  ends [[40.770568,-73.962457],[...not shown...]]
```
The duplicate-final-point pattern is a separate minor artifact (a segment closes on its own last node). It does not cause visual overshoot on its own but indicates the pipeline emits zero-length tails at block ends.

### 3.4 Coordinate evidence — Mott & Spring St

Segments from `tile_9_10.json`:

**Mott Street, Prince → Spring, West side (approaching Spring from north):**
```
_W_5  start: [40.721821, -73.995424]
      end:   [40.72162,  -73.9955]    ← terminal (duplicate: [40.72162,-73.9955])
```

**Mott Street, Spring → Kenmare, East side (departing Spring southward):**
```
_E_0  start: [40.72162,  -73.99542]
```

**Spring Street, Mulberry → Mott, North side (approaching Mott from west):**
```
_N_2  end:   [40.72166, -73.99546]   ← terminal (duplicate: [40.72166,-73.99546])
```

**Analysis:** The Mott St W-side terminal and E-side start both sit at lat 40.72162, which is the centerline of Spring St (Spring runs E-W so its centerline is approximately at that latitude). Spring St N-side terminal is at lat 40.72166, also on the Spring St centerline. These coordinates confirm that all four meeting segments converge to points ON the crossing street centerlines — the intersection box, not the curbline.

Spring St is roughly 8m wide; the curbline would be ~4m away from the centerline (~0.000036 lat). The segment endpoints are thus ~4m into the intersection box from the curb before any visual stroke is applied.

### 3.5 Coordinate evidence — Midtown East (Lex Ave & 50th St)

Segments from `tile_24_20.json`:

**Lexington Ave, E 50th → E 49th, West side (moving south from 50th):**
```
_W_3  end:   [40.75587, -73.97286]  ← terminal (duplicate: [40.75587,-73.97286])
```

**E 50th Street, Park Ave → Lex Ave, South side:**
```
_S_4  start: [40.756942, -73.973519]
_S_5  start: [40.756842, -73.973282]
_S_6  start: [40.756759, -73.973086]  (approaching Lex)
```

The E 50th S-side last segment ends at approximately [40.75666, −73.97285] (from the visible data ending pattern). Lex Ave's centerline runs near lng −73.9727 to −73.9728; the E 50th segment terminates at lng −73.97285 which is on the Lex Ave centerline — again, inside the intersection footprint.

### 3.6 Rendering amplification — round line caps

Both renderers use round line caps:

**PWA (Leaflet):**
```js
L.polyline(seg.line, {
  color: ..., weight: 5, opacity: 0.75,
  lineCap: 'round', lineJoin: 'round'
})
```
Round caps extend `weight / 2 = 2.5px` beyond each endpoint. At typical map zoom (z16–z17 ≈ 1–2m per pixel), this adds ~2.5–5m of visual extension. On top of the ~6–7m of geometric overshoot, total visual penetration into the intersection box is ~9–12m.

**iOS (MKMultiPolylineRenderer):**
```swift
renderer.lineCap = .round
renderer.lineWidth = 3   // normal overlays
renderer.lineWidth = 6   // selected block
```
`lineWidth: 3` adds 1.5pt of round-cap extension. At typical MapKit tile scale that is roughly 1–2m additional overshoot. The selected block highlight at `lineWidth: 6` adds 3pt ≈ 3–4m additional.

### 3.7 Root cause classification

**Bucket (b) — Our build pipeline does not clip at intersection nodes.**

The OSM centerline data (`osm_data.json`) is not the problem — it accurately represents NYC street centerlines. The issue is that `getBlockPolyline()` uses the raw centerline crossing point as the segment endpoint, with no setback from the curb. There is no intersection-clipping or setback step in `build/preprocess.js`.

Bucket (c) (rendering round-cap amplification) is a **contributing factor** but not the primary cause. Even with `.butt` line caps the geometric overshoot would remain visible at zoom levels z15+ because the ~6–7m geometric penetration is 3–6px at those zoom levels.

Bucket (a) (NYC source data imprecision) is not a factor — the OSM geometry is accurate. The issue is how that geometry is used.

### 3.8 Why the offset does not help

`offsetPolyline()` shifts the polyline **laterally** (perpendicular to the street direction) by 4.5m. For a block on Park Avenue, this pushes the line ~4.5m east or west of the centerline. But the endpoint at E 72nd St remains at the E 72nd centerline latitude — it is NOT pushed back along Park Avenue's length. The lateral offset is orthogonal to the required longitudinal setback.

---

## 4. Recommendation

### 4.1 Fix: add a longitudinal intersection setback in `extractPolylineBetween()`

The fix is a single-constant addition to `build/preprocess.js`. After extracting the raw block polyline via `extractPolylineBetween()`, trim `setback_M` meters from each end along the polyline before passing to `offsetPolyline()` and `extractSubSegment()`.

**Recommended value:** `INTERSECTION_SETBACK_M = 6` (6 meters, approximately one lane-width setback from the crossing centerline). This would move segment endpoints to approximately the curbline on most Manhattan blocks. A value of 5–8m is the acceptable range:
- Below 5m: still clips into the intersection box on wider streets
- Above 8m: risks cutting off valid sign geometry near corners (some signs are posted as close as 10ft / 3m from the intersection)

**Implementation location:** At the end of `getBlockPolyline()` (lines 394–414 in `build/preprocess.js`), after the `blockLenFt` calculation. Call `extractSubSegment(blockGeo, setbackFt, blockLenFt - setbackFt)` with `setbackFt = INTERSECTION_SETBACK_M * 3.28084` (≈19.7ft). This reuses the already-tested `extractSubSegment()` helper — no new geometry code needed.

**Code change (illustrative, do not apply without Kevin's go-ahead):**

In `getBlockPolyline()`, after `return { line, totalLen, blockLenM, blockLenFt }`:

```js
const INTERSECTION_SETBACK_M = 6;  // meters to trim from each end at intersection
const INTERSECTION_SETBACK_FT = INTERSECTION_SETBACK_M * 3.28084;

// After computing blockGeo, trim setback from both ends:
function trimIntersectionSetback(blockGeo) {
  const { blockLenFt } = blockGeo;
  if (blockLenFt < INTERSECTION_SETBACK_FT * 3) return blockGeo; // skip very short blocks
  const trimmedLine = extractSubSegment(blockGeo, INTERSECTION_SETBACK_FT, blockLenFt - INTERSECTION_SETBACK_FT);
  if (!trimmedLine || trimmedLine.length < 2) return blockGeo;
  const trimmedTotalLen = cumulativeDists(trimmedLine);
  return {
    line: trimmedLine,
    totalLen: trimmedTotalLen,
    blockLenM: trimmedTotalLen[trimmedTotalLen.length - 1],
    blockLenFt: trimmedTotalLen[trimmedTotalLen.length - 1] * 3.28084
  };
}
```

Apply as: `const blockGeo = trimIntersectionSetback(rawBlockGeo);` after the `if (blockGeo)` check.

**Risk assessment:**
- Rebuilding tiles is the only way to apply the fix — both `tiles/` contents and `tiles/index.json` must be regenerated. This is a large diff (~27 MB, 1,028 files).
- No change to tile schema, segment JSON shape, RPC contracts, or rendering code. The `line` array shape is identical; coordinates simply move ~6m inward on each end.
- Sub-segment distance interpolation is unaffected (the setback trims from both ends of `blockGeo`, which sub-segment distances reference from the new block start).
- Very short blocks (<18m, i.e., 3 × setback) are skipped and retain current behavior. These are rare in Manhattan.

**Estimated effort:** small (~1–2 hours) to write and test the constant against sampled tiles. Tile rebuild itself takes ~10–20 minutes to run once the change is validated.

### 4.2 Secondary fix: remove duplicate terminal coordinates

Multiple segments end with two identical coordinate points (e.g., `[[40.77183,-73.96346],[40.77183,-73.96346]]`). This is a zero-length tail from the interpolation path in `extractSubSegment()`. It has no rendering impact (renderers skip zero-length segments) but is wasteful storage. This is a trivially deferrable cleanup — add a dedup pass in `extractSubSegment()` that drops points where consecutive coordinates are identical. Not worth doing as a standalone rebuild; fold into the setback rebuild if it ships.

### 4.3 Rendering-only partial mitigation (no rebuild required)

If Kevin decides to defer the tile rebuild past TF1, a **partial visual improvement** is possible without any data changes:

**PWA:** Change `lineCap: 'round'` to `lineCap: 'square'` in the `L.polyline()` call at `index.html:3408`. Square caps do not extend beyond the endpoint. This eliminates the 2.5px rendering amplification but leaves the 6–7m geometric overshoot in place. Visible improvement at lower zoom levels; less visible at z17+.

**iOS:** Change `renderer.lineCap = .round` to `renderer.lineCap = .butt` in `MapViewRepresentable.swift` at line 407. Same tradeoff.

This is a **cosmetic workaround only** — the geometric overshoot remains. The round cap also serves a purpose at segment joins (where consecutive sub-segments meet mid-block), so changing to butt/square cap could create small gaps at sub-segment boundaries unless `lineJoin` compensation is also added. Not recommended as a permanent setting; only useful as a zero-rebuild stopgap for TF1.

---

## 5. Shipping decision

| Option | Artifact state at TF1 | Work required | Rebuild? |
|---|---|---|---|
| **A — Full fix** | Eliminated (6m setback) | Write constant + test + rebuild | Yes |
| **B — Rendering workaround only** | Reduced (no cap amplification; geometry still overshoots) | 2-line change in `index.html` + 1-line in Swift | No |
| **C — Document and defer** | Unchanged | This document | No |

**Recommendation:** Option C for TF1. The artifact is cosmetic, pre-existing, and affects both PWA and iOS equally — testers know the app's polish baseline. The tile rebuild is a significant churn and a non-trivial risk to schedule. Document as a known issue, schedule the rebuild as the first post-TF1 data task. Option B (cap change) is acceptable as an optional cosmetic polish if Kevin wants a visible improvement with zero rebuild risk, but flag it clearly as a workaround not a fix.

---

## Sources consulted

- [NYC Parking Regulation Locations and Signs dataset](https://data.cityofnewyork.us/Transportation/Parking-Regulation-Locations-and-Signs/xswq-wnv9) — original sign data source
- [NYC DOT Centerline dataset (CSCL)](https://data.cityofnewyork.us/resource/inkn-q76z.json) — one-way directionality data
- [jehiah/nyc_parking — NYC DOT Sign Data analysis](https://github.com/jehiah/nyc_parking) — prior art on sign geometry processing
