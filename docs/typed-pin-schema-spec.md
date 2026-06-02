# Typed Pin Schema — Foundational Contract

**Status:** Spec ready for @backend-data (schema) and @ios-engineer (Swift models). Date: 2026-06-01.
**Owner:** Tech Lead (spec), @backend-data (schema application), @ios-engineer (iOS model layer).
**Supersedes:** nothing (greenfield — no pin or tracker tables exist in `supabase/01-mvp-schema.sql`).
**Blocks:** Every community feature downstream: Tier 1 open-data ingestion, Tier 2 reputation/voting, Tier 3 ephemeral decay, patrol mode (W8.5e–i).
**Proposed SQL file:** `supabase/02-pins-schema.sql` (new file, separate from 01-mvp-schema.sql).

---

## Open Decisions for Kevin (read before dispatch)

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-1 | Should `enforcement_active` pins be readable by anonymous (unauthenticated) clients? | (a) Yes, same as all other pins — anonymous read is the default; (b) No, require auth to view enforcement pins — reduces risk of abuse at App Store review. | **(a)** Anonymous read. The framing decision (§6 of community-1.0-direction.md) already de-risks enforcement by reframing copy; restricting read adds friction for the primary Drive Mode use case (Drive Mode users may not be authed). Consistency wins. |
| OQ-2 | `votes` table: per-user-per-pin uniqueness enforced at DB or app layer? | (a) Unique constraint at DB (`unique(pin_id, user_id)`) — safe but exposes that a user voted if someone inspects via client PostgREST; (b) Enforce at app layer only — simpler. | **(a)** Unique constraint at DB. Integrity > slight privacy tradeoff; the user_id is already known to Supabase Auth. |
| OQ-3 | Should broken-meter pins be auto-expired after a fixed window (say 7 days) or only on explicit confirm/vote? | (a) Auto-expire after 7 days via `expires_at` column (same decay mechanic as ephemeral pins); (b) Durable until voted resolved. | **(b)** Durable until resolved. A broken meter takes days for DOT to fix; auto-expiry at 7d would create false negatives. Use vote-to-resolve instead. |

---

## 1. Problem

The iOS app has a `UserDefaults`-backed `ParkedCar` struct (from W5, `ios/WePark/WePark/Models/ParkedCar.swift`) representing the user's personal parked-car pin. That model is purely local and single-purpose. As WePark expands to community-generated delta data (filming, enforcement, sweeper, sign corrections, etc.), we need:

1. A **backend-persisted, shared pin table** that multiple users can read and write.
2. A **typed model** that covers every delta type from the §4 taxonomy in `docs/community-1.0-direction.md` plus the existing W5 personal-pin concept, without requiring a painful migration mid-build.
3. A **clear 3-codebase contract** (iOS / PWA / Supabase) so all three can implement against the same shape independently.

Generalizing now is explicitly cheaper than migrating later — pin types share 90% of their schema (location, author, timestamps, zone membership), and the two-axis split (source × lifespan) is stable across all types.

---

## 2. Scope

### In scope

- One `pins` table covering all delta types plus the personal parked-car pin.
- One `pin_type` enum with all §4 types plus existing W5 types.
- Per-type optional metadata stored in a `meta JSONB` column (typed per pin_type — see §4.3).
- Two-axis classification (`source`, `lifespan`) as first-class columns (not metadata).
- `expires_at` / decay columns for ephemeral types.
- `confirm_count` / `dispute_count` vote-tracking columns (denormalized for read performance; source of truth is the `votes` table).
- `votes` table for per-user confirm/dispute actions.
- RLS policies: anonymous read, authenticated write, author-only update/delete.
- Realtime config for the `pins` table (same pattern as `zone_messages`).
- iOS Swift model layer: `PinType` enum + `CommunityPin` struct + `PinMeta` enum.
- PWA contract: the JSON shape `@pwa-maintainer` can `fetch()` from PostgREST.
- Explicit mapping from the W5 `ParkedCar` (local-only) to `CommunityPin` (when/if a parked-car pin is ever promoted to shared — deferred, but the seam is named here so W5 is not a dead end).

### Out of scope (deferred)

- Supabase Storage for photo evidence on sign-correction pins — post-TF2.
- Full-text search on `notes` — post-MVP.
- The `zone_messages` cross-pollination trigger (cross-posting a community pin as a system_tracker zone message) — already noted as "Phase 2d" in HANDOFF.md. The schema has a `related_report_id uuid` column in `zone_messages` today; this spec adds `pins.id` as the compatible UUID target for that column.
- Smart Move recommendation engine consuming pin data — post-MVP.
- The iOS UI surfaces for creating / reading community pins — specified in downstream feature specs (Tier 1 seeded-pin display, Tier 2 sign-correction reporting, Tier 3 patrol-mode ephemeral reporting). This spec defines the data contract only.
- Applying the migration to production — `@backend-data` applies it; `@qa-verifier` gates it per TEAM.md.

---

## 3. The Two-Axis Model (source × lifespan)

Every pin type falls on two axes that determine trust model and decay behavior. These are first-class columns, not metadata.

**source** axis:
- `open_data` — seeded from a NYC open dataset (film permits, ASP calendar, DOT closures). Authoritative by default.
- `hybrid` — seeded from partial open data + crowd fills gaps (construction, some special events).
- `crowd` — user-generated only (enforcement, sweeper, sign correction, block note, broken meter, personal parked-car).

**lifespan** axis:
- `ephemeral` — minutes to hours. Decays automatically via `expires_at`. Needs "still there?" confirm to extend. Examples: enforcement_active, sweeper_passed.
- `session` — hours to one day. Self-expires. Examples: filming (same-day), ASP_suspended_today, special_event.
- `durable` — days to months. Does not auto-expire. Resolved by vote or admin. Examples: construction, broken_meter.
- `correction` — permanent until the underlying data or DOT fixes it. Examples: sign_correction, block_note.

The combination determines build priority (Tier 1 = open_data+hybrid / session+durable; Tier 2 = crowd / correction+durable; Tier 3 = crowd / ephemeral).

---

## 4. Data Model

### 4.1 `pin_type` enum

```sql
create type public.pin_type as enum (
  -- Tier 1: open-data-seedable
  'filming',              -- block held for a film/TV production
  'asp_suspended_today',  -- ASP not in effect today (redundant with calendar but crowd-confirmable)
  'special_event',        -- parade, marathon, snow emergency, fair
  'construction',         -- street repaving, Con Ed, scaffold closure

  -- Tier 2: crowd, durable
  'sign_correction',      -- "this sign is wrong / contradicts the data"
  'block_note',           -- overnight safety, flooding, double-park norms

  -- Tier 3: crowd, ephemeral
  'enforcement_active',   -- agent on the block now (neutral; see §6 of direction doc)
  'sweeper_passed',       -- cleaning truck already came (or is coming imminently)
  'broken_meter',         -- muni-meter down

  -- Existing W5 personal pin (local-only today; schema ready for future shared state)
  'parked_car'            -- user's own parked car pin (personal, not community-visible by default)
);
```

**Note on `enforcement_active`:** The §6 framing decision in `docs/community-1.0-direction.md` specifies: one neutral type, optional sub-tag, compliance copy ("Enforcement active on this block"), cleaning-truck use leads in screenshots. The schema encodes this as: `pin_type = 'enforcement_active'` + `meta.sub_tag` (optional: `'parking_agent' | 'cleaning_truck' | 'tow_truck'`). The UI copy and icon selection are the enforcement-vs-evasion lever; the schema is neutral.

**Note on `parked_car`:** This is the existing W5 personal pin. Today it lives only in `UserDefaults` on-device. The schema includes it so the data model is complete and a future "share my spot" or "community my-car" feature doesn't require a migration. RLS for `parked_car` pins is author-only-read (not anonymous-read) — see §5.3.

### 4.2 `pins` table

```sql
create table if not exists public.pins (
  -- Identity
  id          uuid primary key default gen_random_uuid(),

  -- Type + two-axis classification
  pin_type    public.pin_type not null,
  source      text not null check (source in ('open_data', 'hybrid', 'crowd')),
  lifespan    text not null check (lifespan in ('ephemeral', 'session', 'durable', 'correction')),

  -- Geography
  lat         double precision not null,
  lng         double precision not null,
  segment_id  text,              -- refs tile segment (street|from|to key from tiles/index.json); null if no match
  zone_id     text references public.zones(id) on delete set null,

  -- Authorship
  author_id   uuid references auth.users(id) on delete set null,
  -- null author_id = seeded by open-data pipeline (@backend-data inserts via service-role key)

  -- Temporal
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  expires_at  timestamptz,         -- null = does not auto-expire; set for ephemeral + session types
  resolved_at timestamptz,         -- set when a durable/correction pin is voted resolved or admin-closed

  -- Crowd-signal denormalized counters (updated by trigger from votes table)
  confirm_count  integer not null default 0,
  dispute_count  integer not null default 0,

  -- Per-type structured metadata (shape defined per type in §4.3)
  meta        jsonb,

  -- Free-text notes (optional, user-supplied)
  notes       text check (length(notes) <= 500)
);
```

### 4.3 `meta` JSONB shape per `pin_type`

The `meta` column is untyped at the DB level (JSONB) for schema flexibility. The iOS and PWA client layers enforce shape via typed structs/objects. Per-type contracts:

| pin_type | meta shape | Required fields |
|---|---|---|
| `filming` | `{ permit_id: string, production_name: string?, film_office_url: string? }` | `permit_id` |
| `asp_suspended_today` | `{ suspension_date: string (YYYY-MM-DD), reason: string? }` | `suspension_date` |
| `special_event` | `{ event_name: string, event_type: 'parade'\|'marathon'\|'snow_emergency'\|'fair'\|'other' }` | `event_name`, `event_type` |
| `construction` | `{ permit_id: string?, agency: string?, start_date: string?, end_date: string? }` | none required (partial open data) |
| `sign_correction` | `{ segment_id: string, reported_issue: string, existing_rule_text: string? }` | `segment_id`, `reported_issue` |
| `block_note` | `{ category: 'safety'\|'flooding'\|'parking_norm'\|'other', headline: string }` | `category`, `headline` |
| `enforcement_active` | `{ sub_tag: 'parking_agent'\|'cleaning_truck'\|'tow_truck'\|null }` | none (sub_tag optional) |
| `sweeper_passed` | `{ direction: 'passed'\|'coming_soon'\|null }` | none |
| `broken_meter` | `{ meter_id: string? }` | none |
| `parked_car` | `{ detected_segment_id: string?, detected_side: string?, street: string?, from_street: string?, to_street: string? }` | none (mirrors W5 `ParkedCar` fields) |

### 4.4 `votes` table

```sql
create table if not exists public.votes (
  id        bigserial primary key,
  pin_id    uuid not null references public.pins(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  vote      text not null check (vote in ('confirm', 'dispute')),
  created_at timestamptz not null default now(),

  unique (pin_id, user_id)   -- one vote per user per pin; update via upsert to change vote
);
```

### 4.5 Denormalization trigger

A `AFTER INSERT OR UPDATE OR DELETE ON votes` trigger recomputes `pins.confirm_count` and `pins.dispute_count`:

```sql
-- Sketch only — @backend-data implements
create or replace function public.refresh_pin_vote_counts()
returns trigger language plpgsql security definer as $$
begin
  update public.pins set
    confirm_count = (select count(*) from public.votes where pin_id = coalesce(new.pin_id, old.pin_id) and vote = 'confirm'),
    dispute_count = (select count(*) from public.votes where pin_id = coalesce(new.pin_id, old.pin_id) and vote = 'dispute'),
    updated_at = now()
  where id = coalesce(new.pin_id, old.pin_id);
  return null;
end;
$$;

create trigger votes_refresh_pin_counts
  after insert or update or delete on public.votes
  for each row execute function public.refresh_pin_vote_counts();
```

---

## 5. Indexes

```sql
-- Spatial: all map queries filter by bounding box
create index if not exists pins_lat_lng_idx on public.pins(lat, lng);

-- Temporal: expire-sweep queries + decay dashboard
create index if not exists pins_expires_at_idx on public.pins(expires_at)
  where expires_at is not null;

-- Zone membership: community feed queries
create index if not exists pins_zone_id_created_idx on public.pins(zone_id, created_at desc);

-- Segment: parking-data join (for Drive Mode overlay enrichment)
create index if not exists pins_segment_id_idx on public.pins(segment_id)
  where segment_id is not null;

-- Type: server-side filtering by tier
create index if not exists pins_type_idx on public.pins(pin_type);

-- Active-only partial index (most map reads filter to non-resolved rows).
-- NOTE: the predicate is intentionally scoped to resolved_at only. Using
-- `expires_at > now()` here would freeze now() at DDL-run time, making the
-- predicate useless for future rows. Clients filter expires_at > <current
-- timestamp> at query time via pins_expires_at_idx instead.
create index if not exists pins_active_spatial_idx on public.pins(lat, lng, pin_type)
  where resolved_at is null;
```

---

## 6. RLS Policies

```sql
alter table public.pins enable row level security;
alter table public.votes enable row level security;

-- ---- pins ----

-- Anonymous (and authenticated) can read all non-parked-car pins
drop policy if exists pins_select_public on public.pins;
create policy pins_select_public on public.pins
  for select using (
    pin_type != 'parked_car'          -- parked_car is author-only
    or auth.uid() = author_id         -- or the author sees their own
  );

-- Authenticated users can insert crowd-source pins (not open_data — those come via service-role)
drop policy if exists pins_insert_crowd on public.pins;
create policy pins_insert_crowd on public.pins
  for insert with check (
    auth.uid() is not null
    and author_id = auth.uid()
    and source = 'crowd'
  );

-- Authors can update their own pins (e.g., add notes, change sub_tag)
drop policy if exists pins_update_own on public.pins;
create policy pins_update_own on public.pins
  for update using (auth.uid() = author_id);

-- Authors can delete their own pins
drop policy if exists pins_delete_own on public.pins;
create policy pins_delete_own on public.pins
  for delete using (auth.uid() = author_id);

-- Open-data ingestion uses service-role key (bypasses RLS). No policy needed for that path.

-- ---- votes ----

drop policy if exists votes_select_all on public.votes;
create policy votes_select_all on public.votes
  for select using (true);

drop policy if exists votes_insert_own on public.votes;
create policy votes_insert_own on public.votes
  for insert with check (auth.uid() = user_id);

drop policy if exists votes_update_own on public.votes;
create policy votes_update_own on public.votes
  for update using (auth.uid() = user_id);

drop policy if exists votes_delete_own on public.votes;
create policy votes_delete_own on public.votes
  for delete using (auth.uid() = user_id);
```

---

## 7. Realtime Config

```sql
-- Add pins to the Realtime publication so iOS and PWA receive live updates
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pins'
  ) then
    alter publication supabase_realtime add table public.pins;
  end if;
end $$;
```

Clients filter by bounding box on the client side (PostgREST `eq`/`gte`/`lte` on lat/lng) or subscribe to Realtime with a `filter` on `zone_id`. Vote-count changes propagate via Realtime on the `pins` row (the trigger updates `updated_at`, which surfaces as a Realtime UPDATE event).

---

## 8. Decay / Expiry Convention

| lifespan | default `expires_at` at insert | Extension mechanism |
|---|---|---|
| `ephemeral` | `now() + interval '30 minutes'` (enforcement_active, sweeper_passed) | Each `confirm` vote extends by 15 minutes (capped at 2h total). Implemented via RPC `extend_pin_expiry(pin_id uuid)` that adds 15 min if `expires_at < now() + interval '2 hours'`. |
| `session` | `now() + interval '1 day'` (filming, asp_suspended_today, special_event) | No extension. Auto-expires. Crowd confirms are visible but don't extend. |
| `durable` | `null` (construction, broken_meter, sign_correction, block_note) | Never auto-expires. `resolved_at` is set when dispute_count exceeds confirm_count by a threshold (TBD in Tier 2 spec) or by author/admin action. |
| `correction` | `null` | Same as durable. |

The `extend_pin_expiry` RPC sketch:

```sql
-- @backend-data implements; sketch only
create or replace function public.extend_pin_expiry(p_pin_id uuid)
returns void language plpgsql security definer as $$
begin
  update public.pins set
    expires_at = least(expires_at + interval '15 minutes', now() + interval '2 hours'),
    updated_at = now()
  where id = p_pin_id
    and lifespan = 'ephemeral'
    and expires_at is not null;
end;
$$;
```

A server-side cron (Supabase pg_cron or edge function) soft-deletes or flags expired pins. Alternatively, clients filter `expires_at > now()` on read. Recommend the client-side filter for MVP (no cron needed; expired pins become invisible without deletion, keeping audit history).

---

## 9. Convenience View

```sql
create or replace view public.pins_with_author as
  select
    p.*,
    pr.username as author_username,
    pr.reputation as author_reputation
  from public.pins p
  left join public.profiles pr on pr.id = p.author_id;

grant select on public.pins_with_author to anon, authenticated;
```

Clients use this view to avoid a separate fetch for author display names — mirrors the `zone_messages_with_author` pattern from `01-mvp-schema.sql:122–136`.

---

## 10. iOS Swift Contract

The iOS engineer implements these types in `Models/CommunityPin.swift` (new file). The W5 `ParkedCar` model is NOT replaced — it continues to own local-only pin state. `CommunityPin` is the network/community layer.

### 10.1 `PinType` enum

```swift
// Models/CommunityPin.swift (new)
enum PinType: String, Codable, CaseIterable {
    // Tier 1
    case filming              = "filming"
    case aspSuspendedToday    = "asp_suspended_today"
    case specialEvent         = "special_event"
    case construction         = "construction"
    // Tier 2
    case signCorrection       = "sign_correction"
    case blockNote            = "block_note"
    // Tier 3
    case enforcementActive    = "enforcement_active"
    case sweeperPassed        = "sweeper_passed"
    case brokenMeter          = "broken_meter"
    // Personal (W5 local pin; not community-visible)
    case parkedCar            = "parked_car"
}
```

### 10.2 `PinSource` and `PinLifespan` enums

```swift
enum PinSource: String, Codable {
    case openData = "open_data"
    case hybrid   = "hybrid"
    case crowd    = "crowd"
}

enum PinLifespan: String, Codable {
    case ephemeral  = "ephemeral"
    case session    = "session"
    case durable    = "durable"
    case correction = "correction"
}
```

### 10.3 `CommunityPin` struct

```swift
struct CommunityPin: Codable, Identifiable {
    let id: UUID
    let pinType: PinType
    let source: PinSource
    let lifespan: PinLifespan
    let lat: Double
    let lng: Double
    let segmentId: String?
    let zoneId: String?
    let authorId: UUID?
    let authorUsername: String?  // from pins_with_author view
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
    let resolvedAt: Date?
    let confirmCount: Int
    let disputeCount: Int
    let meta: PinMeta?
    let notes: String?
}
```

### 10.4 `PinMeta` enum (typed metadata)

```swift
enum PinMeta: Codable {
    case filming(FilmingMeta)
    case aspSuspendedToday(ASPSuspendedMeta)
    case specialEvent(SpecialEventMeta)
    case construction(ConstructionMeta)
    case signCorrection(SignCorrectionMeta)
    case blockNote(BlockNoteMeta)
    case enforcementActive(EnforcementActiveMeta)
    case sweeperPassed(SweeperPassedMeta)
    case brokenMeter(BrokenMeterMeta)
    case parkedCar(ParkedCarMeta)
    // Decode via custom init(from:) using pin_type field to pick the case
}

struct EnforcementActiveMeta: Codable {
    enum SubTag: String, Codable {
        case parkingAgent    = "parking_agent"
        case cleaningTruck   = "cleaning_truck"
        case towTruck        = "tow_truck"
    }
    let subTag: SubTag?  // nil = not specified; UI shows generic "Enforcement active"
}

// Other meta structs follow the §4.3 shape definitions verbatim.
```

**Decoding strategy:** `CommunityPin` is decoded from the `pins_with_author` view. Because `meta` is a JSONB blob whose shape varies by `pin_type`, the custom decoder reads `pin_type` first, then decodes `meta` into the matching `PinMeta` case. The `CodingKeys` map snake_case → camelCase.

### 10.5 W5 `ParkedCar` → `CommunityPin` migration path (when needed)

The W5 `ParkedCar` model (`ios/WePark/WePark/Models/ParkedCar.swift`) is NOT changed by this spec. When a future feature promotes a personal parked-car pin to a community pin, `ParkPinService` will call a new `promote(car: ParkedCar) -> CommunityPin` helper that maps W5 fields to the `parked_car` pin_type row. The seam exists; nothing else needs to change at that time.

---

## 11. PWA Contract

The `@pwa-maintainer` queries the `pins_with_author` view via PostgREST. The PWA is in maintenance mode, so this is informational — the PWA does not need to consume community pins for MVP. If the PWA ever displays Tier 1 seeded pins on the live map, the fetch shape is:

```
GET /rest/v1/pins_with_author
  ?pin_type=in.(filming,asp_suspended_today,special_event,construction)
  &lat=gte.{sw_lat}&lat=lte.{ne_lat}
  &lng=gte.{sw_lng}&lng=lte.{ne_lng}
  &resolved_at=is.null
  &select=id,pin_type,lat,lng,segment_id,expires_at,confirm_count,dispute_count,meta,notes,author_username
```

The `expires_at=gt.now()` filter is applied client-side because PostgREST does not support `now()` in RPC-free filter syntax cleanly; `or=(expires_at.is.null,expires_at.gt.<ISO-timestamp>)` works with a fresh timestamp substituted at call time.

---

## 12. Work Streams

These streams are PARALLEL — `@backend-data` and `@ios-engineer` can start simultaneously once this spec is approved.

| Stream | Owner | Dependency | Can parallel? | Notes |
|---|---|---|---|---|
| **A — Apply schema** | @backend-data | This spec approved | Yes (with B) | Write `supabase/02-pins-schema.sql`, apply to Supabase SQL editor, verify via `@qa-verifier` before any iOS/PWA code touches it |
| **B — iOS model layer** | @ios-engineer | This spec approved | Yes (with A) | `Models/CommunityPin.swift` + all meta structs + unit tests for decode round-trip. Does NOT require the DB to be live — tests use fixture JSON matching the contract. |
| **C — Community pin service (iOS)** | @ios-engineer | Stream A live | Serializes after A | `Services/CommunityPinService.swift` — Supabase client fetch, Realtime subscription, insert/vote RPCs. Gate: DB must be applied before integration tests. |

---

## 13. Acceptance Criteria

**Schema (verified by @qa-verifier before any production apply):**
- [ ] **AC-S1.** `supabase/02-pins-schema.sql` is idempotent: running it twice on a clean project produces no errors.
- [ ] **AC-S2.** `pin_type` enum contains exactly the 10 types listed in §4.1.
- [ ] **AC-S3.** `pins` table has all columns in §4.2 with correct types and constraints.
- [ ] **AC-S4.** `votes` table has the `unique(pin_id, user_id)` constraint.
- [ ] **AC-S5.** Insert a `filming` pin with `source = 'crowd'` as an anonymous user: RLS rejects it (anon cannot insert `crowd` pins without auth). Insert as authenticated user with matching `author_id`: succeeds.
- [ ] **AC-S6.** Insert a `filming` pin with `source = 'open_data'` via service-role key: succeeds (bypasses RLS).
- [ ] **AC-S7.** Insert a `parked_car` pin as user A. Query as user B (different authenticated user): zero rows returned (parked_car is author-only).
- [ ] **AC-S8.** Insert a `filming` pin. Query as anon: row is returned with all fields except those excluded by view `grant`.
- [ ] **AC-S9.** Insert a vote. `pins.confirm_count` or `pins.dispute_count` increments within the same transaction (trigger fires synchronously).
- [ ] **AC-S10.** Delete a vote. The corresponding count decrements.
- [ ] **AC-S11.** Realtime: subscribing to `pins` table changes receives an INSERT event within 2s of a new row being inserted.
- [ ] **AC-S12.** `pins_with_author` view: querying it returns `author_username` and `author_reputation` inline.

**iOS model layer (verified by unit tests):**
- [ ] **AC-I1.** `CommunityPin` decodes a fixture JSON row for each of the 10 pin types without error.
- [ ] **AC-I2.** `PinMeta` for `enforcement_active` with `sub_tag: null` decodes to `.enforcementActive(EnforcementActiveMeta(subTag: nil))`.
- [ ] **AC-I3.** `PinMeta` for `enforcement_active` with `sub_tag: "cleaning_truck"` decodes to `.enforcementActive(EnforcementActiveMeta(subTag: .cleaningTruck))`.
- [ ] **AC-I4.** `CommunityPin` with `expires_at: null` decodes `expiresAt` as `nil` (not crash).
- [ ] **AC-I5.** `CommunityPin` with `resolved_at` set decodes `resolvedAt` as a non-nil `Date`.
- [ ] **AC-I6.** No `Calendar.current` usage in `Models/CommunityPin.swift` or any meta struct. (All time math defers to `Calendar.easternTime` convention established in W3.)
- [ ] **AC-I7.** `PinType.rawValue` for each case matches the SQL enum string exactly (round-trip encode → decode produces identical value).

---

## 14. Out-of-Scope Follow-Ups

**Photo evidence column.** Sign-correction reports would benefit from a photo. Supabase Storage + a `photo_url text` column on `pins`. Deferred: Storage setup adds ops overhead and App Store privacy disclosure for camera. Post-TF2.

**Geospatial PostGIS index.** The `lat`/`lng` double-precision columns + a composite B-tree index are sufficient for Manhattan-scale queries (bounding box, ~40K segments, O(log n) scan). A PostGIS geography type with `ST_DWithin` would enable more efficient radius queries for the "pins near me" feature. Deferred until query latency is measured on real data.

**Row-level expiry via pg_cron.** The client-side `expires_at > now()` filter is sufficient for MVP. A server-side sweep job (via Supabase's pg_cron extension or an Edge Function on a schedule) would clean up expired rows and reduce read overhead at scale. Deferred post-MVP.

**`zone_messages` cross-pollination.** When a community pin is created, a `system_tracker` message is auto-posted to the matching zone's chat. The `zone_messages.related_report_id` column already exists for this link. The RPC is documented in `01-mvp-schema.sql:99–101` as a TODO. This spec makes `pins.id` the UUID target for that column. Implementation is Phase 2d per HANDOFF.md backlog.
