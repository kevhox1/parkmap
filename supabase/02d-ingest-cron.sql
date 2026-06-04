-- WePark ingest cron schedule
-- Spec: docs/tier1-open-data-ingest-spec.md §3.8
-- Depends on: pg_cron extension enabled + pg_net extension enabled on the project.
-- Apply via Supabase SQL Editor after deploying the ingest-film-permits Edge Function.
--
-- SECURITY NOTE: The service-role key is NOT committed here.
-- Store it as a Supabase Vault secret named 'service_role_key' first:
--
--   1. Dashboard → Settings → Vault → New Secret
--      Name: service_role_key
--      Value: <your service-role JWT — starts with eyJ...>
--
-- Then the cron job below reads it from the vault at runtime via vault.decrypted_secrets.
-- The project ref is hardcoded below — replace <project-ref> with jiispshyqerscdoferaw.
--
-- Enable required extensions (idempotent):
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- The cron helper lives in a private `internal` schema (not exposed via PostgREST).
-- Must exist before internal.invoke_film_permit_ingest() is created below.
create schema if not exists internal;

-- ---------------------------------------------------------------------------
-- RPC: upsert_filming_pin
-- Used as a fallback by the Edge Function when PostgREST's index-name upsert
-- path is unavailable. Executes the canonical ON CONFLICT upsert directly.
-- SECURITY DEFINER so it can write pins rows bypassing RLS (same privilege as
-- the service-role key path, but callable from within a PostgREST RPC call).
-- Only callable by authenticated users or service-role; anon is rejected.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_filming_pin(
  p_lat        double precision,
  p_lng        double precision,
  p_zone_id    text,
  p_expires_at timestamptz,
  p_meta       jsonb
)
returns void language plpgsql security definer as $$
begin
  -- Reject anonymous callers. The Edge Function always uses service-role,
  -- so this guard is a belt-and-suspenders safety check.
  if auth.role() not in ('service_role', 'authenticated') then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;

  insert into public.pins (
    pin_type, source, lifespan,
    lat, lng, segment_id, zone_id, author_id,
    expires_at, resolved_at,
    confirm_count, dispute_count,
    meta, notes
  )
  values (
    'filming', 'open_data', 'session',
    p_lat, p_lng, null, p_zone_id, null,
    p_expires_at, null,
    0, 0,
    p_meta, null
  )
  on conflict ((meta->>'permit_id'))
    where pin_type = 'filming'
  do update set
    lat        = excluded.lat,
    lng        = excluded.lng,
    zone_id    = excluded.zone_id,
    expires_at = excluded.expires_at,
    meta       = excluded.meta,
    updated_at = now();
end;
$$;

-- Grant to authenticated so the Edge Function's service-role key can call it via PostgREST.
grant execute on function public.upsert_filming_pin(double precision, double precision, text, timestamptz, jsonb)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Helper function: invoke ingest-film-permits Edge Function
-- SECURITY DEFINER so the vault read works from the cron context.
-- ---------------------------------------------------------------------------
create or replace function internal.invoke_film_permit_ingest()
returns void language plpgsql security definer as $$
declare
  v_service_role_key text;
  v_request_id       bigint;
begin
  -- Read the service-role key from Vault at runtime — never hardcoded.
  select decrypted_secret
    into v_service_role_key
    from vault.decrypted_secrets
   where name = 'service_role_key'
   limit 1;

  if v_service_role_key is null then
    raise exception 'Vault secret "service_role_key" not found — cannot invoke ingest function';
  end if;

  select net.http_post(
    url     := 'https://jiispshyqerscdoferaw.functions.supabase.co/ingest-film-permits',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_service_role_key,
      'Content-Type',  'application/json'
    ),
    body    := '{}'::jsonb
  ) into v_request_id;

  raise log 'ingest-film-permits invoked, pg_net request_id=%', v_request_id;
end;
$$;

-- Grant execute to the postgres role used by pg_cron.
grant execute on function internal.invoke_film_permit_ingest() to postgres;

-- ---------------------------------------------------------------------------
-- Schedule: once daily at 09:00 UTC = 04:00–05:00 ET (covers both EST/EDT).
-- Per spec §3.8: "Use 09:00 UTC as the conservative choice".
-- ---------------------------------------------------------------------------
select cron.schedule(
  'ingest-film-permits',          -- job name (unique; safe to re-run — replaces existing)
  '0 9 * * *',                    -- 09:00 UTC daily
  $$ select internal.invoke_film_permit_ingest() $$
);

-- Verify the job was registered:
-- select * from cron.job where jobname = 'ingest-film-permits';
