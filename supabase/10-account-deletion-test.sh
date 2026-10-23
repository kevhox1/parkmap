#!/usr/bin/env bash
# WePark — supabase/10-account-deletion.sql scratch-Postgres test (open item #38).
#
# Runs against a THROWAWAY local Postgres 16 (NOT Supabase, NOT production — an agent can never apply
# schema to prod; Kevin does that by hand, see docs/supabase-ceremony-10-11.md). Builds a fresh database,
# applies the real migrations 01-06 verbatim on a Supabase-shaped stub (supabase/scratch/), applies 10
# TWICE, then drives it as the real `anon` / `authenticated` roles with a JWT-sub GUC like PostgREST.
#
# Usage (libpq env selects the scratch server; the role must be a superuser):
#   PGHOST=/path/to/socketdir PGPORT=55432 PGUSER=postgres ./supabase/10-account-deletion-test.sh
# Requires: psql (16), bash.   Exit code 0 = all passed.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch/common.sh"

scratch_create_db t10
echo "== scratch DB $DB: migrations 01-06 applied; $(sql "$DB" 'show server_version')"

echo "== Test 0: clean apply + idempotent re-apply"
check "first apply of 10-account-deletion.sql" "$(apply_file 10-account-deletion.sql)" "ok"
check "second apply (idempotent)"              "$(apply_file 10-account-deletion.sql)" "ok"

echo "== Test 1: function privilege + hygiene (PR #114 Finding #1 regression guard)"
check "anon has EXECUTE"           "$(sql "$DB" "select has_function_privilege('anon','public.delete_my_account()','execute')")" "f"
check "authenticated has EXECUTE"  "$(sql "$DB" "select has_function_privilege('authenticated','public.delete_my_account()','execute')")" "t"
check "no PUBLIC (grantee 0) EXECUTE entry" "$(sql "$DB" "select count(*) from pg_proc p, aclexplode(p.proacl) a where p.oid='public.delete_my_account()'::regprocedure and a.grantee=0")" "0"
check "SECURITY DEFINER"           "$(sql "$DB" "select prosecdef from pg_proc where oid='public.delete_my_account()'::regprocedure")" "t"
check "search_path pinned empty"   "$(sql "$DB" "select proconfig::text from pg_proc where oid='public.delete_my_account()'::regprocedure")" '{"search_path=\"\""}'
check "takes no arguments"         "$(sql "$DB" "select pronargs from pg_proc where oid='public.delete_my_account()'::regprocedure")" "0"

# ---------------------------------------------------------------- fixtures
A=$(new_user false); B=$(new_user false); C=$(new_user true); D=$(new_user false)
A_EMAIL=$(sql "$DB" "select email from auth.users where id='$A'")
echo "== fixtures: A=$A (email) B=$B (email) C=$C (anonymous session) D=$D (atomicity victim)"
sql "$DB" "
insert into auth.identities(user_id) values ('$A'),('$B'),('$C');
insert into auth.sessions(user_id) values ('$A'),('$B'),('$C');
insert into auth.refresh_tokens(user_id) values ('$A'),('$B'),('$C');

-- A's content (the profile rows are created by the real reputation triggers on these inserts)
insert into public.pins (id, pin_type, source, lifespan, lat, lng, zone_id, author_id, expires_at, notes) values
  ('aaaaaaaa-0000-0000-0000-000000000001','enforcement_active','crowd','ephemeral',40.72,-74.0,'soho-les','$A', now()+interval '40 minutes','A ephemeral'),
  ('aaaaaaaa-0000-0000-0000-000000000002','block_note','crowd','durable',40.72,-74.0,'soho-les','$A', null,'A durable note'),
  ('aaaaaaaa-0000-0000-0000-000000000003','leaving_soon','crowd','ephemeral',40.72,-74.0,'soho-les','$A', now()+interval '10 minutes','A leaving soon');
insert into public.pins (id, pin_type, source, lifespan, lat, lng, zone_id, author_id, expires_at, report_group_id) values
  ('aaaaaaaa-0000-0000-0000-000000000004','filming','crowd','session',40.72,-74.0,'soho-les','$A', now()+interval '1 day', 'cccccccc-0000-0000-0000-000000000001');
-- device-private parked_car pin (personal; must be DELETED, not anonymized)
insert into public.pins (id, pin_type, source, lifespan, lat, lng, author_id) values
  ('aaaaaaaa-0000-0000-0000-000000000005','parked_car','crowd','session',40.72,-74.0,'$A');
insert into public.zone_messages (zone_id, author_id, message_type, body) values
  ('soho-les','$A','user','hello from A'), ('soho-les','$A','user','second message from A');
insert into public.device_push_tokens (user_id, apns_token, environment, zone_id) values ('$A','tokA','sandbox','soho-les');
insert into public.pin_evidence (report_group_id, storage_path, uploaded_by) values
  ('cccccccc-0000-0000-0000-000000000001','$A/cccccccc-0000-0000-0000-000000000001/p.jpg','$A');

-- B's content
insert into public.pins (id, pin_type, source, lifespan, lat, lng, zone_id, author_id, expires_at, notes) values
  ('bbbbbbbb-0000-0000-0000-000000000001','broken_meter','crowd','ephemeral',40.72,-74.0,'soho-les','$B', now()+interval '40 minutes','B pin'),
  ('bbbbbbbb-0000-0000-0000-000000000002','leaving_soon','crowd','ephemeral',40.72,-74.0,'soho-les','$B', now()+interval '10 minutes','B leaving soon');
insert into public.zone_messages (zone_id, author_id, message_type, body) values ('soho-les','$B','user','hello from B');
insert into public.device_push_tokens (user_id, apns_token, environment, zone_id) values ('$B','tokB','production','soho-les');

-- C (anonymous-auth session) content
insert into public.zone_messages (zone_id, author_id, message_type, body) values ('soho-les','$C','user','hello from C');
insert into public.device_push_tokens (user_id, apns_token, environment, zone_id) values ('$C','tokC','sandbox','soho-les');

-- Votes: A confirms B's pin; B confirms A's pin  (confirm_count maintained by the real trigger)
insert into public.votes (pin_id, user_id, vote) values
  ('bbbbbbbb-0000-0000-0000-000000000001','$A','confirm'),
  ('aaaaaaaa-0000-0000-0000-000000000001','$B','confirm');
-- claimed_by: A is 'heading to' B's leaving_soon pin  (pins.claimed_by has NO ON DELETE action)
update public.pins set claimed_by='$A' where id='bbbbbbbb-0000-0000-0000-000000000002';
-- and B claimed A's leaving_soon pin
update public.pins set claimed_by='$B' where id='aaaaaaaa-0000-0000-0000-000000000003';
" >/dev/null || { echo "FATAL: fixture insert failed"; exit 1; }

cnt() { sql "$DB" "select count(*) from $1"; }
echo "== fixture sanity (real triggers populated profiles / ledgers)"
check "A has a profile (trigger-created)"            "$(cnt "public.profiles where id='$A'")" "1"
check "A has reputation_award_log rows"              "$([ "$(cnt "public.reputation_award_log where subject_id='$A'")" -ge 1 ] && echo yes)" "yes"
check "A has block_scoped_report_log row"            "$(cnt "public.block_scoped_report_log where author_id='$A'")" "1"
check "B's pin confirm_count = 1 (A's vote)"          "$(sql "$DB" "select confirm_count from public.pins where id='bbbbbbbb-0000-0000-0000-000000000001'")" "1"

echo "== Test 2: who can call it"
out=$(sql_as "$DB" anon "" "select public.delete_my_account();")
check_err "anon (no JWT) cannot call" "$out" 42501
out=$(sql_as "$DB" anon "$A" "select public.delete_my_account();")
check_err "anon role even with a forged sub claim for A cannot call" "$out" 42501
out=$(sql_as "$DB" authenticated "" "select public.delete_my_account();")
check_err "authenticated role with no JWT subject is rejected by the auth.uid() guard" "$out" 42501
check "A's account untouched by the rejected calls" "$(cnt "auth.users where id='$A'")" "1"
out=$(sql_as "$DB" authenticated "$B" "select public.delete_my_account('$A'::uuid);")
check_err "no argument form exists: B cannot name A (function delete_my_account(uuid) does not exist)" "$out" 42883
check "A's account still intact after B's attempt" "$(cnt "auth.users where id='$A'")" "1"

# snapshot of everything NOT-A, to prove other users' data is untouched by A's and C's deletions
snap_other() {
  sql "$DB" "select
    (select count(*) from public.pins where author_id='$B')::text || '/' ||
    (select count(*) from public.zone_messages where author_id='$B')::text || '/' ||
    (select count(*) from public.device_push_tokens where user_id='$B')::text || '/' ||
    (select count(*) from public.profiles where id='$B')::text || '/' ||
    (select count(*) from public.votes where user_id='$B')::text || '/' ||
    (select count(*) from auth.users where id='$B')::text || '/' ||
    (select count(*) from auth.sessions where user_id='$B')::text"
}
B_BEFORE=$(snap_other)
echo "   B snapshot before: $B_BEFORE (pins/messages/tokens/profile/votes/user/sessions)"

echo "== Test 3: anonymous-auth user C deletes THEIR OWN account; nobody else is touched"
out=$(sql_as "$DB" authenticated "$C" "select public.delete_my_account();")
check_ok "C's call succeeds" "$out"
check "C auth.users row gone"        "$(cnt "auth.users where id='$C'")" "0"
check "C device_push_tokens gone"    "$(cnt "public.device_push_tokens where user_id='$C'")" "0"
check "C profile gone"               "$(cnt "public.profiles where id='$C'")" "0"
check "C message retained, de-attributed" "$(sql "$DB" "select count(*) from public.zone_messages where body='hello from C' and author_id is null")" "1"
check "B untouched by C's deletion"  "$(snap_other)" "$B_BEFORE"
check "A untouched by C's deletion"  "$(cnt "auth.users where id='$A'")" "1"

echo "== Test 4: A deletes their account — happy path"
A_PINS_KEPT_BEFORE=$(cnt "public.pins where author_id='$A' and pin_type <> 'parked_car'")
check "precondition: A authored 4 non-parked_car pins" "$A_PINS_KEPT_BEFORE" "4"
out=$(sql_as "$DB" authenticated "$A" "select public.delete_my_account();")
check_ok "A's call succeeds (claimed_by FK blocker handled, triggers did not obstruct)" "$out"

echo "   -- identity + personal data gone"
check "auth.users row gone"                   "$(cnt "auth.users where id='$A'")" "0"
check "auth.identities/sessions/refresh gone" "$(sql "$DB" "select (select count(*) from auth.identities where user_id='$A')+(select count(*) from auth.sessions where user_id='$A')+(select count(*) from auth.refresh_tokens where user_id='$A')")" "0"
check "no sign-in path: no auth.users row with A's email" "$(cnt "auth.users where email='$A_EMAIL'")" "0"
check "profiles row gone"                     "$(cnt "public.profiles where id='$A'")" "0"
check "device_push_tokens gone"               "$(cnt "public.device_push_tokens where user_id='$A'")" "0"
check "votes gone"                            "$(cnt "public.votes where user_id='$A'")" "0"
check "reputation_award_log gone"             "$(cnt "public.reputation_award_log where subject_id='$A'")" "0"
check "block_scoped_report_log gone"          "$(cnt "public.block_scoped_report_log where author_id='$A'")" "0"
check "pin_evidence rows gone"                "$(cnt "public.pin_evidence where uploaded_by='$A'")" "0"
check "parked_car pin DELETED (not anonymized)" "$(cnt "public.pins where id='aaaaaaaa-0000-0000-0000-000000000005'")" "0"

echo "   -- content retained, de-attributed"
check "A's 4 non-parked pins all still exist"   "$(cnt "public.pins where id::text like 'aaaaaaaa-0000-0000-0000-00000000000%' and pin_type <> 'parked_car'")" "4"
check "...and none still point at A"            "$(cnt "public.pins where author_id='$A'")" "0"
check "...author_id is NULL on all 4"           "$(cnt "public.pins where id::text like 'aaaaaaaa-0000-0000-0000-00000000000%' and pin_type <> 'parked_car' and author_id is null")" "4"
check "pin notes/body text preserved verbatim"  "$(sql "$DB" "select notes from public.pins where id='aaaaaaaa-0000-0000-0000-000000000002'")" "A durable note"
check "block-scoped (report_group_id) pin kept with group id intact" "$(sql "$DB" "select report_group_id from public.pins where id='aaaaaaaa-0000-0000-0000-000000000004'")" "cccccccc-0000-0000-0000-000000000001"
check "A's 2 chat messages retained, author NULL" "$(sql "$DB" "select count(*) from public.zone_messages where body in ('hello from A','second message from A') and author_id is null")" "2"
check "message_type stays 'user' (client renders 'Former neighbor')" "$(sql "$DB" "select count(distinct message_type) || ':' || min(message_type) from public.zone_messages where body in ('hello from A','second message from A')")" "1:user"

echo "   -- FK side effects handled"
check "claimed_by cleared on B's pin (was A)"   "$(sql "$DB" "select coalesce(claimed_by::text,'null') from public.pins where id='bbbbbbbb-0000-0000-0000-000000000002'")" "null"
check "B's claim on A's retained pin is untouched" "$(sql "$DB" "select claimed_by from public.pins where id='aaaaaaaa-0000-0000-0000-000000000003'")" "$B"
check "A's vote removed -> B's pin confirm_count recomputed 1 -> 0" "$(sql "$DB" "select confirm_count from public.pins where id='bbbbbbbb-0000-0000-0000-000000000001'")" "0"
check "B's vote on A's retained pin survives (count still 1)" "$(sql "$DB" "select confirm_count from public.pins where id='aaaaaaaa-0000-0000-0000-000000000001'")" "1"

echo "   -- read paths tolerate the de-attributed rows"
check "pins_with_author (authenticated) returns A's pin with NULL username" "$(sql_as "$DB" authenticated "$B" "select coalesce(author_username,'NULL') from public.pins_with_author where id='aaaaaaaa-0000-0000-0000-000000000002';")" "NULL"
check "zone_messages_with_author (anon) returns A's message with NULL username" "$(sql_as "$DB" anon "" "select coalesce(author_username,'NULL') from public.zone_messages_with_author where body='hello from A';")" "NULL"

echo "== Test 5: another user's data is untouched (B)"
check "B snapshot identical before/after A's and C's deletions" "$(snap_other)" "$B_BEFORE"
check "B still exists as a user"  "$(cnt "auth.users where id='$B'")" "1"

echo "== Test 6: calling twice is safe (A's stale-but-valid JWT)"
out=$(sql_as "$DB" authenticated "$A" "select public.delete_my_account();")
check_ok "second call for already-deleted A returns normally" "$out"
out=$(sql_as "$DB" authenticated "$A" "select public.delete_my_account();")
check_ok "third call too" "$out"
check "B snapshot still identical" "$(snap_other)" "$B_BEFORE"
check "retained A pins unchanged (still 4, still NULL author)" "$(cnt "public.pins where id::text like 'aaaaaaaa-0000-0000-0000-00000000000%' and pin_type <> 'parked_car' and author_id is null")" "4"

echo "== Test 7: a deleted account cannot be resurrected with its stale JWT"
out=$(sql_as "$DB" authenticated "$A" "insert into public.pins (pin_type, source, lifespan, lat, lng, author_id) values ('block_note','crowd','durable',40.7,-74.0,'$A');")
check_err "pin insert as deleted A -> FK violation" "$out" 23503
out=$(sql_as "$DB" authenticated "$A" "insert into public.profiles (id, username) values ('$A','ghost');")
check_err "profile insert as deleted A -> FK violation" "$out" 23503
out=$(sql_as "$DB" authenticated "$A" "insert into public.zone_messages (zone_id, author_id, message_type, body) values ('soho-les','$A','user','ghost');")
check_err "chat insert as deleted A -> FK violation" "$out" 23503

echo "== Test 8: failure is atomic (a future NO-ACTION FK blocks the final delete -> everything rolls back)"
sql "$DB" "
insert into public.profiles (id, username) values ('$D','dee') on conflict (id) do nothing;
insert into public.zone_messages (zone_id, author_id, message_type, body) values ('soho-les','$D','user','hello from D');
insert into public.device_push_tokens (user_id, apns_token, environment) values ('$D','tokD','sandbox');
create table public.zz_future_blocker (u uuid references auth.users(id));  -- NO ACTION, like pins.claimed_by was
insert into public.zz_future_blocker values ('$D');" >/dev/null
out=$(sql_as "$DB" authenticated "$D" "select public.delete_my_account();")
check_err "deletion fails with FK violation" "$out" 23503
check "D user row still exists"            "$(cnt "auth.users where id='$D'")" "1"
check "D profile NOT deleted (rolled back)" "$(cnt "public.profiles where id='$D'")" "1"
check "D push token NOT deleted"            "$(cnt "public.device_push_tokens where user_id='$D'")" "1"
check "D message still attributed to D"     "$(cnt "public.zone_messages where body='hello from D' and author_id='$D'")" "1"
sql "$DB" "drop table public.zz_future_blocker" >/dev/null
out=$(sql_as "$DB" authenticated "$D" "select public.delete_my_account();")
check_ok "after removing the blocker, D's retry succeeds" "$out"
check "D fully deleted"                      "$(cnt "auth.users where id='$D'")" "0"

finish
