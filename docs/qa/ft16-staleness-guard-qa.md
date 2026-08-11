# FT-16 Film-Permit Feed Staleness Guard — QA Pass 1

**Reviewed:** branch `backend-data/ft16-film-permit-feed` at `13f94586` (pinned to a local ref and
re-diffed after a delay to guard against `FETCH_HEAD` mutation by concurrent agents — diff stat was
stable across both reads), against `docs/qa/ft16-film-permit-feed-investigation.md` and
`docs/tier1-open-data-ingest-spec.md` §3.9.

**Verdict:** 🟡 ship with caveats (Edge Function) / **APPLY** (SQL migration, `02f`/`02g-ingest-runs.sql`, unconditionally)

## Summary

The decision to keep the daily cron/filter as-is and add an observability layer, rather than
repoint (no replacement dataset exists) or disable (trades one invisible failure for another), is
the right call and the investigation backing it is thorough and independently checks out. The new
`ingest_runs` table is correctly designed — genuinely idempotent, genuinely deny-all under RLS,
genuinely bypassed by the service-role writer, no contract changes to anything PWA/iOS touch. The
Edge Function change is smaller than it should be to fully deliver on its own stated goal, though:
the "loud" signal is `console.error` in a log dashboard plus a queryable table that nothing
actively polls, and the new freshness probe has two edge cases (an unexpected-but-valid response
shape, and no timeout) that can silently degrade the guard's own reliability — one of which
recreates, one layer up, the exact "legitimately-quiet vs. silently-broken" ambiguity this PR
exists to eliminate. None of these block the SQL or the core mechanism from shipping; they're
follow-up-shaped, not do-not-merge-shaped.

## Acceptance criteria checklist

- [x] **Chosen outcome (repoint/fix/disable) is defensible** — verified by independently reading
  the investigation's evidence (hard cliff in monthly `enteredon` counts, ruled-out embargo theory,
  catalog search for `tvpp-9vvx` correctly rejected as wrong-agency/wrong-granularity) and judging
  the tradeoff myself. Agree with the call — see "Judgment on the chosen outcome" below.
- [ ] **Staleness guard produces a genuinely discoverable signal for a future outage** — PARTIALLY.
  It is discoverable if a human goes looking (Supabase Functions log dashboard, or `select * from
  ingest_runs`), and the deploy runbook's Step 4/7 will make Kevin see it fire correctly once,
  immediately post-deploy. It is **not** discoverable proactively — nothing in this diff or the
  rest of the repo polls `ingest_runs` or the function logs on a schedule and pushes a signal
  anywhere. See Finding #1.
- [x] **`ingest_runs` table + RLS** — verified: table creation, both indexes, and
  `enable row level security` are each individually idempotent (`create table/index if not
  exists`, RLS-enable is a no-op on an already-enabled table — confirmed this exact pattern is
  already established house style in `02-pins-schema.sql`); zero policies + RLS enabled is
  genuinely deny-all to `anon`/`authenticated`; no `grant` statements anywhere in the file, and the
  Edge Function's service-role client bypasses RLS by platform convention identically to every
  other write path in this codebase (no explicit `service_role` grants exist anywhere else in the
  repo's SQL either — this is not an omission). No FK to any other table, so it cannot conflict
  with or block existing objects.
- [ ] **Edge Function's new network call doesn't degrade the function's actual job or leak
  secrets** — mostly yes (main upsert path is untouched and the whole staleness block is
  try/caught around the response/log write, so it cannot fail the invocation's primary purpose or
  its HTTP response), but two real gaps in the probe's own error handling. See Findings #2 and #3.
  No secrets in any log line or URL — `X-App-Token` only ever goes in a header, never a query
  param or log string.
- [x] **Blast radius: no RPC/table contract change** — verified via `git diff main...` name list:
  only `docs/field-testing-log.md`, `docs/qa/ft16-film-permit-feed-investigation.md`,
  `docs/tier1-open-data-ingest-spec.md`, `supabase/02f-ingest-runs.sql`, and
  `supabase/functions/ingest-film-permits/index.ts` changed. `supabase/02d-ingest-cron.sql`
  (defines `upsert_filming_pin`), `supabase/02-pins-schema.sql` (defines `pins` and
  `pins_with_author`) are untouched. Read `processPermit()` and the upsert/RPC-fallback block in
  the new file byte-for-byte against `main`'s copy — identical, not touched by this diff at all.
  `@pwa-maintainer`/`@ios-engineer` have nothing to do here.

## Judgment on the chosen outcome (task item #1)

Agree with keeping the cron running daily rather than disabling it. The cost of a no-op daily
invocation is negligible, the filter logic is provably correct (not the thing that's broken), and
the "disable it" alternative has a real, demonstrated failure mode in this exact org: it took three
months to notice the *current* outage with zero active monitoring, so there is no reason to expect
someone would remember to re-enable a disabled cron promptly if/when NYC resumes publishing —
that's arguably worse than the status quo it replaces, since the feed would then require an
additional manual re-enable step to recover instead of self-healing. No pushback here; the
reasoning in `docs/qa/ft16-film-permit-feed-investigation.md` §5 holds up.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: The staleness signal is passive-only — nothing in this codebase would have surfaced THIS outage any sooner than a human decided to go look**
  - Where: design of the whole FT-16 mechanism (`console.error` + `ingest_runs` row, `index.ts:310-344`)
  - What: the only ways to learn `stale: true` happened are (a) Kevin opens the Supabase Functions
    log dashboard and notices a `console.error` line among routine `console.log` lines, or (b)
    Kevin runs `select * from ingest_runs where stale`. Nothing in this diff, and nothing else
    found anywhere in `supabase/` or `docs/`, polls either of those on a recurring basis or pushes
    the result anywhere (no email, no webhook, no Slack integration, no second cron reading this
    table exists in the repo — confirmed by grepping for `slack|webhook|notify|alert` across
    `docs/` and `supabase/`, which surfaced only unrelated iOS local-notification specs).
  - Expected: the PR's own framing (commit message, investigation doc, spec §3.9) is "so a future
    outage is loud from day one instead of silent for three months." A signal that only becomes
    loud when someone happens to look is not structurally different from what existed before
    the fact this exact org went 3 months without looking is direct evidence that "loud" here
    still depends entirely on a human habit that has already been shown not to happen reliably.
  - Repro: none needed — this is a design property, not a bug. To see it concretely: suppose the
    feed resumes for 2 weeks then goes dark again 6 months from now. `ingest_runs.stale` flips to
    `true` on day 11 of the new outage and stays `true` every day after — but nothing changes on
    any screen Kevin looks at unless he specifically queries this table or opens function logs,
    neither of which is part of any documented recurring routine in `HANDOFF.md` or `TEAM.md`.
  - This is explicitly a judgment call per the task framing, and the investigation doc is
    self-aware about it ("no alerting/paging integration... proportionate, not TF2-19-scale") — I
    think the proportionality call for the *ingest logic* (don't hard-abort, don't page) is right,
    but "durable + queryable" alone doesn't clear the bar the PR's own language sets for itself.
    Cheapest fix that doesn't violate the proportionality principle: a second, tiny scheduled
    function (or even a `pg_cron` SQL job, no Edge Function needed) that runs weekly, does
    `select 1 from ingest_runs where stale order by run_at desc limit 1`, and sends one email via
    Supabase's built-in SMTP/webhook if any row matches — that's still "loud log line" tier
    effort, not TF2-19-tier infrastructure, but it closes the actual gap.
  - Owner: `@backend-data`

- **#2: A structurally-valid-but-wrong-shaped probe response is silently indistinguishable from "verified fresh"**
  - Where: `fetchLatestUpstreamRowAt()`, `index.ts:225-229`, and its caller at `index.ts:298-308`
  - What: `const latest = rows[0]?.latest; if (!latest) return null;` — if Socrata returns HTTP 200
    with a body that parses as valid JSON but doesn't have the expected `[{ latest: "..." }]`
    shape (empty array `[]`, an object instead of an array, the alias silently renamed/dropped by
    Socrata's query planner — this exact class of surprise is already documented as having bitten
    this very function once, per the `fetchPermitPage()` comment about the trailing-`Z` SoQL
    type-mismatch), the function returns `null` with **no exception thrown**. The caller's
    `try/catch` never fires (nothing threw), so `probeError` stays `null`, `isStale` stays `false`
    (its initialized value), and the persisted `ingest_runs` row ends up with
    `upstream_latest_row_at: null, stale: false, stale_days: null, notes: null` — which reads,
    from the table, identically to "we checked, and everything's fine," not "we couldn't tell."
  - Expected: per the task framing and the PR's own stated purpose, a legitimately-empty/-unusable
    result and a successfully-verified-fresh result must not collapse into the same row shape —
    that's the exact bug class (§ "legitimately empty vs. silently broken") this whole PR exists
    to eliminate, recreated one layer up inside the guard mechanism itself.
  - Repro: mock (or wait for) Socrata to return `[]` or `[{}]` for
    `$select=max(enteredon) as latest` against `tg4x-b46p` — the function completes with HTTP 200,
    `upstreamStale: false`, `staleDays: null`, and a clean-looking `ingest_runs` row, with zero
    indication anywhere that the freshness check didn't actually resolve to anything.
  - Owner: `@backend-data` — recommend `fetchLatestUpstreamRowAt` throw on the missing/malformed
    shape (same treatment as a non-`ok` HTTP status) rather than returning `null`, so the existing
    `probeError` path (which is already handled soundly, and does write an honest `notes` string
    into `ingest_runs`) catches it too.

- **#3: New freshness probe has no timeout, and the durable-log write is sequenced after it — so a stalled probe can prevent the very row this PR exists to guarantee**
  - Where: `fetchLatestUpstreamRowAt()` (`index.ts:219`, bare `fetch()`, no `AbortController`/
    `signal`) and the ordering at `index.ts:264-344` — the `ingest_runs` insert happens strictly
    after the freshness-probe `await`, in the same synchronous control flow.
  - What: if the probe's `fetch()` call stalls (TCP connect succeeds but no response ever arrives
    — a plausible failure mode distinct from the already-handled non-`ok`/malformed-JSON cases),
    the `await fetchLatestUpstreamRowAt(...)` never resolves or rejects. No code path in this
    function times it out. The invocation will hang until the Supabase Edge Function platform's own
    execution-time ceiling kills it — at which point the process is terminated externally, the
    `ingest_runs.insert()` a few lines later never executes, and no HTTP response is returned to
    the caller either. Note the main pins upsert (the function's actual job) already completed
    successfully before this point, so parking data is unaffected — but the observability write
    that this whole PR is built around is the thing that silently fails to happen in exactly this
    scenario.
  - Expected: a monitoring code path added specifically to catch silent failures should not itself
    be a new way for the run log to silently not get written. (Pre-existing `fetchPermitPage()` has
    the same missing-timeout pattern, but that's not new to this PR and its failure mode doesn't
    gate a *new* durability guarantee the way this one does.)
  - Repro: not reproduced live (would require injecting a stalled socket against the real Socrata
    endpoint, out of sandbox scope) — flagging as a code-reading finding, not empirically triggered.
  - Owner: `@backend-data` — recommend wrapping the probe `fetch()` in an `AbortController` with a
    short timeout (5-10s is plenty for a `count`/`max` aggregate query) so a stall degrades to the
    already-correct `probeError` path instead of hanging the whole invocation.

### 🟢 Minor / nit

- **#4: 10-day staleness threshold is asserted "generous" but not empirically checked against this dataset's own historical day-level gaps.** The investigation only computed monthly aggregates (`docs/qa/ft16-film-permit-feed-investigation.md` §2 table); it never queried the maximum historical gap between consecutive `enteredon` timestamps pre-2026-05 to confirm 10 days never occurred naturally (e.g. across a long weekend + holiday). Not disputing the number, just noting it's inferred from monthly cadence rather than measured directly — a two-line follow-up SoQL query (`$select=enteredon&$order=enteredon&$where=enteredon < '2026-05-07'`, diffed in a script) would turn this into a verified constant instead of a reasonable guess. Low risk either way given the ~9x margin claimed.
- **#5: `docs/tier1-open-data-ingest-spec.md` §9 Step 4's "Expected response shape" line (documented pre-existing, not touched by this diff) wasn't updated to mention `upstreamStale`/`staleDays`/`upstreamLatestRowAt`.** Step 7 (new, added by this PR) does correctly tell the operator to re-check for those fields, so this is a redundant/inconsistent doc statement rather than a functional gap — low value fix, mention only for completeness.

### 💡 Out of scope (logged, not fixed)

- Did not deploy the Edge Function or apply the SQL to any Supabase project, per explicit task
  constraint — the "does the guard actually alarm `stale: true` on the real, currently-frozen
  feed" claim was verified by reading the arithmetic (`now` ≈ 2026-08-11, last known `enteredon` ≈
  2026-05-07, well past the 10-day threshold) and cross-checking the investigation's live `curl`
  probe numbers, not by an actual live invoke. Not verified end-to-end live — Kevin's own Step 4
  re-run after deploy is the first genuine live confirmation and should be treated as such, not
  skipped as "QA already checked this."
- No local Postgres or Deno runtime available in this sandbox to literally execute the migration
  or boot the Edge Function; verified the SQL by manual read against established house patterns in
  `02-pins-schema.sql`/`02e-auto-resolve-trigger.sql`, and verified the TypeScript by running it
  through `tsc --noEmit` (see Smoke tests) rather than Deno's own checker.
- The filename collision with PR #69's `02f-block-scoped-restrictions.sql` and the pending
  `02f`→`02g` rename were explicitly called out as already-being-fixed and out of scope for this
  review, per the task; not evaluated further.

## Smoke tests run

- `git fetch origin backend-data/ft16-film-permit-feed`, pinned to local ref `qa-ft16-pin`
  (deleted after review), re-ran `git diff main...refs/heads/qa-ft16-pin --stat` twice ~3s apart to
  confirm no `FETCH_HEAD` race — identical 5-file, +532/-10 diff stat both times.
  → stable, trusted.
- Read the full `index.ts` diff hunk-by-hunk against `main`'s copy; confirmed `processPermit()` and
  the `pins` upsert/RPC-fallback block are byte-identical to `main`, not touched by this PR.
- Read `02f-ingest-runs.sql` in full; cross-checked its RLS-enable idempotency claim and
  no-explicit-grants-needed claim against the established pattern in
  `supabase/02-pins-schema.sql` and confirmed no other file in `supabase/` grants anything to
  `service_role` either (platform-provisioned bypass, not something migrations manage here).
- `git diff main...refs/heads/qa-ft16-pin --name-only` → confirmed `02d-ingest-cron.sql`
  (`upsert_filming_pin`) and `02-pins-schema.sql` (`pins`/`pins_with_author`) are absent from the
  diff — blast-radius claim independently verified, not trusted from the PR body.
- `grep -rn "slack|webhook|notify|alert" -i docs/ supabase/` → confirmed no proactive
  alerting/paging mechanism exists anywhere in the repo that would consume `ingest_runs` or the
  new log lines (basis for Finding #1).
- Ran the new `index.ts` through `tsc --noEmit` (TypeScript 7.0.2, `--target es2022 --lib
  es2022,dom --skipLibCheck`, installed fresh in the scratchpad, not the project's own toolchain)
  against both the `main` copy and the branch copy — identical error sets on both (only the
  expected `Deno`-global/`esm.sh`-remote-import errors, which are environmental and present
  pre-PR too), confirming the new code introduces zero additional type errors versus baseline.
- Traced `STALENESS_THRESHOLD_DAYS = 10` against the investigation's own numbers (`now` ≈
  2026-08-11, `max(enteredon)` ≈ 2026-05-07 → ~96 days stale) to confirm the guard's arithmetic
  would in fact evaluate `isStale = true` for the feed's current real state, if invoked today.
- Grepped `HANDOFF.md` for RLS conventions; confirmed "RLS enabled, zero policies = deny-all,
  service-role bypasses" is the established, documented pattern here, not a one-off judgment call
  by this PR.
- Did not run: live Edge Function invoke, live SQL apply, live `curl` against Socrata (explicit
  task constraint — no production changes); no sandbox Postgres/Deno runtime available for literal
  execution of either artifact.

## What's working

- The investigation itself (`docs/qa/ft16-film-permit-feed-investigation.md`) is genuinely
  rigorous: it independently re-confirmed the outage with live Socrata numbers, explicitly went
  looking for and ruled out a plausible alternative explanation (the "intentional embargo" theory)
  with real measurement rather than dismissing it, and did a real catalog search for a replacement
  feed before concluding none exists — including checking *why* the one lookalike candidate
  (`tvpp-9vvx`) would be wrong, not just that it existed.
- The proportionality reasoning (log + queryable table, not a hard abort, not a paging system) for
  a "missing map decoration" vs. TF2-19's "wrong parking-legality data" is the right frame, and is
  applied consistently through the code, the migration, and the spec doc.
- `02f-ingest-runs.sql` is a clean piece of schema work: correctly idempotent, correctly RLS'd,
  correctly decoupled (no FK) from app tables so it can't destabilize anything else, and its
  comments explain *why* each design choice was made rather than just what it does — makes this an
  easy APPLY.
- The main pins-upsert path is untouched and provably so; the entire staleness mechanism is
  additive and wrapped defensively enough that even its own failure modes (Findings #2/#3) degrade
  the *monitoring signal*, not the actual film-permit ingestion Kevin's users depend on.
- Good self-awareness in both the investigation doc and the PR body about scope (explicitly says
  "no alerting/paging integration" was a deliberate choice, not an oversight) — makes it easy to
  have the proportionality conversation in Finding #1 as a genuine judgment call rather than a
  gotcha.
