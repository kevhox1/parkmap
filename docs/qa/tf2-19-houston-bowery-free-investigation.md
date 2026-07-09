# TF2-19: Houston / Bowery "FREE Parking" Investigation
## Investigation Report — 2026-07-09

**Filed:** Kevin field-test, real device (build 13), daytime, 2026-07-09
**Reporter:** backend-data investigation (read-only)
**Status:** Root cause confirmed. Fix NOT yet applied (spec/implementation is a follow-up).

---

## 1. Executive Summary

**Root cause: the regen-5 tile rebuild (commit `a176147`, 2026-06-15) silently shipped an
incomplete pull of NYC's MAIN parking-sign dataset (Socrata `nfid-uabd`).** The build script's
`fetchSocrataDataset()` paginates through this dataset with no retry-on-error, no `$order` clause,
and no post-fetch completeness check. Something went wrong partway through that pull during the
regen-5 build run, and **~40–48% of METERED / NO_STANDING / NO_PARKING / TRUCK_LOADING / SPECIAL /
UNKNOWN rule instances citywide were dropped from the shipped tiles**, while the separately-fetched
ASP dataset (`2x64-6f34`, source of all `ASP_*` categories) came through essentially untouched
(±0.5%). Houston and Bowery are simply where Kevin happened to drive; the defect is **citywide**,
not limited to the TF2-14 divided-street allow-list (Houston/Bowery/Allen/Forsyth/Delancey) that
Kevin's history correctly flagged as the prime suspect.

**This is a genuinely new failure, distinct from FT-9.** FT-9 (2026-06-08) was a `safetyLabel`
branch-ordering bug where the map polyline color was independently verified correct (amber) and
only text/chip surfaces said "free." Here, the **tile data itself** no longer carries the METERED /
NO_STANDING rule for many segments — the map polyline is green because the segment's `rules` array
is missing the restriction, not because of an engine defect. Traced against the current (defective)
tile data, `ParkingRulesEngine.currentState(for:at:)` computes `.freeComfortably` **correctly given
its input** — the engine is not at fault this time.

Kevin's TF2-14 divided-street work (commit `a176147`) is **not the mechanism** of the bug: the code
diff in that commit only touches the curb-offset/geometry function (`getCurbOffsetFromWidth`,
`initWidths`, two `offsetPolyline()` call sites). It does not touch sign fetching, deduplication, or
segmentation/rule-assignment logic. The data loss is a side effect of re-running the **entire**
pipeline end-to-end (which always re-fetches signs live, no cache) in order to ship an
otherwise-unrelated geometry fix.

---

## 2. Corridor-Level Evidence (Houston / Bowery)

Compared segment-by-segment: `tiles/tile_{9,10,11}_{11,12,13}.json` (the Houston/Bowery/LES
cluster) at `a176147^` ("pre," last known-good rule content before regen 5) vs. the current working
tree ("post," what's shipped in both the PWA `tiles/` and the iOS bundle
`ios/WePark/WePark/Resources/tiles/`).

### 2.1 Corridor segment/rule counts (7 tiles covering the Houston/Bowery junction)

| Street/side | Pre segments | Post segments |
|---|---|---|
| BOWERY, E | 23 | 18 |
| BOWERY, W | 23 | 19 |
| EAST HOUSTON STREET, N | 9 | 8 |
| EAST HOUSTON STREET, S | 15 | 10 |

| Rule category | Pre count | Post count | Δ |
|---|---|---|---|
| METERED | 30 | 20 | -33% |
| NO_PARKING | 19 | 8 | -58% |
| NO_STANDING | 36 | 29 | -19% |
| TRUCK_LOADING | 10 | 5 | -50% |
| ASP_DAILY | 5 | 5 | 0% |
| ASP_MON_THU | 2 | 3 | (noise) |
| ASP_OVERNIGHT_MWF | 14 | 14 | 0% |
| ASP_OVERNIGHT_TTHS | 8 | 8 | 0% |
| ASP_TUE_FRI | 3 | 3 | 0% |
| Empty-rules segments | 0 | 0 | — |

The ASP categories (a separate Socrata dataset, see §4) are untouched; every MAIN-dataset category
dropped hard.

### 2.2 Concrete geometry-identical segments that lost their METERED / NO_PARKING rule

These are **not** stub-merge or renumbering artifacts — `line` coordinates are byte-identical
pre/post, so this is the same physical curb losing rule content, not a different curb inheriting an
old numeric suffix:

```
BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_0   (Bowery, east side, Stanton → E Houston)
  line: identical pre/post
  pre : ASP_OVERNIGHT_TTHS, METERED ("2 HMP MON-FRI 10AM-7PM SAT 8AM-7PM"), TRUCK_LOADING
  post: ASP_OVERNIGHT_TTHS   ← METERED and TRUCK_LOADING gone

BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_1   (same block, next sub-segment)
  line: identical pre/post
  pre : ASP_OVERNIGHT_TTHS, METERED, TRUCK_LOADING
  post: ASP_OVERNIGHT_TTHS   ← same loss

BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_2
  line: identical pre/post
  pre : TRUCK_LOADING, METERED
  post: TRUCK_LOADING        ← METERED gone

ELIZABETH_STREET_EAST_HOUSTON_STREET_BLEECKER_STREET_W_3
  line: identical pre/post
  pre : ASP_MON_THU, NO_PARKING
  post: ASP_MON_THU          ← NO_PARKING gone
```

At a weekday 2:00 PM ET, `BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_0`'s METERED sign ("2 HMP
Mon–Fri 10AM–7PM Sat 8AM–7PM") is squarely inside its paid window (600–1140 minutes = 10am–7pm).
Pre-regen-5 the engine would correctly compute `.meteredActive` (amber) here. Post-regen-5 (current,
shipped) the METERED rule simply isn't in the tile anymore, so the engine — acting correctly on the
data it's given — computes `.freeComfortably` (green). This is Kevin's exact complaint.

Same pattern confirmed on the other TF2-14 divided allow-list streets, spot-checked citywide (not
just the Houston/Bowery junction tiles):

| Street | Segs pre→post | METERED pre→post | NO_STANDING pre→post | TRUCK_LOADING pre→post | UNKNOWN pre→post |
|---|---|---|---|---|---|
| ALLEN STREET | 64→60 | 40→34 (-15%) | 31→25 (-19%) | 15→5 (-67%) | 7→2 (-71%) |
| FORSYTH STREET | 64→57 | 17→12 (-29%) | 21→14 (-33%) | 2→1 (-50%) | 38→34 (-11%) |
| DELANCEY STREET | 117→109 | 28→10 (-64%) | 45→34 (-24%) | 3→2 (-33%) | 69→28 (-59%) |

ASP_DAILY/ASP_MON_THU/ASP_TUE_FRI/ASP_OVERNIGHT_MWF counts on all three of these streets are
**unchanged** pre→post (e.g., Delancey ASP_DAILY 31→31, ASP_MON_THU 40→40, ASP_TUE_FRI 38→38).

---

## 3. Citywide Evidence (all 976 tiles)

To determine whether this is confined to the TF2-14 divided allow-list or a broader failure, I
diffed **every** tile file changed by commit `a176147` (988 of 989 tile files) against
`a176147^` (the last commit before regen 5).

| Metric | Pre (a176147^) | Post (current) | Δ |
|---|---|---|---|
| Total segments | 36,924 | 30,000 | -18.8% |
| Empty-rules segments | 0 | 0 | 0 |
| Total rule instances | 70,037 | 51,525 | -26.4% |

| Rule category | Pre | Post | Δ | Source dataset |
|---|---|---|---|---|
| METERED | 12,856 | 6,673 | **-48.1%** | MAIN (`nfid-uabd`) |
| NO_PARKING | 4,821 | 2,574 | **-46.6%** | MAIN |
| NO_STANDING | 16,156 | 9,373 | **-42.0%** | MAIN |
| TRUCK_LOADING | 2,162 | 1,347 | **-37.7%** | MAIN |
| SPECIAL | 1,519 | 929 | **-38.8%** | MAIN |
| UNKNOWN | 4,748 | 2,885 | **-39.2%** | MAIN |
| ASP_DAILY | 4,982 | 4,955 | -0.5% | ASP (`2x64-6f34`) |
| ASP_MON_THU | 11,061 | 11,057 | -0.0% | ASP |
| ASP_TUE_FRI | 11,287 | 11,288 | +0.0% | ASP |
| ASP_OVERNIGHT_MWF | 257 | 256 | -0.4% | ASP |
| ASP_OVERNIGHT_TTHS | 188 | 188 | 0.0% | ASP |

**Every category sourced from the MAIN Socrata dataset dropped 37–48%. Every category sourced from
the separately-fetched ASP dataset held flat (within normal week-to-week sign-update noise, <1%).**
This split maps exactly onto `build/preprocess.js`'s two independent fetch calls
(`fetchSocrataDataset(SOCRATA_MAIN, ...)` then `fetchSocrataDataset(SOCRATA_ASP, ...)`), which is
strong, precise evidence that the MAIN fetch specifically failed to complete during the regen-5 run
— this is not noise, not a code bug in rule classification, and not geography-specific.

The 18.8% segment-count drop is a consequence, not a separate bug: fewer raw MAIN-dataset sign
records means fewer split points during segmentation, so blocks get merged into fewer, coarser
segments. (This also explains why some segment IDs from the pre-tiles don't exist post-regen and
vice versa — §2 above deliberately used geometry-identical, byte-for-byte-matching segments to rule
out renumbering as an explanation.)

The two commits are 22 minutes apart on the same day (`a14a4b8` 10:26:06, `a176147` 10:48:21,
2026-06-15 -0400) — far too close together for NYC to have legitimately revised 40–48% of live
signage citywide between the two pulls. This rules out "NYC updated their data between builds" as
the explanation and points conclusively at the fetch itself.

---

## 4. Root Cause — Exact Code Path

### 4.1 The fetch loop with no retry and no ordering guarantee

`build/preprocess.js`, `fetchSocrataDataset()` (current file, ~line 1215):

```js
async function fetchSocrataDataset(baseUrl, label) {
  const signs = [];
  let offset = 0;
  let keepFetching = true;
  while (keepFetching) {
    const url = `${baseUrl}?$limit=${PAGE_SIZE}&$offset=${offset}&borough=Manhattan`;
    try {
      const resp = await fetch(url);
      if (!resp.ok) {
        console.log(` HTTP ${resp.status} - stopping`);
        break;                              // ← silent truncation, no retry
      }
      const data = await resp.json();
      if (!Array.isArray(data) || data.length === 0) { keepFetching = false; break; }
      signs.push(...data);
      if (data.length < PAGE_SIZE) keepFetching = false;
      else offset += PAGE_SIZE;
    } catch (e) {
      console.log(` ERROR: ${e.message}`);
      break;                                // ← silent truncation, no retry
    }
  }
  return signs;
}
```

Confirmed via `git diff a176147^ a176147 -- build/preprocess.js`: **this function is byte-identical
between the two commits.** The regen-5 diff only adds the CSCL width/offset code
(`getCurbOffsetFromWidth`, `initWidths`, `DIVIDED_STREET_ALLOW_LIST`, etc.) and two call-site
substitutions of `getStreetCurbOffset(block.street)` → `blockCurbOffset` inside `offsetPolyline()`
calls. It does not touch `fetchSocrataDataset`, the dedup step ("3b. Deduplicate signs by
street/side/description"), or segmentation/rule-assignment. **TF2-14's code is not the mechanism.**
The bug is inherent in a fetch helper that predates regen 5 and was simply re-exercised by re-running
the full pipeline for an unrelated geometry fix.

Contributing/aggravating factors, all independently verifiable in the current code:

1. **No `$order` clause** on either Socrata query (`grep -n '\$order' build/preprocess.js` → no
   hits). Per Socrata SODA API guidance, paginating with `$limit`/`$offset` without an explicit,
   stable `$order` is not guaranteed to return a consistent superset across sequential page
   requests, especially against a dataset that receives ongoing writes (this is a live NYC sign
   database). A quick live probe today shows the same offset window returning identical results
   back-to-back (so it isn't visibly churning at this moment), but this doesn't rule it out as a
   contributing factor during the actual regen-5 run — it remains an unforced structural risk with
   zero mitigation in the code.
2. **No `X-App-Token` header** (`grep -n 'X-App-Token\|app_token\|headers' build/preprocess.js` → no
   hits). Unauthenticated Socrata requests are subject to tighter throttling than app-token'd
   requests, which raises the odds of a `429`/timeout partway through the ~16 pages required for the
   MAIN dataset (75,684 live Manhattan records ÷ `PAGE_SIZE=5000` ≈ 16 pages) vs. the ~5 pages
   required for the ASP dataset (20,346 live Manhattan records) — consistent with MAIN being hit and
   ASP being spared. (Live counts verified today via `$select=count(*)&borough=Manhattan` against
   both endpoints: MAIN 75,684, ASP 20,346 — matching the "76K+ records" figure already documented
   for this project.)
3. **No completeness validation.** Nothing in `main()` compares `mainSigns.length` /
   `aspSigns.length` against an expected floor, a `$select=count(*)` sanity check, or the previous
   build's fetched count. A truncated fetch produces a perfectly well-formed, small-looking log line
   (`Total signs fetched: N`) and the pipeline proceeds to build valid-looking tiles with silently
   missing rules. There is no gate anywhere (build-time or CI) that would have caught this before
   commit `a176147` shipped to both `tiles/` and `ios/WePark/WePark/Resources/tiles/`.

### 4.2 Why this reads as "free" and not "unknown/gray"

`segment.rules` is never empty (0 empty-rules segments, pre and post, confirmed in §2 and §3) —
the affected segments still carry *some* rules (e.g., `ASP_OVERNIGHT_TTHS` alone, or
`TRUCK_LOADING` alone), just missing the METERED/NO_STANDING/NO_PARKING entry that would have made
them correctly red/amber during the day. `ParkingRulesEngine.currentState(for:at:)` (iOS,
`Services/ParkingRulesEngine.swift:316-352`) therefore takes the normal "no active/soon restriction,
no active meter" path and returns `.freeComfortably` — which is the **correct output for the data it
was given**. This is the opposite failure mode from FT-9: there, the data was right and the engine's
`safetyLabel` picked the wrong branch; here, the engine picks the right branch and the *data* is
wrong. Traced concretely: at Wed 2:00 PM ET on
`BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_0`, `rules.contains(where: { $0.category == .metered
})` evaluates `false` post-regen-5 (the METERED rule isn't there), so line 337's branch is skipped
entirely and the function falls through to `.freeComfortably` at line 351. Pre-regen-5, with METERED
present and the sign's own time range (600–1140, i.e. 10am–7pm) covering 2:00 PM (minute 840), the
same code would have returned `.meteredActive`.

### 4.3 iOS bundle sync (part of hypothesis (d))

`diff -q` between `tiles/*.json` (PWA/repo canonical tiles) and
`ios/WePark/WePark/Resources/tiles/*.json` for the Houston/Bowery cluster (`tile_10_11`,
`tile_10_12`, `tile_10_13`, `tile_11_11`, `tile_11_12`) and `index.json` shows **zero differences** —
the iOS bundle and the PWA tiles are byte-identical. Regen 5 wrote both from the same (defective) run,
so both apps show the identical incorrect free/green state. This is not a bundle-sync bug; it's
present, consistently, everywhere `tiles/` ships.

---

## 5. Hypothesis Verdicts

| Hypothesis | Verdict |
|---|---|
| (a) Regen 5 dropped/misassigned rules specifically via its divided-street allow-list logic | **NOT THE CAUSE.** The TF2-14 code diff never touches sign fetch, dedup, or rule assignment — only curb-offset geometry. The rule loss is citywide and equally severe on non-allow-list streets (e.g. Elizabeth St, Mott St) as on allow-list streets. |
| (b) Side gap — rules on one curb, opposite side empty | **NOT CONFIRMED.** Empty-rules segments = 0 both pre and post, citywide. Both sides of Bowery/Houston have segments with rules in both snapshots; the loss is *within* existing segments' rule arrays, not a missing side. |
| (c) Zone-cap / stub-filter over-trim (regens 4–5) | **NOT THE CAUSE.** The zero-length stub filter and curb-cut zone cap are regen-4 code (`isDegenerateLine`, TF2-12/13), confirmed unchanged by the regen-5 diff. Segment-count shrinkage (-18.8%) is a downstream consequence of fewer raw sign records to split on, not a change in filter aggressiveness. |
| (d) Engine daytime mapping regression | **NOT THE CAUSE** (confirmed, as FT-9 predicted). `currentState()` is unchanged and computes the objectively correct output for its (defective) input. Traced concretely against `BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_0` at Wed 2PM ET: engine is right, data is wrong. iOS bundle tiles are confirmed in sync with repo tiles — not a packaging gap either. |
| **(new) MAIN Socrata fetch incomplete during regen-5 build run** | **CONFIRMED ROOT CAUSE.** Citywide, category-selective (MAIN -37–48%, ASP ~0%) data loss with no code change to the fetch/dedup/rule-assignment path; fetch loop has no retry, no `$order`, no app token, and no completeness validation. |

---

## 6. Blast Radius

**Citywide, not limited to the TF2-14 divided-street allow list.** Any block whose regulation comes
from the MAIN Socrata dataset (METERED, NO_STANDING, NO_PARKING, TRUCK_LOADING, SPECIAL, UNKNOWN —
i.e., most non-ASP regulation types) has roughly a 40–48% chance, block-by-block, of having lost part
or all of its restrictive signage in the currently-shipped tiles (both PWA and iOS). Blocks whose
regulation is purely `ASP_*` are essentially unaffected. Because the loss appears to follow whatever
implicit/unstable order the Socrata pagination returned records in (not a clean geographic or
alphabetical cutoff — e.g. one 2nd Avenue METERED segment checked was untouched while several
Bowery/Houston/Delancey segments lost METERED entirely), **the actual set of affected blocks is not
predictable from street name alone and needs a full citywide audit**, not just a fix scoped to
Houston/Bowery/Allen/Forsyth/Delancey.

Practical severity: on a metered/no-standing corridor, this shows the map polyline itself as green
("free") when it should be amber/red — a strictly worse and more visible failure than FT-9 (which
only affected text labels while the polyline stayed correct). A driver trusting the map color alone
would be misled into parking on a paid or prohibited block.

---

## 7. Fix Recommendation

### 7.1 Immediate (data correctness): regen 6 — re-run the full pipeline with fetch hardening

This is a **backend-data / pipeline** fix, not an iOS or PWA engine fix (the engine is exonerated —
§4.2, §5). Recommended before the next regen:

1. **Add retry-with-backoff** to `fetchSocrataDataset()` on both HTTP-error and exception paths
   (e.g., 3 attempts, exponential backoff) instead of a bare `break`.
2. **Add an explicit `$order`** clause using a stable field (or switch to Socrata's offset-free
   pagination if a suitable cursor field exists) so repeated page requests can't skip/duplicate rows
   even under concurrent dataset writes.
3. **Add an `X-App-Token` header** (register a free Socrata app token) to reduce throttling risk
   across the ~16-page MAIN pull.
4. **Add a post-fetch completeness check**: query `$select=count(*)&borough=Manhattan` before paging
   and assert `mainSigns.length` (and `aspSigns.length`) land within some tolerance (e.g. ±2%) of the
   reported count; abort the build loudly rather than silently shipping a partial pull. This is the
   single highest-leverage change — it would have caught regen 5's failure outright.
5. Re-run the full regen once (1–4) land, and diff the new output against the current (defective)
   tiles the same way this investigation did, to confirm MAIN-dataset categories return to parity
   with the ASP categories' stability.

### 7.2 Longer-term (defense in depth)

- Consider caching each build's raw fetched sign payload (e.g., `raw_signs_<timestamp>.json`,
  gitignored) so future diagnosis doesn't require reconstructing pre/post state from git history, and
  so a future regen with a good pull doesn't have to be preceded by a bad one to be noticed.
- Add a CI/pre-merge tile-diff sanity gate: flag any regen PR where a rule category's total instance
  count changes by more than some threshold (e.g. >10%) versus the previous committed tiles, as a
  forcing function to catch this class of bug before merge rather than after a field-test drive.

### 7.3 Owner / sequencing

| Step | Owner | Notes |
|---|---|---|
| Fetch hardening (retry, `$order`, app token, completeness check) | `@backend-data` (pipeline, `build/preprocess.js`) | Spec not required — this is fetch-layer robustness, no contract change to tile schema, RPC, or client code. |
| Regen 6 (full re-pull + rebuild) | `@backend-data` | Expensive, large diff — expected and justified here (bug fix, not speculative). Must ship to both `tiles/` and `ios/WePark/WePark/Resources/tiles/` together, as regen 5 did. |
| Validation | `@backend-data` | Re-run this investigation's citywide category-count diff against the new tiles; confirm MAIN-dataset categories are back near parity with ASP-dataset stability, and spot-check Houston/Bowery/Delancey against live NYC signage. |
| No iOS or PWA code change required | — | The rules engine (`ParkingRulesEngine.swift` `currentState`) and its PWA equivalent are confirmed correct against the data they're given. Nothing to fix on the client side for TF2-19 specifically. |

### 7.4 Does this need a tech-lead spec?

Recommend a short spec-lite (not a full contract spec) before regen 6, since it changes the tile
*content* pipeline's reliability guarantees (not a schema/RPC contract both clients call) — mainly to
get sign-off on the app-token registration (external dependency) and the completeness-check
threshold. This does not touch `SUPABASE_MVP_SCHEMA.md`, any RPC name, or client provider code, so it
does not need the full "spec with @tech-lead" workflow reserved for cross-client contracts — but
given the size of the coming diff (a full regen touches ~990 files again) and that Kevin explicitly
called for "proper flow (spec → build → QA → merge), no expedite" in the TF2 Round 3 notes, a brief
write-up before running regen 6 is warranted.

---

## 8. Safety Notes

1. **This is a data-integrity defect, not a display bug.** Unlike FT-9, the map polyline itself is
   wrong. Any surface that reads the polyline color or `currentState`/`currentStateColor` (map, the
   6pt severity band in `BlockDetailView`, `isMeteredActive` line-width logic) is affected on the
   ~40–48% of MAIN-dataset-regulated blocks that lost rule content, on top of any surfaces already
   affected by the still-open FT-9 `safetyLabel` branch-ordering bug (separate, unresolved).
2. **Silent failure mode.** Nothing about the shipped tiles looks malformed — `rules` arrays are
   never empty, so there's no `.unknown` (gray) fallback signaling "we don't know." The pipeline
   produces confidently wrong (green) output instead of visibly incomplete output. This is the most
   dangerous kind of data-pipeline bug and is why item 7.2's completeness-check recommendation is the
   highest-priority hardening step.
3. **Not reproducible from code alone at investigation time** — a live probe today shows the same
   Socrata offset window returning stable, identical results back-to-back, so I cannot say with
   certainty which single proximate trigger (HTTP error/timeout mid-pull, unordered-pagination
   skip, or something else transient in that ~22-minute build window) caused the June 15 truncation.
   That uncertainty does not weaken the root-cause finding — the *citywide, dataset-selective*
   evidence in §3 independently and conclusively points at the MAIN fetch during regen 5, regardless
   of the exact trigger — but it does mean 7.1's hardening items (retry, `$order`, app token,
   completeness check) should all be adopted together rather than picking just one, since any of them
   could plausibly have prevented this specific incident.
4. **TF2-15 (Bowery under construction) is a separate, already-logged, roadmap-scoped issue** — the
   "Bowery isn't actually parkable right now due to construction" observation is about temporary
   real-world conditions the static sign tiles were never meant to capture, and is unrelated to this
   investigation's finding that the *signed, legal* METERED/NO_STANDING regulation itself is missing
   from the tile data.
