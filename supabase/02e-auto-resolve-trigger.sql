-- supabase/02e-auto-resolve-trigger.sql
-- Tier 3 Sub-PR #1 — @backend-data deliverable.
-- Spec: docs/tier3-auth-and-reactions-spec.md §3.7 (sketch) + §7 (AC-DB1 through AC-DB4).
--
-- Auto-resolves an ephemeral crowd pin when dispute_count reaches the threshold.
-- Threshold: 3 disputes (A2 decision, approved by Kevin per OQ-2).
--
-- Trigger chain:
--   votes INSERT
--     → votes_refresh_pin_counts trigger (existing in 02-pins-schema.sql)
--     → UPDATE pins SET dispute_count = dispute_count + 1
--     → pins_auto_resolve_on_dispute trigger (NEW — this file)
--     → IF dispute_count >= 3 AND lifespan = 'ephemeral' AND resolved_at IS NULL:
--         UPDATE pins SET resolved_at = now(), updated_at = now()
--         → Realtime UPDATE event → all clients' mergeRealtimeChange removes pin from map.
--
-- Idempotent: CREATE OR REPLACE + DROP TRIGGER IF EXISTS (AC-DB4).
-- SECURITY DEFINER: consistent with existing votes_refresh_pin_counts trigger pattern.
--
-- TODO: Tier 2 — increment author reputation on 3rd confirm (Tier 2 spec TBD).
-- See docs/tier2-reputation-spec.md when available; profiles.reputation column exists.

-- Function: fires after pins.dispute_count is updated by votes_refresh_pin_counts.
create or replace function public.auto_resolve_on_dispute()
returns trigger
language plpgsql
security definer
as $$
begin
  -- Only act on ephemeral pins that are not already resolved.
  -- Durable-lifespan pins are NOT auto-resolved (AC-DB3).
  if new.dispute_count >= 3
     and new.resolved_at is null
     and new.lifespan = 'ephemeral'
  then
    update public.pins
    set
      resolved_at = now(),
      updated_at  = now()
    where id = new.id;
  end if;

  return null;
end;
$$;

-- Drop + recreate trigger for idempotency (AC-DB4).
drop trigger if exists pins_auto_resolve_on_dispute on public.pins;

create trigger pins_auto_resolve_on_dispute
  after update of dispute_count on public.pins
  for each row
  execute function public.auto_resolve_on_dispute();
