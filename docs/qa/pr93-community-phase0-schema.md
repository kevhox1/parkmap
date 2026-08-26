# Community 2.0 Phase 0 Schema — QA Pass 1 — 2026-08-26

**Reviewed:** branch `backend/community-2.0-phase0` at `f20ae3be`, against
`docs/community-2.0-reconciliation-spec.md` §2 (§2.1–§2.13). Files: `supabase/03-community-2.0-schema.sql`
(538 lines), `supabase/03-community-2.0-test.sh` (333 lines), `supabase/02e-auto-resolve-trigger.sql`
(+6 comment-only lines — confirmed via `git diff`, zero functional change).
**Pass 1 verdict:** 🔴 **FIX-THEN-MERGE** — do not apply to production as-is. Two independent, unbounded
reputation-farming vectors are directly exploitable via plain REST calls the moment this migration is
live, with no client UI required. Everything else in the file (enum handling, RLS, view recreation,
push-token privacy design, `claim_pin`, server-derived expiry, zone seeds) is solid and should not be
thrown out — the fix is scoped to §2.6/§2.8, not a rewrite.
**Superseded by Pass 2 below — see final verdict there.**

## Summary

The migration is well-engineered on structure (idempotency guards, the two-step enum-add procedure,
explicit view column lists instead of `p.*`, column-level grant hygiene matching 02f's fail-closed
model) and gets the privacy-sensitive parts right (`device_push_tokens` has no SELECT policy,
`claimed_by` is correctly excluded from both client GRANT lists so only `claim_pin`'s `SECURITY
DEFINER` context can set it). But the new reputation triggers (§2.6) reward `INSERT`-time events
without any protection against replaying those inserts, and the rate-limit generalization (§2.8) does
not cover two of the seven crowd pin types. Combined, an authenticated (including anonymous-auth)
session can inflate `reputation`, `helped_count`, and `accurate_report_count` without bound via
ordinary, RLS-permitted REST calls — no bug, no auth bypass, just the documented API used in a loop.
This directly contradicts the task's own reasoning for why `block_scoped_report_log` (02f) exists,
which this file does not reuse or replicate for its own new triggers. A secondary, mechanical defect
(three ungated `CREATE POLICY` statements on the new `device_push_tokens` table, missing this
codebase's otherwise-universal `drop policy if exists` guard) breaks the file's own "safe to re-run"
claim on a second paste.

## Acceptance criteria checklist (Pass 1)

- [x] §2.1 `pin_type` enum additions — two-step STEP 1/STEP 2 split is unmistakable in the file header, and both `add value if not exists` statements are correctly isolated in STEP 1.
- [x] §2.2 `pins` columns + grants — `position_fraction`/`leaving_minutes` correctly added to the INSERT column grant; `claimed_by` correctly excluded from both INSERT and UPDATE grants (verified against 02f's fail-closed column-privilege model — only `claim_pin`'s `SECURITY DEFINER` context can set it).
- [x] §2.3 Zone seeds — `soho-les` archived (description updated, not deleted, preserving the `zone_messages` FK cascade concern); three new boxes inserted with `on conflict do update`. Minor geo nit — see Finding #5.
- [x] §2.4 Blockface-anchored chat — `segment_id` column + index added; `zone_messages_with_author` correctly recreated with the pre-existing 9-column list intact plus `segment_id` appended, verified column-by-column against `01-mvp-schema.sql:122-134`.
- [x] §2.5 `profiles` trust columns — `avatar`/`helped_count`/`accurate_report_count`/`total_report_count` added; `profiles_username_key` uniqueness constraint correctly dropped by its Postgres-default inferred name.
- [ ] §2.6 Reputation triggers — **FAILED.** Farmable without bound. See Findings #1, #2.
- [x] §2.7 "Gone" — correctly a no-op/documentation-only section; existing 3-dispute mechanism unchanged.
- [ ] §2.8 Rate limiting generalization — **PARTIAL.** `ephemeral_report` key correctly covers `lifespan='ephemeral'` pin types (incidentally also covers `open_spot`/`leaving_soon` since those are inserted with `lifespan='ephemeral'`), but `sign_correction`/`block_note` (durable crowd types) have zero rate-limit coverage from any trigger in this repo, and now carry a reputation reward with nothing bounding insert volume. See Finding #2.
- [x] §2.9 `device_push_tokens` — RLS/privacy design correct (no SELECT policy at all, `zone_id`-only location signal matches the spec's stated privacy design, insert/update/delete correctly scoped to `auth.uid() = user_id`, no cross-user enumeration path). **Idempotency FAILED** — see Finding #3.
- [x] §2.10 `claim_pin` RPC — single `UPDATE ... WHERE claimed_by IS NULL` is genuinely race-safe; `EXECUTE` correctly restricted to `authenticated`; no unqualified references (no `search_path`-hijack surface despite no explicit `SET search_path`).
- [x] §2.11 Server-derived `expires_at` — verified against the test script's tampered-payload assertions; `open_spot`/`leaving_soon` correctly ignore client-supplied `expires_at` unconditionally; `enforcement_active`/`sweeper_passed`/`broken_meter` left client-supplied, matching the spec's explicit "revisit once Phase 1 ships" deferral, not an oversight.
- [x] §2.12 pg_cron hygiene sweep — functionally correct (1-hour grace window, idempotent named job). Structural ordering nit — see Finding #4.
- [x] §2.13 Test script — all 6 documented scenarios (anon 403, tampered-expiry override ×2, confirmer reputation, 3-dispute resolve, claim_pin race) are present and each assertion actually verifies the claimed behavior, not just a status code. Coverage gap noted in Finding #1 (does not exercise the farming vector it should now test for).

## Findings (Pass 1)

### 🔴 Blocking

- **#1: Reputation/`helped_count`/`accurate_report_count` can be farmed without bound via vote delete + re-insert**
  - Where: `award_confirm_reputation()` (fires `after insert on public.votes`) and
    `award_accuracy_on_first_confirm()` (fires `after update of confirm_count on public.pins`),
    `supabase/03-community-2.0-schema.sql:223-297`.
  - What: `votes` has an unrestricted `votes_delete_own` policy (`02-pins-schema.sql:205-207`,
    unchanged by this migration) and `award_confirm_reputation` rewards every `INSERT` on `votes`
    unconditionally, with no ledger, no "already rewarded for this pin" check, and no cooldown. A
    session can: confirm a pin (+2 reputation, +1 `helped_count` to itself), `DELETE
    /rest/v1/votes?pin_id=eq.X&user_id=eq.me`, re-`POST` the same confirm vote (new row, same
    `(pin_id, user_id)` pair now free again), and repeat indefinitely. Each cycle also flips
    `pins.confirm_count` from 0→1 again (recomputed live by `refresh_pin_vote_counts`), which
    re-triggers `award_accuracy_on_first_confirm`'s `old.confirm_count = 0 and new.confirm_count = 1`
    guard on *every* cycle — so the same loop also farms the pin author's
    `accurate_report_count` unbounded. Nothing in `votes_insert_own`/`votes_delete_own` prevents a
    user from confirming their own pin, so a single account can do this entirely alone, with zero
    other participants, purely via REST calls (no app code path needed).
  - Expected: per spec §2.6 and the task's own explicit ask ("check... can't double-fire (vote
    changed/deleted?)... can't be driven negative or farmed (self-confirm own pin? confirm same pin
    twice...)"), the reward should fire at most once per `(pin_id, user_id, "confirm")` for the life
    of that relationship. This is exactly the bug class `block_scoped_report_log`
    (`02f-block-scoped-restrictions.sql:679-716`) was built in this same repo, three QA rounds deep,
    to close for a different trigger ("counting live rows lets delete-then-reinsert bypass a guard").
    This migration reproduces the identical anti-pattern fresh, unaddressed.
  - Repro: `POST /rest/v1/votes {pin_id, user_id, vote:"confirm"}` → 201, reputation +2. `DELETE
    /rest/v1/votes?pin_id=eq.<id>&user_id=eq.<id>` → 204. Repeat the `POST` → 201, reputation +2
    again. No error, no cap, confirmed reachable by both anon-auth and any authenticated session.
  - Owner: `@backend-data`
  - **Pass 2 status: FIXED. See below.**

- **#2: `award_report_reputation` (+5) has zero rate-limit coverage for `sign_correction`/`block_note`, making it unbounded spam**
  - Where: `award_report_reputation()` (`supabase/03-community-2.0-schema.sql:204-221`) fires on
    `after insert on public.pins` for any `source = 'crowd'` row, unconditionally on `pin_type`.
    `enforce_ephemeral_report_rate_limit()` (§2.8, same file, lines 343-384) only rate-limits rows
    where `lifespan = 'ephemeral'`. `enforce_block_scoped_rate_limit()` (`02f`) only rate-limits rows
    where `report_group_id is not null` (i.e. `filming`/`construction`). `sign_correction` and
    `block_note` are the Tier-2 crowd/durable types (`02-pins-schema.sql:23-25` comment) — `lifespan
    = 'durable'`, no `report_group_id`. They fall through *both* rate limiters entirely.
  - What: any authenticated session can `POST /rest/v1/pins {pin_type:"block_note", source:"crowd",
    lifespan:"durable", ...}` in a tight loop and gain +5 reputation and +1
    `total_report_count` per row, with no cap of any kind — not 20/hour, not 3/day, nothing. This is
    strictly more severe than pre-migration spam risk: before this PR, unlimited `block_note`/
    `sign_correction` inserts were a map-clutter nuisance with no reward attached; this PR attaches an
    unthrottled reputation payout to that same unthrottled insert path.
  - Expected: every reputation-earning crowd insert should be covered by *some* rate limit before the
    reward is wired up, per the task's explicit "can't be driven negative or farmed" ask and this
    repo's own established practice of never shipping a reward/abuse-relevant trigger without a
    corresponding rate-limit guard (see 02f's entire revision history).
  - Repro: any authenticated session, `POST /rest/v1/pins` with `pin_type=block_note` or
    `sign_correction`, `source=crowd`, `lifespan=durable`, repeated N times → 201 and +5 reputation
    each time, unthrottled.
  - Owner: `@backend-data`
  - **Pass 2 status: FIXED. See below.**

### 🟡 Significant

- **#3: `device_push_tokens`'s three RLS policies are not idempotent — re-running STEP 2 a second time will error**
  - Where: `supabase/03-community-2.0-schema.sql:416-421`.
  - What: `create policy device_push_tokens_insert_own ...` / `_update_own` / `_delete_own` have no
    `drop policy if exists` guard before them, unlike every other policy creation in this file and in
    `01-mvp-schema.sql`/`02-pins-schema.sql`/`02f-block-scoped-restrictions.sql` (all of which
    consistently do `drop policy if exists X on Y; create policy X ...`). Postgres has no `CREATE
    POLICY IF NOT EXISTS` syntax. A second paste of this file (or a partial re-run of STEP 2 after an
    unrelated failure elsewhere in STEP 2 — a realistic scenario for a hand-run production migration)
    will abort with `policy "device_push_tokens_insert_own" for table "device_push_tokens" already
    exists`.
  - Expected: the file's own header claims "Idempotent: safe to re-run on a clean or
    partially-applied project" — this is false for this section.
  - Repro: paste the full file's STEP 2 block twice into the SQL Editor in the same session. First run
    succeeds; second run fails at the first `CREATE POLICY` in this block.
  - Owner: `@backend-data`
  - **Pass 2 status: FIXED. See below.**

### 🟢 Minor / nit

- **#4: pg_cron scheduling is sequenced before the critical `pins_with_author`/view-recreation section, not after it.** **Pass 2 status: FIXED.**
- **#5: `soho` zone box's north edge overshoots Houston St by ~480m, contradicting its own inline comment.** **Pass 2 status: FIXED.**
- **#6: `rate_limit_config.max_rows` column comment is fully overwritten, losing 02f's original documentation.** **Pass 2 status: FIXED.**
- **#7: Two-step enum-add run procedure is clear in the file, absent from the commit/PR body.** **Pass 2 status: FIXED.**

### 💡 Out of scope (logged, not fixed)

- **`search_path` unpinned on all 7 new `SECURITY DEFINER` functions.** Consistent with the
  pre-existing, already-accepted repo convention. No live exploit path found (every reference is
  schema-qualified). Pass 2 added an explicit comment documenting this instead of leaving it
  unexplained — see below.
- **Test script doesn't exercise the delete+reinsert farming vector.** Logged, not fixed in Pass 2
  either (script is unchanged) — see Pass 2 residual notes.
- **`soho-les` remains the PWA's and an iOS test fixture's hardcoded zone id.** Expected, transitional
  state, Phase 1+ concern, not a Phase 0 defect.

---

# QA Pass 2 — 2026-08-26

**Reviewed:** branch `backend/community-2.0-phase0` at `b8800598` (fix commit "fix(backend): Community
2.0 Phase 0 — QA round 1 fixes", on top of `b3bd97f7`/`f20ae3be`), against Pass 1's 7 findings above
and a fresh top-to-bottom re-read of the full, current `supabase/03-community-2.0-schema.sql` (702
lines) and PR #93's live body (`gh pr view`). Diffed `b3bd97f7..b8800598` directly rather than trusting
the commit message's own account of what changed.

**Final verdict: ✅ MERGE.** All 7 Pass 1 findings are genuinely fixed, correctly and robustly — not
cosmetically. No new blocking or significant issues introduced by the fix. One pre-existing, low-value
residual gap remains (test script doesn't cover the two vectors that were just fixed) — logged as a
follow-up, not a merge blocker.

## Per-finding verification

**#1 — `reputation_award_log` ledger (blocking → FIXED, verified):**
- Unique key `(source_table, source_id, kind, subject_id)` correctly closes the replay loop for both
  triggers. For `'confirm'`: `subject_id` = voter, `source_id` = `pin_id` — each distinct voter still
  earns their own row on the same pin (correct — multiple confirmers should each be credited), but the
  *same* voter re-confirming the *same* pin after a delete+reinsert now hits the unique constraint.
  Traced the delete+reinsert cycle end to end: cycle 1 → ledger insert succeeds (`row_count=1`) → +2
  rep / +1 `helped_count`. Vote deleted (`votes_delete_own`, unrestricted, unchanged) — the ledger row
  is **not** cascade-deleted (`reputation_award_log` has no FK/cascade tie to `votes`, by design, per
  its own comment). Cycle 2 → re-insert the same vote → ledger insert **conflicts** (`ON CONFLICT ...
  DO NOTHING`, `row_count=0`) → the `if v_inserted > 0` guard skips the payout entirely. **Nets zero on
  the second and every subsequent cycle**, confirmed by code trace (no live DB needed to verify this —
  the logic is deterministic and fully schema-qualified).
- For `'accuracy'`: `subject_id` = `new.author_id`, `source_id` = `new.id` (the pin) — a plain
  `(pins, pin_id, accuracy)` key regardless of which voter or how many delete/reinsert cycles produced
  the 0→1 `confirm_count` transition. The guard changed from `new.confirm_count = 1` to `>= 1`; traced
  why this is still safe: `refresh_pin_vote_counts` recomputes `confirm_count` from a full recount on
  every single votes-table mutation, and each mutation's own `AFTER` trigger fires serialized against
  the pins row's lock — two near-simultaneous confirms from different voters cannot both observe
  `old.confirm_count = 0`; the second one's `old` value is already `1`. The `>=1` widening is
  defensive, not load-bearing, and introduces no new gap.
- **Atomicity/ordering:** confirmed the ledger `INSERT ... ON CONFLICT DO NOTHING` runs *before* the
  payout, gated by `GET DIAGNOSTICS v_inserted = row_count` immediately after — this is the correct
  check-then-act order (a conflict skips the payout; the payout is never attempted, then rolled back,
  on conflict). Both statements execute inside the same trigger invocation, itself inside the same
  transaction as the outer `INSERT`/`UPDATE` — no separate-transaction race window exists.
- **One-way model documented:** yes, extensively — both in the table-level comment and inline above
  `award_confirm_reputation`, with an explicit, reasoned rejection of a symmetric decrement model
  (correctly identifies that decrementing on vote-delete reopens the identical farming shape in
  reverse, and is harder to prove safe under concurrent voters).
- **Ledger RLS/grants:** `alter table ... enable row level security;` with **zero** policies defined
  (no select/insert/update/delete for any role) — deny-all by omission, identical posture to
  `rate_limit_config`/`block_scoped_report_log` in 02f. No `grant` statement of any kind targets
  `anon`/`authenticated` on this table. Confirmed clients cannot read or write it directly; only the
  `SECURITY DEFINER` trigger functions (which bypass RLS as the function owner) ever touch it.
- **Self-confirm still possible** (nothing prevents an author from confirming their own pin) — but this
  is now a **one-time** +2/+1/+1(accuracy) event per pin, not an unbounded farm. That residual is
  product-acceptable (a real, if minor, single-shot reward for confirming your own report) and was not
  what Finding #1 was about — the *unboundedness* is what's fixed, and it is.

**#2 — `enforce_crowd_report_rate_limit` (blocking → FIXED, verified):**
- Skip condition `new.source != 'crowd' or new.report_group_id is not null` correctly exempts exactly
  the rows 02f's `enforce_block_scoped_rate_limit` already owns (in practice, `report_group_id is not
  null` ⟺ `source='crowd' and pin_type in (filming, construction)`, enforced by
  `pins_block_scoped_report_group_required_chk` — no other write path in this repo sets
  `report_group_id`) — confirmed **no double-gating** of 02f's rows.
- Every remaining `source='crowd'` insert buckets into exactly one of two keys by `lifespan`:
  `ephemeral_report` (`lifespan='ephemeral'`: `enforcement_active`/`sweeper_passed`/`broken_meter`/
  `open_spot`/`leaving_soon`) or `durable_crowd_report` (everything else non-block-scoped, i.e.
  `sign_correction`/`block_note` today). Traced that a hypothetical crowd `filming`/`construction` row
  *without* `report_group_id` can't reach this trigger's uncovered branch at all — the `NOT VALID` `..
  _required_chk` constraint (02f) rejects such a row outright before this trigger's logic would matter.
  **No type slips both nets.**
- Both config keys confirmed seeded exactly as specified: `('ephemeral_report', 20, 1, 60)`,
  `('durable_crowd_report', 10, 24, 30)` — `on conflict (key) do nothing`, matching the
  "retune by row update, not migration" philosophy.
- Fallback constants in the trigger body (`20`/`1` and `10`/`24`) match the seeded values, so a missing
  config row degrades to the same effective limits, not a silent bypass.
- Re-verified the previously-accepted, still-present gap (`BEFORE INSERT` only, not `OR UPDATE` — an
  author could insert then `UPDATE lifespan` to move buckets) is explicitly documented as an accepted,
  intentionally-out-of-scope gap, consistent with 02f's own "known limitation" style — not new, not
  silently introduced.

**#3 — `device_push_tokens` idempotency (significant → FIXED, verified):**
- All three policies (`_insert_own`, `_update_own`, `_delete_own`) now have a `drop policy if exists`
  immediately before each `create policy`, matching the rest of the file/repo exactly.
- **Re-walked the entire 702-line file top to bottom** (not just the diff) checking every DDL/DML
  statement for idempotency, per the coordinator's explicit ask given content moved: every `create
  table`/`create index` uses `if not exists`; every `create or replace function`/`view` is
  inherently idempotent; every `create trigger` is preceded by its own `drop trigger if exists`
  (including the new `pins_enforce_ephemeral_report_rate_limit` **and**
  `pins_enforce_crowd_report_rate_limit` drops, both present, so a project that had partially applied
  Pass 1's version would clean up correctly too); every `create policy` now has its `drop policy if
  exists`; `alter table ... add column if not exists` / `drop constraint if exists` / `enable row
  level security` are all natively idempotent; `insert ... on conflict do update/do nothing` is used
  for every seed row (`zones`, `rate_limit_config`); `grant`/`revoke` statements are naturally
  idempotent in Postgres; `comment on ...` always succeeds (replaces text, never errors);
  `create extension if not exists pg_cron` is guarded; `cron.schedule(...)` with a fixed job name
  updates in place. **No other non-idempotent statement found.** The file's "safe to re-run" claim now
  holds in full.

**#4–#7 (nits → all confirmed FIXED):**
- **#4:** `§2.12` (pg_cron) is now the last section in the file, after `pins_with_author`'s view
  recreation — confirmed by line order (view recreation ends line 664; `create extension ...
  pg_cron` starts line 680). A `cron.schedule` failure would now roll back only itself plus the
  test-script pointer comment, not any client-facing column exposure.
- **#5:** `soho`'s `lat_max` corrected from `40.7280` to `40.7237` (Houston St's actual latitude),
  now consistent with its own "roughly Houston St (north)" comment.
- **#6:** `rate_limit_config.max_rows`'s comment now preserves 02f's original text verbatim (the
  `block_scoped_report` explanation, word for word) with a new paragraph appended for the two new
  keys, rather than replacing it.
- **#7:** PR #93's live body (`gh pr list --json body`) now has an explicit "What Kevin needs to do"
  section, step 2 of which spells out the two-paste procedure in the PR description itself, not just
  the file header.

## New-issue check (explicitly requested by the coordinator)

- **Function/trigger rename (`enforce_ephemeral_report_rate_limit` → `enforce_crowd_report_rate_limit`,
  trigger `pins_enforce_ephemeral_report_rate_limit` → `pins_enforce_crowd_report_rate_limit`): no
  dangling references found.** Grepped the entire repo (`*.sql`, `*.sh`, `*.swift`) for the old
  function/trigger names — zero hits outside the new file's own defensive `drop trigger if exists
  pins_enforce_ephemeral_report_rate_limit on public.pins;` (a correct, harmless no-op/cleanup line
  for anyone who had partially applied the Pass 1 version — which nobody has, since this migration has
  never been applied to production, per both the file header and the commit messages).
  `supabase/03-community-2.0-test.sh` was not modified by the fix commit (`git diff` shows zero
  changes to it) and never referenced internal function/trigger names to begin with (it only hits
  PostgREST endpoints) — the rename is fully invisible to it, no update was needed, confirmed by
  re-reading the full script.
- **Old function object `enforce_ephemeral_report_rate_limit()` itself is never explicitly
  `DROP FUNCTION`'d** — a purely theoretical concern (would only matter if Pass 1's version had ever
  been applied to a real project first, which is confirmed not to have happened). Not flagged as a
  finding; noting only because the coordinator asked about dangling references specifically.
- No other renames, signature changes, or removed objects in the diff — `claim_pin`, `derive_pin_expiry`,
  `award_report_reputation`, `award_chat_reputation` are all textually unchanged from Pass 1 (confirmed
  via diff — only new comments were added near them, no logic changes), so nothing else needed
  cross-file updates.

## Residual, non-blocking observations

- **💡 Test script still doesn't exercise either fixed vector.** `03-community-2.0-test.sh` is
  byte-for-byte unchanged. Running it after Kevin applies this migration will pass, but it would not
  have caught Pass 1's bugs, and won't catch a future regression of either fix (e.g., someone later
  "simplifying" the ledger check). Recommend a fast-follow adding: (a) a confirm→delete→reconfirm loop
  asserting reputation stays at +2 total, not +4; (b) a `block_note`/`sign_correction` insert loop
  asserting a 42501 after the `durable_crowd_report` cap. Not a merge blocker — the fix's correctness
  was verified by direct code trace, and the original spec (§2.13) didn't ask for this coverage either.
- **💡 `search_path` still unpinned** on all `SECURITY DEFINER` functions — Pass 2 added an explicit
  comment acknowledging this as an accepted, pre-existing repo convention rather than fixing it. This
  matches the Pass 1 recommendation exactly ("leave as-is item" was the correct call, not a missed fix).

## Smoke tests run (Pass 2)

- `git diff b3bd97f7..b8800598 -- supabase/03-community-2.0-schema.sql supabase/03-community-2.0-test.sh`
  — read in full, twice (once as a diff, once by reading the resulting file end to end) to avoid
  trusting the commit message's own summary of what changed.
- Full top-to-bottom read of the resulting 702-line `supabase/03-community-2.0-schema.sql` (not just
  the diff hunks) specifically to satisfy the coordinator's "re-walk the whole file, content moved"
  ask for idempotency.
- `gh pr list --head backend/community-2.0-phase0 --json body` to verify Finding #7 against the actual
  live PR body, not an assumption about what the commit message implies the PR body says.
- Repo-wide grep for the old rate-limiter function/trigger names across `*.sql`/`*.sh`/`*.swift` to
  confirm no dangling reference survived the rename.
- No live database access (same constraint as Pass 1) — the ledger's atomicity and the delete+reinsert
  "nets zero" claim are verified by deterministic code trace (Postgres `INSERT ... ON CONFLICT DO
  NOTHING` + `GET DIAGNOSTICS row_count` semantics are well-defined and were reasoned through
  explicitly, not assumed), not by executing it against a real Postgres instance.

## What's working (carried forward + Pass 2 additions)

Everything praised in Pass 1 stands unchanged (two-step enum split, `claimed_by` lockdown,
`device_push_tokens` privacy design, both view recreations, `derive_pin_expiry`, the test script's
existing 6 assertions). New in Pass 2: the `reputation_award_log` fix is not a minimal patch — it's
correctly generalized (works for both `confirm` and `accuracy` kinds via one shared table/shape),
correctly reasoned about the one-way-vs-symmetric tradeoff instead of reflexively building a decrement
path, and the rate-limiter widening is genuinely a generalization (two independently tunable keys) not
a hacky one-off carve-out for the two types QA happened to name. Both fixes read as understanding *why*
Pass 1's findings were bugs, not just patching the literal repro.
