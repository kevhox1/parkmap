#!/usr/bin/env bash
# WePark — supabase/11-coverage-requests.sql scratch-Postgres test (open item #39).
#
# Runs against a THROWAWAY local Postgres 16 (NOT Supabase, NOT production — Kevin applies migrations by
# hand, see docs/supabase-ceremony-10-11.md). Fresh database, real migrations 01-06 verbatim on a
# Supabase-shaped stub (supabase/scratch/), 11 applied TWICE, then driven as the real `anon` /
# `authenticated` roles with a JWT-sub GUC like PostgREST. Also applies 10 (account deletion) at the end
# to prove coverage_requests de-attribution works across the two migrations.
#
# Usage:  PGHOST=/path/to/socketdir PGPORT=55432 PGUSER=postgres ./supabase/11-coverage-requests-test.sh
# Requires: psql (16), bash.   Exit code 0 = all passed.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch/common.sh"

scratch_create_db t11
echo "== scratch DB $DB: migrations 01-06 applied; $(sql "$DB" 'show server_version')"

echo "== Test 0: clean apply + idempotent re-apply"
check "first apply of 11-coverage-requests.sql" "$(apply_file 11-coverage-requests.sql)" "ok"
check "second apply (idempotent)"               "$(apply_file 11-coverage-requests.sql)" "ok"
check "exactly 1 policy, INSERT-only (polcmd 'a')" "$(sql "$DB" "select count(*)||':'||min(polcmd::text) from pg_policy where polrelid='public.coverage_requests'::regclass")" "1:a"
check "rate_limit_config rows seeded (no duplicates after 2 applies)" "$(sql "$DB" "select count(*) from public.rate_limit_config where key in ('coverage_request','coverage_request_global')")" "2"

echo "== Test 1: privilege surface"
check "authenticated column INSERT grants == city,note,viewed_lat,viewed_lng only" \
  "$(sql "$DB" "select string_agg(column_name||':'||privilege_type, ',' order by column_name) from information_schema.column_privileges where table_schema='public' and table_name='coverage_requests' and grantee='authenticated'")" \
  "city:INSERT,note:INSERT,viewed_lat:INSERT,viewed_lng:INSERT"
check "anon has no column privileges at all" "$(sql "$DB" "select count(*) from information_schema.column_privileges where table_schema='public' and table_name='coverage_requests' and grantee='anon'")" "0"
check "no table-level privileges for anon/authenticated" "$(sql "$DB" "select count(*) from information_schema.table_privileges where table_schema='public' and table_name='coverage_requests' and grantee in ('anon','authenticated')")" "0"
check "trigger function not EXECUTE-able by anon"          "$(sql "$DB" "select has_function_privilege('anon','public.coverage_requests_before_insert()','execute')")" "f"
check "trigger function not EXECUTE-able by authenticated" "$(sql "$DB" "select has_function_privilege('authenticated','public.coverage_requests_before_insert()','execute')")" "f"
check "trigger function has no PUBLIC EXECUTE entry"       "$(sql "$DB" "select count(*) from pg_proc p, aclexplode(p.proacl) a where p.oid='public.coverage_requests_before_insert()'::regprocedure and a.grantee=0")" "0"

U=$(new_user false)
ins() { # ins UID 'values-clause-with-columns'
  sql_as "$DB" authenticated "$1" "insert into public.coverage_requests $2;"
}
cnt() { sql "$DB" "select count(*) from public.coverage_requests $1"; }

echo "== Test 2: happy path (authenticated, full payload, precise coords get coarsened server-side)"
out=$(ins "$U" "(city, note, viewed_lat, viewed_lng) values ('  Park Slope, Brooklyn ', 'Please add us!', 40.671234, -73.977891)")
check_ok "insert accepted" "$out"
row=$(sql "$DB" "select city||'|'||note||'|'||viewed_lat||'|'||viewed_lng||'|'||(user_id='$U')||'|'||(abs(extract(epoch from now()-created_at)) < 10)||'|'||(id is not null) from public.coverage_requests where user_id='$U'")
check "stored: trimmed city, note, lat/lng rounded to 2dp, user_id = JWT sub, created_at = server now, id generated" "$row" "Park Slope, Brooklyn|Please add us!|40.67|-73.98|true|true|true"

echo "== Test 3: optional fields"
U3=$(new_user true)   # anonymous-auth session is 'authenticated' and allowed
out=$(ins "$U3" "(city) values ('Hoboken')")
check_ok "city-only insert accepted (anonymous-auth session)" "$out"
check "note NULL, lat/lng NULL" "$(sql "$DB" "select (note is null)::text||(viewed_lat is null)::text||(viewed_lng is null)::text from public.coverage_requests where user_id='$U3'")" "truetruetrue"
U3b=$(new_user false)
out=$(ins "$U3b" "(city, note) values ('Astoria', '   ')")
check_ok "whitespace-only note accepted" "$out"
check "whitespace-only note normalized to NULL" "$(sql "$DB" "select (note is null)::text from public.coverage_requests where user_id='$U3b'")" "true"

echo "== Test 4: length CHECK boundaries and ranges (fresh user per case to stay under the rate limit)"
rep() { printf '%*s' "$2" '' | tr ' ' "$1"; }
try() { # try LABEL EXPECT(ok|23514) columns-values
  local u; u=$(new_user false)
  local out; out=$(ins "$u" "$3")
  if [ "$2" = ok ]; then check_ok "$1" "$out"; else check_err "$1" "$out" "$2"; fi
}
try "city 1 char rejected"                23514 "(city) values ('a')"
try "city 2 chars accepted"               ok    "(city) values ('LA')"
try "city 80 chars accepted"              ok    "(city) values ('$(rep a 80)')"
try "city 81 chars rejected"              23514 "(city) values ('$(rep a 81)')"
try "city whitespace-only rejected"       23514 "(city) values ('      ')"
try "city 80 chars + padding accepted (length measured after trim)" ok "(city) values ('  $(rep b 80)  ')"
try "city NULL rejected (not null)"       23502 "(city) values (null)"
try "note 500 chars accepted"             ok    "(city, note) values ('Queens', '$(rep n 500)')"
try "note 501 chars rejected"             23514 "(city, note) values ('Queens', '$(rep n 501)')"
try "lat 90 / lng 180 accepted"           ok    "(city, viewed_lat, viewed_lng) values ('Pole', 90, 180)"
try "lat 90.01 rejected"                  23514 "(city, viewed_lat, viewed_lng) values ('Pole', 90.01, 0)"
try "lng -180.5 rejected"                 23514 "(city, viewed_lat, viewed_lng) values ('Pole', 0, -180.5)"
try "lat without lng rejected (pair rule)" 23514 "(city, viewed_lat) values ('Pole', 40.7)"
try "lng without lat rejected (pair rule)" 23514 "(city, viewed_lng) values ('Pole', -73.9)"
try "NaN lat rejected"                    23514 "(city, viewed_lat, viewed_lng) values ('Pole', 'NaN'::float8, 0)"
try "Infinity lng rejected"               23514 "(city, viewed_lat, viewed_lng) values ('Pole', 0, 'Infinity'::float8)"
check "rounding is applied to the boundary values too (90, 180 stay)" "$(sql "$DB" "select viewed_lat||'/'||viewed_lng from public.coverage_requests where city='Pole'")" "90/180"

echo "== Test 5: client cannot set server-controlled columns"
V=$(new_user false)
out=$(ins "$V" "(city, created_at) values ('Newark', now() - interval '10 years')")
check_err "created_at not client-writable" "$out" 42501
out=$(ins "$V" "(city, id) values ('Newark', gen_random_uuid())")
check_err "id not client-writable" "$out" 42501
out=$(ins "$V" "(city, user_id) values ('Newark', '$V')")
check_err "user_id not client-writable (even own id)" "$out" 42501
out=$(ins "$V" "(city, user_id) values ('Newark', '$U')")
check_err "user_id not client-writable (someone else's id)" "$out" 42501
check "none of the rejected inserts left a row" "$(cnt "where user_id='$V'")" "0"

echo "== Test 6: who can write"
out=$(sql_as "$DB" anon "" "insert into public.coverage_requests (city) values ('Anon City');")
check_err "anon (no JWT) cannot insert" "$out" 42501
out=$(sql_as "$DB" anon "$V" "insert into public.coverage_requests (city) values ('Anon City');")
check_err "anon role with a forged sub cannot insert" "$out" 42501
check "no anon rows landed" "$(cnt "where city='Anon City'")" "0"

echo "== Test 7: clients cannot read, update or delete (dashboard/service role only)"
out=$(sql_as "$DB" authenticated "$U" "select * from public.coverage_requests;")
check_err "authenticated SELECT * denied" "$out" 42501
out=$(sql_as "$DB" authenticated "$U" "select count(*) from public.coverage_requests;")
check_err "authenticated SELECT count(*) denied" "$out" 42501
out=$(sql_as "$DB" authenticated "$U" "select city from public.coverage_requests;")
check_err "authenticated SELECT own writable column denied" "$out" 42501
out=$(sql_as "$DB" anon "" "select * from public.coverage_requests;")
check_err "anon SELECT denied" "$out" 42501
out=$(sql_as "$DB" authenticated "$U" "update public.coverage_requests set city='x';")
check_err "authenticated UPDATE denied" "$out" 42501
out=$(sql_as "$DB" authenticated "$U" "delete from public.coverage_requests;")
check_err "authenticated DELETE denied" "$out" 42501
# Documented consequence (header: 'MUST use minimal return'; same root cause as 05-device-push-tokens-rls-fix.sql):
V2=$(new_user false)
out=$(sql_as "$DB" authenticated "$V2" "insert into public.coverage_requests (city) values ('Returning City') returning id;")
check_err "INSERT ... RETURNING (PostgREST return=representation) is denied — iOS must use return=minimal" "$out" 42501
check "...and the denied RETURNING insert left no row" "$(cnt "where city='Returning City'")" "0"
out=$(sql_as "$DB" authenticated "$V2" "insert into public.coverage_requests (city) values ('Returning City');")
check_ok "the same insert without RETURNING (return=minimal) succeeds" "$out"

echo "== Test 8: rate limit — per user (default 5/hour)"
R=$(new_user false); S=$(new_user false)
okc=0
for i in 1 2 3 4 5; do out=$(ins "$R" "(city) values ('Rate City $i')"); printf '%s' "$out" | grep -q ERROR || okc=$((okc+1)); done
check "first 5 inserts by one user all succeed" "$okc" "5"
out=$(ins "$R" "(city) values ('Rate City 6')")
check_err "6th insert within the hour trips the limiter" "$out" 42501
check "limiter message is the documented one" "$(printf '%s' "$out" | grep -c 'rate limit exceeded: max 5 coverage request(s) per 1 hour(s)')" "1"
check "6th row not stored" "$(cnt "where user_id='$R'")" "5"
out=$(ins "$S" "(city) values ('Other User City')")
check_ok "a different user is unaffected" "$out"
sql "$DB" "update public.coverage_requests set created_at = now() - interval '61 minutes' where user_id='$R'" >/dev/null
out=$(ins "$R" "(city) values ('Rate City 7')")
check_ok "after the window passes (rows older than 1h) the same user can insert again" "$out"
sql "$DB" "update public.rate_limit_config set max_count = 2 where key='coverage_request'" >/dev/null
W=$(new_user false)
ins "$W" "(city) values ('w1')" >/dev/null; ins "$W" "(city) values ('w2')" >/dev/null
out=$(ins "$W" "(city) values ('w3')")
check_err "limit is retunable via rate_limit_config (set to 2 -> 3rd rejected)" "$out" 42501
sql "$DB" "update public.rate_limit_config set max_count = 5 where key='coverage_request'" >/dev/null

echo "== Test 8b: rate limit — global backstop (anonymous-session minting)"
N=$(cnt "where created_at > now() - interval '1 hour'")
sql "$DB" "update public.rate_limit_config set max_count = $N where key='coverage_request_global'" >/dev/null
G=$(new_user true)
out=$(ins "$G" "(city) values ('Global City')")
check_err "global cap reached ($N rows in the last hour) -> a brand-new user is rejected" "$out" 42501
check "global message is the documented one" "$(printf '%s' "$out" | grep -c 'temporarily unavailable')" "1"
sql "$DB" "update public.rate_limit_config set max_count = 300 where key='coverage_request_global'" >/dev/null
out=$(ins "$G" "(city) values ('Global City')")
check_ok "restored to 300 -> accepted" "$out"

echo "== Test 8c: rate limit holds under concurrency (advisory lock): 10 parallel inserts by one user, cap 5"
P=$(new_user false)
# All 10 sessions sleep until the same wall-clock instant, then insert, so the count-then-insert windows overlap.
T0=$(date -d '+2 seconds' +%s.%N)
for i in $(seq 1 10); do
  ( sql_as "$DB" authenticated "$P" "select pg_sleep(greatest(0, $T0 - extract(epoch from clock_timestamp()))) \\g /dev/null
insert into public.coverage_requests (city) values ('Parallel $i');" > "/tmp/par_$$_$i.out" 2>&1 ) &
done
wait
check "exactly 5 of 10 concurrent inserts committed" "$(cnt "where user_id='$P'")" "5"
check "the other 5 failed with the rate-limit error" "$(cat /tmp/par_$$_*.out | grep -c 'rate limit exceeded')" "5"
rm -f /tmp/par_$$_*.out

echo "== Test 9: account deletion (supabase/10) de-attributes, does not delete, a user's suggestions"
check "apply 10-account-deletion.sql" "$(apply_file 10-account-deletion.sql)" "ok"
X=$(new_user false)
ins "$X" "(city, note) values ('Jersey City', 'from X')" >/dev/null
out=$(sql_as "$DB" authenticated "$X" "select public.delete_my_account();")
check_ok "X deletes their account" "$out"
check "suggestion retained" "$(cnt "where city='Jersey City' and note='from X'")" "1"
check "...with user_id NULL (FK ON DELETE SET NULL)" "$(cnt "where city='Jersey City' and user_id is null")" "1"

finish
