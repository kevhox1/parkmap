# FT-21 — Does CSCL Support Option (A) Cleanly? (Gate Investigation)

**Status:** Investigation complete. Answers the one question Kevin's 2026-08-19 ruling put in
front of the pipeline work: *"does CSCL actually support (A) cleanly?"* **No pipeline code was
touched, no regen was run.** This is read-only, live-data investigation plus a written finding.

**Date:** 2026-08-24
**Author:** @backend-data
**Touches:** none (docs only — `build/preprocess.js` was read, not modified)

---

## TL;DR verdict

**Qualified GO on (A) — but not the "clean win" the framing implied, and it does not cover the
exact historical bad block everyone has been pointing at.**

- The core factual premise is **true and verified against live data**: CSCL (`inkn-q76z`) really
  does store divided streets as **separate centerline rows per carriageway**, each carrying house
  numbers for only one side of the street, materially laterally offset from each other (measured
  **19.2 m** apart on East Houston St at Bowery). This is not a guess — it's read directly off
  real coordinates below.
- There is **no join key** tying a carriageway pair together (`joinid`/`bphys_id` are null for
  every Manhattan row checked; `b5sc` is a street-level code, not a block-level one — see §2).
  Pairing carriageways requires a **proximity + address-parity heuristic** — exactly the class of
  heuristic Kevin's ruling was wary of. Say so plainly, as instructed: **yes, it needs a
  heuristic.**
- Block boundaries between the two carriageway rows of a pair **don't align exactly** (one CSCL
  split point can be 10ft+ off from the other's), so a real implementation needs geometric
  snapping/trimming, not a straight polyline swap.
- **Coverage is real but the CSCL-divided set is bigger than the 5-name allow-list** — up to
  roughly 9-10% of citywide segments if the divided-street set is correctly generalized beyond
  Houston/Bowery/Allen/Forsyth/Delancey (Park Ave and others are genuinely CSCL-divided but not on
  today's list). See §5.
- **Important counter-finding:** the specific Bowery blocks (Hester→Grand, Grand→Broome) that the
  *original* TF2-12 investigation named as the worst offenders are recorded in CSCL as **one
  undivided 60-70ft-wide carriageway**, not two. (A) has nothing to attach to there — see §1.3.
  The *current* FT-21 screenshot evidence (build 16, Houston×Bowery, stub on E Houston) lands on
  ground that genuinely IS CSCL-divided, so (A) targets today's live complaint correctly even
  though it would not have fixed the original TF2-12 complaint.
- (A) **replaces** the `DIVIDED_STREET_ALLOW_LIST` + `DIVIDED_MEDIAN_ALLOWANCE_M` fudge-formula
  branch specifically. It does **not** replace `WIDE_AVENUE_RE` / `WIDE_NS_NAMES` /
  `WIDE_CROSSTOWN_NAMES` / `getStreetCurbOffset` / the single-carriageway `CSCL_OFFSET_FRACTION`
  formula — those stay as the (unavoidable) fallback for undivided streets and for any block where
  the carriageway join fails. It is a **targeted replacement of one branch**, not a sixth
  heuristic layer stacked on top. See §4.

---

## 1. Query the real dataset

### 1.1 Field inventory (live, `inkn-q76z`, `/api/views/inkn-q76z.json` metadata)

Confirmed by pulling the dataset's own column metadata, not documentation:

```
physicalid, l_low_hn, l_high_hn, r_low_hn, r_high_hn, l_zip, r_zip, status, bike_lane,
trafdir, rw_type, pre_type, post_type, objectid, fcc, l_blockfaceid, r_blockfaceid,
avgtravtime, rwjurisdiction, nominaldir, accessible, nonped, boroughcode,
borough_indicator, seglocstatus, sandist_ind, lsubsect, rsubsect, continuous_parity_flag,
twisted_parity_flag, posted_speed, segmentlength, streetwidth, streetwidth_irr,
special_disaster, fire_lane, created_date, modified_date, within_bndy_dist,
truck_route_type, collectionmethod, from_level_code, to_level_code, b5sc, snow_priority,
joinid, bphys_id, carto_display_level, number_travel_lanes, number_park_lanes,
number_total_lanes, pre_modifier, pre_directional, post_directional, post_modifier,
full_street_name, bike_trafdir, shape_length, globalid, segment_type, segment_type_value,
street_name, stname_label
```

There is **no `divided` flag, no `carriageway_id`, no `roadway_id`** field. This confirms what
`scripts/build-street-widths.js` already noted from documentation (`streetwidth` is the only width
field — `streetwidth_min`/`streetwidth_max` genuinely do not exist on this dataset, they're a LION
file-geodatabase artifact, not a CSCL/Socrata field — that correction is already live in the repo
and matches what I see on the wire).

**What DOES express "this is one of two carriageways":**
1. **`trafdir`** — `FT`/`TF` (direction along digitization) vs `TW` (two-way, undivided).
2. **`l_low_hn`/`l_high_hn`/`r_low_hn`/`r_high_hn`** — on a genuinely divided street, each
   carriageway row carries house numbers for **only one side** (the other pair is `0`/`0`). On an
   undivided street, a single `TW` row carries **both** sides' numbers.
3. **Geometry** — the two carriageway rows are laterally offset polylines, not the same line
   tagged twice.

There is no single field that says "divided: yes/no" — it's inferred from the *combination* of
one-sided addressing + a laterally-offset sibling row existing nearby.

### 1.2 East Houston Street at Bowery — real rows, real coordinates

Pulled live via `within_box` around the Houston×Bowery intersection (lat 40.720–40.730, lng
−74.000 to −73.985), then isolated the exact block pair spanning the intersection:

```
pid=3310  trafdir=FT  l_hn=0-0     r_hn=33-39   width=44ft  lanes=3/1
  line: (40.725024,-73.995385) -> (40.724873,-73.994953)
pid=3338  trafdir=TF  l_hn=34-40   r_hn=0-0     width=44ft  lanes=3/1
  line: (40.725157,-73.995278) -> (40.725026,-73.994877)
```

`pid=3310` carries the **south** side's addresses (33-39, right side); `pid=3338` carries the
**north** side's addresses (34-40, left side). These are two distinct rows, not one row with a
direction tag. Interpolating both lines to a common longitude (−73.9952) and measuring the
lat-only separation:

```
FT (south carriageway) centerline lat @ lng=-73.9952:  40.724959
TF (north carriageway) centerline lat @ lng=-73.9952:  40.725132
Lateral separation (centerline to centerline): 19.2 m
```

That's **not digitization noise** — 19.2 m is roughly the width of the entire divided roadbed
(median + two carriageways). This is the real geometric fact Kevin's ruling assumed, and it
checks out.

Zooming out: pulling **all 9,289 Manhattan `rw_type=1` rows** and checking East Houston St
end-to-end shows this pattern holds for the whole street east of roughly 6th Ave — every block is
represented as an `FT` row (south side addresses only) paired with a `TF` row (north side
addresses only), the classic dual-carriageway signature.

### 1.3 Bowery, Allen, Forsyth, Delancey — mixed, not uniform

Same test run against all four remaining allow-listed streets, full length, live pull:

| Street | Total rows | One-sided (candidate divided) | Both-sides-on-one-row (undivided) |
|---|---|---|---|
| BOWERY | 38 | 29 (76%) | 5 (13%, remainder ramps/connectors) |
| ALLEN ST | 22 | 17 (77%) | 0 |
| FORSYTH ST | 12 | 4 (33%) | 5 (42%) |
| DELANCEY ST | 48 | 45 (94%) | 0 |

**Forsyth Street is the clearest counter-example to treating this list as uniform** — a third of
its rows are genuinely divided, but a comparable fraction are single, both-sides-addressed
carriageway rows. The allow-list treats it as uniformly "divided" today; CSCL says otherwise for
part of it.

**Bowery's 5 undivided rows are not scattered noise — they cluster on exactly the stretch the
*original* TF2-12 investigation named as the worst offender:**

```
pid=1818  trafdir=TW  l_hn=74-88    r_hn=75-93    width=70ft
pid=1817  trafdir=TW  l_hn=90-122   r_hn=95-127   width=60ft
pid=1819  trafdir=TW  l_hn=124-148  r_hn=129-151  width=60ft
pid=191134 trafdir=TW l_hn=150-162  r_hn=153-169  width=66ft
```

House numbers 74-169 on Bowery fall in the Nolita/Little Italy stretch — Hester→Grand,
Grand→Broome, Broome→Spring — **the exact blocks TF2-12's Part 1 investigation named** ("Kevin
observed that on Bowery around the Grand→Broome and Hester→Grand blocks, opposite-side lines
converge to 0–12m apart"). CSCL records this stretch as **one wide (60-70 ft) undivided
carriageway**, not two. There is nothing for (A) to attach to here — a second centerline simply
doesn't exist in the source data for this stretch. (For what it's worth: TF2-12 already
root-caused and fixed that specific convergence — a per-vertex normal-selection bug at Bowery's
bend, `offsetPolyline`'s `signChoice` logic, confirmed live in the current codebase — so this
isn't an open bug on that block today; it's a note that *if* it were still open, (A) wouldn't be
the fix for it.)

The **live FT-21 screenshot** (build 16, 2026-08-19) that re-opened this issue is captioned
"Houston × Bowery" with the specific stub described as "on E Houston" — i.e. the current evidence
sits on East Houston St, which §1.2 confirms **is** genuinely CSCL-divided. (A) targets today's
complaint correctly; it would not have addressed the original TF2-12 complaint had that still been
open.

---

## 2. Is there a join key, or does it need a heuristic?

**No usable join key. Confirmed on live rows, not inferred from documentation.**

- `joinid` and `bphys_id` are both **present as schema fields but null on every Manhattan row
  checked** (spot-checked on the exact Houston pair above — both fields simply absent from the
  response).
- `b5sc` looked promising (it's populated) but turned out to be a **street-level**, not
  block-level, code: all 31 East Houston St rows pulled in the Houston×Bowery bounding box —
  spanning address ranges from the low-30s all the way to the low-240s, i.e. many different
  physical blocks — share the **identical** `b5sc = "119890"`. It cannot disambiguate one block
  from another on the same street, let alone pair the two carriageways of one specific block.
- `l_blockfaceid`/`r_blockfaceid` are populated and unique per row, but they identify the
  **blockface itself**, not a link to the sibling carriageway's blockface — no cross-reference
  field points from one to the other.

**What you're left with:** pairing `pid=3310` (FT, south) with `pid=3338` (TF, north) as "the two
halves of the same physical block of East Houston between 2nd Ave and Bowery" requires:
1. Same street name.
2. Geometric proximity (their midpoints/lines overlap in the same lat/lng span).
3. Opposite house-number sidedness (one has only left addresses, the other only right).
4. Address-range adjacency as a sanity check (33-39 and 34-40 are the same block's odd/even
   pair; a mismatch would be a red flag).

That's **exactly** the name+proximity heuristic class the ruling was wary of — it's a real
heuristic, not a free lookup. It's a *narrower* heuristic than the current "guess the far curb
from a fudge constant" (it's grounded in real geometry, and it's per-block rather than per-street),
but it is still a heuristic with failure modes, not a clean join.

**Block-boundary mismatch is a second, independent problem in the same join.** The two carriageway
rows of one physical block don't split at the same points:

```
pid=3310 (FT, south): segmentlength = 131.89 ft
pid=3338 (TF, north): segmentlength = 121.05 ft
```

Same physical block, ~11 ft (8%) length mismatch between the two carriageway records. On the
short "connector"/turn-lane rows found near some intersections (e.g. `pid=3302`,
`length=30.8ft`; `pid=159627`/`159629`, `length≈30ft`) the mismatch is proportionally much worse.
A real implementation has to snap/trim each carriageway's polyline to the OSM block's own
intersection-to-intersection extent rather than trusting CSCL's own split points — CSCL's
carriageway splits are not guaranteed to land at the same intersections the OSM-derived block
geometry uses.

---

## 3. How would (A) change `offsetPolyline`'s inputs? (sizing sketch, not an implementation)

Today's call site (`build/preprocess.js` ~L1636-1676):

```js
const blockCurbOffset = getCurbOffsetFromWidth(block.street, blockMidLat, blockMidLng); // scalar, per street
const line = extractSubSegment(blockGeo, zone.distStart, zone.distEnd);                  // from the ONE shared OSM centerline
const offsetLine = offsetPolyline(line, block.side, blockCurbOffset);                    // big offset if divided (fudge)
```

`offsetPolyline`'s two inputs that would change under (A), for blocks where a carriageway pair is
found:

1. **The source line.** Instead of always trimming from the single OSM centerline
   (`blockGeo.line`, shared by both sides of the street), the near-side CSCL carriageway's own
   polyline would become the source — snapped/trimmed to the block's OSM intersection endpoints
   (§2's second problem). This means `getBlockPolyline()`/`extractSubSegment()` need a
   divided-street branch that swaps in CSCL geometry instead of OSM geometry before offsetting.
2. **The offset magnitude.** Today's divided-street offset is `DIVIDED_MEDIAN_ALLOWANCE_M (7m) +
   medianWidthM/2` — a large distance because it's reaching from the far OSM centerline all the
   way to the near carriageway's outer curb. Once the source line IS the near carriageway's own
   centerline, the needed offset shrinks to roughly a single parking-lane width — the same order
   of magnitude as `CURB_OFFSET_DEFAULT_METERS` (6m) or smaller, not the current 11-14m fudge
   range. (Directional note only — not a proposal to hardcode a new constant; that calibration is
   implementation work, not investigation work.)

A new problem this introduces: **which carriageway is "near" for side E vs W (or N vs S)?** That's
the same normal/hemisphere-selection question TF2-12 P1 already solved once (`signChoice` in
`offsetPolyline`) — except previously it was "which way does the fudge distance point," and under
(A) it becomes "which of the two real carriageway rows is on the correct compass side of this
block." Same class of problem, applied to real geometry instead of a computed distance. Not
free — worth sizing as comparable-but-not-identical work to the TF2-12 P1 fix.

**Net sizing signal for whoever picks this up:** this is a new per-block geometric join
(CSCL-carriageway ↔ OSM-block) plus a trim/snap step plus a side-selection step, layered on top of
the *existing* per-street width lookup that's already in the pipeline. It is not a parameter
tweak. It's comparable in shape to TF2-14's regen-6 redesign (which also replaced a per-block CSCL
proximity search with something more principled) rather than to a one-constant tuning pass.

---

## 4. Does (A) replace the existing machinery, or sit alongside it?

**Replaces the divided-street fudge branch specifically. Sits alongside everything else, because
everything else is still needed as a fallback.**

What gets **replaced**:
- `DIVIDED_STREET_ALLOW_LIST` (the hardcoded 5-name set) — under (A) this becomes a **derived**
  set (any street/block where a real CSCL carriageway pair is found), not curated by hand.
- `DIVIDED_MEDIAN_ALLOWANCE_M` and the `medianWidthM/2 + 7.0` fudge formula — becomes unnecessary
  once the near carriageway's own centerline is the offset source (§3).

What **stays, unchanged, as the fallback**:
- `WIDE_AVENUE_RE` / `WIDE_NS_NAMES` / `WIDE_CROSSTOWN_NAMES` / `getStreetCurbOffset` — the
  name-tier logic remains the fallback for any street with **no** CSCL width data at all (already
  the documented fallback today).
- `CSCL_OFFSET_FRACTION` / `CSCL_OFFSET_MIN_M` / `CSCL_OFFSET_MAX_M` and the single-carriageway
  half-width formula — remains exactly as-is for the (large) majority of streets that are
  genuinely undivided in CSCL, and becomes the fallback for divided-street blocks where the
  carriageway join fails (missing CSCL row nearby, ambiguous pairing, mismatched geometry) — same
  role the name-tier fallback plays today for width-data gaps.

So this is **one branch replaced with a more honest version of itself, using data already in the
pipeline** — not a sixth heuristic layer stacked on the existing five. That matches the letter of
Kevin's ruling. The caveat is that the *replacement* branch's trigger condition ("is this street
divided here?") is itself now **derived from a proximity+parity heuristic instead of a curated
list** — more principled, not heuristic-free.

---

## 5. Coverage impact

**Today's `DIVIDED_STREET_ALLOW_LIST` (5 streets) covers 578 of 44,280 citywide tile segments —
1.3%.**

A live, citywide, boroughcode='1' pull (9,289 rows) and a naive proximity+one-sidedness scan
(same signature as §1) surfaces candidate divided-carriageway pairs on **69 distinct street
names**, dominated by:

| Street | Candidate carriageway pairs (naive scan) |
|---|---|
| BROADWAY | 127 |
| PARK AVE | 117 |
| ADAM CLAYTON POWELL JR BLVD | 55 |
| LENOX AVE | 43 |
| 1 AVE | 30 |
| E HOUSTON ST | 22 |
| BOWERY | 20 |
| DELANCEY ST | 15 |
| RIVERSIDE DR | 14 |
| AVE C | 14 |

**This naive scan is noisy and over-counts** — plenty of ordinary one-way blocks legitimately
carry house numbers on only one CSCL row for reasons unrelated to a median (short connector
segments, corner-lot addressing quirks), which the scan can't distinguish from a genuine
carriageway pair without the additional address-range-adjacency check described in §2. Broadway's
127 "pairs" almost certainly include many false positives — Broadway is only physically divided at
specific stretches (pedestrian malls near Times Sq/Herald Sq, not its full length), and a "127
candidate pairs" count for a street that is NOT uniformly divided is a signal the naive scan needs
hand-curation before being trusted, not a usable coverage number on its own.

**Hand-checking the strongest candidate confirms real, additional coverage exists beyond the
5-name list.** Park Avenue: 204 CSCL rows fetched, essentially every one single-sided (one-side
address ranges only, paired FT/TF rows) — Park Ave's median from the low-40s to 96th St is real
and well-documented, and CSCL represents it exactly like Houston does. **Park Avenue is not on
today's allow-list** and currently gets only the flat `WIDE_AVENUE_RE` 10m tier offset, with no
divided-street handling at all.

**Rough order-of-magnitude, using tile segment counts for a curated (not naive-scan) set of
streets that plausibly ARE genuinely divided** (Houston, Bowery, Allen, Forsyth, Delancey, Park
Ave, Riverside Dr, Canal St, ACP Jr Blvd, Lenox Ave, Frederick Douglass Blvd, Ave C, Madison St, St
Nicholas Ave, Cooper Sq, Pike St):

```
Current allow-list (5 streets):        578 / 44,280 segments  (1.3%)
+ plausible additional divided streets: ~3,592 / 44,280 segments (8.1%)
Combined, if fully & correctly identified: ~4,170 / 44,280 (9.4%)
```

**Caveat this needs before it's a real number:** every one of those additional streets needs the
same block-level verification done for Bowery in §1.3 (a street can be *partly* divided — Forsyth
and Bowery both are) before being trusted as "fully covered by (A)." The 9.4% figure is a ceiling
under generous assumptions, not a validated count. But even a fraction of that ceiling is
meaningfully larger than "fix the 5 allow-listed streets," which is the coverage question worth
weighing against the added complexity in §3.

---

## 6. Verdict

**GO on (A), qualified.**

The premise Kevin's ruling rests on is **verified true against live data, not assumed**: CSCL
genuinely stores divided streets as separate, laterally-offset carriageway centerlines (19.2 m
apart, measured, on East Houston St — the street the current live complaint is actually about).
That's real geometry the pipeline doesn't use today, sitting in a dataset (`inkn-q76z`) already
proven-reliable in production via `scripts/build-oneway-data.js` and `scripts/build-street-widths.js`.
No new dataset, no new CORS/auth risk, no new ingestion pipeline — all consistent with how Kevin
framed (A).

**But it is not the "clean" win the framing might suggest, on three specific points that should be
carried into any spec:**

1. **The carriageway join needs a heuristic** (proximity + address-parity), because CSCL carries
   no join key (`joinid`/`bphys_id` null; `b5sc` is street-level, not block-level). It's a
   *narrower, better-grounded* heuristic than today's name-list-plus-fudge — but it is still a
   heuristic, with real failure modes (ambiguous pairing, missing sibling row, mismatched block
   splits).
2. **It doesn't cover every wide/bad-looking block.** CSCL says the specific Bowery stretch the
   *original* TF2-12 report named (Hester→Grand, Grand→Broome) is one wide 60-70ft undivided
   carriageway, not two — (A) has nothing to attach to there. It does correctly cover the block
   the *current* FT-21 screenshot evidence points at (East Houston St), so it targets today's
   live complaint, just not the full historical set.
3. **The block-boundary snap/trim work and the near/far carriageway-to-compass-side resolution are
   real, non-trivial engineering** — comparable in kind to the TF2-12 P1 normal-selection fix and
   the TF2-14 regen-6 redesign, not a parameter tweak. Size it accordingly.

Given (1)-(3), **do not treat this as "obviously go build it."** But the data supports it, the
coverage ceiling (up to ~9% of segments, vs 1.3% today) is meaningfully larger than the current
5-street allow-list, and it is a genuine architectural improvement — replacing a curated
name-list-plus-fudge with a derived, per-block, real-geometry answer — matching what Kevin actually
asked for ("model divided streets honestly"). **Recommend proceeding to a full spec session with
`@tech-lead` before any code**, scoped explicitly to: (a) the block-level join algorithm and its
failure/fallback behavior, (b) the snap/trim step, (c) the near-carriageway compass-side
resolution, and (d) which of the §5 candidate streets get hand-verified into the derived divided
set before the first regen that ships this.

**(B) was not assessed** per the task scope — Kevin's ladder only calls for evaluating (B) if (A)
is a NO-GO, and it is not. No recommendation on (B)'s tractability is made here.

---

## Appendix — queries run (for reproducibility)

All queries hit `https://data.cityofnewyork.us/resource/inkn-q76z.json` directly, read-only, no
auth, no app token (same unauthenticated access pattern already in production in
`scripts/build-oneway-data.js` and `scripts/build-street-widths.js`).

- Field metadata: `GET /api/views/inkn-q76z.json`
- Houston×Bowery block pair: `$where=boroughcode='1' AND stname_label='E HOUSTON ST' AND
  within_box(the_geom, 40.730,-74.000, 40.720,-73.985)`
- Bowery, Allen, Forsyth, Delancey full-street pulls: `$where=boroughcode='1' AND
  stname_label='<NAME>'`
- Citywide Manhattan drivable-street pull for the coverage scan: `$where=boroughcode='1' AND
  rw_type='1'` (9,289 rows, `$select` limited to geometry + addressing + width + trafdir fields)
- Row-level spot checks: `$where=physicalid=3310 OR physicalid=3338` (confirmed `joinid`/`bphys_id`
  null on both)

No coordinate in this document was hand-typed and then trusted — every lat/lng cited was read
directly out of a live Socrata response, per the task's constraint about the prior false NO-GO.

---

## Note for whoever implements the eventual regen

Not part of this investigation's scope — flagged only so it isn't dropped, per the task brief.
FT-21's eventual regen (whichever ladder rung ships) should carry three items in one pass and one
validation cycle, per standing advice already in `docs/field-testing-log.md`'s FT-21 entry:
1. The FT-21 geometry change itself (this investigation's subject).
2. The duplicate-adjacent-vertex hygiene fix (12.4%→22.7%, `open-items` #9 — "fold into the next
   regen rather than spend a regen cycle on vertex hygiene alone").
3. The 359 still-lost zone rows (`open-items` #10), if in scope.

Do not act on this section — it is a note for the future implementation session, not a task for
this investigation.
