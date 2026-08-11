# FT-14 Name-Join Normalizer + Regen 7 — QA Pass 1 (post-merge)

**Reviewed:** `main` at `b5da617f` (PR #68, already merged on Kevin's explicit call without a completed
QA pass), against `docs/qa/ft14-join-drop-investigation.md` and the PR body's claimed measurements.

**Verdict: SAFE TO ARCHIVE, with one 🟡 finding that should get a fast follow-up (not this build).**
This PR is already on `main`; my findings below are (a) a gate on the pending build-15 TestFlight
archive and (b) follow-up tickets, per the coordinator's framing — not merge blockers, since there is
no merge left to block. **I did not find anything that should stop the archive.** Bundle parity,
zero category regressions, and the collision-checked compact-spacing fallback are all clean on
independent re-derivation. I did find that the SAINT↔ST swap's stated safety justification ("OSM has
exactly 3 Saint-prefixed streets citywide") is factually wrong — the real number is 37 — but after
adversarially checking all 37 against the actual OSM key set, I confirmed zero live wrong-street
collisions exist today. That gap is real (no code-level uniqueness check on this path, unlike the
compact-spacing fallback) but not currently exploited, so I'm rating it 🟡 Significant, not 🔴
Blocking.

I ran everything I could without Xcode — this is pure Node/data verification, fully runnable on this
Linux VPS. No iOS build/simulator smoke was possible here; see "What I could not verify" for the
Mac-only checks Kevin should still expect to run.

## Claims checklist (re-derived independently, not trusted from the PR body)

- [x] **Coverage citywide 43%→47%** — verified by running `scripts/coverage-report.js` myself against
  both the pre-PR tile set (checked out via `git worktree` at `b5da617~1`) and the current `main` tile
  set. Baseline: **43% / 318mi**, exact match. Post-fix: **47% / 350mi**, exact match.
- [x] **Harlem 38%→64%, SoHo 65%→73%, Greenwich Village 70%→73%** — all four numbers reproduced
  exactly from the same two coverage-report runs.
- [x] **Category regression guard: zero decreases, METERED/NO_STANDING/NO_PARKING/TRUCK_LOADING/SPECIAL
  all match the claimed before/after counts exactly** — recomputed with my own counting script directly
  against raw tile JSON (not the PR's numbers): METERED 15,153→15,795, NO_STANDING 18,978→19,810,
  NO_PARKING 5,491→5,876, TRUCK_LOADING 2,517→2,624, SPECIAL 1,749→1,948 — exact match on every value.
  Checked every other category too (UNKNOWN, all 4 ASP subtypes): all flat-or-up, **zero decreases
  anywhere**. ASP_MON_THU/ASP_TUE_FRI combined grew +17.6% — matches the PR's "+17%" claim once you
  read it as the two core ASP categories, not the full ASP+overnight+daily blend (which grows +15.9%,
  still consistent, just a slightly different denominator than I initially assumed).
- [x] **Kevin's origin block** — verified by diffing actual tile segments before/after. Before: Bleecker
  `LA GUARDIA PLACE→MERCER` had **zero** faces either side; `THOMPSON→LAGUARDIA` (no-space spelling)
  had south side only. After: `LA GUARDIA PLACE→MERCER` has both N and S side faces; `THOMPSON
  STREET→LA GUARDIA PLACE` (with-space spelling) now also has north-side faces. Both halves of the
  claim confirmed.
- [x] **Corridors: St Nicholas Ave ~444 faces, Lenox/Malcolm X ~192 faces** — confirmed exactly, once I
  matched the counting convention: total tile *segments* (not unique blocks) summed across every raw
  NYC spelling variant of the corridor (`ST NICHOLAS AVENUE` 351 + `SAINT NICHOLAS TERRACE` 59 +
  `SAINT NICHOLAS PLACE` 26 + `SAINT NICHOLAS AVENUE` 8 = **444**; `LENOX AVENUE` 182 + `LENOX TERRACE
  PLACE` 7 + `MALCOLM X BOULEVARD` 3 = **192**). Worth noting for future QA passes: the `street` field
  in tile JSON stores the raw Socrata spelling, not the resolved OSM name, so corridor counts need to
  sum across spelling variants to reproduce these figures.
- [x] **Bundle parity** — `diff -rq tiles ios/WePark/WePark/Resources/tiles` → exit 0, zero output,
  byte-identical. This is the hardest build-15 gate per the task brief and it's clean.
- [x] **Normalizer safety, compact-spacing fallback** — rebuilt the same compact-form index the code
  builds, against the real `osm_data.json` (2,813 keys): **exactly 3 collisions**, and I hand-verified
  all 3 are same-street duplicate spellings (`Vandam Street`/`Van Dam Street`; two spellings each of
  `Williamsburg Bridge Bikepath`/`Williamsburg Bridge Bike Path`; case-variant duplicates of
  `Manhattan Bridge Lower Level`) — no case where the fallback could misroute a sign onto a genuinely
  different street. The investigation's claim here is accurate.
- [x] **8 hand-verified aliases** — all 8 resolve to real, present keys in `osm_data.json`
  (`Malcolm X Boulevard`, `Adam Clayton Powell Jr. Boulevard` ×3 input spellings, `Frederick Douglass
  Boulevard`, `6th Avenue` ×2 input spellings, `Nathan D. Perlman Place`, `West 110th Street`). None
  are missing or typo'd.
- [ ] **SAINT↔ST swap safety justification — FAILED as stated, but re-derived safe in practice.** See
  Finding #1 below. The investigation/PR claim "OSM has exactly 3 Saint-prefixed streets citywide" is
  wrong (actual: 37). I independently re-audited all 37 against the live NYC sign data actually joined
  in regen 7 and found zero wrong-street collisions today, but the code has no defense-in-depth against
  a future one (unlike the compact-spacing fallback, which does).
- [x] **HANDOFF.md invariants** — `sw.js` `CACHE_VERSION` bumped v38→v39, correctly scoped (only line
  changed in `sw.js`). No RLS/Supabase surface touched. No `index.html` module-splitting. One
  *pre-existing, not-this-PR* invariant drift noted below (Finding #2, already flagged in an earlier QA
  report — not new).
- [~] **Socrata completeness-gate soft spot** — not independently provable (the exact expected/fetched
  log line is genuinely lost), but I built several independent consistency checks that all point the
  same direction: complete pull, not truncated. See "Completeness assessment" below. **I do not
  recommend forcing a fresh regen before the archive** — see reasoning below — but I'd treat this as a
  process gap worth closing (capture the gate's console output to a committed log next time).

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

**#1: The SAINT↔ST swap's stated safety count is wrong — OSM has 37 "Saint"-prefixed streets, not 3
— and the code has no collision check on this path (unlike the sibling compact-spacing fallback).**

- Where: `build/preprocess.js` `osmName()`, the `variations` array entries
  `titled.replace(/\bSt\b/g, 'Saint')` / `titled.replace(/\bSaint\b/g, 'St')`
  (lines ~301-306); investigation doc `docs/qa/ft14-join-drop-investigation.md` line 198 and PR body
  ("OSM has exactly 3 'Saint'-prefixed streets citywide").
- What: I ran `Object.keys(osm_data.json).filter(k => /\bsaint\b/i.test(k))` directly and got **37**
  matches (Saint Nicholas Ave/Pl/Terrace, Saint Marks Place, Saint James Place, Saint Lukes Place,
  Saint John's Lane, and 30 more — mostly Staten Island/outer-borough streets present in the shared
  `osm_data.json` file even though this pipeline scopes to Manhattan signs). The investigation's "3"
  figure is simply a miscount (possibly counting only the Manhattan-relevant subset informally, without
  actually running the count against the real key list). Unlike the compact-spacing fallback three
  lines below it — which explicitly gates on `compactMatches.length === 1` before accepting a match —
  the SAINT/ST swap has **no equivalent uniqueness check**. It's a first-match-wins lookup against
  `OSM_STREETS`, protected only by the (wrong) claim that few candidates exist to collide.
- Adversarial follow-up I did before deciding severity: I checked whether any of the 37 "Saint X" keys
  has a *different*, non-punctuated "St X" key that could actually collide with it in today's dataset.
  Result: only one abbreviated `St `-prefixed key exists at all (`St. Andrews Plaza`, with a period),
  and `normalizeNYCName()` never strips punctuation, so it can never exact-match a candidate built from
  a period-less NYC sign string. **Zero live collisions exist in the current OSM data.** I also checked
  which of the 37 "Saint" streets are actually exercised by regen 7's live tile output: only 7 raw
  spelling variants appear (`ST JAMES PLACE`, `ST MARKS PLACE`, `ST NICHOLAS AVENUE`/`SAINT NICHOLAS
  AVENUE`, `SAINT NICHOLAS PLACE`, `SAINT NICHOLAS TERRACE`, `SAINT CLAIR PLACE`), all correctly
  resolved to their real OSM counterparts.
- Expected: the PR's whole risk argument for shipping this swap rests on "the finite OSM key set makes
  wrong matches impossible" — that's the right *kind* of argument, but it needs to actually be checked
  against the real key count, and ideally carry the same defense-in-depth (uniqueness gate) the sibling
  fallback has, rather than relying on an eyeballed low count that turned out to be off by 12x.
- Impact today: **none** — I verified this by exhaustive check, not by trusting the "it's fine" framing.
  This does not justify stopping the archive.
- Risk going forward: OSM data is periodically regenerated/re-sourced (`osm_data.json` isn't static);
  a future update that adds an abbreviated `St X` street name that happens to collide with one of the
  36 non-Nicholas "Saint X" streets would silently misroute signs with no code-level guard to catch it,
  unlike the compact-spacing path.
- Repro: `node -e 'const osm=require("./osm_data.json"); console.log(Object.keys(osm).filter(k=>/\bsaint\b/i.test(k)).length)'` → 37, not 3.
- Owner: `@backend-data` — recommend two small, low-risk follow-ups, not urgent: (1) correct the "3"
  claim in the investigation doc so future readers don't inherit the wrong number, (2) add the same
  `.length === 1`-style uniqueness gate to the Saint/St swap that the compact-spacing fallback already
  has, for defense-in-depth against a future OSM data change. Neither needs to happen before build 15.

### 🟢 Minor / nit

**#2: `index.html`'s `APP_VERSION` remains frozen at `wepark-v36` while `sw.js` `CACHE_VERSION` is now
`wepark-v39` (a 3-version gap) — pre-existing, not introduced or worsened uniquely by this PR, and
already flagged once before.** This exact issue was Finding #2 in `docs/qa/tf2-19-regen6-qa.md` (then a
2-version gap); it has grown by one more version with each subsequent `sw.js`-only bump, including this
one. Per the earlier QA report's analysis (which I re-confirmed by reading the current `index.html`
code at lines 7990-8013), the primary auto-reload path (`controllerchange` listener) doesn't depend on
`APP_VERSION` at all, so this doesn't cause functional cache staleness — only the debug version chip in
the PWA UI shows a stale number. Per Kevin's iOS-only focus, I'm not treating this as material to the
build-15 decision; it's a `@pwa-maintainer` ticket, unrelated to this PR and unrelated to iOS.

## Completeness assessment (item 7 — the Socrata pull soft spot)

The PR body flags that the regen's completeness-gate console output (exact `expected == fetched` counts)
was lost with an interrupted agent session. The gate is fail-closed since #63/TF2-19 (verified by reading
`fetchSocrataDataset()` directly: a failed or malformed `count(*)` probe throws before paging even
starts, and a post-paging shortfall beyond 0.5% tolerance throws before any tile write) — so a completed
regen with committed tiles logically implies the gate passed. I looked for independent corroborating
signal rather than resting on that logical implication alone:

1. **Live Socrata counts today vs. the investigation's live-pull baseline are consistent with normal
   growth, not a large gap.** `curl .../nfid-uabd.json?$select=count(*)&borough=Manhattan` today →
   75,797 (investigation reported 75,324, three weeks earlier: +0.63%). ASP dataset: 20,335 today vs.
   20,262 then (+0.36%). Both are small, organic increases consistent with a live, growing NYC dataset
   — not the kind of swing you'd see from a differently-scoped or truncated pull.
2. **Regen 7's tile segment count tracks the investigation's own scratch candidate-fix run almost
   exactly, once you account for that growth.** Investigation candidate run (live pull ~2026-07-2x):
   42,921 tile segments. Regen 7 (committed, `main`): **43,062** — a +0.33% delta, in the same direction
   and rough magnitude as the independently-measured dataset growth above. A truncated pull in the
   TF2-19 failure-mode class would show a 40-48% *drop*, not a fractional increase.
3. **Average rules-per-segment is flat**: regen 6 was 1.964 (per the prior TF2-19 QA pass's own
   recount), regen 7 is 1.9558 by my independent recount — no distributional anomaly that would suggest
   a partial or duplicated pull.
4. **Category growth is uniform and proportional (+4% to +18% across every category, zero decreases)**
   — the signature of a more-complete pull surfacing previously-dropped rows, not the signature of a
   partial/truncated pull (which tends to drop unevenly/randomly across categories, not lift everything
   in the same direction).

**My recommendation: do not force a fresh regen before the archive.** All four signals point the same
direction and none suggest truncation. That said, this is inference from consistency, not a re-run of
the actual gate — flag as a process gap: future regens should capture the gate's console output
(`expected N rows / fetched N rows / shortfall 0`) to a committed log or PR comment so this kind of
post-hoc reconstruction isn't needed again.

## What I could not verify (Mac-only, deferred)

- No `xcodebuild`/simulator available on this Linux VPS. This PR touches zero Swift files
  (`git diff b5da617~1 b5da617 --stat` — confirmed no `.swift` files, no `MapViewRepresentable.swift`,
  `ContentView.swift`, `DriveMode*.swift`, or overlay-attachment code changed), so it falls outside the
  mandatory live-UI-smoke gate for mount-chain PRs by the stated criteria — but I could not independently
  confirm that the iOS app actually loads and renders the new tile bundle correctly on-device. That
  needs Kevin's on-device build-15 TestFlight check, which the field-testing-log entry says is already
  pending ("⏳ Kevin on-device (build 15): Bleecker @ LaGuardia colored, Harlem jump").
- Live drive-test re-verification of the recovered corridors against real-world signage — outside sandbox
  scope by design, same as prior QA passes on this repo.

## Smoke tests run

- `git worktree add --detach <tmp> b5da617~1` to get a clean pre-PR tile snapshot, then ran
  `node scripts/coverage-report.js` against both the pre-PR and post-PR (`main`) tile directories myself
  — did not trust the PR body's numbers.
- Independent Node recount of rule counts per category from raw tile JSON, both tile sets.
- Independent Node script rebuilding the compact-form collision index against the real `osm_data.json`
  (2,813 keys) — 3 collisions, all verified same-street.
- Independent Node script checking all 8 alias dictionary entries resolve to real `osm_data.json` keys.
- Independent Node script auditing every "Saint"-prefixed OSM key (37, not the claimed 3) and
  cross-checking against regen 7's actual live tile output and the sole abbreviated `St `-prefixed OSM
  key for real collision risk.
- Independent Node diff of Bleecker `LA GUARDIA PLACE↔MERCER↔THOMPSON` tile segments, before vs. after.
- Independent Node recount of St Nicholas / Lenox-Malcolm X corridor face counts, matched to the PR's
  counting convention after checking a couple of alternate definitions.
- `diff -rq tiles ios/WePark/WePark/Resources/tiles` → clean, zero output.
- `git diff --name-status b5da617~1 b5da617 -- tiles/` and the iOS mirror → 39 added / 1 removed / 485
  modified in both, identical file lists.
- `node -c build/preprocess.js` → syntax OK. All 1,070 tile files + `index.json` parsed as valid JSON
  with a script (0 failures).
- `git diff b5da617~1 b5da617 -- sw.js` → single-line `CACHE_VERSION` bump, nothing else touched.
- `curl` against both live Socrata `count(*)&borough=Manhattan` endpoints, compared against the
  investigation's reported baseline counts.
- Read `fetchSocrataDataset()` in full to confirm the fail-closed gate ordering (count probe → throw on
  failure → page → throw on shortfall → only then can tile-write code run).
- Inspected the one removed tile (`tiles/tile_77_47.json`, pre-PR) — confirmed it was a single small
  Inwood segment (Van Corlear Place) that shifted to a neighboring tile due to minor re-segmentation,
  consistent with the PR's "edge resegmentation" characterization, not a data-loss signal.
- Confirmed `git branch --show-current` is `main` before finishing; wrote no branch, no commit, no push.

## What's working

- Every single quantitative claim in the PR body that I could independently re-derive (coverage
  percentages citywide and per-neighborhood, category counts, corridor face counts, Kevin's origin
  block, bundle parity, file-add/remove counts) checked out **exactly**, not approximately — this PR's
  authors did not round favorably or cherry-pick. That's a high-trust signal for a data pipeline PR.
- The compact-spacing fallback's collision-check design is genuinely good — it's the right pattern
  (accept only unique matches) and I verified its "3 collisions, all same-street" claim is accurate,
  independent of the investigation's own word for it.
- The completeness gate (fail-closed since #63) is correctly ordered relative to tile writes — I traced
  it myself rather than trusting the comment, and confirmed no code path reaches a tile write with a
  null/unvalidated expected count.
- The FT-14 fix stayed exactly as scoped: confined to `osmName()`/`NYC_TO_OSM`, zero touches to
  `createSubSegments`, `findIntersection`, offset logic, or anything outside the name-join layer.
- `docs/field-testing-log.md`'s FT-14 entry already transparently documents the missing-pre-merge-QA
  caveat — good process hygiene given the unusual merge circumstances.
