# WePark Tracker, Supabase MVP Schema

## Goal
Ship the fastest real backend for the threat tracker while keeping the frontend on GitHub Pages.

This plan assumes:
- static frontend stays in `index.html`
- Supabase handles Postgres, Auth, Realtime, and RLS
- anonymous/public read is allowed
- login is required only for write actions
- structured reports are the product core, comments stay lightweight

The design below is intentionally biased toward **working fast**, not perfect long-term purity.

---

## MVP architecture decision

### Keep the frontend static
- GitHub Pages serves the app
- browser talks directly to Supabase with the public anon key
- no custom Node API for MVP

### Put write rules behind RPCs
For the MVP, the browser should **not** insert/update `tracker_reports` directly.

Instead:
- reads use table/view queries and a couple of read RPCs
- writes go through Postgres RPC functions

Why this is the fastest sane path:
- merge rules live in one place
- TTL refresh logic stays server-side
- rate limiting and auth checks are easier
- the frontend stays simple

---

## Canonical identity, use a stable text `block_face_id`

Use a deterministic text key instead of a random UUID for block faces.

That is faster for this repo because the current frontend already thinks in:
- `street`
- `from`
- `to`
- `side`

### Recommended format
```text
normalize(street) + '__' + normalize(from_street) + '__' + normalize(to_street) + '__' + side
```

Example:
```text
MULBERRY_ST__PRINCE_ST__SPRING_ST__W
```

This lets the browser derive the same ID from the current segment data without a lookup round-trip.

---

## Recommended schema overview

### Tables
- `block_faces`
- `profiles`
- `tracker_reports`
- `report_confirmations`
- `report_comments`
- `report_events`

### Views
- `tracker_reports_live`

### RPC functions
- `tracker_get_active_reports_in_bbox(...)`
- `tracker_get_nearby_feed(...)`
- `tracker_get_block_face_detail(...)`
- `tracker_create_report(...)`
- `tracker_confirm_report(...)`
- `tracker_mark_block_cleaned(...)`
- `tracker_add_comment(...)`
- `tracker_retract_report(...)`
- `tracker_expire_reports()`

---

## SQL draft

This is SQL-like and close enough to execute with small adjustments.

```sql
create extension if not exists pgcrypto;
create extension if not exists postgis;

-- Optional if available on the project for scheduled expiry cleanup.
-- create extension if not exists pg_cron;

create type tracker_report_type as enum (
  'sweeper',
  'ticket_agent',
  'block_cleaned'
);

create type tracker_report_status as enum (
  'active',
  'expired',
  'retracted'
);

create type tracker_direction_mode as enum (
  'toward_from',
  'toward_to',
  'unknown'
);

create type tracker_confirmation_kind as enum (
  'create',
  'confirm',
  'pass'
);

create type tracker_event_type as enum (
  'created',
  'confirmed',
  'pass_incremented',
  'commented',
  'retracted',
  'expired'
);

create table public.block_faces (
  id text primary key,
  street text not null,
  from_street text not null,
  to_street text not null,
  side text not null check (side in ('N','S','E','W')),
  label text not null,
  street_norm text not null,
  from_street_norm text not null,
  to_street_norm text not null,
  center geometry(Point, 4326) not null,
  geom geometry(LineString, 4326) not null,
  bbox geometry(Polygon, 4326),
  asp_rules jsonb not null default '[]'::jsonb,
  has_asp boolean not null default false,
  source_segment_ids text[] not null default '{}',
  tile_keys text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (street_norm, from_street_norm, to_street_norm, side)
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  trust_score numeric(6,2) not null default 0,
  is_limited boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tracker_reports (
  id uuid primary key default gen_random_uuid(),
  type tracker_report_type not null,
  block_face_id text not null references public.block_faces(id) on delete cascade,
  reporter_user_id uuid not null references public.profiles(id) on delete restrict,
  status tracker_report_status not null default 'active',
  is_hidden boolean not null default false,
  note text,
  direction_mode tracker_direction_mode,
  direction_label_cache text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null,
  retracted_at timestamptz,
  confirm_count integer not null default 1,
  distinct_reporter_count integer not null default 1,
  confidence smallint not null default 1,
  asp_window_start_at timestamptz,
  asp_window_end_at timestamptz,
  pass_count integer not null default 1,
  last_pass_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  check (note is null or char_length(note) <= 140),
  check (confirm_count >= 0),
  check (distinct_reporter_count >= 0),
  check (pass_count >= 1),
  check (
    (type in ('sweeper', 'ticket_agent') and asp_window_start_at is null and asp_window_end_at is null)
    or
    (type = 'block_cleaned' and asp_window_start_at is not null and asp_window_end_at is not null and last_pass_at is not null)
  ),
  check (
    (type = 'block_cleaned' and direction_mode is null)
    or
    (type in ('sweeper', 'ticket_agent'))
  )
);

create unique index tracker_reports_block_cleaned_window_uniq
  on public.tracker_reports (block_face_id, asp_window_start_at, type)
  where type = 'block_cleaned';

create table public.report_confirmations (
  report_id uuid not null references public.tracker_reports(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_kind tracker_confirmation_kind not null default 'confirm',
  confirmations_count integer not null default 1,
  primary key (report_id, user_id)
);

create table public.report_comments (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.tracker_reports(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (char_length(body) between 1 and 280)
);

create table public.report_events (
  id bigint generated always as identity primary key,
  report_id uuid not null references public.tracker_reports(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  event_type tracker_event_type not null,
  created_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb
);

create index block_faces_center_gix on public.block_faces using gist (center);
create index block_faces_geom_gix on public.block_faces using gist (geom);
create index block_faces_tile_keys_idx on public.block_faces using gin (tile_keys);

create index tracker_reports_live_idx
  on public.tracker_reports (status, is_hidden, expires_at desc, created_at desc);

create index tracker_reports_block_face_idx
  on public.tracker_reports (block_face_id, created_at desc);

create index tracker_reports_reporter_idx
  on public.tracker_reports (reporter_user_id, created_at desc);

create index tracker_reports_type_direction_idx
  on public.tracker_reports (type, block_face_id, direction_mode, expires_at desc)
  where type in ('sweeper', 'ticket_agent');

create index report_confirmations_user_idx
  on public.report_confirmations (user_id, last_seen_at desc);

create index report_comments_report_idx
  on public.report_comments (report_id, created_at asc)
  where deleted_at is null and is_hidden = false;

create index report_events_report_idx
  on public.report_events (report_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger set_updated_at_block_faces
before update on public.block_faces
for each row execute function public.set_updated_at();

create trigger set_updated_at_profiles
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger set_updated_at_tracker_reports
before update on public.tracker_reports
for each row execute function public.set_updated_at();

create trigger set_updated_at_report_comments
before update on public.report_comments
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();
```

---

## Live view for normal reads

```sql
create or replace view public.tracker_reports_live
with (security_invoker = true)
as
select
  r.id,
  r.type,
  r.block_face_id,
  r.reporter_user_id,
  r.status,
  r.note,
  r.direction_mode,
  r.direction_label_cache,
  r.created_at,
  r.updated_at,
  r.last_seen_at,
  r.expires_at,
  r.confirm_count,
  r.distinct_reporter_count,
  r.confidence,
  r.asp_window_start_at,
  r.asp_window_end_at,
  r.pass_count,
  r.last_pass_at,
  bf.label as block_label,
  bf.street,
  bf.from_street,
  bf.to_street,
  bf.side,
  st_y(bf.center) as lat,
  st_x(bf.center) as lng,
  (r.distinct_reporter_count >= 2) as is_verified
from public.tracker_reports r
join public.block_faces bf on bf.id = r.block_face_id
where r.status = 'active'
  and r.is_hidden = false
  and r.expires_at > now();
```

Frontend reads should normally use `tracker_reports_live`, not raw `tracker_reports`.

---

## Block-cleaned semantics and `pass_count`

This is the most important special case.

### Rule
There is only **one** `block_cleaned` report row for a block face during a given ASP window.

Uniqueness key:
- `block_face_id`
- `type = 'block_cleaned'`
- `asp_window_start_at`

### Behavior
#### First cleaned report in the window
- create one `tracker_reports` row
- `pass_count = 1`
- `last_pass_at = now()`
- `expires_at = asp_window_end_at`

#### Another pass is seen later in the same window
Do **not** create another report row.

Instead update the existing row:
- `pass_count = pass_count + 1`
- `last_pass_at = now()`
- `last_seen_at = now()`
- `confirm_count = confirm_count + 1`
- `distinct_reporter_count` increments only if this user has never supported this report before

### Why this is right
The UI wants to show:
- `Cleaned`
- `Cleaned x2`
- `Cleaned x3, last pass 10:51 AM`

That is one evolving state object, not a stack of duplicate posts.

---

## TTL / expiry handling

### Moving threats
For `sweeper` and `ticket_agent`:
- default TTL = 15 minutes
- `expires_at = now() + interval '15 minutes'`
- confirming a live report resets `expires_at` to `now() + interval '15 minutes'`

### Cleaned blocks
For `block_cleaned`:
- `expires_at = asp_window_end_at`
- no 15-minute TTL
- validity lasts through the active ASP window

### Practical expiry strategy
Use **both** of these:

#### 1. Read-time protection
Every normal read hits `tracker_reports_live`, which already filters:
- `status = 'active'`
- `expires_at > now()`

So an expired report disappears from reads immediately, even if cleanup is a minute late.

#### 2. Scheduled cleanup for realtime correctness
Run `tracker_expire_reports()` every minute.

That function should:
- mark expired rows from `active` to `expired`
- insert an `expired` row in `report_events`

This matters because Realtime subscribers need an update event when a report ages out.

---

## RLS and auth approach

### Public reads
Allow `anon` and `authenticated` to read:
- `block_faces`
- `tracker_reports_live`
- visible `report_comments`
- visible `report_events`

### Auth required for writes
Require `authenticated` for:
- creating reports
- confirming reports
- incrementing block-cleaned passes
- adding comments
- retracting own reports

### Important MVP simplification
Use regular Supabase auth for write actions:
- email magic link is enough for MVP
- add Google later if desired

Do **not** require a username or onboarding step.

### Policy draft
```sql
alter table public.block_faces enable row level security;
alter table public.profiles enable row level security;
alter table public.tracker_reports enable row level security;
alter table public.report_confirmations enable row level security;
alter table public.report_comments enable row level security;
alter table public.report_events enable row level security;

create policy "public read block_faces"
  on public.block_faces for select
  using (true);

create policy "read own profile"
  on public.profiles for select
  using (auth.uid() = id);

create policy "update own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "public read visible tracker_reports"
  on public.tracker_reports for select
  using (
    (is_hidden = false and status <> 'retracted')
    or reporter_user_id = auth.uid()
  );

create policy "public read visible comments"
  on public.report_comments for select
  using (is_hidden = false and deleted_at is null);

create policy "authenticated insert comments"
  on public.report_comments for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "authors update own comments"
  on public.report_comments for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "public read events"
  on public.report_events for select
  using (true);
```

### Direct write rule for reports
Do **not** create insert/update policies for `tracker_reports` from the browser.

Instead:
- revoke raw writes
- expose only the RPCs below

That keeps merge rules and expiry refresh logic server-side.

---

## RPC contract, preferred MVP path

The frontend should use a tiny wrapper around Supabase and call these functions.

---

## RPC 1, `tracker_get_active_reports_in_bbox`

### Purpose
Fetch live tracker markers for the current map viewport.

### Signature
```sql
tracker_get_active_reports_in_bbox(
  p_west double precision,
  p_south double precision,
  p_east double precision,
  p_north double precision
)
returns setof public.tracker_reports_live
```

### Query logic
Use the block face center point for the viewport test.

```sql
... where st_intersects(
  bf.center,
  st_makeenvelope(p_west, p_south, p_east, p_north, 4326)
)
```

### Returned shape
```ts
type ActiveTrackerReport = {
  id: string
  type: 'sweeper' | 'ticket_agent' | 'block_cleaned'
  block_face_id: string
  block_label: string
  street: string
  from_street: string
  to_street: string
  side: 'N' | 'S' | 'E' | 'W'
  direction_mode: 'toward_from' | 'toward_to' | 'unknown' | null
  direction_label_cache: string | null
  note: string | null
  created_at: string
  last_seen_at: string
  expires_at: string
  confirm_count: number
  distinct_reporter_count: number
  pass_count: number | null
  last_pass_at: string | null
  asp_window_start_at: string | null
  asp_window_end_at: string | null
  lat: number
  lng: number
  is_verified: boolean
}
```

---

## RPC 2, `tracker_get_nearby_feed`

### Purpose
Fetch the micro-neighborhood feed, default 400m.

### Signature
```sql
tracker_get_nearby_feed(
  p_lat double precision,
  p_lng double precision,
  p_radius_m integer default 400,
  p_limit integer default 50
)
returns table (...)
```

### Behavior
- reads from `tracker_reports_live`
- joins `block_faces`
- filters by `st_dwithin(center::geography, point::geography, p_radius_m)`
- sorts by freshness, then distance

### Returned shape
```ts
type NearbyFeedItem = ActiveTrackerReport & {
  distance_m: number
}
```

---

## RPC 3, `tracker_get_block_face_detail`

### Purpose
Power the bottom sheet for one block face.

### Signature
```sql
tracker_get_block_face_detail(
  p_block_face_id text
)
returns jsonb
```

### Returned shape
```ts
type BlockFaceDetail = {
  blockFace: {
    id: string
    label: string
    street: string
    from_street: string
    to_street: string
    side: 'N' | 'S' | 'E' | 'W'
    has_asp: boolean
    asp_rules: unknown[]
    lat: number
    lng: number
  }
  activeReports: ActiveTrackerReport[]
  recentEvents: Array<{
    id: number
    event_type: 'created' | 'confirmed' | 'pass_incremented' | 'commented' | 'retracted' | 'expired'
    created_at: string
    user_id: string | null
    payload: Record<string, unknown>
  }>
  comments: Array<{
    id: string
    report_id: string
    user_id: string
    body: string
    created_at: string
  }>
}
```

### Notes
For MVP, comments can be fetched here together with the block detail so the frontend does not need extra round trips.

---

## RPC 4, `tracker_create_report`

### Purpose
Create a new moving-threat report, or merge into an existing live report if it is the same thing.

### Signature
```sql
tracker_create_report(
  p_block_face_id text,
  p_type tracker_report_type,
  p_direction_mode tracker_direction_mode default null,
  p_note text default null
)
returns public.tracker_reports_live
```

### Allowed types
Only:
- `sweeper`
- `ticket_agent`

If `p_type = 'block_cleaned'`, reject and force the dedicated RPC.

### Merge rule
If an active row already exists with:
- same `block_face_id`
- same `type`
- same `direction_mode`
- `expires_at > now()`

then do not create a new report. Instead:
- update `last_seen_at = now()`
- update `expires_at = now() + interval '15 minutes'`
- increment `confirm_count`
- increment `distinct_reporter_count` only if caller has not supported it before
- insert `confirmed` event
- upsert `report_confirmations`

Else create a new report row and log `created`.

### Direction label cache
Set on write so the UI can render without recalculating.

Example:
- `toward_from` => `Toward Prince St`
- `toward_to` => `Toward Spring St`

### Returned shape
Return the merged or created report object in `tracker_reports_live` shape.

---

## RPC 5, `tracker_confirm_report`

### Purpose
Confirm an existing live moving threat.

### Signature
```sql
tracker_confirm_report(
  p_report_id uuid
)
returns public.tracker_reports_live
```

### Behavior
For `sweeper` and `ticket_agent`:
- row must still be live
- `confirm_count += 1`
- `distinct_reporter_count += 1` only if new supporter
- `last_seen_at = now()`
- `expires_at = now() + interval '15 minutes'`
- upsert `report_confirmations`
- insert `confirmed` event

For `block_cleaned`:
- reject, use `tracker_mark_block_cleaned` instead

---

## RPC 6, `tracker_mark_block_cleaned`

### Purpose
Create or update the one active `block_cleaned` report for the current ASP window.

### Signature
```sql
tracker_mark_block_cleaned(
  p_block_face_id text,
  p_asp_window_start_at timestamptz,
  p_asp_window_end_at timestamptz,
  p_note text default null
)
returns public.tracker_reports_live
```

### MVP validation rules
Server should validate:
- caller is authenticated
- block face exists
- `block_faces.has_asp = true`
- `now()` is between `p_asp_window_start_at` and `p_asp_window_end_at`
- window length is sane, for example `<= 6 hours`

### Important implementation note
For MVP speed, the **frontend resolves the current ASP window** using the existing JS rule parser and the `asp_rules` already attached to the selected block face.

The DB function just sanity-checks the submitted window.

That is the fastest path because the app already has ASP logic in the browser.

If this becomes too easy to abuse later, move this validation to a server-side Edge Function.

### Behavior
#### If no row exists for this block/window
Insert:
- `type = 'block_cleaned'`
- `expires_at = p_asp_window_end_at`
- `pass_count = 1`
- `last_pass_at = now()`
- `confirm_count = 1`
- `distinct_reporter_count = 1`
- insert `created` event
- upsert `report_confirmations` with kind `create`

#### If the row already exists
Update:
- `pass_count = pass_count + 1`
- `last_pass_at = now()`
- `last_seen_at = now()`
- `confirm_count = confirm_count + 1`
- `distinct_reporter_count += 1` only if this user is new to the report
- insert `pass_incremented` event
- upsert `report_confirmations` with kind `pass`

### Returned shape
Return the current live cleaned report.

---

## RPC 7, `tracker_add_comment`

### Purpose
Add a lightweight comment to a report.

### Signature
```sql
tracker_add_comment(
  p_report_id uuid,
  p_body text
)
returns public.report_comments
```

### Behavior
- authenticated only
- reject if parent report is hidden/retracted
- allow comments on live reports and very recent expired reports, recommended grace period `2 hours`
- insert `commented` event with `comment_id`

### Comment product rule
Keep comments flat and short.

No threaded replies, no reactions, no rich formatting in MVP.

---

## RPC 8, `tracker_retract_report`

### Purpose
Let the original reporter retract their own report.

### Signature
```sql
tracker_retract_report(
  p_report_id uuid
)
returns public.tracker_reports
```

### Behavior
Allow when:
- caller is `reporter_user_id`
- report is still active

Then:
- set `status = 'retracted'`
- set `retracted_at = now()`
- set `expires_at = now()`
- insert `retracted` event

Optional MVP restriction:
- only allow retract within 30 minutes of creation

---

## RPC 9, `tracker_expire_reports`

### Purpose
Turn stale active reports into expired rows so Realtime subscribers see a change.

### Signature
```sql
tracker_expire_reports()
returns integer
```

### Behavior
```sql
update public.tracker_reports
set status = 'expired', updated_at = now()
where status = 'active'
  and expires_at <= now();
```

Then insert matching `expired` events.

### Scheduling
Run every minute if `pg_cron` or scheduled functions are available.

Example intent:
```sql
select cron.schedule(
  'tracker-expire-reports',
  '* * * * *',
  $$select public.tracker_expire_reports();$$
);
```

If cron is unavailable, use a Supabase scheduled Edge Function instead.

---

## Core write RPC logic, SQL skeletons

These are intentionally partial, but they show the exact backend shape that should be implemented.

### `tracker_create_report(...)`

```sql
create or replace function public.tracker_create_report(
  p_block_face_id text,
  p_type tracker_report_type,
  p_direction_mode tracker_direction_mode default null,
  p_note text default null
)
returns public.tracker_reports_live
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_existing public.tracker_reports;
  v_existing_confirmation public.report_confirmations;
  v_is_new_supporter boolean := false;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_type = 'block_cleaned' then
    raise exception 'USE_TRACKER_MARK_BLOCK_CLEANED';
  end if;

  select * into v_existing
  from public.tracker_reports
  where block_face_id = p_block_face_id
    and type = p_type
    and coalesce(direction_mode, 'unknown') = coalesce(p_direction_mode, 'unknown')
    and status = 'active'
    and is_hidden = false
    and expires_at > now()
  order by created_at desc
  limit 1;

  if found then
    select * into v_existing_confirmation
    from public.report_confirmations
    where report_id = v_existing.id
      and user_id = v_user_id;

    v_is_new_supporter := not found;

    insert into public.report_confirmations (report_id, user_id, last_kind)
    values (v_existing.id, v_user_id, 'confirm')
    on conflict (report_id, user_id)
    do update set
      last_seen_at = now(),
      last_kind = 'confirm',
      confirmations_count = public.report_confirmations.confirmations_count + 1;

    update public.tracker_reports
    set last_seen_at = now(),
        expires_at = now() + interval '15 minutes',
        confirm_count = confirm_count + 1,
        distinct_reporter_count = distinct_reporter_count + case when v_is_new_supporter then 1 else 0 end,
        confidence = least(3, greatest(1, distinct_reporter_count + case when v_is_new_supporter then 1 else 0 end))
    where id = v_existing.id;

    insert into public.report_events (report_id, user_id, event_type, payload)
    values (v_existing.id, v_user_id, 'confirmed', jsonb_build_object('kind', 'confirm'));

    return (
      select l from public.tracker_reports_live l where l.id = v_existing.id
    );
  end if;

  insert into public.tracker_reports (
    type,
    block_face_id,
    reporter_user_id,
    status,
    note,
    direction_mode,
    direction_label_cache,
    expires_at,
    last_seen_at,
    confirm_count,
    distinct_reporter_count,
    confidence
  )
  select
    p_type,
    p_block_face_id,
    v_user_id,
    'active',
    p_note,
    p_direction_mode,
    case
      when p_direction_mode = 'toward_from' then 'Toward ' || bf.from_street
      when p_direction_mode = 'toward_to' then 'Toward ' || bf.to_street
      else 'Direction unknown'
    end,
    now() + interval '15 minutes',
    now(),
    1,
    1,
    1
  from public.block_faces bf
  where bf.id = p_block_face_id
  returning * into v_existing;

  insert into public.report_confirmations (report_id, user_id, last_kind)
  values (v_existing.id, v_user_id, 'create')
  on conflict do nothing;

  insert into public.report_events (report_id, user_id, event_type)
  values (v_existing.id, v_user_id, 'created');

  return (
    select l from public.tracker_reports_live l where l.id = v_existing.id
  );
end;
$$;
```

### `tracker_mark_block_cleaned(...)`

```sql
create or replace function public.tracker_mark_block_cleaned(
  p_block_face_id text,
  p_asp_window_start_at timestamptz,
  p_asp_window_end_at timestamptz,
  p_note text default null
)
returns public.tracker_reports_live
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_report public.tracker_reports;
  v_existing_confirmation public.report_confirmations;
  v_is_new_supporter boolean := false;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_asp_window_end_at <= now() or p_asp_window_start_at > now() then
    raise exception 'ASP_WINDOW_NOT_ACTIVE';
  end if;

  if extract(epoch from (p_asp_window_end_at - p_asp_window_start_at)) > 21600 then
    raise exception 'ASP_WINDOW_TOO_LONG';
  end if;

  perform 1
  from public.block_faces bf
  where bf.id = p_block_face_id
    and bf.has_asp = true;

  if not found then
    raise exception 'INVALID_BLOCK_FACE_OR_NO_ASP';
  end if;

  select * into v_report
  from public.tracker_reports
  where block_face_id = p_block_face_id
    and type = 'block_cleaned'
    and asp_window_start_at = p_asp_window_start_at
  limit 1;

  if found then
    select * into v_existing_confirmation
    from public.report_confirmations
    where report_id = v_report.id
      and user_id = v_user_id;

    v_is_new_supporter := not found;

    insert into public.report_confirmations (report_id, user_id, last_kind)
    values (v_report.id, v_user_id, 'pass')
    on conflict (report_id, user_id)
    do update set
      last_seen_at = now(),
      last_kind = 'pass',
      confirmations_count = public.report_confirmations.confirmations_count + 1;

    update public.tracker_reports
    set status = 'active',
        last_seen_at = now(),
        expires_at = p_asp_window_end_at,
        last_pass_at = now(),
        pass_count = pass_count + 1,
        confirm_count = confirm_count + 1,
        distinct_reporter_count = distinct_reporter_count + case when v_is_new_supporter then 1 else 0 end,
        confidence = least(3, greatest(1, distinct_reporter_count + case when v_is_new_supporter then 1 else 0 end))
    where id = v_report.id;

    insert into public.report_events (report_id, user_id, event_type, payload)
    values (v_report.id, v_user_id, 'pass_incremented', jsonb_build_object('pass_count_delta', 1));

    return (
      select l from public.tracker_reports_live l where l.id = v_report.id
    );
  end if;

  insert into public.tracker_reports (
    type,
    block_face_id,
    reporter_user_id,
    status,
    note,
    expires_at,
    last_seen_at,
    asp_window_start_at,
    asp_window_end_at,
    pass_count,
    last_pass_at,
    confirm_count,
    distinct_reporter_count,
    confidence
  ) values (
    'block_cleaned',
    p_block_face_id,
    v_user_id,
    'active',
    p_note,
    p_asp_window_end_at,
    now(),
    p_asp_window_start_at,
    p_asp_window_end_at,
    1,
    now(),
    1,
    1,
    1
  ) returning * into v_report;

  insert into public.report_confirmations (report_id, user_id, last_kind)
  values (v_report.id, v_user_id, 'create')
  on conflict do nothing;

  insert into public.report_events (report_id, user_id, event_type)
  values (v_report.id, v_user_id, 'created');

  return (
    select l from public.tracker_reports_live l where l.id = v_report.id
  );
end;
$$;
```

## Realtime subscription plan

Subscribe to:
- `tracker_reports`
- `report_comments`
- optionally `report_events`

### Practical recommendation
For MVP UI performance, subscribe mainly to `tracker_reports` and `report_comments`.

Use `report_events` mostly for the detail feed.

### What the UI should do on report changes
- `INSERT` into `tracker_reports` => add marker/feed item
- `UPDATE` in `tracker_reports` => refresh counts, TTL, or remove if no longer live
- `INSERT` into `report_comments` => append to open detail sheet if relevant

---

## Suggested JS client wrapper

This is the contract the frontend should code against.

```js
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm'

export function createTrackerClient({ supabaseUrl, supabaseAnonKey }) {
  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  })

  async function ensureWriteSession() {
    const { data } = await supabase.auth.getSession()
    if (data.session) return data.session
    throw new Error('AUTH_REQUIRED')
  }

  return {
    supabase,

    async getActiveReportsByBBox({ west, south, east, north }) {
      const { data, error } = await supabase.rpc('tracker_get_active_reports_in_bbox', {
        p_west: west,
        p_south: south,
        p_east: east,
        p_north: north,
      })
      if (error) throw error
      return data
    },

    async getNearbyFeed({ lat, lng, radiusM = 400, limit = 50 }) {
      const { data, error } = await supabase.rpc('tracker_get_nearby_feed', {
        p_lat: lat,
        p_lng: lng,
        p_radius_m: radiusM,
        p_limit: limit,
      })
      if (error) throw error
      return data
    },

    async getBlockFaceDetail(blockFaceId) {
      const { data, error } = await supabase.rpc('tracker_get_block_face_detail', {
        p_block_face_id: blockFaceId,
      })
      if (error) throw error
      return data
    },

    async createThreatReport({ blockFaceId, type, directionMode, note = null }) {
      await ensureWriteSession()
      const { data, error } = await supabase.rpc('tracker_create_report', {
        p_block_face_id: blockFaceId,
        p_type: type,
        p_direction_mode: directionMode,
        p_note: note,
      })
      if (error) throw error
      return data
    },

    async confirmReport(reportId) {
      await ensureWriteSession()
      const { data, error } = await supabase.rpc('tracker_confirm_report', {
        p_report_id: reportId,
      })
      if (error) throw error
      return data
    },

    async markBlockCleaned({ blockFaceId, aspWindowStartAt, aspWindowEndAt, note = null }) {
      await ensureWriteSession()
      const { data, error } = await supabase.rpc('tracker_mark_block_cleaned', {
        p_block_face_id: blockFaceId,
        p_asp_window_start_at: aspWindowStartAt,
        p_asp_window_end_at: aspWindowEndAt,
        p_note: note,
      })
      if (error) throw error
      return data
    },

    async addComment({ reportId, body }) {
      await ensureWriteSession()
      const { data, error } = await supabase.rpc('tracker_add_comment', {
        p_report_id: reportId,
        p_body: body,
      })
      if (error) throw error
      return data
    },

    async retractReport(reportId) {
      await ensureWriteSession()
      const { data, error } = await supabase.rpc('tracker_retract_report', {
        p_report_id: reportId,
      })
      if (error) throw error
      return data
    },

    subscribeToTracker({ onReportChange, onCommentInsert }) {
      const channel = supabase
        .channel('tracker-realtime')
        .on('postgres_changes', {
          event: '*',
          schema: 'public',
          table: 'tracker_reports',
        }, onReportChange)
        .on('postgres_changes', {
          event: 'INSERT',
          schema: 'public',
          table: 'report_comments',
        }, onCommentInsert)
        .subscribe()

      return () => supabase.removeChannel(channel)
    },
  }
}
```

---

## Payloads the frontend should send

### Create sweeper/ticket agent report
```ts
{
  blockFaceId: string,
  type: 'sweeper' | 'ticket_agent',
  directionMode: 'toward_from' | 'toward_to' | 'unknown',
  note?: string | null
}
```

### Confirm a report
```ts
{
  reportId: string
}
```

### Mark block cleaned
```ts
{
  blockFaceId: string,
  aspWindowStartAt: string, // ISO timestamp
  aspWindowEndAt: string,   // ISO timestamp
  note?: string | null
}
```

### Add comment
```ts
{
  reportId: string,
  body: string
}
```

---

## Block face import plan

### Source of truth
Use the current tile/segment dataset and derive one row per canonical block face.

### Import fields
For each canonical block face, populate:
- `id`
- `street`, `from_street`, `to_street`, `side`
- `label`
- `street_norm`, `from_street_norm`, `to_street_norm`
- `geom`
- `center`
- `bbox`
- `asp_rules`
- `has_asp`
- `source_segment_ids`
- `tile_keys`

### Why include `tile_keys`
Optional, but helpful if you later want to prefetch tracker state by the same tile scheme the app already uses.

That said, for MVP reads, the bbox query over `center` is sufficient.

---

## Minimal abuse controls for v1

Keep these in the RPCs, not in the browser.

### Recommended checks
- max 1 fresh report creation per user per 20 seconds
- max 6 write actions per user per 10 minutes
- max 3 comments per user per 5 minutes
- note length <= 140
- comment length <= 280
- reject writes for `profiles.is_limited = true`

### Fast implementation
The RPC can query recent rows in:
- `tracker_reports`
- `report_comments`
- `report_events`

No separate rate-limit table is required for MVP.

---

## Confidence / verification rule

Keep this simple.

```text
1 distinct reporter  => unverified
2+ distinct reporters => verified
```

### Suggested stored value
- keep `distinct_reporter_count` on the report row
- optionally maintain `confidence` as:
  - `1` for one reporter
  - `2` for two reporters
  - `3` for three or more

The frontend can derive the badge from `distinct_reporter_count >= 2`.

---

## Fastest implementation order

### 1. Import `block_faces`
Needed before anything else.

### 2. Create the tables and RLS
Start with the exact schema above.

### 3. Build only these RPCs first
- `tracker_get_active_reports_in_bbox`
- `tracker_get_block_face_detail`
- `tracker_create_report`
- `tracker_confirm_report`
- `tracker_mark_block_cleaned`
- `tracker_retract_report`

### 4. Add comments second
Comments are useful, but not required to make the tracker valuable on day one.

### 5. Add scheduled expiry
Needed for clean realtime behavior.

---

## Final recommendation

For this repo, the best MVP contract is:
- deterministic text `block_face_id`
- `block_faces` as the canonical map object
- one `tracker_reports` row per active tracker object
- one special `block_cleaned` row per block face per ASP window
- `pass_count` incremented in place on that row
- direct public reads
- authenticated writes through RPC functions only
- comments supported, but kept flat and lightweight

This is the shortest path from the current GitHub Pages map to a real multi-user threat tracker.
