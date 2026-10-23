-- WePark — in-app account deletion (open item #38; Apple App Store guideline 5.1.1(v))
-- Proposed by @backend-data 2026-10-23. NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor — single paste, no multi-step restriction (no enum
-- values, no extensions). Companion test: supabase/10-account-deletion-test.sh (scratch Postgres 16).
-- Idempotent: safe to re-run (create or replace function + explicit revoke/grant; no table DDL).
-- Depends on: 01-mvp-schema.sql (profiles, zone_messages), 02-pins-schema.sql (pins, votes),
-- 02f-block-scoped-restrictions.sql (pin_evidence, block_scoped_report_log), 03-community-2.0-schema.sql
-- (pins.claimed_by, reputation_award_log, device_push_tokens). It deliberately does NOT reference any
-- table that exists only in the DRAFT, UNAPPLIED Regulars migrations (07/08/09) — see "REGULARS" below.
--
-- ============================================================================================
-- THE iOS CONTRACT (build the Settings > "Delete account" row against exactly this)
-- ============================================================================================
--   RPC name:     delete_my_account          (schema public; PostgREST path POST /rest/v1/rpc/delete_my_account)
--   Arguments:    NONE. There is no user-id parameter by design: the function deletes
--                 auth.uid() — the caller's own account, taken from the verified JWT — and nothing
--                 else. One user can never name another user's account.
--   Returns:      void  (PostgREST answers 204 No Content / empty body on success).
--   Callable by:  role `authenticated` ONLY (this includes anonymous-auth sessions, which are
--                 `authenticated` + is_anonymous). The anon key with no user JWT is rejected twice
--                 over: no EXECUTE privilege (HTTP 401/403, SQLSTATE 42501) and an explicit
--                 auth.uid() IS NULL guard (SQLSTATE 42501, "authentication required").
--   Errors:       42501 = not signed in. Any other error = the deletion rolled back atomically
--                 (single transaction): NOTHING was deleted, show a retry affordance.
--   Idempotent:   calling it again for an already-deleted account (a still-valid access token
--                 can outlive the deletion by up to its 1h expiry) is a safe no-op that returns
--                 normally. It can never resurrect anything: every table that references the
--                 user has a foreign key to auth.users, which no longer has the row.
--
--   Swift (supabase-swift):   try await client.rpc("delete_my_account").execute()
--
--   What the client MUST do after the call returns successfully (the server cannot do these):
--     1. Sign out locally:  try? await client.auth.signOut()   — the server already destroyed the
--        sessions/refresh tokens, so signOut may itself return a 401/403; ignore that error, the
--        goal is only to clear the locally cached session. (Use scope: .local if available.)
--     2. Clear all local per-user state: cached profile/username/avatar, any cached vote/report
--        history, pending uploads/outbox, push-registration bookkeeping (and unregister for remote
--        notifications), the Keychain session entry. Do NOT delete the on-device parked-car pin or
--        reminders — those are device-local, not account data; the user may keep using the app
--        signed-out / re-bootstrap a fresh anonymous session.
--     3. Return to the signed-out/first-run UI. The app may mint a NEW anonymous or magic-link
--        identity afterwards; that is a different, empty account (new auth.users id), NOT the old
--        one — the old identity cannot be signed back into.
--   Required UX before calling (Apple review expects it): a confirmation step that states the
--   consequences — "Your profile, votes and device registrations are deleted. Your past reports and
--   chat messages stay on the map but are no longer linked to you." Failure must be surfaced, not
--   swallowed. No server-side "undo"/grace period exists: deletion is immediate and irreversible.
--
--   Chat/board display for de-attributed content: a deleted user's zone_messages and pins keep a
--   NULL author_id, so zone_messages_with_author / pins_with_author return author_username = NULL
--   and author_reputation = NULL for them. The client must render a neutral label (e.g. "Former
--   neighbor") whenever message_type = 'user' AND author_id IS NULL — do not crash or hide the row.
--
-- ============================================================================================
-- DESIGN DECISION: ANONYMIZE user content, DELETE personal data (orchestrator ruling; veto-able)
-- ============================================================================================
-- Why NO sentinel "deleted user" profile row was needed. Inspected the APPLIED schema's actual FKs
-- (01–06) rather than assuming:
--   pins.author_id           uuid NULLABLE, references auth.users ON DELETE SET NULL   (02)
--   zone_messages.author_id  uuid NULLABLE, references auth.users ON DELETE SET NULL   (01)
--   pin_evidence.uploaded_by uuid NULLABLE, references auth.users ON DELETE SET NULL   (02f)
-- The schema was already designed so that "author gone" == NULL author (the same representation
-- open-data seeded pins use: "Authorship (null = seeded by open-data pipeline)"). The two
-- author-bearing content tables therefore need NO schema change and NO sentinel: NULL IS the
-- de-attributed state, every read path (pins_with_author / zone_messages_with_author are LEFT JOINs)
-- already tolerates it, RLS policies keyed on author_id simply stop matching anyone (a retained pin
-- can no longer be edited/deleted by anybody — correct for orphaned content), and the rate-limit /
-- reputation triggers all already guard `author_id is not null`. A sentinel row would have been
-- strictly worse: it would have to be an auth.users row (FK target), would make "everything ever
-- deleted" one giant fake account with a public reputation counter, and would collide with the
-- unique(pin_id,user_id) vote constraint. Relaxing columns to nullable was likewise unnecessary —
-- they already are.
-- Content kept (de-attributed):  pins.author_id -> NULL, zone_messages.author_id -> NULL. Body text,
--   notes, geometry, timestamps stay; the neighborhood boards depend on them. The function does the
--   NULLing EXPLICITLY (not only via the FK) so the behavior is a stated contract, not an accident of
--   FK semantics a later migration could change.
-- Personal data deleted:  profiles row (username, avatar, reputation, counters), device_push_tokens
--   (APNs tokens), votes (see "VOTES" below), reputation_award_log, block_scoped_report_log
--   (author_id + report_group_id, no FK, would otherwise outlive the account), pin_evidence rows
--   (photo pointers), any parked_car pins (device-private by definition, never meant to survive).
-- Finally auth.users is deleted, which (GoTrue's own cascades) removes identities, sessions, refresh
--   tokens and the email — the identity cannot sign in again.
--
-- A BLOCKER this file fixes that a bare `delete from auth.users` would have hit:
--   pins.claimed_by (03) is `references auth.users(id)` with NO ON DELETE action (= NO ACTION). Any
--   user who ever tapped "I'm heading there" on someone's leaving_soon pin would make the final
--   auth.users delete FAIL with a foreign-key violation. The function clears claimed_by first
--   (a stale "someone is heading here" marker for a departed user is meaningless anyway).
--
-- VOTES. votes.user_id is NOT NULL with unique(pin_id,user_id) and cascades from auth.users, and a
--   vote is the user's own act on a pin, not board content. They are deleted, and the existing
--   votes_refresh_pin_counts trigger recomputes confirm_count/dispute_count on the affected pins.
--   Consequence to be aware of: a retained pin may drop a confirm. That is accepted — a sentinel
--   voter cannot work (unique(pin_id,user_id) would collide when two deleted users voted the same
--   pin) and keeping votes attributed would defeat the deletion.
--
-- NOT HANDLED HERE — needs a Kevin decision, flagged in the PR:
--   (a) Storage blobs. pin_evidence rows are deleted here, but the PHOTO FILES live in the private
--       `pin-evidence` Storage bucket under `{uid}/…`. Deleting storage.objects rows via SQL does NOT
--       delete the underlying file in Supabase Storage (it only drops metadata), and storage.objects
--       is owned by supabase_storage_admin, so this migration deliberately does not touch it. If
--       evidence upload is live to real users, the blobs need removing via the Storage API (service
--       role: list prefix `{uid}/`, remove) — either by the client before calling this RPC (needs a
--       storage DELETE-own policy, not in this file) or by a small Edge Function. Until then the
--       files are orphaned but unreachable by any client (read policy is keyed on the now-nonexistent
--       auth.uid()).
--   (b) Message bodies / pin notes are user-authored free text and are retained verbatim by design.
--       If a user wrote their own name in one, it stays; a "delete my messages too" option would be a
--       different (destructive) ruling.
--
-- REGULARS (07/08/09 are DRAFT and UNAPPLIED — nothing here references them). Verified in 07's DDL:
--   every user column there (regular_edges.low/high_user_id, regular_blocks.user_id/blocked_user_id,
--   regular_invites.created_by, pin_notes.author_id, regular_notices.sender_id) is
--   `references auth.users(id) ON DELETE CASCADE`, and regular_invites.redeemed_by is ON DELETE SET
--   NULL. So if/when 07 is applied, this function's final `delete from auth.users` already removes a
--   deleting user's edges/blocks/invites/notes/notices with no change to this file. No guarded
--   to_regclass() cleanup is needed. Re-check this claim if 07's FKs change before it ships.
--
-- COVERAGE REQUESTS (11): coverage_requests.user_id is ON DELETE SET NULL, so a deleted user's
--   "suggest a neighborhood" rows are de-attributed automatically once 11 is applied; this file
--   needs no reference to it (and works whether or not 11 exists).
--
-- ============================================================================================
-- SECURITY DEFINER hygiene (PR #114 QA Finding #1 — Postgres grants EXECUTE to PUBLIC by default,
-- and Supabase additionally grants it to anon/authenticated/service_role via default privileges, so
-- an additive GRANT alone leaves the hole open):
--   * SET search_path = '' and every reference is fully schema-qualified (no search-path hijack).
--   * REVOKE ALL ... FROM PUBLIC, anon, authenticated  THEN  GRANT EXECUTE ... TO authenticated.
--   * Identity comes ONLY from auth.uid(); the function takes no arguments.
-- ============================================================================================

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  -- 1. Device-private parked-car pins: personal by definition, never board content. Delete, don't
  --    anonymize (their select policy hides them from everyone but the author, so de-attributing
  --    them would leave invisible junk forever).
  delete from public.pins
   where author_id = v_uid
     and pin_type = 'parked_car';

  -- 2. Release any "I'm heading there" claim (FK without ON DELETE action — would block step 9).
  update public.pins
     set claimed_by = null
   where claimed_by = v_uid;

  -- 3. ANONYMIZE: de-attribute (keep) the user's pins and chat messages.
  update public.pins
     set author_id = null
   where author_id = v_uid;

  update public.zone_messages
     set author_id = null
   where author_id = v_uid;

  -- 4. DELETE personal rows. Most would also cascade from auth.users; explicit so the contract does
  --    not depend on FK actions, and so the vote-count trigger has run before the identity is gone.
  delete from public.votes                 where user_id     = v_uid;
  delete from public.device_push_tokens    where user_id     = v_uid;
  delete from public.reputation_award_log  where subject_id  = v_uid;
  delete from public.pin_evidence          where uploaded_by = v_uid;
  -- No FK to auth.users by design (02f) — would otherwise outlive the account forever.
  delete from public.block_scoped_report_log where author_id = v_uid;

  -- 5. Profile (username, avatar, reputation, counters).
  delete from public.profiles where id = v_uid;

  -- 6. The identity itself. GoTrue's own FKs cascade identities/sessions/refresh_tokens/mfa, so the
  --    user cannot sign in again with this id/email. Any remaining ON DELETE SET NULL / CASCADE
  --    references (future tables) are handled by their FKs.
  delete from auth.users where id = v_uid;
end;
$$;

comment on function public.delete_my_account() is
  'In-app account deletion (Apple 5.1.1(v)). Deletes the CALLER''s own account (auth.uid(); no argument). '
  'Anonymizes (keeps, author -> NULL) pins and zone_messages; deletes profile, votes, device_push_tokens, '
  'reputation/rate-limit ledgers, pin_evidence rows, parked_car pins; then deletes the auth.users row. '
  'Idempotent. Authenticated only. See supabase/10-account-deletion.sql header for the iOS contract.';

revoke all on function public.delete_my_account() from public;
revoke all on function public.delete_my_account() from anon;
revoke all on function public.delete_my_account() from authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- Verify after applying (Kevin, SQL Editor) — expect has_exec: anon=f, authenticated=t, plus
-- prosecdef=t and proconfig containing search_path="":
--   select has_function_privilege('anon',          'public.delete_my_account()', 'execute') as anon_exec,
--          has_function_privilege('authenticated', 'public.delete_my_account()', 'execute') as authed_exec,
--          p.prosecdef, p.proconfig
--     from pg_proc p where p.oid = 'public.delete_my_account()'::regprocedure;
