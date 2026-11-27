# DT35-7 — W Houston St curb lines drawn mid-road / too many lines — Investigation + proposed fix

**Status:** investigation and proposal only. No pipeline code changed, no tiles regenerated, no Supabase, no Xcode.
**Date:** 2026-11-27 · **Author:** @backend-data
**Trigger:** `docs/field-testing-log.md` DT35-7 (build 35 drive test).
**Data examined:** `tiles/` (1,077 tiles, `generatedAt 2026-11-25T22:59:10Z`; byte-identical to `ios/WePark/WePark/Resources/tiles/`, 1077/1077 files, so this is exactly what build 35 shipped), `osm_data.json` (what `build/preprocess.js` reads as `OSM_STREETS`), `street_widths.json` (CSCL `inkn-q76z`), `osm_oneway.json`, and `build/preprocess.js` run offline through its own module exports (no network).
**Prior work read first (not repeated):** `ft21-carriageway-investigation.md`, `ft21-width-offset-investigation.md`, `ft21-option-a-feasibility.md`, `tf2-12-13-curb-geometry-spec.md`, `tile-geometry-investigation.md`.

---

## TL;DR

Three independent faults stack on Houston. None of them is "a missing width".

1. **The +7 m "divided median allowance" is wrong for Houston because the OSM chains are not median centerlines.** In the committed `osm_data.json`, Houston is drawn as one OSM chain per carriageway (about 15 m apart), and 94% of W Houston chain vertices (52/56 on chain 0, 26/27 on chain 2) and about 86% of E Houston's (192/224) lie within 3 m of a CSCL carriageway row. So they are carriageway centerlines. `DIVIDED_STREET_ALLOW_LIST` assumes the OSM line is the median center and adds `DIVIDED_MEDIAN_ALLOWANCE_M = 7.0` on top of the carriageway half-width. Result: `W HOUSTON ST` offset = **12.49 m** (E Houston 12.79 m) measured from a line that is already in the middle of its carriageway. The real outer curb is about 5 m from that line.
2. **Each block face picks whichever OSM chain it happens to resolve to, then offsets by compass side from it.** For a face on the "wrong" carriageway chain, the line lands inside the roadway: a N face on the south chain ends up at 12.49 m north of it, which is about 3 m from the north carriageway's centerline (-2.5 to -3 m in the table below). An S face on the north chain ends up at -12.5 m, in the middle of the south carriageway. That is the "dotted line in the middle of the road" Kevin saw.
3. **FT-21 Option A (the per-carriageway fix) is almost entirely switched off on Houston by its own ambiguity guard.** Only 2 of 24 W Houston faces and 2 of 40 E Houston faces were Option A matched. `buildCarriagewayPairs()` rejects 14 of 20 candidate rows on W Houston (24 of 42 on E) as "ambiguous" because the *next chunk of the same opposite carriageway* is only 0.3-0.4 m farther away than the true partner (ratio about 1.02; the guard needs 1.25). Where Option A did match, the lines are correct (N +6.1 m and S -18.9 m from the north carriageway, against curbs at about +6 and -21), which proves the approach is sound.

Plus, a fourth, separate defect on W Houston **west of 6th Ave**: CSCL and the web say it is a single one-way (westbound) 34 ft carriageway, but it is still on the "divided" allow-list, so the lines go out to ±12.49 m: 7 m **beyond** each curb, 25 m apart on a road about 10 m wide. Not mid-road, but wrong.

"More lines than curbs" is explained by (2): no W Houston cross-section ever carries more than 2 lines (checked every 10 m), but the pair of lines jumps between **8 different tracks** along the dual stretch (+22.5, +12.5, +6, -2.5, -3, -12.5, -19, -28 m from the north carriageway), so a driver sees lines in the lane, in the median zone, and past the curb on successive blocks against 2 real curbs. One real duplicate was found on E Houston (see 1.3).

**Recommended fix:** (a) delete the divided allowance for streets whose OSM chains are carriageway lines, pick the carriageway per face side (outer curb only), and fix Option A's ambiguity guard to ignore same-carriageway neighbours; (b) add `build/curb-overrides.json` as the reviewable escape hatch. Details in section 3. A Houston-only dry run needs no network and no regen.

---

## 0. How to read the numbers

* Coordinates: for W Houston I use `s` = metres along OSM chain 0 from the Bowery end (west is increasing), `u` = metres north (+) / south (-) of chain 0. Chain 0 is the **north (westbound) carriageway centerline**; the south (eastbound) carriageway sits at `u ≈ -15.5`. Curbs that parking should sit on: **north curb about +5 to +6.7, south curb about -21 to -22** in the dual stretch; about ±5.2 in the single one-way stretch.
* `err` (used for Houston and for the ranking in section 4) = how far a drawn line is from the outer curb, where the curb is taken as the outermost CSCL carriageway row on that compass side within 40 m, plus half that row's `stWidthFt`. `err > +3` = outside the curb; `err < -3` = inside the roadway (mid-road). It is a heuristic: noisy on diagonals and plazas. Two W Houston sub-segments (`AVENUE_OF_THE_AMERICAS_VARICK_STREET_S_3/_S_4`) report -29/-36 purely because the checker latched onto a distant row; their drawn lines are really at `u = -12.5`, consistent with their neighbours. Ignore those two numbers.
* All numbers are reproducible with `docs/qa/dt35-7-houston-check.js` (read-only).

---

## 1. Inventory: what is drawn today

### 1.1 Centerline source, width, offset (per street)

| | W Houston | E Houston (comparison) |
|---|---|---|
| Geometry source | `osm_data.json` `"West Houston Street"`, 7 chains | `"East Houston Street"`, 10 chains (chain 0 is one 224-point hairpin: out along one carriageway, back along the other, see the #35 comment in `getBlockPolyline`) |
| Where the chains sit | Chains 0 and 2 are two parallel carriageway lines, 15 m apart, between Broadway and 6th Ave (`s` 0-600). West of 6th Ave (`s` 620-1318) only chain 0 exists. | Two legs about 14-20 m apart for the whole length |
| Divided? (CSCL) | Bowery..6th Ave: yes, 2 one-sided rows per block (FT right-addressed 44 ft = north/westbound; TF left-addressed 34-44 ft = south/eastbound). **6th Ave..West St: single both-sided one-way row, FT, 34 ft** | Yes, one-sided FT/TF rows, 38-44 ft each, 17-20 m apart |
| Allow-list | on `DIVIDED_STREET_ALLOW_LIST` | on it |
| Width used | median of all W Houston rows = 36 ft -> `7.0 + 36×0.3048/2` = **12.49 m**, used for every block | median 38 ft -> **12.79 m** |
| Option A (per-carriageway) matched | 2 of 24 faces (`AVENUE OF THE AMERICAS>MACDOUGAL S`, `MACDOUGAL>6TH AVENUE N`), offsets 4.6 and 5.9 m | 2 of 40 faces |
| Curb lines drawn | **91 sub-segments / 24 block faces** (6 N + 8 S faces in the dual stretch, 5 N + 5 S in the one-way stretch) | **134 sub-segments / 40 faces** |
| Faces within ±3 m of curb | **1 of 24** (7 inside, 16 outside) | 5 of 40 (9 inside, 26 outside); by sub-segment 21 ok / 20 inside / 93 outside of 134 |

Offset applied to each side: always the same number on both sides (the code has no notion of "this carriageway's outer curb"). `getCurbOffsetFromWidth()` returns the per-street constant; `offsetPolyline(line, side, offset)` pushes the OSM slice that many metres toward the compass side.

### 1.2 W Houston, every block face (reference frame of section 0; `u` = mean lateral position of the drawn line)

Dual stretch (Broadway to 6th Ave). Correct targets: N ≈ +5.9 (44 ft carriageway) / +5.2 (34 ft); S ≈ -21.

| `s` range (m) | Face | Side | Drawn `u` | Verdict |
|---|---|---|---|---|
| 22-65 | MERCER>BROADWAY | S | -28.1 | outside the S curb by 7 m |
| 24-66 | BROADWAY>MERCER | N | -3.1 | **mid-road**, inside the N carriageway (8 m inside the curb) |
| 94-305 | MERCER>LA GUARDIA | N | +12.5 | outside by 6.6 m |
| 94-141 | GREENE>MERCER | S | -12.5 | **mid-road** (in the S carriageway) |
| 175-225 | WOOSTER>GREENE | S | -12.5 | **mid-road** |
| 245-302 | WEST BROADWAY>WOOSTER | S | -12.5 | **mid-road** |
| 326-377 | LA GUARDIA>THOMPSON | N | +12.5 | outside |
| 326-377 | THOMPSON>WEST BROADWAY | S | -27.3 | outside by 6 m |
| 397-454 | SULLIVAN>THOMPSON | S | -12.5 | **mid-road** |
| 397-454 | THOMPSON>SULLIVAN | N | +12.5 | outside |
| 475-530 | MACDOUGAL>SULLIVAN | S | -2.5 | **mid-road, inside the N carriageway** (18 m from its curb) |
| 475-530 | SULLIVAN>MACDOUGAL | N | +22.5 | 16 m outside (also hits a short stub chain 4 near MacDougal) |
| 550-579 | AVE OF AMERICAS>MACDOUGAL | S | -18.9 | OK (Option A matched) |
| 553-597 | MACDOUGAL>6TH AVENUE | N | +6.1 | OK (Option A matched) |

One-way stretch (6th Ave to West St, 11 blocks, 22 faces). One chain, one row, CSCL width 34 ft, so curbs at about ±5.2 m. Every face is drawn at **+12.5 (N) / -12.5 (S)**, i.e. about 7.3 m past each curb. Measured per-face errors +6.5 to +8 m (checker), no face inside tolerance.

### 1.3 Duplicates / "extra lines"

* No face pair on W Houston duplicates another (all 225 tile ids are unique; every overlap flagged at 4 m tolerance on W Houston is two tiny adjacent sub-segments of one face).
* **Real duplicate (E Houston):** `EAST_HOUSTON_STREET_AVENUE_A_AVENUE_D_N_0` (52 m, UNKNOWN) sits exactly on top of the 7 sub-segments of `AVENUE D>EAST 2ND STREET N`. It is a stray from/to pairing from the sign grouping (Avenue A to Avenue D is not a block). Cosmetic, but it is one of the "more lines than curbs" on E Houston. It belongs on the suppress list of the override table.
* Cross-section count: W Houston never has more than 2 distinct lines at any point; but over its 600 m dual stretch the pair of lines wanders over 8 different lateral tracks vs 2 real curbs. That is what reads as extra lines on a screen showing 3-4 blocks.

---

## 2. Why: exact mechanisms

### 2.1 The +7 m allowance double counts (the "outside" half of the problem)

`initWidths()` (`build/preprocess.js` about line 2981) for allow-listed streets computes `rawOffset = DIVIDED_MEDIAN_ALLOWANCE_M (7.0) + medianWidthM/2`. The comment block above it (about line 1495) states the premise: "OSM centerlines placed at the full-street center (median center), equidistant from both outer curbs". That premise is false for the committed Houston geometry: the chains sit on the carriageways (vertex check above). So the 7 m is pure error on every Houston block: the correct distance from a carriageway centerline to its outer curb is `stWidthFt×0.3048/2` (5.2-6.7 m). For Bowery (13 of 25 faces outside), Allen, Delancey (27 of 44 outside, clamped at 14 m) the same premise applies and should be re-checked the same way (section 4).

The 10 m name-tier floor (`WIDE_CROSSTOWN_NAMES` contains both Houstons) would also still bite after removing the allowance, because the single-carriageway branch does `max(0.88×halfWidth, tierFloor)`. For a chain that is a carriageway centerline the floor must not apply.

### 2.2 Per-face chain choice (the "mid-road" half)

`getBlockPolyline()` resolves a face's `from`/`to` cross streets to intersection candidates and slices *one* OSM chain between them. On a street drawn as two carriageway chains, which carriageway you get is an accident of the candidate pairing (N and S faces of the same physical block have reversed from/to names, and ties go either way). `offsetPolyline()` then offsets that slice toward the face's compass side by 12.49 m. Four cases appear in the data:

| Face side | Resolved chain | Result |
|---|---|---|
| N | north (chain 0) | +12.5: 6.6 m too far out |
| N | south (chain 2) | -3: mid-road |
| S | south (chain 2) | -28: 7 m too far out |
| S | north (chain 0) | -12.5: mid-road |

Direction-of-travel view: each carriageway is one-way; the parking lane is on the right of travel. WB (north chain) -> right = north curb. EB (south chain) -> right = south curb. So a carriageway should only ever draw its **outer** side, and a N face may only attach to the carriageway whose right is north. The current code never consults this.

### 2.3 Option A would have fixed most of it but is defeated by its own guard

`buildCarriagewayPairs()` found 1 pair on W Houston and 2 on E Houston. Instrumenting its exact logic: W Houston has 20 one-sided candidate rows: 14 rejected `ambiguous`, 2 `noOpposite`, 2 `notMutual`, 2 matched. E Houston: 42 candidates: 24 ambiguous, 6 noOpposite, 8 notMutual, 4 matched. Example ambiguous rows (best vs second distance, metres): R108-128 15.7 vs 16.1; L63-85 16.5 vs 16.9; L19-37 16.1 vs 16.5; E Houston L268-298 17.1 vs 17.2. The "second best" is the **adjacent row of the same opposite carriageway** (CSCL chops each carriageway per block, so the neighbouring chunk is nearly as close as the true partner). Since the guard needs second ≥ 1.25 × best, essentially every interior chunk is rejected. That is a bug in the guard's notion of "alternative", not evidence of real ambiguity. `blocksNoPairInRange 21/24` on W Houston is the downstream symptom.

### 2.4 Missing/wrong width?

Not the cause. W Houston CSCL widths are present on every row (34/36/44 ft; one both-sided 24 ft ramp stub). The width itself is used correctly only in the Option A branch. One caveat to confirm on the street: 34 ft curb-to-curb for the one-way stretch (6th Ave to West St) is what CSCL says; if the real roadway is wider the single-carriageway offset should be raised via the override table, not via the allowance.

---

## 3. Proposed fix

### (a) General rule: "each carriageway draws only its outer curb"

1. **Stop adding the divided allowance where the chain is a carriageway line.** Test it from data rather than a hand list: a street qualifies as "carriageway-chained" when most vertices of its OSM chains lie within 3 m of a CSCL row (done above: Houston 94% W, 86% E, run it for Bowery, Allen, Delancey, Park Ave before trusting). For those streets drop `DIVIDED_MEDIAN_ALLOWANCE_M` and the name-tier floor; offset = `0.88 × stWidthFt×0.3048/2` of the CSCL row nearest the chosen line (this is exactly what Option A already does and was correct on both matched faces). `DIVIDED_STREET_ALLOW_LIST` becomes empty or is removed; Forsyth-style mistakes cannot recur because membership is measured.
2. **Pick the carriageway per face side, not per accident.** For a face with compass side X, take the resolved slice plus its sibling carriageway slice (other OSM chain/leg of the same street between the same snapped intersections: parallel within 20°, 8-35 m lateral, length ratio 0.7-1.4) and use whichever is more outward toward X. The inner carriageway is never drawn from the median side, so the line count is exactly one per outer curb. Cross-check invariant for QA: the chosen carriageway's right-of-travel (from `oneway_toward`) must equal the face side; if not, flag instead of draw.
3. **Where no sibling exists** (W Houston 6th Ave to West St, one-way): no divided treatment at all; offset 0.88 × half-width of its row = 4.6 m (34 ft). Both sides still drawn (parking both sides).
4. **Fix Option A's ambiguity guard** (the alternative: a more general route to the same result): when computing `secondDist` in `buildCarriagewayPairs()`, ignore candidate rows that touch or are within a few metres of the best row's polyline end points (same carriageway chain), or first fuse consecutive same-side rows end-to-end into carriageway chains and pair the chains. Re-run the harness: expect W Houston to go from 2 to about 14 matched faces and E Houston from 2 to about 30.
5. Order of precedence: per-face override (b) > Option A match > general rule (1-3) > legacy name-tier. Unchanged behavior for every street not carriageway-chained (byte-identical regen except Houston-class streets, assertable with `scripts/diff-tiles-residual.js`).

Expected effect on W Houston (re-seated lines, see section 5; independent of the exact implementation): dual stretch N lines about +5 to +7 and S lines about -20 to -22 from the north carriageway; one-way stretch ±4.4 to ±5. Line count unchanged (91 sub-segments), faces drawn once on the outer curb.

Risks: (i) The CSCL width-to-curb mapping is trusted (0.88×half): verify against satellite imagery in geojson.io before regen; (ii) #27 determinism: face resolution order matters, re-run `scripts/test-pipeline-determinism.js` and `scripts/test-width-offset-resurrection.js` (the latter encodes today's Houston +6.5/+6.8 expectations and must be updated, not just run); (iii) iOS ships its own copy of the tiles under `ios/WePark/WePark/Resources/tiles/`, so a regen must be copied there too (@ios-engineer to confirm bundle step); (iv) no schema or client change is needed, tiles keep the same shape.

### (b) Manual override table

**Location:** `build/curb-overrides.json` (next to `build/preprocess.js`, committed, loaded in `main()` right after `pickCarriagewayForBlock()` and before `offsetPolyline()`).

**Key:** the block-face id, i.e. the existing segment id without the `_<n>` sub-segment suffix: `${street}_${from}_${to}_${side}` with whitespace to `_` (e.g. `WEST_HOUSTON_STREET_BROADWAY_MERCER_STREET_N`). The offset in `main()` is block level (`blockCurbOffset`), so a face is the right unit; sub-segments inherit.

```json
{
  "version": 1,
  "overrides": [
    { "face": "WEST_HOUSTON_STREET_BROADWAY_MERCER_STREET_N",
      "base": "outer-carriageway", "offsetM": 5.9,
      "note": "DT35-7: resolved on S chain, drew mid-road", "verified": "YYYY-MM-DD" },
    { "face": "WEST_HOUSTON_STREET_6TH_AVENUE_VARICK_STREET_N",
      "offsetM": 4.6, "note": "one-way WB 34 ft, no median" },
    { "face": "EAST_HOUSTON_STREET_AVENUE_A_AVENUE_D_N", "suppress": true,
      "note": "stray from/to pairing, duplicates AVENUE_D>EAST_2ND_STREET N" }
  ],
  "streetDefaults": [
    { "street": "WEST HOUSTON STREET", "offsetM": 4.6 }
  ]
}
```

Fields: `offsetM` replaces the offset magnitude; `base: "outer-carriageway"` forces the sibling-pick of rule (a)2 for that face; `suppress: true` drops the face (extra/duplicate line); `streetDefaults` is optional and loses to an exact `face` entry. Behaviour on bad input: an override whose face id is not produced by this build is a **hard build error** (catches renames/typos), and the build prints "N overrides applied" plus the list. Reviewability: the file is the whole table; every row carries a note and a verified date; fewer than about 30 rows expected.

**How a fix is verified (no simulator, no network):**
1. `node docs/qa/dt35-7-houston-check.js --street "WEST HOUSTON" --write-geojson` prints per-face `err`; overridden faces must be within ±2 m, others unchanged.
2. Drop the GeoJSON into geojson.io, switch to satellite, and confirm lines sit on the curb, one per curb. (Layers are colored: red/blue = current N/S, green = proposed, gray = CSCL rows, black = OSM chains.)
3. Assert tile counts and ids are unchanged except suppressed faces; diff only the Houston tiles (about 30) with `scripts/diff-tiles-residual.js`.
4. Kevin spot-check on device once, driving or walking Broadway to 6th Ave and 6th Ave to Hudson, as the final gate.

---

## 4. Other Manhattan streets likely to share the problem (ranked)

Counts are tile block faces from the heuristic of section 0 (in = more than 3 m inside the curb, out = more than 3 m beyond, ok = within 3 m). Faces of a street are all faces in tiles, not only the divided stretch.

| Rank | Street | Faces | in / out / ok | Why it is likely bad | Confidence |
|---|---|---|---|---|---|
| 1 | **Park Avenue** (+ Park Ave South) | 209 (+29) | 95 / 51 / 63 (12/10/7) | 190 of 204 CSCL rows one-sided = true median; OSM dual share 67%, 18 m apart; **not on the allow-list**, flat 10 m. Worst by volume of inside (mid-road) faces: 45% | high |
| 2 | **Delancey St** | 44 | 8 / 27 / 9 | 45 of 48 rows one-sided; allow-listed at the 14 m clamp, same +7 m error as Houston, lines about 4 m too far out | high |
| 3 | **E Houston St** | 40 | 10 / 23 / 7 | same defect as W Houston; plus the stray Ave A>Ave D duplicate | high |
| 4 | **Bowery** | 25 | 4 / 13 / 8 | allow-listed; carriageway mix (4 of 25 inside) | medium |
| 5 | **Allen St** | 16 | 8 / 6 / 2 | median mall street, allow-listed, 97% dual in OSM | medium |
| 6 | **Lenox Ave / ACP Jr Blvd** | 63 / 35 | 27/30/6 and 12/5/18 | 69 of 75 and 95 of 123 rows one-sided; not allow-listed; need a satellite check that they really are divided | medium |
| 7 | **Riverside Dr, 12th Ave, West St, 11th Ave** | 106 / 45 / 41 / 76 | Riverside 24/58/24 | OSM duplicated carriageways and ramps; West St and 11th mostly both-sided rows, so mostly OK; Riverside is hairpin ramps plus service roads | low-medium |
| 8 | **Canal St** | 48 | 8 / 14 / 26 | only 13 of 42 rows one-sided: divided only in stretches (near Bowery/Chrystie and the tunnel approach) | low |
| 9 | **Broadway** | 413 | 115 / 137 / 161 | 244 one-sided rows but Broadway's divided stretches are plazas/malls; checker is noisy on this diagonal. Biggest face count: do **not** auto-apply (a)1 street-wide; verify by sections | low (needs hand check) |

Checked and fine: **14th, 23rd, 34th, 42nd, 57th, 125th** (both-sided single CSCL rows, 8 to 16 of 12-16 faces ok, e.g. W 14th 10/12 ok, W 42nd 16/16, W 57th 16/16, E 125th 12/12). **E 14th** is borderline (4/5/11, 18 of 25 rows one-sided near Stuy Town/Union Sq). Madison St and Centre St are fine (22/23 and 14/16 ok). Forsyth is a one-way couplet with Allen and is correctly off the list.

---

## 5. Artifacts

* `/Users/kevinhoxha/repos/parkmap/docs/qa/dt35-7-houston-current-vs-proposed.geojson` (185 KB, drag into geojson.io). Layers by `layer` property: `current-tile-line` (red N, blue S, with the real tile id in `name`), `proposed-line` (green, re-seated at 0.88 × half-width outward of the outermost CSCL row on that side), `ref-cscl-carriageway-row` (gray), `ref-osm-chain` (black, the geometry the pipeline actually slices). 217 of 225 Houston sub-segments have a proposed line; 8 had no CSCL row within 40 m and are shown as current only. The proposed layer is a visualization of the rule's target, not the pipeline's literal output (it re-seats vertices per CSCL row; expect small end effects at the 6th Ave junction around `s` 600-650).
* `/Users/kevinhoxha/repos/parkmap/docs/qa/dt35-7-houston-check.js`: read-only checker and GeoJSON writer. `--street "WEST HOUSTON"` or any street substring; `--write-geojson` rewrites the file above (default checks only prints).

## 6. Open questions for Kevin

1. Where exactly was the drive? The mid-road lines in this data are Broadway to 6th Ave (dual stretch). West of 6th Ave the lines are far outside the curb instead, which may look "off the road" rather than mid-road.
2. Is W Houston really one-way westbound west of 6th Ave with 34 ft paved width? CSCL (both-sided FT row) and web sources say yes; worth one satellite check before the single-carriageway offset is trusted.
3. OK to treat Park Ave as the next street after Houston, since it is the largest mid-road exposure (95 faces) and currently on no list?
