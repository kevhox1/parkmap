-- WePark — open-data ingest run log + staleness tracking
-- Spec: docs/tier1-open-data-ingest-spec.md §3.9
-- Filed by @backend-data 2026-08-11 as the FT-16 fix (docs/qa/ft16-film-permit-feed-investigation.md).
-- NOT yet applied to production. Kevin applies via the Supabase SQL Editor after QA.
-- Idempotent: safe to re-run on a clean or partially-applied project.
-- Depends on: nothing beyond the base `public` schema (no FK to pins/zones/profiles —
-- this is an ops/observability table, deliberately decoupled from app data).

-- ============================================================
-- Why this table exists
-- ============================================================
-- FT-16: the ingest-film-permits Edge Function ran daily via pg_cron for ~3 months
-- while its upstream Socrata feed (tg4x-b46p) silently stopped producing new rows.
-- The function's own filter (current/future permits only) legitimately matched zero
-- rows every single day, so no error was ever raised — a genuinely-empty pull and a
-- broken pull were indistinguishable. This table gives every open-data ingest job a
-- durable, queryable history so "the feed has been dry for N days" becomes a fact we
-- can observe and alarm on, instead of state that only exists in ephemeral function
-- logs (which age out under Supabase's log retention).
--
-- This is the same failure SHAPE as TF2-19 (docs/qa/tf2-19-houston-bowery-free-investigation.md):
-- a silent, confidently-empty/incomplete pull shipped with no signal. TF2-19's fix was a
-- fail-CLOSED completeness gate at build time; this is the equivalent for a runtime cron —
-- proportionate to this layer's much lower blast radius (an empty map layer, not wrong
-- parking-legality tiles), so this is a loud LOG/observe mechanism, not a hard abort.

-- ============================================================
-- ingest_runs table
-- ============================================================
create table if not exists public.ingest_runs (
  id                       bigserial primary key,

  -- Which ingest job this row belongs to. Free text so new ingest jobs (ASP calendar,
  -- special events, construction — see spec §7 "Out of Scope") can reuse this table
  -- without a schema change; not an enum because the job roster is expected to grow.
  source                   text not null,

  run_at                   timestamptz not null default now(),

  -- Counts from this run's own processing (mirrors the Edge Function's IngestResult shape).
  fetched_count            integer not null default 0,
  inserted_count           integer not null default 0,
  updated_count            integer not null default 0,
  skipped_count            integer not null default 0,
  error_count              integer not null default 0,
  -- Truncated list of error strings for quick triage (full detail stays in function logs).
  errors                   jsonb,

  -- Upstream freshness probe: the newest row-submission timestamp the upstream feed
  -- reports RIGHT NOW, independent of this run's own current/future filter. This is
  -- what actually detects "the feed went dry" — a feed can be genuinely, correctly
  -- empty for OUR filter (no permits scheduled today) while still being freshly fed by
  -- the source agency; only a stalled `upstream_latest_row_at` means the upstream feed
  -- itself stopped moving.
  upstream_latest_row_at   timestamptz,
  -- Whether upstream_latest_row_at is older than the job's staleness threshold at the
  -- time of this run. Computed and stored (not derived at query time) so historical
  -- rows keep an accurate record even if the threshold constant changes later.
  stale                    boolean not null default false,
  stale_days               integer,

  notes                    text
);

comment on table public.ingest_runs is
  'Durable run history for open-data ingest jobs (Edge Functions invoked via pg_cron). '
  'Written by the service-role key on every invocation, success or no-op. Exists to make '
  '"upstream feed went dry" observable and loud instead of a silent 0-row no-op — see FT-16.';

-- ============================================================
-- Indexes
-- ============================================================

-- Primary read path: "give me the most recent runs for job X" (health dashboards,
-- manual `select * from ingest_runs where source = '...' order by run_at desc limit 10`).
create index if not exists ingest_runs_source_run_at_idx
  on public.ingest_runs(source, run_at desc);

-- Fast lookup of currently-stale jobs.
create index if not exists ingest_runs_stale_idx
  on public.ingest_runs(source, run_at desc)
  where stale;

-- ============================================================
-- RLS
-- ============================================================
-- This is an internal ops/observability table, not user data — there is no "owning
-- user" row to scope a policy to, so the correct default per the mandatory-RLS rule is
-- deny-all for anon and authenticated. The service-role key (used exclusively by the
-- Edge Function to write rows) bypasses RLS entirely, so writes are unaffected.
-- Enabling RLS with zero policies means every anon/authenticated request is rejected;
-- this is intentional, not an oversight.
alter table public.ingest_runs enable row level security;

-- No select/insert/update/delete policies are added on purpose (see comment above).
-- If a future admin dashboard needs read access, add an explicit
-- "is_admin" or service-role-only policy then — do not open this table to
-- anon/authenticated by default.
