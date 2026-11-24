#!/usr/bin/env bash
# WePark — supabase/13-spot-handoffs.sql scratch-Postgres test (Spot Pass backend, stream A).
#
# Runs against a THROWAWAY local Postgres 16 (NOT Supabase, NOT production — Kevin applies migrations by hand).
# Fresh database, real migrations 01-06 verbatim on a Supabase-shaped stub (supabase/scratch/), then 10 (account
# deletion), then 13 applied TWICE, then 14 (claim returns id) applied TWICE, then driven as the real `anon` / `authenticated` / `service_role` roles with a
# JWT-sub GUC like PostgREST. Service RPCs (the ones the Edge Functions call) are driven as `service_role`.
#
# WHAT IT CANNOT PROVE (stub): pg_cron / pg_net / Vault are stubs (no real HTTP — pushes are asserted via the pg_net
# stub's recorded calls); the Edge Functions are NOT exercised (see supabase/functions/handoff-*/ + the Deno tests and
# the verification checklist in supabase/functions/README-handoff.md).
#
# Usage:  PGHOST=/path/to/socketdir PGPORT=55432 PGUSER=postgres ./supabase/13-spot-handoffs-test.sh
# Requires: psql (16), bash.   Exit code 0 = all passed.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch/common.sh"

scratch_create_db t13
echo "== scratch DB $DB: migrations 01-06 applied; $(sql "$DB" 'show server_version')"

# Supabase keeps pgcrypto in schema `extensions`; the scratch stub put it in public. Shim the one function we use.
sql "$DB" "create schema if not exists extensions;
create or replace function extensions.gen_random_bytes(int) returns bytea language sql as 'select public.gen_random_bytes(\$1)';
grant usage on schema extensions to anon, authenticated, service_role;" >/dev/null

apply13() {
  sed -E 's/^create extension if not exists (pg_cron|pg_net);/-- [scratch] skipped: &/' "$SUPABASE_DIR/13-spot-handoffs.sql" \
    | psql -X -q -d "$DB" -v ON_ERROR_STOP=1 2>&1 >/dev/null && echo ok
}

echo "== Test 0: apply 10, then 13 twice (idempotent)"
check "apply 10-account-deletion.sql" "$(apply_file 10-account-deletion.sql)" "ok"
check "apply 13 (first)"  "$(apply13)" "ok"
check "apply 13 (second, idempotent)" "$(apply13)" "ok"
check "apply 14-handoff-claim-returns-id (first)" "$(apply_file 14-handoff-claim-returns-id.sql)" "ok"
check "apply 14 (second, idempotent)" "$(apply_file 14-handoff-claim-returns-id.sql)" "ok"
check "cron job registered once" "$(sql "$DB" "select count(*) from cron.job where jobname='handoff-sweep'")" "1"
check "HANDOFF_ENABLED seeded false, one row after 2 applies" "$(sql "$DB" "select count(*)||':'||min(value) from public.handoff_config where key='HANDOFF_ENABLED'")" "1:false"

echo "== Test 1: privilege surface"
check "RLS on all 6 tables" "$(sql "$DB" "select count(*) from pg_class where relname in ('spot_handoffs','handoff_reports','handoff_suspensions','handoff_pair_log','handoff_rate_events','handoff_config') and relrowsecurity")" "6"
check "authenticated column grants on spot_handoffs are SELECT-only, fixed list, no secrets" \
  "$(sql "$DB" "select string_agg(column_name||':'||privilege_type, ',' order by column_name) from information_schema.column_privileges where table_schema='public' and table_name='spot_handoffs' and grantee='authenticated'")" \
  "alias:SELECT,armed_at:SELECT,created_at:SELECT,departed_at:SELECT,expires_at:SELECT,glyph:SELECT,id:SELECT,leave_at:SELECT,outcome:SELECT,status:SELECT"
check "anon has no privileges on spot_handoffs" "$(sql "$DB" "select count(*) from information_schema.column_privileges where table_name='spot_handoffs' and grantee='anon'")" "0"
for t in handoff_reports handoff_suspensions handoff_pair_log handoff_rate_events handoff_config; do
  check "no client privileges on $t" "$(sql "$DB" "select count(*) from information_schema.table_privileges where table_schema='public' and table_name='$t' and grantee in ('anon','authenticated')")" "0"
done
fn_acl() { sql "$DB" "select string_agg(distinct pg_get_userbyid(a.grantee), ',' order by pg_get_userbyid(a.grantee)) from pg_proc p, aclexplode(p.proacl) a where p.oid='$1'::regprocedure"; }
for f in 'public.create_handoff(boolean)' 'public.cancel_handoff(uuid)' 'public.confirm_handoff_outcome(uuid,text)' 'public.report_handoff(uuid,text)' 'public.get_my_handoff_karma()'; do
  check "client RPC $f ACL = {authenticated, postgres}" "$(fn_acl "$f")" "authenticated,postgres"
done
for f in 'public.handoff_peek(text,text)' 'public.handoff_claim(text,timestamptz,text,text,text,uuid,text)' 'public.handoff_depart(uuid,text,text)' \
         'public.handoff_extend(uuid,text)' 'public.handoff_cancel_claim(uuid,text)' 'public.handoff_report(text,uuid,text,text,text)' 'public.handoff_clear_tokens(uuid)'; do
  check "service RPC $f ACL = {postgres, service_role}" "$(fn_acl "$f")" "postgres,service_role"
done
check "delete_my_account ACL unchanged ({postgres, authenticated})" "$(fn_acl 'public.delete_my_account()')" "authenticated,postgres"
check "all handoff functions are SECURITY DEFINER with search_path=''" \
  "$(sql "$DB" "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where ((n.nspname='public' and (p.proname like '%handoff%')) or (n.nspname='internal' and p.proname like 'handoff%')) and p.proname <> 'delete_my_account' and (not p.prosecdef or array_to_string(p.proconfig, ',') not like 'search_path=\"\"%')")" "0"

# ---- fixtures / helpers ------------------------------------------------------------------------------
# Users are created 3 days old by default (karma requires a claimer account >= 24 h old, QA #4); new_user_fresh makes a new one.
new_user()       { sql "$DB" "insert into auth.users (email, is_anonymous, created_at) values ('u'||gen_random_uuid()||'@example.test', ${1:-false}, now() - interval '3 days') returning id;"; }
new_user_fresh() { sql "$DB" "insert into auth.users (email, is_anonymous) values ('u'||gen_random_uuid()||'@example.test', ${1:-false}) returning id;"; }
SEEKER=$(new_user true); DRIVER=$(new_user true); OTHER=$(new_user true)
svc() { sql_as "$DB" service_role "" "$1"; }
as()  { sql_as "$DB" authenticated "$1" "$2"; }
jq_() { sql "$DB" "select ($1)::jsonb->>'$2'"; }   # jq_ 'json-text' key
reset_rates() { sql "$DB" "delete from public.handoff_rate_events" >/dev/null; }
# mkpass SEEKER_UID -> "id token"
mkpass() { as "$1" "select (j->>'id')||' '||(j->>'token') from (select public.create_handoff(false) j) s;"; }
claim() { # claim TOKEN [claimer-uid|null] [push_token|null] [leave minutes]
  local c=${2:-null}; [ "$c" != null ] && c="'$c'"
  local p=${3:-null}; [ "$p" != null ] && p="'$p'"
  svc "select public.handoff_claim('$1', now() + interval '${4:-10} minutes', $p, null, ${5:-null}, $c, 'ip-1');"
}
st() { sql "$DB" "select status from public.spot_handoffs where id='$1'"; }
col() { sql "$DB" "select $2 from public.spot_handoffs where id='$1'"; }
rep() { sql "$DB" "select coalesce(reputation,0)||'/'||coalesce(helped_count,0) from public.profiles where id='$1'" ; }
UNAVAIL='{"status": "unavailable"}'

echo "== Test 2: feature flag defaults OFF"
out=$(as "$SEEKER" "select public.create_handoff(false);")
check_err "create_handoff raises 55000 while HANDOFF_ENABLED is false" "$out" 55000
check "service peek returns disabled" "$(svc "select public.handoff_peek('x', 'ip')")" '{"disabled": true}'
check "service depart returns disabled" "$(svc "select public.handoff_depart(gen_random_uuid(), 'x', 'manual')")" '{"disabled": true}'
sql "$DB" "update public.handoff_config set value='true' where key='HANDOFF_ENABLED'" >/dev/null

echo "== Test 3: create_handoff — contract shape, hashing, one active pass"
out=$(sql_as "$DB" anon "$SEEKER" "select public.create_handoff(false);")
check_err "anon cannot call create_handoff" "$out" 42501
out=$(sql_as "$DB" authenticated "" "select public.create_handoff(false);")
check_err "authenticated without sub is rejected by the auth.uid() guard" "$out" 42501
P1=$(mkpass "$SEEKER"); ID1=${P1% *}; TOK1=${P1#* }
check "token is 22 base64url chars (128-bit)" "$(printf '%s' "$TOK1" | grep -Ec '^[A-Za-z0-9_-]{22}$')" "1"
out=$(as "$SEEKER" "select jsonb_object_keys(public.create_handoff(false)) order by 1;")
check "response keys are exactly {alias, expires_at, glyph, id, token}" "$(printf '%s' "$out" | tr '\n' ',')" "alias,expires_at,glyph,id,token"
check "token_hash = sha256(token); the token string is stored nowhere" \
  "$(sql "$DB" "select (token_hash = sha256(convert_to('$TOK1','UTF8')))::text from public.spot_handoffs where id='$ID1'")" "true"
check "no column of the row contains the token" "$(sql "$DB" "select count(*) from public.spot_handoffs h where h::text like '%$TOK1%'")" "0"
check "unclaimed TTL is 20 min" "$(sql "$DB" "select (expires_at - created_at = interval '20 minutes')::text from public.spot_handoffs where id='$ID1'")" "true"
check "creating a 2nd pass cancelled the 1st (one active per seeker)" "$(st "$ID1")" "cancelled"
check "exactly one active pass for the seeker" "$(sql "$DB" "select count(*) from public.spot_handoffs where seeker_id='$SEEKER' and status in ('created','armed')")" "1"

echo "== Test 4: seeker RLS — own rows, fixed columns only"
check "seeker reads own status" "$(as "$SEEKER" "select count(*) from public.spot_handoffs where status in ('created','cancelled');")" "2"
check "other user sees 0 rows" "$(as "$OTHER" "select count(*) from public.spot_handoffs;" 2>&1 | tail -1 | grep -c 42501)" "0"
check "other user sees no rows of the seeker's" "$(as "$OTHER" "select count(*) from public.spot_handoffs where status is not null;")" "0"
out=$(as "$SEEKER" "select token_hash from public.spot_handoffs limit 1;")
check_err "seeker cannot select token_hash" "$out" 42501
out=$(as "$SEEKER" "select claimer_secret_hash from public.spot_handoffs limit 1;")
check_err "seeker cannot select claimer_secret_hash" "$out" 42501
out=$(as "$SEEKER" "select claimer_push_token from public.spot_handoffs limit 1;")
check_err "seeker cannot select claimer_push_token / claimer_anon_id class of columns" "$out" 42501
out=$(as "$SEEKER" "update public.spot_handoffs set status='departed';")
check_err "seeker cannot UPDATE directly" "$out" 42501
out=$(as "$SEEKER" "insert into public.spot_handoffs (token_hash,seeker_id,alias,glyph,expires_at) values ('\\x00','$SEEKER','a','g',now());")
check_err "seeker cannot INSERT directly" "$out" 42501
out=$(sql_as "$DB" anon "" "select id from public.spot_handoffs;")
check_err "anon cannot select" "$out" 42501
out=$(as "$SEEKER" "select public.handoff_peek('x','ip');")
check_err "authenticated cannot call service RPC handoff_peek" "$out" 42501
out=$(sql_as "$DB" anon "" "select public.handoff_claim('x', now(), null,null,null,null,'ip');")
check_err "anon cannot call service RPC handoff_claim" "$out" 42501

echo "== Test 5: peek — identical answers for bad / expired / used"
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
out=$(svc "select public.handoff_peek('$TOK','ip-1');")
check "valid token: open + alias + glyph + display_name null" "$(jq_ "'$out'" status)|$(jq_ "'$out'" display_name)|$(printf '%s' "$out" | grep -c alias)" "open||1"
BAD=$(svc "select public.handoff_peek('AAAAAAAAAAAAAAAAAAAAAA','ip-1');")
check "bad token => unavailable" "$BAD" "$UNAVAIL"
check "garbage token (wrong length) => unavailable" "$(svc "select public.handoff_peek('nope','ip-1');")" "$UNAVAIL"
sql "$DB" "update public.spot_handoffs set expires_at = now() - interval '1 minute' where id='$ID'" >/dev/null
check "expired token => byte-identical to bad token" "$(svc "select public.handoff_peek('$TOK','ip-1');")" "$BAD"
sql "$DB" "update public.spot_handoffs set expires_at = now() + interval '10 minutes' where id='$ID'" >/dev/null
check "peek is read-only (still 'created')" "$(st "$ID")" "created"
claim "$TOK" "$DRIVER" >/dev/null
check "used token => byte-identical to bad token" "$(svc "select public.handoff_peek('$TOK','ip-1');")" "$BAD"

echo "== Test 6: claim — atomic one-time arm, leave_at rounding, horizon, secret"
reset_rates
P=$(mkpass "$OTHER"); ID=${P% *}; TOK=${P#* }
check "leave_at 241+ min rejected (not token-dependent)" "$(claim "$TOK" "$DRIVER" null 245)" '{"invalid_leave_at": true}'
check "...pass still claimable after a rejected leave_at" "$(st "$ID")" "created"
out=$(claim "$TOK" "$DRIVER" null 10)
check "claim => armed" "$(jq_ "'$out'" status)" "armed"
check "claimer_secret returned, 22 chars" "$(jq_ "'$out'" claimer_secret | grep -Ec '^[A-Za-z0-9_-]{22}$')" "1"
SEC=$(jq_ "'$out'" claimer_secret)
check "claim returns the pass id (14)" "$(jq_ "'$out'" id)" "$ID"
check "response keys {claimer_secret, expires_at, id, leave_at, status}" "$(printf '%s' "$out" | sed 's/[{}" ]//g; s/:[^,]*//g' | tr ',' '\n' | sort | tr '\n' ',')" "claimer_secret,expires_at,id,leave_at,status,"
check "leave_at rounded to 5 min" "$(col "$ID" "(extract(epoch from leave_at)::bigint % 300)")" "0"
check "expires_at = leave_at + 15 min grace" "$(col "$ID" "(expires_at - leave_at = interval '15 minutes')::text")" "true"
check "only the secret HASH is stored" "$(col "$ID" "(claimer_secret_hash = sha256(convert_to('$SEC','UTF8')))::text")" "true"
check "no column contains the secret" "$(sql "$DB" "select count(*) from public.spot_handoffs h where h::text like '%$SEC%'")" "0"
check "2nd claim => unavailable" "$(claim "$TOK" "$OTHER" null 10)" "$UNAVAIL"
check "time format is ISO-8601 Z" "$(printf '%s' "$out" | grep -Ec '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z')" "1"

echo "   -- concurrent claims: exactly one winner"
reset_rates
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
for i in 1 2 3 4 5 6; do ( claim "$TOK" "$DRIVER" null 10 > "/tmp/wp13_claim_$$_$i" ) & done; wait
check "exactly one of 6 parallel claims armed" "$(cat /tmp/wp13_claim_$$_* | grep -c '"armed"')" "1"
check "the other 5 are unavailable" "$(cat /tmp/wp13_claim_$$_* | grep -c unavailable)" "5"
rm -f /tmp/wp13_claim_$$_*

echo "   -- self-scan and same-device are rejected without consuming the pass"
reset_rates
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
check "self-scan (claimer == seeker) => unavailable" "$(claim "$TOK" "$SEEKER" null 10)" "$UNAVAIL"
check "...pass NOT consumed" "$(st "$ID")" "created"
sql "$DB" "insert into public.device_push_tokens (user_id, apns_token, environment) values ('$SEEKER','devtok-seeker-1','sandbox')" >/dev/null
check "claimer push token equal to a seeker device token => unavailable" "$(claim "$TOK" "$DRIVER" devtok-seeker-1 10)" "$UNAVAIL"
check "...pass NOT consumed" "$(st "$ID")" "created"
check "different device token claims fine" "$(jq_ "'$(claim "$TOK" "$DRIVER" devtok-driver-1 10 "'com.kevinhoxha.wepark.Clip'")'" status)" "armed"
check "tokens + topic stored while armed" "$(col "$ID" "claimer_push_token||'|'||claimer_topic")" "devtok-driver-1|com.kevinhoxha.wepark.Clip"

echo "== Test 7: depart — secret gating, indistinguishable failures, terminal nulling"
reset_rates
P=$(mkpass "$OTHER"); ID=${P% *}; TOK=${P#* }
C=$(claim "$TOK" "$DRIVER" tok-d2 10); SEC=$(jq_ "'$C'" claimer_secret); CID=$(jq_ "'$C'" id)
check "claim-returned id == pass id (14)" "$CID" "$ID"
FAIL='{"ok": false}'
check "valid token alone cannot depart (no secret)" "$(svc "select public.handoff_depart('$ID', '$TOK', 'manual')")" "$FAIL"
check "wrong secret => ok:false" "$(svc "select public.handoff_depart('$ID', 'AAAAAAAAAAAAAAAAAAAAAA', 'manual')")" "$FAIL"
check "unknown id => same ok:false" "$(svc "select public.handoff_depart(gen_random_uuid(), '$SEC', 'manual')")" "$FAIL"
check "bad source => invalid_source" "$(svc "select public.handoff_depart('$ID', '$SEC', 'teleport')")" '{"invalid_source": true}'
check "still armed after failed attempts" "$(st "$ID")" "armed"
check "depart with the claim-returned (id, secret) succeeds end-to-end (14)" "$(svc "select public.handoff_depart('$CID', '$SEC', 'live_activity')")" '{"ok": true}'
check "status departed, source recorded" "$(col "$ID" "status||'/'||depart_source")" "departed/live_activity"
check "secret hash nulled at terminal" "$(col "$ID" "(claimer_secret_hash is null)::text")" "true"
check "tokens on short fuse (<=30 min) for the thanks push" "$(col "$ID" "(claimer_push_token is not null and claimer_tokens_until <= now()+interval '30 minutes')::text")" "true"
check "repeat depart => ok:false (no double ping)" "$(svc "select public.handoff_depart('$ID', '$SEC', 'manual')")" "$FAIL"
check "extend after terminal fails" "$(svc "select public.handoff_extend('$ID', '$SEC')")" "$FAIL"
check "cancel after terminal fails" "$(svc "select public.handoff_cancel_claim('$ID', '$SEC')")" "$FAIL"

echo "   -- expired pass cannot depart"
reset_rates
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
SEC=$(jq_ "'$(claim "$TOK" "$DRIVER" null 10)'" claimer_secret)
sql "$DB" "update public.spot_handoffs set expires_at = now() - interval '1 second' where id='$ID'" >/dev/null
check "armed but past expires_at => depart ok:false" "$(svc "select public.handoff_depart('$ID', '$SEC', 'manual')")" "$FAIL"

echo "== Test 8: extend — +5 min, max 3, never past the horizon; cancel is silent"
reset_rates
P=$(mkpass "$OTHER"); ID=${P% *}; TOK=${P#* }
SEC=$(jq_ "'$(claim "$TOK" "$DRIVER" null 10)'" claimer_secret)
L0=$(col "$ID" "extract(epoch from leave_at)::bigint")
out=$(svc "select public.handoff_extend('$ID', '$SEC')")
check "extend ok, shape {ok, leave_at, expires_at}" "$(jq_ "'$out'" ok)|$(printf '%s' "$out" | grep -c leave_at)" "true|1"
check "leave_at moved forward (+5 from max(leave_at, now))" "$(col "$ID" "((extract(epoch from leave_at)::bigint - $L0) >= 300)::text")" "true"
svc "select public.handoff_extend('$ID', '$SEC')" >/dev/null; svc "select public.handoff_extend('$ID', '$SEC')" >/dev/null
check "3 extensions used" "$(col "$ID" "extensions")" "3"
check "4th extension refused" "$(svc "select public.handoff_extend('$ID', '$SEC')")" "$FAIL"
reset_rates
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
SEC=$(jq_ "'$(claim "$TOK" "$DRIVER" null 240)'" claimer_secret)
check "claim at the 240 min cap is accepted (leave_at clamped to horizon)" "$(st "$ID")" "armed"
check "extend past the horizon (240 from claim) refused" "$(svc "select public.handoff_extend('$ID', '$SEC')")" "$FAIL"
check "extension count unchanged" "$(col "$ID" "extensions")" "0"

echo "   -- driver cancel is silent: seeker-visible status stays 'armed'"
reset_rates; sql "$DB" "delete from net._http_response" >/dev/null
sql "$DB" "insert into vault.decrypted_secrets values ('service_role_key','fake') on conflict do nothing" >/dev/null
P=$(mkpass "$OTHER"); ID=${P% *}; TOK=${P#* }
SEC=$(jq_ "'$(claim "$TOK" "$DRIVER" tok-cancel 10)'" claimer_secret)
sql "$DB" "delete from net._http_response" >/dev/null   # drop the 'armed' push record; now watch for anything new
check "wrong secret cannot cancel" "$(svc "select public.handoff_cancel_claim('$ID', 'AAAAAAAAAAAAAAAAAAAAAA')")" "$FAIL"
check "correct secret cancels" "$(svc "select public.handoff_cancel_claim('$ID', '$SEC')")" '{"ok": true}'
check "seeker still sees 'armed' (no signal about the driver)" "$(as "$OTHER" "select status from public.spot_handoffs where id='$ID';")" "armed"
check "driver cancel queued NO push to anyone" "$(sql "$DB" "select count(*) from net._http_response")" "0"
check "secret + tokens nulled, cancel time recorded" "$(col "$ID" "(claimer_secret_hash is null and claimer_push_token is null and claimer_activity_token is null and claimer_topic is null and claimer_cancelled_at is not null)::text")" "true"
check "cancelled driver cannot then depart" "$(svc "select public.handoff_depart('$ID', '$SEC', 'manual')")" "$FAIL"

echo "== Test 9: seeker cancel / stop waiting"
reset_rates
P=$(mkpass "$OTHER"); ID=${P% *}; TOK=${P#* }
SEC=$(jq_ "'$(claim "$TOK" "$DRIVER" tok-end 10 "'com.kevinhoxha.wepark'")'" claimer_secret)
sql "$DB" "delete from net._http_response" >/dev/null
out=$(as "$SEEKER" "select public.cancel_handoff('$ID');")
check "other user cannot cancel the seeker's pass (false)" "$out" "f"
check "owner cancels (true)" "$(as "$OTHER" "select public.cancel_handoff('$ID');")" "t"
check "status cancelled, secret nulled" "$(col "$ID" "status||'/'||(claimer_secret_hash is null)::text")" "cancelled/true"
check "handoff_ended push queued for the driver (kind in body, no tokens)" "$(sql "$DB" "select count(*) from net._http_response where url like '%send-handoff-push' and body_logged->>'kind'='handoff_ended' and body_logged::text not like '%tok-end%'")" "1"
check "tokens still present on <=2 min fuse so the push can read them" "$(col "$ID" "(claimer_push_token='tok-end' and claimer_tokens_until <= now()+interval '2 minutes')::text")" "true"
svc "select public.handoff_clear_tokens('$ID')" >/dev/null
check "handoff_clear_tokens nulls them" "$(col "$ID" "(claimer_push_token is null and claimer_topic is null and claimer_tokens_until is null)::text")" "true"
check "depart on a cancelled pass => ok:false" "$(svc "select public.handoff_depart('$ID', '$SEC', 'manual')")" "$FAIL"
check "cancel again => false" "$(as "$OTHER" "select public.cancel_handoff('$ID');")" "f"

echo "== Test 10: sweep — expiry nulls tokens, fuses, purge at 24 h"
reset_rates
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
claim "$TOK" "$DRIVER" tok-exp 10 >/dev/null
sql "$DB" "update public.spot_handoffs set expires_at = now() - interval '1 second' where id='$ID'" >/dev/null
sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "sweep expires an overdue armed pass" "$(st "$ID")" "expired"
check "...with tokens/secret nulled" "$(col "$ID" "(claimer_push_token is null and claimer_secret_hash is null)::text")" "true"
reset_rates
P=$(mkpass "$SEEKER"); ID=${P% *}; TOK=${P#* }
sql "$DB" "update public.spot_handoffs set expires_at = now() - interval '1 second' where id='$ID'" >/dev/null
sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "unclaimed pass expires" "$(st "$ID")" "expired"
sql "$DB" "update public.spot_handoffs set created_at = now() - interval '25 hours' where id='$ID'" >/dev/null
sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "rows older than 24 h are purged" "$(sql "$DB" "select count(*) from public.spot_handoffs where id='$ID'")" "0"
check "expired passes cannot be claimed" "$(claim "$TOK" "$DRIVER" null 10)" "$UNAVAIL"

echo "== Test 11: karma (spec 10) — confirm, idempotency, caps, cooldown, fallback"
sql "$DB" "delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.spot_handoffs; delete from public.profiles" >/dev/null
reset_rates
K1=$(new_user false); K2=$(new_user false); K3=$(new_user false); K4=$(new_user false); K5=$(new_user false)
full_pass() { # full_pass SEEKER DRIVER(or null) SOURCE -> sets ID
  reset_rates
  local p; p=$(mkpass "$1"); ID=${p% *}; local t=${p#* }
  local c; c=$(claim "$t" "${2:-null}" "tokk-$RANDOM" 10); local s; s=$(jq_ "'$c'" claimer_secret)
  svc "select public.handoff_depart('$ID', '$s', '${3:-manual}')" >/dev/null
}
confirm() { as "$1" "select public.confirm_handoff_outcome('$2', '$3');"; }

full_pass "$K1" "$K2"
sql "$DB" "delete from net._http_response" >/dev/null
check "confirm before... wrong user => ok:false" "$(jq_ "'$(confirm "$K3" "$ID" got_spot)'" ok)" "false"
out=$(confirm "$K1" "$ID" bogus); check_err "invalid outcome raises 22023" "$out" 22023
out=$(confirm "$K1" "$ID" got_spot)
check "got_spot ok, seeker_points 3 (+1 +2)" "$(jq_ "'$out'" ok)/$(jq_ "'$out'" seeker_points)" "true/3"
check "seeker 3 pts, helped_count 0" "$(rep "$K1")" "3/0"
check "driver +5, helped_count 1" "$(rep "$K2")" "5/1"
check "thanks push queued" "$(sql "$DB" "select count(*) from net._http_response where body_logged->>'kind'='thanks'")" "1"
out=$(confirm "$K1" "$ID" got_spot)
check "duplicate confirm: ok true, 0 new points" "$(jq_ "'$out'" ok)/$(jq_ "'$out'" seeker_points)" "true/0"
check "...no extra karma (idempotent) and no 2nd thanks" "$(rep "$K1")|$(rep "$K2")|$(sql "$DB" "select count(*) from net._http_response where body_logged->>'kind'='thanks'")" "3/0|5/1|1"
check "conflicting 2nd outcome => ok:false" "$(jq_ "'$(confirm "$K1" "$ID" no_luck)'" ok)" "false"
check "ledger keyed per (handoff, role): 3 rows" "$(sql "$DB" "select count(*) from public.reputation_award_log where source_id='$ID'")" "3"
check "ledger rows direct-insert replay is blocked by the unique key" \
  "$(sql "$DB" "insert into public.reputation_award_log(subject_id,source_table,source_id,kind) values ('$K2','spot_handoffs','$ID','handoff_helper') on conflict do nothing returning 1" | wc -l | tr -d ' ')" "0"

echo "   -- no_luck: seeker +1 only, driver nothing, no thanks"
full_pass "$K1" "$K3"; sql "$DB" "delete from net._http_response" >/dev/null
out=$(confirm "$K1" "$ID" no_luck)
check "no_luck seeker_points 1" "$(jq_ "'$out'" seeker_points)" "1"
check "driver K3 got nothing (no profile row at all)" "$(rep "$K3")" ""
check "no push queued for no_luck" "$(sql "$DB" "select count(*) from net._http_response")" "0"
check "no_luck nulls the driver's tokens" "$(col "$ID" "(claimer_push_token is null)::text")" "true"

echo "   -- pair cooldown: same pair within 24 h earns nothing (either direction)"
before=$(rep "$K1")
full_pass "$K1" "$K2"; out=$(confirm "$K1" "$ID" got_spot)
check "K1/K2 again within 24 h: seeker_points 0" "$(jq_ "'$out'" seeker_points)" "0"
check "...no karma moved for either" "$(rep "$K1")|$(rep "$K2")" "$before|5/1"
full_pass "$K2" "$K1"; out=$(confirm "$K2" "$ID" got_spot)
check "reverse direction (K2 seeker, K1 driver) also blocked" "$(jq_ "'$out'" seeker_points)|$(rep "$K2")" "0|5/1"
sql "$DB" "update public.handoff_pair_log set created_at = now() - interval '25 hours'" >/dev/null
full_pass "$K1" "$K2"; out=$(confirm "$K1" "$ID" got_spot)
check "after 24 h the pair earns again" "$(jq_ "'$out'" seeker_points)" "3"

echo "   -- self / unidentified claimer earns nothing; web fallback arms but no karma"
sql "$DB" "delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.profiles" >/dev/null
full_pass "$K4" null; out=$(confirm "$K4" "$ID" got_spot)
check "no claimer identity: seeker_points 0, no profile rows" "$(jq_ "'$out'" seeker_points)|$(sql "$DB" "select count(*) from public.profiles")" "0|0"

echo "   -- daily cap: 3 rewarded handoffs per user per 24 h"
sql "$DB" "delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.spot_handoffs; delete from public.profiles" >/dev/null
D1=$(new_user true); D2=$(new_user true); D3=$(new_user true); D4=$(new_user true); S0=$(new_user true)
for d in "$D1" "$D2" "$D3" "$D4"; do
  full_pass "$S0" "$d"; out=$(confirm "$S0" "$ID" got_spot); echo "     seeker pts for driver $d: $(jq_ "'$out'" seeker_points)"
done
check "seeker capped at 3 handoffs: 3 x 3 pts = 9" "$(rep "$S0")" "9/0"
check "4th driver (own count 0) was still paid? pair ok but seeker capped" "$(rep "$D4")" "5/1"
check "drivers 1-3 each paid once" "$(rep "$D1")|$(rep "$D2")|$(rep "$D3")" "5/1|5/1|5/1"
sql "$DB" "update public.reputation_award_log set created_at = now() - interval '25 hours'" >/dev/null
sql "$DB" "update public.handoff_pair_log set created_at = now() - interval '25 hours'" >/dev/null
full_pass "$S0" "$D1"; out=$(confirm "$S0" "$ID" got_spot)
check "after 24 h the cap window rolls: seeker earns again" "$(jq_ "'$out'" seeker_points)" "3"

echo "   -- verified-departure fallback (auto/shortcut, never confirmed): driver +2 at 30 min; later confirm adds +3"
sql "$DB" "delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.spot_handoffs; delete from public.profiles" >/dev/null
full_pass "$K1" "$K2" auto
sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "before 30 min: nothing paid" "$(rep "$K2")" ""
sql "$DB" "update public.spot_handoffs set departed_at = now() - interval '31 minutes' where id='$ID'" >/dev/null
sql "$DB" "select internal.handoff_sweep()" >/dev/null; sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "after 30 min: driver +2 exactly once (2 sweeps)" "$(rep "$K2")" "2/1"
check "seeker got nothing from fallback" "$(rep "$K1")" ""
out=$(confirm "$K1" "$ID" got_spot)
check "late got_spot confirm tops the driver up to 5, helped_count stays 1" "$(rep "$K2")" "5/1"
check "manual departures never get the fallback" "$(sql "$DB" "select count(*) from public.reputation_award_log where kind='handoff_helper_fallback'")" "1"
full_pass "$K3" "$K4" manual
sql "$DB" "update public.spot_handoffs set departed_at = now() - interval '2 hours' where id='$ID'" >/dev/null
sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "manual departure + no confirm => no fallback karma" "$(rep "$K4")" ""

echo "   -- get_my_handoff_karma counters"
check "spots_passed/spots_caught for K2/K1" "$(as "$K2" "select (public.get_my_handoff_karma())->>'spots_passed';")/$(as "$K1" "select (public.get_my_handoff_karma())->>'spots_caught';")" "1/1"

echo "   -- QA #4: omitting the push token no longer bypasses the guard; fresh accounts / shared-device accounts earn nothing"
sql "$DB" "delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.spot_handoffs; delete from public.profiles; delete from public.device_push_tokens" >/dev/null
F1=$(new_user true); F2=$(new_user_fresh true)
full_pass "$F1" "$F2"; out=$(confirm "$F1" "$ID" got_spot)
check "claimer account < 24 h old => no karma for either side" "$(jq_ "'$out'" seeker_points)|$(sql "$DB" "select count(*) from public.reputation_award_log")" "0|0"
sql "$DB" "update auth.users set created_at = now() - interval '25 hours' where id='$F2'" >/dev/null
sql "$DB" "insert into public.device_push_tokens (user_id, apns_token, environment) values ('$F1','shared-phone-tok','sandbox'), ('$F2','shared-phone-tok','sandbox')" >/dev/null
full_pass "$F1" "$F2"; out=$(confirm "$F1" "$ID" got_spot)
check "claim sent NO push token but both accounts registered the same device => no karma" "$(jq_ "'$out'" seeker_points)|$(sql "$DB" "select count(*) from public.reputation_award_log")" "0|0"
sql "$DB" "delete from public.device_push_tokens where user_id='$F2'" >/dev/null
full_pass "$F1" "$F2"; out=$(confirm "$F1" "$ID" got_spot)
check "aged, distinct-device claimer => karma flows (seeker 3)" "$(jq_ "'$out'" seeker_points)" "3"
F3=$(new_user_fresh true); full_pass "$F1" "$F3" auto
sql "$DB" "update public.spot_handoffs set departed_at = now() - interval '31 minutes' where id='$ID'" >/dev/null
sql "$DB" "select internal.handoff_sweep()" >/dev/null
check "fallback karma is guarded identically (fresh claimer, auto depart, 31 min)" "$(rep "$F3")" ""
sql "$DB" "delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.spot_handoffs; delete from public.profiles" >/dev/null

echo "== Test 12: reports — distinct reporters, anonymous cap, expiry"
sql "$DB" "delete from public.spot_handoffs; delete from public.handoff_reports; delete from public.handoff_suspensions; delete from public.profiles" >/dev/null
R1=$(new_user true); RD=$(new_user true)
echo "   -- QA probe P4: ONE claimer reporting the same seeker over 3 passes counts once"
for i in 1 2 3; do
  reset_rates
  p=$(mkpass "$R1"); rid=${p% *}; rt=${p#* }
  c=$(claim "$rt" "$RD" null 10); rs=$(jq_ "'$c'" claimer_secret)
  out=$(svc "select public.handoff_report(null, '$rid', '$rs', 'harassment', 'ip-r')")
  check "claimer report #$i accepted" "$(jq_ "'$out'" ok)" "true"
  check "report #$i ends the pass (suspended)" "$(st "$rid")" "suspended"
done
check "3 reports from ONE reporter => NOT suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$R1'")" "0"
check "...3 report rows recorded, 1 distinct reporter" "$(sql "$DB" "select count(*)||'/'||count(distinct reporter_user_id) from public.handoff_reports where subject_user_id='$R1'")" "3/1"
reset_rates
check "seeker can still create a pass" "$(jq_ "'$(as "$R1" "select public.create_handoff(false);")'" alias | grep -c .)" "1"
echo "   -- QA probe P5: anonymous (token-path) reports from rotating IPs count as at most ONE reporter"
reset_rates
for i in 1 2 3 4 5 6; do
  p=$(mkpass "$R1"); rid=${p% *}; rt=${p#* }
  svc "select public.handoff_report('$rt', null, null, 'spam', 'ip-rot-$i')" >/dev/null
done
check "6 anonymous reports + 1 identified claimer => 2 voices, NOT suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$R1'")" "0"
echo "   -- RD (identified) + RD2 (identified) + the anonymous voice = 3 distinct voices => suspended"
RD2=$(new_user true)
reset_rates
p=$(mkpass "$R1"); rid=${p% *}; rt=${p#* }
c=$(claim "$rt" "$RD2" null 10); rs=$(jq_ "'$c'" claimer_secret)
svc "select public.handoff_report(null, '$rid', '$rs', 'unsafe', 'ip-r')" >/dev/null
check "3 distinct voices => suspension row" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$R1'")" "1"
check "suspension expires in ~7 days" "$(sql "$DB" "select (expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour')::text from public.handoff_suspensions where user_id='$R1'")" "true"
reset_rates
out=$(as "$R1" "select public.create_handoff(false);")
check_err "suspended seeker cannot create passes" "$out" 42501
echo "   -- expiry: suspension lapses; a single fresh report does not re-suspend"
sql "$DB" "update public.handoff_suspensions set expires_at = now() - interval '1 minute' where user_id='$R1'" >/dev/null
reset_rates
check "after expiry the seeker can create again" "$(jq_ "'$(as "$R1" "select public.create_handoff(false);")'" alias | grep -c .)" "1"
reset_rates
p=$(mkpass "$R1"); rid=${p% *}; rt=${p#* }
c=$(claim "$rt" "$RD2" null 10); rs=$(jq_ "'$c'" claimer_secret)
svc "select public.handoff_report(null, '$rid', '$rs', 'unsafe', 'ip-r')" >/dev/null
check "one fresh report after expiry => still not suspended (needs 3 NEW voices)" "$(as "$R1" "select (public.create_handoff(false))->>'alias' is not null;")" "t"
check "expired suspension row kept for review" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$R1' and expires_at < now()")" "1"
sql "$DB" "delete from public.handoff_suspensions" >/dev/null
echo "   -- pre-claim report by token; seeker-side report"
p=$(mkpass "$OTHER"); rid=${p% *}; rt=${p#* }
check "claimer can report a still-'created' pass by token" "$(jq_ "'$(svc "select public.handoff_report('$rt', null, null, 'spam', 'ip-r2')")'" ok)" "true"
check "...which ends it" "$(st "$rid")" "suspended"
check "invalid reason refused" "$(svc "select public.handoff_report('x', null, null, 'rude', 'ip')")" '{"invalid_reason": true}'
reset_rates
p=$(mkpass "$OTHER"); rid=${p% *}; rt=${p#* }; claim "$rt" "$RD" null 10 >/dev/null
check "seeker report (own pass) ok" "$(jq_ "'$(as "$OTHER" "select public.report_handoff('$rid','unsafe');")'" ok)" "true"
check "someone else's pass => ok:false" "$(jq_ "'$(as "$R1" "select public.report_handoff('$rid','unsafe');")'" ok)" "false"
check "report recorded against the CLAIMER, with reporter identity" "$(sql "$DB" "select count(*) from public.handoff_reports where subject_user_id='$RD' and reporter_user_id='$OTHER'")" "1"
echo "   -- one seeker reporting the same claimer across 3 passes counts once; 3 distinct seekers suspend"
sql "$DB" "delete from public.handoff_reports where subject_user_id='$RD'; delete from public.handoff_suspensions; delete from public.spot_handoffs" >/dev/null
for i in 1 2 3; do
  reset_rates; p=$(mkpass "$OTHER"); rid=${p% *}; rt=${p#* }; claim "$rt" "$RD" null 10 >/dev/null
  as "$OTHER" "select public.report_handoff('$rid','harassment');" >/dev/null
done
check "same seeker x3 passes => claimer NOT suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$RD'")" "0"
for sk in "$SEEKER" "$R1"; do
  reset_rates; p=$(mkpass "$sk"); rid=${p% *}; rt=${p#* }; claim "$rt" "$RD" null 10 >/dev/null
  as "$sk" "select public.report_handoff('$rid','harassment');" >/dev/null
done
check "3 distinct seekers => claimer suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$RD'")" "1"
echo "   -- suspended claimer cannot claim"
reset_rates; p=$(mkpass "$OTHER"); rt=${p#* }
check "suspended claimer => unavailable" "$(claim "$rt" "$RD" null 10)" "$UNAVAIL"
sql "$DB" "delete from public.handoff_suspensions" >/dev/null

echo "   -- R1: 3 FRESH (<24h) accounts each claim a pass of the victim and report => recorded, NOT suspended"
sql "$DB" "delete from public.spot_handoffs; delete from public.handoff_reports; delete from public.handoff_suspensions" >/dev/null
V=$(new_user true)
for i in 1 2 3; do
  F=$(new_user_fresh true); reset_rates
  p=$(mkpass "$V"); rid=${p% *}; rt=${p#* }
  c=$(claim "$rt" "$F" null 10); rs=$(jq_ "'$c'" claimer_secret)
  svc "select public.handoff_report(null, '$rid', '$rs', 'harassment', 'ip-f')" >/dev/null
done
check "R1: 3 fresh reporters => 3 report rows recorded" "$(sql "$DB" "select count(*) from public.handoff_reports where subject_user_id='$V'")" "3"
check "R1: 3 fresh distinct reporters => victim NOT suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$V'")" "0"
echo "   -- R1: fresh reporters do not even add the anonymous voice; 1 anonymous + 1 aged + 2 fresh => still not suspended"
reset_rates; p=$(mkpass "$V"); rt=${p#* }
svc "select public.handoff_report('$rt', null, null, 'spam', 'ip-anon')" >/dev/null
A1=$(new_user true); reset_rates; p=$(mkpass "$V"); rid=${p% *}; rt=${p#* }
c=$(claim "$rt" "$A1" null 10); rs=$(jq_ "'$c'" claimer_secret)
svc "select public.handoff_report(null, '$rid', '$rs', 'unsafe', 'ip-a')" >/dev/null
check "R1: anon + 1 aged + 3 fresh => 2 counted voices, NOT suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$V'")" "0"
echo "   -- R1 positive: a 2nd + 3rd AGED distinct reporter DO suspend"
for i in 1 2; do
  A=$(new_user true); reset_rates; p=$(mkpass "$V"); rid=${p% *}; rt=${p#* }
  c=$(claim "$rt" "$A" null 10); rs=$(jq_ "'$c'" claimer_secret)
  svc "select public.handoff_report(null, '$rid', '$rs', 'unsafe', 'ip-a')" >/dev/null
done
check "R1: 3 aged distinct reporters => suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$V'")" "1"
sql "$DB" "delete from public.spot_handoffs; delete from public.handoff_reports; delete from public.handoff_suspensions" >/dev/null
echo "   -- R1 positive (clean): exactly 3 aged distinct reporters, nothing else"
for i in 1 2 3; do
  A=$(new_user true); reset_rates; p=$(mkpass "$V"); rid=${p% *}; rt=${p#* }
  c=$(claim "$rt" "$A" null 10); rs=$(jq_ "'$c'" claimer_secret)
  svc "select public.handoff_report(null, '$rid', '$rs', 'unsafe', 'ip-a')" >/dev/null
done
check "R1: 3 aged distinct reporters (clean) => suspended" "$(sql "$DB" "select count(*) from public.handoff_suspensions where user_id='$V'")" "1"
sql "$DB" "delete from public.spot_handoffs; delete from public.handoff_reports; delete from public.handoff_suspensions" >/dev/null

echo "== Test 13: rate limits"
reset_rates
p=$(mkpass "$SEEKER"); rt=${p#* }
n=0; for i in $(seq 1 30); do svc "select public.handoff_peek('$rt','ip-rl')" >/dev/null; done
check "30 peeks/hour/IP allowed, 31st limited" "$(svc "select public.handoff_peek('$rt','ip-rl')")" '{"rate_limited": true}'
check "a different IP is unaffected" "$(jq_ "'$(svc "select public.handoff_peek('$rt','ip-other')")'" status)" "open"
c=$(claim "$rt" "$DRIVER" null 10); rid=$(col "(select id from public.spot_handoffs where seeker_id='$SEEKER' and status='armed')" "id" 2>/dev/null)
rid=$(sql "$DB" "select id from public.spot_handoffs where seeker_id='$SEEKER' and status='armed' limit 1")
echo "   -- QA probe P3: 21+ wrong secrets on a known pass id must NOT lock out the real secret holder"
WRONG=AAAAAAAAAAAAAAAAAAAAAA
for fn in depart extend cancel; do
  reset_rates
  p=$(mkpass "$SEEKER"); rid=${p% *}; rt=${p#* }
  SECX=$(jq_ "'$(claim "$rt" "$DRIVER" null 10)'" claimer_secret)
  for i in $(seq 1 25); do
    case $fn in depart) svc "select public.handoff_depart('$rid','$WRONG','manual')" >/dev/null;;
                extend) svc "select public.handoff_extend('$rid','$WRONG')" >/dev/null;;
                cancel) svc "select public.handoff_cancel_claim('$rid','$WRONG')" >/dev/null;; esac
  done
  case $fn in depart) w=$(svc "select public.handoff_depart('$rid','$WRONG','manual')");;
              extend) w=$(svc "select public.handoff_extend('$rid','$WRONG')");;
              cancel) w=$(svc "select public.handoff_cancel_claim('$rid','$WRONG')");; esac
  check "$fn: further WRONG-secret attempts are rate limited (failure bucket)" "$w" '{"rate_limited": true}'
  case $fn in depart) g=$(svc "select public.handoff_depart('$rid','$SECX','manual')");;
              extend) g=$(svc "select public.handoff_extend('$rid','$SECX')");;
              cancel) g=$(svc "select public.handoff_cancel_claim('$rid','$SECX')");; esac
  check "$fn: real secret still succeeds after 26 wrong attempts" "$(jq_ "'$g'" ok)" "true"
done
reset_rates
for i in $(seq 1 10); do as "$OTHER" "select public.create_handoff(false);" >/dev/null; done
out=$(as "$OTHER" "select public.create_handoff(false);")
check_err "create_handoff limited to 10/hour/user" "$out" 53400
check "rate rows carry only a bucket + opaque key (no IP column)" "$(sql "$DB" "select string_agg(column_name,',' order by ordinal_position) from information_schema.columns where table_name='handoff_rate_events'")" "id,bucket,key,at"

echo "== Test 14: show_name opt-in"
reset_rates
sql "$DB" "insert into public.profiles(id, username) values ('$SEEKER','Maya Lopez') on conflict (id) do update set username='Maya Lopez'" >/dev/null
TOKN=$(as "$SEEKER" "select public.create_handoff(true)->>'token';")
check "show_name=true uses first word of username" "$(sql "$DB" "select seeker_display_name from public.spot_handoffs where seeker_id='$SEEKER' and status='created'")" "Maya"
check "peek returns display_name for an opted-in pass" "$(jq_ "'$(svc "select public.handoff_peek('$TOKN', 'ip-d')")'" display_name)" "Maya"
reset_rates
p=$(mkpass "$SEEKER"); rt=${p#* }
check "show_name=false => null (default)" "$(sql "$DB" "select seeker_display_name is null from public.spot_handoffs where seeker_id='$SEEKER' and status='created'")" "t"
sql "$DB" "update public.profiles set username='neighbor-ab12cd34' where id='$SEEKER'" >/dev/null
reset_rates; as "$SEEKER" "select public.create_handoff(true);" >/dev/null
check "auto-generated handle is never shown" "$(sql "$DB" "select seeker_display_name is null from public.spot_handoffs where seeker_id='$SEEKER' and status='created'")" "t"

echo "== Test 15: no location/identity columns on the row"
check "spot_handoffs has no lat/lng/address/plate/username columns" "$(sql "$DB" "select count(*) from information_schema.columns where table_name='spot_handoffs' and (column_name ~ 'lat|lng|lon|addr|plate|user' )")" "0"

echo "== Test 16: account deletion (extends 10)"
sql "$DB" "delete from public.spot_handoffs; delete from public.handoff_reports; delete from public.reputation_award_log; delete from public.handoff_pair_log; delete from public.profiles" >/dev/null
A=$(new_user true); B=$(new_user true); C=$(new_user true)
full_pass "$A" "$B" ; IDAB=$ID; confirm "$A" "$IDAB" got_spot >/dev/null
reset_rates; pa=$(mkpass "$A"); IDA2=${pa% *}
reset_rates; pc=$(mkpass "$C"); IDC=${pc% *}; tc=${pc#* }; claim "$tc" "$B" null 10 >/dev/null
svc "select public.handoff_report('x', null, null, 'spam', 'ip')" >/dev/null
as "$C" "select public.report_handoff('$IDC','spam');" >/dev/null
check "precondition: A has handoff rows + ledger + pair log" \
  "$(sql "$DB" "select (select count(*) from public.spot_handoffs where seeker_id='$A')||'/'||(select count(*) from public.reputation_award_log where subject_id='$A')||'/'||(select count(*) from public.handoff_pair_log where user_low='$A' or user_high='$A')")" "2/2/1"
out=$(as "$A" "select public.delete_my_account();")
check_ok "A deletes their account" "$out"
check "A's handoffs gone" "$(sql "$DB" "select count(*) from public.spot_handoffs where seeker_id='$A'")" "0"
check "A's ledger + pair log + rate keys gone" "$(sql "$DB" "select (select count(*) from public.reputation_award_log where subject_id='$A')+(select count(*) from public.handoff_pair_log where user_low='$A' or user_high='$A')+(select count(*) from public.handoff_rate_events where key='$A')")" "0"
check "A's auth.users row gone" "$(sql "$DB" "select count(*) from auth.users where id='$A'")" "0"
check "B's driver karma ledger untouched by A's deletion" "$(sql "$DB" "select count(*) from public.reputation_award_log where subject_id='$B'")" "1"
out=$(as "$B" "select public.delete_my_account();")
check_ok "B (a claimer on C's armed pass) deletes their account" "$out"
check "handoff rows B claimed are gone" "$(sql "$DB" "select count(*) from public.spot_handoffs where claimer_anon_id='$B'")" "0"
check "reports ABOUT B are gone" "$(sql "$DB" "select count(*) from public.handoff_reports where subject_user_id='$B'")" "0"
check "C untouched, no orphans referencing deleted users" "$(sql "$DB" "select count(*) from auth.users where id='$C'")|$(sql "$DB" "select count(*) from public.spot_handoffs h where not exists (select 1 from auth.users u where u.id=h.seeker_id)")" "1|0"
check "delete_my_account is still idempotent" "$(check_ok x "$(as "$A" "select public.delete_my_account();")" | grep -c PASS)" "1"

finish
