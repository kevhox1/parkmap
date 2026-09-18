-- DRAFT — DO NOT APPLY (Kevin applies at the S3/S4 gate, after deploying send-regular-push, per the
-- spec's ceremony plan)
--
-- WePark Regulars network — S3: pins_invoke_send_regular_push trigger
-- Spec: docs/regulars-network-spec.md §2.9 ("send-regular-push — the new Edge Function (the ONLY new
-- one)"). Sequencing: docs/regulars-roadmap.md, session S3.
-- Proposed by @backend-data 2026-09-17. NOT yet applied to production.
--
-- APPLY ORDER MATTERS:
--   1. supabase/07-regulars-schema.sql must already be applied — this file's trigger reads
--      public.regular_edges (§S1-2) and depends on public.pins.regulars_head_start_seconds/
--      author_id (§S1-1, and pins' own pre-existing author_id column). Applying this file before 07
--      fails outright at CREATE FUNCTION time (relation "regular_edges" does not exist) — this is a
--      hard dependency, not a soft one, unlike 04's own relationship to 02d (which merely restates an
--      idempotent extension/schema create as a defensive no-op).
--   2. Deploy the send-regular-push Edge Function BEFORE applying this file (same order 04's own
--      header already establishes for send-community-push — see that file's comment for the identical
--      reasoning: applying the trigger first is not unsafe, pg_net just gets a 404 that this trigger's
--      own exception handler logs and swallows, but a push obviously can't be delivered until the
--      function exists).
--
-- Depends on:
--   07-regulars-schema.sql  — public.regular_edges (the trust graph this trigger's function reads),
--                              public.pins.regulars_head_start_seconds (read-only here — see the SCOPE
--                              NOTE below for why this trigger does NOT gate on it)
--   02-pins-schema.sql       — public.pins.author_id, pin_type enum (leaving_soon)
--   02d-ingest-cron.sql      — pg_net extension already enabled, `internal` schema already created,
--                              and the Vault secret 'service_role_key' already provisioned. This file's
--                              trigger reuses that EXACT secret and auth pattern (see below), same as
--                              04-community-push-trigger.sql's own internal.invoke_send_community_push()
--                              — zero new one-time setup for Kevin beyond deploying the new Edge
--                              Function itself.
--   04-community-push-trigger.sql — NOT modified by this file. This trigger is a separate, additive
--                              AFTER INSERT trigger on the same table; the live
--                              pins_invoke_send_community_push trigger and its WHEN clause are
--                              completely untouched. Two independent triggers fire on the same INSERT
--                              when a leaving_soon pin with Regulars is created — Postgres runs both,
--                              order is unspecified and irrelevant (they write to unrelated Edge
--                              Functions, neither reads the other's result).
--
-- Idempotent: safe to re-run on a clean or already-applied project (create-or-replace function,
-- drop-then-create trigger — same convention as every prior migration in this repo).
--
-- ============================================================================================
-- SCOPE NOTE — what this trigger is and is not (read before reviewing)
-- ============================================================================================
-- This is the ONLY new trigger S3 adds. It is deliberately NOT a rewrite of
-- pins_invoke_send_community_push's WHEN clause and does NOT touch, gate on, or even reference the
-- 30-second sweep_leaving_soon_zone_push() cron job the spec's §2.8 describes — that piece is still
-- explicitly deferred to its own follow-up session (docs/regulars-roadmap.md's "S1-follow-up" row,
-- unchanged by this file). The two push paths are independent by design:
--   - pins_invoke_send_community_push (LIVE, unmodified) fires the existing silent zone-wide push
--     immediately at insert today, and will keep doing so until the S1-follow-up session lands the
--     delayed-sweep rewrite. Nothing in THIS file changes when that push fires.
--   - pins_invoke_send_regular_push (NEW, this file) fires the new visible Regulars push immediately
--     at insert, unconditionally — this is "the head start" (spec §2.9: "this one fires immediately,
--     unconditionally, same instant the pin is created — the whole point of 'head start'"). It does
--     NOT read regulars_head_start_seconds to decide WHETHER or WHEN to fire; that column exists
--     purely for the (still-deferred) zone-wide sweep's own delay math, and this trigger has no
--     dependency on it being null, set, or any particular value. A leaving_soon pin with ZERO Regulars
--     still fires this trigger (send-regular-push's own regular_edges lookup then finds nothing and
--     returns `sent: 0` — see that function's own early-return branch) — cheap, correct, and no special
--     casing needed in SQL to skip Regulars-less authors.
-- Net effect while both S3 (this file) and the S1-follow-up remain unapplied/unmerged relative to each
-- other: applying JUST this file changes production behavior (a new, additive push starts firing for
-- leaving_soon pins) without touching the live zone-wide pipeline's timing at all — that pipeline still
-- fires exactly as it does today until the separate follow-up lands. Zero regression risk to the
-- existing crowd-reporting push loop from this file.
--
-- ============================================================================================
-- Auth pattern: reused EXACTLY from internal.invoke_send_community_push() (04-community-push-trigger.sql)
-- — read the 'service_role_key' Vault secret at runtime (never hardcoded here), then net.http_post
-- with `Authorization: Bearer <service-role-key>`.
--
-- FAIL-OPEN, NOT FAIL-CLOSED — same S11/PR#99 lesson, preserved verbatim: a missing Vault secret, a
-- pg_net error, or any other unexpected exception while invoking the push function must never roll
-- back or block the pins INSERT that triggered it. The QA-found bug in PR #99 (docs/qa/pr99-community-
-- phase4b-push.md, Finding #1 BLOCKING) was that only net.http_post sat inside the exception block
-- while the preceding Vault select + null-check sat OUTSIDE it — any throw during the Vault read
-- (relation missing, permissions, a Vault hiccup — HANDOFF itself calls Vault "BETA") propagated
-- UNCAUGHT and aborted the whole triggering pins INSERT. This file's function is written CORRECTLY
-- from the start (never repeats that bug): ONE begin/exception block encloses the Vault read, the
-- null-check, AND the http_post, exactly mirroring 04's own POST-FIX shape, not its original buggy one.
-- `v_stage` is set immediately before each step so the single shared handler's log line still
-- identifies which stage failed, same convention.
-- ============================================================================================
create extension if not exists pg_net;
create schema if not exists internal;

create or replace function internal.invoke_send_regular_push()
returns trigger language plpgsql security definer as $$
declare
  v_service_role_key text;
  v_request_id       bigint;
  v_stage            text := 'vault_read';
begin
  begin
    v_stage := 'vault_read';
    select decrypted_secret
      into v_service_role_key
      from vault.decrypted_secrets
     where name = 'service_role_key'
     limit 1;

    if v_service_role_key is null then
      raise log 'send-regular-push: Vault secret "service_role_key" not found — skipping push for pin %', new.id;
      return new;
    end if;

    v_stage := 'http_post';
    select net.http_post(
      url     := 'https://jiispshyqerscdoferaw.functions.supabase.co/send-regular-push',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_service_role_key,
        'Content-Type',  'application/json'
      ),
      -- Send the whole inserted row (to_jsonb(NEW)) as {"pin": {...}} — same convention as
      -- 04-community-push-trigger.sql's own invocation. send-regular-push/index.ts reads only
      -- id/pin_type/source/lifespan/author_id/segment_id/zone_id/leaving_minutes/
      -- regulars_head_start_seconds from it
      -- (see that file's PinRecord interface and its own defense-in-depth pin_type re-check), and
      -- NEVER reads `notes` (pin_notes is a separate table entirely, not a pins column — see that
      -- function's file header for why the note can never race into this push regardless). Sending
      -- the full row costs nothing extra and avoids this trigger needing an edit every time the
      -- function's field needs change.
      body    := jsonb_build_object('pin', to_jsonb(new))
    ) into v_request_id;

    raise log 'send-regular-push invoked for pin % (author %), pg_net request_id=%', new.id, new.author_id, v_request_id;
  exception when others then
    raise log 'send-regular-push: % stage failed for pin % (sqlstate %): %', v_stage, new.id, sqlstate, sqlerrm;
  end;

  return new;
end;
$$;

-- AFTER INSERT (not BEFORE): pure side-effect trigger, no NEW-row mutation — same posture as
-- pins_invoke_send_community_push.
--
-- WHEN clause: pin_type = 'leaving_soon' AND source = 'crowd' AND lifespan = 'ephemeral'.
-- QA FIX (🟢 nit, docs/qa/pr112-regulars-s3-push.md): the original version of this trigger gated on
-- pin_type ALONE. QA correctly noted this is looser than 04-community-push-trigger.sql's own WHEN
-- clause (`source='crowd' and lifespan='ephemeral' and zone_id is not null`) — there is no DB-level
-- CHECK tying pin_type to source/lifespan (confirmed against 02-pins-schema.sql's insert policy, which
-- only requires source='crowd'), so a hand-crafted leaving_soon insert with a non-ephemeral lifespan
-- would have fired send-regular-push but not send-community-push. Not exploitable beyond "send one
-- extra push via a hand-crafted REST call" (no privacy/data-integrity impact — QA's own severity call,
-- logged as a nit, not blocking), but cheap to close and closes a real asymmetry with 04's own
-- gate, so fixed here rather than deferred. The app's own leaving_soon composer always sends
-- source='crowd'/lifespan='ephemeral' today (Community 2.0 Phase 4a), so this tightening is a no-op
-- for every legitimate insert path and only closes the hand-crafted-REST-call gap QA found.
--
-- Deliberately UNCHANGED, and NOT copied from 04: `zone_id is not null`. 04 requires it because the
-- ZONE push's whole targeting mechanism is zone-scoped (device_push_tokens.zone_id) — a null zone_id
-- pin has no zone to push to. This trigger's targeting is by author_id -> regular_edges ->
-- device_push_tokens.user_id (spec §2.9) and has no dependency on zone_id at all; requiring it here
-- would incorrectly withhold a Regulars push from a (currently theoretical, since the client always
-- sets zone_id for leaving_soon today) zone-less leaving_soon pin, for no privacy or correctness
-- reason — this trigger's own targeting never reads zone_id. Also unchanged, per the SCOPE NOTE above:
-- no regulars_head_start_seconds check, no author-has-Regulars check — both are cheap to evaluate
-- inside the Edge Function itself, so the SQL WHEN clause stays minimal enough to never silently drift
-- out of sync with a business-logic change that only touches the function.
--
-- Every OTHER pin_type (open_spot, enforcement_active, sweeper_passed, broken_meter, sign_correction,
-- block_note, filming, construction, parked_car) is excluded — this pipeline is Tiered-Handoff-specific,
-- per spec §1.2/§2.9, not a general Regulars-notification pipeline (Loop C's regular_notices broadcasts
-- are a SEPARATE mechanism — a future session's own trigger on public.regular_notices, not this one,
-- and explicitly out of scope for S3's single named deliverable, "the pins_invoke_send_regular_push
-- insert trigger").
drop trigger if exists pins_invoke_send_regular_push on public.pins;
create trigger pins_invoke_send_regular_push
  after insert on public.pins
  for each row
  when (new.pin_type = 'leaving_soon' and new.source = 'crowd' and new.lifespan = 'ephemeral')
  execute function internal.invoke_send_regular_push();

-- Verify after applying (Kevin, SQL Editor):
--   select tgname, tgenabled from pg_trigger where tgname = 'pins_invoke_send_regular_push';
-- Verify a specific invocation fired (after inserting a qualifying test pin):
--   select * from net._http_response order by created desc limit 5;
-- (net._http_response is internal — not exposed via PostgREST/anon key — hence the SQL-Editor-only
-- verification step here and the MANUAL instructions in the companion test script.)

-- ============================================================================================
-- See supabase/08-regulars-push-trigger-test.sh (companion file) — run AFTER applying this migration
-- AND supabase/07-regulars-schema.sql (both required — 07 first).
-- Never applied/run by an agent — this is Kevin's dashboard task, same as every prior migration.
-- ============================================================================================
