# TF2-19 Socrata Fetch Hardening + Regen 6 — QA Pass 1

**Reviewed:** branch `data/tf2-19-socrata-fix-regen6` at `851d5d8` (commit 1 `9ef38e7` fetch hardening + commit 2 `851d5d8` regen 6), against `docs/qa/tf2-19-houston-bowery-free-investigation.md`
**Verdict: SHIP WITH CAVEATS** — data correctness independently proven byte-for-byte; one real gap in the new hardening code itself (non-blocking, filed below) and one growing pre-existing (not-this-PR) doc-invariant drift noted for the record.

*(Report filed by qa-verifier 2026-07-09; transcribed to file by orchestrator — agent returned the report body without writing it.)*

## Summary

I independently recomputed the entire tile-content dataset from raw files (not trusted from the PR body) and it matches the builder's claimed numbers exactly, category-by-category, for both the pre-regen-5 baseline and regen 6. I cross-checked the live Socrata `count(*)` endpoint directly and it matches the claimed "expected" counts (75,684 / 20,346) exactly. The key adversarial question — recovery vs. duplication — resolves cleanly to **recovery (benign)**: the duplicate-rule-within-segment ratio is statistically constant (~32-33%) across pre-baseline, defective-regen-5, and regen-6, proving the ~15-18% count increase is proportional completeness gain, not new duplication from the retry logic. One real gap: the new completeness gate has a silent fail-open path if the `count(*)` probe itself errors, undermining the investigation's "highest-leverage" mitigation in exactly the failure class it exists to catch — not triggered in this run, but worth hardening before it bites on a future regen.

## Acceptance criteria checklist

- [x] **AC1 Code diff confinement** — verified via `git diff a176147 9ef38e7 -- build/preprocess.js`: exactly 2 diff hunks, both confined to `fetchSocrataDataset()` (original lines ~1210–1259). `getCurbOffsetFromWidth`, `initWidths`, `DIVIDED_STREET_ALLOW_LIST`, zone-cap/stub-filter/rule-assignment logic byte-identical. `street_widths.json`/`osm_data.json`/`osm_oneway.json` also unchanged in the PR.
- [x] **AC2 Gate correctness** — verified by reading the diff: paged fetch URL and `$select=count(*)` probe both use the identical bare filter `borough=Manhattan` (no `$where=` used anywhere, so no drift possible between the two). The completeness throw and the retry-exhaustion throw both fire inside `fetchSocrataDataset()`, called at `main()` line ~1251, well before any `fs.writeFileSync` (first tile write at line 1538) — confirmed no tile write can follow a gate failure. Tolerance (0.5% of ~75,684 ≈ 378 rows) is sane and tighter than the investigation's suggested ±2%. Grepped the new code for `break`: only remaining `break` is the retry loop's success-exit; no silent truncation path remains.
- [x] **AC3 Duplication vs. recovery (the key question)** — see dedicated section below. **Verdict: recovery, not duplication.**
- [x] **AC4 Independent recount** — recomputed from raw tile files with my own node script (not the builder's numbers). Regen 6 (worktree): METERED 15,153, NO_PARKING 5,491, NO_STANDING 18,978, TRUCK_LOADING 2,517, SPECIAL 1,749, UNKNOWN 5,506, ASP_DAILY 4,997, ASP_MON_THU 11,050, ASP_TUE_FRI 11,279, ASP_OVERNIGHT_MWF 258, ASP_OVERNIGHT_TTHS 188, total segments 39,289, total rule instances 77,166, empty-rules 0 — **exact match** to the PR body's table. Pre-regen-5 baseline (`git show a176147^`, 1028 tile files, 36,924 segments): METERED 12,856, NO_PARKING 4,821, NO_STANDING 16,156, TRUCK_LOADING 2,162, SPECIAL 1,519, UNKNOWN 4,748, ASP all flat — **exact match** to both the investigation and PR claims.
- [x] **AC5 Corridor + geometry spot-checks** — independently reproduced the 4 builder-cited segments (`BOWERY_STANTON_STREET_EAST_HOUSTON_STREET_E_0/1/2`, `ELIZABETH_STREET_..._W_3`) byte-for-byte: `line` arrays identical pre/post, rules recovered exactly as claimed. Plus **two corridors the builder did NOT specifically cite**: DELANCEY STREET (66 geometry-identical matched segments, METERED 28→27 essentially at parity, NO_STANDING 45→54) and ALLEN STREET (59 matched, METERED 40→56, TRUCK_LOADING 15→17). Control ordinary side street MOTT STREET (90 matched, modest +5-8% across categories, no anomaly). Independently re-ran the module's own offset probe (`initWidths()` + `_perStreetOffset`) and got BOWERY 12.4864m, E HOUSTON ST 12.7912m, W HOUSTON ST 12.4864m — exact match to the claimed values, verified directly rather than trusted by construction.
- [x] **AC6 Sync + bump** — `diff -rq tiles ios/WePark/WePark/Resources/tiles` in the worktree: 0 differences. `git diff 3af8f2a..origin/data/tf2-19-socrata-fix-regen6 -- sw.js`: exactly one line changed (`wepark-v37`→`wepark-v38`), nothing else in `sw.js` touched.
- [x] **AC7 Blast-radius sanity** — sampled `tile_5_10`, `tile_15_20`, `tile_20_22` (regular tiles) plus 3 of the 8 newly-created tiles (`tile_1_13`, `tile_26_7`, `tile_40_25`): all well-formed JSON, schema fields (`id`, `street`, `from`, `to`, `side`, `line`, `rules`, `dominantCategory`, `oneway`) present on every segment; `oneway_toward` present when `oneway=true`, correctly omitted when `oneway=false` — confirmed this conditional-omission pattern is pre-existing (same behavior in the pre-regen-5 baseline), not a regression. `index.json` grid geometry (`gridSize`, `latMin/Max`, `lngMin/Max`, `rowSize`/`colSize`) byte-identical to baseline — only tile membership/counts changed, as expected.

## The key adversarial question — duplication vs. recovery

**Verdict: (i) benign recovery, not (ii) a duplication bug.** Evidence:

1. **Live ground truth matches.** `curl` against Socrata's `nfid-uabd` and `2x64-6f34` `$select=count(*)&borough=Manhattan` today returns exactly `75684` and `20346` — matching the PR's claimed expected counts to the row, independently of anything the builder ran.
2. **The dedup step is content-keyed, not row-id-keyed, and unchanged by this PR.** `deduped` uses key `on_street|from_street|to_street|side_of_street|distance_from_intersection|sign_description` (line ~1282 in current main, untouched by the diff). This means any genuine same-row re-fetch would collapse in dedup regardless of the fetch layer. Separately, the new retry code only pushes a page's data once — on the first successful attempt, `pageData` is set and the retry loop `break`s; there is no code path that appends a page twice.
3. **Duplicate-rule-within-segment ratio is statistically flat across all three snapshots**, which is the discriminating test: pre-baseline 12,099/36,924 = 32.8%, defective regen 5 (currently shipped) 9,727/30,000 = 32.4%, regen 6 12,851/39,289 = 32.7%. If the retry hardening were introducing new duplicate-page artifacts, this ratio would spike in regen 6 specifically. It doesn't — it tracks the *existing* pipeline characteristic (same-worded signs posted at multiple physical points that get merged into one segment) proportionally with total volume.
4. **Average rules/segment grew only modestly** (1.897 pre-baseline → 1.964 regen 6, +3.5%), consistent with a more-complete pull surfacing more raw signs per block, not an exponential/duplicative blowup.
5. **A structural point the investigation didn't fully surface**: the pre-regen-5 "last known-good" baseline used the *exact same* fetch loop (no `$order`, no retry, no completeness check) that failed in regen 5 — it was simply luckier. Given Socrata's unordered `$limit`/`$offset` pagination is not guaranteed stable against a live, concurrently-written dataset, it's entirely plausible the pre-baseline was *itself* a partial pull, just a much less damaged one. Regen 6, with `$order=:id` + retry + a verified completeness gate, is a strong candidate for the **first genuinely complete pull this pipeline has ever produced** — which would explain landing *above* the old "baseline" rather than merely restoring it.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: Completeness gate is fail-open on its own probe error, silently disabling the investigation's "highest-leverage" mitigation**
  - Where: `build/preprocess.js`, `fetchSocrataDataset()`, the `$select=count(*)` probe block (new code, ~20 lines added ahead of the paging loop in commit `9ef38e7`)
  - What: if the count(*) probe itself throws or returns non-`ok` (network blip, transient 5xx, malformed `count` field), `expectedCount` stays `null`, only a `console.log` WARNING is emitted, and the entire completeness check is skipped for that dataset — the build proceeds and can still ship a truncated pull without ever throwing, provided the *paged* fetch happens not to error on that run.
  - Expected: per the investigation, the completeness check was called out as "the single highest-leverage change — it would have caught regen 5's failure outright." A gate that can be silently disabled by the same class of transient network failure it exists to guard against doesn't deliver on that promise.
  - Repro: mock/observe a network blip on the initial `count(*)` request (independent of the subsequent paged requests, which have their own unrelated retry logic) — the build completes normally with no non-zero exit and no loud failure, identical to the pre-PR silent-truncation risk, just narrower in scope (now only reachable via unordered-pagination + concurrent-write skip, since `$order=:id` closes the main historical vector).
  - Not triggered in this run — confirmed via the live `curl` check that both probes would have succeeded, and the commit message's `expected == fetched` claim is real and independently reproducible.
  - Owner: `@backend-data` — recommend either retrying the probe with the same backoff as pages, or treating probe failure as a hard build failure (fail-closed) rather than a soft skip.

### 🟢 Minor / nit

- **#2: HANDOFF.md's `APP_VERSION`/`CACHE_VERSION` sync invariant continues to drift, unrelated to this PR.** `index.html`'s `APP_VERSION` is frozen at `'wepark-v36'` while this PR bumps `sw.js` `CACHE_VERSION` to `wepark-v38` (a 2-version gap post-merge). Confirmed via `git log -S` that this is an established pattern going back several bump commits (`f0f1b91`, `8720a3a`, `179904c`, `5fd690b`, `d3f20cb` all touch only `sw.js`), not something this PR introduces or worsens uniquely — but it is a real, growing violation of the documented HANDOFF.md invariant ("the two should match"). Practical impact is limited: the primary auto-reload path (`controllerchange` listener) doesn't depend on `APP_VERSION`, so functionality isn't broken — only the debug version-chip UI shows a stale number. Not this PR's job to fix; flagging for a `@pwa-maintainer` follow-up ticket.
- **#3: Regen 6 commit message doesn't state whether `SOCRATA_APP_TOKEN` was actually set for this run.** Functionally moot (the gate reported exact `expected == fetched`), but would help future incident forensics to know whether the completeness gate alone sufficed or the token also helped.

### 💡 Out of scope (logged, not fixed)

- Investigation §7.2 longer-term items (raw-signs payload caching for diagnosability, CI tile-diff sanity gate flagging >10% category swings pre-merge) were explicitly deferred by the investigation itself as "longer-term" and correctly not attempted in this PR.
- No `NO_STOPPING` category in classifier output — acknowledged by the builder as pre-existing, unrelated to this PR, not reproduced as new here.
- Live on-device re-verification of Houston/Bowery/Delancey/Allen/Forsyth against current NYC signage (explicitly requested of `@qa-verifier` in the PR body) was **not performed** — this requires a physical drive-test per Kevin's own field-testing process and is outside sandbox scope. This PR touches no `MapViewRepresentable.swift`/`ContentView.swift`/`DriveMode*.swift`/overlay-attachment code, so it falls outside the mandatory live-UI-smoke gate for mount-chain PRs; flagged explicitly as **not verified** rather than silently passing, per house style. The byte-level tile-content verification above gives very high confidence the data is correct, but only a live drive confirms the rendered experience.

## Smoke tests run

- `node --check build/preprocess.js` → syntax OK (reproduced the builder's claim).
- Live `curl` against both Socrata `count(*)` endpoints with the identical filter used by the pipeline → exact match to claimed expected counts (75,684 MAIN / 20,346 ASP).
- Independent node-script recount of category totals + segment/rule counts from raw tile JSON, for both regen-6 (worktree) and pre-regen-5 baseline (`git archive a176147^ -- tiles`) → exact match to builder's table on every row.
- Independent duplicate-rule-entry scan across all three snapshots (pre-baseline, defective regen 5 currently on `main`, regen 6) → ratio invariant (~32-33%), the discriminating test for the duplication-vs-recovery question.
- Byte-for-byte `line`-geometry + rule-array comparison for the 4 builder-cited corridor segments, plus independently chosen Delancey/Allen (divided-street allow-list, not cited by builder) and Mott Street (ordinary control) — all consistent with the recovery narrative.
- Re-ran the module's `initWidths()`/`_perStreetOffset` probe directly (not trusted from the PR body) → exact match to claimed offset values.
- `diff -rq tiles ios/WePark/WePark/Resources/tiles` in the worktree → clean.
- `git diff` scoping checks confirming `build/preprocess.js` diff confined to `fetchSocrataDataset()`, `sw.js` diff is a single-line version bump, and no other non-tile files changed.
- Schema/well-formedness spot-check on 3 random pre-existing tiles + 3 of the 8 newly-created tiles, including `oneway`/`oneway_toward` (FT-11 fields) survival.
- Not run: Xcode build/simulator screenshot (no Swift/UI files touched by this PR; out of scope per the mount-chain live-UI-smoke gate) and live on-device signage re-verification (requires physical drive-test, logged above as not verified).

## What's working

- The fetch hardening is precisely scoped — a reviewer worried about scope creep into TF2-14's geometry code has nothing to worry about; the diff is genuinely two tight hunks inside one function.
- The gate design (retry-before-give-up, throw-before-write, count-before-page) is architecturally correct and in the right order relative to the tile-write stage — a failure here truly cannot ship partial tiles.
- The builder's own PR body numbers are trustworthy: every single claimed count in the table, the corridor recovery claims, and the offset values checked out exactly against independent, from-scratch recomputation — no inflation or cherry-picking found.
- Good self-awareness in the PR: explicitly calling out the anomalies (8 new tile files, no NO_STOPPING category, segment ID churn) rather than hiding them, and explicitly asking QA to do the duplication-vs-recovery discrimination rather than asserting it away.

---

## Pass 2 (2026-07-09)

**Reviewed:** commit `139f738` (`fix(data): fail-closed completeness probe per QA finding #1`) on `data/tf2-19-socrata-fix-regen6`, on top of the `851d5d8` state reviewed in Pass 1. Scope: re-verify Finding #1 (Significant, fail-open completeness probe) and Finding #3 (nit, undocumented `SOCRATA_APP_TOKEN` status) only — tile data was not re-verified since this commit touches no tile files (confirmed below), and AC4–AC7 from Pass 1 stand unchanged.

**Verdict: SHIP CLEAN.**

### Claim-by-claim verification

1. **Probe now retries + fails closed; no null-`expectedCount` path survives.** Read the full new hunk in `build/preprocess.js` (`fetchSocrataDataset()`, lines ~1240–1291 in the worktree) directly, not the PR description. Confirmed:
   - The count(*) probe now runs inside the exact same `for (attempt = 1; attempt <= totalAttempts; attempt++)` retry loop, reusing the same `RETRY_BACKOFF_MS = [2000, 4000, 8000, 16000, 32000]` array and `sleep()` helper as the paged fetch — not a separate/divergent schedule.
   - **Checked the specific subtle case the task called out — malformed/NaN count parsing.** The old code's `if (Number.isFinite(parsed)) expectedCount = parsed;` (silently falls through with `expectedCount` still `null` on non-finite, no retry) is gone. New code: `if (!Number.isFinite(parsed)) { lastError = new Error('malformed count(*) response'); continue; }` — a malformed/NaN response is now treated as a retryable failure identically to an HTTP error, consuming a retry attempt rather than silently short-circuiting.
   - The old `try { ... } catch (e) { console.log('WARNING...') }` wrapper that let the function fall through to the paging loop with `expectedCount === null` is gone entirely. The only path out of the probe block with `expectedCount === null` now hits `throw new Error('FATAL: ... count(*) probe failed after 6 attempts...')` — unconditional, no remaining warn-and-skip branch anywhere in the probe.
   - Downstream: the old `if (expectedCount !== null) { ...gate... }` conditional (which was the actual mechanism of the fail-open bug — it let the gate be *skipped* rather than failing) is now an unconditional `{ ...gate... }` block with a comment explaining `expectedCount` is guaranteed non-null by construction. Confirmed by reading the code that no path reaches this block with a null value — the only way to get here is via `break` on a validated `Number.isFinite` count.
   - **Empirically exercised both failure modes in a scratch-only harness** (`/private/tmp/.../scratchpad/failclosed_test/`, not run against the real worktree or committed anywhere): (a) a harness reproducing the exact retry/backoff/throw control flow, pointed at an unreachable host (`http://127.0.0.1:1/...`) — correctly made all 6 attempts, then threw `FATAL: ... probe failed after 6 attempts`, process exited 1, and a "tile write" sentinel variable was never reached; (b) a second harness mocking `global.fetch` to return HTTP 200 with a body containing no `count` field on every call (the malformed-response path, not a network error) — also correctly consumed all 6 attempts before throwing, proving the malformed-body case is not treated as a silent success. Both harnesses left the real worktree and branch untouched.
   - **Verdict: Finding #1 is fully resolved.** No remaining path — network error, HTTP error, or malformed/NaN response — can leave the gate silently disabled.

2. **Diff confinement.** `git diff-tree --no-commit-id --name-only -r 139f738` → `build/preprocess.js` only, reproduced independently. Zero tile files, zero `sw.js`, matching the builder's claim and the commit message's statement that no regen was re-run (correctly deferred to Pass 1's already-complete byte-for-byte data verification, since this commit is fetch-layer code only).

3. **`node --check`.** Ran directly against the worktree's `build/preprocess.js` (which is synced to `139f738`): `SYNTAX OK`.

4. **`SOCRATA_APP_TOKEN` status documented.** Confirmed via `gh pr view 63 --json body,comments`: the PR body now states "`SOCRATA_APP_TOKEN` was **not set** for the regen 6 run (env var unset)," and the builder's PR comment reiterates the same, additionally documenting the exact `expected == fetched` counts (MAIN 75,684/75,684, ASP 20,346/20,346) achieved without the token. Finding #3 (nit) resolved.

### Findings

**🔴 Blocking:** none.
**🟡 Significant:** none — Finding #1 from Pass 1 is closed by this commit.
**🟢 Minor / nit:** Finding #3 from Pass 1 is closed by this commit. Finding #2 (`APP_VERSION`/`CACHE_VERSION` drift, `index.html` vs `sw.js`) remains open — it was correctly out of scope for this fetch-layer-only follow-up commit (no `sw.js` touched, per the diff-tree confinement check above) and continues to be a pre-existing, not-this-PR issue for `@pwa-maintainer` to pick up separately.
**💡 Out of scope:** unchanged from Pass 1 — live on-device signage re-verification still not performed (requires a physical drive-test, outside sandbox scope).

### Smoke tests run (Pass 2)

- Read the full new diff hunk in `build/preprocess.js` line-by-line against the specific gap identified in Pass 1, including the malformed/NaN-parsing sub-case explicitly.
- `git diff-tree --no-commit-id --name-only -r 139f738` → confirmed `build/preprocess.js` only.
- `node --check build/preprocess.js` (worktree, synced to `139f738`) → `SYNTAX OK`.
- Built two standalone scratch-only Node harnesses reproducing the exact retry/backoff/fail-closed control flow from the diff, to empirically exercise (a) exhausted-retries-on-network-error and (b) exhausted-retries-on-malformed-response — both correctly threw after 6 attempts and never reached a simulated "tile write" point. Harnesses live only under `/private/tmp/claude-501/.../scratchpad/failclosed_test/`; the worktree and branch were not modified.
- `gh pr view 63 --json body,comments` → confirmed both the PR body and the builder's follow-up comment document the `SOCRATA_APP_TOKEN`-unset status and the Finding #1 fix.
- Did not re-run tile-data verification (AC4–AC7) — correctly out of scope per the diff-tree confinement result (zero tile files changed) and the coordinator's instruction; Pass 1's byte-for-byte verification stands unchanged.

### Verdict

**SHIP CLEAN.** Both Pass 1 findings (#1 Significant, #3 nit) are verifiably closed by commit `139f738`, confirmed by direct code reading plus empirical scratch-harness reproduction of the fail-closed path (including the specific malformed/NaN-parsing edge case), not just by trusting the commit message. No new findings introduced by this commit — it is precisely scoped to the two lines of defense requested (probe retry schedule + fail-closed semantics) and touches nothing else. The one remaining open item (Finding #2, `APP_VERSION`/`CACHE_VERSION` drift) is pre-existing, unrelated to TF2-19, and does not block this PR. Recommend merge.
