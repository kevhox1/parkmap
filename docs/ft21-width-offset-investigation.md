# FT-21 — Real Half-Width Curb Offsets (open item #25 resurrection) — Investigation

**Status:** Investigation only, per instruction. No pipeline code touched, no regen run. Read + small
data samples only, all reproduced live against the actual `street_widths.json` / `build/preprocess.js`
on the `data/ft21-option-a-manhattan` (PR #116) branch, using `initWidths()`/`_perStreetOffset` via
`require()` (the module's own diagnostic export surface) rather than eyeballing the diff.

**Date:** 2026-09-29
**Author:** @backend-data
**Trigger:** Kevin's visual gate on PR #116 (Option A) failed — Houston/Bowery lines still float
mid-road after Option A's per-carriageway reference-line fix, because the offset *magnitude* applied
from that (now-correct) reference line is still the small fixed name-tier constant. Real fix = Option A
(done) + real half-width offsets from CSCL (this investigation).

---

## TL;DR verdict

**Feasible, but do not "just add `initWidths(OSM_WIDTHS)` to `main()`."** That naive resurrection would
ship a **second, previously-undiscovered bug**: a canonical-key mismatch inside `initWidths()` itself
that silently **regresses ~24 major streets** (14th/23rd/34th/42nd/57th/72nd/79th/86th/96th/110th/125th
St, Canal, Fulton, Chambers, Vesey, Rector, Liberty, West Broadway, Lafayette, ACP Jr Blvd, Frederick
Douglass Blvd, Riverside Dr, Central Park West) from today's correct flat 10m down to CSCL-derived
values as low as **6.00m** — the opposite of the goal. There's also a smaller, already-known staleness
bug (`DIVIDED_STREET_ALLOW_LIST` still contains Forsyth St, which Option A's own investigation already
proved is *not* genuinely divided, and is missing Park Ave, which the same investigation proved *is*).
Both are fixable, both are small, and once fixed the resurrection is safe and does exactly what's
needed: Houston/Allen/Forsyth/Delancey move +6.3 to +8.0m further off the shared centerline, Bowery
only +2.5m (it's already on the correct 10m tier — Bowery was never really the problem), and nothing
that already renders correctly regresses. **#27 (order-dependent `getBlockPolyline()` non-determinism)
must land first** — not because the code paths overlap (they don't), but because the one confirmed
non-deterministic block found so far is Delancey St, which is also the single largest-magnitude street
in this resurrection's own blast radius. Estimate: ~2.5-3 VPS sessions beyond #27 (which is already its
own queued item), then one Kevin visual-gate pass, same street tour as #116's own checklist.

---

## 1. Archaeology — why `initWidths()` was never called

**It was never called, not "disabled."** `git log -p -S initWidths -- build/preprocess.js` shows the
squash commit `a1761476` ("TF2-14 CSCL per-street curb widths — regen 5", 2026-06-15, squash of the
deleted `data/cscl-widths-wip` branch) is the *first* commit `initWidths()` ever appears in, and even at
that commit `main()` loads `street_widths.json` into the module-level `OSM_WIDTHS` variable directly
(`OSM_WIDTHS = JSON.parse(...)`) rather than calling `initWidths(JSON.parse(...))`. There is no later
commit that *removed* a call — `git log -p -S initWidths` across all history shows exactly one call
site ever, and it's in `scripts/validate-widths.js`, a standalone diagnostic, not `main()`. No smoking
gun for "it broke something and got pulled" — there's nothing to pull, it was orphaned from day one.

**Most likely mechanism:** the squashed WIP branch's own in-file comments describe a **mid-development
redesign** — `getCurbOffsetFromWidth()`'s header comment explicitly frames itself as a rewrite that
"replaces the per-segment divided-carriageway detection from regen-5" with a "PRE-COMPUTE one offset
per canonical street name in `initWidths()`" design (this comment already exists in the *very first*
commit that landed on `main`, meaning the squash flattened an already-redesigned WIP branch). The
redesign rewrote `getCurbOffsetFromWidth()` to require a precompute step but the `main()` loading block
(which predates the redesign, from the original regen-5 per-call design that didn't need one) was never
updated to call it. Classic refactor-orphaning: the call site and the function it calls diverged during
a squash, and nothing caught it because there was no automated gate.

**A genuine misattribution compounds this.** TF2 Round 3 (build 13, 2026-07-09) logged Kevin's
"mostly went over closer" as approval of TF2-14. But the `CURB_OFFSET_WIDE_METERS`/`CURB_OFFSET_DEFAULT_METERS`
constants (10m/6m) were set by an *earlier*, unrelated commit (`035c00ca`, "TF2-10 — width-aware curb
offset (avenues 10m, side streets 6m)") and have never been touched since — that fixed-tier bump alone
is almost certainly what Kevin was seeing improve, not the CSCL data, because the CSCL wiring was dead
the whole time. TF2-19 (a real, serious Socrata data-completeness bug, unrelated to curb offsets)
detonated immediately after and consumed the next several regens' worth of attention; by the time the
docs declared "TF2-14 accepted on-device" (commit `893cf51b`), nobody had re-verified the wiring.

**The one gate that would have caught this has been failing the whole time, unenforced.**
`scripts/validate-widths.js` — whose own header calls itself "TF2-14 regen-5 validation probe... Safe
for orchestrator to run regen 5" — is the *only* place `initWidths()` is ever called. It is not wired
into any build script, npm script, or CI check (confirmed via repo-wide grep) — it has only ever been
run manually. PR #116's QA (2026-09-24) ran it on both `main` and the PR branch and got **identical
"8/9 tests pass... NO-GO — fix failures before regen 5"** on both — it has been silently red since the
regen-5→regen-6 redesign changed the target calibration (the test file's hardcoded target for E Houston
is `[14,16]`m; the live redesigned algorithm produces `12.79`m) and nobody has revisited the test file's
targets since. This is strong corroborating evidence, not just a hypothesis: the one artifact that
should have forced someone to notice #25 has been broken and unconsulted for over three months.

**What the width path does when live (read from the code, not run in production anywhere):**
`initWidths(data)` computes one offset per canonical street name, once: collect all `stWidthFt` values
for that street's CSCL ways, take the median, then either (a) if the street is on the hardcoded
`DIVIDED_STREET_ALLOW_LIST` (6 streets today: E/W Houston, Bowery, Allen, Forsyth, Delancey) —
`offset = medianWidthM/2 + DIVIDED_MEDIAN_ALLOWANCE_M (7.0m)`, designed to reach from the *shared* OSM
centerline past the median to the far carriageway's outer curb — or (b) otherwise — `offset =
max(medianWidthM/2 × 0.88, nameTierFloor)`, clamped to `[4.0, 14.0]`m. `getCurbOffsetFromWidth()`
becomes a flat per-street map lookup at that point; every call today falls through the "not yet
computed" branch straight to `getStreetCurbOffset()` (pure name-tier), because the map is always empty.

---

## 2. Data reality — CSCL width for the flagship streets

CSCL (`inkn-q76z`) genuinely carries a usable per-way `streetwidth` field. Per NYC DCP metadata and
`scripts/build-street-widths.js`'s own header: **"the width, in feet, of the paved area of the
street"** — curb-to-curb of the addressed segment, not the full right-of-way (sidewalks excluded).
For a divided street, each carriageway is a *separate* CSCL row carrying house numbers for only one
side, and `streetwidth` on that row is that carriageway's own paved width, from median/separation edge
to its own outer curb — confirmed directly against live coordinates for East Houston St at Bowery in
`docs/ft21-carriageway-investigation.md` §1.2: two rows, `width=44ft` each, centerline-to-centerline
lateral separation **19.2m** (matches a real 6-lane-plus-median arterial, not digitization noise).

Sampled directly from `street_widths.json` on the PR #116 branch (2,938,990 bytes, 1,207 streets — this
branch's copy was refreshed by PR #116 itself to add `trafdir`/address-range/`physicalid` fields for
the carriageway-pairing heuristic; the underlying width *values* for these streets are unchanged from
`main`'s copy, cross-checked):

| Street | CSCL ways (n) | median width (ft) | **today's flat tier (m)** | **resurrected-as-designed offset (m)** | **delta** |
|---|---|---|---|---|---|
| E HOUSTON ST | 60 | 38 | 6 (default — no wide-pattern match) | 12.79 | **+6.79** |
| W HOUSTON ST | 29 | 36 | 6 | 12.49 | **+6.49** |
| BOWERY | 38 | 36 | 10 (already WIDE_NS_NAMES) | 12.49 | **+2.49** |
| ALLEN ST | 22 | 42 | 6 | 13.40 | **+7.40** |
| FORSYTH ST | 12 | 35 | 6 | 12.33 (⚠️ see below — wrong) | **+6.33 (wrong)** |
| DELANCEY ST | 48 | 54 | 6 | 14.00 (clamp ceiling) | **+8.00** |
| PARK AVE | 204 | 40 | 10 (WIDE_AVENUE_RE) | 10.00 (undivided treatment — see below) | +0.00 |
| 2 AVE | 142 | 60 | 10 | 10.00 | +0.00 |
| E 2 ST | 7 | 34 | 6 | 6.00 | +0.00 |
| Broadway / 5 Ave / 1 Ave / Lenox Ave / Riverside Dr / Mott / Prince / W 4 St | — | — | 6 or 10 | unchanged | +0.00 |

**Bowery was never really the problem.** It already sits on the `WIDE_NS_NAMES` 10m tier today, so
resurrection only adds 2.5m there — the flagship complaint (Houston, and to a lesser extent Allen/
Delancey/Forsyth) is dominated by streets that get the *wrong* 6m **default** tier today because their
NYC names ("EAST HOUSTON STREET", "ALLEN STREET") don't match any of `WIDE_AVENUE_RE`/`WIDE_NS_NAMES`/
`WIDE_CROSSTOWN_NAMES`. That's exactly why Kevin's visual gate flagged Houston, specifically, as the
worst offender — it's getting a side-street-class offset on an arterial.

**Forsyth St ground-truth check — the allow-list is stale.** Forsyth is on `DIVIDED_STREET_ALLOW_LIST`
today (inherited from the original TF2-10/TF2-14 design), but `docs/ft21-carriageway-investigation.md`
§1.3 already established, with live CSCL data, that Forsyth is a **one-way couplet paired with Allen
St** — a genuinely undivided single carriageway, not two carriageways of one divided street. If
resurrected as-is, Forsyth incorrectly gets the divided-median formula and jumps from 6m to 12.33m — a
second, avoidable, wrong movement on top of the first bug. Removing Forsyth from the allow-list and
re-running the formula confirms it: treated correctly as single-carriageway, Forsyth's resurrected
offset is **6.00m — unchanged from today**, because its median CSCL width (35ft) doesn't clear the 6m
tier floor even at the full single-carriageway fraction. **Park Ave is the mirror-image miss**: the
same investigation (§5) found Park Ave genuinely CSCL-divided (204 one-sided rows, real median low-40s
St–96th St) but it is *not* on today's allow-list, so it gets zero divided-street handling — flat 10m,
same as any ordinary avenue. Adding it and re-running: **13.10m** (vs. today's 10.00m, +3.10m) — a real,
currently-missed correction. **The allow-list needs an explicit audit pass (drop Forsyth, add Park Ave,
verify the rest of the investigation's other §5 candidates — Riverside Dr, Canal St, ACP Jr Blvd, Lenox
Ave, Madison St, St Nicholas Ave, Cooper Sq, Pike St) before resurrection, not after.**

---

## 3. Risk analysis — the headline finding: a second, undiscovered bug inside the dead code

**Full blast radius, computed against the actual algorithm exactly as written:** out of 1,207 streets
in `street_widths.json`, resurrecting `initWidths()` changes the offset for **74 streets (6.1%)** —
everyone else clamps straight back to today's name-tier floor via `Math.max(csclOffset, tierOffset)`,
byte-identical to today. That sounds reassuringly narrow. **It is misleading**, because the "today's
tier" baseline that `Math.max()` floors against inside `initWidths()` is itself computed wrong:

```js
// initWidths(), current code — two internal call sites (build/preprocess.js ~1857, ~1878):
_perStreetOffset[canonKey] = getStreetCurbOffset(canonKey);   // no-CSCL-data fallback
const tierOffset = getStreetCurbOffset(canonKey);             // single-carriageway floor
```

Both pass `canonKey` — the abbreviated form used as `street_widths.json`'s own keys (e.g. `"W 125 ST"`,
`"CANAL ST"`, `"ADAM CLAYTON POWELL JR BLVD"`) — into `getStreetCurbOffset()`. But `getStreetCurbOffset()`'s
wide-street classification checks `WIDE_NS_NAMES.has(upper)` and `WIDE_CROSSTOWN_NAMES.has(upper)`
against **full, un-abbreviated NYC names** (`"WEST 125TH STREET"`, `"CANAL STREET"`, `"ADAM CLAYTON
POWELL JR BOULEVARD"`). `Set.has()` requires an exact match, so **every wide crosstown/boulevard street
whose classification depends on Set membership silently fails to match**, and `getStreetCurbOffset()`
falls through to the 6m default. Avenue-class streets are accidentally *immune* to this, because
`WIDE_AVENUE_RE` (`/\bAVE(NUE)?\b/`) is a regex checked first and happens to match both the full and
abbreviated forms — pure luck of that one pattern being format-agnostic, not a designed protection.

**Live-tested against every member of `WIDE_CROSSTOWN_NAMES`/`WIDE_NS_NAMES`** (running each through the
same `canonicalStreetName()` normalizer `build-street-widths.js` uses to build its keys, then comparing
`getStreetCurbOffset(rawName)` — what genuinely ships today — against `_perStreetOffset[canonKey]` as
`initWidths()` would actually compute it): **24 of the 31 non-avenue wide streets checked would regress**
from today's correct 10m down to values as low as **6.00m**:

| Street (today's classification: WIDE_CROSSTOWN or full-name WIDE_NS) | True today (m) | Resurrected-as-coded (m) |
|---|---|---|
| E/W 14th, 23rd, 34th, 42nd, 57th, 72nd, 86th, 96th, 125th St | 10 | 6.71 – 8.58 |
| W 79th St, E 110th St | 10 | **6.00** |
| Canal St, Fulton, Chambers, Vesey, Rector, Liberty St | 10 | 6.00 – 8.05 |
| West Broadway, Lafayette St | 10 | 6.17 – 6.44 |
| ACP Jr Blvd | 10 | **6.00** |
| Frederick Douglass Blvd | 10 | 8.05 |
| Riverside Dr | 10 | **6.00** |
| Central Park West | 10 | 8.31 |

(Broadway, Bowery, St Nicholas Ave, Lenox Ave, Amsterdam Ave, Convent Ave, Ft Washington Ave, Audubon
Ave, Edgecombe Ave all land correctly at 10.00m — every one of the immune cases is either already an
exact-canonical-form match (`BROADWAY`, `BOWERY`) or protected by the `WIDE_AVENUE_RE` regex.)

**This means "naive resurrection" (add one `initWidths()` call, regen) is not safe — it would ship a
real, citywide regression on ~24 major streets, silently, alongside the intended Houston/Allen/Delancey
fix.** It is a second bug, independent of and previously unrelated to #25's "never called" status — it
only becomes observable once #25 is actually resurrected, which is exactly why nobody has found it: the
code that contains it has never executed in production. **Fix required before any resurrection:** make
`initWidths()`'s two internal tier-floor lookups canonical-key-aware — either normalize
`WIDE_CROSSTOWN_NAMES`/`WIDE_NS_NAMES` into a second, canonical-form set for this specific call site, or
thread the raw NYC name through `street_widths.json` (not currently carried) so the existing
`getStreetCurbOffset(streetName)` can be called with the form it actually expects. The first option is
smaller and doesn't require re-fetching/re-shaping `street_widths.json`.

**Once both bugs (canonKey mismatch + allow-list staleness) are fixed, the design is provably
monotonic-safe:** every non-degenerate case runs through `Math.max(csclOffset, correctTierOffset)`
(or, for the 6 genuinely-divided streets, `csclOffset + fixedAllowance` — always ≥ the tier floor by
construction, since `DIVIDED_MEDIAN_ALLOWANCE_M` (7m) alone already exceeds every tier floor). **No
street can end up with a smaller offset than it has today**, once the floor itself is computed
correctly — this is the same "never a worse guess" guarantee Option A already leaned on, just applied
to a different bug. Given that, a **hybrid scope (only the 6 divided streets) is not actually a safer
choice than full resurrection** — the existing single-carriageway formula already *is* the hybrid (a
tier-floored correction, not a replacement), and restricting it to 6 streets forfeits real, currently-
wrong offsets on the other 68 streets (the wide-crosstown/boulevard set above) for no safety benefit,
once the floor bug is fixed. Recommend **full resurrection**, gated on fixing both bugs first, not a
narrower scope.

**Interaction with Option A (PR #116) — no double-counting, verified by reading the actual matched-block
code path on the `data/ft21-option-a-manhattan` branch.** `pickCarriagewayForBlock()` computes its own
inline offset directly:

```js
const offsetM = matched.way.stWidthFt
  ? Math.min(Math.max((matched.way.stWidthFt * 0.3048 / 2) * CSCL_OFFSET_FRACTION, CSCL_OFFSET_MIN_M), CSCL_OFFSET_MAX_M)
  : CURB_OFFSET_DEFAULT_METERS;
```

This is the **single-carriageway** half-width formula, applied to the *matched carriageway's own*
`stWidthFt` — it never calls `getCurbOffsetFromWidth()`/`_perStreetOffset` at all, and is therefore
already width-aware today, completely independent of #25's dead-code status. For E Houston's sampled
44ft carriageway, this computes to **≈5.90m** — nearly identical to today's flat 6m default, which is
exactly why Kevin's visual gate still saw lines floating close to their old position even on the 118
blocks Option A *did* match: the reference line moved (correctly, to the carriageway's own centerline),
but the offset magnitude from that new line barely changed. Resurrecting #25 does **not** touch this
path — `main()`'s block-offset computation is
`carriagewayMatch ? carriagewayMatch.offsetM : getCurbOffsetFromWidth(...)`, so matched blocks are
structurally insulated from `getCurbOffsetFromWidth()`. #25 only affects (a) the ~98.9% of Manhattan
blocks Option A did *not* match (including nearly all of Houston/Bowery/Allen's actual block-face
length — only 118 blocks matched citywide) — for those, the shared OSM centerline is still the
reference line, and the `DIVIDED_MEDIAN_ALLOWANCE_M (7m)` term exists specifically to reach past the
median from that shared line, which is the correct, non-redundant use of it — and (b) Option A's own
"per-zone safety net" (`legacyCurbOffsetForBlock()`), which is *designed* to retry against the legacy
shared-centerline geometry when a matched block's specific zone fails, and correctly wants the legacy
(pre-Option-A) offset formula there. **CSCL width semantics resolve cleanly across both cases**: for
matched blocks the offset is "half of *this carriageway's own* width" (correct, since the reference
line is that carriageway's own centerline); for unmatched/fallback blocks it's "half of *one*
carriageway's width, plus enough to cross the median from the *shared* centerline" (also correct, since
the reference line there is different). Same underlying `stWidthFt` field, two different — and both
individually correct — formulas for two different reference geometries. No conflation risk found.

**Residual, lower-priority risk (inherent to the design, not newly introduced by either bug fix above):**
the per-street offset is a **street-wide median** of all that street's CSCL way widths — a single block
whose local paved width is unusually narrow relative to its street's median could get an offset that
overshoots that specific block's own curb. This is a pre-existing characteristic of the TF2-14 design
(only ever calibrated by eyeball against two streets, Houston and Bowery, per the comments in
`preprocess.js`) and applies to the 68-street "long tail" far more than the 6 flagship divided streets,
since those have never had any human look at their per-block geometry. Worth flagging to Kevin's visual
gate explicitly (watch for any block that looks like it overshoots, not just "does the street generally
look better"), not a blocker.

---

## 4. The determinism prerequisite (#27) — ✅ RESOLVED 2026-09-30

**Status update:** #27 is fixed on branch `data/pipeline-determinism` (no tiles/ regen in that PR — the
fix ships with this resurrection's own regen, or whichever geometry regen lands first). This section is
left in place as the investigation record; the risk it describes is closed.

**The code paths do not overlap.** Width computation (`initWidths()`, `getCurbOffsetFromWidth()`) is
entirely per-street, precomputed once from `street_widths.json`'s own polylines — it never calls
`findIntersection()`, `closestPointOnStreet()`, or `extractPolylineBetween()` (the three functions
`docs/qa/pr117-arrow-direction.md` names as the source of #27's order-dependent results), and it never
calls `getBlockPolyline()`. Nothing about resurrecting #25 exercises the buggy code.

**But #27 had to land first, operationally, for two reasons.** First, the general reason already on
the board: a regen pipeline must be deterministic for `compare-tilesets.js` diffs to mean anything, and
this resurrection touches **74 streets** (vs. Option A's 23) — a much larger, harder-to-eyeball diff
that leans on the comparator being trustworthy even more than Option A did. Second, and more concretely:
**the one confirmed non-deterministic block found so far is `DELANCEY STREET (LUDLOW to ESSEX) [S]`** —
per PR #117 QA, in isolation it returns a normal ~53m block, but after ~1,000 other blocks are processed
first in the same run it can return a corrupted ~961m result. Delancey is also **the single
largest-magnitude street in this resurrection's own blast radius (+8.00m, top of the list in §2)**.
Running a resurrection regen while #27 was unresolved risked nondeterministically baking either the
correct short block or the corrupted long one into committed tiles, on exactly the street getting the
largest offset change, with no reliable tool to catch it (the QA-flagged `compare-tilesets.js`
displacement-metric bug, PR #116 finding #1, should also be fixed first — this regen will produce far
more moved segments than Option A's 355, and that tool is already known to misreport by up to 10x on
vertex-count-mismatched segments).

**Root cause, for the record (full mechanism in `build/preprocess.js`'s `findIntersection()` comment and
`docs/open-items.md` #27):** the function's cache key was canonical/order-independent
(`[street1,street2].sort().join('|')`), but the search that populated the cache used raw caller argument
order to decide loop nesting. Delancey's OSM way is fragmented into overlapping chains that create a
genuine second exact crossing candidate with Essex St ~17m from the real one; whichever block's
`findIntersection()` call reached that shared cache entry first (Delancey-primary or Essex-primary)
silently determined which of the two candidates won for the rest of the run. Fixed by canonicalizing the
search to the same sorted order as the cache key — same-inputs-same-output only, no other semantic
change. `scripts/test-pipeline-determinism.js` is now a standing regression gate for this class of bug.

---

## 5. Verdict + plan

**Feasible — clean, well-understood fix, once two prerequisite bugs are closed.** Not a parameter
tweak or a flag flip; comparable in shape to Option A itself (new investigation-derived correctness
fixes to already-written code, plus a full Manhattan regen and a fresh visual gate), not a small
tuning pass.

**Sequencing, relative to #116/#117/the Brooklyn regen:**

1. **#27 (`getBlockPolyline` non-determinism) — already its own queued item, must land first.**
   Not new scope from this investigation; already on the board as a dedicated pre-Brooklyn session.
2. **Allow-list + canonical-key audit** (~1 session): drop Forsyth, add Park Ave, verify the
   investigation's other §5 candidates (Riverside Dr, Canal St, ACP Jr Blvd, Lenox Ave, Madison St, St
   Nicholas Ave, Cooper Sq, Pike St) against live CSCL one-sided-addressing evidence the same way
   Houston/Bowery were verified; fix `initWidths()`'s two `getStreetCurbOffset(canonKey)` call sites to
   use a canonical-form-aware wide-street check (build a canonicalized `WIDE_CROSSTOWN_NAMES`/
   `WIDE_NS_NAMES` variant, don't re-fetch `street_widths.json`).
3. **Wire + validate + regen** (~1–1.5 sessions): add the (now-correct) `initWidths(OSM_WIDTHS)` call to
   `main()`; re-derive `scripts/validate-widths.js`'s hardcoded target ranges against the actual
   redesigned algorithm (they're stale, dating to the pre-redesign per-call detection approach) or
   retire the script in favor of a live assertion inside the build itself; fix `compare-tilesets.js`'s
   displacement-metric bug (PR #116 finding #1) before trusting this regen's own diff; run the same
   `SIGNS_CACHE_PATH`/`TILES_OUTPUT_DIR` controlled-A/B harness Option A already built.
4. **QA pass** (~0.5–1 session): re-verify the monotonic "no street regresses" claim against the real
   committed diff, spot-check a sample of the 68 "long tail" streets that have never been visually
   checked before, confirm rule-content is untouched (same structural argument as Option A — offset
   computation happens after rule composition).
5. **Kevin's visual gate** (phone/Mac, same street tour as #116's own checklist — Houston, Bowery,
   Allen, Delancey, Park Ave, Broadway, Riverside Dr, Lenox Ave, ACP Jr Blvd, plus Forsyth as a control
   that should look **unchanged**). Expected movement per street, stated so the gate has a number to
   check against rather than a vibe: Houston **+6.3 to +6.8m** further off the old line, Allen **+7.4m**,
   Delancey **+8.0m** (clamp ceiling), Bowery only **+2.5m** (it was already close), Forsyth **+0.0m**
   (control — must look identical to today), Park Ave **+3.1m** if added to the divided allow-list.

**Do not fold this into the eventual Brooklyn regen.** Two independent reasons already established
elsewhere in this project's own conventions: (a) Brooklyn is still in its own early B0/B1 investigation
phase (per `open-items.md` #24), likely weeks from its own regen — bundling would block this fix on an
unrelated, much larger effort; (b) the project has a consistent, explicitly-stated pattern of not
bundling unrelated regens so a visual-gate failure can be attributed to one cause (build 17/18 split,
FT-21-must-not-ship-with-realtime, and PR #117's own stated "geometry vs composition kept as separate
regens" rule for its sequencing after #116). **Do fold this into the still-open #116 PR/regen**, rather
than merging #116 first and running a second, separate geometry regen afterward — both are geometry-only
curb-offset changes on the same axis, and bundling them gives Kevin **one** visual gate to pass instead
of two, on streets he's already planning to drive-test. **#117 (rule-composition/arrow-direction) stays
its own, later regen**, exactly as already decided on the board — it touches a different axis (which
rules apply to a zone) and shouldn't be conflated with a geometry-only offset change.
