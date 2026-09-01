-- WePark Community 2.0 — Phase 4b: community push pipeline (build 20, session S11)
-- Spec: docs/community-2.0-reconciliation-spec.md §2.9 (device_push_tokens — already live in prod via
-- the applied Phase 0 migration, supabase/03-community-2.0-schema.sql) and §3 Phase 4's "APNs
-- pipeline" ("New ephemeral crowd pin → pg_net trigger → Edge Function → silent push to every token
-- in that zone → client compares segment_id ... "). §3 Phase 4 explicitly names this exact deliverable
-- and explicitly pre-clears it as a standalone migration: "the pg_net trigger invoking it
-- (backend-data, folds into §2's migration file or a small follow-up — Kevin's call whether Phase 0
-- stays single-PR or a slim Phase-4-schema PR is acceptable given the working agreement's 'ask before
-- altering schema after Phase 0')". This IS that slim Phase-4-schema PR — anticipated by the spec, not
-- an unplanned schema change slipped in outside the working agreement.
--
-- Also lands the queued §5 follow-up (docs/community-2.0-reconciliation-spec.md §5): "Expose
-- profiles.avatar on pins_with_author ... queued by PR #97 QA (2026-08-31) as a real follow-up ...
-- Lands in the next migration file that touches the view (natural candidate: S11's Phase-4 backend
-- PR)". Section A below is that one-line view change (`pr.avatar as author_avatar` appended), done
-- FIRST and with a full explicit column list diffed against 03's recreation of the same view, per
-- this repo's own repeated lesson (02f section 5 / 03's own zone_messages_with_author comment) that
-- an accidentally-shortened `CREATE OR REPLACE VIEW` column list is a silent-drop bug this repo has
-- hit twice already — never re-derive the list from memory, always diff.
--
-- Proposed by @backend-data 2026-09-01. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor. ORDER MATTERS — deploy the send-community-push Edge
-- Function BEFORE applying this file (see the PR description for the full step-by-step). Applying this
-- trigger before the function is deployed is not unsafe (pg_net will just get a 404/connection error,
-- which the trigger function logs and swallows — see Section B's fail-open note) but a push obviously
-- can't actually be delivered until the function exists, so deploy-then-migrate is the sane order.
-- Run supabase/04-community-push-test.sh after applying (both sections, single paste — no ALTER TYPE
-- two-step restriction like 03 had, since this file adds zero new enum values).
--
-- Depends on:
--   01-mvp-schema.sql       — profiles.avatar (added in 03, referenced here), zones
--   02-pins-schema.sql      — pins, pins_with_author's original column set
--   02d-ingest-cron.sql     — pg_cron + pg_net extensions already enabled, `internal` schema already
--                             created, and — most importantly — the Vault secret `service_role_key`
--                             already provisioned. This file's trigger reuses that EXACT secret and
--                             auth pattern (see Section B) rather than asking Kevin to provision a
--                             second one for the same project.
--   03-community-2.0-schema.sql — device_push_tokens table (RLS: no select policy for any client
--                             role, insert/update/delete "own row" only — read exclusively by this
--                             function's service-role client, per spec §2.9), pins_with_author's prior
--                             (post-Phase-0) column list, pin_type enum values used by ephemeral crowd
--                             pins (enforcement_active, sweeper_passed, open_spot, leaving_soon,
--                             broken_meter — all lifespan='ephemeral').
--
-- Idempotent: safe to re-run on a clean or already-applied project (create-or-replace view/function,
-- drop-then-create trigger — same pattern as every prior migration in this repo).

-- ============================================================================================
-- Section A — pins_with_author gains author_avatar (spec §5 follow-up)
-- ============================================================================================
-- Full explicit column list, diffed line-for-line against 03-community-2.0-schema.sql's own
-- recreation of this view (03's "pins_with_author — append the three new columns" section) — every
-- column present there is present here, in the same order, with exactly one new column
-- (`pr.avatar as author_avatar`) appended at the end. Appending to an explicit SELECT list is always a
-- safe CREATE OR REPLACE (never renames/reorders existing output columns, never drops the view's
-- grants — the grant is still re-issued below anyway as a defensive no-op, matching 02f section 5's
-- own "the grant is re-issued below anyway... in case this statement is ever preceded by a DROP"
-- reasoning).
create or replace view public.pins_with_author as
  select
    p.id,
    p.pin_type,
    p.source,
    p.lifespan,
    p.lat,
    p.lng,
    p.segment_id,
    p.zone_id,
    p.author_id,
    p.created_at,
    p.updated_at,
    p.expires_at,
    p.resolved_at,
    p.confirm_count,
    p.dispute_count,
    p.meta,
    p.notes,
    pr.username    as author_username,
    pr.reputation  as author_reputation,
    p.starts_at,
    p.report_group_id,
    p.position_fraction,
    p.leaving_minutes,
    p.claimed_by,
    pr.avatar      as author_avatar
  from public.pins p
  left join public.profiles pr on pr.id = p.author_id;

grant select on public.pins_with_author to anon, authenticated;

-- ============================================================================================
-- Section B — pg_net trigger: new ephemeral crowd pin -> send-community-push Edge Function
-- ============================================================================================
-- Enable required extensions (idempotent — both already enabled and in production use per
-- 02d-ingest-cron.sql:17-18; re-stated here so this file has no undeclared dependency on 02d having
-- run first, even though in practice it always has).
create extension if not exists pg_net;

-- ------------------------------------------------------------------------------------------
-- Auth pattern: reused EXACTLY from internal.invoke_film_permit_ingest() (02d-ingest-cron.sql) —
-- read the 'service_role_key' Vault secret at runtime (never hardcoded in this file), then
-- net.http_post with `Authorization: Bearer <service-role-key>`. Deliberately not a new pattern: the
-- Vault secret is already provisioned on this project for 02d's cron job, so this trigger adds zero
-- new one-time setup for Kevin beyond deploying the Edge Function itself (see PR description).
--
-- Fail-open, not fail-closed: a missing Vault secret, a pg_net error, or any other unexpected
-- exception while invoking the push function must never roll back or block the pins INSERT that
-- triggered it — a lost push notification is a degraded experience, not a data-integrity issue, the
-- same posture every other best-effort side-effect in this codebase takes (e.g. the ingest_runs
-- write-failure handling in supabase/functions/ingest-film-permits/index.ts, which logs and continues
-- rather than failing the whole invocation). Both failure branches below `raise log` (visible in
-- Postgres logs / Supabase Logs Explorer) and `return null` rather than `raise exception`.
-- ------------------------------------------------------------------------------------------
create or replace function internal.invoke_send_community_push()
returns trigger language plpgsql security definer as $$
declare
  v_service_role_key text;
  v_request_id       bigint;
begin
  select decrypted_secret
    into v_service_role_key
    from vault.decrypted_secrets
   where name = 'service_role_key'
   limit 1;

  if v_service_role_key is null then
    raise log 'send-community-push: Vault secret "service_role_key" not found — skipping push for pin %', new.id;
    return null;
  end if;

  begin
    select net.http_post(
      url     := 'https://jiispshyqerscdoferaw.functions.supabase.co/send-community-push',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_service_role_key,
        'Content-Type',  'application/json'
      ),
      -- Send the whole inserted row (to_jsonb(NEW)) as {"pin": {...}} — the Edge Function reads only
      -- id/pin_type/source/lifespan/segment_id/zone_id from it (see index.ts's PinRecord interface
      -- and its own defense-in-depth source/lifespan/zone_id re-check), but sending the full row here
      -- costs nothing extra and avoids this trigger needing to be re-edited every time the function's
      -- field needs change.
      body    := jsonb_build_object('pin', to_jsonb(new))
    ) into v_request_id;

    raise log 'send-community-push invoked for pin % (zone %), pg_net request_id=%', new.id, new.zone_id, v_request_id;
  exception when others then
    raise log 'send-community-push: unexpected error invoking function for pin %: %', new.id, sqlerrm;
  end;

  return null;
end;
$$;

-- AFTER INSERT (not BEFORE): this is a pure side-effect trigger with no NEW-row mutation, matching
-- pins_derive_expiry's BEFORE-only scope not applying here — nothing in this trigger needs to change
-- what actually gets written to the pins row.
--
-- WHEN clause scope, per the task spec verbatim ("crowd + ephemeral + zone_id not null"): every
-- ephemeral crowd pin_type qualifies (enforcement_active, sweeper_passed, open_spot, leaving_soon,
-- broken_meter as of this migration — lifespan='ephemeral' is the actual gate, not an enumerated
-- pin_type list, so a FUTURE ephemeral crowd pin_type automatically participates with zero trigger
-- edit required). durable/correction/session crowd pins (sign_correction, block_note, filming,
-- construction) and every open_data/hybrid-sourced pin are excluded — matches the spec's stated scope
-- exactly ("this pipeline is for block-relevant pushes only, per rule 5"; zone-wide states like
-- ASP/snow keep using the existing top-banner surface, unchanged).
drop trigger if exists pins_invoke_send_community_push on public.pins;
create trigger pins_invoke_send_community_push
  after insert on public.pins
  for each row
  when (new.source = 'crowd' and new.lifespan = 'ephemeral' and new.zone_id is not null)
  execute function internal.invoke_send_community_push();

-- Verify after applying (Kevin, SQL Editor):
--   select tgname, tgenabled from pg_trigger where tgname = 'pins_invoke_send_community_push';
-- Verify a specific invocation fired (after inserting a qualifying test pin):
--   select * from net._http_response order by created desc limit 5;
-- (net._http_response is internal — not exposed via PostgREST/anon key — hence the SQL-Editor-only
-- verification step here and the MANUAL instructions in supabase/04-community-push-test.sh.)

-- ============================================================================================
-- See supabase/04-community-push-test.sh (companion file) — run AFTER applying this migration.
-- Never applied by an agent — this is Kevin's dashboard task, same as every prior migration.
-- ============================================================================================
