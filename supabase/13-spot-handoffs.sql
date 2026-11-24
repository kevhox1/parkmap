-- WePark — Spot Pass ("QR neighbor handoff") backend, streams A (schema/RPCs). Spec: docs/specs/qr-spot-handoff.md
-- (Revision 2), sections 3, 8, 9, 10. Written by @backend-data 2026-11-23. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor — single paste, idempotent (safe to re-run). Companion test:
-- supabase/13-spot-handoffs-test.sh (scratch Postgres). Depends on 01, 03 (reputation_award_log, profiles.helped_count,
-- device_push_tokens), 10 (delete_my_account, which this file REPLACES with an extended version — apply 10 first).
--
-- ============================================================================================
-- WHAT THIS FILE CREATES
-- ============================================================================================
--   Tables (all RLS-enabled):
--     public.spot_handoffs         the pass. Seeker may SELECT own rows, a fixed column list only (no hashes/tokens).
--     public.handoff_reports       abuse reports (deny-all to clients).
--     public.handoff_suspensions   users blocked after 3 reports (deny-all).
--     public.handoff_pair_log      24 h pair-cooldown ledger for karma (deny-all).
--     public.handoff_rate_events   rate-limit counters (deny-all; keys are user ids or SALTED IP hashes, never raw IPs).
--     public.handoff_config        server-side feature flag HANDOFF_ENABLED (deny-all).
--   Client RPCs (role `authenticated` ONLY — anonymous-auth sessions count as authenticated):
--     create_handoff(show_name boolean)        -> jsonb {id, token, alias, glyph, expires_at}
--     cancel_handoff(id uuid)                  -> boolean   (true = a live pass was cancelled)
--     confirm_handoff_outcome(id uuid, outcome text) -> jsonb {ok, outcome, seeker_points}
--     report_handoff(id uuid, reason text)     -> jsonb {ok}           (ADDITIVE; seeker-side report)
--     get_my_handoff_karma()                   -> jsonb {spots_passed, spots_caught, helped_count, reputation} (ADDITIVE)
--   Service RPCs (role `service_role` ONLY — called by the handoff-* Edge Functions; never by a client):
--     handoff_peek, handoff_claim, handoff_depart, handoff_extend, handoff_cancel_claim, handoff_report,
--     handoff_clear_tokens.
--   Internal (schema `internal`, not exposed to PostgREST): flag, rate limiter, push dispatch, karma, sweep.
--   Cron: 'handoff-sweep' every minute (expiry, token nulling, fallback karma, 24 h purge).
--
-- ============================================================================================
-- DELIBERATE DEVIATIONS FROM THE SPEC SKETCH (documented; the API CONTRACT of section 8 is unchanged)
-- ============================================================================================
--  1. TOKENS AT TERMINAL (spec 9 #13): the claimer secret hash is nulled at EVERY terminal transition, immediately.
--     Push/activity tokens + topic are nulled immediately for expired/cancelled(claimer)/driver-cancel. They CANNOT be
--     nulled in the same instant for the transitions that must still PUSH THE DRIVER, because the push is sent
--     asynchronously (pg_net -> send-handoff-push reads the row): (a) seeker cancel / suspension -> silent
--     `handoff_ended`; (b) `departed` -> later `thanks` after the seeker confirms. For those, tokens get a short fuse
--     (`claimer_tokens_until`: +2 min for (a), +30 min for (b)) and are nulled by whichever comes first: the
--     send-handoff-push call completing (handoff_clear_tokens), the seeker confirming, or the minute sweep.
--     They are never retained past 30 min after a terminal and never past the 24 h purge.
--  2. DRIVER CANCEL IS SILENT (spec 3): the row keeps status 'armed' (so the seeker's own status read does not reveal
--     the cancel) and only `claimer_cancelled_at` is set, secret/tokens nulled. The pass then expires on schedule.
--  3. EXTRA COLUMNS: claimer_tokens_until, claimer_cancelled_at, fallback_settled, outcome_at, claim horizon.
--  4. seeker_display_name has no "first name" source in the schema; with show_name=true the server uses
--     profiles.username unless it is an auto-generated 'neighbor-xxxxxxxx' handle (then NULL), first word, <=20 chars.
--  5. Karma needs the claimer's identity; a claim with NO user JWT (web fallback) arms fine but earns no karma for
--     either side (cannot prove "different user", spec 10).
--
-- ============================================================================================
-- THE FLAG (spec 9 #10 kill switch). Default OFF.
--   enable:  update public.handoff_config set value = 'true'  where key = 'HANDOFF_ENABLED';
--   disable: update public.handoff_config set value = 'false' where key = 'HANDOFF_ENABLED';
--   While off: create_handoff raises 55000 'handoff_disabled'; every service RPC returns {"disabled":true}
--   (the Edge Functions turn that into HTTP 503 {"error":"disabled"}).
-- ============================================================================================

create schema if not exists internal;

-- ------------------------------------------------------------------------------------------
-- Config / flag
-- ------------------------------------------------------------------------------------------
create table if not exists public.handoff_config (
  key   text primary key,
  value text not null
);
insert into public.handoff_config (key, value) values ('HANDOFF_ENABLED', 'false')
  on conflict (key) do nothing;
alter table public.handoff_config enable row level security;
revoke all on public.handoff_config from anon, authenticated;
-- no policies: deny-all to clients; SQL Editor / service_role only.

create or replace function internal.handoff_enabled()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select lower(value) = 'true' from public.handoff_config where key = 'HANDOFF_ENABLED'), false)
$$;

-- ------------------------------------------------------------------------------------------
-- ledger: allow the handoff kinds. The original CHECK is unnamed in 03 -> drop whatever CHECK mentions `kind`.
-- ------------------------------------------------------------------------------------------
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.reputation_award_log'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) like '%kind%'
  loop
    execute format('alter table public.reputation_award_log drop constraint %I', c.conname);
  end loop;
  alter table public.reputation_award_log
    add constraint reputation_award_log_kind_check
    check (kind in ('confirm', 'accuracy',
                    'handoff_helper', 'handoff_helper_fallback', 'handoff_seeker_confirm', 'handoff_seeker_got_spot'));
end $$;

-- ------------------------------------------------------------------------------------------
-- spot_handoffs
-- ------------------------------------------------------------------------------------------
create table if not exists public.spot_handoffs (
  id                     uuid primary key default gen_random_uuid(),
  token_hash             bytea not null unique,                       -- sha256(token); the token itself is never stored
  seeker_id              uuid not null references auth.users(id) on delete cascade,
  alias                  text not null,
  glyph                  text not null,
  seeker_display_name    text,                                        -- opt-in first name, purged with the row
  status                 text not null default 'created'
                           check (status in ('created','armed','departed','expired','cancelled','suspended')),
  created_at             timestamptz not null default now(),
  leave_at               timestamptz,
  expires_at             timestamptz not null,
  armed_at               timestamptz,
  departed_at            timestamptz,
  claimer_anon_id        uuid references auth.users(id) on delete cascade,  -- never shown to the seeker
  claimer_secret_hash    bytea,                                       -- gates depart/extend/cancel; nulled at terminal
  claimer_push_token     text,
  claimer_activity_token text,
  claimer_topic          text,
  claimer_tokens_until   timestamptz,                                 -- short fuse, see deviation 1
  claimer_cancelled_at   timestamptz,                                 -- silent driver cancel, see deviation 2
  depart_source          text check (depart_source in ('manual','live_activity','notification','auto','start_driving','shortcut')),
  extensions             smallint not null default 0 check (extensions between 0 and 3),
  outcome                text check (outcome in ('got_spot','no_luck')),
  outcome_at             timestamptz,
  fallback_settled       boolean not null default false
);

comment on table public.spot_handoffs is
  'Spot Pass (docs/specs/qr-spot-handoff.md Rev 2). No coordinates/address/plate/username. Seeker reads own rows via a '
  'column-restricted grant; all writes go through SECURITY DEFINER RPCs. NOT in the realtime publication on purpose: '
  'realtime would deliver whole rows (claimer tokens) — seekers learn state from alert pushes + polling this table.';

create unique index if not exists spot_handoffs_one_active_per_seeker
  on public.spot_handoffs(seeker_id) where status in ('created', 'armed');
create index if not exists spot_handoffs_claimer_idx on public.spot_handoffs(claimer_anon_id) where claimer_anon_id is not null;
create index if not exists spot_handoffs_expiry_idx  on public.spot_handoffs(expires_at) where status in ('created', 'armed');
create index if not exists spot_handoffs_created_idx on public.spot_handoffs(created_at);

alter table public.spot_handoffs enable row level security;
drop policy if exists spot_handoffs_select_own on public.spot_handoffs;
create policy spot_handoffs_select_own on public.spot_handoffs
  for select to authenticated using (seeker_id = auth.uid());
-- no insert/update/delete policy: RPCs only.

-- Table default privileges grant ALL to the API roles; strip them, then give the seeker a SELECT on a fixed column
-- list. `select *` from a client therefore fails (permission denied) by design — clients must name columns.
revoke all on public.spot_handoffs from anon, authenticated;
grant select (id, status, alias, glyph, created_at, leave_at, expires_at, armed_at, departed_at, outcome)
  on public.spot_handoffs to authenticated;

-- ------------------------------------------------------------------------------------------
-- reports / suspensions / pair log / rate events
-- ------------------------------------------------------------------------------------------
create table if not exists public.handoff_reports (
  id              uuid primary key default gen_random_uuid(),
  handoff_id      uuid references public.spot_handoffs(id) on delete set null,
  reporter        text not null check (reporter in ('seeker', 'claimer')),
  reason          text not null check (reason in ('harassment', 'spam', 'unsafe', 'other')),
  subject_user_id uuid references auth.users(id) on delete cascade,   -- the REPORTED party (nullable: unknown claimer)
  created_at      timestamptz not null default now()
);
create unique index if not exists handoff_reports_one_per_side
  on public.handoff_reports(handoff_id, reporter) where handoff_id is not null;
create index if not exists handoff_reports_subject_idx on public.handoff_reports(subject_user_id, created_at);
alter table public.handoff_reports enable row level security;
revoke all on public.handoff_reports from anon, authenticated;

create table if not exists public.handoff_suspensions (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  suspended_at timestamptz not null default now(),
  reason       text not null default 'reports'
);
alter table public.handoff_suspensions enable row level security;
revoke all on public.handoff_suspensions from anon, authenticated;
comment on table public.handoff_suspensions is
  'Lift a suspension by hand: delete from public.handoff_suspensions where user_id = ''<uuid>'';';

create table if not exists public.handoff_pair_log (
  handoff_id uuid primary key,                         -- no FK: must outlive the 24 h row purge for the cooldown
  user_low   uuid not null references auth.users(id) on delete cascade,
  user_high  uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists handoff_pair_log_pair_idx on public.handoff_pair_log(user_low, user_high, created_at);
create index if not exists handoff_pair_log_high_idx on public.handoff_pair_log(user_high);
alter table public.handoff_pair_log enable row level security;
revoke all on public.handoff_pair_log from anon, authenticated;

create table if not exists public.handoff_rate_events (
  id     bigserial primary key,
  bucket text not null,
  key    text not null,          -- user id, handoff id, or HMAC/salted hash of an IP (computed in the Edge Function)
  at     timestamptz not null default now()
);
create index if not exists handoff_rate_events_idx on public.handoff_rate_events(bucket, key, at);
alter table public.handoff_rate_events enable row level security;
revoke all on public.handoff_rate_events from anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Internal helpers
-- ------------------------------------------------------------------------------------------
create or replace function internal.iso(p timestamptz)
returns text language sql immutable set search_path = '' as $$
  select to_char(p at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

create or replace function internal.sha(p text)
returns bytea language sql immutable set search_path = '' as $$
  select sha256(convert_to(coalesce(p, ''), 'UTF8'))
$$;

-- base64url of n random bytes (n=16 -> 128-bit -> 22 chars, spec 3 step 1 and 9 #10/#12)
create or replace function internal.rand_b64url(n int)
returns text language sql volatile set search_path = '' as $$
  select translate(rtrim(replace(encode(extensions.gen_random_bytes(n), 'base64'), E'\n', ''), '='), '+/', '-_')
$$;

create or replace function internal.ct_equal(a bytea, b bytea)
returns boolean language plpgsql immutable set search_path = '' as $$
declare r int := 0; i int;
begin
  if a is null or b is null or length(a) <> length(b) then return false; end if;
  for i in 0 .. length(a) - 1 loop
    r := r | (get_byte(a, i) # get_byte(b, i));
  end loop;
  return r = 0;
end $$;

create or replace function internal.floor5(p timestamptz)
returns timestamptz language sql immutable set search_path = '' as $$
  select to_timestamp(floor(extract(epoch from p) / 300.0) * 300)
$$;

-- Sliding-window limiter. Records the attempt, returns false when over the limit.
create or replace function internal.handoff_rate_hit(p_bucket text, p_key text, p_max int, p_window interval)
returns boolean language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into public.handoff_rate_events (bucket, key) values (p_bucket, p_key);
  select count(*) into n from public.handoff_rate_events
   where bucket = p_bucket and key = p_key and at > now() - p_window;
  return n <= p_max;
end $$;

create or replace function internal.handoff_user_suspended(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_uid is not null and exists (select 1 from public.handoff_suspensions where user_id = p_uid)
$$;

-- Fire-and-forget push dispatch (same Vault + pg_net pattern as 08). pg_net sends AFTER the surrounding transaction
-- commits, so a rolled-back transition never pushes. Fail-open: a dispatch problem never breaks the state change.
-- Body is ONLY {kind, handoff_id}; tokens/alias are looked up by the function — nothing sensitive in the pg_net queue.
create or replace function internal.handoff_push(p_kind text, p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_key text;
begin
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key' limit 1;
    if v_key is null then
      raise log 'send-handoff-push: Vault secret "service_role_key" not found — skipping % for %', p_kind, p_id;
      return;
    end if;
    perform net.http_post(
      url     := 'https://jiispshyqerscdoferaw.functions.supabase.co/send-handoff-push',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
      body    := jsonb_build_object('kind', p_kind, 'handoff_id', p_id)
    );
  exception when others then
    raise log 'send-handoff-push dispatch failed (kind %, sqlstate %): %', p_kind, sqlstate, sqlerrm;
  end;
end $$;

-- Move a live pass to a terminal status. Always nulls the secret hash. Tokens: nulled now unless a push still needs
-- them (p_push_kind not null -> short fuse p_fuse). Pushes the requested kind (or none).
create or replace function internal.handoff_end(p_id uuid, p_status text, p_push_kind text, p_fuse interval)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  select * into r from public.spot_handoffs where id = p_id for update;
  if not found or r.status not in ('created', 'armed') then return; end if;
  update public.spot_handoffs set
      status = p_status,
      claimer_secret_hash = null,
      claimer_push_token = case when p_push_kind is not null and r.claimer_cancelled_at is null then claimer_push_token end,
      claimer_activity_token = case when p_push_kind is not null and r.claimer_cancelled_at is null then claimer_activity_token end,
      claimer_topic = case when p_push_kind is not null and r.claimer_cancelled_at is null then claimer_topic end,
      claimer_tokens_until = case when p_push_kind is not null and r.claimer_cancelled_at is null then now() + p_fuse end
    where id = p_id;
  if p_push_kind is not null and r.status = 'armed' and r.claimer_cancelled_at is null then
    perform internal.handoff_push(p_push_kind, p_id);
  end if;
end $$;

-- ------------------------------------------------------------------------------------------
-- Karma (spec 10). Idempotent via reputation_award_log (source_table='spot_handoffs', source_id=handoff id, kind=role).
-- ------------------------------------------------------------------------------------------
create or replace function internal.handoff_award(p_handoff uuid, p_subject uuid, p_kind text, p_points int, p_helped int)
returns int language plpgsql security definer set search_path = '' as $$
declare v_ins int;
begin
  insert into public.reputation_award_log (subject_id, source_table, source_id, kind)
  values (p_subject, 'spot_handoffs', p_handoff, p_kind)
  on conflict (source_table, source_id, kind, subject_id) do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then return 0; end if;
  insert into public.profiles (id, username, reputation, helped_count)
  values (p_subject, 'neighbor-' || substr(p_subject::text, 1, 8), p_points, p_helped)
  on conflict (id) do update set
    reputation   = public.profiles.reputation + p_points,
    helped_count = public.profiles.helped_count + p_helped,
    updated_at   = now();
  return p_points;
end $$;

-- 3 rewarded handoffs / user / rolling 24 h (distinct handoffs). A handoff already in the user's ledger always passes
-- (so the second reward line of the SAME handoff, e.g. seeker +1 then +2, is not blocked by its own first line).
create or replace function internal.handoff_under_cap(p_handoff uuid, p_subject uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reputation_award_log
                  where source_table = 'spot_handoffs' and source_id = p_handoff and subject_id = p_subject)
      or (select count(distinct source_id) from public.reputation_award_log
           where source_table = 'spot_handoffs' and subject_id = p_subject
             and created_at > now() - interval '24 hours') < 3
$$;

-- Same pair (either direction) rewarded at most once per 24 h, excluding this handoff itself.
create or replace function internal.handoff_pair_cooling(p_handoff uuid, p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.handoff_pair_log
                  where user_low = least(p_a, p_b) and user_high = greatest(p_a, p_b)
                    and handoff_id <> p_handoff and created_at > now() - interval '24 hours')
$$;

-- Driver reward. p_mode 'confirmed' (+5, +3 if the fallback +2 was already paid) or 'fallback' (+2, no seeker).
-- Returns points awarded to the driver.
create or replace function internal.handoff_reward_driver(r public.spot_handoffs, p_mode text)
returns int language plpgsql security definer set search_path = '' as $$
declare v_fb boolean; v_pts int := 0;
begin
  if r.claimer_anon_id is null or r.claimer_anon_id = r.seeker_id then return 0; end if;
  if internal.handoff_user_suspended(r.claimer_anon_id) then return 0; end if;
  if internal.handoff_pair_cooling(r.id, r.seeker_id, r.claimer_anon_id) then return 0; end if;
  if not internal.handoff_under_cap(r.id, r.claimer_anon_id) then return 0; end if;
  select exists (select 1 from public.reputation_award_log
                  where source_table = 'spot_handoffs' and source_id = r.id
                    and subject_id = r.claimer_anon_id and kind = 'handoff_helper_fallback') into v_fb;
  if p_mode = 'fallback' then
    v_pts := internal.handoff_award(r.id, r.claimer_anon_id, 'handoff_helper_fallback', 2, 1);
  else
    v_pts := internal.handoff_award(r.id, r.claimer_anon_id, 'handoff_helper', case when v_fb then 3 else 5 end,
                                    case when v_fb then 0 else 1 end);
  end if;
  if v_pts > 0 then
    insert into public.handoff_pair_log (handoff_id, user_low, user_high)
    values (r.id, least(r.seeker_id, r.claimer_anon_id), greatest(r.seeker_id, r.claimer_anon_id))
    on conflict (handoff_id) do nothing;
  end if;
  return v_pts;
end $$;

-- ------------------------------------------------------------------------------------------
-- Client RPCs (authenticated only)
-- ------------------------------------------------------------------------------------------
create or replace function public.create_handoff(show_name boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid     uuid := auth.uid();
  v_aliases text[] := array[
    'Bodega Cat|bodega_cat', 'Stoop Pigeon|stoop_pigeon', 'Corner Slice|corner_slice', 'Subway Rat|subway_rat',
    'Fire Escape Fern|fire_escape_fern', 'Brownstone Bear|brownstone_bear', 'Hydrant Hound|hydrant_hound',
    'Ferry Gull|ferry_gull', 'Rooftop Owl|rooftop_owl', 'Egg Cream|egg_cream', 'Yellow Cab|yellow_cab',
    'Bagel Bandit|bagel_bandit', 'Metrocard Mouse|metrocard_mouse', 'Park Squirrel|park_squirrel',
    'Bridge Bat|bridge_bat', 'Cart Pretzel|cart_pretzel'];
  v_pick    text;
  v_name    text;
  v_token   text;
  v_row     public.spot_handoffs;
  v_old     uuid;
  v_uname   text;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  if not internal.handoff_enabled() then
    raise exception 'handoff_disabled' using errcode = '55000';
  end if;
  if internal.handoff_user_suspended(v_uid) then
    raise exception 'handoff_suspended' using errcode = 'insufficient_privilege';
  end if;
  if not internal.handoff_rate_hit('create', v_uid::text, 10, interval '1 hour') then
    raise exception 'handoff_rate_limited' using errcode = '53400';
  end if;

  -- One active pass per seeker: starting a new one ends the old (silent to any driver except the handoff_ended push).
  for v_old in select id from public.spot_handoffs where seeker_id = v_uid and status in ('created', 'armed') loop
    perform internal.handoff_end(v_old, 'cancelled', 'handoff_ended', interval '2 minutes');
  end loop;

  v_pick := v_aliases[1 + floor(random() * array_length(v_aliases, 1))::int];
  if show_name then
    select username into v_uname from public.profiles where id = v_uid;
    if v_uname is not null and v_uname not like 'neighbor-%' then
      v_name := left(split_part(btrim(v_uname), ' ', 1), 20);
      if v_name = '' then v_name := null; end if;
    end if;
  end if;

  v_token := internal.rand_b64url(16);   -- 128-bit
  insert into public.spot_handoffs (token_hash, seeker_id, alias, glyph, seeker_display_name, status, expires_at)
  values (internal.sha(v_token), v_uid, split_part(v_pick, '|', 1), split_part(v_pick, '|', 2), v_name,
          'created', now() + interval '20 minutes')
  returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'token', v_token, 'alias', v_row.alias, 'glyph', v_row.glyph,
                            'expires_at', internal.iso(v_row.expires_at));
end $$;

create or replace function public.cancel_handoff(id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.spot_handoffs;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.spot_handoffs h where h.id = cancel_handoff.id and h.seeker_id = v_uid for update;
  if not found or r.status not in ('created', 'armed') then return false; end if;
  -- 'handoff_ended' (silent) tells a full-app driver to close the window and ends the Live Activity (spec 3, 7.1).
  perform internal.handoff_end(r.id, 'cancelled', 'handoff_ended', interval '2 minutes');
  return true;
end $$;

create or replace function public.confirm_handoff_outcome(id uuid, outcome text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  r        public.spot_handoffs;
  v_pts    int := 0;
  v_pair_ok boolean;
  v_any    boolean := false;
  v_n      int;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  if outcome is null or outcome not in ('got_spot', 'no_luck') then
    raise exception 'invalid outcome' using errcode = '22023';
  end if;
  select * into r from public.spot_handoffs h where h.id = confirm_handoff_outcome.id and h.seeker_id = v_uid for update;
  if not found or r.status <> 'departed' then
    return jsonb_build_object('ok', false, 'outcome', null, 'seeker_points', 0);
  end if;
  if r.outcome is not null then   -- idempotent replay: never pays twice, never re-pushes
    return jsonb_build_object('ok', r.outcome = confirm_handoff_outcome.outcome, 'outcome', r.outcome, 'seeker_points', 0);
  end if;

  update public.spot_handoffs set outcome = confirm_handoff_outcome.outcome, outcome_at = now() where public.spot_handoffs.id = r.id;
  r.outcome := confirm_handoff_outcome.outcome;

  -- Karma only when a DIFFERENT, identified user claimed it (spec 10); caps + pair cooldown apply to both sides.
  v_pair_ok := r.claimer_anon_id is not null and r.claimer_anon_id <> r.seeker_id
               and not internal.handoff_user_suspended(r.claimer_anon_id)
               and not internal.handoff_pair_cooling(r.id, r.seeker_id, r.claimer_anon_id);
  if v_pair_ok then
    if internal.handoff_under_cap(r.id, v_uid) then
      v_pts := v_pts + internal.handoff_award(r.id, v_uid, 'handoff_seeker_confirm', 1, 0);
      if outcome = 'got_spot' then
        v_pts := v_pts + internal.handoff_award(r.id, v_uid, 'handoff_seeker_got_spot', 2, 0);
      end if;
      v_any := v_pts > 0;
    end if;
    if outcome = 'got_spot' then
      v_n := internal.handoff_reward_driver(r, 'confirmed');
      v_any := v_any or v_n > 0;
    end if;
    if v_any then
      insert into public.handoff_pair_log (handoff_id, user_low, user_high)
      values (r.id, least(r.seeker_id, r.claimer_anon_id), greatest(r.seeker_id, r.claimer_anon_id))
      on conflict (handoff_id) do nothing;
    end if;
  end if;

  if outcome = 'got_spot' and (r.claimer_push_token is not null or r.claimer_activity_token is not null) then
    -- thanks is one bit, positive only (spec 9 #14). Tokens stay until the push completes or the sweep fuse (<= 2 min).
    update public.spot_handoffs set claimer_tokens_until = now() + interval '2 minutes' where public.spot_handoffs.id = r.id;
    perform internal.handoff_push('thanks', r.id);
  else
    update public.spot_handoffs set claimer_push_token = null, claimer_activity_token = null,
           claimer_topic = null, claimer_tokens_until = null where public.spot_handoffs.id = r.id;
  end if;

  return jsonb_build_object('ok', true, 'outcome', outcome, 'seeker_points', v_pts);
end $$;

create or replace function public.report_handoff(id uuid, reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.spot_handoffs;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  if reason is null or reason not in ('harassment', 'spam', 'unsafe', 'other') then
    raise exception 'invalid reason' using errcode = '22023';
  end if;
  if not internal.handoff_rate_hit('report', v_uid::text, 10, interval '1 hour') then
    raise exception 'handoff_rate_limited' using errcode = '53400';
  end if;
  select * into r from public.spot_handoffs h where h.id = report_handoff.id and h.seeker_id = v_uid;
  if not found then return jsonb_build_object('ok', false); end if;
  perform internal.handoff_record_report(r.id, 'seeker', reason, r.claimer_anon_id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_my_handoff_karma()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_p int; v_c int; v_rep int := 0; v_help int := 0;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  select count(distinct source_id) into v_p from public.reputation_award_log
   where subject_id = v_uid and source_table = 'spot_handoffs' and kind in ('handoff_helper', 'handoff_helper_fallback');
  select count(*) into v_c from public.reputation_award_log
   where subject_id = v_uid and source_table = 'spot_handoffs' and kind = 'handoff_seeker_got_spot';
  select coalesce(reputation, 0), coalesce(helped_count, 0) into v_rep, v_help from public.profiles where id = v_uid;
  return jsonb_build_object('spots_passed', v_p, 'spots_caught', v_c,
                            'helped_count', coalesce(v_help, 0), 'reputation', coalesce(v_rep, 0));
end $$;

-- ------------------------------------------------------------------------------------------
-- Reports (shared by seeker RPC and claimer service RPC). 3 reports against one user within 30 days -> suspended.
-- A report ends the pass immediately (status 'suspended').
-- ------------------------------------------------------------------------------------------
create or replace function internal.handoff_record_report(p_id uuid, p_reporter text, p_reason text, p_subject uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_subject uuid := p_subject; r public.spot_handoffs; n int;
begin
  select * into r from public.spot_handoffs where id = p_id;
  if p_reporter = 'claimer' then v_subject := r.seeker_id; end if;
  insert into public.handoff_reports (handoff_id, reporter, reason, subject_user_id)
  values (p_id, p_reporter, p_reason, v_subject)
  on conflict do nothing;
  perform internal.handoff_end(p_id, 'suspended', case when p_reporter = 'seeker' then 'handoff_ended' end, interval '2 minutes');
  if v_subject is not null then
    select count(*) into n from public.handoff_reports
     where subject_user_id = v_subject and created_at > now() - interval '30 days';
    if n >= 3 then
      insert into public.handoff_suspensions (user_id, reason) values (v_subject, 'reports')
      on conflict (user_id) do nothing;
      -- end any other live pass of the suspended seeker
      perform internal.handoff_end(h.id, 'suspended', 'handoff_ended', interval '2 minutes')
         from public.spot_handoffs h where h.seeker_id = v_subject and h.status in ('created', 'armed');
    end if;
  end if;
end $$;

-- ------------------------------------------------------------------------------------------
-- Service RPCs (service_role only; called by the handoff-* Edge Functions). ALL "not usable" outcomes
-- (bad token / expired / used / self / suspended / wrong secret) return the SAME shape: spec 8 "Errors indistinguishable".
-- p_ip_hash is a salted hash computed by the Edge Function (raw IPs never reach the DB).
-- ------------------------------------------------------------------------------------------
create or replace function public.handoff_peek(p_token text, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if not internal.handoff_rate_hit('peek', coalesce(p_ip_hash, 'unknown'), 30, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  select * into r from public.spot_handoffs where token_hash = internal.sha(p_token);
  if not found or r.status <> 'created' or r.expires_at <= now() or internal.handoff_user_suspended(r.seeker_id) then
    return '{"status":"unavailable"}'::jsonb;
  end if;
  return jsonb_build_object('status', 'open', 'alias', r.alias, 'glyph', r.glyph, 'display_name', r.seeker_display_name);
end $$;

create or replace function public.handoff_claim(
  p_token text, p_leave_at timestamptz, p_push_token text, p_activity_token text, p_topic text,
  p_claimer uuid, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r        public.spot_handoffs;
  v_now    timestamptz := now();
  v_leave  timestamptz;
  v_secret text;
  v_cap    timestamptz := internal.floor5(now() + interval '240 minutes');   -- HANDOFF_MAX_HORIZON_MIN
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if not internal.handoff_rate_hit('claim', coalesce(p_ip_hash, 'unknown'), 20, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  -- value-only validation (independent of the token => reveals nothing about token state). Horizon cap = 240 min.
  if p_leave_at is null or p_leave_at > v_now + interval '240 minutes 30 seconds' or p_leave_at < v_now - interval '10 minutes' then
    return '{"invalid_leave_at":true}'::jsonb;
  end if;

  select * into r from public.spot_handoffs where token_hash = internal.sha(p_token) for update;   -- row lock = atomic single claim
  if not found or r.status <> 'created' or r.expires_at <= v_now then return '{"status":"unavailable"}'::jsonb; end if;
  if internal.handoff_user_suspended(r.seeker_id) or internal.handoff_user_suspended(p_claimer) then
    return '{"status":"unavailable"}'::jsonb;
  end if;
  if p_claimer is not null and p_claimer = r.seeker_id then return '{"status":"unavailable"}'::jsonb; end if;   -- self-scan
  if p_push_token is not null and exists (select 1 from public.device_push_tokens
                                           where user_id = r.seeker_id and apns_token = p_push_token) then
    return '{"status":"unavailable"}'::jsonb;                                                                    -- same device
  end if;

  v_leave  := least(to_timestamp(round(extract(epoch from p_leave_at) / 300.0) * 300), v_cap);   -- round to 5 min
  v_secret := internal.rand_b64url(16);                                                          -- 128-bit
  update public.spot_handoffs set
      status = 'armed', armed_at = v_now, leave_at = v_leave,
      expires_at = v_leave + interval '15 minutes',                                              -- HANDOFF_GRACE_MIN
      claimer_anon_id = p_claimer, claimer_secret_hash = internal.sha(v_secret),
      claimer_push_token = p_push_token, claimer_activity_token = p_activity_token,
      claimer_topic = case when p_push_token is not null or p_activity_token is not null then p_topic end,
      claimer_tokens_until = null
    where id = r.id returning * into r;

  perform internal.handoff_push('armed', r.id);
  return jsonb_build_object('status', 'armed', 'leave_at', internal.iso(r.leave_at),
                            'expires_at', internal.iso(r.expires_at), 'claimer_secret', v_secret);
end $$;

-- shared gate for depart/extend/cancel: returns the locked live row if (id, secret) valid, else NULL id.
create or replace function internal.handoff_gate(p_id uuid, p_secret text)
returns public.spot_handoffs language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  select * into r from public.spot_handoffs where id = p_id for update;
  if not found or r.status <> 'armed' or r.expires_at <= now()
     or not internal.ct_equal(r.claimer_secret_hash, internal.sha(p_secret)) then
    return null;
  end if;
  return r;
end $$;

create or replace function public.handoff_depart(p_id uuid, p_secret text, p_source text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if not internal.handoff_rate_hit('depart', p_id::text, 20, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  if p_source is null or p_source not in ('manual','live_activity','notification','auto','start_driving','shortcut') then
    return '{"invalid_source":true}'::jsonb;
  end if;
  r := internal.handoff_gate(p_id, p_secret);
  if r.id is null then return '{"ok":false}'::jsonb; end if;
  update public.spot_handoffs set
      status = 'departed', departed_at = now(), depart_source = p_source,
      claimer_secret_hash = null,
      claimer_tokens_until = now() + interval '30 minutes'    -- kept ONLY so the seeker's "Got it" can send `thanks`
    where id = r.id;
  perform internal.handoff_push('departed', r.id);
  return '{"ok":true}'::jsonb;
end $$;

create or replace function public.handoff_extend(p_id uuid, p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs; v_new timestamptz; v_cap timestamptz;
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if not internal.handoff_rate_hit('extend', p_id::text, 20, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  r := internal.handoff_gate(p_id, p_secret);
  if r.id is null then return '{"ok":false}'::jsonb; end if;
  v_cap := internal.floor5(r.armed_at + interval '240 minutes');             -- never past the horizon measured from claim
  v_new := greatest(r.leave_at, internal.floor5(now())) + interval '5 minutes';
  if r.extensions >= 3 or v_new > v_cap then return '{"ok":false}'::jsonb; end if;
  update public.spot_handoffs set leave_at = v_new, expires_at = v_new + interval '15 minutes',
         extensions = extensions + 1 where id = r.id returning * into r;
  return jsonb_build_object('ok', true, 'leave_at', internal.iso(r.leave_at), 'expires_at', internal.iso(r.expires_at));
end $$;

-- Driver cancel / "Not leaving": SILENT to the seeker (deviation 2). Status stays 'armed'; the driver side is dead.
create or replace function public.handoff_cancel_claim(p_id uuid, p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if not internal.handoff_rate_hit('cancel', p_id::text, 20, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  r := internal.handoff_gate(p_id, p_secret);
  if r.id is null then return '{"ok":false}'::jsonb; end if;
  update public.spot_handoffs set
      claimer_secret_hash = null, claimer_push_token = null, claimer_activity_token = null,
      claimer_topic = null, claimer_tokens_until = null, claimer_cancelled_at = now()
    where id = r.id;
  return '{"ok":true}'::jsonb;
end $$;

-- Claimer-side report: either BEFORE claiming (token, pass still 'created') or while armed (id + secret).
create or replace function public.handoff_report(p_token text, p_id uuid, p_secret text, p_reason text, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  if not internal.handoff_enabled() then return '{"disabled":true}'::jsonb; end if;
  if p_reason is null or p_reason not in ('harassment', 'spam', 'unsafe', 'other') then
    return '{"invalid_reason":true}'::jsonb;
  end if;
  if not internal.handoff_rate_hit('report', coalesce(p_ip_hash, 'unknown'), 10, interval '1 hour') then
    return '{"rate_limited":true}'::jsonb;
  end if;
  if p_token is not null then
    select * into r from public.spot_handoffs where token_hash = internal.sha(p_token) for update;
    if not found or r.status <> 'created' or r.expires_at <= now() then return '{"ok":false}'::jsonb; end if;
  else
    r := internal.handoff_gate(p_id, p_secret);
    if r.id is null then return '{"ok":false}'::jsonb; end if;
  end if;
  perform internal.handoff_record_report(r.id, 'claimer', p_reason, null);
  return '{"ok":true}'::jsonb;
end $$;

-- send-handoff-push calls this once its sends are done (service role): tokens leave the row immediately.
create or replace function public.handoff_clear_tokens(p_id uuid)
returns void language sql security definer set search_path = '' as $$
  update public.spot_handoffs set claimer_push_token = null, claimer_activity_token = null,
         claimer_topic = null, claimer_tokens_until = null where id = p_id
$$;

-- ------------------------------------------------------------------------------------------
-- Sweep (cron, every minute): expiry, token fuses, fallback karma, purge.
-- ------------------------------------------------------------------------------------------
create or replace function internal.handoff_sweep()
returns void language plpgsql security definer set search_path = '' as $$
declare r public.spot_handoffs;
begin
  -- 1. expiry (unclaimed 20 min TTL; armed = leave_at + 15 min). Tokens nulled with the transition.
  update public.spot_handoffs set status = 'expired', claimer_secret_hash = null, claimer_push_token = null,
         claimer_activity_token = null, claimer_topic = null, claimer_tokens_until = null
   where status in ('created', 'armed') and expires_at <= now();

  -- 2. token fuses (departed 30 min, ended 2 min).
  update public.spot_handoffs set claimer_push_token = null, claimer_activity_token = null,
         claimer_topic = null, claimer_tokens_until = null
   where claimer_tokens_until is not null and claimer_tokens_until <= now();

  -- 3. verified-departure fallback karma: auto/shortcut departure, seeker never confirmed within 30 min -> driver +2.
  for r in select * from public.spot_handoffs
            where status = 'departed' and outcome is null and not fallback_settled
              and depart_source in ('auto', 'shortcut') and departed_at <= now() - interval '30 minutes'
  loop
    perform internal.handoff_reward_driver(r, 'fallback');
    update public.spot_handoffs set fallback_settled = true where id = r.id;
  end loop;

  -- 4. purge (24 h) + housekeeping
  delete from public.spot_handoffs where created_at < now() - interval '24 hours';
  delete from public.handoff_rate_events where at < now() - interval '2 hours';
  delete from public.handoff_pair_log where created_at < now() - interval '48 hours';
  delete from public.handoff_reports where created_at < now() - interval '30 days';
end $$;

-- ------------------------------------------------------------------------------------------
-- Account deletion (extends 10-account-deletion.sql). FKs already cascade (seeker_id, claimer_anon_id, reports.subject,
-- suspensions, pair log) when the final auth.users row goes; this REPLACES delete_my_account() with 10's exact body
-- plus an explicit step so the contract does not lean on FK actions alone. The rate-event key is the user id as text
-- (no FK) so it is deleted explicitly. Same signature, same ACL (authenticated only) as 10.
-- ------------------------------------------------------------------------------------------
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  delete from public.pins where author_id = v_uid and pin_type = 'parked_car';
  update public.pins set claimed_by = null where claimed_by = v_uid;
  update public.pins set author_id = null where author_id = v_uid;
  update public.zone_messages set author_id = null where author_id = v_uid;

  delete from public.votes                 where user_id     = v_uid;
  delete from public.device_push_tokens    where user_id     = v_uid;
  delete from public.reputation_award_log  where subject_id  = v_uid;
  delete from public.pin_evidence          where uploaded_by = v_uid;
  delete from public.block_scoped_report_log where author_id = v_uid;

  -- Spot Pass (13): passes the user created or claimed (reports about those passes go with them via FK set-null,
  -- and reports ABOUT the user cascade on subject_user_id), suspension, pair log, rate counters.
  delete from public.handoff_reports      where subject_user_id = v_uid
     or handoff_id in (select id from public.spot_handoffs where seeker_id = v_uid or claimer_anon_id = v_uid);
  delete from public.spot_handoffs        where seeker_id = v_uid or claimer_anon_id = v_uid;
  delete from public.handoff_suspensions  where user_id = v_uid;
  delete from public.handoff_pair_log     where user_low = v_uid or user_high = v_uid;
  delete from public.handoff_rate_events  where key = v_uid::text;

  delete from public.profiles where id = v_uid;
  delete from auth.users where id = v_uid;
end;
$$;

comment on function public.delete_my_account() is
  'In-app account deletion (Apple 5.1.1(v)). Deletes the CALLER''s own account (auth.uid(); no argument). '
  'Anonymizes (keeps, author -> NULL) pins and zone_messages; deletes profile, votes, device_push_tokens, '
  'reputation/rate-limit ledgers, pin_evidence rows, parked_car pins, Spot Pass rows (13); then deletes the auth.users row. '
  'Idempotent. Authenticated only. See supabase/10-account-deletion.sql header for the iOS contract.';

revoke all on function public.delete_my_account() from public;
revoke all on function public.delete_my_account() from anon;
revoke all on function public.delete_my_account() from authenticated;
revoke all on function public.delete_my_account() from service_role;
grant execute on function public.delete_my_account() to authenticated;

-- ------------------------------------------------------------------------------------------
-- Function ACLs. Postgres grants EXECUTE to PUBLIC on new functions, and Supabase default privileges add
-- anon/authenticated/service_role: strip all, then grant the minimum (same posture as 10/11).
-- ------------------------------------------------------------------------------------------
do $$
declare f text;
begin
  -- client RPCs: authenticated only
  foreach f in array array[
    'public.create_handoff(boolean)', 'public.cancel_handoff(uuid)',
    'public.confirm_handoff_outcome(uuid,text)', 'public.report_handoff(uuid,text)', 'public.get_my_handoff_karma()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- service RPCs: service_role only
  foreach f in array array[
    'public.handoff_peek(text,text)',
    'public.handoff_claim(text,timestamptz,text,text,text,uuid,text)',
    'public.handoff_depart(uuid,text,text)', 'public.handoff_extend(uuid,text)',
    'public.handoff_cancel_claim(uuid,text)', 'public.handoff_report(text,uuid,text,text,text)',
    'public.handoff_clear_tokens(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- internal helpers: nobody but the owner (they are reached only through SECURITY DEFINER functions above)
  for f in
    select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'internal' and p.proname like 'handoff\_%' escape '\'
        or (n.nspname = 'internal' and p.proname in ('iso', 'sha', 'rand_b64url', 'ct_equal', 'floor5'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
  end loop;
end $$;

-- ------------------------------------------------------------------------------------------
-- Cron — LAST on purpose (same sequencing lesson as 03): if pg_cron were unavailable, the paste above is the part
-- that matters; re-run only this block after enabling the extension. Fixed job name => idempotent.
-- ------------------------------------------------------------------------------------------
create extension if not exists pg_cron;
select cron.schedule('handoff-sweep', '* * * * *', $$ select internal.handoff_sweep() $$);

-- Verify after applying (Kevin, SQL Editor):
--   select key, value from public.handoff_config;                                   -- HANDOFF_ENABLED = false
--   select jobname, schedule from cron.job where jobname = 'handoff-sweep';
--   select has_function_privilege('anon','public.create_handoff(boolean)','execute') as anon_create,          -- f
--          has_function_privilege('authenticated','public.create_handoff(boolean)','execute') as authed_create, -- t
--          has_function_privilege('authenticated','public.handoff_claim(text,timestamptz,text,text,text,uuid,text)','execute') as authed_claim, -- f
--          has_function_privilege('service_role','public.handoff_claim(text,timestamptz,text,text,text,uuid,text)','execute') as svc_claim;      -- t
--   select relrowsecurity from pg_class where relname in ('spot_handoffs','handoff_reports','handoff_suspensions','handoff_pair_log','handoff_rate_events','handoff_config');
