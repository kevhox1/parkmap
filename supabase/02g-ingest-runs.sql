-- WePark — open-data ingest run log + staleness tracking
-- Spec: docs/tier1-open-data-ingest-spec.md §3.9
-- Filed by @backend-data 2026-08-11 as the FT-16 fix (docs/qa/ft16-film-permit-feed-investigation.md).
-- NOT yet applied to production. Kevin applies via the Supabase SQL Editor after QA.
-- Idempotent: safe to re-run on a clean or partially-applied project.
-- Depends on: nothing beyond the base `public` schema (no FK to pins/zones/profiles —
-- this is an ops/observability table, deliberately decoupled from app data).
--
-- QA pass 1 (docs/qa/ft16-staleness-guard-qa.md) reviewed an earlier cut of this table with a
-- plain `stale boolean` column and flagged (finding #2) that it let "probe failed" collapse into
-- the same `false` value as "verified fresh." Revised below to a tri-state `probe_status` column
-- before this migration was ever applied anywhere — no ALTER/backfill needed, this is still the
-- pre-apply shape.

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
  -- itself stopped moving. Null exactly when probe_status = 'probe_failed' (we could not
  -- determine a timestamp at all — see probe_status below).
  upstream_latest_row_at   timestamptz,

  -- Tri-state, not boolean, on purpose (QA finding #2 on the first cut of this table):
  -- a boolean `stale` column lets "we probed and it's fresh" and "the probe itself
  -- failed/returned an unusable shape" collapse into the same `false` value — which
  -- recreates, one layer up, the exact "legitimately-empty vs. silently-broken"
  -- ambiguity this whole mechanism exists to eliminate. 'probe_failed' must never be
  -- representable as indistinguishable from 'fresh'.
  --   'fresh'        — probe succeeded; upstream_latest_row_at is within the threshold.
  --   'stale'        — probe succeeded; upstream_latest_row_at is older than the threshold.
  --   'probe_failed' — probe could not produce a trustworthy timestamp at all (network
  --                    error, timeout, non-2xx, or an unexpected/malformed response
  --                    shape). Distinct from both of the above — treat as "unknown,
  --                    needs a human," not as "fine."
  probe_status             text not null default 'probe_failed'
                             check (probe_status in ('fresh', 'stale', 'probe_failed')),
  -- Days since upstream_latest_row_at, computed and stored (not derived at query time)
  -- so historical rows keep an accurate record even if the threshold constant changes
  -- later. Null exactly when probe_status = 'probe_failed'.
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

-- Fast lookup of runs that need a human look — both a confirmed-stale feed and a
-- probe that couldn't determine freshness at all belong in this set; only 'fresh'
-- is the "nothing to see here" state.
create index if not exists ingest_runs_needs_attention_idx
  on public.ingest_runs(source, run_at desc)
  where probe_status <> 'fresh';

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
