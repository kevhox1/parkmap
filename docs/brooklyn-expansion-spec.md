# Brooklyn Expansion — Execution Spec

**Status:** Execution spec, commissioned after Kevin's greenlight, 2026-09-18 ("I reviewed the spec
on Brooklyn and it looks like that is possible? I think we should add" — `docs/open-items.md` #24).
**Supersedes/extends:** `docs/expansion-brooklyn-hoboken-scoping.md` (the scoping memo — read that
first; this doc assumes its verdicts and does not re-litigate them). Hoboken stays parked — the memo's
"not currently feasible" verdict stands and nothing here reopens it.
**Author:** tech-lead. **Ratifies:** Kevin. **Builds:** `@backend-data`, `@ios-engineer`, `@qa-verifier`.

---

## Read this first — decisions Kevin needs to make before any session starts

1. **Beachhead neighborhoods, not full borough.** Recommend starting with the North Brooklyn
   brownstone belt (Williamsburg, Greenpoint, Fort Greene, Park Slope — exact list is Kevin's call,
   see §1). Full borough later, once the mechanism is proven on a phase.
2. **FT-21 (wide-street curb offset) — fix it first, or ship Brooklyn with the same known flaw
   Manhattan has today?** Brooklyn has more wide/divided boulevards (Eastern Parkway, Ocean Parkway,
   Flatbush Ave, Atlantic Ave) than Manhattan. Recommend: do the already-queued one-session
   investigation first (confirm CSCL supports Kevin's Option A), and only implement Option A if that
   comes back clean — bail to "ship with the imperfection" rather than let this balloon. See §2.
3. **No Kevin-drive-test exists for Brooklyn.** Recommend: ship dark behind a flag, gate the flip on a
   numeric coverage bar per neighborhood + informal validation from Brooklyn users who already asked
   Kevin for this. See §5.
4. **App size will grow.** Phase 1 (beachhead) adds roughly 10–20MB to the ~31MB tile payload
   already bundled in the app; full borough later would add 60–90MB. Fine with that now? See §6.
5. **Two small pre-existing Manhattan cleanups (dup-vertex points, 359 leftover missing zone rows)
   ride along for free if #2 triggers a regen — no separate cost, flagging so it isn't lost.** A third
   item (Chinatown diagonal lines, #11) stays parked, unchanged from Kevin's own "after all hero
   builds" call — nothing here touches it.
6. **Backend engineer time is shared with the in-flight Regulars feature.** One small Regulars
   session (the S1-follow-up push-trigger rewrite) should land first — it's already blocking
   Regulars' own next step and touches none of the files Brooklyn touches. After that, the two
   features don't compete for the same files. See §6.
7. **🔴 NEW (2026-09-25) — the #26 arrow_direction composition fix (PR #117) MUST land before any
   Brooklyn regen.** `createSubSegments()` in `build/preprocess.js` — the exact function Stream B1
   parameterizes — is the code that composes which rule applies to which stretch of curb from raw
   sign data. It had a systemic bug (glyph-only direction reads, ignoring NYC's authoritative
   `arrow_direction` field) that flips rule zones onto the wrong half of a block; measured at
   ~70% of confidently-resolvable signs disagreeing with the old glyph assumption citywide. Brooklyn
   pulls from the SAME Socrata sign datasets and runs through the SAME composition code — it
   inherits this bug identically, unfixed. Regenerating Brooklyn tiles before #26/#117 lands (or
   worse, regenerating Brooklyn and Manhattan together while #26 is still open) would ship a
   brand-new borough with the exact class of error Kevin field-caught in Manhattan, at first-impression
   time. See `docs/open-items.md` #26 and PR #117 for the fix, quantification, and acceptance test.

Everything below is the reasoning and the checklist. Read on for detail; the five items above are
the only things that actually need a yes/no from Kevin before work starts.

---

## 1. Problem & user story

Kevin has inbound users who park in Brooklyn. WePark today shows accurate, live-rule-derived curb
color only inside a Manhattan-shaped bounding box. A Brooklyn user opens the app, sees an honest
basemap with zero overlay data, and gets no value from the app's core promise ("is this curb legal
right now") anywhere they actually park.

The scoping memo (`docs/expansion-brooklyn-hoboken-scoping.md`) already answered "is this possible":
yes, feasible-with-work, because every ingested data source (NYC DOT signs, ASP suspensions, CSCL
centerlines) is citywide already — Brooklyn's rows are being thrown away today by a hardcoded
`borough=Manhattan` filter, not missing from the source. This spec turns that verdict into a session
plan.

**Why now:** Kevin greenlit it after reading the memo. Community 2.0 and Regulars' schema/push work
are both merged or nearly done, freeing backend-lane time for a new data project.

## 2. Scope — In / Out

**In (Phase 1 — the beachhead):**
- Generalize the pipeline's borough filter into a reusable neighborhood-allowlist mechanism (not a
  one-off Brooklyn hack — the same mechanism should extend to Phase 2/3 and eventually other boroughs
  without a rewrite).
- Pull, join, and tile real Brooklyn sign/CSCL/OSM data for a small, named set of beachhead
  neighborhoods (Kevin picks the exact list; §1 has a working default).
- Extend `NYC_TO_OSM` alias table, `WIDE_*` street lists, and the seam/bridge-exclusion logic for
  Brooklyn's own name/geometry quirks.
- Seed `zones` rows for the beachhead neighborhoods (data-only, mirrors `06-manhattan-zones.sql`).
- Generalize `scripts/coverage-report.js`'s neighborhood list to include Brooklyn boxes.
- Generalize iOS's `manhattanCoverageBounds` → a single coverage box matching the expanded grid, plus
  a dark-ship flag gating Brooklyn's visibility until validated.
- Ship behind a flag, validate, flip.

**Out (deferred, named so they don't evaporate):**
- Full-borough Brooklyn tiling — a later phase, sized after Phase 1's real numbers land, not
  estimated precisely here.
- Hoboken — ruled not-currently-feasible by the memo; nothing in this spec reopens it.
- A new legality category / semantic model change — the memo confirmed Brooklyn needs none (same
  regulatory vocabulary, same 5-color palette, zero category-model changes).
- FT-21 Option B (real curb-geometry ingestion from NYC planimetric sidewalk polygons) — that is its
  own project per Kevin's own A→B→C ruling; this spec only asks whether Option A is a Brooklyn
  prerequisite, not whether to build B.
- Fixing Chinatown diagonals (#11) — stays backburnered exactly as Kevin left it.
- Any Regulars feature work — mentioned only for lane-sequencing purposes (§6).

## 3. Architecture

**Codebases touched:** Backend-data pipeline (`build/preprocess.js`, `scripts/build-oneway-data.js`,
`scripts/build-street-widths.js`, `scripts/coverage-report.js`), Supabase (one data-only migration,
no schema change), iOS (`Services/Constants.swift`, a new dark-ship flag, a bundle-mirror update).
No PWA changes required (`index.html` stays maintenance-mode per HANDOFF's standing operating rule;
if Kevin ever wants Brooklyn in the PWA too, that's a separate, unscoped ask).

**Key architectural finding (changes the shape of this spec): the tile-loading layer is already
borough-agnostic.** Read directly from the code:

- `ios/WePark/WePark/Services/TileLoader.swift` derives every grid parameter — `gridRows`, `gridCols`,
  `latMin`, `lngMin`, `rowSize`, `colSize` — from the bundled `index.json` at runtime
  (`TileLoader.swift:269-281`), not from a compiled-in Manhattan constant. `tileKeys(forRegion:...)`
  is a pure function parameterized entirely by those values (`TileLoader.swift:316-339`).
- The pipeline itself already produces one flat grid (`build/preprocess.js:38-44`, `GRID.latMin
  40.700`/`latMax 40.882`/`lngMin -74.020`/`lngMax -73.907`, 80×50 rows/cols) and one `index.json`
  header carrying those same bounds (`build/preprocess.js:1773-1776`; confirmed live in
  `tiles/index.json`: `1071` tiles, `44280` segments, `31MB`, sparse — only ~27% of the 4,000 possible
  grid cells are populated, non-covered cells simply don't exist as files).

**Conclusion: expanding Brooklyn coverage does NOT require multiple grids, multiple `index.json`
files, or any `TileLoader` code change.** The correct move is to widen the single `GRID` bounding box
in `build/preprocess.js` to the union of Manhattan's existing box and the beachhead neighborhoods'
boxes, recompute `rowSize`/`colSize` to keep tile physical size roughly constant, and regenerate.
`TileLoader` will load whatever tiles exist inside that wider box with zero changes — it is already
designed to handle a sparse, larger-than-currently-populated grid (that is the entire reason the
grid-cell/tile-file split exists today).

**What DOES need to change, and where:**

| File | Manhattan-only thing today | Generalization |
|---|---|---|
| `build/preprocess.js` | `SP_BOUNDS` (State Plane box), `GRID` bounds, `&borough=Manhattan` on both Socrata fetch URLs (`:1405`, `:1456`) | Parameterize into a neighborhood-allowlist argument; widen `GRID`/`SP_BOUNDS` to the phase's union bbox; borough filter becomes a list (`Manhattan,Brooklyn`) or drops in favor of the allowlist doing the narrowing post-fetch |
| `scripts/build-oneway-data.js`, `scripts/build-street-widths.js` | `WHERE = "boroughcode='1' AND ..."` | Parameterize `boroughcode` (Brooklyn = `'3'`, confirmed live count 27,678 rows, `docs/expansion-brooklyn-hoboken-scoping.md` data-source table) |
| `NYC_TO_OSM` alias table (`preprocess.js:187`) | ~50 hand-verified Manhattan aliases | Extend with Brooklyn-specific aliases, found empirically in B2 (§4) — cannot be pre-guessed, memo is explicit about this |
| `WIDE_AVENUE_RE`/`WIDE_NS_NAMES`/`WIDE_CROSSTOWN_NAMES` (`preprocess.js:832-894`) | Manhattan-only hand-curated wide-street lists | Audit against Brooklyn's own wide boulevards (Eastern Pkwy, Ocean Pkwy, Flatbush Ave, Atlantic Ave, Grand Army Plaza) — the generic `WIDE_AVENUE_RE` regex (`/\bAVE(NUE)?\b/`) likely already catches avenue-named ones; parkways/named streets need the explicit-list treatment the Manhattan set already uses |
| `scripts/coverage-report.js` | `HOODS` — hand-drawn Manhattan neighborhood boxes (`:20-41`) | Add a Brooklyn `HOODS` block for the beachhead neighborhoods (the memo already flags this tool as "not load-bearing for the actual data pipeline" — QA/validation tooling only) |
| `ios/WePark/WePark/Services/Constants.swift` | `manhattanCoverageBounds` (`:25-30`), doc comment explicitly reasons about Hoboken/Brooklyn edge cases already | Rename/widen to a single box matching the expanded `index.json` bbox (see §5 for the "list vs single box" decision) |
| `supabase/0N-brooklyn-zones.sql` (new, next available migration number after `08`) | N/A — `zones` table has no borough column, no bounding-box constraint, RLS is `select using (true)` already (memo, confirmed) | Pure data insert, mirrors `06-manhattan-zones.sql`'s box-per-neighborhood pattern, written and stopped per the standing "Kevin applies migrations by hand" rule |

**Data flow, unchanged in shape:** Socrata (signs, ASP suspensions) + CSCL (centerlines/width/oneway)
+ OSM (street geometry) → `preprocess.js` join/classify/offset/tile → `tiles/*.json` + `index.json` →
committed to `tiles/` AND `ios/WePark/WePark/Resources/tiles/` (must stay byte-identical — the #21
lesson, verify with `diff -rq` every regen) → bundled into the .app at archive time → `TileLoader`
reads them at runtime with no code change.

## 4. Work streams

Ordered roughly as they'd actually run; streams marked **parallel-safe** can run concurrently with
whatever else is active (subject to the 2-core VPS note in `docs/open-items.md` — keep concurrency to
1-2 agents).

### Stream B0 — FT-21 Option A feasibility confirm (`@backend-data`, ~1 session)
The investigation `docs/open-items.md` #7 already calls for ("one tech-lead session to confirm CSCL's
carriageway modeling actually supports (A) cleanly") — pulled forward here because Brooklyn is the
reason to do it now rather than later. Confirm CSCL models Brooklyn's (and Manhattan's) divided
streets as separate carriageways cleanly enough to treat each as its own centerline/curb-offset,
per Kevin's ruling in `docs/field-testing-log.md` FT-21. **Gate: if yes, Stream B0b runs. If no,
declare cosmetic (Option C) and Brooklyn proceeds on today's heuristic — do not escalate to Option B
(real curb-geometry ingestion) as a Brooklyn prerequisite; that stays its own, unscoped project.**

### Stream B0b — FT-21 Option A implementation + Manhattan regen (`@backend-data`, ~2 sessions, CONDITIONAL on B0)
Implements the per-carriageway CSCL offset in `build/preprocess.js`, replacing the five-name
allow-list fudge (`7m + width/2` for Houston/Bowery/Allen/Forsyth/Delancey) with real carriageway
geometry. **Bundles the two parked geometry-debt items that ride any regen for free:**
- **#9** — duplicate-adjacent-vertex hygiene fix (`docs/open-items.md` #9, 12.4%→22.7% side effect of
  the FT-14/FT-19 fix) — cheap, mechanical, skip pushing coordinate-identical points in
  `extractSubSegment()`'s result loop.
- **#10** — the 359 residual lost zone rows (`docs/open-items.md` #10) — no further fix is known to
  exist; this stream just re-measures the residual count after B0b's changes for the record. Not a
  fix, a measurement.

Runs on **Manhattan data only** — validates against the known Houston/Bowery case before Brooklyn's
own data ever touches this code, and means Brooklyn inherits already-fixed geometry rather than
inheriting the bug and refighting it at 2x scale. **Explicitly excluded from this stream:** #11
(Chinatown diagonals) — stays parked per Kevin's own call; only a regression spot-check (not a fix)
rides along in QA (Stream B6).

### Stream B1 — Pipeline generalization (`@backend-data`, ~1 session)
**Prerequisite: PR #117 (docs/open-items.md #26, arrow_direction span-authority fix) must be merged
before this stream starts** — it touches the same function (`createSubSegments()`) this stream
parameterizes, and its own production regen must be sequenced deliberately (see #26/#117), not
accidentally bundled into Brooklyn's first regen. Confirm #26/#117's status before starting B1.

Mechanical parameterization: borough/neighborhood-allowlist argument threading through
`build/preprocess.js`, `build-oneway-data.js`, `build-street-widths.js`. Introduces the
neighborhood-allowlist mechanism itself — a generic `name → bbox` list (mirrors
`coverage-report.js`'s existing `HOODS` pattern) that (a) narrows which fetched rows get kept, and
(b) defines the union `GRID`/`SP_BOUNDS` bbox for the current phase. This is the mechanism the memo
asked for generically — extending it for Phase 2/3 or a future borough is "add rows to the list,"
not "rewrite the pipeline." Also ports `coverage-report.js`'s `EXCLUDE` regex
(`BRIDGE|TUNNEL|EXPRESSWAY|...`) into `preprocess.js`'s own fetch/join path, so Manhattan-Brooklyn
seam segments (Brooklyn Bridge, Manhattan Bridge, Williamsburg Bridge, the Battery/BQE tunnel
approaches) are excluded from tile geometry rather than risking a double-count or mis-join once both
boroughs' CSCL rows are in play simultaneously — bridges/tunnels aren't curb parking anyway, and the
QA tool already treats them this way. **Verify:** run the parameterized pipeline with the allowlist
set to Manhattan-only and confirm byte-identical tile output vs today's `tiles/` — proves the
refactor is behavior-preserving before Brooklyn data ever enters it.

### Stream B2 — Brooklyn data pull + name/geometry join fixes (`@backend-data`, ~2-3 sessions)
The real cost, per the memo. Pull real Brooklyn OSM/CSCL/sign data for the beachhead neighborhoods,
inspect side by side, and expect (not hope against) Brooklyn's own version of the FT-14/FT-19 bug
class — name-join drops from co-names/spacing variants specific to Brooklyn street naming, and
geometry quirks from Brooklyn's angled grid and diagonal avenues. Extends `NYC_TO_OSM` with
Brooklyn-specific aliases (found empirically, not guessed). Audits `WIDE_AVENUE_RE`/`WIDE_NS_NAMES`/
`WIDE_CROSSTOWN_NAMES` against Brooklyn's wide boulevards. **Budget round-trip QA cycles here** —
this is explicitly not a clean rerun of the Manhattan build.

### Stream B3 — First beachhead tile regen + coverage measurement (`@backend-data`, ~1-2 sessions)
Produces the first real Brooklyn tile set for the beachhead. Extends `scripts/coverage-report.js`
with a Brooklyn `HOODS` block for the beachhead neighborhoods. Measures, precisely (not estimated):
tile count/MB added, segment count, per-neighborhood coverage %, category breakdown sanity-check
against Manhattan's known shape (ASP/METERED/NO_STANDING ratios shouldn't look wildly different —
same regulatory vocabulary, per the memo). This is the number that replaces the memo's 60-90MB
full-borough guess with a real, phase-1-scoped figure.

### Stream B4 — Zone seed migration (`@backend-data`, ~0.5-1 session, can fold into B3)
`supabase/0N-brooklyn-zones.sql` — one row per beachhead neighborhood, box-per-neighborhood pattern
copied from `06-manhattan-zones.sql`. No schema/RLS change (`zones` table is already borough-agnostic,
confirmed by the memo). Written and stopped; Kevin applies by hand per standing rule.

### Stream B5 — iOS coverage-bounds generalization + dark-ship flag (`@ios-engineer`, ~1 session, **parallel-safe** with B2/B3)
Because `TileLoader` needs zero changes (§3), this stream is small and can start as soon as B1 lands
(it only needs to know the *shape* of the new bbox, not the final Brooklyn data). Work:
- Rename/widen `AppConstants.manhattanCoverageBounds` → a single box matching the pipeline's expanded
  `GRID` bbox once B3's numbers are final (single box for v1 — see §5).
- Add a unit test asserting the constant encloses the bundled `index.json`'s own `latMin/latMax/
  lngMin/lngMax` header — a drift guard, catches the constant going stale on the next regen without
  needing fetch-at-launch infrastructure.
- Add a new dark-ship flag (name TBD, e.g. `AppConstants.brooklynCoverageEnabled`) gating whether
  Brooklyn tiles/zones are visible/loadable at all, mirroring the `communityEnabled`/`regularsEnabled`
  playbook. Ships `false` until Stream B6+B7 clear.
- Verify `ios/WePark/WePark/Resources/tiles` mirrors `tiles/` byte-identically after the regen (the
  #21 lesson — PR #21's tiles landed only in `./tiles/` and iOS ran stale tiles for days).

### Stream B6 — QA pass (`@qa-verifier`, ~1-1.5 sessions)
- Coverage-report thresholds: a numeric go/no-go per beachhead neighborhood, calibrated against
  Manhattan's own historical weakest neighborhoods (FiDi 34%, East Harlem 36%, Harlem 38% — from
  `docs/field-testing-log.md` FT-14) as the floor, not zero.
- Sim spot-checks: a hand-picked sample of Brooklyn blocks, cross-referenced against Street View/
  known regulations — the same kind of manual check Kevin's own early Manhattan spot-checks were
  (e.g. TF2-4), performed by the QA agent instead since there's no drive test.
- Confirm zero Manhattan regression (byte-diff Manhattan-only tile output against pre-B0b/B1
  baseline).
- Confirm the seam/bridge exclusion actually excludes the named bridges/tunnels.
- Confirm the dark-ship flag genuinely hides Brooklyn data end to end (tiles not loaded, zones not
  fetched-and-shown, coverage bounds not widened) when off.
- Regression spot-check (not fix) on Chinatown diagonals (#11) if B0b ran, per its exclusion note.

### Stream B7 — Beta validation (Kevin + backend-data, ~0.5-1 session, mostly non-code)
Recruit/notify the Brooklyn users who already asked Kevin about this as informal per-neighborhood
validators — behind the still-off flag, a small soak period, Report-flow submissions become the
correction signal Manhattan got from Kevin's own drives. Product/ops task; the only engineering
component is making sure Report submissions during this soak are visible to whoever's watching.

### Stream B8 — Flag flip + TestFlight ceremony (`@ios-engineer` + Kevin, ~0.5 session)
Flip the dark-ship flag once B6's gate and B7's soak period both clear, mirroring the
`communityEnabled`/`regularsEnabled` flip playbook (one boolean, named guard tests reconciled).
Kevin's ceremony: archive, bump `CURRENT_PROJECT_VERSION`, note Brooklyn coverage + the size increase
in the build's What-to-Test copy (same precedent as naming FT-21/coverage gaps in Manhattan's own
external TestFlight copy).

**Parallel-execution summary:** B0/B0b/B1/B2/B3/B4 are one continuous backend-data thread (mostly
serial — each depends on the previous one's output; B4 can fold into B3's session). B5 is
`@ios-engineer` and file-disjoint from all of them — safe to start as soon as B1's bbox shape is
known, well before B3's Brooklyn data lands. B6 is `@qa-verifier`, naturally serial after B3/B5. B7
is Kevin-driven soak time, not an agent session. B8 is the small closing iOS+Kevin session.

## 5. Coverage-bounds decision (detail on §1 item 3 / §4's B5)

**Single expanded box, compile-time, for v1 — not a per-area list, not fetch-at-launch.** Reasoning:
- `manhattanCoverageBounds` is a coarse camera/auto-center guard, not data — it changes only when the
  tile grid's own extent changes (a handful of times ever), unlike `zones` (20-40+ rows, changes
  often, correctly generalized to fetch-at-launch in S14). Building fetch-at-launch infrastructure for
  something that changes this rarely is over-engineering.
- A single box (matching the pipeline's own expanded `GRID` bbox) requires zero new Swift types and
  is naturally kept in sync by the drift-guard unit test (§4, Stream B5) reading the bundled
  `index.json` header at test time.
- Being "over-inclusive" at the edges (the box now spans some water/other-borough slivers between
  Manhattan and the beachhead) is the same acceptable trade the existing doc comment already reasons
  about for DUMBO/Brooklyn Heights today — "honest basemap; no overlays at that location," not
  misleading.
- **If a future phase's bbox becomes so large or so non-contiguous that a single rectangle would
  swallow huge uncovered territory (e.g. jumping to a borough far from Manhattan, or covering
  Manhattan + Brooklyn + Staten Island with nothing between), revisit this and move to a small named
  list.** Not needed for Phase 1's contiguous North Brooklyn beachhead.

**Seam handling (bridges/tunnels):** excluded from tile geometry entirely via the ported `EXCLUDE`
regex (Stream B1) rather than trusting CSCL's borough-code assignment at the boundary to be
unambiguous — cheaper and matches the existing philosophy that bridges/tunnels aren't curb parking.

## 6. Community/Regulars implications

**Zones:** confirmed current state (not the memo's snapshot) — migration `06-manhattan-zones.sql` is
**applied to production** (`HANDOFF.md`, 2026-09-13: "42 rows verified... 41 zones Battery Park→Inwood
+ the retired soho-les id"), fetched at launch via `Services/ZoneStore.swift`, `communityEnabled` is
now **shipped true** (launched 2026-09-14). The `zones` table remains borough-agnostic (no borough
column, RLS `select using (true)`) exactly as the memo found — a Brooklyn zone seed is a pure data
insert (Stream B4), same migration pattern as `06`, next available number after `07`/`08` (Regulars'
schema/push-trigger files). Push targeting is unaffected by borough: community zone push is already
`zone_id`-driven and Regulars' push is `user_id`/`regular_edges`-driven — neither has ever assumed
Manhattan, so nothing needs to change there for Brooklyn to work.

**Sequencing against Regulars' remaining backend work:** as of this spec, Regulars' only remaining
pure-`@backend-data` item is the **S1-follow-up** row (`docs/regulars-roadmap.md`) — the live
`pins_invoke_send_community_push` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` cron job.
It's small, and it's already a hard gate for Regulars' own S3 deploy ceremony (QA-proven: without it,
the Regulars head start is inert). **Recommend it lands before Stream B0 starts** — not because of
any file collision (it touches `supabase/04-*`, Brooklyn touches `build/preprocess.js` and friends;
zero overlap), but because it's small and already blocking a ceremony gate elsewhere. Every other
remaining Regulars session (S5, S7, S9, S10, S10b, S13, S14) is `@ios-engineer` or a Kevin
device-ceremony — none compete with Brooklyn's backend-data thread for files or, practically, for
agent attention. **Net effect: after the one small S1-follow-up session, Brooklyn's backend lane runs
essentially uninterrupted.**

## 7. Validation strategy (detail on §1 item 3)

Manhattan's tile quality today is the product of many rounds of Kevin physically driving past the
data and reporting what's wrong — FT-14 (Bleecker gap), FT-19 (intersection overshoot), TF2-19
(Houston/Bowery showing free), FT-21 (still open). **Brooklyn has no equivalent safety net — Kevin
parks in Manhattan, not Brooklyn — so the risk of shipping visibly wrong data is genuinely higher
than it was for Manhattan, not just "the same risk, new city."**

What replaces the drive test, in order of how much weight each carries:
1. **Ship dark behind a flag first** (Stream B5's `brooklynCoverageEnabled` or equivalent) — mirrors
   the Community 2.0/Regulars playbook. A bad regen never reaches a real user's map before someone
   looks at it.
2. **A numeric coverage-quality bar per beachhead neighborhood** (Stream B6), calibrated against
   Manhattan's own weakest historical neighborhoods rather than an arbitrary round number — an
   objective go/no-go that doesn't require a human to eyeball every block.
3. **The inquiring Brooklyn users as informal per-neighborhood beta validators** (Stream B7) — the
   closest substitute for Kevin's own drive-and-report loop: real people, driving Brooklyn, using the
   app's existing Report flow, which both validates the feature and produces the correction signal
   Manhattan got for free from Kevin's own driving.
4. **Sim spot-checks against Street View** (Stream B6) — a manual check, done by an agent instead of
   Kevin, on a small hand-picked sample. Weakest signal of the four (no live traffic conditions, no
   real-world confirmation of ASP suspension timing, etc.) but catches gross join failures before
   anyone drives past them.

**The phased-beachhead choice (§1 item 1) is itself a risk-containment decision, not just a scoping
convenience:** a bad join or geometry bug in a 4-6-neighborhood beachhead is a contained, findable,
fixable mistake. The same bug across a full borough regen (2x Manhattan's street-mile count) would be
far more expensive to find and far more visible to far more strangers before anyone catches it.

## 8. Sizing

**Rough numbers, per the memo's own instruction to measure precisely rather than guess further —
these are the honest current best estimates, refined precisely by Stream B3:**

| | Manhattan today | Phase 1 (beachhead, ~4-6 neighborhoods) | Full Brooklyn (future, unsized) |
|---|---|---|---|
| Tiles | 1,071 | +rough 150-300 (measured in B3) | full borough is CSCL ~2x Manhattan's segment count |
| Segments | 44,280 | +rough 6,000-12,000 (measured in B3) | sign volume 2x-4.6x Manhattan's, per dataset |
| Bundle size added | 31MB baseline | rough **10-20MB** | rough **60-90MB** (memo's own estimate, unchanged) |

Phase 1's beachhead is a handful of dense brownstone neighborhoods out of Brooklyn's ~70+
neighborhoods — the rough 10-20MB figure assumes comparable curb-sign density to Manhattan per street
mile for these specific neighborhoods (plausible; not verified — Stream B2/B3 will verify it against
real data, same as the memo's own instruction for the full-borough number).

**Full borough is explicitly not sized precisely here** — sizing it now would be estimating a
project that doesn't exist yet. It gets sized the same way Phase 1 was: measure Phase 1's real
numbers, then extrapolate a Phase 2/3 with real data in hand, not more guessing.

## 9. Session-by-session plan (summary)

| # | Session | Owner | Depends on | Sessions |
|---|---|---|---|---|
| (Regulars S1-follow-up) | Live push-trigger rewrite + cron | `@backend-data` | none (Regulars' own gate) | 1 — recommend runs first |
| B0 | FT-21 Option A feasibility confirm | `@backend-data` | — | 1 |
| B0b | FT-21 Option A impl + Manhattan regen (bundles #9, measures #10) | `@backend-data` | B0 = yes | 2 (conditional) |
| B1 | Pipeline generalization (allowlist mechanism, borough params, seam exclusion) | `@backend-data` | B0/B0b | 1 |
| B2 | Brooklyn data pull + name/geometry join fixes | `@backend-data` | B1 | 2-3 |
| B3 | First beachhead regen + coverage-report generalization + measurement | `@backend-data` | B2 | 1-2 |
| B4 | Zone seed migration | `@backend-data` | can fold into B3 | 0.5-1 |
| B5 | iOS coverage-bounds generalization + dark-ship flag | `@ios-engineer` | B1 (bbox shape) — parallel-safe with B2/B3 | 1 |
| B6 | QA pass (coverage thresholds, sim spot-checks, regression, flag verification) | `@qa-verifier` | B3, B5 | 1-1.5 |
| B7 | Beta validation soak (Brooklyn inquiring users) | Kevin + `@backend-data` | B6 | 0.5-1 |
| B8 | Flag flip + TestFlight ceremony | `@ios-engineer` + Kevin | B7 | 0.5 |

**Total, Phase 1 only:**
- **Without FT-21 (B0 comes back "declare cosmetic," B0b skipped):** ~10 sessions core + ~1-2 buffer
  = **11-12 sessions.**
- **With FT-21 Option A (B0 comes back yes, B0b runs):** ~12 sessions core + ~1-2 buffer =
  **13-14 sessions.**

Either way, this excludes the Regulars S1-follow-up session (that's Regulars' own count, just
recommended to land first) and excludes full-borough Phase 2/3 (unsized, see §8).

**Kevin's ceremonies in this plan:** apply the zone migration by hand (after B4/B6 clear); the flag
flip + archive/TestFlight upload (B8); informally recruiting/notifying Brooklyn beta validators (B7).
No tile "deploy" exists as a separate ceremony — tiles are bundled in the app binary, so Brooklyn
ships as part of a normal app build, same as every Manhattan tile regen has.

## 10. Acceptance criteria

- [ ] AC-1: `build/preprocess.js`, `build-oneway-data.js`, `build-street-widths.js` accept a
  neighborhood-allowlist/borough parameter; running with Manhattan-only produces byte-identical tile
  output to the pre-change baseline (Stream B1's own verification step).
- [ ] AC-2: Brooklyn beachhead neighborhoods produce tiles with per-neighborhood coverage % at or
  above the QA-defined floor (Stream B6), with zero category-breakdown anomaly vs Manhattan's known
  shape.
- [ ] AC-3: Bridges/tunnels at the Manhattan-Brooklyn seam (Brooklyn Bridge, Manhattan Bridge,
  Williamsburg Bridge, Battery/BQE tunnel approaches) produce zero tile segments (excluded, not
  mis-joined or double-counted).
- [ ] AC-4: `tiles/` and `ios/WePark/WePark/Resources/tiles/` are byte-identical after every regen in
  this plan (`diff -rq`), verified before merge.
- [ ] AC-5: `AppConstants` coverage-bounds constant encloses the bundled `index.json`'s own bbox
  (unit test), and a dark-ship flag gates all Brooklyn data (tiles load, zones fetch/display,
  coverage-bounds widening) — flag off reproduces today's Manhattan-only behavior exactly.
  Named guard tests to be declared by name in Stream B5, mirroring the `communityEnabled`/
  `regularsEnabled` playbook.
  - `test<Flag>_defaultsFalse`
  - `test<Flag>_tilesNotLoaded_whenDisabled`
  - `test<Flag>_zonesNotFetched_whenDisabled` (or equivalent, depending on how zone-fetch scoping is
    implemented)
  - `testCoverageBounds_enclosesIndexJsonBbox`
- [ ] AC-6: `supabase/0N-brooklyn-zones.sql` is written, idempotent, and requires zero schema/RLS
  change (data-only migration) — matches `06-manhattan-zones.sql`'s pattern.
- [ ] AC-7: If Stream B0b runs — Manhattan's Houston/Bowery divided-street case shows curb offsets
  hugging each carriageway's own curb (not mid-road), confirmed by the same kind of check used for
  TF2-19 (real-engine simulation or sim spot-check, since no drive test is required for a
  Manhattan-only regen).
- [ ] AC-8: The 359-row zone-loss residual (#10) is re-measured (not necessarily reduced) and the
  number is recorded, whether or not B0b runs.
- [ ] AC-9: Chinatown diagonals (#11) show no new regression if B0b's geometry changes ran — spot
  check only, no fix expected or required.
- [ ] AC-10: At least one Brooklyn beta-validator Report submission is received and reviewed during
  the B7 soak period before B8's flag flip (evidence the informal validation loop is real, not just
  planned).
- [ ] AC-11: Post-flip, `CURRENT_PROJECT_VERSION` is bumped, and the build's What-to-Test copy names
  Brooklyn's beachhead coverage and its known limitations (mirrors how FT-21/coverage gaps are named
  in today's external TestFlight copy).

## 11. Open decisions (repeated from §1, for the record)

1. Exact beachhead neighborhood list (recommend Williamsburg/Greenpoint/Fort Greene/Park Slope as a
   starting default; Kevin's call).
2. FT-21 Option A as a Brooklyn prerequisite — recommend yes, bounded to one cheap investigation
   session with an explicit bail-out.
3. Coverage-bounds mechanism — recommend single compile-time box for v1 (§5), revisit only if a
   future phase's geometry stops being contiguous with Manhattan.
4. Beta-validator recruitment — whose relationship, what channel, how many neighborhoods' worth of
   validators is "enough" before B8's flip (no hard number proposed here; Kevin's judgment call,
   informed by however many inquiring users actually exist per neighborhood).
5. App-size growth tolerance — 10-20MB now, 60-90MB at full borough; no objection surfaced yet, listed
   so it's an explicit yes rather than an assumed one.

## 12. Out-of-scope follow-ups noticed but not specced here

- **Full-borough Brooklyn** (and eventually Queens/Bronx/Staten Island, per the memo's own open
  question about whether "Brooklyn" implies a long-term all-boroughs intent) — deliberately unsized,
  revisit after Phase 1's real numbers land.
- **PWA parity for Brooklyn** — `index.html` stays maintenance-mode; if Brooklyn coverage is ever
  wanted there, that's a separate ask against a codebase this project explicitly does not touch.
- **A borough column on `zones`** — not needed today (no query needs to filter zones by borough), but
  worth naming if a future phase ever needs cross-borough zone search/filtering at scale beyond what
  the nearest-first nine-zone picker already handles.
- **NYC 311 live ASP-suspension feed** — unrelated to Brooklyn specifically, already an open item
  (HANDOFF's ASP calendar section); the citywide suspension calendar Brooklyn will use is the same one
  Manhattan already uses, so this expansion doesn't change that item's priority either way.
