# Regulars S3 (send-regular-push) QA — 2026-09-18

**Reviewed:** branch `backend/regulars-s3-push` at `0c37b0e6` (base `7fa96bab`), against
`docs/regulars-network-spec.md` §2.8/§2.9, `docs/regulars-roadmap.md`'s S3 row, and PR #112's own body
(resolved ambiguities section). Files: `supabase/functions/send-regular-push/index.ts` (new, 380
lines), `supabase/functions/_shared/apns.ts` (new, 256 lines), `supabase/functions/send-community-push/index.ts`
(modified, 444→277 lines), `supabase/08-regulars-push-trigger.sql` (new, 168 lines),
`supabase/08-regulars-push-trigger-test.sh` (new, 303 lines), `docs/regulars-roadmap.md` (+1 row),
`docs/open-items.md` (+1 row).

**Verdict: 🟡 FIX-THEN-MERGE — one doc-only blocking finding, everything else clean.**

## Summary

The code itself is solid: the `_shared/apns.ts` extraction is verifiably behavior-preserving (confirmed
by a direct line-by-line diff, not just trusting the PR's `tsc` claim), `send-regular-push` never
touches `pin_notes`, its targeting query is empirically safe against blocked/removed Regulars, and the
new trigger correctly mirrors `04`'s hard-won fail-open posture — all independently reproduced live on
a scratch Postgres 16 instance I stood up myself. The one real problem is not in the SQL or TypeScript,
it's in the **ceremony documentation**: I confirmed live that inserting a `leaving_soon` pin fires
`send-community-push` (zone-wide, instant, unmodified) and `send-regular-push` (visible, instant, new)
**in the same trigger execution, regardless of `regulars_head_start_seconds`'s value** — the "head
start" is completely inert until the still-unscheduled S1-follow-up session lands. The PR's own SQL
comments and PR body disclose this honestly, but the roadmap's actionable "Kevin gate at end" cell for
the S3 row (and the PR body's own numbered ceremony list) both omit any gate on S1-follow-up having
landed first — a real risk that Kevin, executing the documented steps literally, ships a real
production behavior change (new visible pushes to real Regulars) whose entire premise (Regulars-first)
does not yet exist. This is a one-paragraph doc fix, not a code fix.

## Acceptance criteria checklist

- [x] `send-regular-push` targets Regulars by `user_id` via `regular_edges`+`device_push_tokens`, not
  `zone_id` — verified by code read and by a live SQL-level proof that a blocked pair's edge is gone
  from the graph the function's own query reads.
- [x] Visible, content-bearing payload (`alert.title`/`alert.body`, `pushType:"alert"`, `priority:"10"`)
  — verified by code read against `_shared/apns.ts`'s `ApnsRequestSpec`.
- [x] `pin_notes` text is never read or included — verified: zero `.from("pin_notes")` call sites in
  `send-regular-push/index.ts` (grep-confirmed), only comments reference the table.
- [x] `_shared/apns.ts` extraction is behavior-preserving for the live `send-community-push` — verified
  by direct pre/post diff: identical `aps.content-available`/`pin_type`/`segment_id`/`pin_id`/`zone_id`
  body, identical `apns-push-type:"background"`/`apns-priority:"5"`, identical secret names, identical
  token/environment query, identical dead-token-classification and response-shape logic.
- [x] `08`'s trigger mirrors `04`'s Vault-read-inside-exception-block fail-open pattern — verified live:
  with `vault`/`net` schemas absent, a `leaving_soon` insert survives and logs a caught `vault_read`
  stage failure, never an aborted INSERT.
- [x] `08` does not modify `04`'s WHEN clause or add a cron job — verified: `git diff` on
  `04-community-push-trigger.sql` between base and this PR is empty; `08`'s own file has no
  `cron.schedule` call.
- [x] `07`→`08` apply cleanly and idempotently on a fresh scratch Postgres 16 — verified live (full
  chain `01→02→02b→02c→02d→02e→02f→02g→03→04→05→06→07→08` applied clean; `07`/`08` re-applied a
  second time back-to-back, zero errors).
- [x] A zero-Regulars author's `leaving_soon` insert is unaffected — verified live (insert survives,
  trigger still invokes `send-regular-push`'s endpoint per spec's "unconditional, cheap no-op" design).
- [x] A non-`leaving_soon` pin (`open_spot`) never fires `send-regular-push` — verified live (only a
  `send-community-push` log line appears for that insert).
- [x] `regulars_head_start_seconds` clamp `[60,3600]` still holds (S1 scope, re-verified since S3
  depends on it) — verified live: 59 and 3601 rejected, 60 and 3600 accepted.
- [x] No banned copy words (avoid/ticket/fine/evasion/dodge) in any generated string — verified by
  direct read of every template literal in `send-regular-push/index.ts`.
- [x] A blocked/removed Regular cannot receive a push — verified live: `regular_blocks` insert deletes
  the corresponding `regular_edges` row in the same transaction (existing S1 trigger), and the exact
  query `send-regular-push` runs against `regular_edges` for the (former) author returns zero rows
  post-block.
- [ ] **The eventual deploy/apply ceremony, as documented in this PR, cannot be safely executed as
  written without silently defeating the feature's entire premise.** FAILED — see Finding #1.

## The key semantic ruling — is the head start inert until §2.8 lands?

**Yes, ruled definitively, live-reproduced, not just read.** `04-community-push-trigger.sql` is
untouched by this PR (`git diff` confirms zero lines changed) — its WHEN clause
(`source='crowd' and lifespan='ephemeral' and zone_id is not null`) still fires
`pins_invoke_send_community_push` **synchronously, at INSERT time**, for every `leaving_soon` pin,
exactly as it does today. `08`'s new `pins_invoke_send_regular_push` trigger fires **immediately and
unconditionally** on the same `leaving_soon` insert (by design — "the whole point of head start," per
the file's own SCOPE NOTE). I inserted a `leaving_soon` pin with `regulars_head_start_seconds = 900`
(15 minutes) against my scratch instance with both triggers live, and both fired **in the same
statement**, logged within milliseconds of each other:

```
LOG:  send-community-push: vault_read stage failed for pin be98bdf8... (sqlstate 42P01): relation "vault.decrypted_secrets" does not exist
LOG:  send-regular-push: vault_read stage failed for pin be98bdf8... (sqlstate 42P01): relation "vault.decrypted_secrets" does not exist
```

Both triggers fired off the identical `pins` row, at the identical instant, regardless of the 15-minute
head start value. **Conclusion: if `07`+`08` are applied and both Edge Functions deployed today (before
the still-unscheduled S1-follow-up session lands its `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()`
cron job), a `leaving_soon` pin with a head start gives Regulars a new, visible, content-bearing push —
but the zone board sees the exact same pin, via the exact same silent push, at the exact same instant.
The head start delivers zero actual exclusivity. It is not broken in the sense of throwing an error or
corrupting data — it is broken in the sense that the feature's entire premise (§1.1: "hand my spot to
them specifically before strangers see it") does not exist yet, silently, with nothing to alert anyone
that it's inert.**

This is honestly disclosed in three places already — the PR body, `08`'s own SCOPE NOTE, and the test
script's Test 6 manual instructions (which literally predict "two rows" of `net._http_response` for
each `leaving_soon` insert once applied). **What's missing is the fourth place that actually matters:
the two *actionable* ceremony checklists** (`docs/regulars-roadmap.md`'s S3-row "Kevin gate at end"
cell, and the PR body's own "Kevin's ceremony" bullet list) both read:

> apply `07` → deploy `send-regular-push` and re-deploy `send-community-push` → apply `08` → run
> `08-regulars-push-trigger-test.sh`

— with **no mention of the S1-follow-up gate anywhere in that sequence.** Compare this to the roadmap's
own top-level "Kevin's ceremonies" section (unchanged by this PR, `docs/regulars-roadmap.md` line
~133), which correctly says deploying `send-regular-push` happens "once the S1-follow-up migration has
landed." The two sections of the *same document* now disagree with each other on whether that gate
exists, and the disagreement is in the direction that's easy to miss — the generic section is right,
the specific, doable-today checklist for this exact PR is silent. Since Kevin executes ceremonies from
the specific row, not the generic preamble, this is a real risk, not a hypothetical.

## Findings

### 🔴 Blocking

- **#1: The S3 ceremony (roadmap row + PR body) omits the S1-follow-up gate, which is required to make
  the head start real rather than decorative.**
  - Where: `docs/regulars-roadmap.md` S3 row, "Kevin gate at end" column; PR #112 body, "Kevin's
    ceremony" bullet list.
  - What: Both instruct Kevin to apply `07` → deploy `send-regular-push` (+ redeploy
    `send-community-push`) → apply `08` → run the test script, with zero mention that this sequence, on
    its own, ships a new production push whose defining feature (a head start before the zone-wide
    push) does not yet function — see the ruling above, live-reproduced.
  - Expected: Per the roadmap's own top-level "Kevin's ceremonies" section, deploying
    `send-regular-push`/applying `08` should be explicitly gated on the S1-follow-up migration (the
    `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` cron job, still "Not yet scheduled" per
    the roadmap's own S1-follow-up row) having already landed and been applied — or, at minimum, the
    ceremony must say in plain language that applying this PR's ceremony alone makes the head start a
    no-op and the zone board will see every `leaving_soon` pin instantly regardless of the chosen
    value, so Kevin can decide with full information rather than discover it from real usage.
  - Repro: Read `docs/regulars-roadmap.md`'s S3 row ceremony cell and PR #112's body's own numbered
    "Kevin's ceremony" list side by side with its "Kevin's ceremonies" top section — the two disagree.
    Live-reproduce the actual behavior with the steps in the ruling above.
  - Owner: `@backend-data` (this is a docs-only fix on files this PR already touches — add one
    explicit sentence to both locations before merge, no code change needed).

### 🟡 Significant

None. (The one item that came close — see the minor note on `08`'s WHEN-clause scope below — did not
clear the bar for "will cause a real bug," so it's logged as a nit instead, per this report's own
severity discipline.)

### 🟢 Minor / nit

- **`08`'s WHEN clause is looser than `04`'s.** `pins_invoke_send_regular_push` fires on
  `pin_type = 'leaving_soon'` alone; `pins_invoke_send_community_push` additionally requires
  `source='crowd' and lifespan='ephemeral' and zone_id is not null`. There is no DB-level CHECK tying
  `pin_type` to `lifespan`/`source` (confirmed by reading `02-pins-schema.sql`'s `pins_insert_crowd`
  policy, which only requires `source='crowd'`), so a hand-crafted `leaving_soon` insert with a
  non-`ephemeral` `lifespan` would fire `send-regular-push` but not `send-community-push`. This is
  explicitly called out as a deliberate choice in `08`'s own SCOPE NOTE ("keeping the SQL WHEN clause
  minimal... can never silently drift"), and the app's actual client code always sends
  `lifespan='ephemeral'` for `leaving_soon` — not exploitable beyond "send an extra push via a
  hand-crafted REST call," no privacy or data-integrity impact. Worth a one-line defensive-parity fix
  in a future pass, not blocking.
- **Zone-name-vs-street-name copy substitution** (`zones.name` instead of a street-level descriptor).
  The builder's own reasoning is sound — `segment_id` is an internal tile-index slug with no
  server-side geocoding path, and §2.9 gives one illustrative example, not a locked string. Flagging
  only so Kevin explicitly signs off on the copy quality call (not an engineering correctness issue).

### 💡 Out of scope (logged, not fixed)

- The actual S1-follow-up session (the `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` 30s
  cron job) remains unscheduled on the roadmap — already tracked as its own row, not this PR's job to
  build. Finding #1 is about the *documentation gap* around sequencing relative to that still-future
  session, not a demand to build it here.
- I could not re-run the PR's own `tsc --noEmit` structural-correctness check (no network access to
  install TypeScript in this sandbox) — I consider this a non-issue, since I substituted a strictly
  stronger check (a full manual line-by-line diff of `send-community-push/index.ts` before/after,
  confirming byte-identical wire behavior) rather than relying on either the builder's claim or a
  weaker proxy.

## Smoke tests run

All against a scratch Postgres 16 instance I stood up myself (`qa_pr112` database, not the builder's),
with an independently-written minimal Supabase-shape stub (`auth.users`/`auth.uid()` reading a session
GUC, `anon`/`authenticated` roles with default privileges, `supabase_realtime` publication) — no
`vault`/`net`/`pg_cron` schemas created, deliberately, to prove fail-open organically rather than fake
success:

- Applied the full chain `01→02→02b→02c→02d→02e→02f(minus its unrelated Storage section, which this PR
  does not touch)→02g→03→04→05→06→07→08`, stripping only `create extension pg_cron/pg_net` and
  `cron.schedule(...)` calls (unavailable in this sandbox) — **clean, zero errors.**
- Re-applied `07` and `08` a second time back-to-back — **idempotent, zero errors.**
- Confirmed `04-community-push-trigger.sql`'s diff against base is empty (`git diff 7fa96bab..0c37b0e6`)
  — the live trigger is untouched.
- Inserted a `leaving_soon` pin by an author with one Regular, `regulars_head_start_seconds=900` — both
  `send-community-push` and `send-regular-push` invocations logged in the **same statement**, both
  correctly caught by their own exception handler (`vault.decrypted_secrets` missing) — insert
  survived. This is the live proof behind the head-start ruling above.
- Inserted a `leaving_soon` pin by a zero-Regulars author — both triggers still fired (matches spec:
  the SQL trigger is unconditional, the Edge Function's own `regular_edges` lookup is what finds zero
  Regulars) — insert survived.
- Inserted an `open_spot` pin — only `send-community-push` fired; **zero** `send-regular-push` log line
  — WHEN-clause scope confirmed live, not just by reading it.
- `regulars_head_start_seconds` clamp: 59 and 3601 both rejected by
  `pins_regulars_head_start_seconds_check`; 60 and 3600 both accepted.
- Block-severs-edge + `pin_notes` RLS, end to end: created an edge between author (11) and a Regular
  (44); inserted a `pin_notes` row on the author's `leaving_soon` pin; confirmed (a) a non-Regular
  (`33`) sees zero rows, (b) the actual Regular (`44`) sees the row, (c) a *separate* Regular (`22`)
  who had already blocked the author earlier in the same session sees zero rows — RLS correctly
  reflects the post-block graph state, not a stale one.
- Direct diff read of `send-community-push/index.ts` pre/post-refactor: identical push body, headers,
  `apns-push-type`/`apns-priority`, secret names, token query, dead-token rule, response shapes.
- Direct read of every generated string literal in `send-regular-push/index.ts` for banned words
  (avoid/ticket/fine/evasion/dodge) — none present.
- Grepped `send-regular-push/index.ts` for any `pin_notes` query — zero hits outside comments.
- Read `docs/regulars-roadmap.md`'s S3 row + top-level ceremony section side by side — found the gap in
  Finding #1.
- **Not verified — recommend before Kevin's ceremony, not before merge:** `08-regulars-push-trigger-test.sh`
  itself was read but not executed (it targets a live Supabase project over anon-key REST, which this
  sandbox cannot reach — same limitation the script's own header documents). Live APNs delivery
  (S13-class, needs a real device) is out of scope for this pass, as it is for the PR itself.

## What's working

- The RLS/privacy design here is genuinely careful and — this pass confirms — correct in practice, not
  just on paper: block severs trust immediately and the push-targeting query and `pin_notes` RLS both
  reflect that live, with no stale-edge window I could find.
- The `_shared/apns.ts` extraction is exactly what it claims to be: a pure refactor, verified by direct
  diff rather than taken on faith, with zero behavior drift in the one function that's already live in
  production.
- The new trigger's fail-open posture is not just copied from `04`'s comment, it actually reproduces
  the correct control flow (Vault read inside the same exception block as the HTTP dispatch) — the
  exact class of bug PR #99 found is not repeated here.
- The targeting design (by `user_id`, not `zone_id`) is simple and matches the spec's own reasoning
  exactly, and the "unconditional trigger, function finds zero Regulars" split keeps the SQL side
  simple without sacrificing correctness.
- The PR's own honesty about the head-start-inert consequence (SQL comments, PR body, test script) is
  real and substantive — this is a case where the builder correctly identified and disclosed the exact
  risk this report is flagging; the gap is narrowly in the *actionable* ceremony text, not in the
  engineering judgment or the willingness to say the hard thing.
