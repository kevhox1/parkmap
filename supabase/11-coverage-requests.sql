-- WePark — "Suggest a neighborhood" coverage requests (open item #39)
-- Proposed by @backend-data 2026-10-23. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor — single paste, no multi-step restriction.
-- Companion test: supabase/11-coverage-requests-test.sh (scratch Postgres 16).
-- Idempotent: safe to re-run (create ... if not exists / create or replace / drop-then-create
-- policies+triggers / on conflict do nothing). Re-running converges to the same end state.
-- Depends on: 01-mvp-schema.sql (auth.users via Supabase), 02f-block-scoped-restrictions.sql
-- (rate_limit_config table + the config-driven rate-limit trigger convention). Independent of 10 and
-- of the draft Regulars migrations 07/08/09.
--
-- PURPOSE: the demand signal for expansion ordering (docs/brooklyn-expansion-spec.md). When a user is
-- looking at a place WePark doesn't cover, the app offers "Suggest a neighborhood": city + optional
-- note. Kevin reads the table from the Supabase dashboard / service role. Nothing in it is ever shown
-- back to any client.
--
-- ============================================================================================
-- THE iOS CONTRACT
-- ============================================================================================
--   Table:    public.coverage_requests   (PostgREST: POST /rest/v1/coverage_requests)
--   Insert:   authenticated role ONLY (anonymous-auth sessions count — they are `authenticated`).
--             Client-writable columns, and ONLY these:
--                city          text, required, 2..80 characters after trimming
--                note          text, optional, <= 500 characters (empty/whitespace-only -> stored NULL)
--                viewed_lat    double precision, optional
--                viewed_lng    double precision, optional   (both or neither; the SERVER rounds them
--                              to 2 decimals ~ 1 km, so send the map-center / neighborhood centroid,
--                              never the user's GPS fix — nothing precise is retained even if you do)
--             user_id is filled by the DATABASE from the JWT (column default auth.uid()); sending it,
--             or id / created_at, is rejected with 42501 "permission denied for table coverage_requests".
--   MUST use minimal return: do not request the inserted row back. supabase-swift's
--             `.insert(row)` defaults to returning: .minimal — correct; do NOT chain `.select()` and do
--             NOT send `Prefer: return=representation`. Clients have no SELECT access by design, and
--             (docs: supabase/05-device-push-tokens-rls-fix.sql) an INSERT ... RETURNING requires
--             SELECT access to the written row, so representation-returning inserts fail with 42501
--             even though the row would otherwise be accepted. This is expected for this table.
--   Errors:   23514 (check_violation)      city/note length or lat/lng range invalid -> show form error
--             42501 + message 'rate limit exceeded ...'  -> too many suggestions; show a friendly
--                                                           "You've sent a few already, thanks!"
--             42501 + 'permission denied' / RLS          -> not signed in / bad payload (client bug)
--   Success toast copy suggestion: "Thanks — we'll use this to decide where to launch next."
--
-- ============================================================================================
-- DECISIONS
-- ============================================================================================
-- anon vs authenticated: AUTHENTICATED ONLY (veto-able). An anon-key insert has no identity at all, so
--   the only rate-limit key would be an IP header that the DB cannot see reliably and a client can
--   spoof — an open write endpoint on the public anon key is an abuse magnet (spam, storage fill).
--   It costs real users nothing: the app establishes an (anonymous or magic-link) auth session before
--   any community write already (03's "device has an auth.uid() from anonymous auth the moment it does
--   anything"). Per-user keying also gives a clean limiter and, via user_id, lets deletion/analytics
--   work. user_id is nullable ONLY so account deletion can de-attribute rows (ON DELETE SET NULL);
--   RLS forces user_id = auth.uid() on every client insert.
--   Residual risk: a script can mint many anonymous sessions (each a fresh uid) to dodge the per-user
--   cap. Mitigations here: (1) a GLOBAL hourly backstop cap (second rate_limit_config key), and
--   (2) Supabase Auth's built-in per-IP anonymous-sign-in rate limit. Retune either by UPDATEing
--   rate_limit_config — no migration needed.
--
-- Coarse location: viewed_lat/lng are rounded to 2 decimals by a BEFORE INSERT trigger — enforced
--   server-side because the client can't be trusted to do it. They identify the neighborhood being
--   looked at, not a person. No device id, no IP, no precise anything is stored.
--
-- Privilege model (repo pattern from 02f/07): Supabase's default privileges GRANT ALL on every new
--   public table to anon/authenticated, and column grants are ADDITIVE to a table-level grant, so the
--   table-level REVOKE must come first, then an explicit column-level INSERT grant. Anything not
--   listed (id, created_at, user_id) is unwritable by clients; the table has no SELECT/UPDATE/DELETE
--   grant and no such policies for anyone but service_role / the dashboard (postgres).
-- ============================================================================================

create table if not exists public.coverage_requests (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  city        text not null,
  note        text,
  viewed_lat  double precision,
  viewed_lng  double precision,
  user_id     uuid default auth.uid() references auth.users(id) on delete set null,

  constraint coverage_requests_city_len_chk
    check (char_length(btrim(city)) between 2 and 80),
  constraint coverage_requests_note_len_chk
    check (note is null or char_length(note) <= 500),
  constraint coverage_requests_lat_range_chk
    check (viewed_lat is null or viewed_lat between -90 and 90),
  constraint coverage_requests_lng_range_chk
    check (viewed_lng is null or viewed_lng between -180 and 180),
  constraint coverage_requests_latlng_pair_chk
    check ((viewed_lat is null) = (viewed_lng is null))
);

comment on table public.coverage_requests is
  '"Suggest a neighborhood" demand signal (open item #39). INSERT-only for authenticated clients via '
  'column-level grants (city, note, viewed_lat, viewed_lng); user_id defaults to auth.uid() and is not '
  'client-writable; NO client SELECT/UPDATE/DELETE — read from the Supabase dashboard. viewed_lat/lng '
  'are rounded to 2 decimals by trigger (coarse neighborhood, never precise). user_id ON DELETE SET '
  'NULL so account deletion (supabase/10) de-attributes rows.';

create index if not exists coverage_requests_created_at_idx
  on public.coverage_requests(created_at desc);
create index if not exists coverage_requests_user_created_idx
  on public.coverage_requests(user_id, created_at)
  where user_id is not null;

alter table public.coverage_requests enable row level security;

drop policy if exists coverage_requests_insert_own on public.coverage_requests;
create policy coverage_requests_insert_own on public.coverage_requests
  for insert to authenticated
  with check (auth.uid() is not null and user_id = auth.uid());
-- Deliberately NO select / update / delete policy for any client role (deny-all; dashboard and
-- service_role bypass RLS). See the iOS contract above for the PostgREST return=minimal consequence.

revoke all on public.coverage_requests from anon, authenticated;
grant insert (city, note, viewed_lat, viewed_lng) on public.coverage_requests to authenticated;
-- anon: nothing. authenticated: column-level INSERT on exactly the four fields above.
-- (user_id is filled by its column default, which does not require a column privilege.)

-- ============================================================
-- Rate limiting — same convention as 02f/03: tunable rows in rate_limit_config, SECURITY DEFINER
-- trigger function, raises 42501 over the cap. max_rows is NOT NULL in the table; it is unused by
-- this guard, so it mirrors max_count.
-- ============================================================
insert into public.rate_limit_config (key, max_count, window_hours, max_rows)
values
  ('coverage_request',        5,   1, 5),     -- per user per hour
  ('coverage_request_global', 300, 1, 300)    -- all users per hour: backstop vs anon-session minting
on conflict (key) do nothing;

create or replace function public.coverage_requests_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_max     integer;
  v_user_window  integer;
  v_glob_max     integer;
  v_glob_window  integer;
  v_recent       integer;
begin
  -- Normalize first (CHECK constraints run after BEFORE triggers, so they validate the cleaned values).
  new.city := btrim(new.city);
  new.note := nullif(btrim(new.note), '');
  if new.viewed_lat is not null then new.viewed_lat := round(new.viewed_lat::numeric, 2)::double precision; end if;
  if new.viewed_lng is not null then new.viewed_lng := round(new.viewed_lng::numeric, 2)::double precision; end if;

  select max_count, window_hours into v_user_max, v_user_window
    from public.rate_limit_config where key = 'coverage_request';
  select max_count, window_hours into v_glob_max, v_glob_window
    from public.rate_limit_config where key = 'coverage_request_global';
  -- Belt-and-suspenders fallback if a config row is ever deleted.
  v_user_max    := coalesce(v_user_max, 5);     v_user_window := coalesce(v_user_window, 1);
  v_glob_max    := coalesce(v_glob_max, 300);   v_glob_window := coalesce(v_glob_window, 1);

  -- Per-user guard. Serialize concurrent inserts for the same user so a burst of parallel requests
  -- cannot all read the same count (closes the TOCTOU that 03 accepted for pins; cheap here).
  if new.user_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('coverage_requests:' || new.user_id::text, 0));
    select count(*) into v_recent
      from public.coverage_requests
     where user_id = new.user_id
       and created_at > now() - make_interval(hours => v_user_window);
    if v_recent >= v_user_max then
      raise exception 'rate limit exceeded: max % coverage request(s) per % hour(s)', v_user_max, v_user_window
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  -- Global backstop.
  select count(*) into v_recent
    from public.coverage_requests
   where created_at > now() - make_interval(hours => v_glob_window);
  if v_recent >= v_glob_max then
    raise exception 'rate limit exceeded: coverage requests temporarily unavailable, try again later'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

-- Trigger functions are not callable as RPC, but strip the default EXECUTE grants anyway (PR #114 QA
-- Finding #1 hygiene). Firing a trigger does not require the invoking role to hold EXECUTE.
revoke all on function public.coverage_requests_before_insert() from public;
revoke all on function public.coverage_requests_before_insert() from anon;
revoke all on function public.coverage_requests_before_insert() from authenticated;

drop trigger if exists coverage_requests_before_insert on public.coverage_requests;
create trigger coverage_requests_before_insert
  before insert on public.coverage_requests
  for each row execute function public.coverage_requests_before_insert();

-- Verify after applying (Kevin, SQL Editor):
--   select grantee, privilege_type, column_name from information_schema.column_privileges
--    where table_schema='public' and table_name='coverage_requests'
--      and grantee in ('anon','authenticated') order by grantee, column_name, privilege_type;
--   -- expect ONLY: authenticated INSERT on city, note, viewed_lat, viewed_lng (4 rows); nothing for anon.
--   select polname, polcmd from pg_policy where polrelid='public.coverage_requests'::regclass;
--   -- expect exactly one policy: coverage_requests_insert_own, polcmd 'a' (INSERT).
-- To read the demand signal:  select city, count(*), max(created_at) from public.coverage_requests
--                              group by 1 order by 2 desc;
