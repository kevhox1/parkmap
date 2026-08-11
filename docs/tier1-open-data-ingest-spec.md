# Tier 1 Open-Data Ingest Spec

**Status:** Spec ready for implementation. Date: 2026-06-01.
**Owner:** @backend-data (spec + ingest job). @ios-engineer reads §6 for the iOS consumption contract.
**Blocks:** Tier 1 pin display on iOS map. AC-T1.1, AC-T1.2 from community-1.0-buildplan.md.
**Depends on:** `supabase/02-pins-schema.sql` applied and QA-cleared (AC-S1–S12).
**Explicitly out of scope:** DOT closures, HIQA construction data (TF2 — see §7).

---

## 1. What This Spec Covers

Two NYC open-data sources seeded as community pins:

1. **NYC Film Permits** (NYC OpenData, dataset `tg4x-b46p`) → `pin_type = 'filming'`, `source = 'open_data'`, `lifespan = 'session'`.
2. **ASP Suspension Calendar** → `pin_type = 'asp_suspended_today'`, `source = 'open_data'`, `lifespan = 'session'`.

Both are anonymous, contain no PII, and are inserted via service-role key (bypasses RLS). No user attribution — `author_id` is null on all seeded rows.

---

## 2. Source-of-Truth Reconciliation: ASP Calendar

The PWA (`index.html`) currently hardcodes a 2026 ASP suspension calendar as `ASP_SUSPENSIONS_2026` (lines 2030–2073). This is the **existing in-app source of truth**. Community 1.0 adds a parallel path: the ingest job writes an `asp_suspended_today` pin to the `pins` table on each suspension day.

**Reconciliation rules:**

- The hardcoded `ASP_SUSPENSIONS_2026` constant in `index.html` is NOT removed. It continues to power the PWA's banner logic and the block-detail parking calculations — those code paths read `aspSuspensions` directly and do not query Supabase.
- The ingest job writes the same dates as pins. This creates a second, Supabase-backed representation for the iOS map layer to consume.
- The two representations must agree. The ingest job's date list is authoritative for the `pins` table; `index.html`'s hardcoded list is authoritative for PWA calculations. They should be identical (both sourced from the NYC DOT PDF). If they diverge due to a real-time suspension added mid-year (e.g., snow emergency), the Supabase pin is the more up-to-date signal for iOS; the PWA does not auto-update without a code deploy.
- **2027 migration path:** When NYC publishes the 2027 calendar, update both `ASP_SUSPENSIONS_2026` in `index.html` (rename to `ASP_SUSPENSIONS_2027`) AND the ingest job's seed list. The ingest job spec (§4) notes the cadence for this.

---

## 3. Film Permit Ingest

### 3.1 Source

NYC OpenData Socrata API, dataset ID `tg4x-b46p`:

```
https://data.cityofnewyork.us/resource/tg4x-b46p.json
```

No API key required for public access up to 1,000 rows per request. Use the `$limit` and `$offset` params for pagination. Use the `$$app_token` query param (NYC OpenData app token) in the `X-App-Token` header for higher rate limits — store the token in a Supabase Edge Function secret (not in committed code).

CORS: Browser fetches to Socrata are blocked by CORS for some endpoints. The ingest job runs server-side (Supabase Edge Function or pg_cron-triggered SQL + `http` extension) — no CORS issue.

### 3.2 Relevant Source Fields

| Source field | Type | Maps to |
|---|---|---|
| `eventid` | string | `meta.permit_id` (dedup key) |
| `startdatetime` | ISO 8601 | `created_at` reference; also lower bound of the permit window |
| `enddatetime` | ISO 8601 | `expires_at` |
| `parkingheld` | string | Street address(es) where parking is blocked |
| `borough` | string | Zone lookup (see §3.4) |
| `latitude` | string (decimal) | `lat` |
| `longitude` | string (decimal) | `lng` |
| `category` | string | `meta.production_name` label (e.g., "Television", "Film") |
| `subcategoryname` | string | Additional context for `meta` |
| `applicant` | string | Production company — store in `meta.production_name` |

Not all permits have `latitude`/`longitude`. When lat/lng are missing, attempt geocoding via the `parkingheld` field (see §3.5). If geocoding fails, skip the permit row — a pin with no coordinates cannot be displayed.

### 3.3 Column Mapping

| pins column | Value | Notes |
|---|---|---|
| `id` | `gen_random_uuid()` | DB default |
| `pin_type` | `'filming'` | constant |
| `source` | `'open_data'` | constant |
| `lifespan` | `'session'` | constant — session pins expire after 1 day or at `expires_at` |
| `lat` | `latitude::double precision` | from source or geocoded |
| `lng` | `longitude::double precision` | from source or geocoded |
| `segment_id` | null | not resolvable at ingest time without tile lookup; leave null |
| `zone_id` | lookup by borough (§3.4) | nullable if no zone matches |
| `author_id` | null | open-data, no user author |
| `expires_at` | `enddatetime` parsed to timestamptz | if null or past, skip row |
| `resolved_at` | null | ingest sets null; auto-resolved by expiry |
| `confirm_count` | 0 | DB default |
| `dispute_count` | 0 | DB default |
| `meta` | `{ "permit_id": eventid, "production_name": applicant, "film_office_url": null }` | see §4.3 of schema spec |
| `notes` | null | no notes on seeded pins |

### 3.4 Zone Lookup

The current zone seed has one zone: `soho-les` (lat 40.713–40.732, lng -74.006–-73.973). Zone assignment:

```
if lat between zones.lat_min and zones.lat_max
   and lng between zones.lng_min and zones.lng_max
then zone_id = zones.id
else zone_id = null
```

As more zones are seeded, the same bounding-box lookup applies. The ingest job queries `public.zones` at run time — no hardcoded zone IDs in the ingest code.

### 3.5 Missing Coordinates

If `latitude` and `longitude` are absent or non-numeric, attempt to derive them from `parkingheld` using the NYC GeoSearch API:

```
https://geosearch.planninglabs.nyc/v2/search?text={parkingheld}&borough={borough}
```

This is a free, CORS-open NYC Planning API. Take the first result's coordinates if confidence is high (score > 0.7). If confidence is low or the API returns no results, skip the permit row and log the `eventid` for manual review.

### 3.6 Deduplication

Dedup key: `meta->>'permit_id'` (the Socrata `eventid`).

Insert strategy: `INSERT ... ON CONFLICT DO NOTHING` is insufficient because `meta->>'permit_id'` is not a unique DB constraint (it's inside JSONB). Instead use an upsert keyed on a computed expression:

```sql
insert into public.pins (pin_type, source, lifespan, lat, lng, zone_id, author_id,
                          expires_at, meta, notes)
values (...)
on conflict ((meta->>'permit_id')) where pin_type = 'filming'
do update set
  lat         = excluded.lat,
  lng         = excluded.lng,
  zone_id     = excluded.zone_id,
  expires_at  = excluded.expires_at,
  meta        = excluded.meta,
  updated_at  = now();
```

The `ON CONFLICT` target must exactly match the partial unique index defined in `supabase/02b-pins-ingest-indexes.sql` and §5 below: a single-expression index on `(meta->>'permit_id')` with a `WHERE pin_type = 'filming'` predicate. Using `ON CONFLICT (pin_type, (meta->>'permit_id'))` would require a two-column unique index (which does not exist) and will throw at runtime.

The partial unique index:

```sql
create unique index if not exists pins_filming_permit_id_uidx
  on public.pins ((meta->>'permit_id'))
  where pin_type = 'filming';
```

This is a **partial unique index** scoped to `filming` pins only, so it does not constrain other pin types that use `meta.permit_id`.

### 3.7 Filtering at Ingest

Exclude a permit row if:
- `enddatetime` is in the past at the time of the ingest run (permit already expired).
- `latitude`/`longitude` are absent and geocoding fails.
- `borough` is not in NYC's five boroughs (sanity check on the source data).
- `eventid` is null or empty string (cannot dedup).

Only permits where parking is actually held (`parkingheld` is non-empty) should be considered. Permits without a parking hold do not translate to a map pin.

### 3.8 Refresh Cadence

NYC OpenData film permits are updated daily by the NYC Mayor's Office of Media and Entertainment (MOME). The ingest job should run **once per day at 04:00 ET** to catch permits added overnight and permits whose dates have changed.

Cron shape (Supabase Edge Function scheduled via Supabase Dashboard → Edge Functions → Schedule):

```
# Once daily at 04:00 ET (09:00 UTC in Eastern Standard, 08:00 UTC in Eastern Daylight)
# Use 09:00 UTC as the conservative choice (always 04:00–05:00 ET)
0 9 * * *
```

Alternatively via pg_cron if the `pg_cron` extension is enabled on the project:

```sql
select cron.schedule(
  'ingest-film-permits',
  '0 9 * * *',
  $$ select net.http_post(
       url := 'https://<project-ref>.functions.supabase.co/ingest-film-permits',
       headers := '{"Authorization": "Bearer <service-role-key>"}'::jsonb
     ) $$
);
```

The service-role key in the pg_cron call is stored as a Supabase Vault secret, not committed to the repo.

### 3.9 Staleness Detection (FT-16)

**Filed 2026-08-11.** Full investigation: `docs/qa/ft16-film-permit-feed-investigation.md`.

The current/future filter in §3.7 can legitimately return zero rows on any given day — there may
simply be no permits scheduled. That is normal and must not be treated as an error. What must be
detected is the upstream feed itself going dark: NYC MOME's `tg4x-b46p` dataset stopped receiving
new permit submissions entirely around 2026-05-07, while its published metadata continued to claim
`Update Frequency: Daily` and its Socrata `rowsUpdatedAt` timestamp kept advancing (the asset was
being re-touched, but no new rows arrived). The ingest job ran daily for ~3 months against this dead
feed, matched zero rows every time (correctly, given its filter), and raised nothing — a
legitimately-empty pull and a broken pull were indistinguishable.

**Fix, proportionate to this layer's blast radius** (an empty map layer is far less harmful than
TF2-19's incorrect tile data, so this is a loud/observable signal, not a hard abort):

1. On every invocation, `ingest-film-permits` separately probes
   `$select=max(enteredon)` against the **whole** upstream dataset — no current/future filter — to
   answer "has MOME submitted anything recently at all?" independent of whether today's filtered
   query matched anything.
2. If that upstream timestamp is more than `STALENESS_THRESHOLD_DAYS` (10, see code comment for
   rationale) old, the function logs a `console.error` (distinct severity in the Supabase Functions
   log dashboard from the routine `console.log` summary) and marks the run `stale = true`.
3. Every invocation — success, no-op, or stale — writes one row to `public.ingest_runs`
   (`supabase/02f-ingest-runs.sql`), a durable, source-tagged run log shared by all open-data ingest
   jobs. This survives past Supabase's function-log retention window, which is what let this
   3-month outage go unnoticed in the first place.
4. The HTTP response also carries `upstreamStale`, `staleDays`, and `upstreamLatestRowAt` so a
   manual `curl` invocation (Step 4 in §9) surfaces staleness immediately without needing to query
   the database.

**Decision on the cron job itself:** kept running daily, unchanged. The filter logic in §3.7 is not
buggy — it is correctly matching zero rows against a genuinely stale upstream feed. No replacement
dataset was found for individual short-duration film permits (the FT-16 investigation checked the
NYC Open Data catalog directly; the only film-adjacent alternative, `tvpp-9vvx` "NYC Permitted Event
Information," is a different Street Activity Permit Office feed — production logistics events like
office moves and pop-up events, not MOME film-shoot permits, and would misrepresent the `filming`
pin type if substituted). Disabling the cron was rejected: it would recreate the exact same
invisible-failure risk this ticket exists to close, just with the added risk of nobody remembering
to re-enable it if/when NYC resumes publishing. The daily invocation cost is one small Socrata query
either way, self-heals the moment the upstream feed resumes, and is now paired with the staleness
alarm above so a *future* outage is loud from day one instead of silent for three months.

---

## 4. ASP Suspension Calendar Ingest

### 4.1 Source

The 2026 ASP calendar is already encoded in `index.html` as `ASP_SUSPENSIONS_2026` (lines 2030–2073 of `index.html`). The dates come from the NYC DOT PDF published annually: `https://www.nyc.gov/html/dot/downloads/pdf/asp-calendar-2026.pdf`.

The ingest job treats this same date list as its data source for the `pins` table. No live API call is needed — the calendar is pre-parsed from the DOT PDF once per year.

Future option (iOS native only, not PWA): Wire the NYC 311 Public Developer API for real-time snow emergency suspensions. This is deferred — the 311 API requires an API key, has CORS restrictions for browsers, and adds complexity. The hardcoded calendar covers all scheduled suspensions. Snow emergencies are rare and unscheduled; they can be added manually via a seed script if needed.

### 4.2 Column Mapping

One pin per suspension date. The pin is created at midnight ET on the suspension date and expires at midnight ET the following day (the full suspension day).

| pins column | Value | Notes |
|---|---|---|
| `id` | `gen_random_uuid()` | DB default |
| `pin_type` | `'asp_suspended_today'` | constant |
| `source` | `'open_data'` | constant |
| `lifespan` | `'session'` | constant — 1-day window |
| `lat` | null concept — ASP suspensions are citywide | see §4.3 |
| `lng` | null concept | see §4.3 |
| `segment_id` | null | citywide; not segment-bound |
| `zone_id` | null | citywide; not zone-bound |
| `author_id` | null | open-data, no user author |
| `expires_at` | suspension date at 23:59:59 ET | the pin expires at end of the suspension day |
| `resolved_at` | null | expires via expires_at |
| `meta` | `{ "suspension_date": "YYYY-MM-DD", "reason": "<holiday name>" }` | per schema spec §4.3 |
| `notes` | null | |

### 4.3 Coordinates for ASP Pins

ASP suspensions are citywide — there is no meaningful single lat/lng. Two options:

**Option A (recommended for MVP):** Use a fixed "city centroid" coordinate for the pin row (lat 40.7128, lng -74.0060 — Manhattan city hall). This satisfies the `not null` constraint and allows the pin to be queried. The iOS display layer identifies `asp_suspended_today` pins by type and renders them as a citywide banner, not a map point.

**Option B (deferred):** One pin per zone, placed at the zone centroid. Enables zone-scoped Realtime subscriptions. More pins to manage. Implement in TF2 if the citywide banner approach is insufficient.

Use Option A for MVP. The ingest job hardcodes the city centroid.

### 4.4 Deduplication

Dedup key: `meta->>'suspension_date'` (the YYYY-MM-DD string).

Unique index:

```sql
create unique index if not exists pins_asp_suspension_date_uidx
  on public.pins ((meta->>'suspension_date'))
  where pin_type = 'asp_suspended_today';
```

Upsert:

```sql
insert into public.pins (pin_type, source, lifespan, lat, lng, zone_id, author_id,
                          expires_at, meta, notes)
values (...)
on conflict ((meta->>'suspension_date'))
  where pin_type = 'asp_suspended_today'
do update set
  expires_at  = excluded.expires_at,
  meta        = excluded.meta,
  updated_at  = now();
```

### 4.5 Refresh Cadence

The 2026 calendar is fixed — no daily API call needed. The ingest job runs **once at schema-apply time** (seeding all future 2026 suspension dates that have not yet passed) and **once yearly** when NYC publishes the next year's calendar.

Operational procedure for yearly update:
1. NYC publishes the new calendar PDF (typically December of the prior year).
2. @backend-data parses the new dates, updates the seed script, and runs it against production via service-role key.
3. @pwa-maintainer updates `ASP_SUSPENSIONS_2026` → `ASP_SUSPENSIONS_2027` in `index.html` and deploys.

Snow emergency additions (if needed mid-year): Manual seed via the Supabase SQL Editor with the service-role key. No automation until the 311 API path is wired.

---

## 5. Dedup Indexes (follow-on migration)

The two partial unique indexes described in §3.6 and §4.4 are required for the `ON CONFLICT` upsert targets. They belong in a follow-on migration file `supabase/02b-pins-ingest-indexes.sql` applied immediately after `02-pins-schema.sql`:

```sql
-- supabase/02b-pins-ingest-indexes.sql
-- Partial unique indexes for open-data dedup on the pins table.
-- Depends on: 02-pins-schema.sql applied.

create unique index if not exists pins_filming_permit_id_uidx
  on public.pins ((meta->>'permit_id'))
  where pin_type = 'filming';

create unique index if not exists pins_asp_suspension_date_uidx
  on public.pins ((meta->>'suspension_date'))
  where pin_type = 'asp_suspended_today';
```

These are split into a separate file because they depend on the `pins` table existing and because they may be applied separately by ops without re-running the full schema migration.

---

## 6. iOS Consumption Contract

The iOS `CommunityPinService` (stream C in community-1.0-buildplan.md, serializes after schema apply) fetches pins via PostgREST against the `pins_with_author` view:

```
GET /rest/v1/pins_with_author
  ?pin_type=in.(filming,asp_suspended_today)
  &resolved_at=is.null
  &or=(expires_at.is.null,expires_at.gt.<ISO-timestamp-now>)
  &select=id,pin_type,source,lifespan,lat,lng,segment_id,zone_id,expires_at,confirm_count,dispute_count,meta,notes,author_username
```

Replace `<ISO-timestamp-now>` with the current device time in ISO 8601 format at call time. This is the client-side expiry filter described in schema spec §8.

`asp_suspended_today` pins: the iOS display layer checks for a pin with `pin_type = 'asp_suspended_today'` and `meta->>'suspension_date' = today's YYYY-MM-DD`. If found, render the citywide ASP banner (same banner the PWA renders from `ASP_SUSPENSIONS_2026`). The lat/lng on the pin row is ignored for display purposes.

Realtime: Subscribe to the `pins` table filtered by `zone_id` for zone-specific updates, or use a broad subscription filtered by `pin_type = 'filming'` for the city-level film permit layer. Film permit Realtime events fire when the ingest job upserts a row (INSERT or UPDATE).

---

## 7. Explicitly Out of Scope (TF2 / Never)

- **DOT closures:** NYC DOT permit data (`nyc_dot` or `HIQA` APIs) has inconsistent data quality — permits are often not closed out when work finishes, producing stale durable pins that damage user trust. Per OQ-4 in community-1.0-buildplan.md, this is TF2 after a data quality audit.
- **Construction:** Same rationale as DOT closures. HIQA data is partial. TF2.
- **Special events via 311:** NYC 311 has a parades/events API (`311.nyc.gov`) but it requires an API key and has browser CORS restrictions. Defer to iOS native implementation post-TF1.
- **Spot handoff ("I'm leaving"):** Explicitly out of scope per community-1.0-direction.md §4 (MonkeyParking/Sweetch SF precedent). Do not spec or build.
- **Photo evidence:** Supabase Storage + `photo_url` column deferred post-TF2 per schema spec §14.

---

## 9. Deployment (Kevin's Manual Steps)

All SQL and Edge Function code is in the repo. None of these steps run automatically — Kevin applies them in order.

### Step 1 — Apply 02c ASP seed (immediate, no Edge Function needed)

1. Open the Supabase SQL Editor for project `jiispshyqerscdoferaw`.
2. Paste the entire contents of `supabase/02c-asp-seed.sql` and run.
3. Verify: `select count(*) from public.pins where pin_type = 'asp_suspended_today';` should return 42.
4. Spot-check one row: `select meta, expires_at from public.pins where pin_type = 'asp_suspended_today' and meta->>'suspension_date' = '2026-06-19';` — confirm `reason` = "Juneteenth" and `expires_at` is `2026-06-19 23:59:59-04` (EDT offset).
5. The script is idempotent. Running it again produces no changes (ON CONFLICT DO UPDATE is a no-op when values match).

### Step 2 — Set Edge Function secrets

Before deploying the function, set the secrets it reads from `Deno.env`:

```bash
# From your local machine with the Supabase CLI installed and logged in:
supabase secrets set --project-ref jiispshyqerscdoferaw \
  NYC_APP_TOKEN=<your-nyc-opendata-app-token>
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically by the Supabase runtime — do NOT set them manually. `NYC_APP_TOKEN` is optional but recommended for higher Socrata rate limits; register for a free token at https://data.cityofnewyork.us/profile/app_tokens.

### Step 3 — Deploy the Edge Function

```bash
# From the repo root, with Supabase CLI installed and logged in:
supabase functions deploy ingest-film-permits \
  --project-ref jiispshyqerscdoferaw
```

The function source is at `supabase/functions/ingest-film-permits/index.ts`.

### Step 4 — Invoke once for immediate backfill

After deployment, trigger a manual run to ingest all currently active film permits without waiting for the cron:

```bash
curl -X POST \
  https://jiispshyqerscdoferaw.functions.supabase.co/ingest-film-permits \
  -H "Authorization: Bearer <service-role-key>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

Expected response shape: `{"inserted":<N>,"updated":<M>,"skipped":<K>,"errors":[],"totalFetched":<T>}`. A non-empty `errors` array means some permits had coordinate problems — check the function logs in the Supabase Dashboard for the logged `eventid` values.

### Step 5 — Store service-role key in Vault (required for Step 6)

The pg_cron job reads the service-role key from Vault at runtime. Store it once:

1. Dashboard → Settings → Vault → New Secret.
2. Name: `service_role_key`
3. Value: the service-role JWT (starts with `eyJ...`; find it under Dashboard → Settings → API → Service role key).

### Step 6 — Apply 02d cron schedule + upsert RPC

1. Open the Supabase SQL Editor.
2. Paste the entire contents of `supabase/02d-ingest-cron.sql` and run.
3. Verify the cron job registered: `select jobname, schedule, active from cron.job where jobname = 'ingest-film-permits';` should return one row with `active = true`.
4. The `upsert_filming_pin` RPC is also created by this script — verify: `select proname from pg_proc where proname = 'upsert_filming_pin';`.

### Step 7 — Apply 02f ingest run log + staleness tracking (FT-16)

1. Open the Supabase SQL Editor.
2. Paste the entire contents of `supabase/02f-ingest-runs.sql` and run.
3. Verify: `select * from public.ingest_runs limit 1;` (empty result is fine — no rows exist until
   the Edge Function is redeployed with the FT-16 changes and invoked at least once).
4. Redeploy the Edge Function (Step 3) — it now writes to `ingest_runs` and probes upstream
   freshness on every run. Re-run Step 4's manual invocation and confirm the response includes
   `upstreamStale`, `staleDays`, and `upstreamLatestRowAt`, and that `select * from public.ingest_runs
   order by run_at desc limit 1;` shows the new row.

### Yearly calendar update (2027)

When NYC publishes the 2027 ASP calendar (typically December 2026):

1. `@backend-data` updates `supabase/02c-asp-seed.sql` with the new dates and re-runs it (idempotent ON CONFLICT handles the upsert).
2. `@pwa-maintainer` renames `ASP_SUSPENSIONS_2026` → `ASP_SUSPENSIONS_2027` in `index.html` and deploys.

---

## 8. No Secrets in This Diff

Checklist:
- No Supabase service-role key in any file in this diff. The key is referenced conceptually ("service-role key") but no actual JWT string is present.
- No NYC OpenData app token. The token is stored in a Supabase Edge Function secret at deploy time.
- No pg_cron credential string — the vault reference is noted but the value is external.
