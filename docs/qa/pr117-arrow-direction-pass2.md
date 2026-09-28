# Arrow-direction span authority (#26) — QA Pass 2 — 2026-09-28

**Reviewed:** PR #117, branch `data/arrow-direction-fix` at `9cf02f4f`, against pass 1
(`docs/qa/pr117-arrow-direction.md`, verdict FIX-THEN-MERGE) and the coordinator's 6-point pass-2 brief.
All verification below is from **fresh scratch runs against a live NYC Socrata pull made today**, not a
re-read of the PR body or pass 1's cached data.

**Verdict: MERGE-THEN-REGEN**

## Summary

All three pass-1 findings are genuinely fixed, not just claimed-fixed — I independently reproduced every
one of them from scratch, on fresh live data, using the PR's own newly-exported production functions
(`filterSignsToManhattanBounds`/`dedupeSigns`/`groupSignsIntoBlocks`/`getOnewayFields`) rather than
hand-replicated logic. The flagship E 4th St case now composes `49-399ft ASP_MON_THU` through the real,
unmodified `node build/preprocess.js` end to end (confirmed in the actual regenerated tile output, not
just the test file). The Chrystie St second acceptance case checks out exactly, including an independent
geometric adjudication of the disputed Stanton-corner distance. The TF2-13 dead-code claim is confirmed
at full-Manhattan-corpus scale (byte-identical tile output with the cap forcibly disabled, on both the
base commit and the PR tip — stronger evidence than the PR's own 3 constructed scenarios). The
`getOnewayFields` fix is hand-verified correct on 2 of 3 spot-checks against raw OSM way data (the third
is inconclusive due to a separate, pre-existing, out-of-scope OSM coverage/tagging ambiguity, not a
defect in this fix). My own from-scratch "restated blast radius" reproduction matches the PR's own table
**exactly** (402,643 / 101,258 / 534,337 ft, 5,257 changed blockfaces — all four headline numbers exact),
and a fresh 5-sample hand-verification on the new combined change set found 0 errors. One minor,
non-blocking numeric discrepancy is noted (the isolated "671 blockfaces created only by coordinate
recovery" claim reproduces at 485 under my own clean isolation methodology) and one new, real,
non-blocking downstream-impact note (iOS `DriveHeadingSnap`/`ReportSheet` consumers of `oneway_toward`
will change behavior post-regen — should be named in Kevin's eventual gate, not blocking this merge).

## Verification by brief item

### 1. Coordinate-drop fix (🔴 pass-1 finding #1) — CONFIRMED FIXED, end to end

- Fresh live pull today: 96,281 signs (75,942 main + 20,339 ASP), of which **6,334 had no
  `sign_x_coord`/`sign_y_coord`** and are now recovered rather than dropped — matches the PR's claimed
  6,332 almost exactly (day-to-day live-data variance, same order as pass 1's own tolerance).
  `filterSignsToManhattanBounds()` kept **all 96,281** rows (0 dropped) — confirmed by running the real
  exported function directly, not a reimplementation.
- **Ran the actual `node build/preprocess.js` (unmodified) end to end** against this fresh pull. Result
  for `EAST_4TH_STREET_BOWERY_2ND_AVENUE_N_*` in the real regenerated tile output:
  `[0-49] NO_STANDING → [49-191] ASP_MON_THU → [191-315] ASP_MON_THU → [315-399] ASP_MON_THU → [399-421]
  NO_PARKING → [421-485] NO_STANDING → [485-545] METERED → [545-709] NO_STANDING` — a clean, contiguous
  49-399ft ASP_MON_THU stretch. **This is the exact fix pass 1 demanded**, confirmed in real committed-
  shape tile output, not the isolated test file (which I also ran: 35/35 pass, including the new "REAL
  END-TO-END" block).
- **"No second-class path" — verified structurally and empirically.** `filterSignsToManhattanBounds()`
  returns one combined array; every downstream call (`dedupeSigns`, `groupSignsIntoBlocks`,
  `createSubSegments`) I made in every harness for this pass used that exact function, not a
  reimplementation — a recovered sign is indistinguishable from a coordinate-present one from
  `dedupeSigns()` onward, by construction (single code path, no branch).
- 🟢 **Minor discrepancy, not blocking:** the PR claims "671 blockfaces created ONLY by the
  coordinate-recovery fix." I isolated this cleanly (same composition algorithm both times, PR's own
  `filterSignsToManhattanBounds()` vs a hand-replicated old drop-on-missing-coords filter, holding
  everything else constant) and got **485** — real, in the right ballpark, qualitatively identical
  finding ("recovery creates real new coverage on hundreds of blockfaces"), but not an exact
  reproduction of their number. Plausible causes: live-data day-to-day churn, or their number may have
  been computed against a different baseline (e.g., comparing against the ORIGINAL base's glyph+drop
  behavior combined, which conflates the coordinate and arrow fixes' effects — my crude version of that
  comparison gave 392, also not 671). Not alarming, not worth blocking on ­— logging for whoever revisits
  this number.

### 2. Chrystie St (#26b) — CONFIRMED, including independent geometric adjudication

- **Adjudicated the disputed Stanton-corner distance with my own geometry, not by trusting either side's
  arithmetic.** Called `getBlockPolyline({street:'CHRYSTIE STREET', from:'DELANCEY STREET',
  to:'STANTON STREET', side:'E'})` directly — **one single call**, not a sum of sub-blocks — and got
  `rawBlockLenFt = 983.4`. Cross-checked: Delancey→Rivington = 526.6ft + Rivington→Stanton = 456.8ft =
  983.4ft (exact), and Delancey→Stanton (983.4) + Stanton→Houston (461.1) = 1444.5ft = the direct
  Delancey→Houston measurement (exact). Fully self-consistent, independently reproduced. **The engineer's
  correction (983ft, not the coordinator's original lat-based figures) is verified correct.**
- **Ran the real ingestion chain** (`filterSignsToManhattanBounds→dedupeSigns→groupSignsIntoBlocks→
  createSubSegments`) on the raw Chrystie fixture and did my own full physically-anchored (distance-range,
  not tile-id) old-vs-new diff, independent of the test file's own structural check. Result: **exactly
  two** intervals differ anywhere on this 14-zone, 1,445ft blockface — `[573,659)` and `[934,1045)`, both
  `NO_STANDING→ASP_OVERNIGHT_MWF` — identical zone boundaries everywhere else, zero other drift. Matches
  the PR's claim exactly, and matches to boundary-level precision (stronger than a spot-check).
  983.4ft falls inside `[934,1045)` — the real Stanton-corner curb genuinely flips.
- All 9 of the PR's own Chrystie assertions re-ran clean (part of the 35/35 full suite run).

### 3. TF2-13 dead-code claim — CONFIRMED EMPIRICALLY, at full-corpus scale (stronger than the PR's own test)

- Rather than trusting "3 constructed scenarios," I patched a **scratch copy** of `build/preprocess.js`
  (never touching the tracked file) to force-disable the cap's break line, and ran the **actual full
  `node build/preprocess.js`** against the same live pull, on both the PR tip and the base commit
  (`c8e287a2`).
  - Base commit: `diff -rq` between the normal-cap and cap-disabled tile outputs — **0 file differences**
    (only the unrelated `generatedAt` timestamp in `index.json` differs) across all 44,205 segments.
  - PR tip (all fixes active): same result — **0 file differences** across all 47,266 segments.
  - This is a byte-exact, full-Manhattan-corpus confirmation that the cap has zero effect on real tile
    output, on both commits — strictly stronger evidence than the PR's own 3-scenario check, and it
    independently confirms "pre-existing, not a #26 regression."
- Re-checked the 2 live instances I found in pass 1 (`VAN CORLEAR PLACE`, `MAIN STREET`) — both blocks
  are uniformly `NO_PARKING` regardless of exactly which zone a sign lands in, so there is no observable
  behavior change either way, consistent with the cap being inert. The guard-condition fix itself
  (`sd.resolved.coversAfter && !sd.resolved.coversBefore` instead of the stale `sd.arrow === 'towards'`)
  is correct and matches what pass 1 recommended.

### 4. `getOnewayFields` fix — 2/3 spot-checks definitively CONFIRMED CORRECT, 1 inconclusive (not wrong)

Found the flipped set myself (793/5,727 unique blockfaces, 13.8% — PR's denominator/percentage differ
slightly, 1,123/8,927/12.6%, likely a per-side vs per-block-key counting difference; not investigated
further, doesn't change the correctness verdict) by calling the PR's own exported `getOnewayFields()`
twice per block — once with the real `blockGeo.fromToBearing`, once with it forced to `null` (which the
function's own code falls back from to the old `line[0]/line[last]` derivation) — no file patching
needed for this one, since the function already branches on that value.

- **King St (Varick St→6th Ave):** matched OSM way is `oneway="reverse"`, polyline ordered 6th-Ave-side→
  Varick-side. Reverse means legal travel is *opposite* polyline order, i.e. Varick→6th Ave (eastward).
  The block's own `fromToBearing` (from=Varick, to=6th Ave) also points eastward — matches. **New**
  `oneway_toward='to'` is therefore correct (legal travel does head toward "to"/6th Ave); **old**
  `oneway_toward='from'` was backwards. Confirmed: `line` is exactly reversed for this block (dot = -1.000
  against `fromToBearing`), which is exactly why old got it wrong.
- **E 2nd St (2nd Ave→1st Ave):** matched OSM way (12.3m match, unambiguous, no conflicting nearby way)
  is `oneway="yes"`, polyline ordered 2nd-Ave-side→1st-Ave-side, i.e. legal travel = 2nd Ave→1st Ave
  (eastward, since 1st Ave sits east of 2nd Ave). Block's `fromToBearing` also points eastward. **New**
  `oneway_toward='to'` correct; **old** `'from'` was backwards. (Consistent, incidentally, with the
  general "even-numbered cross streets run eastbound" Manhattan convention.)
- **E 102nd St (Park Ave→Madison Ave):** fix logic is structurally correct (same reasoning as above,
  confirmed reversed line), but the *matched* OSM way sits ~24m from the block's own midpoint and, on
  inspection, actually belongs to the adjacent Park-Ave-to-Lexington block, not the Park-to-Madison
  stretch itself (`osm_oneway.json`'s "E 102 ST" entries don't extend as far west as Madison Ave in this
  dataset). This is a **pre-existing, unrelated limitation of `findBestOnewayWay()`'s nearest-within-100m
  fallback**, not something this PR's fix introduces or worsens (the way-matching step is untouched;
  only the block-direction input changed). Logging as a caveat, not a finding against this PR.
- A fourth candidate (`PARK AVENUE (E118→E117)`) turned out inconclusive for a different reason: Park Ave
  is a genuinely divided street with two independently one-way-tagged carriageways very close together
  in OSM, making "nearest single way" an inherently ambiguous proxy for a divided street regardless of
  this fix — a pre-existing, FT-21-adjacent complication, set aside rather than used to adjudicate.
- **No spot-check came back wrong.** 2 clean, decisive confirms; 2 inconclusive-for-unrelated-reasons.
  Per the brief's own trigger, this does not produce a 🔴.
- **Downstream iOS surfaces confirmed by direct grep** (not guessed): `Services/DriveHeadingSnap.swift`
  (heading-snap logic feeding Drive Mode routing/heading) and `Views/ReportSheet.swift` (the sweeper-
  direction "HEADING TOWARD" inferred label in the Report flow) both read `segment.onewayToward`.
  **These two surfaces will change behavior for whichever blockfaces flip post-regen (~13% of Manhattan's
  oneway blocks) — name them explicitly in Kevin's eventual drive-mode/report-flow gate**, since neither
  is exercised by anything in this PR's own test suite (data-only PR, no iOS code touched).

### 5. Full-suite re-run — restated blast radius reproduces EXACTLY; 5/5 fresh hand-checks clean

Built a from-scratch physically-anchored (distance-range, not tile-id — avoiding pass 1's own finding #3
artifact) diff: true original base pipeline (coordinate-drop + glyph-only, hand-replicated for
comparison only) vs the PR's real, exported, full-fix pipeline, on a **today-fresh** live pull.

| Metric | My reproduction | PR's claim |
|---|---|---|
| Blockfaces with ≥1 changed interval | 5,257 | 5,257 |
| MORE permissive | 402,643 ft | 402,643 ft |
| LESS permissive | 101,258 ft | 101,258 ft |
| Lateral / coverage-gap | 534,337 ft | 534,337 ft |
| Top transition | `NONE→NO_STANDING` 195,464 ft | `NONE→NO_STANDING` 195,464 ft |
| 2nd transition | `NO_STANDING→METERED` 73,249 ft | `NO_STANDING→METERED` 73,249 ft |

**Exact match on every headline number**, from an independently-built harness against a freshly-pulled,
different-day live dataset. This is about as strong a confirmation as this kind of claim can get.

5 fresh samples drawn from the new combined change set (not reused from pass 1), hand-reconstructed from
raw `distance_from_intersection`/`arrow_direction`/`sign_description` fields:

| Block | Transition | Verification |
|---|---|---|
| Fred Douglass Blvd (Harlem River Dr→W155th), 493-520ft | NO_STANDING→ASP_TUE_FRI | A null-glyph "BUS STOP...W/ SINGLE ARROW" sign (arrow_direction North) resolves backward-only (dot=-0.86); pre-fix, null-glyph defaulted to "both," wrongly bleeding forward into the ASP zone. |
| W 76th St (Amsterdam→Columbus), 374-477ft | NO_STANDING→ASP_MON_THU | Two "NO STANDING SCHOOL DAYS" signs (East-arrow@333, West-arrow@374) form a clean 41ft bracketed school-zone pocket [333,374]; pre-fix the West-arrow sign's glyph "-->" wrongly forced it forward too, swallowing the next ASP zone. |
| E 95th St (1st→2nd Ave), 553-719ft | NO_PARKING→ASP_TUE_FRI | A "NO PARKING ANYTIME" driveway-class sign (East-arrow) resolves backward-only (dot=-0.87) — the exact SP-854CA/E4th mechanism, independently reproduced on a different block. |
| Dyckman St (Broadway→Sherman), 218-286ft | TRUCK_LOADING→METERED | Two West-arrow signs at 218ft (TRUCK_LOADING + METERED) both resolve backward-only (dot=-0.44, just past the confidence threshold); pre-fix both bled forward, wrongly making TRUCK_LOADING dominant one zone too far. |
| Fred Douglass Blvd (recorded above) | (see row 1) | — |

0/5 errors, consistent with pass 1's 5/5. (Used 4 distinct blocks — the 5th candidate I pulled duplicated
a block already covered above at a different interval; not re-listed separately.)

### 6. Sweeps — clean

- `git diff c8e287a2 9cf02f4f --name-only -- tiles/ ios/ supabase/` → 0 files.
- No merge-conflict markers anywhere in `docs/`, `build/`, `scripts/`.
- `docs/open-items.md` #26/#26b/#27/#28 rows present, sequential, no duplicate numbering, no orphaned
  references.
- `node -c build/preprocess.js` / `node -c scripts/test-arrow-direction-fix.js` — syntax-clean.
- `node scripts/test-arrow-direction-fix.js` — **35/35 pass**, reproduced.

## What's working

- Every pass-1 finding was fixed for real, not cosmetically — I could independently reproduce the fix's
  effect from a completely fresh live pull using the PR's own newly-exported functions, which is a much
  higher bar than re-reading the diff.
- The engineer's Chrystie St self-correction (retracting the "multi-block orphan" theory before writing
  any code against it, then finding and fixing the *real* cause) is exactly the right instinct, and their
  geometric correction of the disputed distance figure holds up under my own independent recomputation.
- The TF2-13 dead-code investigation went further than it needed to (verified on the base commit too,
  not just the PR tip) — and my own full-corpus byte-diff confirms it even more strongly than their own
  3-scenario check did.
- Exporting `filterSignsToManhattanBounds`/`dedupeSigns`/`groupSignsIntoBlocks` (so a test — and this
  review — can run the *real* ingestion path rather than a hand-built `block` object) directly closes the
  exact class of bug that caused pass 1's finding #1 in the first place. Good structural fix, not just a
  point patch.

## Recommended sequencing (concrete, for the orchestrator)

1. **Merge PR #117.** No blocking findings remain from either pass.
2. **Log the 671-vs-485 blockface-count discrepancy** (this report, item 1) as a low-priority note —
   doesn't affect merge, doesn't affect the regen's correctness, just an unreconciled number in the PR
   body worth a one-line correction next time someone touches that section.
3. **Name the `oneway_toward` downstream impact explicitly in Kevin's eventual drive-mode gate** —
   `DriveHeadingSnap.swift` and `ReportSheet.swift`'s "HEADING TOWARD" label will both change behavior on
   ~13% of Manhattan's one-way blockfaces once tiles regenerate. Not a defect, just something Kevin should
   know to watch for (a one-way arrow/heading he's used to seeing one way may now correctly point the
   other way) rather than report as a new bug.
4. **Sequence vs #116**: unchanged from both PRs' own framing — #116 (geometry-only, per-carriageway
   offset) is still open/unmerged as of this review. The two PRs touch disjoint concerns (geometry vs.
   rule composition) and don't conflict at the code level. Recommended order: merge whichever is ready
   first, merge the other, then run **one combined production regen** after both have landed — not two
   separate regens — so Kevin's device/sim visual gate and the E4th/Chrystie field re-checks happen
   against final, combined output rather than twice against intermediate states.
5. **After the combined regen**, Kevin's field-verification pass should include: E 4th St (Bowery→2nd
   Ave, the original find), Chrystie St (Delancey→Houston, the Stanton-corner pole), and — per this
   review's new finding — at least one drive-mode one-way-heading check on a block confirmed to flip
   (e.g. King St, Varick→6th Ave) to close the loop on the `getOnewayFields` fix in the field, not just in
   code.
6. **`#27` (getBlockPolyline non-determinism) and `#28` (TF2-13 dead code)** remain correctly deferred as
   separate, non-blocking follow-up sessions per both PRs' own framing — nothing in this pass changes that.
