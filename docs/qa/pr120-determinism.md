# Pipeline Determinism (#27) QA Pass 1 — 2026-10-01

**Reviewed:** PR #120, branch `data/pipeline-determinism` at `b9348b32`, base `main` at `8b55d19c`,
against `docs/qa/pr117-arrow-direction.md` (where #27 was discovered), `docs/ft21-width-offset-investigation.md`
§4 (the prerequisite this PR claims to close), and the PR's own body/commit-message claims.

**Verdict: 🔴 BLOCK**

**Is the width-fix (FT-21) prerequisite genuinely closed? No.** The harness proves `findIntersection()`
is now *order-independent*. It does not prove — and I independently disproved — that order-independence
means *correct*. I found a concrete, real Manhattan block (Park Avenue, East 135th St to East 132nd St,
East Harlem/Lincoln Houses) where the new canonical tie-break deterministically resolves to the **Major
Deegan Expressway in the Bronx**, a wrong answer the pre-fix code could at least sometimes get right.
Shipping FT-21's 74-street regen on top of this fix, believing #27 is "closed," risks silently baking
wrong, cross-borough geometry into production with no tooling that would catch it (determinism ≠
correctness, and the PR's own "ground truth" check — which should have caught this class of problem —
is itself demonstrably unsound; see Finding #2).

## Summary

The core mechanism (canonicalize `chains1`/`chains2` to the same sorted order the cache key already
uses) is real, well-tested for the one case it targets, and I reproduced every specific number in the PR
body almost exactly (175.26ft pinned isolated value, 3153.62ft poisoned value, 4/10 fuzz-trial failures
pre-fix, 10/10 passes post-fix). The determinism harness (`scripts/test-pipeline-determinism.js`) is a
genuinely useful, well-built regression gate and should be kept. But the PR's framing — "same-inputs-
same-output only," "no other block changes," "ground truth: currently-committed tiles already contain
the correct short Delancey geometry" — does not survive independent verification. I found: (1) the
canonical (alphabetical-sort) tie-break has no geographic correctness guarantee and I produced a concrete
counterexample where it resolves a real Manhattan block to a different borough; (2) the PR's own
flagship "ground truth" comparison is wrong — the currently-shipped Delancey/Ludlow/Essex tile is
independently verifiable as geographically incorrect today, for reasons unrelated to and not fixed by
this PR, which the PR's verification method failed to catch; (3) a cheap (~3 minute) controlled
regen A/B — which the PR did not run despite having all the pieces to do so — shows **564 tile files**
differ between pre-fix and post-fix code on today's real, live sign data, not the "one confirmed real
block" the PR discloses.

## Methodology (what I actually ran, not just read)

1. Read `findIntersection()`'s diff and header comment; confirmed by direct code trace that the fix
   changes the *search* (`chains1 = OSM_STREETS[a]`, sorted) not just the cache key.
2. Built a byte-for-byte-identical controlled A/B of the **real, full `node build/preprocess.js`
   pipeline** (not just the isolated harness): wrote a `global.fetch`-caching preload shim, ran the real
   pipeline once on live Socrata data (96,260 signs, completeness gates passed) with the fix, then
   re-ran the **pre-fix** code (a byte-identical copy of `8b55d19c`'s `preprocess.js`, patched only to
   add the same export surface this PR adds, zero logic changes) against the **identical cached fetch
   responses** — a true, fast, offline-after-first-run A/B. Confirmed `tiles/` fully reverted
   (`git checkout -- tiles/ ios/ && git clean -fd`) after each run; no committed output was left dirty.
3. Independently reproduced `scripts/test-pipeline-determinism.js`'s own pinned and fuzz results against
   both a real post-fix run and a real pre-fix run (not trusting the PR's console-output screenshot).
4. For ground-truth validation (not just "does the number look plausible"), cross-referenced computed
   intersection coordinates against live OpenStreetMap Nominatim search/reverse-geocode results (subway
   stops, bus stops, building addresses, named highways) — network access confirmed available in this
   sandbox. This is how both the Delancey confirmation and the Park Avenue regression were nailed down:
   plausible-looking lat/lngs were checked against what is *actually* at that coordinate.
5. Manually enumerated every exact (`dist===0`) `lineIntersect()` crossing between relevant street-chain
   pairs directly from `osm_data.json` (not via `findIntersection()`) to trace *why* a given candidate
   wins, independent of trusting the pipeline's own self-report.
6. Replicated the PR's undisclosed "~46 candidate" synthetic blast-radius sweep with my own bbox-overlap
   script (different exact method, same order of magnitude: 71 divergent pairs out of 3,502 checked),
   then hand-classified 5 sampled pairs against real-world ground truth.

## Acceptance criteria checklist

- [x] **Mechanism — does canonicalizing make the *search* order-independent?** Yes, confirmed by code
      trace and by running `findIntersection(A,B)` vs `findIntersection(B,A)` directly post-fix: both
      return byte-identical results for every pair tested, including the adversarial Delancey/Essex and
      Park Avenue/East 135th pairs.
- [ ] **Is the winning candidate geometrically correct?** **FAILS in general.** Correct for the
      motivating Delancey/Essex case (independently confirmed via real-world landmarks). **Wrong** for
      Park Avenue/East 135th St (independently confirmed via reverse-geocode: resolves to the Major
      Deegan Expressway, Bronx). See Finding #1.
- [ ] **Reproduce the poisoning pre/post fix.** Reproduced exactly: pinned case 175.26ft (isolated) vs
      3153.62ft (after poisoner) pre-fix, byte-identical 175.26ft both ways post-fix. Fuzz: 4/10 trials
      fail pre-fix, 10/10 pass post-fix — matches the PR's own numbers almost exactly. **However**, see
      Finding #3: the harness's own candidate-pool construction has no plausibility/geography check, so
      it would not have caught the Park Avenue-style "deterministic but wrong" failure mode even running
      today — it only asserts *consistency*, never *correctness*.
- [ ] **Zero-committed-tile-diff claim.** `git diff --stat` is technically empty (true, no regen shipped
      in this PR) — but the PR's supporting claim ("currently-committed tiles already contain the
      correct short Delancey geometry... matches post-fix isolated output exactly") is **false**. See
      Finding #2.
- [x] **Tie-break semantics / "~46 candidates, mostly sampling artifacts."** Directionally reproduced
      (71 divergent pairs independently found via a similar sweep). Classification of 5 samples: 2 are
      genuine sampling artifacts as the PR describes (non-contiguous same-named street, highway ramp
      complex); 2 are **real** divided-boulevard multi-crossings (Allen St Mall, Park Ave South median),
      small-magnitude and likely benign but **not individually ground-truthed** the way the PR implies;
      1 is an ambiguous skewed-junction case. See Finding #4 — the "mostly artifacts" framing undersells
      a real minority, and per Finding #1, at least one member of this broader population class is
      confirmed actively harmful, not just unverified.
- [x] **Sweeps — no iOS/Supabase changes.** Confirmed: diff touches only `build/preprocess.js`,
      `scripts/test-pipeline-determinism.js`, `docs/open-items.md`, `docs/ft21-width-offset-investigation.md`.
- [ ] **Docs accuracy (#27 resolved annotation, width-memo §4 update).** The mechanism description in
      both docs is accurate and doesn't repeat the PR body's false "ground truth" claim verbatim — but
      both assert "✅ RESOLVED" / "prerequisite closed," which Finding #1 shows is not a safe conclusion
      for FT-21's purposes. See Finding #5.
- [x] **Harness wired to be cheaply runnable.** Yes — `node scripts/test-pipeline-determinism.js`
      (defaults, ~82s measured in this sandbox, vs the PR's claimed "~15-20s" — see Finding #6, minor).
      Documented a second, more powerful invocation below (full controlled-regen A/B) that the harness
      itself does not perform but that is what actually caught Findings #1–#3.

## Findings

### 🔴 Blocking

- **#1: The canonical (alphabetical-sort) tie-break has no geographic correctness guarantee — it
  "fixes" Delancey/Essex by alphabetical coincidence and breaks Park Avenue/East 135th St the same way.**
  - Where: `build/preprocess.js`'s `findIntersection()` — `const [a, b] = [street1, street2].sort();`.
  - What: Real Manhattan block `PARK AVENUE (EAST 135TH STREET to EAST 132ND STREET) [W]` (East Harlem,
    serves the Lincoln Houses). `osm_data.json`'s `'Park Avenue'` key has 17 disconnected chains spanning
    lat 40.745–40.87+ (Manhattan Park Ave plus what is very likely a Bronx continuation/fragment set —
    the Harlem River crossing area where Park Ave, E132nd–E135th St all continue into Mott Haven, Bronx,
    via the Park Ave/Metro-North viaduct). I traced the exact root cause the same way the PR traces
    Delancey/Essex:
    - `findIntersection('Park Avenue', 'East 135th Street')` (Park-primary — how the real block calls
      it) → `(40.81152, -73.93493)` → reverse-geocodes to **"60 East 135th Street, Lincoln Houses,
      Manhattan Community Board 11"** — correct.
    - `findIntersection('East 135th Street', 'Park Avenue')` (East135th-primary — how a hypothetical
      cross-street block would call it) → `(40.81162, -73.93116)` → reverse-geocodes to **"Major Deegan
      Expressway, The Bronx, Bronx County"** — wrong, ~450–1475ft away, a different borough, a different
      kind of road entirely (interstate highway, not a surface street).
    - Post-fix, the canonical sort of `('Park Avenue', 'East 135th Street')` is **`('East 135th Street',
      'Park Avenue')`** (E < P alphabetically) — i.e., post-fix *always* uses the **wrong** order for
      this pair, permanently locking in the Bronx answer for every future run. Pre-fix, whether this
      block got the right or wrong answer depended on whether some other, East-135th-primary block (a
      real possibility — East 135th St surely has its own real DOT blocks) reached the shared cache
      entry first; my single real-pipeline sample happened to get it right because no such poisoner ran
      first in that particular block-processing order.
    - Confirmed via a real, full-pipeline regen on live cached data: the pre-fix run placed this block's
      geometry correctly in Manhattan (two tile files, `tile_48_37.json`); the post-fix run placed part
      of it on a pier/greenway path along the Harlem River Drive in Manhattan and part of it at the
      Major Deegan Expressway in the Bronx, split across three different tile files
      (`tile_48_38.json`, `tile_48_39.json`, `tile_49_39.json`) that don't even exist in the pre-fix
      output.
  - Expected: a deterministic fix for #27 should be deterministic **and** correct, or at minimum should
    not make a previously-sometimes-correct block permanently wrong. The PR's own stated goal
    ("same-inputs-same-output only... does not change which candidate wins for the overwhelming majority
    of pairs that only have one real crossing") is true as far as it goes but silently assumes alphabetic
    order has no bearing on correctness for the *minority* of pairs with multiple exact candidates —
    which is false, as this counterexample shows.
  - Repro: on the PR branch, `node -e "const pp=require('./build/preprocess.js'); const osm=require('./osm_data.json'); pp.initStreets(osm); console.log(pp.findIntersection('Park Avenue','East 135th Street'));"`
    → `[40.81162, -73.93116]`. Reverse-geocode that point against OSM Nominatim (`https://nominatim.openstreetmap.org/reverse?lat=40.81162&lon=-73.93116`) to see "Major Deegan Expressway, The Bronx."
  - Impact: this is not a one-off — `osm_data.json` has **140 street names** whose chains span more than
    ~1.4 miles of latitude across more than 3 disconnected chains (John Street, Pine Street, Cedar
    Street, Spruce Street, South Street, Spring Street, Park Place, and more all show this pattern),
    strongly suggesting multi-borough/multi-neighborhood name collisions are widespread in the street
    geometry data, not a single Delancey-shaped fluke. The alphabetical tie-break interacts with this
    population in an uncontrolled way: it happened to *fix* a second real instance I found
    (`JOHN STREET (PEARL STREET to WATER STREET)`, which pre-fix could resolve to Dumbo, Brooklyn's
    identically-named streets instead of the real Financial District ones — confirmed via reverse-geocode
    both ways; post-fix correctly lands in Manhattan) purely because J < P alphabetically happens to put
    the correct street first for *that* pair. There is no reason to expect this coin flip to keep
    landing right across the full citywide street-name population FT-21's 74-street regen will exercise.
  - Fix suggestion: replace the alphabetical tie-break with something geographically grounded — e.g.,
    when `findIntersection()` finds multiple exact candidates, prefer the one closest to an
    already-resolved reference point for the same block (the block's *other* cross-street intersection,
    which `getBlockPolyline()` already computes), or add a hard sanity bound (reject candidates whose
    computed point falls outside a plausible radius of the signs' own lat/lng, which `main()` already
    has available), or at minimum detect and flag (not silently resolve) ties that span more than some
    threshold distance (the current code has no distance-magnitude signal at all for *why* two
    candidates tied — `pt.dist` is always 0 for both). Any of these needs real design work, not a
    one-line reorder.
  - Owner: `@backend-data`.

- **#2: The PR's own "ground truth" verification is unsound — its flagship claim about the currently-
  committed Delancey/Ludlow/Essex tile is independently falsifiable, and a controlled regen the PR did
  not run reveals the real blast radius is ~564 tile files, not one block.**
  - Where: PR body / commit message, the "Ground truth" and "Changed-blocks accounting" sections; test
    plan checkbox "Committed tile geometry for Delancey/Ludlow/Essex cross-checked against
    `tile_8_13.json` — matches post-fix isolated output exactly."
  - What: I pulled the actual committed `DELANCEY_STREET_LUDLOW_STREET_ESSEX_STREET_S` segments from
    `tiles/tile_8_13.json` at `b9348b32`: line endpoints `(40.71887, -73.989292)` →
    `(40.719078, -73.989958)`. Independently computed, via `findIntersection()` on the current, committed
    `osm_data.json`, the real Delancey×Essex crossing at `(40.71863, -73.98817)` and the real
    Delancey×Orchard crossing at `(40.71911, -73.98973)`. Distance from the committed tile's "Essex end"
    to the real Essex crossing: **520.7ft**. Distance from the same point to the real **Orchard**
    crossing: **64.1ft** — well within normal curb-offset/setback tolerance (max possible curb offset in
    this codebase is 14m/~46ft, per `CSCL_OFFSET_MAX_M`). In other words: **the tile currently shipping
    in production for "Delancey St (Ludlow to Essex)" is not anchored to Essex Street at all — it's
    anchored to the adjacent Ludlow–Orchard block instead**, confirmed byte-identical between the
    top-level `tiles/` and `ios/WePark/WePark/Resources/tiles/` (i.e. this *is* what ships in the app
    today). This is wrong, independent of and unrelated to #27.
  - I then ran the real, full `node build/preprocess.js` pipeline twice against byte-identical cached
    live sign data — once with pre-fix code, once with post-fix code. **Both produced identical,
    correctly Essex-anchored geometry** for this block (`[40.71863,-73.98848]...[40.718758,-73.988911]`,
    within normal setback tolerance of the real Essex and Ludlow crossings). This proves two things: (a)
    the currently-committed/shipped tile is simply **stale** relative to today's code and data, for a
    reason that has nothing to do with #27 (neither pre- nor post-fix code reproduces it); and (b) the
    PR's claim that its own isolated-function check "matches post-fix isolated output exactly" against
    the committed tile is **false** — they are off by 500+ feet and anchored to a different cross street.
    The PR's verification evidently compared "does a 2-sub-zone, ~100ft-each shape exist" rather than
    checking actual coordinates against real-world ground truth, which is exactly the kind of check this
    QA pass was asked to perform and which the PR's own author should have performed before writing
    "cross-checked... matches exactly."
  - I then ran the same controlled pre-fix/post-fix regen A/B across the **full tileset** (not just this
    one block): **564 of 1,066–1,069 tile files differ** between pre-fix and post-fix output on today's
    real, live data. Some of this is pre-existing live-sign-data churn unrelated to #27 (I did not
    separately isolate every file), but hand-sampling 6 of the changed blocks found at least 2 more real,
    concrete, non-trivial geometry changes directly attributable to the `findIntersection()` fix (John
    St/Pearl St/Water St — fix correct; Park Avenue/E135th — fix wrong, see Finding #1), discovered in
    about 10 minutes using a cheap, repeatable method (cached-fetch A/B regen) the PR did not use despite
    citing `compare-tilesets.js` by name and despite this exact verification being the single most
    important claim in the PR for justifying "safe to merge without further scrutiny."
  - Impact: anyone reading this PR and concluding "Delancey's committed geometry is fine, FT-21 can
    build directly on top of it" is working from a false premise on two independent axes: the specific
    committed tile is already wrong (pre-existing, not caused or fixed by #27), and the general claim
    that #27's fix has a small, well-understood blast radius is also not supported by the cheapest
    available check.
  - Fix suggestion: before this PR (or any future determinism-adjacent PR) claims "no other block
    changes" or "ground truth confirmed," run the controlled cached-fetch regen A/B described in
    "Smoke tests run" below and actually diff the resulting `tiles/` directories — it takes about 3
    minutes end-to-end with a warm cache and is far more convincing than isolated-function checks against
    a tileset nobody has verified is current. Separately, open a new tracked item for the pre-existing
    wrong Delancey/Ludlow/Essex committed tile (Finding out-of-scope below) — it needs a real regen
    regardless of #27's fate.
  - Owner: `@backend-data`.

### 🟡 Significant

- **#3: `scripts/test-pipeline-determinism.js` only proves consistency, never correctness — it is
  structurally incapable of catching a Park-Avenue-style "deterministic but wrong" regression.**
  - Where: `buildFuzzPool()`'s candidate validation (`if (findIntersection(s, from) && findIntersection(s, to))`) and `runFuzzTrials()`'s pass/fail criterion (byte-identical serialization across shuffled
    trials).
  - What: the harness's only bar is "does the same block produce the same output across shuffled
    processing orders." A tie-break that is 100% consistent but 100% wrong (exactly what Finding #1
    demonstrates for Park Avenue) would **pass** this harness every time, with no signal at all that
    anything is amiss. This isn't a bug in the harness's existing tests (which do what they say), but the
    PR leans on this harness's "PASS" as evidence of safety for FT-21, and that inference doesn't hold.
  - Fix suggestion: add a geographic plausibility assertion to the fuzz pool — e.g., reject or
    specially-flag any street pair where `findIntersection(A,B)` disagrees with `findIntersection(B,A)`
    by more than some threshold distance (say 100ft) when BOTH raw argument orders are tried, since that
    signals an unresolved ambiguity the canonicalization step is papering over rather than solving. This
    would have caught Park Avenue/East 135th immediately (it was flagged for both-exact-ties before I
    ever needed a live regen to find it).
  - Owner: `@backend-data`.

- **#4: The "~46 candidates, mostly sampling artifacts" framing undersells a real minority of candidates
  that reflect genuine divided-boulevard multi-crossings, not pure artifacts, and are unverified.**
  - Where: PR body, "Changed-blocks accounting" / "Synthetic blast-radius sweep" section (the sweep
    script itself isn't committed, so this couldn't be re-run verbatim; I replicated the spirit of it).
  - What: independently swept `osm_data.json` for bbox-overlapping street pairs with order-dependent
    exact-tie divergence (different exact method/parameters than the PR's undisclosed script, same order
    of magnitude: 71 pairs out of 3,502 checked vs the PR's "~46 of ~4,000"). Hand-classified 5 samples:
    `Waverly Place × Washington Square North` (938ft divergence) and `PABT Ramp × PABT Bus Ramp`
    (519ft) are genuine sampling artifacts as the PR describes (Waverly Place is a non-contiguous,
    two-part named street in Greenwich Village; PABT Ramp/Bus Ramp are highway infrastructure, not real
    curb/DOT block pairs). But `Allen Street × Hester Street` (56–150ft, Allen St Mall's divided median
    genuinely crosses Hester at two distinct real points) and `East 24th Street × Park Avenue South`
    (33ft, Park Ave South's median) are **real** multi-crossing situations caused by divided boulevards —
    a different root cause than Delancey's fragmented-chain self-overlap, not individually
    ground-truthed, and (per Finding #1) this broader population class is now confirmed to sometimes
    resolve wrong, not just "mostly artifacts, safe to defer."
  - Impact: small individual magnitude for the two real cases sampled (well within curb-offset
    tolerance), so likely low practical risk for *these two specific streets* — but the characterization
    gives false confidence about the population as a whole.
  - Owner: `@backend-data` — worth a follow-up census using the geography-aware tie-break from Finding
    #1's fix suggestion, not urgent on its own.

- **#5: `docs/open-items.md` #27 and `docs/ft21-width-offset-investigation.md` §4 mark the prerequisite
  "✅ RESOLVED" / "closed" — not supportable given Finding #1.**
  - Where: both docs' diffs in this PR.
  - What: the mechanism description in both docs is accurate on its own terms (doesn't repeat the PR
    body's false ground-truth claim verbatim), but both assert closure in a way that would let FT-21
    proceed treating #27 as a solved problem. It isn't, in the sense that matters for a 74-street regen:
    a geography-blind tie-break that's already confirmed to corrupt at least one real Manhattan block.
  - Fix suggestion: until Finding #1 is addressed, revert the "RESOLVED"/"closed" language to something
    like "partial fix landed — order-independence confirmed, but the tie-break's geographic correctness
    is NOT guaranteed and at least one real counterexample is known (Park Ave/E135th → Bronx); FT-21
    still blocked pending a geography-aware tie-break."
  - Owner: `@backend-data` / `@tech-lead`.

### 🟢 Minor / nit

- **#6:** The PR claims the harness "runs in ~15-20s with default args." Measured in this sandbox:
  ~82s. Likely hardware-dependent (not a correctness issue), but worth correcting the expectation in the
  PR body/header comment since "cheap enough to run on every regen and every QA pass" is still true at
  82s, just not at the claimed magnitude.

### 💡 Out of scope (logged, not fixed by this PR, discovered during QA)

- The currently-shipped `DELANCEY_STREET_LUDLOW_STREET_ESSEX_STREET` tile (Finding #2) is wrong today,
  independent of #27, and needs its own regen — this isn't this PR's bug to fix, but it needs a tracked
  item so it doesn't evaporate. Given Delancey is FT-21's single highest-priority street, this should be
  fixed in the same regen that eventually resolves Finding #1.
- The broader "140 streets with multi-borough/multi-neighborhood-scale disconnected OSM chains" data
  characteristic (Finding #1's root enabler) deserves its own investigation independent of #27 — it's
  the kind of thing that could also affect `closestPointOnStreet()`/width calculations elsewhere in the
  codebase (not verified either way in this pass).
- `DELANCEY STREET (FDR DRIVE to COLUMBIA STREET)` (a second, different Delancey block, near the FDR)
  and `MARGARET CORBIN PLAZA`/`MAIN STREET (EAST ROAD to ROOSEVELT ISLAND BRIDGE)` also appeared in the
  564-file pre/post-fix diff and were not individually ground-truthed in this pass (time-boxed) —
  flagging as unverified rather than asserting either direction.

## Smoke tests run

1. `node -c build/preprocess.js`, `node -c scripts/test-pipeline-determinism.js` — syntax clean.
2. `node scripts/test-pipeline-determinism.js` on the real PR branch: **PASS** — pinned 175.26ft
   identical both ways; 202 blocks × 10 shuffled trials, byte-identical (~82s).
3. Built a patched pre-fix copy of `build/preprocess.js` (byte-identical to `8b55d19c`, only the export
   surface added, zero logic changes) and ran the same harness against it: pinned regression reproduced
   exactly (175.26ft isolated vs 3153.62ft after poisoner); fuzz: 4/10 trials failed (`DELANCEY STREET
   (LUDLOW STREET to ESSEX STREET)` / `ESSEX STREET (RIVINGTON STREET to DELANCEY STREET)` pairs) —
   matches the PR's own disclosed numbers almost exactly.
4. Manually enumerated every exact `lineIntersect()` crossing between Delancey/Essex and Delancey/Ludlow
   chain pairs directly from `osm_data.json`, independent of `findIntersection()`, to trace the exact
   mechanism by hand (which chain/segment indices produce the correct vs. corrupted candidate).
5. Cross-referenced computed Delancey/Essex/Ludlow intersection coordinates against live OSM Nominatim
   results (Essex St subway stop node, Duane Reade at 100 Delancey St, bus stop node) — all within normal
   setback tolerance of the fix's chosen candidate, confirming it's geometrically correct for this block.
6. Built a `global.fetch`-caching preload shim and ran the **real, full `node build/preprocess.js`**
   pipeline (not just the isolated harness) three times: once uncached (live Socrata pull, 96,260 signs,
   84s), once with the fix against the cached pull, once with pre-fix code against the identical cached
   pull (byte-for-byte controlled A/B, confirmed identical segment/sign counts).
7. Diffed the resulting `tiles/` directories: 564 of ~1,067 files differ between pre-fix and post-fix on
   today's real data. Hand-inspected 6 of the differing blocks; reverse-geocoded key coordinates via live
   Nominatim for 2 of them in detail (John St/Pearl St/Water St — fix correct, resolves a Dumbo-Brooklyn
   name collision; Park Avenue/East 135th St — fix wrong, resolves to the Bronx).
8. Pulled the committed `tiles/tile_8_13.json` at `b9348b32` and compared its `DELANCEY_STREET_LUDLOW_
   STREET_ESSEX_STREET` segment coordinates against independently-computed real intersection points —
   found a 500+ft, wrong-cross-street discrepancy (Finding #2). Confirmed the same wrong tile is
   byte-identical in `ios/WePark/WePark/Resources/tiles/tile_8_13.json` (i.e. ships in the app today).
9. Replicated a synthetic bbox-overlap blast-radius sweep independently (71 divergent pairs found, same
   order of magnitude as the PR's undisclosed "~46"); hand-classified 5 samples against real-world
   ground truth via Nominatim (2 confirmed artifacts, 2 confirmed real-but-small-magnitude divided-
   boulevard effects, 1 ambiguous).
10. Confirmed via `git diff --stat` that the PR touches no `ios/`/`supabase/` files.
11. Reverted every experimental regen output (`git checkout -- tiles/ ios/ && git clean -fd`) after each
    run; confirmed final worktree state is byte-identical to the PR tip (`git status` clean, `git diff
    HEAD` empty) before finishing.
12. Not run: iOS build/sim smoke, live-UI screenshot gate. This PR touches no Swift code and no
    mount-chain file — pure data/pipeline change, so the merge-blocking live-UI-smoke gate does not
    apply.

## Reusable methodology note (for future QA / the next regen owner)

The determinism harness (`node scripts/test-pipeline-determinism.js`, ~82s with defaults, `--pool=/
--trials=` for a heavier run) is good and cheap — keep running it. But it only proves consistency. To
actually validate correctness before trusting a regen, run a controlled real-pipeline A/B:

1. Write a `global.fetch` preload shim that caches responses to disk by URL hash on first call and
   replays on subsequent calls (no source file changes needed, `node --require <shim.js> build/preprocess.js`).
2. Run the real `node build/preprocess.js` once per code version you want to compare (base vs. fix,
   or fix vs. next-regen-candidate), against the identical cache.
3. `git diff --stat -- tiles/` (or diff two scratch copies) to see exactly which blocks changed, then
   spot-check a sample's actual lat/lng against live OSM Nominatim reverse-geocoding — not just "does the
   length look plausible."
4. Always `git checkout -- tiles/ ios/ && git clean -fd -- tiles/ ios/` afterward to leave the worktree
   clean.

This whole loop took about 10 minutes end-to-end in this pass (after the first live fetch warms the
cache) and is what actually found Findings #1 and #2 — isolated-function or synthetic-pool checks alone
would not have.

## What's working

- The core canonicalization mechanism does exactly what it claims for the search-order-independence
  question: `findIntersection(A,B)` and `findIntersection(B,A)` are now provably identical for every
  pair I tested, including both the motivating case and my adversarial counterexample.
- Every specific number in the PR body that I could independently reproduce (175.26ft, 3153.62ft,
  4/10 fuzz failures pre-fix, 10/10 post-fix) matched almost exactly — the PR is not fabricating its
  own test output.
- The determinism harness itself is well-built, fast enough to run on every regen, and genuinely catches
  the specific historical regression it targets (verified fails pre-fix, passes post-fix, independently).
- For the one case the PR deeply investigated (Delancey/Essex), the root-cause tracing is accurate and
  matches my own independent chain-index analysis exactly — the engineering instinct here is sound, the
  gap is in generalizing a single-case fix to a "prerequisite closed" claim without checking the
  population it will actually run against.
- Scope discipline is good: no iOS/Supabase touch, docs updated, no banned copy.
