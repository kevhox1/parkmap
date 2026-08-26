# Community 2.0 Phase 0 Schema — QA Pass 1 — 2026-08-26

**Reviewed:** branch `backend/community-2.0-phase0` at `f20ae3be`, against
`docs/community-2.0-reconciliation-spec.md` §2 (§2.1–§2.13). Files: `supabase/03-community-2.0-schema.sql`
(538 lines), `supabase/03-community-2.0-test.sh` (333 lines), `supabase/02e-auto-resolve-trigger.sql`
(+6 comment-only lines — confirmed via `git diff`, zero functional change).
**Verdict:** 🔴 **FIX-THEN-MERGE** — do not apply to production as-is. Two independent, unbounded
reputation-farming vectors are directly exploitable via plain REST calls the moment this migration is
live, with no client UI required. Everything else in the file (enum handling, RLS, view recreation,
push-token privacy design, `claim_pin`, server-derived expiry, zone seeds) is solid and should not be
thrown out — the fix is scoped to §2.6/§2.8, not a rewrite.

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

## Acceptance criteria checklist

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

## Findings

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

### 🟢 Minor / nit

- **#4: pg_cron scheduling is sequenced before the critical `pins_with_author`/view-recreation section, not after it**
  - Where: `supabase/03-community-2.0-schema.sql:468-489` (pg_cron) precedes the "pins_with_author —
    append the three new columns" section at line 491.
  - What: if `create extension if not exists pg_cron;` or `cron.schedule(...)` ever fails on a given
    project (e.g. the extension isn't actually enabled, contrary to this file's assumption that it's
    "already enabled and in production use" — verified true today via `02d-ingest-cron.sql:17-18`, so
    current risk is low), the whole STEP 2 paste is one implicit transaction and rolls back —
    including the `pins_with_author` view recreation, which is the only thing that makes
    `position_fraction`/`leaving_minutes`/`claimed_by` reach any client at all. This is the exact
    "don't gate required functionality behind a risky section" lesson `02f` already learned and
    explicitly applied to its own file (moving required sections before its risky Storage section,
    per that file's Round 2 note #3). This file doesn't apply that same lesson to its own pg_cron
    section.
  - Expected: place the view-recreation / grant statements before the pg_cron section, or at minimum
    note the ordering risk explicitly (it currently isn't called out anywhere in the file).
  - Owner: `@backend-data`

- **#5: `soho` zone box's north edge overshoots Houston St by ~480m, contradicting its own inline comment**
  - Where: `supabase/03-community-2.0-schema.sql:117-118, 130` — `lat_max = 40.7280` for the `soho`
    box, with the comment "roughly Houston St (north)... to Canal St (south)". Houston St's actual
    latitude is ≈40.7237; 40.7280 is ≈0.0043° (≈480m) further north, into NoHo/Greenwich Village
    blocks that are not SoHo.
  - Expected: not a blocker — the spec (OQ-1) explicitly accepts rough bounding boxes and says
    "revisit if boxes visibly misclassify blocks in practice" — but worth a one-line fix now since the
    comment and the number disagree with each other, not just with the ground truth.
  - Owner: `@backend-data`

- **#6: `rate_limit_config.max_rows` column comment is fully overwritten, losing 02f's original documentation**
  - Where: `supabase/03-community-2.0-schema.sql:311-318` vs. `02f-block-scoped-restrictions.sql:714-715`.
  - What: `COMMENT ON COLUMN` replaces the entire prior comment, not appends. The new comment text is
    about the `ephemeral_report` key only; the original explanation of why `max_rows` exists for the
    `block_scoped_report` key (the delete-then-reinsert bypass class, 02f Round 4) is gone from the
    live schema's introspectable comment, recoverable only via `git blame` on 02f. Purely cosmetic —
    no functional change — but a future reader querying `pg_description` in the SQL Editor loses
    context this repo otherwise takes pains to preserve inline.
  - Owner: `@backend-data`

- **#7: Two-step enum-add run procedure is clear in the file, absent from the commit/PR body**
  - Where: `supabase/03-community-2.0-schema.sql:15-35` (excellent, unambiguous in-file instructions)
    vs. the commit message for `f20ae3be` (says "Kevin applies by hand," nothing about the STEP
    1/STEP 2 split).
  - What: Kevin only sees the two-step requirement if he opens and reads the file's header before
    pasting. Low actual risk — the file itself says single-paste is "very likely safe in practice,"
    and if it does fail, the error text plus the in-file recovery instructions are sufficient — but a
    one-line callout in the PR description ("run in two pastes — see file header") would remove any
    chance of Kevin discovering this only after an error mid-paste.
  - Owner: `@backend-data`

### 💡 Out of scope (logged, not fixed)

- **`search_path` unpinned on all 7 new `SECURITY DEFINER` functions.** Consistent with the
  pre-existing, already-accepted repo convention (`02f-block-scoped-restrictions.sql:48-50` explicitly
  calls this out as "pre-existing pattern... not a regression introduced here" for its own two
  `SECURITY DEFINER` functions). Traced every new function in this migration
  (`award_report_reputation`, `award_confirm_reputation`, `award_chat_reputation`,
  `award_accuracy_on_first_confirm`, `enforce_ephemeral_report_rate_limit`, `claim_pin`,
  `derive_pin_expiry`) — every table/object reference inside each is schema-qualified
  (`public.profiles`, `public.pins`, etc.), so the classic search-path-hijack privilege-escalation
  vector does not actually apply to any of them today. Flagging per the task's explicit ask, not
  because a live exploit path was found.
- **Test script doesn't exercise the delete+reinsert farming vector (Finding #1).** Not a defect in
  the script — spec §2.13's "at minimum" list didn't ask for this coverage — but now that this pass
  has found the vulnerability, the eventual fix should add a regression test for it.
- **`soho-les` remains the PWA's and an iOS test fixture's hardcoded zone id** (`index.html:7355`,
  `Tier3AuthReactionsTests.swift:270`). Expected, transitional state per spec §2.3 ("no new
  pins/messages *should* target this id" is a soft convention, not enforced in schema) — this is a
  Phase 1+ iOS/PWA wiring concern, not a Phase 0 backend defect.

## Smoke tests run

No live database access in this environment (per task constraints) — all verification is close
reading + reasoning, cross-referenced against the three schema files this migration depends on
(`01-mvp-schema.sql`, `02-pins-schema.sql`, `02f-block-scoped-restrictions.sql`, read in full) and a
`git diff origin/main...origin/backend/community-2.0-phase0 -- supabase/02e-auto-resolve-trigger.sql`
to confirm that file's change is comment-only (6 lines added, zero lines removed, no code touched).

- Traced every RLS policy and column-level GRANT/REVOKE touching `pins`, `votes`, `profiles`,
  `zone_messages`, `device_push_tokens` across all four schema files to build the actual effective
  privilege set for `anon`/`authenticated` — this is how Findings #1/#2 were found (the migration's
  own reward logic vs. the actual, already-permissive write surface it attaches to).
  - Diffed `pins_with_author` and `zone_messages_with_author`'s new `SELECT` lists column-by-column
    against their prior definitions (`02f:553-577`, `01-mvp-schema.sql:122-134`) — confirmed exact
    match plus correctly-appended new columns in both cases, no dropped columns.
  - Checked the iOS read path (`ios/WePark/WePark/Services/CommunityPinService.swift`) — confirmed the
    two live pin fetches use explicit column lists (not `*`), so they're unaffected either way, and
    confirmed `CommunityPin.gracefulDecode` (`CommunityPinService.swift:1091-1106`) already tolerates
    unknown `pin_type` values per-row without crashing the whole fetch — this migration's two new enum
    values will not break the live iOS app the moment they exist in the DB, even before Phase 1 ships
    the corresponding Swift enum cases.
  - Grepped `ios/` and `index.html` for `soho-les` / `zone_id` usage to check cross-codebase impact of
    the zone archival (Finding logged as out-of-scope, not a defect).
  - Read `02d-ingest-cron.sql` to confirm pg_cron/pg_net are genuinely already enabled in production
    (not just asserted) before assessing Finding #4's actual risk level.
  - Walked the full test script (`03-community-2.0-test.sh`) line by line — all 6 scenario assertions
    correctly verify the behavior they claim to (not just status codes; e.g. the expiry tests compute
    actual epoch deltas against the claimed override value with a reasonable tolerance).
- Did not attempt to run the test script (requires a live Supabase project; explicitly Kevin's task
  per both HANDOFF.md and the script's own header).
- Did not run any SQL syntax validator (no local Postgres/psql available in this environment) — all
  SQL correctness was verified by careful reading against known Postgres semantics (enum-add
  transaction rules, `CREATE OR REPLACE VIEW` append-only column-list semantics, ACL merge behavior
  for table-level vs. column-level grants — all independently re-derived, not just trusted from the
  file's own comments, and found to check out).

## What's working

- The two-step `ALTER TYPE ... ADD VALUE` split is exactly right and better-explained than the
  Postgres restriction actually requires — the in-file reasoning for *why* single-paste is "very
  likely safe but not guaranteed" is accurate and will save whoever hits the edge case real
  debugging time.
- `claimed_by`'s privilege lockdown is correctly reasoned and correctly implemented — deliberately
  left out of both column-level GRANT lists so only `claim_pin`'s `SECURITY DEFINER` context can ever
  set it, with a clear comment explaining why. This is the right pattern, applied correctly.
- `device_push_tokens`'s privacy design (zone-only location signal, no SELECT policy for any client
  role, silent-push-then-client-side-relevance-check architecture) directly and correctly closes the
  tension between "push needs some geo signal" and "never upload the user's exact parked location" —
  genuinely thoughtful design work, not just schema.
- View recreation (`pins_with_author`, `zone_messages_with_author`) correctly avoids the exact
  `p.*`-frozen-at-view-creation bug class this repo has hit twice before (FT-14, 02f) — explicit
  column lists, new columns appended at the end, verified byte-for-byte against the prior definitions.
- `derive_pin_expiry`'s handling of `leaving_soon`/`open_spot` correctly and unconditionally overrides
  any client-supplied `expires_at`, closing a real pre-existing gap (client-supplied expiry was
  previously trusted outright for every crowd pin) — verified against the test script's two
  tampered-payload assertions, both of which correctly exercise this.
- The test script itself is well-built: portable ISO8601 parsing (no BSD/GNU `date` divergence),
  meaningful tolerances on timing assertions instead of exact-match flakiness, and a best-effort
  cleanup pass that doesn't require the service-role key.

## Post-fix verification plan for Kevin

Do not apply this migration to production until Findings #1 and #2 are fixed. Recommended fix shape
(not prescriptive — `@backend-data`'s call): extend the same append-only-ledger pattern this repo
already uses for `block_scoped_report_log` — a `reputation_award_log(subject_id, source_table,
source_id, kind, created_at)` (or similar) that each award trigger checks/inserts against before
crediting, so a given `(pin_id, user_id, "confirm")` or `(pin_id, "report")` tuple can only ever pay
out once — plus either widen `enforce_ephemeral_report_rate_limit`'s scope to cover all `source='crowd'`
rows regardless of `lifespan`, or add a parallel guard for `sign_correction`/`block_note`. Finding #3
(policy idempotency) is a one-line `drop policy if exists` fix per policy. Re-review after the fix
lands; this pass's structural findings (#4–#7) do not need to block a merge on their own.
