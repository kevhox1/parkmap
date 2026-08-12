-- WePark block-scoped temporary restrictions (FT-15 / TF2-15)
-- Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §3.2 (schema sketch, finalized here),
--       §3.3 (auto-resolve gap), §5 (time window model), §6 (trust/abuse), §7 (photo evidence & PII).
-- Stream A of that spec. Proposed by @backend-data 2026-08-11. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor after @qa-verifier clears AC-S1 through AC-S8.
-- Idempotent: safe to re-run on a clean or partially-applied project.
-- Depends on: 02-pins-schema.sql (pins table, pin_type enum, pins_with_author view),
--             02e-auto-resolve-trigger.sql (auto_resolve_on_dispute function/trigger — this file
--             REPLACES its body, does not re-derive it from scratch).
--
-- ============================================================
-- REVISION HISTORY
-- ============================================================
-- Round 1 (commits b83124b6, 40f04315): initial migration + storage-ownership hardening.
-- Round 2 (this revision): fixes four issues found in independent QA
-- (docs/qa/ft15-a-block-scoped-schema-qa.md, docs/qa/ft15-b1-ios-models-qa.md), all four verified
-- against this exact file before this revision was written:
--   1. 🔴 BLOCKING, fixed. The hard-ceiling CHECK and the rate-limit trigger both keyed off
--      `report_group_id is not null` — a plain, client-supplied, RLS-unenforced column. Any
--      authenticated user (anonymous auth is enabled on this project) could omit
--      `report_group_id` on a `filming`/`construction` crowd insert and bypass BOTH the duration
--      ceiling and the 3-per-24h rate limit, and the spec's own §3.4 Channel 3 fetch predicate
--      (`source=crowd, pin_type in (filming, construction), resolved_at is null, expires_at >
--      now`) has no `report_group_id` filter, so the row would still render as a legitimate
--      closure on every client. See "2. Required report_group_id correlation" below — fixed by
--      adding a `NOT VALID` CHECK forcing `source='crowd' AND pin_type in ('filming',
--      'construction') ⟹ report_group_id is not null`, which structurally closes the gap the
--      existing controls already assumed was true but never enforced.
--   2. 🔴 BLOCKING, fixed. `pins_with_author` (02-pins-schema.sql:274) is a `select p.*, ...` view
--      created BEFORE `starts_at`/`report_group_id` existed. PostgreSQL expands `p.*` into an
--      explicit column list at `CREATE VIEW` time, not a live wildcard — `ALTER TABLE ... ADD
--      COLUMN` afterward does not retroactively add columns to an already-created view's output.
--      Without a fix, `starts_at`/`report_group_id` would never reach any client, ever, with zero
--      error anywhere (same failure shape as the FT-14 join-drop). See "5. Recreate
--      pins_with_author" below.
--   3. 🟡 Section order changed. §5 (auto-resolve) and §6 (rate limit) — both spec-"required" —
--      now precede the Storage section, which carries the one real, documented ownership risk in
--      this file. A stuck Storage section can no longer gate the required abuse-control mechanisms
--      out of a single-pass hand-run apply. The `pins_with_author` fix (new, also required) is
--      placed before Storage for the identical reason.
--   4. 🟢 Nit, fixed. The `starts_at`/`expires_at` sanity constraint's summary comment said "<="
--      but the code is strict "<" (a zero-length window is rejected) — comment corrected to match
--      the code, since a misleading comment on a hand-run production migration is worse than none.
-- Not changed, per QA's own explicit "no action needed" / "out of scope" calls (see PR discussion
-- for the full reasoning on each): the rate-limiter's benign TOCTOU race under concurrent inserts
-- (finding #4, an abuse deterrent not a security boundary), `pin_evidence.pin_id` always being
-- null in practice today (finding #6, intentionally optional, no code path sets it yet),
-- `pin_evidence.report_group_id` having no FK (finding #7, inherent to the write-before-pins-exist
-- order, already accepted), and `search_path` pinning on the two `SECURITY DEFINER` functions
-- (pre-existing pattern from `02-pins-schema.sql`/`02e`, not a regression introduced here). The
-- rate-limit index composite-column tweak (finding #5) IS applied below — cheap, zero-risk.
--
-- Round 3 (this revision, docs/qa/ft15-a-block-scoped-schema-qa-pass2.md): both Pass 1 blocking
-- findings (required report_group_id correlation, pins_with_author) were independently
-- re-verified as genuinely fixed and are UNCHANGED in this revision. Pass 2 found two NEW,
-- independent bypasses of the rate-limit trigger specifically (adversarial testing was the
-- explicit ask of that pass) — both fixed here, narrowly, without touching anything else in the
-- file:
--   1. 🔴 BLOCKING, fixed. The rate-limit trigger's `count(distinct report_group_id)` self-
--      exclusion (`report_group_id != new.report_group_id`) has no time bound: an author who
--      always reuses ONE fixed report_group_id is excluded from its own count on every insert,
--      forever, so the distinct-group count can never exceed the number of OTHER ids the author
--      has ever used — an attacker who never varies the id stays at 0 permanently. See
--      enforce_block_scoped_rate_limit() Guard 2 below (new): an absolute per-author cap on total
--      block-scoped ROWS in the window, counted with NO id-based exclusion at all, closes this —
--      count(*) grows with every row regardless of how report_group_id is chosen, unlike
--      count(distinct ...) of a value the attacker fully controls. Guard 1 (the original distinct-
--      group check) is left textually unchanged: QA pass 2 confirmed time-bounding its self-
--      exclusion instead does NOT close the bypass (a reused id still maxes out at exactly one
--      distinct value, however the exclusion window is scoped) and would additionally penalize a
--      legitimate delayed retry of the same batch. See inline comment above Guard 1 for the full
--      "why not fix it there instead" reasoning.
--   2. 🟡 SIGNIFICANT, fixed. The trigger was `BEFORE INSERT` only; the pre-existing, unrestricted
--      `pins_update_own` policy let an author insert a cheap non-grouped crowd pin (report_group_id
--      null, so the guard's own null-check skipped the INSERT-time check entirely) and then UPDATE
--      it into a filming/construction block-scoped report, never touching the rate limiter at all.
--      Fixed by widening the trigger to `BEFORE INSERT OR UPDATE`, with new in-function logic that
--      skips the guards (no re-check, no query) when an UPDATE does not change whether/how a row
--      qualifies — i.e. the row was already a qualifying block-scoped report under the SAME
--      report_group_id before this statement — so a legitimate author edit (notes, expires_at) is
--      never rejected, and the internal UPDATEs issued by refresh_pin_vote_counts() and
--      auto_resolve_on_dispute() (neither of which touches report_group_id) are unaffected. See
--      enforce_block_scoped_rate_limit() for the full skip-condition reasoning and CREATE TRIGGER
--      pins_enforce_block_scoped_rate_limit below.
-- Verified NOT to reject Kevin's canonical 4-row E 2nd St batch (one report_group_id, 4 sequential
-- inserts): traced Guard 2's existing-row count at each of the 4 inserts as 0, 1, 2, 3 — all well
-- under the new max_rows default (30) — see rate_limit_config seed and Guard 2 comment below.
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
--      on NYC's own permit data. (Round 2 note: this scoping is now backed by the new required
--      report_group_id correlation constraint below, so it's no longer bypassable the way QA
--      found — see REVISION HISTORY item 1.)
--   3. Added a general `starts_at < expires_at` sanity constraint (strict — a zero-length window
--      is rejected, not just an inverted one). Not asked for explicitly, but a free correctness
--      fix: nothing outside this feature ever sets `starts_at`, so it cannot break any existing
--      row, and it closes an obvious "inverted/zero window" bug class before any client ships
--      against this schema.

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
  'Links N pins rows (one per selected blockface) from a single block-scoped report submission. Null for all pin types outside this feature. Required (see pins_block_scoped_report_group_required_chk below) whenever source=crowd and pin_type in (filming, construction). See docs/ft15-tf215-temporary-block-restrictions-spec.md §3.2.';
comment on column public.pins.segment_id is
  'Street|from|to key from tiles/index.json (3-part, no side) for most pin types. For pin_type in (filming, construction) AND report_group_id is not null, this is instead a 4-part blockface key: STREET|MIN(FROM,TO)|MAX(FROM,TO)|SIDE (cross streets sorted so the key is direction-agnostic). Safe divergence: the only existing writer of segment_id on filming pins (upsert_filming_pin) always writes null, so there is no legacy 3-part data on filming rows to collide with; construction pins have no existing writer at all. See docs/ft15-tf215-temporary-block-restrictions-spec.md §3.2.';

-- Lookup: fetch/update all rows in one report's group (read path, author-side edits).
create index if not exists pins_report_group_id_idx
  on public.pins(report_group_id)
  where report_group_id is not null;

-- Rate-limit trigger support: "how many distinct report_group_ids has this author created
-- recently" is the hot query the trigger below runs on every block-scoped insert. report_group_id
-- is included in the index itself (QA finding #5) so the planner can satisfy the trigger's
-- `count(distinct report_group_id)` more of the way index-only, not just by author_id/created_at.
create index if not exists pins_author_report_group_created_idx
  on public.pins(author_id, created_at, report_group_id)
  where report_group_id is not null;

-- General sanity: a window cannot end before, or at the same instant as, it starts. Nothing
-- outside this feature sets starts_at today, so this cannot reject any existing row.
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

-- Intentionally NOT constrained to a fixed pin_type allowlist in general: nothing in this schema
-- forces every block-scoped grouped row to be filming/construction specifically — that pairing is
-- otherwise an application-level convention of this feature's write path (§3.4), not a DB
-- invariant. A CHECK constraint tying report_group_id to a fixed pin_type allowlist in THIS
-- direction would fight §9.3's explicit design goal that this is a reusable "block-scoped grouped
-- report" primitive, not a filming/construction-specific one — a future pin_type could
-- legitimately reuse report_group_id without a schema change here. The hard-ceiling constraint
-- below has its own generous fallback (90 days) for exactly this reason.
--
-- The constraint immediately below enforces the OPPOSITE, narrower direction only — filming/
-- construction crowd rows MUST carry a group id — which is what actually closes the abuse-control
-- bypass QA found (REVISION HISTORY item 1), without touching the general-reusability stance above.
--
-- ============================================================
-- 2. Required report_group_id correlation (closes QA-found abuse-control bypass)
-- ============================================================
-- Root cause of the bypass: the hard-ceiling CHECK (§3 below) and the rate-limit trigger (§7
-- below) both short-circuit to "not applicable" when report_group_id is null. report_group_id is
-- a plain nullable uuid with no NOT NULL tie to pin_type, and pins_insert_crowd (unmodified RLS,
-- 02-pins-schema.sql:142-148) never required it to be set. Result: any authenticated user
-- (including anonymous-auth users — enabled on this project per HANDOFF.md) could insert a
-- source=crowd, pin_type=filming/construction row with report_group_id simply omitted, and both
-- abuse controls would silently skip it — an unlimited-duration, rate-limit-exempt "closure" that
-- the spec's own §3.4 Channel 3 fetch predicate (no report_group_id filter) would still render as
-- legitimate on every client. Full repro in docs/qa/ft15-a-block-scoped-schema-qa.md Finding #1.
--
-- Fix: force the correlation the rest of the file already assumed. Any source=crowd row of
-- pin_type filming/construction MUST carry a report_group_id — closing the gap at its root while
-- preserving the general-reusability stance above (a future pin_type can still adopt
-- report_group_id without touching this constraint, since this constraint only fires for the two
-- pin_types named here).
--
-- NOT VALID is deliberate, not a shortcut: this environment has no access to the live production
-- database, so "verify against existing production rows before proposing this" (the explicit ask)
-- cannot be done empirically here. Code-level evidence strongly suggests zero existing violating
-- rows — the shipped `ReportSheet` UI has never offered filming/construction as crowd-submittable
-- types (confirmed by reading `ios/WePark/WePark/Views/ReportSheet.swift` and
-- `CommunityPinService.swift`'s existing `insertCrowdPin` call sites) — but "strongly suggests" is
-- not "verified," and a validating ADD CONSTRAINT would scan and could abort Kevin's hand-run
-- migration on live data this file's author cannot inspect. NOT VALID sidesteps that risk
-- entirely: it is enforced against every INSERT/UPDATE from the moment this statement commits
-- (the bypass is closed immediately, unconditionally), while existing rows are simply never
-- scanned at ADD TIME, so this statement cannot fail regardless of what's already in the table.
-- Once Kevin (or a future pass with live DB access) confirms no violating rows exist, running
--   alter table public.pins validate constraint pins_block_scoped_report_group_required_chk;
-- upgrades it to a fully validated constraint (a cheap, non-exclusive-lock operation, safe to run
-- any time) — but the security property does not depend on that follow-up ever happening.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pins_block_scoped_report_group_required_chk'
  ) then
    alter table public.pins
      add constraint pins_block_scoped_report_group_required_chk
      check (
        not (source = 'crowd' and pin_type in ('filming', 'construction'))
        or report_group_id is not null
      ) not valid;
  end if;
end $$;

-- ============================================================
-- 3. Hard-ceiling constraint on the time window (§5.3)
-- ============================================================
-- filming:      24h default (client-enforced, not here) / 7-day hard ceiling from starts_at.
-- construction: 14d default (client-enforced, not here) / 90-day hard ceiling from starts_at.
-- OQ-2 (spec, non-blocking): these numbers are first-pass placeholders, not researched values.
-- Scoped to `source = 'crowd' and report_group_id is not null` — see divergence note #2 above.
-- As of section 2 above, this scoping is no longer bypassable for filming/construction: those two
-- pin_types cannot have a null report_group_id on a crowd row at all once that constraint is
-- valid, so this CHECK's `report_group_id is not null` gate and "is this a block-scoped
-- filming/construction report" are now equivalent for the rows that matter, closing the gap QA
-- found (docs/qa/ft15-a-block-scoped-schema-qa.md Finding #1) without narrowing this constraint's
-- own forward-compat stance for a hypothetical future report_group_id-reusing pin_type.
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
-- 4. pin_evidence — photo storage metadata (§7)
-- ============================================================
-- PII note: the placard photo this feature was built around has a real name and phone number on
-- it. This table + its RLS + the storage bucket policies below are the entire PII containment
-- boundary. pins_with_author (the public view every client reads) is recreated in section 5 below
-- but still gains NO evidence-related column — evidence is never surfaced through it.
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
-- (QA finding #6: in practice pin_id is always null today, since no code path sets it yet — noted,
-- not a defect, this column is intentionally optional forward-compat.)
--
-- Known accepted gap (not fixed here, flagged for B3): per §3.4's write order, the evidence row
-- is inserted BEFORE any of the N pins rows exist (client generates report_group_id up front).
-- If the subsequent pins insert is rejected (e.g. by the rate-limit trigger below), the evidence
-- row is left orphaned with no pins ever pointing at report_group_id. This is a client-side
-- retry/ordering concern, not a schema defect — the spec explicitly rules out a new wrapping RPC
-- for this insert path (§3.4: "no new RPC needed"), and evidence retention already has no
-- automatic deletion in phase 1 (§7), so an orphaned row is inert, not harmful. (QA finding #7:
-- report_group_id has no FK for the same reason — accepted, read access stays gated on
-- uploaded_by regardless.)
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
  'Optional pointer to one representative pins row, for convenience joins only. Nullable + ON DELETE SET NULL (not the cascade/ownership key) — see the divergence note above this table. Always null today; no code path sets it yet.';
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
-- 5. Recreate pins_with_author to surface starts_at / report_group_id
-- ============================================================
-- Bug this closes (docs/qa/ft15-b1-ios-models-qa.md Finding #1): PostgreSQL expands `select p.*`
-- inside a CREATE VIEW into an explicit column list AT VIEW-CREATION TIME, not a live wildcard.
-- `pins_with_author` (02-pins-schema.sql:274) was created before starts_at/report_group_id
-- existed, so those two columns — the entire read-path payload this feature depends on — would
-- otherwise never appear in the view's output, silently, forever, with no error anywhere (same
-- failure shape as the FT-14 join-drop: a working-looking pipeline that quietly drops data).
--
-- Why an explicit column list instead of the original `create or replace view ... select p.*, ...`
-- shape: CREATE OR REPLACE VIEW may only APPEND new output columns at the end of the existing
-- column list — it cannot insert, rename, or reorder existing ones. Because the view's original
-- SELECT list was `p.*, author_username, author_reputation`, naively re-running that literal text
-- would make `p.*` re-expand to include the two new pins columns BEFORE author_username/
-- author_reputation in the output list (they're new physical columns on pins, appended at the end
-- of the base table, but p.* is not the last item in the SELECT list) — which the replace
-- algorithm reads as "renaming" author_username/author_reputation out from under their existing
-- ordinal positions: a hard error (`cannot change name of view column "author_username" to
-- "starts_at"`) that would abort Kevin's hand-run production paste. Switching to an explicit
-- column list — never `p.*` again in this view — fixes this migration AND prevents the same bug
-- class from recurring on the next pins column addition: appending new items to an explicit
-- SELECT list is always a safe CREATE OR REPLACE; appending columns to the base TABLE can never
-- silently change this view's output again.
--
-- Column order below is deliberately NOT "logical" (author fields land in the middle, then
-- starts_at/report_group_id at the very end) — it exactly preserves the ordinal position of every
-- column the existing, already-shipped view emits today, then appends the two new ones after.
-- Reordering to something cleaner would require DROP VIEW + CREATE VIEW, which also drops the
-- view's grants (`grant select on public.pins_with_author to anon, authenticated` does not survive
-- a DROP) — a real risk of silently breaking every client read in production if the re-grant is
-- ever forgotten on a hand-run paste. A slightly non-obvious column order is a strictly safer
-- trade for this file. The grant is re-issued below anyway as a defensive no-op (GRANT is
-- idempotent — re-granting an already-held privilege is not an error), in case this statement is
-- ever the one that first creates the view on a from-scratch project.
create or replace view public.pins_with_author as
  select
    p.id,
    p.pin_type,
    p.source,
    p.lifespan,
    p.lat,
    p.lng,
    p.segment_id,
    p.zone_id,
    p.author_id,
    p.created_at,
    p.updated_at,
    p.expires_at,
    p.resolved_at,
    p.confirm_count,
    p.dispute_count,
    p.meta,
    p.notes,
    pr.username    as author_username,
    pr.reputation  as author_reputation,
    p.starts_at,
    p.report_group_id
  from public.pins p
  left join public.profiles pr on pr.id = p.author_id;

grant select on public.pins_with_author to anon, authenticated;

-- ============================================================
-- 6. Auto-resolve gap fix (§3.3, §6.1)
-- ============================================================
-- Today's guard (02e-auto-resolve-trigger.sql) is `lifespan = 'ephemeral' AND source = 'crowd'`.
-- A block-scoped filming/construction report is lifespan = 'session' or 'durable' — with the old
-- guard it has NO dispute-driven resolution path at all, only hard expiry (days to weeks for
-- construction). This replaces the function body only; the trigger itself (AFTER UPDATE OF
-- dispute_count on pins) is unchanged in shape, re-created here only to keep the file
-- self-sufficiently re-runnable without depending on 02e having been applied in the same session.
--
-- Placed before the Storage section (below): this is spec-"required" functionality, and Storage
-- is the one section of this file with a real, documented ownership-related failure risk (see
-- section 8). If Storage fails on a given project, this section must already have run, not be
-- gated behind it.
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
-- 7. Rate limit (§6.2, OQ-3)
-- ============================================================
-- OQ-3 (spec, non-blocking): "3 per 24h" is an arbitrary starting number. Implemented as a
-- config table read at trigger time (not hardcoded constants) so tuning it later is an UPDATE
-- statement, not a schema migration.
--
-- Placed before the Storage section (below) for the same reason as section 6 — this is
-- spec-"required" and must not be gated behind Storage's ownership risk in a single-pass apply.
--
-- Known limitation, not fixed (QA finding #4, low-severity, logged not blocking): both guards'
-- COUNT reads (Guard 1's `count(distinct report_group_id)`, Guard 2's `count(*)`, added round 3 —
-- see enforce_block_scoped_rate_limit() below) have no row lock (no SELECT ... FOR UPDATE /
-- advisory lock) under default READ COMMITTED isolation, so two near-simultaneous submissions from
-- the same author (e.g. two devices) could both read a count just under the threshold and both
-- proceed, landing the author one over the intended cap. This is an abuse deterrent, not a
-- security boundary, and the feature's realistic volume makes this a low-severity, accepted gap —
-- not fixed here. Distinct from, and does not reopen, QA pass 2 Finding #1 (round 3's fix target):
-- that finding was an UNBOUNDED bypass (permanently invisible, not merely racy); this TOCTOU note
-- is about an ordinary off-by-a-few race on an otherwise-bounded, working limiter.
create table if not exists public.rate_limit_config (
  key           text primary key,
  max_count     integer not null,
  window_hours  integer not null,
  max_rows      integer not null,
  updated_at    timestamptz not null default now()
);

comment on table public.rate_limit_config is
  'Tunable thresholds for rate-limit triggers. Update in place (e.g. update public.rate_limit_config set max_count = 5 where key = ''block_scoped_report'') to retune without a migration.';
comment on column public.rate_limit_config.max_rows is
  'Absolute cap on total block-scoped crowd pins rows an author may create in window_hours, independent of report_group_id distinctness. Added QA pass 2 round 3 (docs/qa/ft15-a-block-scoped-schema-qa-pass2.md Finding #1): count(distinct report_group_id) alone can never exceed 1 for an author who always reuses a single fixed id, so max_count alone cannot bound that attack no matter how its self-exclusion is scoped. max_rows counts occurrences, not distinct ids, so it bounds it. Default (30) is deliberately generous — 10x max_count — so it cannot reject a legitimate single large multi-blockface report; see enforce_block_scoped_rate_limit() Guard 2.';

insert into public.rate_limit_config (key, max_count, window_hours, max_rows)
values ('block_scoped_report', 3, 24, 30)
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
  v_max_count     integer;
  v_window_hours  integer;
  v_max_rows      integer;
  v_recent_groups integer;
  v_recent_rows   integer;
begin
  -- Only rate-limit block-scoped crowd reports. Everything else (open-data ingestion,
  -- non-grouped crowd pins) is untouched. As of section 2 above, report_group_id is guaranteed
  -- non-null for every source=crowd row of pin_type filming/construction, so this guard can no
  -- longer be bypassed by omitting report_group_id for those two types.
  if new.report_group_id is null or new.source != 'crowd' then
    return new;
  end if;

  -- QA pass 2 round 3, Finding #2: this trigger now fires BEFORE UPDATE as well as BEFORE INSERT
  -- (see CREATE TRIGGER below), closing the pins_update_own bypass (insert a cheap non-grouped
  -- crowd pin, then UPDATE it into a filming/construction report — the INSERT-time guard above
  -- never saw a report_group_id to check). Firing on every UPDATE unconditionally would also
  -- re-run the guards on a row that was ALREADY a qualifying block-scoped report before this
  -- statement (e.g. an author fixing a typo in notes, or correcting expires_at on their own
  -- existing report) — that row was already checked and counted when it first became qualifying,
  -- and Guard 2 below in particular counts pre-existing rows, so re-checking on every edit could
  -- reject a legitimate edit purely because OTHER activity by the same author has since filled the
  -- window (an edit does not add a row). So: skip both guards entirely when this UPDATE does not
  -- change whether/how the row qualifies — i.e. it was already qualifying, under the SAME
  -- report_group_id, before this statement. This also means the internal UPDATEs issued by
  -- refresh_pin_vote_counts() (votes trigger) and auto_resolve_on_dispute() below — neither of
  -- which ever touches report_group_id — always hit this skip branch and are never blocked by rate
  -- limiting. Any UPDATE that newly makes a row qualify, or reassigns an already-qualifying row to
  -- a DIFFERENT report_group_id, still falls through to the guards below.
  if tg_op = 'UPDATE' then
    if old.report_group_id is not null
       and old.source = 'crowd'
       and old.report_group_id = new.report_group_id
    then
      return new;
    end if;
  end if;

  select max_count, window_hours, max_rows
    into v_max_count, v_window_hours, v_max_rows
    from public.rate_limit_config
   where key = 'block_scoped_report';

  -- Belt-and-suspenders fallback if the config row is ever missing.
  v_max_count    := coalesce(v_max_count, 3);
  v_window_hours := coalesce(v_window_hours, 24);
  v_max_rows     := coalesce(v_max_rows, 30);

  -- Guard 1 (original, spec §6.2 "3 block-scoped reports per author per 24h"): count DISTINCT
  -- report_group_ids already created by this author in the window, excluding the group currently
  -- being inserted/updated — so the N rows of one batched report submission (same report_group_id)
  -- don't self-count against the limit as they land one at a time.
  --
  -- Left textually UNCHANGED from round 2 — QA pass 2 Finding #1 found this clause provides zero
  -- protection against an author who always reuses ONE fixed report_group_id (count(distinct ...)
  -- of a single constant value the attacker fully controls can never exceed 1, so it can never
  -- reach v_max_count regardless of how many rows are inserted). The fix is NOT to time-bound this
  -- self-exclusion: doing so still caps the count at exactly one distinct value for a reused id (a
  -- reused id is still only ever "1 distinct id," time-bound or not), so it does not close the
  -- bypass either — and it would newly penalize a legitimate delayed retry of the same batch (same
  -- report_group_id, resubmitted after a network hiccup) by making the retry consume a fresh group
  -- slot it wouldn't have consumed before. Guard 2 below closes the actual gap instead, without
  -- that regression risk, by counting rows rather than distinct ids.
  select count(distinct report_group_id)
    into v_recent_groups
    from public.pins
   where author_id = new.author_id
     and report_group_id is not null
     and report_group_id != new.report_group_id
     and created_at > now() - (v_window_hours || ' hours')::interval;

  if v_recent_groups >= v_max_count then
    raise exception 'rate limit exceeded: max % block-scoped report(s) per % hour(s)', v_max_count, v_window_hours
      using errcode = 'insufficient_privilege';
  end if;

  -- Guard 2 (new, QA pass 2 round 3): absolute cap on total block-scoped crowd ROWS created by
  -- this author in the window — no report_group_id-based exclusion at all, deliberately. This is
  -- what actually closes Finding #1: an attacker who always reuses one fixed report_group_id
  -- defeats Guard 1 completely (however Guard 1's self-exclusion is scoped, count(distinct ...) of
  -- one constant value can never reach v_max_count) but cannot defeat this guard, because count(*)
  -- grows by one on every row regardless of what report_group_id is attached to it. v_max_rows
  -- defaults generously (30 — 10x v_max_count, see rate_limit_config seed above) specifically so
  -- it can never reject a legitimate single large multi-blockface report; it exists purely to
  -- bound otherwise-unlimited row insertion under a single reused id. Verified against Kevin's
  -- canonical 4-row E 2nd St batch (one report_group_id, 4 sequential inserts): the existing-row
  -- count this query would see at each of the 4 inserts is 0, 1, 2, 3 — all well under 30, so the
  -- batch is unaffected.
  select count(*)
    into v_recent_rows
    from public.pins
   where author_id = new.author_id
     and report_group_id is not null
     and source = 'crowd'
     and created_at > now() - (v_window_hours || ' hours')::interval;

  if v_recent_rows >= v_max_rows then
    raise exception 'rate limit exceeded: max % block-scoped report row(s) per % hour(s)', v_max_rows, v_window_hours
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

drop trigger if exists pins_enforce_block_scoped_rate_limit on public.pins;
create trigger pins_enforce_block_scoped_rate_limit
  before insert or update on public.pins
  for each row execute function public.enforce_block_scoped_rate_limit();

-- ============================================================
-- 8. Storage: private 'pin-evidence' bucket + owner-scoped policies
-- ============================================================
-- OPERATOR NOTE (Kevin runs this by hand in the SQL Editor, no agent watching): `storage.objects`
-- is owned by `supabase_storage_admin`, not `postgres`. The `create policy ... on storage.objects`
-- statements below need ownership of (or membership in) that role to succeed; whether the SQL
-- Editor's session role has it varies by project vintage. This is the one section of this file
-- with a real, non-hypothetical chance of failing on a given project. If it does, you'll see an
-- error like `must be owner of table objects` or `must be owner of relation objects` on one of the
-- `create policy` statements in this section.
--
-- This section is now LAST in the file, specifically so a failure here cannot prevent sections
-- 1-7 — including the required auto-resolve and rate-limit mechanisms (6, 7) and the required
-- pins_with_author fix (5) — from having already run. Every statement in sections 1-7 is
-- independently idempotent (`if not exists` / `create or replace` / `drop ... if exists` / `on
-- conflict do nothing`), so if THIS section fails, you can safely re-run the entire file — sections
-- 1-7 will just no-op back to their current (already-correct) state and execution will reach this
-- section again. If this section's `create policy` statements keep failing after a retry (i.e. the
-- ownership issue is persistent, not transient), re-running the whole file will not get you past
-- it — at that point, either (a) select-and-run only sections 1-7 to get every required mechanism
-- live while Storage is sorted separately, or (b) fix the Storage policies directly via the
-- Supabase Dashboard → Storage → Policies UI, which does not require the SQL Editor's session role
-- to own storage.objects.
--
-- No public/anon read policy exists anywhere in this section, by design (§7). Access is only via
-- the uploading user's own authenticated session (short-lived signed URLs requested by the
-- uploader, or service-role tooling later).
insert into storage.buckets (id, name, public)
values ('pin-evidence', 'pin-evidence', false)
on conflict (id) do nothing;

-- Deliberately NOT running `alter table storage.objects enable row level security;` here.
-- Supabase enables RLS on storage.objects by default on every managed project, so the statement
-- would be a no-op on any project this migration is ever actually applied to — but unlike the
-- `if not exists`-guarded DDL elsewhere in this file, `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`
-- is not itself failure-safe against an ownership error, and `storage.objects` is owned by
-- `supabase_storage_admin`, not `postgres`. A statement that is guaranteed no-op on success and
-- can abort a hand-run migration on failure is strictly worse than not running it. If a future
-- project genuinely has RLS disabled on storage.objects, enable it via the Supabase dashboard
-- (Storage → Policies) rather than this file.

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
