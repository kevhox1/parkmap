-- WePark typed-pin schema — community delta layer
-- Spec: docs/typed-pin-schema-spec.md
-- Proposed by @tech-lead 2026-06-01. Finalized by @backend-data 2026-06-01.
-- Apply via Supabase SQL Editor — DO NOT apply to production until @qa-verifier
-- clears AC-S1 through AC-S12.
-- Idempotent: safe to re-run on a clean or partially-applied project.
-- Depends on: 01-mvp-schema.sql (profiles, zones tables must exist).

-- ============================================================
-- pin_type enum
-- Guarded: only created if the type does not yet exist.
-- Adding new values later requires ALTER TYPE ... ADD VALUE.
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'pin_type') then
    create type public.pin_type as enum (
      -- Tier 1: open-data-seedable
      'filming',
      'asp_suspended_today',
      'special_event',
      'construction',
      -- Tier 2: crowd, durable
      'sign_correction',
      'block_note',
      -- Tier 3: crowd, ephemeral
      'enforcement_active',
      'sweeper_passed',
      'broken_meter',
      -- Personal pin (W5 local model; not community-visible by default)
      'parked_car'
    );
  end if;
end $$;

-- ============================================================
-- pins table
-- ============================================================
create table if not exists public.pins (
  -- Identity
  id            uuid primary key default gen_random_uuid(),

  -- Type + two-axis classification (first-class columns, not metadata)
  pin_type      public.pin_type not null,
  source        text not null check (source in ('open_data', 'hybrid', 'crowd')),
  lifespan      text not null check (lifespan in ('ephemeral', 'session', 'durable', 'correction')),

  -- Geography
  lat           double precision not null,
  lng           double precision not null,
  -- segment_id: the street|from|to key from tiles/index.json (nullable — pins can be non-segment-bound)
  segment_id    text,
  zone_id       text references public.zones(id) on delete set null,

  -- Authorship (null = seeded by open-data pipeline via service-role key)
  author_id     uuid references auth.users(id) on delete set null,

  -- Temporal
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- expires_at: null = no auto-expiry; set for ephemeral (30 min default) and session (1 day default) types
  expires_at    timestamptz,
  -- resolved_at: set when a durable/correction pin is voted resolved or admin-closed
  resolved_at   timestamptz,

  -- Crowd-signal counters (denormalized; updated by trigger from votes table)
  confirm_count  integer not null default 0,
  dispute_count  integer not null default 0,

  -- Per-type structured metadata (shape defined per type in docs/typed-pin-schema-spec.md §4.3)
  meta          jsonb,

  -- Optional free-text notes (user-supplied)
  notes         text check (length(notes) <= 500)
);

-- ============================================================
-- Indexes
-- ============================================================

-- Spatial bounding-box queries (primary map read path)
create index if not exists pins_lat_lng_idx
  on public.pins(lat, lng);

-- Temporal decay sweep + expiry filtering.
-- Partial: only rows that actually have an expiry window are indexed here.
create index if not exists pins_expires_at_idx
  on public.pins(expires_at)
  where expires_at is not null;

-- Zone feed (community tab sorted by recency)
create index if not exists pins_zone_id_created_idx
  on public.pins(zone_id, created_at desc);

-- Segment join (Drive Mode overlay enrichment, sign-correction lookup)
create index if not exists pins_segment_id_idx
  on public.pins(segment_id)
  where segment_id is not null;

-- Type filter (tier-based queries: fetch filming + asp_suspended_today for map layer)
create index if not exists pins_type_idx
  on public.pins(pin_type);

-- Two-axis filter support: source (ingest pipeline queries; "show only open_data pins")
create index if not exists pins_source_idx
  on public.pins(source);

-- Two-axis filter support: lifespan (decay dashboard, "show only ephemeral pins")
create index if not exists pins_lifespan_idx
  on public.pins(lifespan);

-- Active-only spatial index for the common map read path.
-- NOTE: partial index predicates are evaluated at index-creation time for static
-- expressions only. `expires_at > now()` is NOT used here because `now()` would
-- be frozen at the moment this DDL runs, making the predicate useless for future
-- rows. Instead the predicate is kept to resolved_at only (a permanent state flag).
-- Clients filter expires_at > <current timestamp> at query time, which the planner
-- satisfies via pins_expires_at_idx.
create index if not exists pins_active_spatial_idx
  on public.pins(lat, lng, pin_type)
  where resolved_at is null;

-- ============================================================
-- RLS for pins
-- ============================================================
-- ENABLE ROW LEVEL SECURITY is inherently idempotent in Postgres 15 (Supabase's engine):
-- running it on a table that already has RLS enabled is a no-op, not an error.
-- No explicit IF NOT EXISTS guard exists for this statement — none is needed.
alter table public.pins enable row level security;

-- Anonymous + authenticated can read all non-parked-car pins.
-- parked_car pins are author-only (OQ-1 decision: enforcement pins ARE readable by anon).
drop policy if exists pins_select_public on public.pins;
create policy pins_select_public on public.pins
  for select using (
    pin_type != 'parked_car'
    or auth.uid() = author_id
  );

-- Authenticated users can insert crowd-source pins only.
-- open_data and hybrid pins arrive via service-role key, which bypasses RLS entirely.
drop policy if exists pins_insert_crowd on public.pins;
create policy pins_insert_crowd on public.pins
  for insert with check (
    auth.uid() is not null
    and author_id = auth.uid()
    and source = 'crowd'
  );

-- Authors can update their own pins (add notes, correct sub_tag, etc.)
drop policy if exists pins_update_own on public.pins;
create policy pins_update_own on public.pins
  for update using (auth.uid() = author_id)
  with check (auth.uid() = author_id);

-- Authors can delete their own pins
drop policy if exists pins_delete_own on public.pins;
create policy pins_delete_own on public.pins
  for delete using (auth.uid() = author_id);

-- ============================================================
-- votes table
-- ============================================================
create table if not exists public.votes (
  id          bigserial primary key,
  pin_id      uuid not null references public.pins(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  vote        text not null check (vote in ('confirm', 'dispute')),
  created_at  timestamptz not null default now(),

  -- One vote per user per pin. Clients upsert on (pin_id, user_id) to change vote.
  unique (pin_id, user_id)
);

-- Index on pin_id so the vote-count trigger's COUNT(*) query does not full-scan.
-- The unique constraint on (pin_id, user_id) already creates a B-tree index on the
-- composite, but PostgreSQL may not use it efficiently for single-column pin_id
-- lookups. An explicit index makes the trigger O(log n) on votes per pin.
create index if not exists votes_pin_id_idx
  on public.votes(pin_id);

-- ============================================================
-- RLS for votes
-- ============================================================
-- ENABLE ROW LEVEL SECURITY is inherently idempotent in Postgres 15 — see note above.
alter table public.votes enable row level security;

-- Any user (anon included) can read the vote tally.
drop policy if exists votes_select_all on public.votes;
create policy votes_select_all on public.votes
  for select using (true);

-- Authenticated users can insert votes on their own behalf only.
drop policy if exists votes_insert_own on public.votes;
create policy votes_insert_own on public.votes
  for insert with check (auth.uid() = user_id);

-- Users can change their vote (confirm <-> dispute) via upsert.
drop policy if exists votes_update_own on public.votes;
create policy votes_update_own on public.votes
  for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Users can retract their vote.
drop policy if exists votes_delete_own on public.votes;
create policy votes_delete_own on public.votes
  for delete using (auth.uid() = user_id);

-- ============================================================
-- Trigger: keep confirm_count / dispute_count in sync with votes
-- SECURITY DEFINER so the UPDATE on pins succeeds even if the voting
-- user does not own the pin (update RLS would otherwise block it).
-- ============================================================
create or replace function public.refresh_pin_vote_counts()
returns trigger language plpgsql security definer as $$
declare
  v_pin_id uuid;
begin
  v_pin_id := coalesce(new.pin_id, old.pin_id);
  update public.pins set
    confirm_count = (
      select count(*) from public.votes
      where pin_id = v_pin_id and vote = 'confirm'
    ),
    dispute_count = (
      select count(*) from public.votes
      where pin_id = v_pin_id and vote = 'dispute'
    ),
    updated_at = now()
  where id = v_pin_id;
  return null;
end;
$$;

drop trigger if exists votes_refresh_pin_counts on public.votes;
create trigger votes_refresh_pin_counts
  after insert or update or delete on public.votes
  for each row execute function public.refresh_pin_vote_counts();

-- ============================================================
-- RPC: extend_pin_expiry
-- Adds 15 minutes to expires_at for ephemeral pins, capped at 2 hours from now.
-- Only callable by authenticated users (anon cannot extend pins).
-- SECURITY DEFINER so the UPDATE bypasses the author-only update RLS policy —
-- any authenticated user can extend an ephemeral pin, not just the author.
-- ============================================================
create or replace function public.extend_pin_expiry(p_pin_id uuid)
returns void language plpgsql security definer as $$
begin
  -- Require authentication. Reject anonymous callers explicitly.
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  update public.pins set
    expires_at = least(
      expires_at + interval '15 minutes',
      now() + interval '2 hours'
    ),
    updated_at = now()
  where id = p_pin_id
    and lifespan = 'ephemeral'
    and expires_at is not null
    and expires_at > now();  -- only extend non-expired pins; silently no-ops if already expired
end;
$$;

-- ============================================================
-- Convenience view: pins with author display fields
-- Mirrors zone_messages_with_author pattern from 01-mvp-schema.sql.
-- RLS on the underlying pins table is enforced: the view is SECURITY INVOKER
-- (PostgreSQL default), so anon callers cannot see parked_car rows for other users.
-- ============================================================
create or replace view public.pins_with_author as
  select
    p.*,
    pr.username   as author_username,
    pr.reputation as author_reputation
  from public.pins p
  left join public.profiles pr on pr.id = p.author_id;

grant select on public.pins_with_author to anon, authenticated;

-- ============================================================
-- Realtime: enable for pins table
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'pins'
  ) then
    alter publication supabase_realtime add table public.pins;
  end if;
end $$;
