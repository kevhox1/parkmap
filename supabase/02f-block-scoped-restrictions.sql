-- WePark block-scoped temporary restrictions (FT-15 / TF2-15)
-- Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §3.2 (schema sketch, finalized here),
--       §3.3 (auto-resolve gap), §5 (time window model), §6 (trust/abuse), §7 (photo evidence & PII).
-- Stream A of that spec. Proposed by @backend-data 2026-08-11. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor after @qa-verifier clears AC-S1 through AC-S8.
-- Idempotent: safe to re-run on a clean or partially-applied project.
-- Depends on: 02-pins-schema.sql (pins table, pin_type enum), 02e-auto-resolve-trigger.sql
--             (auto_resolve_on_dispute function/trigger — this file REPLACES its body, does not
--             re-derive it from scratch).
--
-- ============================================================
-- DIVERGENCES FROM THE SPEC'S §3.2 SKETCH — read before applying
-- ============================================================
-- The spec explicitly names this file as a sketch for @backend-data to finalize. Three points
-- diverge from the literal sketch; each is called out again inline at the relevant section below
-- and summarized in the PR body.
--
--   1. `pin_evidence.pin_id` is nullable + ON DELETE SET NULL, not "not null + ON DELETE CASCADE"
--      as sketched. `report_group_id` (not null) is the durable identifier for a submission's
--      evidence, not a single arbitrary pin row. See "pin_evidence" section below for the full
--      reasoning — the sketch's CASCADE would silently orphan evidence for the other N-1
--      blockfaces in a group the moment an author deletes just one mis-tapped blockface row via
--      the existing, unmodified `pins_delete_own` policy.
--   2. The hard-ceiling constraint is scoped to `source = 'crowd' AND report_group_id is not
--      null`, not to `pin_type in ('filming','construction')` unconditionally. This protects the
--      existing open-data `upsert_filming_pin` ingestion path (`02d-ingest-cron.sql`) from being
--      broken by a legitimate multi-week filming permit exceeding the crowd-report ceiling — the
--      ceiling's stated purpose (§6) is abuse control on the new crowd primitive, not a constraint
--      on NYC's own permit data.
--   3. Added a general `starts_at <= expires_at` sanity constraint. Not asked for explicitly, but
--      a free correctness fix: nothing outside this feature ever sets `starts_at`, so it cannot
--      break any existing row, and it closes an obvious "inverted window" bug class before any
--      client ships against this schema.

-- ============================================================
-- 1. pins: starts_at, report_group_id
-- ============================================================
-- starts_at: null = active immediately (matches every existing pin type's current implicit
--            behavior — zero migration risk, no backfill needed).
-- report_group_id: links N blockface rows (one per selected blockface) from one user report.
--            Chosen over a join table per spec §3.2 rationale: reuses pins_insert_crowd RLS and
--            the existing plain-REST insert path unmodified — no new RPC, no new policy.
alter table public.pins
  add column if not exists starts_at        timestamptz,
  add column if not exists report_group_id  uuid;

comment on column public.pins.starts_at is
  'Null = active immediately. Active window is [starts_at ?? created_at, expires_at]. See docs/ft15-tf215-temporary-block-restrictions-spec.md §5.';
comment on column public.pins.report_group_id is
  'Links N pins rows (one per selected blockface) from a single block-scoped report submission. Null for all pin types outside this feature. See docs/ft15-tf215-temporary-block-restrictions-spec.md §3.2.';
comment on column public.pins.segment_id is
  'Street|from|to key from tiles/index.json (3-part, no side) for most pin types. For pin_type in (filming, construction) AND report_group_id is not null, this is instead a 4-part blockface key: STREET|MIN(FROM,TO)|MAX(FROM,TO)|SIDE (cross streets sorted so the key is direction-agnostic). Safe divergence: the only existing writer of segment_id on filming pins (upsert_filming_pin) always writes null, so there is no legacy 3-part data on filming rows to collide with; construction pins have no existing writer at all. See docs/ft15-tf215-temporary-block-restrictions-spec.md §3.2.';

-- Lookup: fetch/update all rows in one report's group (read path, author-side edits).
create index if not exists pins_report_group_id_idx
  on public.pins(report_group_id)
  where report_group_id is not null;

-- Rate-limit trigger support: "how many distinct report_group_ids has this author created
-- recently" is the hot query the trigger below runs on every block-scoped insert.
create index if not exists pins_author_report_group_created_idx
  on public.pins(author_id, created_at)
  where report_group_id is not null;

-- General sanity: a window cannot end before it starts. Nothing outside this feature sets
-- starts_at today, so this cannot reject any existing row.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pins_starts_before_expires_chk'
  ) then
    alter table public.pins
      add constraint pins_starts_before_expires_chk
      check (starts_at is null or expires_at is null or expires_at > starts_at);
  end if;
end $$;

-- ============================================================
-- 2. Hard-ceiling constraint on the time window (§5.3)
-- ============================================================
-- filming:      24h default (client-enforced, not here) / 7-day hard ceiling from starts_at.
-- construction: 14d default (client-enforced, not here) / 90-day hard ceiling from starts_at.
-- OQ-2 (spec, non-blocking): these numbers are first-pass placeholders, not researched values.
-- Scoped to `source = 'crowd' and report_group_id is not null` — see divergence note #2 above.
-- A CHECK constraint (not a BEFORE INSERT trigger) is deliberate: it applies to UPDATE as well as
-- INSERT, so a future author-side "extend expires_at" affordance (named as an out-of-scope
-- follow-up in the spec, §14) cannot silently punch through the ceiling either — the constraint
-- is the actual hard limit, not merely an insert-time gate.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pins_block_scoped_ceiling_chk'
  ) then
    alter table public.pins
      add constraint pins_block_scoped_ceiling_chk
      check (
        not (source = 'crowd' and report_group_id is not null)
        or expires_at is null
        or expires_at <= coalesce(starts_at, created_at) + case pin_type
             when 'filming'      then interval '7 days'
             when 'construction' then interval '90 days'
             else interval '90 days'  -- generous fallback if this primitive is ever reused by another type
           end
      );
  end if;
end $$;

-- ============================================================
-- 3. pin_evidence — photo storage metadata (§7)
-- ============================================================
-- PII note: the placard photo this feature was built around has a real name and phone number on
-- it. This table + its RLS + the storage bucket policies below are the entire PII containment
-- boundary. pins_with_author (the public view every client reads) is NOT modified anywhere in
-- this migration and gains no evidence-related column.
--
-- Divergence from the §3.2 sketch (see top-of-file note #1): `pin_id` here is nullable with
-- ON DELETE SET NULL, and `report_group_id` is NOT NULL and is the durable identifier for a
-- submission's evidence. The sketch had `pin_id uuid not null references pins(id) on delete
-- cascade` with `report_group_id` only as a denormalized convenience column. That shape has a
-- real bug: per §3.4's own data flow, ONE photo backs ALL N pins rows in a group, but a single
-- pin_id + CASCADE means deleting any ONE of those N rows (a normal, already-supported action
-- under the existing, unmodified `pins_delete_own` policy — e.g. an author fixing a mis-tapped
-- blockface) deletes the evidence row outright, orphaning the other N-1 blockfaces from ever
-- being able to reference their own evidence. report_group_id is the stable key; pin_id is kept
-- only as an optional "representative pin" convenience pointer for joins, not a cascade anchor.
--
-- Known accepted gap (not fixed here, flagged for B3): per §3.4's write order, the evidence row
-- is inserted BEFORE any of the N pins rows exist (client generates report_group_id up front).
-- If the subsequent pins insert is rejected (e.g. by the rate-limit trigger below), the evidence
-- row is left orphaned with no pins ever pointing at report_group_id. This is a client-side
-- retry/ordering concern, not a schema defect — the spec explicitly rules out a new wrapping RPC
-- for this insert path (§3.4: "no new RPC needed"), and evidence retention already has no
-- automatic deletion in phase 1 (§7), so an orphaned row is inert, not harmful.
create table if not exists public.pin_evidence (
  id               uuid primary key default gen_random_uuid(),
  report_group_id  uuid not null,
  pin_id           uuid references public.pins(id) on delete set null,
  storage_path     text not null,
  uploaded_by      uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);

comment on table public.pin_evidence is
  'Photo evidence for block-scoped restriction reports. NEVER exposed via pins_with_author or any anon-readable path — read is author-only + service_role. See docs/ft15-tf215-temporary-block-restrictions-spec.md §7.';
comment on column public.pin_evidence.report_group_id is
  'Durable link to the pins.report_group_id shared by the N blockface rows in this submission. Not a foreign key (pin_evidence is written before the pins rows exist, per §3.4 write order) — an application-level invariant, not enforced in SQL.';
comment on column public.pin_evidence.pin_id is
  'Optional pointer to one representative pins row, for convenience joins only. Nullable + ON DELETE SET NULL (not the cascade/ownership key) — see the divergence note above this table.';
comment on column public.pin_evidence.storage_path is
  'Path within the private pin-evidence Storage bucket. Convention: {auth.uid()}/{report_group_id}/{filename} — the leading auth.uid() segment is what the storage.objects RLS policies below key on.';

create index if not exists pin_evidence_report_group_id_idx
  on public.pin_evidence(report_group_id);
create index if not exists pin_evidence_uploaded_by_idx
  on public.pin_evidence(uploaded_by);
create index if not exists pin_evidence_pin_id_idx
  on public.pin_evidence(pin_id)
  where pin_id is not null;

alter table public.pin_evidence enable row level security;

-- Only the uploader can read their own evidence row. service_role bypasses RLS entirely for
-- future moderation tooling (not built here).
drop policy if exists pin_evidence_select_own on public.pin_evidence;
create policy pin_evidence_select_own on public.pin_evidence
  for select using (auth.uid() = uploaded_by);

drop policy if exists pin_evidence_insert_own on public.pin_evidence;
create policy pin_evidence_insert_own on public.pin_evidence
  for insert with check (auth.uid() = uploaded_by);

-- No update/delete policy in phase 1 — matches §7's "no automatic deletion in phase 1" retention
-- posture and the §3.2 sketch's minimal scope. An author who wants to remove a report can still
-- delete the pins rows via the existing pins_delete_own policy; the evidence row is left in
-- place (harmless, author-readable only) until a future retention sweep (§14 follow-up).

-- ============================================================
-- 4. Storage: private 'pin-evidence' bucket + owner-scoped policies
-- ============================================================
-- No public/anon read policy exists anywhere in this section, by design (§7). Access is only via
-- the uploading user's own authenticated session (short-lived signed URLs requested by the
-- uploader, or service-role tooling later).
insert into storage.buckets (id, name, public)
values ('pin-evidence', 'pin-evidence', false)
on conflict (id) do nothing;

-- ENABLE ROW LEVEL SECURITY is idempotent in Postgres 15 (Supabase's engine) — see the same note
-- in 02-pins-schema.sql. Supabase projects have RLS enabled on storage.objects by default; this
-- statement is a no-op belt-and-suspenders guard, not a functional change.
alter table storage.objects enable row level security;

-- Ownership convention: object path is {auth.uid()}/{report_group_id}/{filename}. Using the path
-- prefix (storage.foldername) rather than the storage.objects.owner column, because owner-column
-- semantics have shifted across Supabase storage versions (owner vs owner_id) — the path-prefix
-- pattern is the documented, version-stable convention and is what this migration commits to as
-- the contract for B3's upload code.
drop policy if exists pin_evidence_storage_select_own on storage.objects;
create policy pin_evidence_storage_select_own on storage.objects
  for select using (
    bucket_id = 'pin-evidence'
    and auth.uid() is not null
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists pin_evidence_storage_insert_own on storage.objects;
create policy pin_evidence_storage_insert_own on storage.objects
  for insert with check (
    bucket_id = 'pin-evidence'
    and auth.uid() is not null
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- No update/delete storage policy in phase 1 — same rationale as the pin_evidence table RLS
-- above (§7 retention posture). Uploads are write-once; nothing in the spec requires replacing or
-- removing an evidence photo post-submit.

-- ============================================================
-- 5. Auto-resolve gap fix (§3.3, §6.1)
-- ============================================================
-- Today's guard (02e-auto-resolve-trigger.sql) is `lifespan = 'ephemeral' AND source = 'crowd'`.
-- A block-scoped filming/construction report is lifespan = 'session' or 'durable' — with the old
-- guard it has NO dispute-driven resolution path at all, only hard expiry (days to weeks for
-- construction). This replaces the function body only; the trigger itself (AFTER UPDATE OF
-- dispute_count on pins) is unchanged in shape, re-created here only to keep the file
-- self-sufficiently re-runnable without depending on 02e having been applied in the same session.
create or replace function public.auto_resolve_on_dispute()
returns trigger language plpgsql security definer as $$
begin
  -- Guard: only act when crossing the threshold and not already resolved.
  -- Threshold: dispute_count >= 3 (Kevin-approved OQ-2, option A2, docs/tier3-auth-and-reactions-spec.md).
  --
  -- Scope, extended by this migration (docs/ft15-tf215-temporary-block-restrictions-spec.md §6.1):
  --   lifespan = 'ephemeral'                                            — original case, unchanged.
  --   OR (lifespan in ('session','durable') AND pin_type in ('filming', 'construction'))
  --                                                                      — NEW: closes the gap for
  --                                                                        block-scoped reports.
  --   AND source = 'crowd'                                              — excludes open_data/hybrid
  --                                                                        pins in both branches.
  --
  -- AC-S6: a source=crowd, pin_type=filming, lifespan=session pin at 3 disputes now resolves
  -- (previously would NOT). An ephemeral crowd pin at 3 disputes still resolves (no regression).
  if new.dispute_count >= 3
     and new.resolved_at is null
     and new.source = 'crowd'
     and (
       new.lifespan = 'ephemeral'
       or (new.lifespan in ('session', 'durable') and new.pin_type in ('filming', 'construction'))
     )
  then
    update public.pins
    set
      resolved_at = now(),
      updated_at  = now()
    where id = new.id;
    -- NOTE: this UPDATE sets resolved_at and updated_at only — NOT dispute_count. The AFTER
    -- UPDATE OF dispute_count trigger fires only when dispute_count is in the updated column
    -- list. This UPDATE does not touch dispute_count, so the trigger does NOT re-fire. No
    -- recursion.
  end if;

  -- TODO: Tier 2 — when 3rd confirm is reached (confirm_count >= 3), increment author_id's
  -- profiles.reputation by 2 per community-1.0-buildplan.md §3. Not in this pass either.

  return null;  -- AFTER trigger; return value is ignored for row-level triggers.
end;
$$;

drop trigger if exists pins_auto_resolve_on_dispute on public.pins;
create trigger pins_auto_resolve_on_dispute
  after update of dispute_count on public.pins
  for each row execute function public.auto_resolve_on_dispute();

-- ============================================================
-- 6. Rate limit (§6.2, OQ-3)
-- ============================================================
-- OQ-3 (spec, non-blocking): "3 per 24h" is an arbitrary starting number. Implemented as a
-- config table read at trigger time (not hardcoded constants) so tuning it later is an UPDATE
-- statement, not a schema migration.
create table if not exists public.rate_limit_config (
  key           text primary key,
  max_count     integer not null,
  window_hours  integer not null,
  updated_at    timestamptz not null default now()
);

comment on table public.rate_limit_config is
  'Tunable thresholds for rate-limit triggers. Update in place (e.g. update public.rate_limit_config set max_count = 5 where key = ''block_scoped_report'') to retune without a migration.';

insert into public.rate_limit_config (key, max_count, window_hours)
values ('block_scoped_report', 3, 24)
on conflict (key) do nothing;

alter table public.rate_limit_config enable row level security;
-- Deliberately no select/insert/update policy for anon or authenticated: this is internal
-- operational config, not user data. RLS-enabled-with-zero-policies is a correct, intentional
-- deny-all posture here (not an oversight) — the only readers are SECURITY DEFINER trigger
-- functions (which run as the function owner and bypass RLS, same pattern already relied on by
-- extend_pin_expiry and auto_resolve_on_dispute in 02-pins-schema.sql / 02e) and service_role
-- (which always bypasses RLS). Retuning is done by Kevin directly in the SQL editor, which runs
-- as an owner-equivalent role.

create or replace function public.enforce_block_scoped_rate_limit()
returns trigger language plpgsql security definer as $$
declare
  v_max_count    integer;
  v_window_hours integer;
  v_recent_count integer;
begin
  -- Only rate-limit block-scoped crowd reports. Everything else (open-data ingestion,
  -- non-grouped crowd pins) is untouched.
  if new.report_group_id is null or new.source != 'crowd' then
    return new;
  end if;

  select max_count, window_hours
    into v_max_count, v_window_hours
    from public.rate_limit_config
   where key = 'block_scoped_report';

  -- Belt-and-suspenders fallback if the config row is ever missing.
  v_max_count    := coalesce(v_max_count, 3);
  v_window_hours := coalesce(v_window_hours, 24);

  -- Count DISTINCT report_group_ids already created by this author in the window, excluding the
  -- group currently being inserted — so the N rows of one batched report submission (same
  -- report_group_id) don't self-count against the limit as they're inserted one at a time.
  select count(distinct report_group_id)
    into v_recent_count
    from public.pins
   where author_id = new.author_id
     and report_group_id is not null
     and report_group_id != new.report_group_id
     and created_at > now() - (v_window_hours || ' hours')::interval;

  if v_recent_count >= v_max_count then
    raise exception 'rate limit exceeded: max % block-scoped report(s) per % hour(s)', v_max_count, v_window_hours
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

drop trigger if exists pins_enforce_block_scoped_rate_limit on public.pins;
create trigger pins_enforce_block_scoped_rate_limit
  before insert on public.pins
  for each row execute function public.enforce_block_scoped_rate_limit();
