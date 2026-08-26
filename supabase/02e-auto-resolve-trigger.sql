-- WePark — auto-resolve trigger for disputed ephemeral crowd pins
-- Spec: docs/tier3-auth-and-reactions-spec.md §3.7, OQ-2 (threshold A2: 3 disputes)
-- Proposed by @backend-data 2026-06-05. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor before the sub-PR #1 integration test.
-- Idempotent: CREATE OR REPLACE function + DROP TRIGGER IF EXISTS before CREATE.
-- Depends on: 02-pins-schema.sql (pins table, votes table,
--             refresh_pin_vote_counts trigger — all must be live first).

-- ============================================================
-- Design: separate trigger on pins, not folded into refresh_pin_vote_counts
-- ============================================================
-- Two clean alternatives exist:
--
--   (A) Trigger on `pins` AFTER UPDATE OF dispute_count — chosen here.
--   (B) Inline the check inside refresh_pin_vote_counts(), which already
--       runs UPDATE public.pins from a `votes`-table trigger.
--
-- Option A is chosen for three reasons:
--
--   1. No double-fire / recursion risk.
--      The new trigger fires ONLY when dispute_count changes.
--      Its body sets resolved_at and updated_at — NOT dispute_count — so the
--      trigger's own UPDATE does not satisfy the `OF dispute_count` column
--      filter and does NOT re-fire the trigger. Zero recursion.
--
--   2. Separation of concerns.
--      refresh_pin_vote_counts() has one job: recount votes and write them to
--      the pins row. Auto-resolve is a policy decision, not a count. Mixing
--      them couples two concerns and makes future policy changes (e.g. raising
--      the threshold, adding a source='crowd' guard, adding a grace period)
--      harder to reason about.
--
--   3. Matches the spec diagram (§3.6 data flow).
--      The spec describes an explicit two-trigger chain:
--        votes INSERT → refresh_pin_vote_counts → pins.dispute_count++ →
--        auto_resolve_on_dispute → pins.resolved_at = now()
--      Implementing it as specified keeps the audit trail unambiguous.
--
-- Option B (inline) was rejected because it would also be safe from recursion
-- (the votes trigger is on the votes table, not pins), but it conflates policy
-- with mechanics and makes the trigger chain less visible in pg_trigger catalog.

-- ============================================================
-- Function: auto_resolve_on_dispute
-- ============================================================
create or replace function public.auto_resolve_on_dispute()
returns trigger language plpgsql security definer as $$
begin
  -- Guard: only act when crossing the threshold and not already resolved.
  -- Threshold: dispute_count >= 3 (Kevin-approved OQ-2, option A2).
  --
  -- Scope: ONLY ephemeral crowd pins.
  --   lifespan = 'ephemeral'  — excludes durable corrections, block notes, open-data pins.
  --   source   = 'crowd'      — excludes any open_data or hybrid pins that happen to be
  --                             ephemeral (none exist today, but guard is belt-and-suspenders).
  --
  -- AC-DB2: 2 disputes → no action (new.dispute_count < 3 fails the check).
  -- AC-DB3: durable pin with 3 disputes → no action (lifespan check fails).
  if new.dispute_count >= 3
     and new.resolved_at is null
     and new.lifespan = 'ephemeral'
     and new.source = 'crowd'
  then
    update public.pins
    set
      resolved_at = now(),
      updated_at  = now()
    where id = new.id;
    -- NOTE: this UPDATE sets resolved_at and updated_at only — NOT dispute_count.
    -- The AFTER UPDATE OF dispute_count trigger fires only when dispute_count is
    -- in the updated column list. This UPDATE does not touch dispute_count, so
    -- the trigger does NOT re-fire. No recursion.
  end if;

  -- TODO: Tier 2 — when 3rd confirm is reached (confirm_count >= 3), increment
  -- author_id's profiles.reputation by 2 per community-1.0-buildplan.md §3.
  -- Not in this sub-PR; add a separate trigger or extend this function then.
  -- SUPERSEDED 2026-08-26: this TODO's threshold-based, author-only model was never built, and is
  -- superseded by a different, immediate/per-action model (report +5, confirm +2 to the confirmer,
  -- chat +1) — see docs/community-2.0-reconciliation-spec.md §2.6 and
  -- supabase/03-community-2.0-schema.sql (award_report_reputation / award_confirm_reputation /
  -- award_chat_reputation / award_accuracy_on_first_confirm). Left in place, not deleted, per this
  -- repo's "link to superseded work, don't delete" convention (spec §5).

  return null;  -- AFTER trigger; return value is ignored for row-level triggers.
end;
$$;

-- ============================================================
-- Trigger: pins_auto_resolve_on_dispute
-- ============================================================
-- Column-specific firing: AFTER UPDATE OF dispute_count
-- This means the trigger body only runs when dispute_count is explicitly
-- included in the SET clause of the UPDATE. The refresh_pin_vote_counts()
-- function always sets dispute_count (even if unchanged) so the trigger
-- fires on every vote change — correct behavior: re-evaluate threshold
-- after every vote mutation.
drop trigger if exists pins_auto_resolve_on_dispute on public.pins;
create trigger pins_auto_resolve_on_dispute
  after update of dispute_count on public.pins
  for each row execute function public.auto_resolve_on_dispute();
