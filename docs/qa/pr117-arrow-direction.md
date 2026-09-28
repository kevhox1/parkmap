# Arrow-direction span authority (#26) — QA Pass 1 — 2026-09-26

**Reviewed:** PR #117, branch `data/arrow-direction-fix` at `e601aa41`, base `main` at `c8e287a2`,
against `docs/open-items.md` #26, `docs/field-testing-log.md` TF2-13, and the PR body's own acceptance
claims. Independent full-pipeline regens re-run against **live NYC Socrata data pulled 2026-09-26**
(96,250 signs, byte-identical cached pull reused for both before/after runs — see methodology below).

**Verdict: FIX-THEN-MERGE**

## Summary

The core mechanism — using DOT's authoritative `arrow_direction` compass field, via dot product
against a correctly-derived (non-reversed) block bearing, to override an ambiguous printed glyph — is
**structurally sound and independently verified correct** in every hand-checked case (5/5 sampled
more-permissive flips reconstructed by hand from raw sign records, 0 errors found; several cases show
two co-located signs with an *identical* printed glyph but *opposite* real-world `arrow_direction`,
which is decisive proof that glyph alone cannot disambiguate and this fix is necessary). The blast-radius
and rule-drift numbers in the PR body reproduce almost digit-for-digit against a fresh live pull. Fallback
discipline for arrow_direction-absent signs is clean (0 drift across 4,478 block faces). However, **the
PR's own flagship, motivating acceptance case — Kevin's E 4th St / Bowery→2nd Ave photographed block —
does not actually resolve to the claimed result when run through the real, full production pipeline
against live data**, because of an unrelated, pre-existing coordinate-completeness gap in the DOT sign
dataset that the acceptance test's fixture silently bypasses. There is also a real, small-blast-radius
regression in the TF2-13 cap's interaction with this fix, and the PR undersells (as "one verified block")
a line-orientation characteristic that is present in **23% of Manhattan blocks**, not a rare edge case —
which matters because a sibling function (`getOnewayFields`) inherits the identical bug, undisclosed.
None of this indicts the core direction-resolution logic. Fix the two concrete bugs and correct/caveat
the E4th claim before merging; the mechanism itself does not need to be redesigned.

## Methodology (what "independently reproduced" means here)

I did not read the diff and trust the PR's numbers. I built a byte-identical controlled A/B myself:

1. Pulled the full live Manhattan sign corpus once (both Socrata datasets, 96,250 rows, completeness
   gates passed) and cached every HTTP response to disk keyed by URL hash via a `global.fetch` preload
   shim (`--require` preload, no source file touched).
2. Ran the **actual, unmodified `node build/preprocess.js`** twice — once checked out at base `c8e287a2`,
   once at PR tip `e601aa41` — both replaying the identical cached pull (no live-data drift between
   "before" and "after"). Base wrote to its own `tiles/`; PR wrote to a scratch dir via the PR's own new
   `PREPROCESS_OUT_DIR` guard (confirmed real `tiles/`/iOS Resources paths untouched: `git diff
   c8e287a2 HEAD --name-only -- tiles/ ios/ supabase/` → 0 files).
3. For finer-grained analysis (physically-anchored, distance-range diffing rather than the tile output's
   fragile index-based segment IDs — see Finding #3), I called the PR's own exported
   `createSubSegments()`/`getBlockPolyline()`/`resolveSignSpanDirection()` directly, replicating
   `main()`'s filter/dedup/block-grouping steps verbatim against the same cached pull.  Passing
   `bearingVector = null` reproduces the pre-#26 glyph-only algorithm exactly (confirmed against `scripts/test-arrow-direction-fix.js`'s own semantics), giving a true controlled A/B without needing the base
   commit's un-exported internals.
4. Re-ran `scripts/test-arrow-direction-fix.js` verbatim (18/18) and hand-inspected all three fixtures
   against a fresh live pull for the same physical signs (by `order_number`).

## Acceptance criteria checklist

- [x] **Danger-direction classification of the ~5,067 changed segments** — done via a physically-anchored
      (distance-range) diff, not tile-id matching (see Finding #3 for why). Totals: **391,729 ft newly
      MORE permissive, 88,553 ft newly LESS permissive, 251,626 ft coverage-gap/lateral** (ratio ≈4.4:1
      toward more-permissive, consistent with the PR's own aggregate category deltas). Top single flip
      bucket by ft: `NO_STANDING → METERED` (71,589 ft), matching the PR's own claim.
- [x] **Hand-verification of ≥5 more-permissive changes against raw sign data** — 5/5 sampled, 0 errors
      found. See Finding table below. **Not a BLOCK per the brief's trigger** — none of the hand-verified
      *mechanism* outputs were wrong; see Finding #1 for why the acceptance-case concern is a different,
      separate issue (test representativeness, not mechanism correctness).
- [x] **Compass-conversion math / 0.35 confidence threshold** — reviewed and reproduced: 56/17,818
      (0.31%) of arrow_direction-present signs fall below threshold and correctly glyph-fallback.
      Adversarial curved/L-shaped-block case constructed — see Finding #4 (structural gap confirmed,
      real-world quantification inconclusive due to an unrelated bug my own tooling surfaced).
- [x] **Orientation bug fix (`fromToBearing`)** — verified structurally correct (computed from raw
      pre-reordering `ptFrom`/`ptTo`, never from `line[0]/line[last]`) and **far more consequential than
      the PR discloses**: 1,731/7,488 (23.1%) of unique Manhattan blockfaces have `line` oriented
      opposite to `from_street→to_street`, not "at least one verified real block." Geometry outputs
      (`line`, trim, offsets) confirmed byte-identical to pre-PR via `git diff --name-only -- tiles/
      ios/` (0 files) and via direct tile inspection.
- [ ] **E 4th St acceptance test — FAILS against a live full-pipeline regen.** See Finding #1 (🔴).
      The isolated fixture-level test (18/18) passes and is not fabricated (every fixture row matches a
      real, live `order_number` I independently re-pulled) — but the *real* pipeline drops exactly the
      signs load-bearing for the claimed "49-399ft ASP_MON_THU" result, for a reason unrelated to this
      PR's own diff.
- [x] **TF2-13 kept, not redundant** — the reasoning is correct in general, but the cap has a real,
      small-blast-radius gating bug post-fix. See Finding #2 (🟡).
- [x] **Fallback discipline (arrow_direction-absent → byte-identical)** — verified clean: 0 drift across
      4,478 block faces where no sign carries `arrow_direction`.
- [x] **Sweeps** — no `tiles/`/iOS/Supabase changes (confirmed via `git diff --name-only`), docs updates
      (`open-items.md`, `field-testing-log.md`, `brooklyn-expansion-spec.md`) accurately reflect
      independently-reproduced numbers, no banned copy (data-only PR, no user-facing strings).

## Findings

### 🔴 Blocking

- **#1: The PR's flagship, motivating acceptance case (Kevin's E 4th St / Bowery→2nd Ave block) does not
  resolve to the claimed result in a live, full-pipeline regen — a real production regen would still
  misrepresent this exact block, just with a different wrong answer.**
  - Where: `build/preprocess.js`'s Manhattan-bounds filter (`SP_BOUNDS` check on `sign_x_coord`/
    `sign_y_coord`, unchanged by this PR, ~line 1743-1747) interacting with `scripts/fixtures/
    arrow-direction-e4th-bowery-2ave-n.json` (bypasses that filter entirely).
  - What: I ran the real `node build/preprocess.js` end to end against a live pull (see Methodology).
    For `EAST 4TH STREET (BOWERY to 2ND AVENUE) [N]`, the shipped tile output is:
    ```
    [0-49ft]    NO_STANDING
    [49-421ft]  NO_PARKING      <- PR claims "49-399ft contiguous ASP_MON_THU"
    [421-485ft] NO_STANDING
    [485-545ft] METERED (rules include ASP_MON_THU, not dominant)
    [545-709ft] NO_STANDING
    ```
    The three DOT sign rows that create the claimed ASP_MON_THU zone (order `P-01798286`, distances
    191ft/315ft/399ft, `sign_code` PS-113B/PS-113BA, "NO PARKING ... MONDAY THURSDAY ...") are **present
    and correct in NYC's live dataset today, but are missing `sign_x_coord`/`sign_y_coord`** — I
    confirmed this by pulling the raw records directly (full JSON dump, fields absent, not just empty).
    `main()`'s pre-existing `SP_BOUNDS` filter silently drops any sign lacking coordinates before it ever
    reaches classification/composition. This is a genuine, real (not synthetic) ~6.9%/5.3%
    coordinate-completeness gap across the two Socrata datasets (5,247/75,917 main, 1,087/20,333 ASP) —
    it just happens to hit exactly the three rows this PR's headline example depends on.
    The acceptance test (`scripts/test-arrow-direction-fix.js`) never surfaces this because its fixture
    is a hand-"slimmed" copy of real field values with the coordinate fields dropped entirely — it
    exercises `createSubSegments()`/`resolveSignSpanDirection()` directly, below the layer where
    `SP_BOUNDS` filtering happens, so it cannot fail this way even though the real pipeline does.
  - Expected: per the PR body, a production regen should show "49-399ft contiguous ASP_MON_THU" for
    this block — the entire reason this fix session exists.
  - Repro: `node build/preprocess.js` (live pull) on the PR branch; inspect the tile segment(s) for
    `EAST_4TH_STREET_BOWERY_2ND_AVENUE_N_*`. Or re-run my harness: see scratch scripts referenced below.
  - Impact: this is *not* a defect in `resolveSignSpanDirection()` — the resolution of every sign that
    *does* reach composition is correct (the 49ft/421ft/485ft/545ft signs resolve exactly as the PR
    describes). It is a test-representativeness problem: the acceptance test proves the algorithm is
    right given the data it's fed, but does not prove the *real pipeline* will actually feed it that
    data for the block that matters most. Shipping this as-is means Kevin's photographed complaint
    (No Standing wrongly painted over an ASP stretch) becomes a *different* wrong claim (No Parking
    wrongly painted over the same stretch) — progress in the abstract (NO_STANDING is more restrictive
    than NO_PARKING) but not the fix as described, and exactly the block he will re-check first.
  - Fix suggestion: either (a) relax/supplement `SP_BOUNDS` to not silently drop signs missing
    coordinates when `on_street`/`from_street`/`to_street` are otherwise resolvable to a known Manhattan
    block (the `borough=Manhattan` query param already does most of this filtering upstream — the
    coordinate check may be redundant/over-strict), which would also recover ~5-7% of signs dataset-wide,
    not just this block; or (b) at minimum, correct the PR body's claim and get Kevin's explicit
    sign-off on the corrected outcome (NO_PARKING, not ASP_MON_THU) before shipping a regen he will
    personally re-verify against his own photo.
  - Owner: `@backend-data`.

### 🟡 Significant

- **#2: TF2-13's isolated-driveway cap checks the printed glyph (`sd.arrow === 'towards'`) instead of
  the resolved, arrow_direction-aware direction — so a sign the #26 fix newly flips *into* an isolated,
  forward-resolving `NO PARKING ANYTIME` reading (because its glyph disagreed with `arrow_direction`)
  never gets capped, silently reintroducing the exact TF2-13 symptom for that population.**
  - Where: `build/preprocess.js`, the `isIsolatedNPAnytime` guard (~line 1465-1469): `sd.category ===
    'NO_PARKING' && sd.arrow === 'towards' && /NO PARKING ANYTIME/i.test(...) && !uniqueDists.some(...)`.
  - What: the surrounding `if (coversAfter)` block is gated on `sd.resolved.coversAfter` (the new,
    arrow_direction-aware value) — but the cap's own guard condition still reads `sd.arrow` (the raw
    glyph). For a sign whose glyph is `<--`/`<->`/null but whose `arrow_direction` flips
    `resolved.coversAfter` to `true`, the block executes but the cap never fires (`sd.arrow !==
    'towards'`), so an isolated driveway-class sign with no closing sign within 50ft bleeds to the block
    end or next sign, uncapped.
  - Repro: live-verified 2 real instances today (both `NO PARKING ANYTIME (ARROW) (SUPERSEDED BY
    R7-40RA...)`, `distance=0`, glyph `null`, `arrow_direction` present and confidently resolving
    forward, isolated): `VAN CORLEAR PLACE (WEST 227TH STREET to FORT CHARLES PLACE) [E]` and
    `MAIN STREET (ROOSEVELT ISLAND BRIDGE to WEST ROAD) [W]`.
  - Impact: small confirmed population today (2 instances) but the guard's own comment ("both/null
    signs cover the whole face by design") is now a stale assumption post-#26 — a null/both glyph can
    be arrow_direction-resolved into a one-directional isolated sign, and the cap's design never
    accounted for that. Worth fixing precisely rather than leaving a gap that could grow.
  - Fix suggestion: gate `isIsolatedNPAnytime` on `sd.resolved.coversAfter` having actually been
    established by this iteration (already true, since we're inside `if (coversAfter)`) and drop the
    `sd.arrow === 'towards'` literal-glyph check entirely — the cap's intent ("isolated forward-only
    NO PARKING ANYTIME sign") is now fully captured by `sd.resolved.coversAfter === true` combined with
    the isolation/description checks; the glyph itself is no longer the right signal for "is this
    forward-only."
  - Owner: `@backend-data`.

- **#3: The tile-level segment `id` scheme (`street_from_to_side_${idx}`, an ordinal zone index, not a
  physical anchor) produces a misleading "geometry moved" signal when a PR changes zone *counts* per
  block face — which this PR does, by design, unlike #116 (whose comparator this scheme was built for).**
  - Where: `build/preprocess.js` (`segId` construction, ~line 1900) / `scripts/compare-tilesets.js` (not
    present on this PR's branch, but the same idx-based ID scheme it depends on is inherited from
    `main`).
  - What: I ran the fixed comparator (from #116, `5dc4eefe`) against my controlled before/after tiles.
    It reported 1,873 segments as "geometry moved, rules identical" with a mean displacement of 12.87m
    and outliers up to 76.99m — including `EAST 4TH STREET (BOWERY to 2ND AVENUE) [N]` at 74.66m. I
    traced this by hand: it is **not** a real geometry bug. Because #26 changes how many zones a block
    splits into, the *same* ordinal `idx` (e.g. `_N_0`) can refer to a completely different physical
    stretch before vs after, and if that stretch coincidentally carries byte-identical `rules` content
    (e.g. two different NO_STANDING zones with the same sign text), the comparator treats it as "moved
    geometry" for a segment that is not the same segment at all — a false signal, not a real mover.
  - Impact: does not affect this PR's own correctness (the actual tile output is fine — I verified the
    real physical composition separately, see Methodology step 3, which avoids id-matching entirely).
    But it means: (a) this specific comparator run is not usable evidence for *this* PR's geometry
    claims (the PR body doesn't cite it, so no false claim was made); (b) any future reviewer who reruns
    `compare-tilesets.js` against this PR's tiles and sees "1,873 moved segments, up to 77m" will be
    misled unless they know this. The PR's own reported "43,113 matching ids" / "9,683 same-category
    different-rules" / "28,363 unchanged" buckets are *also* built on this same idx-based id, and while I
    independently reproduced the PR's top-line aggregate numbers via a physically-anchored method that
    doesn't have this flaw (Methodology step 3, matching almost digit-for-digit), I did not re-derive the
    PR's own 43,113/9,683/28,363 split via an id-independent method, so I can't rule out some drift
    between those specific bucket counts and physical reality at the margins.
  - Fix suggestion: for composition-only PRs (zone count can change), match zones by physical
    distance-range overlap rather than ordinal index — exactly the technique I used to build the
    danger-direction table in this review. Worth adding as a `compare-tilesets.js` mode alongside the
    existing geometry-only mode #116 built it for.
  - Owner: `@backend-data`.

- **#4: The 0.35 confidence threshold only guards against block-wide diagonal ambiguity (near-45°
  from→to bearing) — it does NOT guard against a curved/bent/L-shaped block whose single, block-wide
  straight-line bearing misrepresents the LOCAL street direction at a specific sign's actual position.**
  - Where: `getBlockBearingVector()`/`resolveSignSpanDirection()` — `bearingVector` is computed once per
    block (straight line between the two intersection points) and applied identically to every sign on
    the face, regardless of where along a curve that sign physically sits.
  - What (adversarial case, as requested): imagine a block that runs due East for its first half then
    bends 90° to run due North for its second half. The straight-line endpoint-to-endpoint bearing might
    point confidently ~NE (dot product nowhere near the 0.35 ambiguity zone) while a sign on the second
    (northward) leg has a true local orientation that's actually perpendicular to that "confident"
    bearing. The threshold would not catch this — it measures confidence in the *wrong* thing (global
    alignment) for a case where the risk is *local* curvature, not diagonal-grid ambiguity.
  - Quantification attempt and an important caveat: I tried to count real Manhattan blocks exhibiting
    this shape (straight-line/arc-length ratio < 0.85) that also had ≥1 sign resolve via
    `arrow_direction`. My first attempt found 34 such blocks (including Delancey St, E Houston St,
    Canal St, Riverside Dr) — but investigating further, I found this count itself is **unreliable**: I
    discovered that `getBlockPolyline()` (specifically `findIntersection`/`closestPointOnStreet`/
    `extractPolylineBetween`, none of them touched by this PR) returns **order-dependent, non-
    deterministic results** for at least one block (`DELANCEY STREET (LUDLOW STREET to ESSEX STREET)
    [S]`) depending on how many *other* blocks were processed earlier in the same run — isolated,
    it returns a normal ~53m/175ft block; after processing 1,000 other blocks first, the identical
    call returns a corrupted 961m/3,154ft result. I could not fully root-cause this in the time
    available (it does not appear to be simple call-count repetition — repeating the *same* call 1,005
    times in a row is stable). The real, committed tile output for this specific block (from my true
    `node build/preprocess.js` regen) shows the *normal*, short geometry, so I have no evidence this
    bug is currently causing wrong shipped output — but it means my curvature count (and possibly other
    geometry-adjacent measurements anyone runs via ad-hoc scripting rather than the real `main()` entry
    point) cannot be trusted without further investigation. I am reporting the *structural* gap (the
    threshold's blind spot) as verified, but explicitly NOT reporting a trustworthy count of how many
    blocks are exposed to it.
  - Fix suggestion (for the structural gap, independent of the non-determinism bug above): compute a
    local tangent bearing near each sign's actual `distance_from_intersection` position (using the
    nearest polyline segment) rather than one block-wide bearing, for blocks whose straight/arc ratio
    falls below some threshold — or explicitly add curvature to the confidence check.
  - Owner: `@backend-data`. Recommend a **separate, dedicated investigation session** for the
    non-determinism bug given its blast-radius is currently unknown and it affects code this PR does not
    touch — see also Finding #5, which shares the same root functions.

- **#5: `getOnewayFields()` relies on the exact same wrong assumption this PR's own investigation found
  and fixed for `arrow_direction` (`line[0]→line[last] = ptFrom→ptTo`) — but the PR does not fix or even
  flag it for this second consumer, and the real blast radius is far larger than "one verified block."**
  - Where: `build/preprocess.js`, `getOnewayFields()` (~line 468-470): `"If legal travel goes in the same
    direction as seg (line[0]→line[last] = ptFrom→ptTo)..."` — this comment states the assumption
    explicitly, and the function derives `oneway_toward` (`'from'`/`'to'`) from it.
  - What: this PR's commit message and PR body describe the `line`-reversal characteristic as verified
    on "at least one verified real block (Pike St, Henry St → East Broadway)" — phrasing that reads as a
    rare exception. I measured it directly: **1,731 of 7,488 (23.1%) unique Manhattan blockfaces have
    `line` oriented opposite to the block's own `from_street→to_street` direction** (dot product of line
    direction vs. `fromToBearing` ≤ −0.3, and empirically almost all of these are exactly −1.000, i.e.
    fully reversed, not partial). `getOnewayFields()` was never touched by this PR (correctly — it's out
    of scope), but it inherits the identical wrong assumption for a different field, on a population this
    PR's own session discovered and measured but didn't disclose for that consumer. If `oneway_toward` is
    surfaced anywhere user-facing (one-way arrows, drive-mode wrong-way warnings), it is plausibly wrong
    for a real fraction of Manhattan blocks today, independent of anything in this PR.
  - Impact: not a regression from this PR (pre-existing, orthogonal function, unmodified). But it is a
    finding this PR's own session was uniquely positioned to surface loudly (they found and fixed the
    exact same bug for a sibling consumer) and didn't.
  - Fix suggestion: log as a new, named open-item (`docs/open-items.md`) for a dedicated
    `@backend-data` follow-up — likely a one-line fix (have `getOnewayFields()` also read
    `blockGeo.fromToBearing` the way `getBlockBearingVector()` now does, instead of `line[0]/line[last]`).
  - Owner: `@backend-data` (logging this loudly is the ask before merge; the actual oneway fix can be a
    fast follow, does not need to block this PR).

### 🟢 Minor / nit

- **#6:** The PR body's flip-rate framing ("70.3% flip rate — higher than expected... I'd recommend
  Kevin or QA spot-check a handful more physical signs before trusting this at full scale") is honest and
  well-calibrated — this review did exactly that (5 independent hand-verifications, 0 errors), which is
  worth recording as confirmation the self-flagged caveat was answered, not just noted.
- **#7:** `docs/open-items.md` #26's updated row is accurate against my independent reproduction, but
  doesn't yet reflect Finding #1 (E4th's real-pipeline result) — will need a follow-up doc update once
  #1 is resolved either way.

### 💡 Out of scope (logged, not fixed)

- Regen sequencing vs #116 — correctly deferred to the orchestrator per the PR's own framing; not
  re-litigated here. #116 is still open (not merged) as of this review.
- Brooklyn expansion gate note (`docs/brooklyn-expansion-spec.md`) — correctly flags that #26 must land
  before any Brooklyn regen; accurate, not re-verified beyond reading (no Brooklyn data pulled in this
  pass).

## Danger-direction table (physically-anchored, ft of curb affected)

| Direction | Total ft | Share |
|---|---|---|
| **MORE permissive** (was forbidden-ish, now parkable-ish) | 391,729 ft | 55.9% |
| **LESS permissive** (was parkable, now forbidden) | 88,553 ft | 12.6% |
| **Lateral / coverage-gap** (one side has no governing zone at all) | 251,626 ft | 35.9%* |

*percentages sum >100% due to rounding/overlap in bucket definitions; treat as approximate shares, not
exact partition.

Top 5 flip transitions by ft affected (all independently reproduced from live data, not read from the PR
body): `NO_STANDING→METERED` 71,589 ft · `NONE→NO_STANDING` 51,748 ft · `NO_STANDING→NONE` 49,340 ft ·
`NO_STANDING→ASP_MON_THU` 43,766 ft · `NO_STANDING→ASP_TUE_FRI` 43,390 ft.

### Hand-verification results (5/5, 0 errors)

| Block | Transition | Verification |
|---|---|---|
| E 28th St (3rd→2nd Ave) [S], 466-488ft | NO_STANDING → METERED | NO_STANDING@466ft has `arrow_direction=West`; confidently resolves `coversBefore`, pairing cleanly with an `East`-arrow NO_STANDING@416ft to form exactly [416-466]. The [466-488] stretch is left to three "both"-direction signs (ASP_TUE_FRI/UNKNOWN/METERED, no `arrow_direction` at all) — correct. |
| Edgecombe Ave (W140th→W141st) [E], 40-115ft | NO_STANDING → ASP_TUE_FRI | **Two signs at the identical 40ft position, identical printed glyph `-->`, opposite `arrow_direction` (North vs South)** — decisive proof glyph alone can't disambiguate. North-arrow NO_PARKING resolves forward (confident, dot=0.87); South-arrow NO_STANDING resolves backward. Pre-fix, both were forced forward by the shared glyph, wrongly painting NO_STANDING over the ASP stretch and leaving a coverage gap at [0-40]. |
| W 4th St (W10th→Charles) [W], 45-115ft | TRUCK_LOADING → ASP_MON_THU | TRUCK_LOADING@45ft has `arrow_direction=South`; block bearing runs ~North (this is one of the West Village's diagonal streets). Confidently resolves backward, confining the loading-dock sign to [0-45] instead of bleeding into the ASP zone. |
| E 124th St (1st→2nd Ave) [S], 371-497ft | NO_STANDING → ASP_TUE_FRI | Again two signs at the identical 371ft position, identical glyph `-->`, opposite `arrow_direction` (East vs West) — same decisive pattern as Edgecombe Ave. |
| Adam Clayton Powell Jr Blvd (W133rd→W134th) [E], 85-120ft | NO_STANDING → METERED | A "BUS STOP...W/ SINGLE ARROW" sign has **no parseable glyph at all** (`sd.arrow = null`); pre-fix, null-glyph defaulted to "covers both directions," wrongly bleeding into the metered zone. `arrow_direction=South` confidently resolves it backward-only — correctly using the *only* directional signal available for a sign the glyph parser has zero information about. |

Sample size caveat: 5/5 is reassuring but far too small to bound a population error rate given
17,818 arrow_direction-present signs and 11,405 flips. Echoing the PR's own recommendation: before a
production regen, get Kevin to physically re-verify 2-3 more real streets (ideally including one of the
`NONE→NO_STANDING`/coverage-gap transitions, which I did not hand-verify against a photo).

## Smoke tests run

1. `node -c build/preprocess.js`, `node -c scripts/test-arrow-direction-fix.js` — syntax-clean.
2. Full live regen, base `c8e287a2`: 96,250 signs fetched (completeness gates passed both datasets),
   44,184 segments generated.
3. Full live regen, PR `e601aa41`, **identical cached sign pull** (byte-for-byte controlled A/B):
   44,636 segments. `PREPROCESS_OUT_DIR`/`PREPROCESS_SKIP_IOS_SYNC` guards confirmed working (scratch
   output only, iOS Resources sync skipped, real `tiles/` untouched).
4. Reproduced the PR's own arrow-stats almost exactly: classified 53,494 (PR: 53,491), present 17,818
   (33.3%, exact match), absent 35,676 (PR: 35,673), ambiguous 56 (exact match), agree 4,821 (PR: 4,820),
   flip 11,403 (PR: 11,405), narrowed 1,538 (PR: 1,537), blockfaces-with-flip 4,971 (PR: 4,970).
5. Reproduced the category-count deltas almost exactly: NO_STANDING −1,935 (PR: −1,933), ASP_MON_THU
   +561 (PR: +560), ASP_TUE_FRI +540 (PR: +539), METERED +729 (PR: +729, exact), UNKNOWN +458 (PR: +460).
6. Ran the fixed comparator (`compare-tilesets.js` from #116, `5dc4eefe`) against my controlled A/B tile
   dirs — surfaced Finding #3 (idx-based id artifact); confirmed it does not indicate real geometry drift
   by hand-tracing the specific reported "outlier" segments.
7. Built a physically-anchored (distance-range union, not tile-id-matched) diff harness calling the PR's
   own exported `createSubSegments()`/`getBlockPolyline()`/`resolveSignSpanDirection()` directly —
   produced the danger-direction table above and the 5 hand-verification cases.
8. Hand-reconstructed ground truth for 5 randomly-selected more-permissive transitions from raw
   `distance_from_intersection`/`arrow_direction`/`sign_description` fields (the same method Kevin used
   for the original E4th finding) — 0 errors found.
9. Ran `node scripts/test-arrow-direction-fix.js` on the real PR branch — 18/18 pass, reproduced exactly.
10. Cross-checked all three fixture files' sign records against a fresh live pull by `order_number` —
    every field value matches (arrow_direction, description, distance) for the rows the fixtures include;
    discovered the fixtures silently omit coordinate fields present in some but not all real records,
    which is how Finding #1 was found.
11. Verified fallback discipline: 0 rule-composition drift across 4,478 block faces with zero
    arrow_direction-carrying signs.
12. Verified `tiles/`, `ios/WePark/WePark/Resources/tiles/`, `supabase/` are byte-identical to base
    (`git diff c8e287a2 HEAD --name-only` → 0 files under any of those paths).
13. Measured the `line`-reversal characteristic directly (not trusting "at least one block"): 1,731/7,488
    (23.1%) of unique blockfaces reversed — see Finding #5.
14. Attempted to quantify curved/bent-block exposure to Finding #4's structural gap; discovered and
    reported the `getBlockPolyline` order-dependency bug that makes this quantification untrustworthy
    (see Finding #4).
15. Tested the TF2-13 cap's interaction with the fix directly against live data — found 2 real,
    live-confirmed instances of Finding #2's gating bug.
16. Not run: iOS build/sim smoke, live-UI screenshot gate. This PR touches no Swift code and no
    mount-chain file (`MapViewRepresentable.swift`, `ContentView.swift`, `DriveMode*.swift`,
    `.safeAreaInset`) — pure data/pipeline change, so the merge-blocking live-UI-smoke gate from the QA
    operating rules does not apply.

## What's working

- The core direction-resolution mechanism is genuinely sound — every hand-verified case checked out, and
  two of the five samples show the single most decisive kind of evidence possible short of a physical
  photo: two co-located signs with an identical printed glyph and opposite real-world compass readings,
  which only `arrow_direction` can disambiguate.
- The `fromToBearing` fix (deriving bearing from raw intersection points, not `line[0]/line[last]`) is
  correct and load-bearing at a scale far beyond what the PR discloses — good that it was built this way,
  because using `line`'s own endpoints would have silently inverted resolution for roughly a quarter of
  Manhattan.
- Every quantitative claim in the PR body that could be independently re-run was re-run and matched
  almost digit-for-digit against a fresh live pull a full day later — an unusually high bar, cleared.
- Fallback discipline (the majority case — 66.7% of signs lack `arrow_direction`) is provably
  byte-identical, not just claimed to be.
- Scope discipline is good: no iOS/Supabase/tiles touch, `PREPROCESS_OUT_DIR` guard genuinely prevents an
  accidental production write, docs updates are accurate.
- The PR's own self-flagged caveat (70.3% flip rate, "recommend a spot-check before trusting at scale")
  was the right instinct — and answered clean by this review.

## Recommended sequencing (concrete, for the orchestrator)

1. **Fix Finding #2** (TF2-13 cap gating) — small, isolated, `build/preprocess.js` only, no test-fixture
   changes needed beyond re-running `test-arrow-direction-fix.js`.
2. **Resolve Finding #1** — either (a) relax the `SP_BOUNDS` coordinate filter to recover
   coordinate-missing-but-otherwise-valid signs (benefits ~5-7% of all signs, not just E4th; larger,
   more careful change, may want its own QA pass), or (b) at minimum, correct the PR body/acceptance
   test framing to state the real, live-pipeline result for the E4th block and get Kevin's explicit
   sign-off on that corrected outcome before it ships. Do not let a regen go out the door still
   advertising "49-399ft ASP_MON_THU" for this block if a live regen won't actually produce that.
3. **Log Finding #5** (`getOnewayFields` inherited bug) as a new named item in `docs/open-items.md` so
   it isn't lost — does not need to be fixed before merging this PR, but should not evaporate either.
4. **Log Finding #4's non-determinism discovery** (`getBlockPolyline` order-dependent results) as a
   separate, dedicated investigation item — unrelated to arrow_direction, but concerning enough (and
   currently un-root-caused) that it deserves its own session before anyone else builds analysis tooling
   on top of `getBlockPolyline()` outside the real `main()` entry point.
5. **Re-run this PR's own acceptance test + blast-radius numbers once more, post-fix**, then merge.
6. **Regen sequencing vs #116**: unchanged from the PR's own framing — #116 is geometry-only and still
   open (not merged as of this review); the two PRs don't conflict at the code level, and a combined
   production regen should run once, after both land. This review does not change that recommendation.
