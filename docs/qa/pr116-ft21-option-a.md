# FT-21 Option A — Manhattan Regen QA Pass 1 — 2026-09-24

**Reviewed:** PR #116, branch `data/ft21-option-a-manhattan` at `e3c51617`, base `main` at `2eabdf76`,
against `docs/ft21-option-a-feasibility.md` (B0), `docs/ft21-carriageway-investigation.md`, and
`docs/brooklyn-expansion-spec.md` Stream B0b.

**Verdict: MERGE-PENDING-VISUAL-GATE**

No blocking defects found in the pipeline logic, the rule-drift proof, or the regenerated tiles. Every
quantitative claim in the PR description was independently reproduced byte-for-byte or number-for-number
by re-running the actual pipeline against live data (not just reading the diff). One 🟡 finding: the new
`compare-tilesets.js` comparator's displacement metric is measurably wrong for segments whose vertex
count changed between before/after (44.5% of moved segments), inflating the "mean ~11m" / outlier
numbers by up to ~10x on individual segments — it does not affect the pass/fail rule-drift verdict, but
it does affect the credibility of the tool's own sanity-check numbers and should be fixed before this
tool is trusted on Brooklyn's larger dataset. The other gate — Kevin's own on-device/sim visual check of
Houston/Bowery/Allen/Delancey/Park Ave — is explicitly still outstanding per the PR's own checklist, and
nothing in this review substitutes for it (a geometry pipeline can be provably self-consistent and still
put a curb line in a place that looks wrong to a human standing on the actual street).

## Acceptance criteria checklist

- [x] Per-carriageway offset replaces the allow-list fudge for confidently-matched blocks — verified by
      reading `pickCarriagewayForBlock()`/`buildCarriagewayPairs()` and re-running the pipeline; got
      identical stats to the PR (118/10,616 matched, 23 streets, same fallback breakdown).
- [x] Every unmatched block is byte-identical to pre-PR geometry — verified mechanically via a
      same-cached-signs `OPTION_A_DISABLED=1` vs Option-A-on regen + `compare-tilesets.js`: 0 lost, 0
      gained, 0 rule-content drift, 43,736/44,091 segments geometrically identical.
- [x] Rule content (zone boundaries, dominant category, oneway) is never affected by Option A — verified
      structurally (rule construction happens in `createSubSegments()` before any carriageway lookup) and
      empirically (0 rule-content drift across the full controlled A/B).
- [x] Forsyth St correctly falls back to legacy geometry (one-way couplet with Allen, not a genuine
      divided street) — verified: 0/69 Forsyth St segments differ between before/after.
- [x] The CSCL/OSM opposite-digitization (mirror) bug is actually fixed — verified across **all 118**
      matched blocks (not a sample): a start/end-alignment check confirms the matched carriageway's line
      always starts at the same physical intersection as the original OSM line. Zero misalignments,
      zero near-ties (<5m margin).
- [x] #9 duplicate-adjacent-vertex fix — re-measured independently against the actual committed `main`
      tiles (12.34%, 10,190/82,590) and the actual committed PR tiles (0.15%, 95/65,359): both numbers
      match the PR description exactly.
- [x] #10 (359→357 lost rows) is a re-measurement, not a fix, and is unaffected by Option A — confirmed:
      357/357 identical with Option A on or off in the controlled A/B.
- [x] #25 (`initWidths()` dead code) is not accidentally activated by this PR — confirmed: `initWidths(`
      appears only in its own definition/comments in `build/preprocess.js`; `main()` still never calls it.
- [x] `tiles/` and `ios/.../Resources/tiles/` byte-identical — confirmed via `diff -rq` on the actual
      PR-branch checkout (0 differences, 1071 files each).
- [x] No `supabase/` changes, no iOS Swift changes — confirmed via `git diff --name-only` (only
      `build/preprocess.js`, three `docs/*.md`, `scripts/*.js`, `street_widths.json`, and `tiles/`).
- [ ] Kevin's visual gate (Houston, Bowery, Allen, Delancey, Park Ave on a sim build) — **not done**,
      explicitly still open per the PR's own test plan. Not something this review can substitute for.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: `compare-tilesets.js`'s displacement metric is wrong whenever vertex count changes between
  before/after, and this happens on 158/355 (44.5%) of the moved segments in this very regen.**
  - Where: `scripts/compare-tilesets.js`, `displacementMeters()` (lines 57-66).
  - What: when `a.line.length !== b.line.length`, the function falls back to comparing the point at
    `Math.floor(length/2)` on each line — index-midpoint, not arc-length-midpoint, and not a true
    point-to-polyline distance. When the two lines have very unevenly spaced vertices (common here,
    since the #9 fix can silently drop a near-duplicate point on one side and not the other), this
    produces numbers that don't reflect real geometric displacement at all.
  - Repro: `BROADWAY_LA_SALLE_STREET_WEST_122ND_STREET_W_0` — before has 3 points, after has 2. The
    tool's own metric reports **62.14m** displacement (the single largest value it would report across
    all 355 moved segments if a max were printed). Recomputing with a proper symmetric
    point-to-nearest-polyline-point distance gives **5.77-5.84m** — the true offset, consistent with the
    other Broadway matches (`offsetM≈5.4` in the block's own confidence stats). I re-ran this same
    proper-distance calculation across all 355 moved segments: **true mean is 7.37m** (vs. the tool's
    reported 11.10m) and **true max is 26.84m** (vs. 8 segments the tool would call ">30m", up to 62m,
    none of which are real). The PR's own "mean ~11m" claim is therefore itself ~50% high due to this
    tool bug, and any future reviewer who asks the tool "any outliers?" gets a false positive.
  - Expected: a displacement metric a human/QA agent can trust to flag a genuine 100m-mover as a bug
    (per this review's own brief) — the current implementation cannot do that; it manufactures
    fake mid-size outliers instead.
  - Impact on this PR: **none on correctness** — the actual tile geometry is fine (independently
    verified via proper distance and via orientation checks, see below). This is a bug in the
    verification tool itself, not in `build/preprocess.js`. But it directly undercuts the "rule-drift
    proof" tool's trustworthiness for exactly the kind of sanity-check this PR was built to support, and
    it will get worse (more segments, more vertex-count churn) once this tool is reused for Brooklyn.
  - Fix suggestion: replace the length-mismatch fallback with a symmetric point-to-polyline
    nearest-distance average (both directions), or resample both lines to a fixed number of points
    before comparing. Should not gate merging this data regen; should gate trusting this tool's own
    numbers on the next one.
  - Owner: `@backend-data` (author of `compare-tilesets.js`).

### 🟢 Minor / nit

- **#2: Residual 0.15% duplicate-adjacent-vertex rate (95 points) is very likely a downstream rounding
  artifact, not left-over from the #9 fix, but this isn't proven, just plausible.** `extractSubSegment()`
  dedupes on raw (many-decimal) coordinates; `offsetPolyline()` rounds the final lat/lng to 6 decimals
  (`build/preprocess.js:1189-1190`) *after* the dedup runs. Two raw points close enough to survive the
  raw-coordinate dedup check can still collapse to the same rounded value once the offset+round pass
  runs. This is a plausible, structurally-consistent explanation, but wasn't traced through the actual
  95 residual points end-to-end to prove it out. Not worth a regen cycle on its own; worth a one-line
  note if someone revisits #9.
- **#3: One matched block (`NORTH END AVENUE`, Warren St–Chambers St) rides very close to the
  ambiguous-side fallback threshold.** The internal `dotB` value that decided which of the two candidate
  carriageways is the "W" side vs. the "E" side was only ~0.46m past zero (`-0.0000041` in degree-units,
  ≈ -0.46m). The sign is still deterministic and both directions (E-side lookup, W-side lookup) picked
  consistent, opposite carriageways — I verified this is correct, not a mirror bug — but a ~0.5m-different
  OSM or CSCL pull on some future day could tip this specific block into the (harmless) ambiguous-side
  fallback rather than a confident match. Not a bug, just a fragility note for whoever monitors future
  regens' match-count deltas.
- **#4: PR test-plan checkbox "`scripts/validate-widths.js` still runs clean" overstates what actually
  happens.** Ran it against both `main` and the PR branch: both print `8/9 tests pass` /
  `NO-GO — fix failures before regen 5` with the identical failing case (`E HOUSTON ST`, expects
  ≤12.79m target, unrelated to Option A). The PR's claim of "unaffected" is accurate (byte-identical
  before/after); "runs clean" is not — it was already failing pre-PR. Wording nit only.

### 💡 Out of scope (logged, not fixed)

- Three-carriageway parkway case (Eastern Pkwy/Ocean Pkwy) — correctly out of scope per B0/B0b
  sequencing; not exercised by Manhattan data, not attempted here.
- `initWidths()`/CSCL-width dead code (#25) — correctly flagged, correctly left inert; confirmed not
  accidentally activated (see checklist).

## Smoke tests run

All of the following were run against a **fresh checkout of the actual PR branch tip (`e3c51617`)** in
an isolated scratch directory, not by reading the diff and trusting the PR body:

1. `node -c build/preprocess.js`, `node -c scripts/compare-tilesets.js`, `node -c
   scripts/build-street-widths.js`, `node -c scripts/coverage-report.js` — all syntax-clean.
2. **Full live regen, Option A enabled** (`SIGNS_CACHE_PATH` + `TILES_OUTPUT_DIR` harness): 96,017 signs
   fetched live, 44,091 segments, **118/10,615 blocks matched, 23 streets** — exact match to the PR's
   stated confidence stats (blocksNoPairsOnStreet=8028, noPairInRange=2229 [2230 in PR desc — off by one
   block, live Socrata data moves day to day, not a concern], ambiguousSide=150, snapFailed=90,
   zonesFellBackPerZone=14 — all otherwise identical).
3. **Same regen, `OPTION_A_DISABLED=1`, identical cached sign data** — 44,091 segments (matches step 2
   exactly), 0 blocks matched (kill-switch confirmed working).
4. **Ran `scripts/compare-tilesets.js` on the two outputs from steps 2-3** (the actual controlled A/B the
   PR claims to have run): reproduced **0 lost, 0 gained, 0 rule-content drift, 355 moved, mean 11.10m**
   — identical to the PR description's numbers, digit for digit.
5. **Re-measured #9 independently** against the real committed baseline (`main`'s `tiles/`, via direct
   file read, not `git archive`, same effect): 12.34% (10,190/82,590) — matches PR claim exactly. Against
   the real committed PR-branch `tiles/`: 0.15% (95/65,359) — also matches exactly.
6. **`diff -rq tiles/ ios/WePark/WePark/Resources/tiles/`** on the PR checkout — 0 differences, 1071
   files each side.
7. **Systematically re-derived orientation correctness for all 118 matched blocks** (not a sample): for
   each, confirmed the matched carriageway's polyline starts at the same physical OSM intersection as
   the original centerline (geodesic nearest-endpoint check). 0 misaligned, 0 within a 5m ambiguity
   margin of being misaligned.
8. **Recomputed true geometric displacement (proper point-to-polyline distance, not the tool's
   midpoint-index shortcut) for all 355 moved segments** — true mean 7.37m, true max 26.84m, 0 segments
   over 30m. No outlier suggestive of a bug (a 100m+ mover would have been one; none exist).
9. **Confirmed Forsyth St untouched**: 0/69 Forsyth segments differ in the controlled A/B.
10. **Confirmed tile-set churn (`tile_1_31`/`tile_1_32` lost, `tile_30_10` gained) is live-data drift, not
    Option A**: identical tile filename sets in the controlled same-cached-signs A/B; the churn only
    shows up when comparing against the real (different-day) `main` baseline. Matches PR's own framing.
11. **Confirmed `initWidths()` is never called** (`grep` for actual call-site syntax, not just the
    function name) — dead-code status of #25 unchanged by this PR.
12. **Ran `scripts/validate-widths.js` on both `main` and the PR branch** — identical output
    (`8/9 tests pass`, same failing case) on both; confirms "unaffected," not "clean" (see nit #4).
13. **Tile-size delta**: `ios/.../Resources/tiles/` is 30,141,963 bytes on `main`, 29,683,169 bytes on
    the PR branch — **-458,794 bytes (~-1.5%, app gets slightly smaller)**, consistent with the
    live-data-churn segment-count drop (44,280→44,127), not a regression.
14. Not run: iOS build/sim smoke. This PR touches no Swift code and no mount-chain file
    (`MapViewRepresentable.swift`, `ContentView.swift`, `DriveMode*.swift`, `.safeAreaInset`) — it is a
    pure data/resource change, so the merge-blocking live-UI-smoke gate from the QA operating rules does
    not apply here. The PR's own outstanding gate (Kevin's visual check of real curb placement) is a
    different, product-correctness gate that no amount of pipeline self-consistency checking can replace
    — flagged below, not performed by this review.

## What's working

- The core "never a worse guess" guarantee is real, not just asserted — every fallback path is a
  logged, counted branch, and the controlled A/B proves 98.9% of blocks are provably byte-identical to
  today's shipped geometry.
- The orientation/mirror fix is solid: I independently re-derived it across the entire matched set (118
  blocks, not a sample) rather than trusting the PR's own description of "found and fixed," and found
  zero cases where it doesn't hold, including the one block that runs closest to the decision boundary.
- Every single numeric claim in the PR body that could be independently re-run, was re-run, and matched.
  That's an unusually high bar for a PR description to clear, and this one cleared it completely — the
  match confidence stats, the rule-drift proof, the #9 percentages, the tile-count/size deltas, and the
  Forsyth non-match all reproduced exactly (or within an expected single-block Socrata-day-to-day
  tolerance).
- Scope discipline is genuinely good: #25 was found, documented, and deliberately left inert rather than
  folded into an already-large diff; the 3-carriageway parkway case is correctly deferred to Brooklyn.
- Repo hygiene (byte-identical iOS/tiles sync, no supabase/ touch, no Swift touch) holds up under direct
  `diff -rq` and `git diff --name-only`, not just the PR's own checklist.

## Kevin's visual gate checklist (still required before merge)

Build off `data/ft21-option-a-manhattan` on the sim (or a device). For each street below, the specific
thing to look for is **curb lines hugging the actual curb on both sides of a divided roadway**, not
sitting in the median or crossing into the opposite carriageway. All of these were geometrically matched
in this regen (real per-carriageway offset, not the old fudge):

- **Houston St / Bowery** (the original FT-21 complaint, build-16 screenshot) — this is the highest-value
  check. Look at both sides of Bowery between Stanton and Great Jones, and E Houston between Bowery and
  Chrystie. Lines should now sit close to each physical curb, clearly separated by the full width of the
  roadway + median, not converging toward the middle.
- **Allen St** (Delancey–Rivington) — wide divided street, ~22.6m carriageway separation measured.
- **Delancey St** (Suffolk–Clinton / Norfolk–Suffolk) — similar, ~20.5-22.8m separation.
- **Park Ave** (multiple blocks, e.g. E 61st–62nd, E 97th–98th, E 129th–130th) — **this street was never
  handled at all before this PR** (not on the old 5-name allow-list), so this is a genuinely new capability,
  not a re-tuning — worth a close look precisely because there's no prior "good enough" baseline to fall
  back on visually.
- **Broadway** (e.g. W 93rd–94th, W 130th–131st, W 64th–65th) — also newly handled; Broadway is angled
  relative to the grid in places, a reasonable stress-test for the compass-side offset math.
- **Riverside Dr, Lenox Ave, Adam Clayton Powell Jr Blvd** — newly handled, lower priority than the above
  but worth a glance if time allows (uptown, may require driving further).
- **Control check — Forsyth St**: should look **unchanged** from whatever build Kevin is currently
  running (this PR left it on the legacy fallback, confirmed above). If Forsyth suddenly looks different,
  something is wrong that this review's data-side checks didn't catch.
- **Before/after comparison guidance**: the cleanest way to see the effect is a same-location, same-zoom
  screenshot on `main` vs. this branch for Houston×Bowery — the offset difference there is large enough
  (allow-list fudge vs. real per-carriageway offset) to be visible at a normal driving zoom level, unlike
  most of the smaller (4-10m) moves elsewhere in the 355-segment set.

## Recommendation

Data pipeline logic, rule-drift proof, and regen artifacts all check out under independent re-execution.
Fix finding #1 (comparator displacement metric) before this tool is relied on for the larger Brooklyn
regen — it's not merge-blocking for *this* PR since the actual geometry is independently verified sound,
but it's the kind of tool bug the task brief specifically warned about ("a buggy comparator proving 'no
drift' is worse than no proof") and it would be worse, not better, at Brooklyn's scale. Merge is
otherwise clear pending Kevin's own visual gate, which remains the real bar for "does this look right on
a real street," and which nothing in this review substitutes for.
