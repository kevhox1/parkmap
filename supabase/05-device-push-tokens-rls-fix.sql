-- WePark Community 2.0 — device_push_tokens RLS fix (build 20, S12 deploy ceremony incident)
--
-- INCIDENT: Kevin's S12 deploy ceremony ran supabase/04-community-push-test.sh against live prod.
-- Test 3 ("authenticated user can insert own device_push_tokens row") FAILED with HTTP 403:
--   {"code":"42501","message":"new row violates row-level security policy for table
--   \"device_push_tokens\""}
-- Tests 1/2/4 passed (anon insert rejected 401; cross-user insert rejected 403; the "nobody can read"
-- checks held both ways) — meaning table-level grants exist and the INSERT policy's WITH CHECK does
-- fire, but something makes even a legitimate, own-user insert fail.
--
-- ROOT CAUSE (reproduced live on local Postgres 16.15, both against a byte-for-byte extraction of
-- 03-community-2.0-schema.sql's §2.9 section AND against a minimal from-scratch isolation table with
-- zero foreign keys — same result both times, so this is NOT specific to device_push_tokens'
-- particular columns/FKs):
--
-- `device_push_tokens` was deliberately built with NO select policy at all ("device tokens are never
-- read by any client role, only by the sender Edge Function via the service-role key" — 03's own
-- comment, spec §2.9). That design goal is sound on its own, BUT it collides with a genuine, documented
-- PostgreSQL behavior that the original design didn't account for: when a client issues
-- `INSERT ... RETURNING ...` (which is exactly what PostgREST does under `Prefer: return=representation`
-- — the header both 04-community-push-test.sh's `rest()` helper AND the Supabase client SDKs send by
-- default on every insert/update/delete unless a caller explicitly opts into `return=minimal`),
-- PostgreSQL requires the newly-written row to ALSO satisfy the table's SELECT policy in order to
-- produce the RETURNING output. This is not a filter-and-omit step (unlike a plain `SELECT ... WHERE`) —
-- for INSERT/UPDATE/DELETE with RETURNING, Postgres treats "can this row be shown back to the caller"
-- as a CHECK-style requirement: if it fails, the *entire statement* raises
-- `new row violates row-level security policy for table "X"` and rolls back, even though the row was
-- otherwise fully permitted by the INSERT/UPDATE/DELETE policy's own WITH CHECK/USING clause.
-- With zero SELECT policy defined, that implicit check ALWAYS fails, for every role, including the
-- row's own owner. `device_push_tokens_insert_own`'s `with check (auth.uid() = user_id)` was never the
-- problem — it was correctly firing and correctly evaluating true. The missing SELECT policy is.
--
-- Verified empirically (not just reasoned): the identical INSERT, with the identical role/JWT-claims
-- context, SUCCEEDS when no RETURNING clause is present, and SUCCEEDS with RETURNING the moment a
-- `for select using (auth.uid() = user_id)` policy is added — both on a direct extraction of this
-- table's real DDL and on a minimal reproduction table with no foreign keys, ruling out the FK to
-- `auth.users`/`public.zones` as a contributing factor. This also explains, consistently, why Tests 1/2/4
-- of 04-community-push-test.sh passed under the same defect: Test 1 (anon, no bearer at all) and Test 2
-- (cross-user insert) both expect REJECTION, and a row that fails RLS for "wrong user" fails identically
-- whether or not this RETURNING gap exists — those tests could not have distinguished this bug from
-- correctly-working RLS, only Test 3 (which expects SUCCESS on a legitimate own-row insert) could, and
-- did. Test 4 already independently confirmed the SELECT-side deny-all posture held for anon and (via a
-- plain, non-RETURNING-triggering GET) for the owner too — consistent with "the INSERT policy fires
-- correctly, only the RETURNING-visibility gate is the problem."
--
-- This also explains why every OTHER `auth.uid() = <col>` insert policy in this codebase (pins,
-- zone_messages, profiles, votes) has never hit this: every one of those tables already has a SELECT
-- policy the newly-written row satisfies (`pins_select_public`, `zone_messages_select_all using (true)`,
-- `profiles_select_all using (true)`, etc.) — `device_push_tokens` is the first (and, per the audit
-- below, only) table in this codebase designed with a deliberate zero-SELECT-policy posture that is
-- ALSO reachable by a client-side (non-service-role) INSERT/UPDATE/DELETE.
--
-- FIX: add a `for select using (auth.uid() = user_id)` policy — the row's owner can read back their own
-- token row (satisfying the RETURNING-visibility requirement for INSERT/UPDATE/DELETE alike, since all
-- three reuse the same SELECT policy for this check), while every other user/role still sees zero rows,
-- proven below. This is a genuine, minimal, deliberate SEMANTIC CHANGE from the original "no client can
-- ever read a device_push_tokens row, not even its own owner" design intent (spec §2.9) — that exact
-- posture turns out to be structurally incompatible with PostgREST's default INSERT/UPDATE/DELETE
-- behavior (every mainstream Supabase client SDK, including the iOS one S12 will use, defaults to
-- `return=representation`), not merely a stricter-than-necessary choice. The data newly exposed is a
-- device's own apns_token/environment/zone_id — its own token, which the device already possesses and
-- generated, and its own zone_id, which the spec's own privacy note already treats as coarse and
-- non-sensitive ("the same zone concept every user already sees in the UI"). No cross-user, no
-- location, no segment_id exposure results from this change.
--
-- AUDIT (per this incident's own working agreement — hand-checked every `create policy` statement in
-- 03-community-2.0-schema.sql for the same pattern, not just the one that broke): 03 creates RLS
-- policies for exactly one other table, `reputation_award_log` — which has ZERO policies of any kind
-- (deliberate deny-all; only SECURITY DEFINER trigger functions write to it, and those execute as an
-- RLS-bypassing owner role, never going through a client-facing INSERT/UPDATE/DELETE path at all, so
-- the RETURNING-visibility gate this incident is about can never be reached for that table). No other
-- instance of this pattern exists in 03. `device_push_tokens` is the only table affected, and its
-- INSERT/UPDATE/DELETE "own row" policies are all fixed by the one SELECT policy below (all three reuse
-- the same SELECT-policy check for their RETURNING-visibility gate, so this migration proactively closes
-- the identical latent failure on UPDATE/DELETE too — Kevin's ceremony only exercised INSERT via Test 3,
-- but `device_push_tokens_update_own`/`device_push_tokens_delete_own` had the exact same structural gap
-- and would have failed identically the first time any client called them with RETURNING).
--
-- Proposed by @backend-data 2026-09-02. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor — single paste, no multi-step restriction (no new enum
-- values, no cross-transaction dependency). Re-run supabase/04-community-push-test.sh (updated in the
-- same commit as this file — see Test 4's rewritten assertions) after applying.
-- Idempotent: safe to re-run (drop-then-create policy, `comment on table` replace-in-full).
-- Depends on: 03-community-2.0-schema.sql (device_push_tokens table + its insert/update/delete
-- policies, applied and live in prod verbatim as of this incident).

drop policy if exists device_push_tokens_select_own on public.device_push_tokens;
create policy device_push_tokens_select_own on public.device_push_tokens
  for select using (auth.uid() = user_id);

-- `comment on table` replaces the entire existing comment, not appends (same "preserve original text,
-- append a new paragraph" convention 03 itself used for rate_limit_config.max_rows) — original text
-- reproduced verbatim below, with the amendment appended.
comment on table public.device_push_tokens is
  'APNs token registry. Stores ONLY (apns_token, zone_id) as location signal — never lat/lng, never '
  'segment_id. The relevance gate (does this pin matter to this specific parked car) runs entirely '
  'on-device, comparing a silent push payload''s segment_id against the device''s own on-device '
  'ParkedCar.segmentId — the server never learns which blockface any device cares about, only which '
  'zone. See spec §2.9''s privacy-preserving design note. '
  '— '
  'AMENDED (supabase/05-device-push-tokens-rls-fix.sql, S12 deploy ceremony incident): a device CAN '
  'now read back its OWN token row (device_push_tokens_select_own, auth.uid() = user_id) — the '
  'original "no client role can ever read any row, including its own owner" posture was structurally '
  'incompatible with PostgREST''s default INSERT/UPDATE/DELETE ... RETURNING behavior (Postgres '
  'requires the written row to satisfy a SELECT policy to produce RETURNING output; with none defined '
  'that requirement can never be met, and the whole write is rejected with a row-level-security error '
  'even though the write itself was fully permitted). Cross-user visibility remains fully denied — '
  'this is strictly narrower than every other "own row" table in this codebase, not a broadening of '
  'exposure beyond a device''s own already-known token/environment/zone_id.';

-- Verify after applying (Kevin, SQL Editor):
--   select polname, polcmd, pg_get_expr(polwithcheck, polrelid) as with_check,
--          pg_get_expr(polqual, polrelid) as using_expr
--   from pg_policy where polrelid = 'public.device_push_tokens'::regclass order by polname;
-- Should list FOUR policies now (delete_own, insert_own, select_own, update_own), select_own's
-- using_expr = (auth.uid() = user_id). Then re-run supabase/04-community-push-test.sh — Test 3 should
-- now pass (HTTP 201), and Test 4 (rewritten in this same commit) should confirm the owner sees exactly
-- their own row while a different authenticated user and an anonymous caller both still see zero.
