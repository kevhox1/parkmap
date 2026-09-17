#!/usr/bin/env bash
# WePark Regulars network — S3 push-trigger test script
# Spec: docs/regulars-network-spec.md §2.9 (send-regular-push), §2.10-style test-script scope.
# Companion to supabase/08-regulars-push-trigger.sql — run this AFTER Kevin has:
#   1. Applied supabase/07-regulars-schema.sql (the trust-graph schema this trigger depends on)
#   2. Deployed the send-regular-push Edge Function (with the same 4 APNS_* secrets
#      send-community-push already uses — no new secrets to provision)
#   3. Applied supabase/08-regulars-push-trigger.sql via the Supabase SQL Editor
# See the PR description for the full, ordered deploy runbook.
#
# NEVER applied/run by an agent — this is Kevin's task, same as every prior migration verification
# (mirrors supabase/04-community-push-test.sh's own convention).
#
# Usage:
#   SUPABASE_URL=https://jiispshyqerscdoferaw.supabase.co \
#   SUPABASE_ANON_KEY=<anon key from Dashboard > Settings > API> \
#   ./supabase/08-regulars-push-trigger-test.sh
#
# Never hardcode credentials in this file — both env vars are required and read at runtime only.
#
# What this script CAN verify with anon-key-only access:
#   - A full invite -> redeem round trip creates a real regular_edges row between two fresh anonymous
#     sessions (reusing 07's own redeem_regular_invite() RPC — this script does not duplicate that
#     RPC's own coverage, already exhausted by 07-regulars-schema-test.sh; it only creates ONE edge as
#     setup for the push-trigger checks below).
#   - A leaving_soon pin insert by an author WITH a Regular succeeds (the
#     pins_invoke_send_regular_push trigger's WHEN clause is satisfied and the insert survives,
#     matching the fail-open guarantee this repo now has two independent local-Postgres proofs for —
#     see the PR description's "local validation" section for the scratch-instance repro this script
#     cannot itself perform over anon-key REST).
#   - A leaving_soon pin insert by an author WITH ZERO Regulars ALSO succeeds and behaves identically
#     to today (zero regression) — the trigger fires unconditionally in SQL; it is send-regular-push's
#     OWN job (not this script's, not visible over anon-key REST) to look up zero Regulars and return
#     early. This script only proves the INSERT itself is unaffected by the new trigger's existence.
#   - A non-leaving_soon ephemeral crowd pin (open_spot) insert still succeeds unaffected — establishing
#     that adding this trigger did not regress the pre-existing insert path for other pin types.
#
# What this script CANNOT verify with anon-key-only access (same limitation 04's own test script
# documents, printed as MANUAL steps instead of silently skipped):
#   - That send-regular-push actually ran, found the Regular's device token, and that APNs accepted
#     anything. net._http_response and Edge Function logs are SQL-Editor/Dashboard-only.
#   - That the visible push payload the function builds matches this PR's documented field list
#     exactly — that is a code-read/QA-read concern, not something this script probes over REST.
#
# Requires: curl, jq.

set -uo pipefail

FAILURES=0
PASSES=0

# ------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------
: "${SUPABASE_URL:?Set SUPABASE_URL, e.g. https://jiispshyqerscdoferaw.supabase.co}"
: "${SUPABASE_ANON_KEY:?Set SUPABASE_ANON_KEY to this project anon/public API key}"

for bin in curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "FATAL: required tool '$bin' not found on PATH." >&2
    exit 1
  fi
done

SUPABASE_URL="${SUPABASE_URL%/}"

pass() { PASSES=$((PASSES + 1)); echo "  PASS: $1"; }
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }
manual() { echo "  MANUAL: $1"; }

# assert_status ACTUAL_STATUS EXPECTED_STATUS LABEL BODY
assert_status() {
  if [ "$1" = "$2" ]; then
    pass "$3 (HTTP $1)"
  else
    fail "$3 (expected HTTP $2, got HTTP $1 — body: $4)"
  fi
}

# ------------------------------------------------------------------
# HTTP helpers (same shape as 04-community-push-test.sh / 07-regulars-schema-test.sh)
# ------------------------------------------------------------------
# rest METHOD PATH BEARER_TOKEN [JSON_BODY]
# Prints "<status>\n<body>" to stdout (status on first line).
rest() {
  local method=$1 path=$2 token=$3 body=${4:-}
  local raw
  if [ -n "$body" ]; then
    raw=$(curl -sS -X "$method" "${SUPABASE_URL}${path}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=representation" \
      -d "$body" \
      -w '\n%{http_code}')
  else
    raw=$(curl -sS -X "$method" "${SUPABASE_URL}${path}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H "Authorization: Bearer ${token}" \
      -w '\n%{http_code}')
  fi
  local status body_out
  status=$(echo "$raw" | tail -n1)
  body_out=$(echo "$raw" | sed '$d')
  echo "$status"
  echo "$body_out"
}

# rpc PATH BEARER_TOKEN JSON_BODY — same shape as rest() but targets /rest/v1/rpc/<fn>.
rpc() {
  local fn=$1 token=$2 body=$3
  rest POST "/rest/v1/rpc/${fn}" "$token" "$body"
}

# new_session: creates a fresh anonymous auth session.
# Sets globals SESSION_TOKEN / SESSION_USER_ID. Exits the script if signup fails outright.
new_session() {
  local resp token uid
  resp=$(curl -sS -X POST "${SUPABASE_URL}/auth/v1/signup" \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"data":{}}')
  token=$(echo "$resp" | jq -r '.access_token // empty')
  uid=$(echo "$resp" | jq -r '.user.id // empty')
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "FATAL: anonymous signup failed — is 'Allow anonymous sign-ins' enabled on this project?" >&2
    echo "Response: $resp" >&2
    exit 1
  fi
  SESSION_TOKEN=$token
  SESSION_USER_ID=$uid
}

echo "=== WePark Regulars S3 (send-regular-push trigger) test ==="
echo "Target: ${SUPABASE_URL}"
echo

# Coordinates inside the seeded 'nolita' zone box (03-community-2.0-schema.sql §2.3:
# lat 40.7217-40.7256, lng -73.9967--73.9930) — same convention as 04-community-push-test.sh.
TEST_LAT=40.7235
TEST_LNG=-73.9950
ZONE_ID=nolita

echo "--- Setting up anonymous test sessions ---"
new_session; AUTHOR_TOKEN=$SESSION_TOKEN; AUTHOR_ID=$SESSION_USER_ID
new_session; REGULAR_TOKEN=$SESSION_TOKEN; REGULAR_ID=$SESSION_USER_ID
new_session; LONELY_AUTHOR_TOKEN=$SESSION_TOKEN; LONELY_AUTHOR_ID=$SESSION_USER_ID
echo "  3 anonymous sessions created (author, regular, lonely-author-with-zero-regulars)."
echo

# ------------------------------------------------------------------
# Test 1 — invite -> redeem round trip creates a real regular_edges row
# (setup, not a re-test of 07's own RPC coverage)
# ------------------------------------------------------------------
echo "--- Test 1: create + redeem an invite so author and regular become Regulars ---"
BODY=$(jq -n --arg uid "$AUTHOR_ID" '{created_by: $uid}')
RESP=$(rest POST /rest/v1/regular_invites "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "author creates a regular_invites row" "$RBODY"
INVITE_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')

if [ -z "$INVITE_ID" ]; then
  echo "FATAL: invite insert did not return an id — cannot continue Test 1/2. Body: $RBODY" >&2
else
  RESP=$(rpc redeem_regular_invite "$REGULAR_TOKEN" "$(jq -n --arg t "$INVITE_ID" '{p_token: $t}')")
  STATUS=$(echo "$RESP" | head -n1)
  RBODY=$(echo "$RESP" | tail -n +2)
  assert_status "$STATUS" 200 "regular redeems the invite" "$RBODY"
  OK=$(echo "$RBODY" | jq -r '.ok // empty')
  if [ "$OK" = "true" ]; then
    pass "redeem_regular_invite returned ok:true"
  else
    fail "redeem_regular_invite did not return ok:true (body: $RBODY)"
  fi
fi
echo

# ------------------------------------------------------------------
# Test 2 — register a device_push_tokens row for the Regular (send-regular-push's own targeting query
# reads this table by user_id — see that function's own header for why zone_id is irrelevant here).
# ------------------------------------------------------------------
echo "--- Test 2: register a device_push_tokens row for the Regular ---"
BODY=$(jq -n --arg uid "$REGULAR_ID" '{
  user_id: $uid, apns_token: "deadbeef-s3-regular-token", environment: "sandbox"
}')
RESP=$(rest POST /rest/v1/device_push_tokens "$REGULAR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "regular registers own device_push_tokens row" "$RBODY"
echo

# ------------------------------------------------------------------
# Test 3 — author posts a leaving_soon pin WITH a head start; the pins_invoke_send_regular_push
# trigger's WHEN clause is satisfied — the insert must survive regardless of what happens downstream
# (fail-open guarantee, proven independently against a local scratch Postgres — see PR description).
# ------------------------------------------------------------------
echo "--- Test 3: leaving_soon pin insert (author HAS a Regular) succeeds (expect 201) ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$AUTHOR_ID" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
  leaving_minutes: 10, regulars_head_start_seconds: 900
}')
RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "leaving_soon pin insert (author with a Regular) accepted" "$RBODY"
PIN_ID_WITH_REGULAR=$(echo "$RBODY" | jq -r '.[0].id // empty')
echo

# ------------------------------------------------------------------
# Test 4 — a DIFFERENT author with ZERO Regulars posts a leaving_soon pin too — must ALSO succeed,
# byte-identical to today's behavior. The trigger fires unconditionally in SQL; it is
# send-regular-push's own job (invisible to this anon-key script) to find zero Regulars and no-op.
# ------------------------------------------------------------------
echo "--- Test 4: leaving_soon pin insert (author has ZERO Regulars) still succeeds (expect 201) — zero regression ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$LONELY_AUTHOR_ID" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
  leaving_minutes: 20
}')
RESP=$(rest POST /rest/v1/pins "$LONELY_AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "leaving_soon pin insert (zero-Regulars author) accepted" "$RBODY"
PIN_ID_LONELY=$(echo "$RBODY" | jq -r '.[0].id // empty')
echo

# ------------------------------------------------------------------
# Test 5 — a non-leaving_soon ephemeral crowd pin (open_spot) still inserts fine — establishes this
# new trigger's WHEN clause did not regress the pre-existing insert path for other pin types (it also
# still exercises pins_invoke_send_community_push, unaffected by this PR).
# ------------------------------------------------------------------
echo "--- Test 5: open_spot pin insert (unaffected by this trigger) still succeeds (expect 201) ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$AUTHOR_ID" '{
  pin_type: "open_spot", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author
}')
RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "open_spot pin insert accepted (unaffected by the new trigger)" "$RBODY"
PIN_ID_OPEN_SPOT=$(echo "$RBODY" | jq -r '.[0].id // empty')
echo

# ------------------------------------------------------------------
# Test 6 — MANUAL: confirm the new trigger actually fired for the Test 3 pin, and ONLY for that one
# among Tests 3-5 as far as send-regular-push is concerned (Test 4 should show a send-regular-push
# invocation too — it fires unconditionally — but the function itself should log "zero Regulars";
# Test 5's pin should show NO send-regular-push line at all, only send-community-push).
# ------------------------------------------------------------------
echo "--- Test 6: push trigger firing — cannot be automated with anon-key-only access ---"
manual "Open the Supabase SQL Editor and run:"
manual "  select id, status_code, created from net._http_response order by created desc limit 10;"
manual "You should see fresh rows for pins ${PIN_ID_WITH_REGULAR:-<test-3-pin-id>}, ${PIN_ID_LONELY:-<test-4-pin-id>},"
manual "and ${PIN_ID_OPEN_SPOT:-<test-5-pin-id>} — the open_spot pin (Test 5) should have exactly ONE row"
manual "(send-community-push only); the two leaving_soon pins (Tests 3/4) should each have TWO rows"
manual "(send-community-push AND send-regular-push)."
manual ""
manual "Also check: Dashboard -> Edge Functions -> send-regular-push -> Logs. Expect a"
manual "'send-regular-push complete: ... regulars=1 candidates=1 sent=... ' line for the Test 3 pin"
manual "(author has exactly one Regular, who registered exactly one sandbox token in Test 2 — note that"
manual "token is a fake string and will always fail APNs with BadDeviceToken, which the function treats"
manual "as a dead token and deletes, same convention as send-community-push), and a"
manual "'send-regular-push: ... has zero Regulars — nothing to send.' line for the Test 4 pin."
manual ""
manual "Full end-to-end push delivery (a real device receiving and displaying a visible alert) cannot"
manual "be verified until a real APNs token exists in device_push_tokens (spec's own S13 gate, two real"
manual "physical devices required) — this script proves the trigger's WHEN clause matched for the"
manual "correct pin_types only, the row reached both Edge Functions' HTTP endpoints via pg_net, and the"
manual "insert path is completely unaffected either way — not that APNs itself accepted anything."
echo

# ------------------------------------------------------------------
# Best-effort cleanup
# ------------------------------------------------------------------
echo "--- Cleanup ---"
for pid in "$PIN_ID_WITH_REGULAR" "$PIN_ID_LONELY" "$PIN_ID_OPEN_SPOT"; do
  if [ -n "${pid:-}" ] && [ "$pid" != "null" ]; then
    curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/pins?id=eq.${pid}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H "Authorization: Bearer ${AUTHOR_TOKEN}" >/dev/null
  fi
done
echo "  deleted test pins."
curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/device_push_tokens?user_id=eq.${REGULAR_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${REGULAR_TOKEN}" >/dev/null
echo "  deleted test device_push_tokens row(s) for the regular."
curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/regular_edges?low_user_id=eq.${AUTHOR_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${AUTHOR_TOKEN}" >/dev/null
curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/regular_edges?high_user_id=eq.${AUTHOR_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${AUTHOR_TOKEN}" >/dev/null
echo "  deleted the test regular_edges row (best-effort, whichever ordering matched)."
echo

echo "=== Results: ${PASSES} passed, ${FAILURES} failed ==="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
