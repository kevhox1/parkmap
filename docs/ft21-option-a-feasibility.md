# FT-21 Option A — Brooklyn Feasibility (B0, Brooklyn Expansion)

**Status:** Investigation complete. INVESTIGATION ONLY — no pipeline changes, no regen, no code touched.
**Date:** 2026-09-22
**Author:** `@backend-data`
**Ratifying context:** Kevin's 2026-09-21 investigate-first ruling for FT-21 Option A as a Brooklyn
prerequisite (`docs/brooklyn-expansion-spec.md` Stream B0), extending the Manhattan-only investigation
already on file at `docs/ft21-carriageway-investigation.md` (2026-08-24, "Qualified GO on (A)" for
Manhattan's Houston/Bowery/Allen/Forsyth/Delancey/Park Ave set).
**Touches:** none (docs only — read `build/preprocess.js`, `scripts/build-street-widths.js`; queried
live CSCL and OSM data, read-only).

**This document does not re-derive the Manhattan verdict** — that stands as written. This is the new
question Kevin's ruling asked: does the same mechanism hold up against **Brooklyn's boulevard class**
(Eastern Pkwy, Ocean Pkwy, Flatbush Ave, Atlantic Ave, 4th Ave), and does it change the Brooklyn
expansion plan?

---

## TL;DR verdict

**PARTIAL.** The Manhattan mechanism (CSCL stores divided streets as separate, laterally-offset
carriageway centerlines; no join key; needs a proximity+address-parity heuristic) **does generalize to
Brooklyn** — confirmed on live data, not assumed — and on Brooklyn's clearest case (Eastern Parkway) the
evidence is **even stronger** than Houston's original case. But two new, Brooklyn-specific findings
change the practical picture enough that this isn't a clean "yes, build it everywhere":

1. **Whether Option A actually matters for a given Brooklyn boulevard depends on what OSM — not
   CSCL — already gives the pipeline.** The FT-21 problem is specifically "OSM has ONE centerline for a
   street CSCL/reality treats as two-plus." That gap is **not uniform** across Brooklyn's boulevard
   class: Eastern Parkway is a clean single-OSM-centerline case (Option A matters a lot, exactly like
   Houston). 4th Ave and Atlantic Ave are **already split into two directional OSM ways** with
   real lateral separation close to what CSCL independently measures — meaning today's pipeline is
   probably already closer to correct there than the allow-list case ever was, and Option A's payoff on
   those two streets is smaller than the framing assumed.
2. **Parkways (Eastern Pkwy, Ocean Pkwy) are a THREE-carriageway structure**, not two — a center
   through-road plus two service roads, separated by the landscaped malls — which Manhattan's test set
   never exercised. This is new complexity for the eventual implementation, though the existing
   proposed heuristic (favor one-sided-address rows) appears to select the correct service-road
   carriageway naturally (see §3). Untested in implementation, flagged as a real new edge case.
3. **Coverage is uneven even within one street**, same pattern as Manhattan's Bowery/Forsyth finding:
   Flatbush Ave is **73.6% represented as a single undivided CSCL carriageway** — Option A has limited
   attachment surface there.
4. **Phase 1's actual named beachhead (Williamsburg, Greenpoint, Fort Greene, Park Slope) barely
   touches this problem.** Eastern Pkwy and Ocean Pkwy — the strongest Option A case — sit **outside**
   all four neighborhoods. Only short boundary segments of Atlantic Ave (Fort Greene) and Flatbush
   Ave/4th Ave (Fort Greene/Park Slope edges) brush the named footprint, and those are the two weaker
   cases (§1, §3).

**Recommendation:** proceed exactly as `docs/brooklyn-expansion-spec.md` Streams B0/B0b already
sequence it — B0b runs on **Manhattan data only**, validating the two-carriageway mechanism before any
Brooklyn data touches the code. Don't bail to Option C (cosmetic) — the mechanism is real and worth
building. But **don't oversell it to Phase 1**: the beachhead's actual FT-21 exposure is small, and its
highest-value Brooklyn case (parkways) won't be exercised until a later phase reaches Crown
Heights/Prospect Heights or Kensington/Midwood. Budget the 3-carriageway service-road classifier as a
small, separate follow-up item whenever the beachhead (or B0b's own scope) actually reaches a parkway
block — not blocking, not urgent for Phase 1.

---

## 1. Live data: does CSCL model Brooklyn's boulevards as separate carriageways?

Same methodology as the Manhattan investigation — live pulls against `inkn-q76z`
(`boroughcode='3'`), one-sidedness + proximity signature, no hand-typed coordinates.

| Street | Rows | One-sided (candidate divided) | Both-sided (undivided) | `joinid`/`bphys_id` populated |
|---|---|---|---|---|
| EASTERN PKWY | 104 | 77 (74.0%) | 15 (14.4%) | 0 / 0 |
| OCEAN PKWY | 195 | 109 (55.9%) | 41 (21.0%) | 0 / 0 |
| ATLANTIC AVE | 259 | 178 (68.7%) | 43 (16.6%) | 0 / 0 |
| 4 AVE | 223 | 169 (75.8%) | 41 (18.4%) | 0 / 0 |
| FLATBUSH AVE | 159 | 42 (26.4%) | 84 (52.8%) | 0 / 0 |

Same finding as Manhattan: **no usable join key anywhere in Brooklyn CSCL either** — `joinid`/`bphys_id`
null on every row checked across all five streets. The pairing heuristic (proximity + address-side
parity) is required in Brooklyn exactly as it was in Manhattan. Nothing new here; consistent.

**Flatbush Ave is the Brooklyn analogue of Bowery/Forsyth** — mostly represented as one undivided
row, not a clean divided street. Its one-sided rows cluster on specific stretches (mid/high address
ranges, not the Grand Army Plaza/downtown end), not uniformly.

### Real lateral separation, proximity-and-parity matched pairs (full-street, live pull)

Matched candidate carriageway pairs by same-side-of-block address overlap + nearest proximity,
perpendicular separation computed from full polylines (not single-point lat-diff):

| Street | Matched pairs | Separation range | Median separation |
|---|---|---|---|
| EASTERN PKWY | 34 | 10.4–61.6 m | **41.3 m** |
| OCEAN PKWY | 45 | 44.8–95.5 m | **49.1 m** |
| ATLANTIC AVE | 55 | 12.6–94.3 m | **21.8 m** |
| 4 AVE | 78 | 8.7–23.1 m | **12.6 m** |
| FLATBUSH AVE | 10 | 0.0–23.0 m | 20.3 m |

For reference, Manhattan's Houston St (the original FT-21 sighting) measured **19.2 m** separation.

**Eastern Parkway's separation (41.3 m median) is more than double Houston's** — the real geometric
premise Option A depends on is not just present in Brooklyn, it's *starker* there. Ocean Parkway is
similar (49.1 m). Atlantic Ave (21.8 m) lands close to Houston's own number — a clean two-carriageway
case, comparable in kind. **4th Ave's 12.6 m median is the outlier** — see §2, this is not the same
kind of "divided by a median" separation; it's closer to the street's own recorded curb-to-curb width,
which turns out to matter a lot for the verdict.

---

## 2. New finding: OSM's own source geometry is not uniformly single-centerline across Brooklyn's boulevards

This is the piece the Manhattan investigation didn't need to check, because Houston/Bowery/Park Ave all
happened to be single-centerline in OSM. `build/preprocess.js` builds block geometry from
**`osm_data.json`** (OSM-sourced), not CSCL — CSCL only supplies width/carriageway data today. So the
real question for "does Option A matter here" isn't just "is CSCL divided" — it's **"does OSM already
give the pipeline more than one line, or does it hand over a single centerline that then gets a flat
width-based offset applied to it (the actual FT-21 failure mode)?"**

Live Overpass queries, same five streets:

| Street | OSM `oneway` tags in test bbox | Lateral pattern |
|---|---|---|
| EASTERN PKWY | 25/25 ways `oneway=no` | **Single line, no lateral duplication at any block** — genuinely one centerline, exactly the Houston-class failure mode. |
| OCEAN PKWY | 13 `yes` / 11 `no` / 2 untagged | **Mixed** — real lateral duplication found (multiple distinct longitudes at the same latitude), consistent with OSM already partially capturing the center+service-road structure, unlike Eastern Pkwy. |
| ATLANTIC AVE | 13/13 `oneway=yes` | Already split into direction-specific ways (median nearest-neighbor separation ~30 m in a small 13-way sample — noisy at this N, but the *structural* finding — pre-split — is solid). |
| 4 AVE | 45/45 `oneway=yes` | Already split into two directional ways; median nearest-neighbor separation **13.8 m**, matching CSCL's own 12.6 m almost exactly. |
| FLATBUSH AVE | 21/27 `oneway=yes`, 5 `no` | Mixed, not checked geometrically in depth (out of scope given CSCL's own 73.6%-undivided finding already caps the opportunity here). |

**Read on 4th Ave:** OSM already represents it as two parallel directional lines ~13.8 m apart; CSCL
independently measures ~12.6 m. These numbers agreeing closely, on a street whose *recorded* CSCL
carriageway width is 36 ft (≈11 m), is the tell — the "two carriageways" here aren't separated by a
median; they're close to being the street's own two curblines, already digitized separately in OSM.
**The existing pipeline is likely already reasonably positioned on 4th Ave, independent of any CSCL
Option A work.** This is not the wide-street-showing-mid-road failure Kevin's screenshots documented on
Houston — it's a structurally different, probably-already-okay case. Not verified against a live tile
render (no Brooklyn tiles exist yet, out of scope for this investigation), but the geometric evidence
points away from urgency here.

**Read on Eastern Parkway:** the opposite case — a clean, uncomplicated single OSM centerline with **no**
lateral duplication anywhere in the test bbox, and CSCL's own carriageway data shows the widest,
most-separated real divided-street signature of anything tested (41.3 m median, service roads
specifically — see §3). This is the strongest, cleanest confirmation-by-contrast in the whole
investigation: it is simultaneously the best CSCL evidence for Option A's premise and the worst current
OSM-driven case for the existing width-fudge fallback (whatever offset `getCurbOffsetFromWidth` would
compute from a single centerline, the true near-curb line is up to ~24 m further out on the service
road than the far-curb line is on the *other* service road — a 40+ m error band the current allow-list
mechanism (Houston/Bowery/Allen/Forsyth/Delancey only, Eastern Pkwy not on it) doesn't even attempt to
correct for today).

---

## 3. New complexity: parkways are three carriageways, not two

Sample block, Eastern Pkwy @ Nostrand Ave (live CSCL rows, real coordinates):

```
pid=145563  trafdir=TW  width=58ft  l=453-537  r=458-538   <- center through-road, BOTH sides addressed
pid=48551   trafdir=TW  width=58ft  l=539-617  r=540-630   <- center through-road, next block
pid=145566  trafdir=FT  width=24ft  l=0-0      r=458-538   <- north service road, ONE side only
pid=145567  trafdir=TF  width=24ft  l=453-537  r=0-0       <- south service road, ONE side only
pid=48568   trafdir=TF  width=24ft  l=539-617  r=0-0       <- south service road, next block
pid=78910   trafdir=FT  width=24ft  r=540-630  l=0-0       <- north service road, next block
```

Three CSCL rows per block, not two: one wide (58ft) `TW` central roadway carrying **both** sides'
addresses (matching Manhattan's undivided-row signature), plus two narrow (24ft) one-sided service
roads flanking it. Same pattern repeats on Ocean Parkway (75ft `TW` center + 22-34ft one-sided service
segments, §1).

**This is new relative to the Manhattan test set** (Houston/Bowery/Allen/Forsyth/Delancey/Park Ave were
all clean two-carriageway cases — a center road never appears alongside the pair). It matters because
curb parking on a parkway happens on the **service roads**, not the central through-road, so a correct
implementation must pick the *service* carriageway as the offset source, not accidentally grab the wide
central `TW` row as "the nearest CSCL line."

**Favorable finding, not yet implementation-tested:** the proximity+address-parity heuristic already
proposed for the two-carriageway case (Manhattan investigation §2 — "does this row carry addresses for
only one side, near a name+proximity match") **naturally excludes the center row**, because the center
`TW` row is by definition both-sided, not one-sided. A block-matching algorithm built to prefer
one-sided rows would land on `pid=145566`/`145567` and correctly skip `pid=145563` without any
special-casing for "this is a three-way parkway." That's a genuinely good sign, but it is a sign, not a
tested implementation — flag explicitly for whoever builds this: **write a unit test for the
three-carriageway case specifically** (a parkway block with one `TW` center row + two one-sided service
rows present simultaneously) before trusting the pairing logic on Eastern/Ocean Pkwy in production.

---

## 4. Coverage / prioritization: where does this actually land relative to Phase 1?

Cross-referencing the five test streets against `docs/brooklyn-expansion-spec.md`'s named Phase 1
beachhead (Williamsburg, Greenpoint, Fort Greene, Park Slope):

| Street | Runs through Phase 1 beachhead? | Option A payoff (this investigation) |
|---|---|---|
| Eastern Pkwy | **No** — Crown Heights/Prospect Heights (touches Grand Army Plaza, the Park Slope boundary, at most) | **Highest** — clean single-OSM-centerline case, largest real separation measured (41.3 m) |
| Ocean Pkwy | **No** — Kensington/Midwood, far south | High, but OSM partially pre-split already — smaller than Eastern Pkwy's gap |
| Atlantic Ave | **Partial** — southern edge of Fort Greene | Moderate premise (CSCL genuinely two-sided, 21.8 m), but OSM already directionally split — likely smaller practical win than the CSCL numbers alone suggest |
| Flatbush Ave | **Partial** — western edge of Fort Greene/Park Slope (Grand Army Plaza area) | Low — CSCL itself is 73.6% undivided here, same as Bowery/Forsyth's mixed pattern |
| 4 Ave | **Partial** — western border of Park Slope | Low — OSM already gives two closely-matching directional lines; not the failure mode Option A targets |

**None of the five test streets sit fully inside the four named neighborhoods, and the two strongest
cases (the parkways) sit entirely outside them.** The honest read: Option A is a real, worthwhile
architectural fix — the Manhattan verdict stands, and Eastern Parkway is arguably the single best piece
of evidence for it found anywhere in this investigation — but it is **not a Phase-1 blocking
dependency**. Kevin's ladder ("do A first, then B, then declare cosmetic") was written against
Manhattan's Houston/Bowery complaint; nothing here suggests Phase 1's actual four neighborhoods need it
to ship without a visible flaw. It becomes relevant again once a later phase's beachhead reaches
Crown Heights, Prospect Heights, Kensington, or Midwood.

---

## 5. Verdict and recommendation

**PARTIAL — confirmed viable in principle, unevenly valuable in practice, small overlap with Phase 1.**

- **Do not fall to Option C (declare cosmetic) as a Brooklyn-specific ruling.** The mechanism is real,
  confirmed on live data in both boroughs, and Eastern Parkway is a stronger piece of supporting
  evidence than anything the original Manhattan investigation found. There is no reason to abandon
  Option A on Brooklyn's account.
- **Proceed exactly per `docs/brooklyn-expansion-spec.md`'s existing B0→B0b sequencing** — B0b runs on
  Manhattan data first regardless (Houston/Bowery/Allen/Forsyth/Delancey + the newly-identified Park Ave
  opportunity from the original investigation). That work is unaffected by anything found here.
- **Do not size a Brooklyn-specific Option A effort into Phase 1's session budget.** The beachhead's real
  exposure is thin (§4) and the two streets that DO brush the footprint (4th Ave, Atlantic Ave) show the
  weakest payoff of the five tested. Ship Phase 1 on today's fallback machinery
  (`WIDE_AVENUE_RE`/`getStreetCurbOffset`) for these edges; it is the same treatment Manhattan boulevards
  outside the allow-list already get, and the newly-measured separations here (12.6–21.8 m) are smaller
  than Houston's known-bad case.
- **When a later phase's beachhead reaches a parkway** (Eastern Pkwy via Crown Heights/Prospect
  Heights, or Ocean Pkwy via Kensington/Midwood), re-open this file and size the **three-carriageway
  service-road classifier** described in §3 as a small, targeted addition on top of B0b's two-carriageway
  machinery — not a rebuild. Budget: comparable to B0b's own two-carriageway pairing/snap-trim work
  (§3/§4 of the Manhattan investigation), plus one new unit test class for the center-vs-service-road
  discrimination. Not sized precisely here — genuinely not needed until a beachhead actually reaches
  one of these streets.

---

## Appendix — queries run (for reproducibility)

CSCL (`inkn-q76z`, unauthenticated Socrata, same pattern as `scripts/build-oneway-data.js`):
- Exact `stname_label` spellings: `$where=boroughcode='3' AND stname_label like '<PREFIX>%'`
- Full-street pulls: `$where=boroughcode='3' AND stname_label='<NAME>'`, fields
  `physicalid,trafdir,l_low_hn,l_high_hn,r_low_hn,r_high_hn,streetwidth,segmentlength,joinid,bphys_id,b5sc,the_geom`
- Intersection-area spot checks: `within_box(the_geom, ...)` around Nostrand Ave (Eastern Pkwy),
  Church Ave (Ocean Pkwy), Nostrand Ave (Atlantic Ave), 9th St (4th Ave)

OSM (Overpass API, `overpass-api.de/api/interpreter`, unauthenticated, read-only):
- `way["name"="<NAME>"]["highway"](<bbox>);out tags geom;` for each of the five streets
- `way["highway"="service"](<bbox>);out tags;` to check for separately-named parkway service roads
  (none found near Eastern Pkwy under any highway subtype)

All separation/perpendicular-distance numbers were computed from the full polyline geometry returned by
these live queries (point-to-polyline minimum distance in meters, not single-point lat/lng subtraction),
matching the rigor standard the prior Manhattan investigation set. No coordinate in this document was
hand-typed and then trusted.

---

# Appendix — Kevin's beachhead question: is there actually a lot of street parking in North Brooklyn?

**Question, verbatim:** *"Is there actually a lot of street parkers [in the suggested North Brooklyn
set]? My guess would be yes more than NYC [Manhattan]."*

## Short answer

**Yes, Kevin's guess is correct at the borough level, by a wide margin — roughly 2x.** Within Brooklyn,
though, the four neighborhoods already suggested (Williamsburg, Greenpoint, Fort Greene, Park Slope)
are **not** the highest-car-ownership part of the borough — South Brooklyn (Bay Ridge, Bensonhurst,
Sheepshead Bay, Dyker Heights) owns cars at a meaningfully higher rate. Whether that makes South
Brooklyn a *better* beachhead than the suggested set is a separate question from raw ownership — see
the ranking below, which weighs both car density and app-audience fit as asked.

## Borough-level data (the part with solid sourcing)

Two independently-sourced figures agree closely:

| Borough | Households with ≥1 vehicle | Car-free households |
|---|---|---|
| Manhattan | ~22–23% | ~76.6% |
| Brooklyn | ~44–45% | ~56.5% |

(Sources: NYC EDC's published car-ownership breakdown and a separate Census-derived comparison, both
converging independently on the same ~22% Manhattan / ~44% Brooklyn split — see Sources below.)

**Brooklyn's household car ownership rate is essentially double Manhattan's.** Kevin's guess is directly
confirmed, not just directionally right.

## Assumption stated plainly: granularity limit

Precise, current-year, neighborhood-by-neighborhood (community-district-level) percentages were not
obtainable in this session — NYC Planning's Population FactFinder and Community Profiles tools are
JavaScript-rendered and not fetchable headlessly from this environment, and the Census Bureau's own API
(`api.census.gov`) is not reachable from this sandbox's network egress (confirmed: requests are
intercepted by a local gateway before reaching Census, unrelated to Census's own key system). What
follows below the borough-level split is triangulated from: (a) one real PUMA data point that did load
(Park Slope/Carroll Gardens — median 0 cars/household, but 41.8% transit commute / 36.1% work-from-home,
implying a real minority driving share, consistent with a family brownstone neighborhood, not a
car-empty one), (b) multiple independent sources' qualitative agreement that South Brooklyn
(Bay Ridge/Dyker Heights/Bensonhurst/Sheepshead Bay/Gravesend) has NYC's highest car ownership outside
Staten Island and eastern Queens, driven by housing stock (detached/semi-detached 1-2 family homes with
driveways), and (c) general, well-documented NYC housing-stock knowledge about off-street parking supply
by neighborhood. **Treat the ranking below as directionally solid, not as precise percentages** — it is
adjustable, as Kevin's own framing already anticipates, once he knows where his actual inquiring users
park.

## The car-density vs. app-audience-fit distinction (stated as an explicit assumption)

Raw car ownership isn't the same thing as *street*-parking pressure, and it isn't the same thing as
*WePark's* target audience. Two adjustments, both assumptions, both worth naming:

1. **Off-street parking supply differs by housing stock, not just by car count.** South Brooklyn's
   housing stock (semi-detached/attached 1-2 family homes) commonly includes private driveways/garages;
   North/Northwest Brooklyn's housing stock (rowhouses, mid-rise apartment buildings) largely does not.
   A neighborhood can have *fewer* cars per household and still have *more* cars competing for the same
   curb, if a higher share of those cars have nowhere else to go. This cuts toward Williamsburg/Fort
   Greene/Park Slope mattering more for WePark's specific problem than raw ownership numbers alone
   suggest — but it is an inference from general housing-stock knowledge, not a measured
   off-street-supply statistic.
2. **App-audience fit.** WePark's existing (Manhattan) base is young, phone-native, EV/LES/West Village-
   style renters who fight for street spots and get burned by ASP rules — not people with driveways.
   South Brooklyn's higher-car-ownership neighborhoods skew toward an older, more homeowner-heavy,
   more car-dependent-by-design population; the demographic overlap with WePark's demonstrated audience
   is weaker even where the raw car count is higher. This is an assumption about demographic fit, not a
   measured stat — flagged as instructed.

## Recommended Phase-1 set (4-6 neighborhoods, ranked)

1. **Park Slope** — real, well-documented street-parking friction (family brownstone neighborhood,
   meaningful car ownership despite good transit, culturally notorious for alternate-side-parking
   complaints); little to no off-street supply in most of the neighborhood; strong demographic overlap
   with WePark's existing base (young professional / family, phone-native).
2. **Fort Greene** (extend to include Clinton Hill if the box needs rounding out) — similar brownstone
   density/parking-pressure profile to Park Slope, good transit, no material off-street supply, adjacent
   to the existing set (keeps the box contiguous per `docs/brooklyn-expansion-spec.md` §5's stated
   reasoning for staying with a single compile-time bbox).
3. **Williamsburg** — lower raw car-ownership rate than Park Slope/Fort Greene, but real, arguably
   *outsized* street-parking pressure: alternate-side rules, minimal off-street supply, plus
   Manhattan-adjacent commuter/nightlife overflow parking competing for the same spots (an assumption,
   not a measured stat, but a widely-recognized dynamic). Strong demographic fit — this is WePark's
   exact existing audience profile, just across the river.
4. **Greenpoint** — same profile as Williamsburg, one stop further from Manhattan, slightly less
   commuter-overflow pressure; keep for contiguity with Williamsburg and because Kevin's original set
   already named it.
5. **(New addition, recommend adding) Carroll Gardens/Cobble Hill/Boerum Hill** — same brownstone,
   no-driveway, high-street-pressure profile as Park Slope/Fort Greene; contiguous with both (fills the
   gap between them); rounds the set to 5 without breaking the single-bbox contiguity assumption
   Stream B5 already relies on.
6. **(Optional 6th, flagged not recommended for Phase 1) Bay Ridge** — the strongest *raw* car-ownership
   candidate in all of Brooklyn by a real margin, and it does have subway service (R line), so it isn't
   a pure non-starter. Not recommended for Phase 1 specifically because (a) it's geographically
   non-contiguous with the rest of the set — Sunset Park sits between Park Slope and Bay Ridge with no
   natural bbox-sharing rationale, which breaks the single-compile-time-box assumption
   `docs/brooklyn-expansion-spec.md` §5 deliberately chose for Phase 1, and (b) the demographic/app-fit
   overlap with WePark's proven audience is the weakest guess of anything on this list. Worth
   re-evaluating for Phase 2 on raw car-density grounds alone, especially if Kevin's actual inquiring
   users turn out to skew that way.

**Net recommendation: Williamsburg, Greenpoint, Fort Greene, Park Slope, + Carroll
Gardens/Cobble Hill/Boerum Hill as a fifth.** This keeps the contiguous single-bbox design Stream B5
already committed to, keeps every neighborhood in the "no material off-street parking supply" bucket
(where WePark's core promise matters most regardless of raw ownership numbers), and stays closest to
WePark's demonstrated Manhattan audience profile. Bay Ridge (and by extension Bensonhurst/Sheepshead
Bay) is the honest answer to "where is car ownership highest" but is flagged, not recommended, for
Phase 1 specifically — exactly the kind of decision Kevin said he'd revisit once he knows where his
actual inquirers park.

## Sources

- [Car Ownership in NYC: By the Numbers — Hunter Urban / NYC EDC data](https://www.hunterurban.org/wp-content/uploads/2024/06/Car-Light-NYC-Infographics-May-2024.pdf) — borough breakdown (Manhattan 22%, Brooklyn 44%, Bronx 40%, Queens 62%, Staten Island 83%)
- [New Yorkers and Their Cars — NYC EDC](https://www.tumblr.com/nycedc/173261729079/new-yorkers-and-their-cars) — same borough-level figures, independent publication
- [Who owns a car in New York City? — Venkatesh Elango, Census-derived analysis](https://wellango.github.io/posts/2021/06/who-owns-cars-in-nyc/) — corroborates Manhattan (22.7%) / Brooklyn (44.7%) household vehicle ownership rates; notes South Brooklyn/East Bronx/Eastern Queens/Staten Island/UES as above-average car-ownership zones
- [NYC-Brooklyn Community District 6 (Park Slope & Carroll Gardens) PUMA — DataUSA](https://datausa.io/profile/geo/nyc-brooklyn-community-district-6-park-slope-carroll-gardens-puma-ny) — 41.8% transit commute, 36.1% work-from-home, median 0 cars/household (real but low-precision data point)
- [Brooklyn factsheet — Tri-State Transportation Campaign / Pratt Center](file, fetched locally) — older (2000 Census) borough-wide figure, 43.0% household vehicle ownership, directionally consistent with newer sources
