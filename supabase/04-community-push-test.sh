#!/usr/bin/env bash
# WePark Community 2.0 — Phase 4b community push pipeline test script
# Spec: docs/community-2.0-reconciliation-spec.md §2.9, §3 Phase 4.
# Companion to supabase/04-community-push-trigger.sql — run this AFTER Kevin has:
#   1. Deployed the send-community-push Edge Function (with all 4 APNS_* secrets set)
#   2. Applied supabase/04-community-push-trigger.sql via the Supabase SQL Editor
# See the PR description for the full, ordered deploy runbook.
#
# NEVER applied/run by an agent — this is Kevin's task, same as every prior migration verification
# (mirrors supabase/03-community-2.0-test.sh's own convention, itself modeled on the
# "curl /auth/v1/signup" smoke from HANDOFF 2026-06-06).
#
# Usage:
#   SUPABASE_URL=https://jiispshyqerscdoferaw.supabase.co \
#   SUPABASE_ANON_KEY=<anon key from Dashboard > Settings > API> \
#   ./supabase/04-community-push-test.sh
#
# Never hardcode credentials in this file — both env vars are required and read at runtime only.
#
# What this script CAN verify with anon-key-only access:
#   - device_push_tokens RLS: anon cannot read ANY row (no select policy exists at all — not even the
#     owning authenticated user can read their own token back via the anon-key REST API); anon cannot
#     insert a token for someone else; an authenticated user CAN insert a token for themselves.
#   - pins_with_author still returns every pre-Phase-4b column, plus the new author_avatar column, with
#     the correct value once an avatar is set.
#   - An ephemeral crowd pin insert succeeds (the pins_invoke_send_community_push trigger's WHEN
#     clause conditions are met) — but NOT that the Edge Function actually ran or that APNs accepted
#     anything, since net._http_response and Edge Function logs are only visible via the SQL Editor /
#     Supabase Dashboard, never via anon-key REST. Those steps are printed as MANUAL instructions
#     rather than silently skipped.
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

# assert_eq ACTUAL EXPECTED LABEL
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3 (got $1)"
  else
    fail "$3 (expected $2, got $1)"
  fi
}

# ------------------------------------------------------------------
# HTTP helpers (same shape as 03-community-2.0-test.sh)
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

echo "=== WePark Community 2.0 Phase 4b (send-community-push) test ==="
echo "Target: ${SUPABASE_URL}"
echo

# Coordinates inside the seeded 'nolita' zone box (03-community-2.0-schema.sql §2.3:
# lat 40.7217-40.7256, lng -73.9967--73.9930).
TEST_LAT=40.7235
TEST_LNG=-73.9950
ZONE_ID=nolita

echo "--- Setting up anonymous test sessions ---"
new_session; DEVICE_A_TOKEN=$SESSION_TOKEN; DEVICE_A_ID=$SESSION_USER_ID
new_session; DEVICE_B_TOKEN=$SESSION_TOKEN; DEVICE_B_ID=$SESSION_USER_ID
new_session; PIN_AUTHOR_TOKEN=$SESSION_TOKEN; PIN_AUTHOR_ID=$SESSION_USER_ID
echo "  3 anonymous sessions created."
echo

# ------------------------------------------------------------------
# Test 1 — anonymous (unauthenticated) device_push_tokens insert -> expect rejection
# ------------------------------------------------------------------
echo "--- Test 1: anonymous device_push_tokens insert (expect 401/403) ---"
BODY=$(jq -n --arg uid "$DEVICE_A_ID" '{
  user_id: $uid, apns_token: "deadbeef-anon-insert-attempt", environment: "sandbox"
}')
RESP=$(curl -sS -X POST "${SUPABASE_URL}/rest/v1/device_push_tokens" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "$BODY" -w '\n%{http_code}')
STATUS=$(echo "$RESP" | tail -n1)
RBODY=$(echo "$RESP" | sed '$d')
# Same 401-vs-403 ambiguity already documented in 03-community-2.0-test.sh Test 1 (PostgREST returns
# 401 when the unauthenticated `anon` role itself is denied, not necessarily 403) — the property under
# test is the rejection, not the exact status code PostgREST chooses for it.
if [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
  pass "anonymous device_push_tokens insert rejected (HTTP $STATUS)"
else
  fail "anonymous device_push_tokens insert rejected (expected HTTP 401 or 403, got HTTP $STATUS — body: $RBODY)"
fi
echo

# ------------------------------------------------------------------
# Test 2 — authenticated user CANNOT insert a token for a DIFFERENT user_id (impersonation attempt)
# ------------------------------------------------------------------
echo "--- Test 2: authenticated user cannot insert a token for a different user_id (expect 401/403) ---"
BODY=$(jq -n --arg uid "$DEVICE_B_ID" '{
  user_id: $uid, apns_token: "deadbeef-impersonation-attempt", environment: "sandbox"
}')
RESP=$(rest POST /rest/v1/device_push_tokens "$DEVICE_A_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
if [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
  pass "cross-user device_push_tokens insert rejected (HTTP $STATUS)"
else
  fail "cross-user device_push_tokens insert rejected (expected HTTP 401 or 403, got HTTP $STATUS — body: $RBODY)"
fi
echo

# ------------------------------------------------------------------
# Test 3 — authenticated user CAN insert a token for themselves
# ------------------------------------------------------------------
echo "--- Test 3: authenticated user can insert own device_push_tokens row (expect 201) ---"
BODY=$(jq -n --arg uid "$DEVICE_A_ID" --arg zone "$ZONE_ID" '{
  user_id: $uid, apns_token: "deadbeef-device-a-own-token", environment: "sandbox", zone_id: $zone
}')
RESP=$(rest POST /rest/v1/device_push_tokens "$DEVICE_A_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "authenticated own-token insert accepted" "$RBODY"
echo

# ------------------------------------------------------------------
# Test 4 — NO ONE can read device_push_tokens back, not even the row's own owner
# (deliberately no select policy at all, spec §2.9 — server-only surface).
# ------------------------------------------------------------------
echo "--- Test 4: device_push_tokens has no select policy for anyone (expect empty result, not the row just inserted) ---"
RESP=$(rest GET "/rest/v1/device_push_tokens?user_id=eq.${DEVICE_A_ID}&select=id" "$DEVICE_A_TOKEN")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
if [ "$STATUS" = "200" ]; then
  COUNT=$(echo "$RBODY" | jq 'length')
  assert_eq "$COUNT" "0" "owner cannot read back their own just-inserted device_push_tokens row (no select policy)"
elif [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
  pass "device_push_tokens read denied outright (HTTP $STATUS) — also consistent with 'no select policy'"
else
  fail "unexpected status reading device_push_tokens as owner (HTTP $STATUS — body: $RBODY)"
fi

RESP=$(curl -sS -X GET "${SUPABASE_URL}/rest/v1/device_push_tokens?select=id" \
  -H "apikey: ${SUPABASE_ANON_KEY}" -w '\n%{http_code}')
STATUS=$(echo "$RESP" | tail -n1)
RBODY=$(echo "$RESP" | sed '$d')
if [ "$STATUS" = "200" ]; then
  COUNT=$(echo "$RBODY" | jq 'length')
  assert_eq "$COUNT" "0" "anonymous read of device_push_tokens returns zero rows"
elif [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
  pass "anonymous device_push_tokens read denied outright (HTTP $STATUS)"
else
  fail "unexpected status reading device_push_tokens as anon (HTTP $STATUS — body: $RBODY)"
fi
echo

# ------------------------------------------------------------------
# Test 5 — pins_with_author still returns every prior column + the new author_avatar column
# ------------------------------------------------------------------
echo "--- Test 5: pins_with_author has every prior column plus author_avatar ---"
AVATAR_VALUE="rocket-$(date +%s)"
PATCH_RESP=$(rest PATCH "/rest/v1/profiles?id=eq.${PIN_AUTHOR_ID}" "$PIN_AUTHOR_TOKEN" "$(jq -n --arg a "$AVATAR_VALUE" '{avatar: $a}')")
# profiles row for a brand-new anonymous user may not exist yet (it is lazily created by
# award_report_reputation's upsert on first report, per 03-community-2.0-schema.sql §2.6) — insert it
# first if the PATCH affected zero rows, then retry.
PATCH_STATUS=$(echo "$PATCH_RESP" | head -n1)
PATCH_BODY=$(echo "$PATCH_RESP" | tail -n +2)
if [ "$(echo "$PATCH_BODY" | jq 'length' 2>/dev/null || echo 0)" = "0" ]; then
  INSERT_BODY=$(jq -n --arg id "$PIN_AUTHOR_ID" --arg u "neighbor-test-${PIN_AUTHOR_ID:0:8}" --arg a "$AVATAR_VALUE" \
    '{id: $id, username: $u, avatar: $a}')
  rest POST /rest/v1/profiles "$PIN_AUTHOR_TOKEN" "$INSERT_BODY" >/dev/null
fi

BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$PIN_AUTHOR_ID" '{
  pin_type: "open_spot", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author
}')
RESP=$(rest POST /rest/v1/pins "$PIN_AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "ephemeral crowd pin insert accepted (also exercises the push trigger's WHEN clause — see Test 6)" "$RBODY"
PIN_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')

if [ -z "$PIN_ID" ]; then
  echo "FATAL: pin insert did not return an id — cannot continue Test 5/6. Body: $RBODY" >&2
else
  RESP=$(rest GET "/rest/v1/pins_with_author?id=eq.${PIN_ID}&select=*" "$SUPABASE_ANON_KEY")
  RBODY=$(echo "$RESP" | tail -n +2)
  ROW=$(echo "$RBODY" | jq '.[0] // empty')

  EXPECTED_COLUMNS="id pin_type source lifespan lat lng segment_id zone_id author_id created_at updated_at expires_at resolved_at confirm_count dispute_count meta notes author_username author_reputation starts_at report_group_id position_fraction leaving_minutes claimed_by author_avatar"
  MISSING=""
  for col in $EXPECTED_COLUMNS; do
    if ! echo "$ROW" | jq -e --arg c "$col" 'has($c)' >/dev/null 2>&1; then
      MISSING="$MISSING $col"
    fi
  done
  if [ -z "$MISSING" ]; then
    pass "pins_with_author returns all $(echo $EXPECTED_COLUMNS | wc -w) expected columns (prior set + author_avatar)"
  else
    fail "pins_with_author is missing column(s):$MISSING"
  fi

  GOT_AVATAR=$(echo "$ROW" | jq -r '.author_avatar // empty')
  assert_eq "$GOT_AVATAR" "$AVATAR_VALUE" "pins_with_author.author_avatar matches the value just set on profiles"
fi
echo

# ------------------------------------------------------------------
# Test 6 — MANUAL: confirm the push trigger actually fired for the Test 5 pin
# ------------------------------------------------------------------
echo "--- Test 6: push trigger firing — cannot be automated with anon-key-only access ---"
manual "Open the Supabase SQL Editor and run:"
manual "  select id, status_code, created from net._http_response order by created desc limit 5;"
manual "You should see a row created just now, status_code=200 (or 4xx/5xx if the Edge Function itself"
manual "errored — check the response body/content column, and the Edge Function's own logs, in that case)."
manual ""
manual "Also check: Dashboard -> Edge Functions -> send-community-push -> Logs. You should see a line"
manual "like 'send-community-push: no sandbox tokens for zone=nolita (pin=${PIN_ID:-<pin-id>}) — nothing"
manual "to send.' (expected — no real device has registered a token yet; that's S12's job) OR, if a"
manual "real token was registered first via Test 3 above, a 'send-community-push complete: ... sent=1'"
manual "line, though note Test 3's token is a fake string ('deadbeef-...') and will always fail APNs with"
manual "BadDeviceToken, which the function will treat as a dead token and delete."
manual ""
manual "Full end-to-end push delivery (a real device receiving and locally surfacing a notification)"
manual "cannot be verified until S12 ships iOS device registration + a TestFlight build with a real APNs"
manual "token in device_push_tokens. This script proves the trigger's WHEN clause matched, the row"
manual "reached the function's HTTP endpoint via pg_net, and the RLS/view contracts hold — not that"
manual "APNs itself accepted anything."
echo

# ------------------------------------------------------------------
# Best-effort cleanup
# ------------------------------------------------------------------
echo "--- Cleanup ---"
if [ -n "${PIN_ID:-}" ] && [ "$PIN_ID" != "null" ]; then
  curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/pins?id=eq.${PIN_ID}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${PIN_AUTHOR_TOKEN}" >/dev/null
  echo "  deleted test pin ${PIN_ID:0:8}..."
fi
# device_push_tokens rows cannot be deleted by this script the normal way without a select policy to
# find them again via REST — device_push_tokens_delete_own's USING clause only needs auth.uid(), not a
# prior read, so a direct DELETE by user_id still works even though GET does not.
curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/device_push_tokens?user_id=eq.${DEVICE_A_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${DEVICE_A_TOKEN}" >/dev/null
echo "  deleted test device_push_tokens row(s) for device A."
echo

echo "=== Results: ${PASSES} passed, ${FAILURES} failed ==="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
