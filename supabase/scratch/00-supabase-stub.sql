-- SCRATCH-POSTGRES-ONLY fixture. NEVER run against a real Supabase project.
-- Minimal stand-ins for the Supabase-managed primitives the applied migrations (01-06) lean on, so the
-- real migration files can be applied verbatim to a throwaway Postgres 16 and exercised under the real
-- `anon` / `authenticated` roles. Same shape as the stubs used for the PR #111/#112/#114 QA passes.
--
-- Not stubbed because not needed: pg_cron / pg_net as extensions (scratch/common.sh comments the two
-- `create extension` lines out of the copies it applies; the cron.* / net.* stubs below satisfy the calls).

create extension if not exists pgcrypto;

create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  is_anonymous boolean not null default false
);
-- Mimics GoTrue's own FKs onto auth.users so a deleted user's sessions/identities cascade.
create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null default 'email'
);
create table if not exists auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade
);
create table if not exists auth.refresh_tokens (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete cascade
);

-- auth.uid(): reads the JWT sub claim from a session GUC, as PostgREST would set it.
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth   to anon, authenticated, service_role;

-- Supabase's project template: default privileges give anon/authenticated/service_role ALL on every
-- new public table/sequence AND EXECUTE on every new public function (this is exactly the posture
-- the REVOKE-then-GRANT pattern in 10/11 must defeat; matching it is what makes these tests honest).
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- Vault: empty on purpose (04's trigger is written to fail open when the secret is missing).
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (name text primary key, decrypted_secret text);

-- pg_net stub: records the call, returns an id.
create schema if not exists net;
create sequence if not exists net.request_id_seq;
create table if not exists net._http_response (
  id bigint primary key, status_code int, content text, created timestamptz default now(), url text, body_logged jsonb
);
create or replace function net.http_post(
  url text, headers jsonb default '{}'::jsonb, body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb, timeout_milliseconds int default 5000
) returns bigint language plpgsql as $$
declare v_id bigint;
begin
  v_id := nextval('net.request_id_seq');
  insert into net._http_response(id, status_code, content, url, body_logged) values (v_id, 200, 'stub-ok', url, body);
  return v_id;
end $$;

-- pg_cron stub.
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigserial primary key, jobname text unique, schedule text, command text, active boolean default true
);
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint
language plpgsql as $$
declare v_id bigint;
begin
  insert into cron.job(jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid into v_id;
  return v_id;
end $$;

-- Storage stub (02f section 8 creates a bucket row and two policies on storage.objects).
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid
);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
$$;
grant usage on schema storage to anon, authenticated, service_role;
-- Real Supabase grants the API roles table privileges on storage.objects; RLS policies do the gating.
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
