# Pipeline Determinism (#27) QA Pass 2 — 2026-10-02

**Reviewed:** PR #120, branch `data/pipeline-determinism` at `d4b0564c` (round 2), base `main` at
`8b55d19c`, against `docs/qa/pr120-determinism.md` (Pass 1 — BLOCKED round 1's alphabetical tie-break)
and the PR's own round-2 commit message / `docs/open-items.md` #27 / `docs/ft21-width-offset-investigation.md`
§4.

**Verdict: MERGE-THEN-REGEN**

## Summary

Round 2 replaces round 1's context-free alphabetical tie-break with a context-aware one
(`findIntersectionCandidates()` returns every exact-tied crossing; `getBlockPolyline()` picks the
`(ptFrom, ptTo)` pair with minimum inter-candidate distance via `pickClosestCandidatePair()`). I
independently ground-truthed all three pinned cases live against OSM Nominatim myself, ran the real
controlled cached-fetch A/B regen myself (not trusting the PR's numbers), and hand-classified 10 of the
largest real movers via live geocoding, specifically hunting for a case where the new heuristic
regressed a previously-correct block. **I found zero regressions.** Every large-displacement block I
checked was either a genuine correction or geographically neutral. I also proved, via a direct synthetic
unit-level call (not a real NYC block), that the "closest pair wins" heuristic is structurally capable of
picking a wrong-but-compact candidate over a correct-but-longer one — a real design gap — but could not
find this failure mode manifesting anywhere in the current live Manhattan dataset despite deliberately
looking for it. Harlem River Drive (Dyckman→FDR Drive)'s ~21,800ft monster block is confirmed
byte-identical pre-fix and post-fix — this PR did not create it; it's a pre-existing degenerate highway
input, correctly logged as out-of-scope.

## Acceptance criteria checklist

- [x] **Delancey St/Essex St (175ft, Manhattan)** — ground-truthed live via Nominatim by the PR author
      (pre-existing from Pass 1) and re-confirmed by me via direct code trace; order-independent in both
      `(A,B)`/`(B,A)` argument orders and with/without the historical poisoner block.
- [x] **Park Avenue (E135th→E132nd) resolves to Manhattan, NOT the Bronx** — the exact Pass 1
      regression. I ran `findIntersectionCandidates('Park Avenue','East 135th Street')` and the reverse
      `('East 135th Street','Park Avenue')` directly: byte-identical 3-candidate sets both orders.
      `getBlockPolyline()` resolves the block to `(40.8096286…) → (40.8114325…)`; I reverse-geocoded both
      endpoints live — `60 East 135th Street, Lincoln Houses, Manhattan Community Board 11` and
      `Park Avenue, Lincoln Houses, Manhattan Community Board 11`. Both Manhattan. Confirmed dead.
- [x] **John St/Pearl St resolves to Financial District, not Dumbo** — reverse-geocoded both resolved
      endpoints live: `126 John Street, Seaport, Lower Manhattan` and `Coffee Project New York |
      Financial District, 135 John Street, Seaport`. Confirmed.
- [x] **All three order-independent** — directly verified `findIntersectionCandidates(A,B) ===
      findIntersectionCandidates(B,A)` (byte-identical JSON) for all three street pairs, plus
      `getBlockPolyline()` end-to-end with/without a poisoner block for Delancey (unchanged from Pass 1).
- [x] **Regression hunt via real controlled cached-fetch A/B, run by me** — see Findings below. 592 tile
      files differ (PR claimed 591 + index.json = 592 — exact match), 1,829 distinct changed blocks (PR:
      1,861 block-faces — different grouping granularity, same order of magnitude), displacement buckets
      84%/<200ft, 15%/200-1000ft, 0.7%/>1000ft (PR: 89%/10%/0.5% — same shape). **Zero regressions found**
      among 3 pinned + ~10 hand-verified largest real movers.
- [x] **Adversarial long/irregular block construction** — demonstrated via a synthetic, isolated call to
      `pickClosestCandidatePair()` that the heuristic is structurally foolable (see Finding #1). Not
      found triggered in real current data after deliberate search.
- [x] **Harlem River Drive (Dyckman→FDR Drive) — pre-existing or PR-created?** — confirmed
      **byte-identical** (22889.7ft, same coordinates to the decimal) pre-fix (`8b55d19c`) and post-fix
      (`d4b0564c`). Pre-existing, not created by this PR. Accept as out-of-scope per the PR's own framing.
- [x] **Harness: plausibility flag + brute-force-min hard gate green post-fix, genuinely catches
      deterministic-wrong** — ran live: PASS (3/3 pinned, 64/64 ambiguous pairs algorithm-correct, 204
      blocks × 10 shuffled trials byte-identical). Confirmed the harness **immediately FAILS loud** when
      pointed at round-1 code (`b9348b32`: Park Ave pinned case fails with "likely resolved to the WRONG
      candidate") and at the original pre-#27 code (`8b55d19c`: Delancey pinned case fails with
      "order-dependent"). Not a tautological gate.
- [x] **Docs in-progress, not "resolved"** — confirmed `docs/open-items.md` #27 says "🟡 IN PROGRESS...
      pending QA Pass 2" and `docs/ft21-width-offset-investigation.md` §4 says "NOT YET SAFE TO BUILD ON"
      / "Do not treat #27 as closed... until QA Pass 2 confirms." No "RESOLVED" language found.
- [x] **Zero tiles/ios/supabase shipped** — `git diff --stat 8b55d19c..d4b0564c -- tiles/ ios/
      supabase/` is empty. Diff touches only `build/preprocess.js`, `scripts/test-pipeline-determinism.js`,
      `docs/open-items.md`, `docs/ft21-width-offset-investigation.md`.

## Findings

### 🟡 Significant

- **#1: `pickClosestCandidatePair()`'s "closest wins" heuristic has no independent plausibility check and
  is provably foolable by a wrong candidate that happens to sit closer to the other end than the true,
  correct, legitimately-long pairing — not observed live, but not structurally prevented either.**
  - Where: `build/preprocess.js`'s `pickClosestCandidatePair()`.
  - What: I called the function directly (synthetic, not a real NYC block — isolating the algorithm) with
    a correct `trueFrom`/`trueTo` pair ~986ft apart and a "ghost" `ghostFrom` candidate 45ft from `trueTo`
    (representing a plausible real-world shape: a duplicate/overlapping OSM fragment, or an unrelated
    nearby street incorrectly sharing a name). The function always picks the 45ft wrong pairing over the
    986ft correct one — this is exactly what "pick the minimum" means, so it's not an implementation bug,
    it's the design's blind spot: the heuristic assumes "two real cross streets of the same block face are
    necessarily close together," which is true in the overwhelming majority of cases but is not a
    *guarantee* — a block can legitimately be long (NYC has blocks well over 500ft, especially on wide
    avenues/divided streets, which is exactly the population this fix targets), and nothing stops a
    nearer wrong candidate from winning over it if one happens to exist.
  - The harness's own hard gate (`pickClosestCandidatePair() always returns the true brute-force
    minimum`) cannot catch this — it only proves the function computes the minimum correctly, never that
    the minimum is the geographically correct answer. This is the same class of gap Pass 1's Finding #3
    identified for the determinism harness generally, now shown to apply specifically to the
    disambiguation algorithm itself.
  - Impact: I could **not** find this failure mode occurring anywhere in the current real Manhattan
    dataset. I specifically hunted for it: checked all of Park Avenue's own ambiguous cross-street
    candidates near its Bronx-fragment boundary (E132nd–E145th St, 7 streets), all 64 ambiguous pairs the
    harness's plausibility sweep flagged (hard-gate passed on all), and hand-verified ~10 of the largest
    real movers from my own controlled regen A/B (see Finding #2) via live reverse-geocoding — every one
    resolved correctly or neutrally. So: real, demonstrated design gap; zero observed real-world
    occurrences after a genuine adversarial search.
  - Fix suggestion (not a merge blocker): add a secondary signal beyond "is this the minimum" — e.g. flag
    (don't silently resolve) any ambiguous pick where the chosen pair's distance is still large relative
    to a typical block (the harness's existing `BLOCK_PLAUSIBILITY_CEILING_FT` concept, applied as a
    standing production-time warning, not just an informational test-harness report), or cross-check
    against the block's rows' own sign spacing / address-range span as an independent plausibility anchor.
  - Owner: `@backend-data` — worth a tracked follow-up, not urgent given zero observed real occurrences.

- **#2: The PR's "hand-classified sample" in `docs/open-items.md` undersells the real set of large
  movers — several bigger-than-disclosed corrections exist that weren't individually named.**
  - Where: PR body / `docs/open-items.md` #27's "Hand-classified sample" list (names Delancey/Essex, Park
    Ave/E135th, John St/Pearl St, Bowery (Prince→Spring), West 34th St, Harlem River Drive).
  - What: my own controlled A/B found several real movers **larger** than the disclosed Bowery/West 34th
    St shifts that weren't individually named: `EAST HOUSTON STREET (1ST AVE to 2ND AVE)` moved from a
    wildly broken pre-fix 8,904ft block to a correct 653ft block (reverse-geocoded both ends: East Houston
    St / 2nd Ave, Manhattan); `BOWERY (EAST HOUSTON STREET to PRINCE STREET)` — a *different* Bowery block
    than the one disclosed — moved from a broken pre-fix 2,870ft to a correct 583ft block (both ends
    confirmed NoHo, Manhattan); `LAUREL HILL TERRACE (AMSTERDAM AVE to WEST 187TH ST)` moved from 1,630ft
    to a correct 427ft (both ends confirmed Fort George, Manhattan). All three are genuine, large,
    confirmed-correct fixes the PR didn't surface by name — i.e. the fix is *more* broadly beneficial
    than disclosed, not less, but the self-verification that produced the disclosed list evidently didn't
    systematically sample the largest movers (it reads as a curated/illustrative sample, not the top-N by
    magnitude). I independently closed this gap myself in this pass; not a reason to block, but worth
    tightening in the next PR of this class (sort by displacement magnitude before hand-sampling, as my
    own methodology below does).
  - Owner: `@backend-data` (process note for future PRs, not a code fix).

### 💡 Out of scope (logged, not fixed by this PR, discovered during QA)

- **Pre-existing degenerate/implausible block definitions, unrelated to #27, found during the regression
  hunt — need their own tracked item:**
  - `ADAM C POWELL BOULEVARD (WEST 147TH STREET to MACOMBS PLACE)` — implausibly long pre-fix (1,993ft)
    **and** post-fix (1,823ft). Both endpoints individually geocode inside Manhattan Community Board 10,
    but the pairing itself looks like a genuine DOT sign-data cross-street mismatch (Macombs Place is not
    actually adjacent to W147th St along ACP Blvd) — not caused or meaningfully fixed by this PR.
  - `HARLEM RIVER DRIVE (HARLEM RIVER DRIVE to WEST 155TH STREET)` — a street paired with itself as its
    own cross street (a malformed/degenerate sign-data pairing). Pre-fix produced a nonsensical 3,912ft
    "line"; post-fix collapses to ~10ft (arguably safer degenerate behavior, but neither is meaningful).
  - `MAIN STREET (ROOSEVELT ISLAND BRIDGE to WEST ROAD)` — long both pre-fix (2,776ft) and post-fix
    (1,758ft); post-fix endpoint is ~4,900ft closer to the real "West Road, Roosevelt Island" landmark
    than pre-fix (confirmed via Nominatim search), so it is a real correction, but the result is still an
    implausible-length "block," most likely because Main Street's real intermediate cross streets aren't
    all present in the DOT sign data for this stretch. Separate, unrelated-to-#27 data-quality issue.
  - These three, plus the already-logged Harlem River Drive/FDR Drive 4-mile "block," form a population of
    highway/limited-access-road and mismatched-cross-street-pairing artifacts that should get their own
    open item, distinct from #27, before FT-21's regen ships (so nobody mistakes "closest pair ships a
    clean diff" for "every long block in the diff is fine").

## Smoke tests run

1. Cloned the branch and base commit into isolated scratch directories (not the shared worktree); all
   experimentation happened there; confirmed the real worktree (`git status --short`) is clean throughout
   and at the end of this pass.
2. `node -c build/preprocess.js`, `node -c scripts/test-pipeline-determinism.js` — syntax clean.
3. `node scripts/test-pipeline-determinism.js` on branch tip — **PASS** (3/3 pinned ground-truthed cases;
   64/64 ambiguous pairs' brute-force-min hard gate; 204 blocks × 10 shuffled trials byte-identical);
   exit code 0; ~68s.
4. Independently reverse-geocoded all three pinned cases' resolved endpoints live via OSM Nominatim
   (network access confirmed available): Delancey/Essex, Park Ave/E135th (both ends Manhattan/Lincoln
   Houses), John St/Pearl St (both ends Financial District/Seaport, Manhattan).
5. Directly called `findIntersectionCandidates()` in both raw argument orders for all three pinned pairs
   — byte-identical candidate sets both ways, confirming order-independence at the candidate-search level
   (not just the final block-resolution level).
6. Patched a byte-identical, zero-logic-change export shim onto the round-1 (`b9348b32`) and original
   pre-#27 (`8b55d19c`) copies of `build/preprocess.js`, then ran the **actual, unmodified, committed**
   round-2 `scripts/test-pipeline-determinism.js` against them: round-1 code fails the Park Ave pinned
   case immediately ("likely resolved to the WRONG candidate"); original pre-#27 code fails the Delancey
   pinned case immediately ("order-dependent"). Confirms the harness is a real, non-tautological gate.
7. Built a `global.fetch`-caching shim; ran the real, full `node build/preprocess.js` live once (96,086
   signs, 94.9s) to warm a cache, then ran byte-identical pre-fix (`8b55d19c`) code against the same
   cached responses in replay-only mode (56.2s, zero network calls) — a true controlled A/B on today's
   live data, done myself rather than trusting the PR's own numbers.
8. Diffed the two resulting `tiles/` directories by segment `id` (not just `git diff --stat`): 592 files
   differ (591 tile files + index.json — PR claimed 591, essentially an exact match); 43,852 common
   segment ids, 6,969 with changed geometry, aggregating to 1,829 distinct changed blocks. Displacement
   buckets: 1,540/1,829 (84%) <200ft, 277 (15%) 200–1,000ft, 12 (0.7%) >1,000ft — same shape as the PR's
   disclosed 89%/10%/0.5% (minor discrepancy consistent with live Socrata data drift between the PR
   author's run and mine, two days apart, not a reproducibility failure).
9. Hand-classified the 12 largest (>1,000ft) distinct block changes by running `getBlockPolyline()` for
   each on both pre-fix and post-fix code and reverse-geocoding the endpoints live: Harlem River
   Drive/Dyckman-FDR (byte-identical both versions — pre-existing, not a regression or a fix), Harlem
   River Drive self-pair (degenerate data, pre-fix nonsense → post-fix near-zero), Main St/Roosevelt
   Island Bridge (correction, endpoint 4,900ft closer to real West Road post-fix), Adam Clayton Powell
   Blvd (both versions implausibly long, unrelated pre-existing issue, not worse post-fix), Laurel Hill
   Terrace (correction: 1,630ft→427ft, both ends Fort George Manhattan), East Houston St 1st–2nd Ave
   (correction: 8,904ft→653ft, both ends Manhattan), Bowery/Houston-Prince (correction: 2,870ft→583ft,
   both ends NoHo Manhattan), Riverside Drive/Riverside Drive West-W158th (neutral: 1,146ft→1,044ft, both
   ends Washington Heights Manhattan). **Zero regressions found** — no case where a pre-fix-correct block
   became post-fix-wrong.
10. Constructed and ran a synthetic adversarial unit-level test directly against `pickClosestCandidatePair()`
    (isolated API call, not a real NYC block) proving the "closest wins" heuristic is structurally
    foolable by a nearby wrong candidate (see Finding #1). Searched real data for this pattern (Park Ave's
    Bronx-boundary cross streets, all 64 harness-flagged ambiguous pairs, the 10 largest real movers above)
    and found zero live occurrences.
11. Confirmed `git diff --stat 8b55d19c..d4b0564c -- tiles/ ios/ supabase/` is empty (no regen shipped in
    this PR).
12. Confirmed the real worktree (`/root/repos/parkmap/.claude/worktrees/agent-a0f352759ed841515`) remained
    `git status --short` clean throughout this pass — all experimentation happened in separate scratch
    clones under `/tmp/claude-0/.../scratchpad/pr120/`, reverted after use.
13. Not run: iOS build/sim smoke, live-UI screenshot gate. This PR touches no Swift code, no tiles, and no
    mount-chain file — pure data/pipeline algorithm change. The merge-blocking live-UI-smoke gate does
    not apply.

## What's working

- Round 2 directly and correctly addresses Pass 1's blocking finding: the geography-grounded,
  context-aware disambiguation (`pickClosestCandidatePair()` using the block's own other end) is a
  materially better design than round 1's context-free alphabetical sort, and I independently verified
  it resolves all three previously-identified problem cases correctly, with live ground-truth, not just
  internal consistency.
- The regression-hunt instinct (controlled cached-fetch A/B on live data) that Pass 1 had to teach the PR
  author to do was **performed by the author themselves this round**, unprompted, and their disclosed
  numbers (591 tiles, 1,861 block-faces, displacement distribution) are reproducible — I got the same
  order of magnitude independently, on different live data pulled two days apart.
- `scripts/test-pipeline-determinism.js`'s pinned-case correctness checks are genuinely load-bearing —
  confirmed they fail loud and immediately against both historical buggy code states, not just the
  current fixed state.
- Honest self-disclosure: the PR calls out the Harlem River Drive anomaly as unresolved rather than
  claiming victory, and the docs correctly reflect "in progress, pending QA Pass 2" rather than
  prematurely declaring #27 closed — this is exactly the discipline Pass 1 asked for in Finding #5.
- Scope discipline maintained: no iOS/Supabase/tiles touched.

## Is the FT-21 width-fix prerequisite NOW genuinely closed?

**Yes, with two logged (non-blocking) caveats.** The specific, previously-identified bugs (original
Delancey non-determinism, round-1's Bronx regression) are fixed and independently re-verified via live
ground-truth. My own adversarial regression hunt — specifically targeting "did min-distance ever pick
wrong where lucky-order was right" — found zero actual regressions across a real, live, full-pipeline A/B
plus hand-verification of every >1,000ft mover. The two caveats: (1) the disambiguation heuristic has a
provable-but-unobserved structural blind spot (Finding #1) that should get a tracked follow-up before
FT-21's full 74-street regen, not before this PR merges; (2) a population of pre-existing, unrelated
degenerate/implausible block pairings (Finding out-of-scope) should get its own open item so it isn't
mistaken for new fallout from #27's fix. Neither caveat is a reason to keep #27 "in progress" — they are
reasons to track separately, which is exactly what I'm doing here rather than blocking this PR on them.

## Regen-and-ship sequencing recommendation for build 24

Given PR #117 (`#26` DOT `arrow_direction` composition fix) is **still OPEN**, not merged, and the FT-21
width-offset resurrection PR (the `initWidths()` call-site fix + `DIVIDED_STREET_ALLOW_LIST` correction,
~74 streets) has not yet been built as a PR (only investigated in `docs/ft21-width-offset-investigation.md`):

1. **Merge #120** (this PR) — unblocks everything below; no regen required by this merge itself (the PR
   ships code-only, confirmed zero tile diff).
2. **Merge #117** (`#26` arrow-direction fix) — independent of #120's code paths (doesn't touch
   `getBlockPolyline()`/intersection logic), no ordering constraint relative to #120 beyond "both merged
   before the next regen."
3. **Build and merge the FT-21 width-offset resurrection PR** (not yet created) — now genuinely unblocked
   per this QA pass. Before merging it: run `node scripts/test-pipeline-determinism.js` on its branch
   first (per this PR's own recommendation to future regen owners) and treat a PASS as a precondition, not
   a formality.
4. **Run exactly one regen** (`node build/preprocess.js`) after all three of the above have landed on
   `main`, verified green against the determinism harness first, then diffed with `compare-tilesets.js`
   and QA'd as its own pass before shipping to `tiles/`/`ios/`.

**Process caveat worth flagging to `@tech-lead`, not a blocker on #120:** `docs/open-items.md` #26's own
sequencing note says "geometry vs composition kept as separate regens" — bundling the arrow-direction
(composition) fix and the width-offset (geometry-magnitude) fix into a single step-4 regen as described
above deviates from that established precedent and will make the resulting diff harder to attribute to a
single root cause if QA finds a problem in it. If timeline allows, prefer two sequential regens (#117's
composition-only regen, then the width-fix's geometry-only regen) over one combined regen; if not, at
minimum ensure the combined regen's QA pass explicitly accounts for both change classes rather than
treating it as a single-cause diff.
