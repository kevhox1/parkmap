-- WePark MVP schema — chat foundation
-- Run this in Supabase SQL Editor (Project → SQL → New Query → paste → Run).
-- Idempotent: safe to re-run.

-- ============================================================
-- Profiles: pseudonymous user public data
-- ============================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  reputation integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_username_idx on public.profiles(lower(username));

alter table public.profiles enable row level security;

drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_all on public.profiles
  for select using (true);

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
  for insert with check (auth.uid() = id);

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update using (auth.uid() = id);

-- ============================================================
-- Zones: community channels (geographic)
-- ============================================================
create table if not exists public.zones (
  id text primary key,
  name text not null,
  description text,
  lat_min double precision not null,
  lat_max double precision not null,
  lng_min double precision not null,
  lng_max double precision not null,
  created_at timestamptz not null default now()
);

alter table public.zones enable row level security;

drop policy if exists zones_select_all on public.zones;
create policy zones_select_all on public.zones
  for select using (true);

-- Seed: SOHO/LES zone
insert into public.zones (id, name, description, lat_min, lat_max, lng_min, lng_max)
values (
  'soho-les',
  'SOHO/LES',
  'Soho, Nolita, Lower East Side, East Village',
  40.713, 40.732,
  -74.006, -73.973
)
on conflict (id) do update set
  name = excluded.name,
  description = excluded.description,
  lat_min = excluded.lat_min,
  lat_max = excluded.lat_max,
  lng_min = excluded.lng_min,
  lng_max = excluded.lng_max;

-- ============================================================
-- Zone messages: chat + auto-system messages
-- ============================================================
create table if not exists public.zone_messages (
  id bigserial primary key,
  zone_id text not null references public.zones(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null,
  message_type text not null default 'user' check (message_type in ('user', 'system_tracker')),
  body text not null check (length(body) between 1 and 1000),
  related_report_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists zone_messages_zone_created_idx
  on public.zone_messages(zone_id, created_at desc);

alter table public.zone_messages enable row level security;

drop policy if exists zone_messages_select_all on public.zone_messages;
create policy zone_messages_select_all on public.zone_messages
  for select using (true);

drop policy if exists zone_messages_insert_user on public.zone_messages;
create policy zone_messages_insert_user on public.zone_messages
  for insert with check (
    auth.uid() is not null
    and author_id = auth.uid()
    and message_type = 'user'
  );

-- System messages (cross-pollination from tracker reports) get inserted
-- via a SECURITY DEFINER RPC that bypasses RLS — that RPC will be added
-- in the next migration when the tracker schema lands.

-- ============================================================
-- Realtime: enable for zone_messages
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'zone_messages'
  ) then
    alter publication supabase_realtime add table public.zone_messages;
  end if;
end $$;

-- ============================================================
-- Helpers
-- ============================================================

-- Convenience view that joins messages with author username for the client.
-- Useful when supabase-js wants username inline without a separate fetch.
create or replace view public.zone_messages_with_author as
  select
    m.id,
    m.zone_id,
    m.author_id,
    m.message_type,
    m.body,
    m.related_report_id,
    m.created_at,
    p.username as author_username,
    p.reputation as author_reputation
  from public.zone_messages m
  left join public.profiles p on p.id = m.author_id;

grant select on public.zone_messages_with_author to anon, authenticated;
