-- WePark Community 2.0 — Phase 0 schema extension (build 20, session S1)
-- Spec: docs/community-2.0-reconciliation-spec.md §2 (§2.1-§2.13). Every decision below cites the
-- subsection it implements. Sequencing/sizing context: docs/community-2.0-roadmap.md.
-- Proposed by @backend-data 2026-08-26. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor — see the two-step run instructions immediately
-- below before pasting anything. Run the companion `03-community-2.0-test.sh` after applying.
-- Idempotent: safe to re-run on a clean or partially-applied project (alter ... add column if not
-- exists / create ... if not exists / do-block-guarded constraints / drop-then-create policies and
-- triggers), EXCEPT that re-running does not undo anything — it converges to the same end state.
-- Depends on: 01-mvp-schema.sql (profiles, zones, zone_messages), 02-pins-schema.sql (pin_type enum,
-- pins, votes, refresh_pin_vote_counts, extend_pin_expiry, pins_with_author), 02e (auto_resolve_on_dispute
-- — untouched by this file, still fires independently), 02f (pins column-level privilege lockdown —
-- IMPORTANT, see §2.2-note below; rate_limit_config table pattern reused for §2.8).
--
-- ============================================================================================
-- HOW TO RUN THIS FILE (read before pasting anything) — Postgres restriction on new enum values
-- ============================================================================================
-- Postgres will not let a transaction USE an enum value it just added with
-- `ALTER TYPE ... ADD VALUE` in that same transaction ("unsafe use of new value of enum type").
-- The Supabase SQL Editor sends everything you paste as one query string, which Postgres wraps in
-- one implicit transaction — so pasting this entire file in a single Run risks that error the
-- moment anything later in the file evaluates 'open_spot'/'leaving_soon' as a live enum comparison
-- (this file's function BODIES reference those literals, but PL/pgSQL bodies are not type-checked
-- until first EXECUTED, which only happens on some future INSERT after this migration has already
-- committed — so a single-paste run is very likely safe in practice). To remove all doubt on a
-- hand-run production migration, run this file in TWO paste-and-Run steps:
--
--   STEP 1 — select and run ONLY the "STEP 1" block immediately below (the two ALTER TYPE lines),
--            click Run, confirm it succeeds.
--   STEP 2 — select and run everything from "STEP 2" to the end of the file, click Run.
--
-- If you paste the whole file at once and it works, that's fine too (the two-step split exists to
-- eliminate risk, not because single-paste is known to fail) — but if you hit
-- "unsafe use of new value of enum type", this is why: re-run from STEP 2 onward only, in a fresh
-- paste, after confirming STEP 1 already committed.

-- ============================================================================================
-- STEP 1 — pin_type enum additions (§2.1)
-- ============================================================================================
-- `add value if not exists` is itself idempotent (built into Postgres 12+) — no do-block guard
-- needed, unlike the original `create type` in 02-pins-schema.sql which needed a pg_type existence
-- check because CREATE TYPE has no native IF NOT EXISTS form.
--
-- Both new types fall through the EXISTING pins_insert_crowd and pins_select_public RLS policies
-- unchanged — neither restricts by pin_type — so no RLS delta is needed for these two values
-- themselves (spec §2.1). leaving_soon posts at the car's exact position, but only via an explicit,
-- user-initiated "Hand your spot to the crew" tap — a deliberate disclosure, not an ambient leak,
-- so it does not need the parked_car precedent's read lockdown. Any *future* personal-location type
-- must still follow that precedent.
alter type public.pin_type add value if not exists 'open_spot';
alter type public.pin_type add value if not exists 'leaving_soon';

-- ============================================================================================
-- STEP 2 — everything else. Run this block in a SEPARATE paste from STEP 1 above.
-- ============================================================================================

-- ============================================================
-- §2.2 `pins` table — three new columns
-- ============================================================
alter table public.pins
  add column if not exists position_fraction double precision
    check (position_fraction is null or (position_fraction between 0 and 1)),
  add column if not exists leaving_minutes integer
    check (leaving_minutes is null or leaving_minutes in (5, 10, 15, 20)),
  add column if not exists claimed_by uuid references auth.users(id);

comment on column public.pins.position_fraction is
  'Position along the blockface, [0,1] from the segment''s "from" endpoint to its "to" endpoint '
  '(same directional convention as meta.heading_toward). Null = render at segment midpoint '
  '(every existing pin type''s current, unchanged behavior). Spec §2.2.';
comment on column public.pins.leaving_minutes is
  'User-chosen countdown for a leaving_soon pin (5/10/15/20). Used for display copy and to derive '
  'expires_at server-side (§2.11) — never trust a client-supplied expires_at for this type. Spec §2.2.';
comment on column public.pins.claimed_by is
  'Single-claimant "I''m heading there" marker for leaving_soon pins. Set exactly once via the '
  'claim_pin RPC (§2.10) — first writer wins, informational only, never a reservation. Deliberately '
  'NOT granted to anon/authenticated in the column-privilege lockdown below (§2.2-note): the ONLY '
  'way to set this column is through claim_pin''s SECURITY DEFINER context, which executes as the '
  'function owner and is unaffected by the caller''s column grants. Spec §2.2, §2.10.';

-- Nullable on every existing row and every existing pin type — zero migration risk, matches the
-- starts_at/report_group_id precedent from 02f.

-- ------------------------------------------------------------------------------------------
-- §2.2-note (not in the spec's literal text, but required for the spec's own columns to work):
-- 02f-block-scoped-restrictions.sql section 2b REVOKEd the blanket table-level INSERT/UPDATE
-- privilege on public.pins from anon/authenticated and re-GRANTed it back column-by-column,
-- explicitly, "fail-closed" by that file's own stated design ("If a future migration adds a new
-- pins column, that column is NOT writable by anon/authenticated until it's explicitly added to one
-- or both GRANT column lists below"). position_fraction and leaving_minutes are exactly that case:
-- without the GRANT below, every open_spot/leaving_soon crowd insert that includes them would be
-- rejected outright with a column-privilege error (42501), even though pins_insert_crowd's RLS
-- WITH CHECK would otherwise allow the row. Column-level GRANTs are additive (each GRANT statement
-- adds columns to the existing privilege set; it does not replace 02f's list), so this is a safe,
-- minimal addition, not a re-issue of the whole grant.
--
-- claimed_by is deliberately NOT added to either grant list — see the column comment above. This
-- is the correct, secure default already established by 02f's fail-closed philosophy: leaving a
-- column out of both grants means only a SECURITY DEFINER function (claim_pin) can ever set it,
-- with zero additional lockdown code required here.
--
-- Neither column needs an UPDATE grant: no client flow ever edits its own position_fraction or
-- leaving_minutes after insert (leaving_minutes only affects expires_at derivation at INSERT time,
-- via the §2.11 trigger, which is BEFORE INSERT only).
grant insert (position_fraction, leaving_minutes) on public.pins to anon, authenticated;

-- ============================================================
-- §2.3 Zones — data operation, not a code path
-- ============================================================
-- OQ-1 resolved (docs/community-2.0-roadmap.md "Decisions locked" #4, Kevin 2026-08-26): three
-- bounding boxes, not true NTA polygons. Boxes are carved from the existing soho-les box's extent,
-- adjacent and non-overlapping, chosen as a rough correspondence to NYC's NTA neighborhood tabulation
-- areas (not an authoritative NTA boundary import — see docs/community-2.0-roadmap.md §"Decisions
-- locked" #4 for the "revisit if boxes visibly misclassify blocks" caveat):
--   nolita — roughly Houston St (north) to Kenmare/Spring St (south), Bowery (east) to
--            Lafayette/Centre (west) — NTA "SoHo-TriBeCa-Civic Center-Little Italy" subarea.
--   soho   — roughly Houston St (north) to Canal St (south), 6th Ave/Sullivan (west) to
--            Lafayette/Centre (east) — same NTA, western/southern subarea.
--   les    — roughly Houston St (north) to Grand St/East Broadway (south), Bowery (west) to the
--            East River (east) — NTA "Lower East Side" / "East Village" boundary area.
-- Do NOT delete or rewrite soho-les. zone_messages.zone_id is
-- `references public.zones(id) on delete cascade` (01-mvp-schema.sql:74) — deleting that row would
-- cascade-delete every historical SoHo/LES chat message. Leave it as an inert archive.
--
-- QA pass 1 fix (Finding #5, docs/qa/pr93-community-phase0-schema.md): soho's north edge
-- (lat_max) was 40.7280, ~480m north of Houston St's actual latitude (≈40.7237) — contradicting
-- this section's own "roughly Houston St (north)" comment above and overshooting into NoHo/
-- Greenwich Village blocks. Corrected to 40.7237 below; not a blocker per OQ-1's own "revisit if
-- boxes visibly misclassify blocks" acceptance, but the comment and the number should agree.
update public.zones set
  description = 'Legacy — superseded 2026-08-26 by nolita/soho/les. Retained for chat history; no new pins/messages should target this id.'
where id = 'soho-les';

insert into public.zones (id, name, description, lat_min, lat_max, lng_min, lng_max) values
  ('nolita', 'Nolita', 'Nolita, NY', 40.7217, 40.7256, -73.9967, -73.9930),
  ('soho',   'SoHo',   'SoHo, NY',   40.7220, 40.7237, -74.0050, -73.9970),
  ('les',    'LES',    'Lower East Side, NY', 40.7145, 40.7230, -73.9920, -73.9800)
on conflict (id) do update set
  name = excluded.name, description = excluded.description,
  lat_min = excluded.lat_min, lat_max = excluded.lat_max,
  lng_min = excluded.lng_min, lng_max = excluded.lng_max;

-- ============================================================
-- §2.4 Blockface-anchored messages — extend `zone_messages`
-- ============================================================
alter table public.zone_messages
  add column if not exists segment_id text;

create index if not exists zone_messages_segment_created_idx
  on public.zone_messages(segment_id, created_at desc)
  where segment_id is not null;

-- Nullable — every pre-existing PWA zone-chat row (segment-less) keeps working unchanged. No RLS
-- delta: zone_messages_insert_user already lets an authenticated author set any column on their own
-- insert (01-mvp-schema.sql never applied a 02f-style column-level lockdown to zone_messages).

-- ------------------------------------------------------------------------------------------
-- §2.4-note (same "p.* is frozen at view-creation time" bug class as 02f section 5 — required for
-- the new column to actually reach any client): zone_messages_with_author (01-mvp-schema.sql:122)
-- was created with an EXPLICIT column list (never `m.*`), so segment_id will NOT appear in this
-- view's output unless the view is recreated to append it — same failure shape as the FT-14
-- join-drop / the pins_with_author bug 02f fixed, just for a different view. Appending at the end of
-- an explicit SELECT list is always a safe CREATE OR REPLACE (does not rename/reorder existing
-- output columns), matching 02f section 5's own reasoning.
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
    p.reputation as author_reputation,
    m.segment_id
  from public.zone_messages m
  left join public.profiles p on p.id = m.author_id;

grant select on public.zone_messages_with_author to anon, authenticated;

-- ============================================================
-- §2.5 `profiles` — identity + trust-loop columns
-- ============================================================
alter table public.profiles
  add column if not exists avatar text,
  add column if not exists helped_count integer not null default 0,
  add column if not exists accurate_report_count integer not null default 0,
  add column if not exists total_report_count integer not null default 0;

-- The handle is decorative, not a login identifier — dedupe collisions client-side-friendly
-- (two neighbors both picking "MottStRegular" is a cosmetic non-issue, not a security one).
-- Auto-generated constraint name confirmed against 01-mvp-schema.sql's inline
-- `username text unique not null` column definition (Postgres names single-column inline UNIQUE
-- constraints `<table>_<column>_key` by default).
alter table public.profiles drop constraint if exists profiles_username_key;

-- created_at (already exists) is tenure. accurate_report_count / total_report_count back a
-- client-computed accuracy percentage (accurate / total, guard divide-by-zero client-side for a
-- brand-new poster) rather than a stored percentage that would need its own recompute trigger.

-- ============================================================
-- §2.6 Reputation — server-computed, supersedes the 02e TODO
-- ============================================================
-- Three action triggers + one accuracy trigger, mirroring the existing refresh_pin_vote_counts /
-- auto_resolve_on_dispute style (SECURITY DEFINER, narrow, single-purpose). All upsert the profiles
-- row so reputation still accrues to a user who has never opened the identity sheet (device has an
-- auth.uid() from anonymous auth the moment it does anything — a display handle is optional, a
-- reputation-bearing row is not).
--
-- search_path note (QA pass 1, docs/qa/pr93-community-phase0-schema.md, "leave as-is" item):
-- none of the SECURITY DEFINER functions in this file pin search_path via SET search_path. This
-- matches the pre-existing, already-accepted repo convention (02f-block-scoped-restrictions.sql:48-50
-- calls the same gap out for its own two SECURITY DEFINER functions as "pre-existing... not a
-- regression"). Every table/function reference in every SECURITY DEFINER function below is
-- schema-qualified (public.pins, public.profiles, public.reputation_award_log, etc.), so the classic
-- search-path-hijack privilege-escalation vector does not apply to any of them.
--
-- QA pass 1 fix (Finding #1, docs/qa/pr93-community-phase0-schema.md): the original version of this
-- section rewarded confirm/accuracy on every raw INSERT/transition with no record of having already
-- paid out for that specific (pin, actor) relationship. votes_delete_own (02-pins-schema.sql:205-207,
-- unrestricted, unchanged by this migration) lets any user delete their own vote and re-insert it,
-- replaying the reward indefinitely — the exact "counting/rewarding off live, deletable rows lets
-- delete-then-reinsert bypass a guard" anti-pattern block_scoped_report_log
-- (02f-block-scoped-restrictions.sql:679-716) already exists in this repo to close, for a different
-- trigger. Fix: an append-only ledger, reputation_award_log, keyed uniquely per
-- (source_table, source_id, kind, subject_id) — a given tuple can pay out at most once, ever, no
-- matter how many times the underlying vote/transition is replayed. Model chosen: ONE-WAY (award
-- once, never revoked on vote delete) — not a symmetric award/revoke pair. Documented reason: a
-- symmetric decrement model reopens the exact same farming shape in reverse (repeatedly toggling a
-- vote to drive rep down, e.g. to grief another account, or oscillating to churn helped_count/
-- accurate_report_count in ways that are hard to reason about under concurrent voters on the same
-- pin) and requires proving a symmetric operation can never go negative under concurrent
-- confirm/dispute toggles — genuinely harder to get right than "credit once, permanently" for a
-- reward whose product meaning ("this user helped confirm this pin at least once") is already true
-- forever once it has happened even if the vote is later retracted. This mirrors
-- block_scoped_report_log's own append-only, never-pruned, never-decremented posture exactly.
create table if not exists public.reputation_award_log (
  id           bigserial primary key,
  subject_id   uuid not null references auth.users(id) on delete cascade,
  source_table text not null,
  source_id    uuid not null,
  kind         text not null check (kind in ('confirm', 'accuracy')),
  created_at   timestamptz not null default now(),
  -- One award per (source row, kind, recipient) ever. For 'confirm', subject_id is the voter and
  -- multiple distinct voters each legitimately earn their own row for the same pin (source_id).
  -- For 'accuracy', subject_id is always the pin's author — a value fully determined by source_id —
  -- so this composite constraint is equivalent to a plain (source_table, source_id, kind) uniqueness
  -- for that kind, just expressed with the same generic 4-column shape as 'confirm'.
  unique (source_table, source_id, kind, subject_id)
);

comment on table public.reputation_award_log is
  'Append-only ledger closing the vote delete+reinsert reputation-replay vector found in QA pass 1 '
  '(docs/qa/pr93-community-phase0-schema.md Finding #1). Never updated, never deleted, no FK to votes '
  'or pins (same "application-level invariant, not enforced in SQL" pattern already used for '
  'pin_evidence.report_group_id in 02f) — surviving a votes/pins row being deleted is the entire '
  'point. No RLS policies (deny-all, same posture as rate_limit_config/block_scoped_report_log) — '
  'only the SECURITY DEFINER trigger functions below ever write to it.';

create index if not exists reputation_award_log_source_idx
  on public.reputation_award_log(source_table, source_id, kind);

alter table public.reputation_award_log enable row level security;
-- Deliberately no select/insert/update/delete policy for anon or authenticated — internal
-- abuse-accounting state, not user data, same deny-all posture as rate_limit_config and
-- block_scoped_report_log (02f). The only writers are the SECURITY DEFINER trigger functions below,
-- which bypass RLS as the function owner.

create or replace function public.award_report_reputation()
returns trigger language plpgsql security definer as $$
begin
  -- Not farmable via delete+reinsert of the SAME row: this fires AFTER INSERT only, once per newly
  -- created pins row (a fresh, immutable id every time) — it cannot re-fire for a row that already
  -- exists, deleted or not. Unbounded *insert volume* (a fresh row every time) is a rate-limiting
  -- concern, not a replay concern — see enforce_crowd_report_rate_limit() in §2.8 (QA Finding #2),
  -- which now covers every source='crowd' pin_type that reaches this trigger, not just ephemeral
  -- ones. No ledger needed here for that reason.
  if new.source = 'crowd' and new.author_id is not null then
    insert into public.profiles (id, username, reputation, total_report_count)
    values (new.author_id, 'neighbor-' || substr(new.author_id::text, 1, 8), 5, 1)
    on conflict (id) do update set
      reputation = public.profiles.reputation + 5,
      total_report_count = public.profiles.total_report_count + 1,
      updated_at = now();
  end if;
  return null;
end; $$;

drop trigger if exists pins_award_report_reputation on public.pins;
create trigger pins_award_report_reputation
  after insert on public.pins
  for each row execute function public.award_report_reputation();

create or replace function public.award_confirm_reputation()
returns trigger language plpgsql security definer as $$
declare
  v_inserted int;
begin
  if new.vote = 'confirm' then
    -- Ledger-gated: pays out at most once ever per (pin_id, user_id) pair, regardless of how many
    -- times this exact vote is deleted (votes_delete_own) and re-inserted. ON CONFLICT DO NOTHING +
    -- checking the actual row count (not just "did the votes insert succeed") is what makes this
    -- safe — a second attempt at the same tuple inserts zero ledger rows and pays out nothing.
    insert into public.reputation_award_log (subject_id, source_table, source_id, kind)
    values (new.user_id, 'votes', new.pin_id, 'confirm')
    on conflict (source_table, source_id, kind, subject_id) do nothing;
    get diagnostics v_inserted = row_count;

    if v_inserted > 0 then
      insert into public.profiles (id, username, reputation, helped_count)
      values (new.user_id, 'neighbor-' || substr(new.user_id::text, 1, 8), 2, 1)
      on conflict (id) do update set
        reputation = public.profiles.reputation + 2,
        helped_count = public.profiles.helped_count + 1,
        updated_at = now();
    end if;
  end if;
  return null;
end; $$;

drop trigger if exists votes_award_confirm_reputation on public.votes;
create trigger votes_award_confirm_reputation
  after insert on public.votes
  for each row execute function public.award_confirm_reputation();

create or replace function public.award_chat_reputation()
returns trigger language plpgsql security definer as $$
begin
  -- Not farmable via delete+reinsert: zone_messages has no delete or update policy at all
  -- (01-mvp-schema.sql defines only zone_messages_select_all and zone_messages_insert_user) — a
  -- chat message, once posted, cannot be retracted and reposted by its author. No ledger needed.
  if new.message_type = 'user' and new.author_id is not null then
    insert into public.profiles (id, username, reputation)
    values (new.author_id, 'neighbor-' || substr(new.author_id::text, 1, 8), 1)
    on conflict (id) do update set
      reputation = public.profiles.reputation + 1,
      updated_at = now();
  end if;
  return null;
end; $$;

drop trigger if exists messages_award_chat_reputation on public.zone_messages;
create trigger messages_award_chat_reputation
  after insert on public.zone_messages
  for each row execute function public.award_chat_reputation();

-- accurate_report_count: intended to fire once, the first time a pin the caller authored gets its
-- first confirm — but a vote delete+reinsert replays the 0->1 confirm_count transition indefinitely
-- (refresh_pin_vote_counts recomputes confirm_count from scratch on every votes mutation, so deleting
-- and re-inserting the SAME confirm vote drives confirm_count 1->0->1 again), which is exactly QA
-- Finding #1's second half. Same ledger fix as award_confirm_reputation above, keyed by
-- (pins, pin_id, 'accuracy') only — one award ever per pin, independent of which voter (or how many
-- delete/reinsert cycles) produced the 0->1 transition, since the recipient (the pin's author) is
-- fixed for a given pin_id regardless.
create or replace function public.award_accuracy_on_first_confirm()
returns trigger language plpgsql security definer as $$
declare
  v_inserted int;
begin
  if new.confirm_count >= 1 and old.confirm_count = 0 and new.author_id is not null then
    insert into public.reputation_award_log (subject_id, source_table, source_id, kind)
    values (new.author_id, 'pins', new.id, 'accuracy')
    on conflict (source_table, source_id, kind, subject_id) do nothing;
    get diagnostics v_inserted = row_count;

    if v_inserted > 0 then
      update public.profiles set
        accurate_report_count = accurate_report_count + 1,
        updated_at = now()
      where id = new.author_id;
    end if;
  end if;
  return null;
end; $$;

drop trigger if exists pins_award_accuracy_on_first_confirm on public.pins;
create trigger pins_award_accuracy_on_first_confirm
  after update of confirm_count on public.pins
  for each row execute function public.award_accuracy_on_first_confirm();

-- Supersedes 02e-auto-resolve-trigger.sql:75-77's TODO (author +2 on 3rd confirm) — that comment is
-- left in place with a one-line pointer to this file (edited in this same PR, per this repo's "link
-- to superseded work, don't delete" convention — spec §5). auto_resolve_on_dispute itself (the
-- 3-dispute auto-hide) is unchanged and still fires independently.

-- ============================================================
-- §2.7 "Gone" — reuse the shipped 3-dispute mechanism, don't parallel-build single-tap decay
-- ============================================================
-- No SQL in this section. Documented decision only: "Gone" maps to upsertVote(pinId, .dispute) on
-- the existing votes/auto_resolve_on_dispute path (02e), unchanged. The prototype's single-tap
-- "shrink TTL to +2min" behavior is NOT built — see spec §2.7 for the full reasoning (the shipped
-- 3-vote threshold is already proven and gamed-resistant; revisit only if live use shows 3 votes is
-- too slow for a 3-minute open_spot pin, and if so the fix is a rate_limit_config-style tunable
-- threshold, not a rebuild).

-- ============================================================
-- §2.8 Rate limiting — generalize the existing pattern to every non-block-scoped crowd report
-- ============================================================
-- rate_limit_config (02f-block-scoped-restrictions.sql:704-721) is already designed to be retuned
-- by row update, not migration. Two keys, not one — see QA fix note below.
--
-- QA pass 1 fix (Finding #2, docs/qa/pr93-community-phase0-schema.md): the original version of this
-- section scoped the trigger to lifespan='ephemeral' only. sign_correction/block_note (Tier 2 crowd,
-- durable/correction lifespan, no report_group_id — 02-pins-schema.sql:23-25 comment) fell through
-- BOTH this trigger (lifespan check) and 02f's enforce_block_scoped_rate_limit (report_group_id
-- check) entirely, leaving them with zero rate-limit coverage despite now paying +5 reputation per
-- insert via award_report_reputation (§2.6). Fixed by widening this trigger's scope to every
-- source='crowd' insert that is NOT already covered by 02f's dedicated block-scoped limiter
-- (report_group_id is not null), and splitting the config into two independently tunable keys:
--   'ephemeral_report'     — lifespan='ephemeral' (enforcement/sweeper/open_spot/leaving_soon/
--                            broken_meter): frequent, short-lived, high default cap (20/hour).
--   'durable_crowd_report' — everything else non-block-scoped (session/durable/correction, i.e.
--                            sign_correction/block_note today): persistent map clutter if abused,
--                            stricter default cap (10/24h).
-- leaving_soon is naturally self-limiting too (one active pin per parked car, per spec §2.8) but is
-- not excluded by a pin_type filter here — it is lifespan='ephemeral', so it is harmlessly counted
-- under the same bucket as enforcement/sweeper/open_spot; its natural one-per-car cadence never
-- approaches the cap.
insert into public.rate_limit_config (key, max_count, window_hours, max_rows)
values
  ('ephemeral_report', 20, 1, 60),
  ('durable_crowd_report', 10, 24, 30)
on conflict (key) do nothing;

-- QA pass 1 fix (Finding #6): COMMENT ON COLUMN replaces the entire prior comment, not appends —
-- the original text below (02f-block-scoped-restrictions.sql:714-715) is preserved verbatim, with a
-- new paragraph appended for this migration's two new keys, rather than being silently lost from the
-- live schema's introspectable comment.
comment on column public.rate_limit_config.max_rows is
  'Absolute cap on total block-scoped crowd report rows an author may create in window_hours, '
  'independent of report_group_id distinctness. Added QA pass 2 round 3 '
  '(docs/qa/ft15-a-block-scoped-schema-qa-pass2.md Finding #1): count(distinct report_group_id) '
  'alone can never exceed 1 for an author who always reuses a single fixed id, so max_count alone '
  'cannot bound that attack no matter how its self-exclusion is scoped. max_rows counts occurrences, '
  'not distinct ids, so it bounds it. Default (30) is deliberately generous — 10x max_count — so it '
  'cannot reject a legitimate single large multi-blockface report; see '
  'enforce_block_scoped_rate_limit() Guard 2. Round 4: Guard 2 (and Guard 1) now count rows in '
  'block_scoped_report_log, not live public.pins rows, so this cap is cumulative over window_hours '
  'and immune to delete-then-reinsert (docs/qa/ft15-a-block-scoped-schema-qa-pass3.md Finding #3). '
  '— '
  'For the ephemeral_report / durable_crowd_report keys added in '
  'supabase/03-community-2.0-schema.sql (§2.8): this column is currently UNUSED by design for both — '
  'see enforce_crowd_report_rate_limit() below for why a single guard fully bounds these non-block-'
  'scoped crowd reports (they never carry a report_group_id, so the "reused fixed report_group_id" '
  'bypass class 02f closed does not apply here) — seeded regardless, so a future second guard can be '
  'wired up for either key without a schema change if abuse patterns ever require it.';

-- enforce_crowd_report_rate_limit(): same shape as 02f's enforce_block_scoped_rate_limit
-- (config-driven thresholds, SECURITY DEFINER, raises 42501 over the cap) — but deliberately a
-- SINGLE guard per key (count(*) of this author's qualifying rows in the trailing window), not 02f's
-- delete-then-reinsert-proof two-guard/ledger design. This is a considered simplification, not a
-- shortcut: 02f's ledger table (block_scoped_report_log) exists specifically because THREE rounds
-- of adversarial QA demonstrated concrete bypasses of a live-pins-count guard for block-scoped
-- reports (reused report_group_id, delete-then-reinsert). Non-block-scoped crowd reports have no
-- report_group_id concept at all (always null on these rows) — the reused-id bypass class is
-- structurally impossible here — leaving only the delete-then-reinsert class as a theoretical
-- concern. If live abuse is observed, port 02f's append-only ledger pattern directly (same
-- author_id/created_at index shape) rather than adding a second live-count guard.
--
-- BEFORE INSERT only (not BEFORE INSERT OR UPDATE like 02f's trigger). Accepted, documented gap
-- (mirroring 02f's own "known limitation, not fixed" style for its TOCTOU note): an author could in
-- principle insert a pin under one lifespan bucket, then UPDATE lifespan to move it into the other
-- bucket after the fact (lifespan remains in the anon/authenticated UPDATE grant list — 02f section
-- 2b — since it is a legitimate author-edit field for other reasons), bypassing this guard on that
-- one row. Not closed here to keep this fix scoped to QA Finding #2's actual coverage gap; if this
-- is exploited in practice, widen the trigger to BEFORE INSERT OR UPDATE with the same old/new
-- skip-condition shape 02f uses.
create or replace function public.enforce_crowd_report_rate_limit()
returns trigger language plpgsql security definer as $$
declare
  v_key          text;
  v_max_count    integer;
  v_window_hours integer;
  v_recent_rows  integer;
begin
  -- Only rate-limit non-block-scoped crowd reports. Block-scoped filming/construction
  -- (report_group_id is not null) already has its own dedicated limiter
  -- (02f enforce_block_scoped_rate_limit) — skip here to avoid double-gating an already-tuned,
  -- three-rounds-of-adversarial-QA'd mechanism.
  if new.source != 'crowd' or new.report_group_id is not null then
    return new;
  end if;

  if new.lifespan = 'ephemeral' then
    v_key := 'ephemeral_report';
  else
    v_key := 'durable_crowd_report';
  end if;

  select max_count, window_hours
    into v_max_count, v_window_hours
    from public.rate_limit_config
   where key = v_key;

  -- Belt-and-suspenders fallback if a config row is ever missing.
  if v_max_count is null then
    if v_key = 'ephemeral_report' then
      v_max_count := 20; v_window_hours := 1;
    else
      v_max_count := 10; v_window_hours := 24;
    end if;
  end if;

  select count(*)
    into v_recent_rows
    from public.pins
   where author_id = new.author_id
     and source = 'crowd'
     and report_group_id is null
     and (
       (v_key = 'ephemeral_report' and lifespan = 'ephemeral')
       or (v_key = 'durable_crowd_report' and lifespan != 'ephemeral')
     )
     and created_at > now() - (v_window_hours || ' hours')::interval;

  if v_recent_rows >= v_max_count then
    raise exception 'rate limit exceeded: max % % report(s) per % hour(s)', v_max_count, v_key, v_window_hours
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end; $$;

drop trigger if exists pins_enforce_ephemeral_report_rate_limit on public.pins;
drop trigger if exists pins_enforce_crowd_report_rate_limit on public.pins;
create trigger pins_enforce_crowd_report_rate_limit
  before insert on public.pins
  for each row execute function public.enforce_crowd_report_rate_limit();

-- ============================================================
-- §2.9 Device push tokens — schema + sender seam only (Phase 4 builds the pipeline)
-- ============================================================
create table if not exists public.device_push_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  apns_token   text not null,
  environment  text not null check (environment in ('sandbox', 'production')),
  zone_id      text references public.zones(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (user_id, apns_token)
);

comment on table public.device_push_tokens is
  'APNs token registry. Stores ONLY (apns_token, zone_id) as location signal — never lat/lng, never '
  'segment_id. The relevance gate (does this pin matter to this specific parked car) runs entirely '
  'on-device, comparing a silent push payload''s segment_id against the device''s own on-device '
  'ParkedCar.segmentId — the server never learns which blockface any device cares about, only which '
  'zone. See spec §2.9''s privacy-preserving design note.';

-- Supports the Phase 4 sender function's "every token in this zone" query.
create index if not exists device_push_tokens_zone_id_idx
  on public.device_push_tokens(zone_id)
  where zone_id is not null;

alter table public.device_push_tokens enable row level security;
-- Deliberately NO select policy at all — device tokens are never read by any client role, only by
-- the sender Edge Function via the service-role key (bypasses RLS). Same deny-by-default posture as
-- rate_limit_config.
--
-- QA pass 1 fix (Finding #3, docs/qa/pr93-community-phase0-schema.md): the original version of this
-- section created these three policies with no `drop policy if exists` guard, unlike every other
-- policy in this file and every prior migration (01-mvp-schema.sql / 02-pins-schema.sql /
-- 02f-block-scoped-restrictions.sql all consistently drop-then-create). Postgres has no
-- `CREATE POLICY IF NOT EXISTS`, so a second paste of STEP 2 — or a partial re-run after an
-- unrelated mid-file failure, a realistic scenario for a hand-run production migration — aborted
-- with "policy already exists", contradicting this file's own "safe to re-run" claim. Fixed below.
drop policy if exists device_push_tokens_insert_own on public.device_push_tokens;
create policy device_push_tokens_insert_own on public.device_push_tokens
  for insert with check (auth.uid() = user_id);
drop policy if exists device_push_tokens_update_own on public.device_push_tokens;
create policy device_push_tokens_update_own on public.device_push_tokens
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists device_push_tokens_delete_own on public.device_push_tokens;
create policy device_push_tokens_delete_own on public.device_push_tokens
  for delete using (auth.uid() = user_id);

-- ============================================================
-- §2.10 `claim_pin` RPC
-- ============================================================
create or replace function public.claim_pin(p_pin_id uuid)
returns boolean language plpgsql security definer as $$
declare
  v_updated int;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  update public.pins set claimed_by = auth.uid(), updated_at = now()
  where id = p_pin_id and pin_type = 'leaving_soon' and claimed_by is null;
  get diagnostics v_updated = row_count;
  return v_updated > 0;  -- false = someone already claimed it; client shows "someone beat you to it"
end; $$;

grant execute on function public.claim_pin(uuid) to authenticated;
-- Not granted to anon: auth.uid() is null for anon anyway (function raises), but an explicit
-- EXECUTE grant limited to authenticated matches the "authenticated users only" intent stated in
-- the function body rather than relying solely on the runtime check.

-- ============================================================
-- §2.11 Server-derived `expires_at` — closes a pre-existing gap while touching this code
-- ============================================================
create or replace function public.derive_pin_expiry()
returns trigger language plpgsql security definer as $$
begin
  if new.pin_type = 'leaving_soon' then
    new.expires_at := now() + ((coalesce(new.leaving_minutes, 10) + 3) || ' minutes')::interval;
  elsif new.pin_type = 'open_spot' then
    new.expires_at := now() + interval '3 minutes';
  end if;
  -- enforcement_active / sweeper_passed / broken_meter keep their existing client-supplied value
  -- for now (ephemeralTTLSeconds(for:) — OQ-2 was resolved 2026-08-26 in favor of the prototype's
  -- 45m/120m values, applied client-side in Phase 1, not here); revisit once Phase 1 ships so both
  -- families get the same server-side-authoritative treatment in one pass.
  return new;
end; $$;

drop trigger if exists pins_derive_expiry on public.pins;
create trigger pins_derive_expiry
  before insert on public.pins
  for each row execute function public.derive_pin_expiry();

-- ============================================================
-- pins_with_author — append the three new columns
-- ============================================================
-- Same "p.* is frozen at CREATE VIEW time" bug class 02f section 5 already fixed once for this
-- exact view (starts_at/report_group_id) — required again here or position_fraction/
-- leaving_minutes/claimed_by would never reach any client (iOS reads exclusively via
-- pins_with_author — confirmed via grep of ios/WePark/WePark/Services/CommunityPinService.swift —
-- so missing this would silently break every Phase 1+ read of these three columns with no error
-- anywhere). Column list below is 02f section 5's exact list, in the exact same order, with the
-- three new columns appended at the end — appending to an explicit SELECT list is always a safe
-- CREATE OR REPLACE (never renames/reorders existing output columns, never drops the view's grants).
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
    p.report_group_id,
    p.position_fraction,
    p.leaving_minutes,
    p.claimed_by
  from public.pins p
  left join public.profiles pr on pr.id = p.author_id;

grant select on public.pins_with_author to anon, authenticated;

-- ============================================================
-- §2.12 TTL expiry mechanism — light hygiene sweep, not a full scheduled function
-- ============================================================
-- QA pass 1 fix (Finding #4, docs/qa/pr93-community-phase0-schema.md): this section originally
-- preceded the pins_with_author view-recreation section above. STEP 2 is one implicit transaction in
-- the SQL Editor — if `create extension if not exists pg_cron;`/`cron.schedule(...)` ever failed on a
-- given project (current risk is low; pg_cron/pg_net are already enabled and in production use,
-- 02d-ingest-cron.sql:17-18), the whole paste would roll back, including the view recreation that is
-- the ONLY thing that makes position_fraction/leaving_minutes/claimed_by reach any client at all.
-- This is the exact "don't gate required functionality behind a risky/optional section" lesson 02f
-- already applied to itself (moving required sections before its own risky Storage section, 02f
-- Round 2 note #3) — this section is now sequenced last for the same reason: pure data hygiene, not
-- required for any column to reach a client, so it is the safest thing in this file to have roll
-- back on its own if it ever fails.
create extension if not exists pg_cron;

-- 1-hour grace window past expires_at, not immediate — avoids any race with a client mid-read.
-- Pure data hygiene: clientSideFilter already hides these pins the instant expires_at passes, well
-- before this sweep ever runs; this only bounds query-result-set growth and keeps
-- pins_active_spatial_idx effective over time. cron.schedule with a fixed job name is idempotent
-- (re-running updates the existing job's schedule/command rather than creating a duplicate), same
-- pattern as 02d-ingest-cron.sql's 'ingest-film-permits' job.
select cron.schedule(
  'community-pin-expiry-hygiene-sweep',
  '*/15 * * * *',
  $$ update public.pins set resolved_at = now() where expires_at < now() - interval '1 hour' and resolved_at is null $$
);

-- Verify the job was registered:
-- select * from cron.job where jobname = 'community-pin-expiry-hygiene-sweep';

-- ============================================================
-- §2.13 Test script
-- ============================================================
-- See supabase/03-community-2.0-test.sh (companion file to this migration). Never applied by an
-- agent — this is Kevin's dashboard task, same as every prior migration. Run the test script AFTER
-- applying this file (both STEP 1 and STEP 2 above).
