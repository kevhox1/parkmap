-- DRAFT — DO NOT APPLY (Kevin applies at this row's own gate, per the ceremony order below)
--
-- WePark Regulars network — S1-follow-up: make the Regulars head start REAL
-- Spec: docs/regulars-network-spec.md §2.8 ("Tiered push delay — reuse send-community-push unchanged;
-- only the TIMING of its trigger changes for leaving_soon"). Sequencing: docs/regulars-roadmap.md,
-- "S1-follow-up" row.
--
-- WHY THIS FILE EXISTS (read this first): PR #112's QA (docs/qa/pr112-regulars-s3-push.md, live-
-- reproduced on a scratch Postgres 16 instance) proved that with 04-community-push-trigger.sql
-- unmodified, inserting a leaving_soon pin fires send-community-push (zone-wide, silent, instant) AND
-- send-regular-push (Regulars, visible, instant) IN THE SAME STATEMENT, regardless of
-- regulars_head_start_seconds's value. The "head start" — the entire premise of Regulars (spec §1.1:
-- "hand my spot to them specifically before strangers see it") — is completely inert until this file's
-- two pieces land: (1) the 04 WHEN-clause rewrite that STOPS the immediate zone-wide push for a
-- leaving_soon pin with a real head start, and (2) the sweep that fires it LATER, once the head start
-- has elapsed. Both pieces ship together in this one file because they are two halves of a single
-- behavior change — landing (1) without (2) would mean a head-start pin NEVER gets a zone-wide push at
-- all (a real regression, not just an inert feature), and landing (2) without (1) is a no-op (the sweep
-- would find zone_pushed_at already irrelevant, since 04 already pushed at insert).
--
-- Proposed by @backend-data 2026-09-18. NOT yet applied to production.
--
-- ============================================================================================
-- APPLY ORDER — 07 -> 09 (this file) -> 08, not the roadmap's originally-sketched 07 -> 08 -> ...
-- ============================================================================================
-- 1. supabase/07-regulars-schema.sql MUST already be applied. This file's rewritten WHEN clause reads
--    pins.regulars_head_start_seconds (07 §S1-1), and the sweep function reads that column plus
--    pins.zone_pushed_at (also 07 §S1-1). Applying this file before 07 fails outright (undefined
--    column) — a hard dependency, same class as 08's own hard dependency on 07's regular_edges table.
-- 2. THIS FILE (09) must be applied BEFORE supabase/08-regulars-push-trigger.sql is applied and before
--    the send-regular-push Edge Function is deployed. This is the opposite of "no ordering
--    requirement" — it is the exact fix for the PR #112 QA finding. Reasoning: 08's new
--    pins_invoke_send_regular_push trigger fires immediately and unconditionally on every qualifying
--    leaving_soon insert BY DESIGN (spec §2.9: "the whole point of head start" is that Regulars hear
--    first). For that to mean anything, the zone-wide push must NOT also fire at that same instant —
--    which is exactly what this file's WHEN-clause rewrite (Section A) guarantees. If 08 were applied
--    first (or at the same time, with no ordering statement), there would be a window — however short
--    — where a leaving_soon pin with a head start gets an immediate, visible Regulars push AND an
--    immediate, silent zone-wide push, i.e. exactly the inert state QA already proved live. Applying
--    09 first closes that window before 08's new push path ever goes live, so Regulars-first is true
--    from the moment send-regular-push is deployed, not eventually true once someone remembers to also
--    apply 09. docs/regulars-roadmap.md's S3 gate cell already states this ordering in prose; this file
--    is the thing that gate is waiting on.
-- 3. Deploy no new Edge Function for this file — Section A/B both call the ALREADY-DEPLOYED
--    send-community-push function, unmodified (spec §2.8: "No new Edge Function is needed for the
--    'falls through to the zone board' half — it is the exact same send-community-push function").
-- Full ceremony once this file's own QA clears: apply 07 (if not already) -> apply THIS FILE (09) ->
-- verify the sweep cron job is registered and has run at least once successfully -> deploy
-- send-regular-push + re-deploy send-community-push -> apply 08 -> run 08-regulars-push-trigger-test.sh.
-- See docs/regulars-roadmap.md's updated S1-follow-up row and S3 gate cell for the canonical statement.
--
-- Depends on:
--   07-regulars-schema.sql        — pins.regulars_head_start_seconds / pins.zone_pushed_at (§S1-1)
--   04-community-push-trigger.sql — the LIVE pins_invoke_send_community_push trigger this file rewrites
--                                    the WHEN clause of; internal.invoke_send_community_push() itself
--                                    is NOT modified (see Section A's own note on why the diff is
--                                    intentionally this small)
--   02d-ingest-cron.sql            — pg_cron/pg_net already enabled, `internal` schema already created,
--                                    Vault secret 'service_role_key' already provisioned — zero new
--                                    one-time setup for Kevin beyond applying this file
--
-- Idempotent: safe to re-run on a clean or already-applied project (drop-then-create trigger, create-
-- or-replace function, cron.schedule with a fixed job name replaces rather than duplicates — same
-- convention as every prior migration in this repo, incl. 02d's 'ingest-film-permits' job and 03's
-- 'community-pin-expiry-hygiene-sweep' job).
--
-- ============================================================================================
-- CRON CADENCE — 30 SECONDS IS SUPPORTED, but NOT via the spec's literal pseudocode syntax
-- ============================================================================================
-- Spec §2.8's pseudocode wrote `select cron.schedule('sweep-leaving-soon-zone-push', '*/30 * * * * *',
-- ...)` — a 6-field "cron-with-seconds" string. THIS IS NOT VALID pg_cron SYNTAX. Verified against
-- pg_cron's own README (citusdata/pg_cron) and Supabase's pg_cron extension docs: pg_cron's seconds-
-- based scheduling is a SEPARATE, dedicated form — the schedule argument is the literal string
-- '<1-59> seconds' (e.g. '30 seconds'), not a 6-field crontab extension, and "you cannot use seconds
-- with the other time units." This has been supported since pg_cron 1.5; Supabase ships pg_cron 1.6.4+
-- project-wide (pg_cron is already enabled and load-bearing on this project per 02d-ingest-cron.sql,
-- so no new extension-enablement risk here — only the schedule-STRING needs correcting from the
-- spec's pseudocode). Section B below uses the correct '30 seconds' form, achieving the spec's own
-- stated 30-second cadence — no fallback to a 1-minute cadence is needed. Flagging this as a spec-
-- pseudocode correction, not a scope deviation: the spec's INTENT (30s cadence) is delivered exactly;
-- only the literal syntax it sketched was wrong.
--
-- ============================================================================================
-- SCOPE NOTE — one deliberate, named deviation from §2.8's literal pseudocode (read before reviewing)
-- ============================================================================================
-- §2.8's pseudocode has the sweep pick up EVERY leaving_soon pin, including ones with
-- regulars_head_start_seconds IS NULL, via `coalesce(regulars_head_start_seconds, 0)` (a null head
-- start wait()=0, so the sweep's first ~30s pass would push it). This file does NOT do that — per this
-- session's own task framing (confirmed against the spec's actual product intent, §1.2a: a head start
-- is "only meaningful for leaving_soon" pins that HAVE one): Section A's rewritten WHEN clause only
-- withholds the immediate push when regulars_head_start_seconds IS NOT NULL AND > 0 — a null-head-start
-- leaving_soon pin (poster has zero Regulars, or chose no head start) keeps firing
-- pins_invoke_send_community_push SYNCHRONOUSLY AT INSERT, byte-identical to today, exactly as it does
-- right now in production. The sweep function (Section B) therefore only ever needs to scan pins that
-- explicitly opted into a head start, not every leaving_soon pin ever inserted. This is strictly
-- better than the literal pseudocode for two independent reasons, not just a style preference:
--   1. Zero added latency for the common case. The large majority of leaving_soon pins today (author
--      has no Regulars, or Regulars are still dark-shipped/disabled) get the exact same push speed
--      they get today — nothing about this migration makes an ordinary crowd report slower.
--   2. Smaller, cheaper, more targeted sweep. Every 30-second poll only has to examine leaving_soon
--      rows that were inserted with a real head start, not the full leaving_soon table — a smaller
--      candidate set is easier to reason about under the "first sub-minute cron job in this repo"
--      risk the spec's own §8 names.
-- Net behavioral result for a null-head-start pin is IDENTICAL either way (immediate push, whether
-- delivered by 04's trigger today or by a sweep's first ~0-wait pass under the literal pseudocode) —
-- this is a mechanism change, not a product-behavior change, and is called out here explicitly as a
-- resolved ambiguity for @qa-verifier / @tech-lead to confirm against the spec text rather than
-- silently diverging.

-- ============================================================================================
-- Section A — 04-community-push-trigger.sql's pins_invoke_send_community_push: WHEN-clause rewrite
-- ============================================================================================
-- BEFORE (04-community-push-trigger.sql, live in production today):
--   when (new.source = 'crowd' and new.lifespan = 'ephemeral' and new.zone_id is not null)
--
-- AFTER (this file):
--   when (
--     new.source = 'crowd' and new.lifespan = 'ephemeral' and new.zone_id is not null
--     and not (
--       new.pin_type = 'leaving_soon'
--       and new.regulars_head_start_seconds is not null
--       and new.regulars_head_start_seconds > 0
--     )
--   )
--
-- PROOF this is provably unchanged for every case except "leaving_soon WITH a positive head start":
-- the new clause is the OLD clause AND-ed with one new NOT(...) term. That term's inner condition can
-- only be true when pin_type = 'leaving_soon' AND regulars_head_start_seconds is both non-null and
-- positive — for every other pin_type (enforcement_active, sweeper_passed, open_spot, broken_meter,
-- and any future ephemeral crowd type), the inner condition is unconditionally false regardless of any
-- other column value, so NOT(false) = true, and the new clause reduces exactly to the old clause — zero
-- change. For a leaving_soon pin with regulars_head_start_seconds IS NULL (no Regulars, or Regulars
-- disabled — today's only possible state for every leaving_soon pin ever inserted, since 07 has not
-- shipped a client write path yet), the inner condition is again false (first sub-condition alone is
-- enough), so the new clause again reduces exactly to the old clause — zero change, matching the SCOPE
-- NOTE above. The ONLY case where the new clause diverges from the old one is pin_type = 'leaving_soon'
-- AND regulars_head_start_seconds is not null AND > 0: there, the inner condition is true, NOT(true) =
-- false, the whole AND collapses to false, and the trigger does not fire at insert — deferred to
-- Section B's sweep instead. This is the entire behavior change, and it is provable by inspection of
-- the WHEN clause alone, without needing to trust the function body (which is untouched — see below).
--
-- internal.invoke_send_community_push() ITSELF IS NOT MODIFIED by this file — zero lines of that
-- function change. Only the trigger's WHEN clause changes, which is why this diff is a drop-then-
-- create TRIGGER statement, not a CREATE OR REPLACE FUNCTION. Keeping the function body untouched
-- means the only thing to audit for correctness is the WHEN clause above, not a second copy of the
-- Vault-read/pg_net/fail-open logic — smaller, more provable diff for a trigger that is live in
-- production today.
--
-- ATOMICITY: the DROP TRIGGER + CREATE TRIGGER pair below executes as two statements inside the same
-- implicit SQL-Editor paste transaction (same posture 02-pins-schema.sql's own STEP-2 comment already
-- documents for this repo's migration convention) — there is no window where the live pins table has
-- NO pins_invoke_send_community_push trigger at all; Postgres does not release the DDL lock on `pins`
-- between the DROP and the CREATE within one transaction, so a concurrent INSERT either sees the old
-- trigger (transaction not yet committed) or the new one (committed) — never neither.
drop trigger if exists pins_invoke_send_community_push on public.pins;
create trigger pins_invoke_send_community_push
  after insert on public.pins
  for each row
  when (
    new.source = 'crowd' and new.lifespan = 'ephemeral' and new.zone_id is not null
    and not (
      new.pin_type = 'leaving_soon'
      and new.regulars_head_start_seconds is not null
      and new.regulars_head_start_seconds > 0
    )
  )
  execute function internal.invoke_send_community_push();

comment on trigger pins_invoke_send_community_push on public.pins is
  'Fires the existing, unmodified send-community-push Edge Function immediately at INSERT for every '
  'ephemeral crowd pin EXCEPT a leaving_soon pin that was posted WITH a positive Regulars head start '
  '(spec §2.8) — that one case is deferred to sweep_leaving_soon_zone_push() below (Section B), which '
  'fires the SAME Edge Function once the head start has elapsed and stamps pins.zone_pushed_at. '
  'Rewritten by supabase/09-regulars-zone-push-delay.sql, 2026-09-18, superseding '
  '04-community-push-trigger.sql''s original WHEN clause (still readable there, unchanged, for history) '
  '— see this file''s Section A comment for the line-by-line proof that every non-head-start case is '
  'byte-identical to the pre-existing behavior.';

-- ============================================================================================
-- Section B — sweep_leaving_soon_zone_push(): the delayed half of the zone-wide push (spec §2.8)
-- ============================================================================================
-- Race-safety mechanism: SELECT ... FOR UPDATE SKIP LOCKED. Two overlapping sweep runs (pg_cron does
-- not itself guarantee non-overlapping invocations of the same job if one run takes longer than the
-- schedule interval) must never both dispatch a push for the same pin. SKIP LOCKED means a second,
-- concurrently-running sweep simply skips any row the first sweep's cursor has already locked, rather
-- than blocking on it — the first sweep will stamp zone_pushed_at (see below) before its transaction
-- commits and releases the lock, so by the time any other sweep could see that row again, it is already
-- filtered out by `zone_pushed_at is null`. This is the same "single-writer-wins via a row lock" SHAPE
-- 07's redeem_regular_invite() already uses for a different race (SELECT ... FOR UPDATE there; SKIP
-- LOCKED added here on top, because unlike a single-token redemption, this sweep processes a WHOLE SET
-- of rows per invocation and must not block a second concurrent sweep's unrelated rows just because one
-- row is mid-dispatch).
--
-- Fail-open, not fail-closed — identical posture and identical bug class already fixed twice in this
-- repo (04's Finding #1, 08's verbatim copy of the fix): the Vault read, the null-check, AND the
-- net.http_post call for EACH candidate pin all sit inside ONE begin/exception block, so a Vault or
-- pg_net failure on one pin logs and moves on to the next pin in the same sweep invocation, and never
-- aborts the whole sweep (which would otherwise leave every remaining candidate pin unswept until the
-- next 30-second tick — itself not catastrophic given the 30s cadence, but strictly worse than handling
-- it per-row).
--
-- STAMP-ON-ATTEMPT, NOT STAMP-ON-CONFIRMED-DELIVERY: zone_pushed_at is set to now() immediately after
-- the dispatch ATTEMPT for a given pin, whether that attempt threw (Vault/pg_net failure, caught above)
-- or succeeded in getting a pg_net request_id back — matching the EXACT one-shot, fire-and-forget
-- semantics 04's own live trigger already has today (it does not retry a failed send-community-push
-- invocation on a later pin update either; a lost push is a degraded experience, not a data-integrity
-- issue, per that file's own header). The alternative (only stamp on confirmed net.http_post success)
-- would make a persistent Vault/pg_net outage retry the SAME pin forever, every 30 seconds, until it
-- expires — worse than today's behavior, where a single failed attempt is simply a single missed push.
-- This is a deliberate choice, stated here for @qa-verifier to weigh rather than discovering silently.
--
-- HEAD-START-EXCEEDS-DEPARTURE / honest exclusivity (spec §1.2a, §0 decision 8) — "skip it FOREVER":
-- achieved by construction, with no special-case code, via the WHERE clause's own resolved_at/
-- expires_at predicates. Once a pin's expires_at passes, `expires_at > now()` becomes false and STAYS
-- false forever (time is monotonic) — the row drops out of every future sweep's candidate set
-- permanently, with zone_pushed_at left null forever, which is the CORRECT, intended state per the
-- honest-exclusivity ruling (the zone board legitimately never learns about a spot that's already
-- gone). Likewise, once resolved_at is set (claimed via claim_pin(), or swept resolved by the existing
-- community-pin-expiry-hygiene-sweep job, 03-community-2.0-schema.sql §2.12), `resolved_at is null`
-- becomes false and stays false forever — same permanent exclusion, same reasoning (pushing a zone-wide
-- alert for a spot that is already claimed or already resolved would be actively wrong, not just late).
-- No trigger or stamp is needed to enforce "forever" here — it falls out of resolved_at/expires_at being
-- one-way, monotonic state transitions that this file does not need to duplicate or race against.
--
-- SCHEMA PLACEMENT — `internal.sweep_leaving_soon_zone_push()`, NOT `public.sweep_leaving_soon_zone_push()`
-- (fixed post-QA, docs/qa/pr114-regulars-delay.md Finding #1, live-reproduced 🔴): this function is
-- SECURITY DEFINER, reads vault.decrypted_secrets, and issues real net.http_post calls carrying the
-- service-role key, system-wide, bypassing RLS. Postgres grants EXECUTE to PUBLIC by default on
-- function creation — an earlier version of this file created the function in `public` with only an
-- ADDITIVE `grant ... to postgres`, which does NOT revoke PUBLIC's retained default grant, so `anon`
-- and `authenticated` (both PostgREST-exposed) could call it directly via
-- `POST /rest/v1/rpc/sweep_leaving_soon_zone_push` using nothing but the public anon key — QA confirmed
-- this live (`set role anon; select public.sweep_leaving_soon_zone_push();` succeeded). The file's own
-- prior comment credited `internal.invoke_film_permit_ingest()` (02d-ingest-cron.sql) as "the same
-- convention," but that function is safe for a DIFFERENT reason than its grant statement: it lives in
-- the `internal` schema, which this repo has established throughout (04, 08, 02d) specifically as the
-- "PostgREST does not expose this" boundary — its own `pg_proc.proacl` has the identical
-- PUBLIC-retained EXECUTE grant, it's just harmless there because of schema placement. This file now
-- matches that precedent for real (schema placement, not just the grant line) rather than copying only
-- its surface-level GRANT statement, per QA's own recommended fix (a) — "prefer the schema move for
-- consistency" over an explicit `REVOKE EXECUTE FROM PUBLIC` (fix (b)), since it is the LEAST NOVEL
-- pattern: every other cron-invoked SECURITY DEFINER helper in this repo (internal.invoke_send_community_push,
-- internal.invoke_send_regular_push, internal.invoke_film_permit_ingest) already lives in `internal`
-- with no explicit REVOKE anywhere, and this function now does too.
create schema if not exists internal;
-- Idempotent restatement — `internal` already exists by this point in the chain (created by `04`
-- and/or `08`), same "no undeclared dependency on file-apply order" reasoning this file's own header
-- already applies to `create extension if not exists pg_cron` below.

create or replace function internal.sweep_leaving_soon_zone_push()
returns void language plpgsql security definer as $$
declare
  r                  record;
  v_service_role_key text;
  v_request_id       bigint;
  v_stage            text;
  v_swept_count      integer := 0;
begin
  for r in
    select *
      from public.pins
     where pin_type = 'leaving_soon'
       and source = 'crowd'
       and lifespan = 'ephemeral'
       and zone_id is not null
       and resolved_at is null
       and expires_at > now()
       and zone_pushed_at is null
       and regulars_head_start_seconds is not null
       and regulars_head_start_seconds > 0
       and created_at <= now() - make_interval(secs => regulars_head_start_seconds)
     order by created_at
       for update of pins skip locked
  loop
    v_stage := 'vault_read';
    begin
      select decrypted_secret
        into v_service_role_key
        from vault.decrypted_secrets
       where name = 'service_role_key'
       limit 1;

      if v_service_role_key is null then
        raise log 'sweep_leaving_soon_zone_push: Vault secret "service_role_key" not found — skipping delayed push for pin %', r.id;
      else
        v_stage := 'http_post';
        -- Same Edge Function, same auth pattern, same body shape as 04-community-push-trigger.sql's
        -- own invocation — send-community-push is completely unmodified by this file (spec §2.8: "No
        -- new Edge Function is needed").
        select net.http_post(
          url     := 'https://jiispshyqerscdoferaw.functions.supabase.co/send-community-push',
          headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_service_role_key,
            'Content-Type',  'application/json'
          ),
          body    := jsonb_build_object('pin', to_jsonb(r))
        ) into v_request_id;

        raise log 'sweep_leaving_soon_zone_push: send-community-push invoked for pin % (zone %), pg_net request_id=%', r.id, r.zone_id, v_request_id;
      end if;
    exception when others then
      raise log 'sweep_leaving_soon_zone_push: % stage failed for pin % (sqlstate %): %', v_stage, r.id, sqlstate, sqlerrm;
    end;

    -- Stamp on ATTEMPT, not on confirmed delivery — see the file header note above for why. This is
    -- the ONLY writer of zone_pushed_at anywhere in this codebase (07 explicitly excludes it from the
    -- client-writable column grant — see 07-regulars-schema.sql §S1-1's own comment — so this
    -- SECURITY DEFINER context is the sole path that can ever set it).
    update public.pins set zone_pushed_at = now() where id = r.id;
    v_swept_count := v_swept_count + 1;
  end loop;

  if v_swept_count > 0 then
    raise log 'sweep_leaving_soon_zone_push: swept % pin(s) this run', v_swept_count;
  end if;
end;
$$;

comment on function internal.sweep_leaving_soon_zone_push() is
  'The delayed half of spec §2.8''s Tiered Handoff push. Runs on a 30-second pg_cron schedule (see the '
  'cron.schedule call below). Finds every leaving_soon pin whose Regulars head start has elapsed '
  '(created_at + regulars_head_start_seconds <= now()), is not yet zone-pushed, and has not expired or '
  'resolved before the head start elapsed (see the honest-exclusivity note above for why a pin that '
  'expires/resolves first is skipped FOREVER, by construction, not specially coded), and fires the '
  'existing send-community-push Edge Function for each one exactly once, stamping zone_pushed_at '
  'immediately after the attempt (success or failure alike — see the stamp-on-attempt note above). '
  'Race-safe under overlapping invocations via SELECT ... FOR UPDATE SKIP LOCKED. Column-privilege '
  'model note: this SECURITY DEFINER function is the ONLY writer of pins.zone_pushed_at anywhere in '
  'this codebase, matching 07-regulars-schema.sql''s own grant design (zone_pushed_at deliberately '
  'excluded from the client-writable column grant on pins) — verified: this function''s UPDATE runs as '
  'its owner (SECURITY DEFINER), which bypasses table/column-level GRANT checks entirely for its own '
  'writes, the same posture every other SECURITY DEFINER writer in this repo relies on (e.g. '
  'redeem_regular_invite() writing regular_edges, which has no client INSERT policy at all).';

-- Grant execute to postgres only — the role pg_cron invocations run as on this project, same convention
-- as 02d-ingest-cron.sql's internal.invoke_film_permit_ingest() grant. NOT reachable via PostgREST at
-- all now (the `internal` schema itself is the boundary, not this grant — see the SCHEMA PLACEMENT
-- note above): there is no product reason for a client to trigger this sweep on demand, and the
-- existing community-pin-expiry-hygiene-sweep job (03-community-2.0-schema.sql §2.12) sets the same
-- precedent (a raw SQL cron body with zero RPC exposure) for a cron-only helper.
grant execute on function internal.sweep_leaving_soon_zone_push() to postgres;

-- Enable required extension (idempotent — already enabled and in production use per
-- 02d-ingest-cron.sql:17 / 03-community-2.0-schema.sql §2.12; restated here so this file has no
-- undeclared dependency on either having run first, even though in practice they always have).
create extension if not exists pg_cron;

-- CADENCE: '30 seconds' — pg_cron's dedicated sub-minute schedule-string form (see the CRON CADENCE
-- note above for why this is NOT the spec pseudocode's 6-field '*/30 * * * * *' string, which is not
-- valid pg_cron syntax). cron.schedule with a fixed job name is idempotent — re-running this file
-- updates the existing job's schedule/command rather than creating a duplicate, same pattern as
-- 02d/03's own cron.schedule calls.
select cron.schedule(
  'sweep-leaving-soon-zone-push',
  '30 seconds',
  $$ select internal.sweep_leaving_soon_zone_push(); $$
);

-- Verify after applying (Kevin, SQL Editor):
--   select jobname, schedule, active from cron.job where jobname = 'sweep-leaving-soon-zone-push';
--   select tgname, tgenabled from pg_trigger where tgname = 'pins_invoke_send_community_push';
-- Verify the function is NOT anon/authenticated-callable via PostgREST (the QA-found gap this file
-- now fixes — docs/qa/pr114-regulars-delay.md Finding #1):
--   curl -sS -X POST "https://jiispshyqerscdoferaw.supabase.co/rest/v1/rpc/sweep_leaving_soon_zone_push" \
--     -H "apikey: <anon key>" -H "Authorization: Bearer <anon key>"
--   -- expect 404 (function not found in the exposed public schema), not 200/204.
-- Verify the sweep has actually run and swept a test pin (after inserting a qualifying test pin with a
-- short head start, e.g. regulars_head_start_seconds=60, and waiting ~60-90s):
--   select id, created_at, regulars_head_start_seconds, zone_pushed_at from public.pins
--     where pin_type = 'leaving_soon' order by created_at desc limit 5;
--   select * from cron.job_run_details
--     where jobid = (select jobid from cron.job where jobname = 'sweep-leaving-soon-zone-push')
--     order by start_time desc limit 5;

-- ============================================================================================
-- See supabase/09-regulars-zone-push-delay-test.sh (companion file) — run AFTER applying this migration
-- AND supabase/07-regulars-schema.sql (07 first, required).
-- Never applied/run by an agent — this is Kevin's dashboard task, same as every prior migration.
-- ============================================================================================
