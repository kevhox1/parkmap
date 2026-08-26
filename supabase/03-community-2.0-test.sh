#!/usr/bin/env bash
# WePark Community 2.0 — Phase 0 schema test script
# Spec: docs/community-2.0-reconciliation-spec.md §2.13
# Companion to supabase/03-community-2.0-schema.sql — run this AFTER Kevin applies that migration
# (both STEP 1 and STEP 2) via the Supabase SQL Editor.
#
# NEVER applied/run by an agent — this is Kevin's task, same as every prior migration verification
# (mirrors the "curl /auth/v1/signup" smoke already used to diagnose the anonymous-auth gap,
# HANDOFF 2026-06-06).
#
# Usage:
#   SUPABASE_URL=https://jiispshyqerscdoferaw.supabase.co \
#   SUPABASE_ANON_KEY=<anon key from Dashboard > Settings > API> \
#   ./supabase/03-community-2.0-test.sh
#
# Never hardcode credentials in this file — both env vars are required and read at runtime only.
#
# Requires: curl, jq, python3 (for ISO8601 timestamp math — portable across macOS/Linux, unlike
# `date -d`/`date -j` which differ between BSD and GNU date).
#
# This script creates real rows (pins, votes, profiles) via real anonymous auth sessions against
# whatever project SUPABASE_URL points at. It does best-effort cleanup of the pins it creates at the
# end (via each pin's own author token, using the existing pins_delete_own policy) but does NOT
# delete the throwaway anonymous auth users or their profiles rows — those are harmless, low-value
# rows and deleting auth.users requires the service-role key, which this script deliberately never
# touches (anon-key-only, per HANDOFF's established test pattern).

set -uo pipefail

FAILURES=0
PASSES=0

# ------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------
: "${SUPABASE_URL:?Set SUPABASE_URL, e.g. https://jiispshyqerscdoferaw.supabase.co}"
: "${SUPABASE_ANON_KEY:?Set SUPABASE_ANON_KEY to this project anon/public API key}"

for bin in curl jq python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "FATAL: required tool '$bin' not found on PATH." >&2
    exit 1
  fi
done

SUPABASE_URL="${SUPABASE_URL%/}"

pass() { PASSES=$((PASSES + 1)); echo "  PASS: $1"; }
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

to_epoch() {
  # Parses an ISO8601 timestamp (with or without fractional seconds, 'Z' or '+00:00') to unix epoch.
  python3 -c "
import sys, datetime
s = sys.argv[1].replace('Z', '+00:00')
print(int(datetime.datetime.fromisoformat(s).timestamp()))
" "$1"
}

now_epoch() { date -u +%s; }

# assert_close SECONDS_DIFF TOLERANCE LABEL
assert_close() {
  local diff=$1 tol=$2 label=$3
  local abs=${diff#-}
  if [ "$abs" -le "$tol" ]; then
    pass "$label (delta ${diff}s, tolerance ${tol}s)"
  else
    fail "$label (delta ${diff}s EXCEEDS tolerance ${tol}s)"
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

# assert_status ACTUAL_STATUS EXPECTED_STATUS LABEL BODY
assert_status() {
  if [ "$1" = "$2" ]; then
    pass "$3 (HTTP $1)"
  else
    fail "$3 (expected HTTP $2, got HTTP $1 — body: $4)"
  fi
}

# ------------------------------------------------------------------
# HTTP helpers
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

echo "=== WePark Community 2.0 Phase 0 schema test ==="
echo "Target: ${SUPABASE_URL}"
echo

# Coordinates inside the seeded 'nolita' zone box (§2.3: lat 40.7217-40.7256, lng -73.9967--73.9930).
TEST_LAT=40.7235
TEST_LNG=-73.9950
ZONE_ID=nolita

# ------------------------------------------------------------------
# Test 1 — anonymous (unauthenticated) open_spot insert -> expect 403
# ------------------------------------------------------------------
echo "--- Test 1: anonymous open_spot insert (expect 403) ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" '{
  pin_type: "open_spot", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone
}')
RESP=$(rest POST /rest/v1/pins "$SUPABASE_ANON_KEY" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 403 "anonymous open_spot insert rejected" "$RBODY"
echo

# ------------------------------------------------------------------
# Set up sessions used across the remaining tests.
# ------------------------------------------------------------------
echo "--- Setting up anonymous test sessions ---"
new_session; AUTHOR_TOKEN=$SESSION_TOKEN; AUTHOR_ID=$SESSION_USER_ID
new_session; CONFIRM_VOTER_TOKEN=$SESSION_TOKEN; CONFIRM_VOTER_ID=$SESSION_USER_ID
new_session; DISPUTE_VOTER_1_TOKEN=$SESSION_TOKEN; DISPUTE_VOTER_1_ID=$SESSION_USER_ID
new_session; DISPUTE_VOTER_2_TOKEN=$SESSION_TOKEN; DISPUTE_VOTER_2_ID=$SESSION_USER_ID
new_session; DISPUTE_VOTER_3_TOKEN=$SESSION_TOKEN; DISPUTE_VOTER_3_ID=$SESSION_USER_ID
new_session; CLAIMANT_1_TOKEN=$SESSION_TOKEN; CLAIMANT_1_ID=$SESSION_USER_ID
new_session; CLAIMANT_2_TOKEN=$SESSION_TOKEN; CLAIMANT_2_ID=$SESSION_USER_ID
new_session; LEAVING_AUTHOR_TOKEN=$SESSION_TOKEN; LEAVING_AUTHOR_ID=$SESSION_USER_ID
echo "  8 anonymous sessions created."
echo

# ------------------------------------------------------------------
# Test 2 — authenticated open_spot insert -> expect 201, server-derived expires_at ~= now+3m
# regardless of a deliberately bogus client-supplied expires_at.
# ------------------------------------------------------------------
echo "--- Test 2: authenticated open_spot insert, tampered expires_at (expect 201, expires_at ~ now+3m) ---"
BOGUS_EXPIRES=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=30)).isoformat())")
BEFORE=$(now_epoch)
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" \
  --arg author "$AUTHOR_ID" --arg bogus "$BOGUS_EXPIRES" '{
  pin_type: "open_spot", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
  expires_at: $bogus
}')
RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "authenticated open_spot insert accepted" "$RBODY"
OPEN_SPOT_PIN_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')
OPEN_SPOT_EXPIRES=$(echo "$RBODY" | jq -r '.[0].expires_at // empty')
if [ -z "$OPEN_SPOT_PIN_ID" ]; then
  echo "FATAL: open_spot pin insert did not return an id — cannot continue dependent tests. Body: $RBODY" >&2
  exit 1
fi
if [ -n "$OPEN_SPOT_EXPIRES" ]; then
  EXP_EPOCH=$(to_epoch "$OPEN_SPOT_EXPIRES")
  DIFF=$((EXP_EPOCH - BEFORE - 180))
  assert_close "$DIFF" 30 "open_spot expires_at ~= insert-time + 3 minutes (server-derived, ignoring client's +30d payload)"
else
  fail "open_spot response missing expires_at"
fi
echo

# ------------------------------------------------------------------
# Test 3 — confirm-vote gives the CONFIRMER +2 rep and +1 helped_count
# ------------------------------------------------------------------
echo "--- Test 3: confirm vote awards confirmer +2 rep / +1 helped_count ---"
BODY=$(jq -n --arg pin "$OPEN_SPOT_PIN_ID" --arg user "$CONFIRM_VOTER_ID" '{
  pin_id: $pin, user_id: $user, vote: "confirm"
}')
RESP=$(rest POST /rest/v1/votes "$CONFIRM_VOTER_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "confirm vote insert accepted" "$RBODY"

RESP=$(rest GET "/rest/v1/profiles?id=eq.${CONFIRM_VOTER_ID}&select=reputation,helped_count" "$SUPABASE_ANON_KEY")
RBODY=$(echo "$RESP" | tail -n +2)
REP=$(echo "$RBODY" | jq -r '.[0].reputation // empty')
HELPED=$(echo "$RBODY" | jq -r '.[0].helped_count // empty')
assert_eq "$REP" "2" "confirmer profiles.reputation is +2 from a zero baseline"
assert_eq "$HELPED" "1" "confirmer profiles.helped_count is +1 from a zero baseline"
echo

# ------------------------------------------------------------------
# Test 4 — 3 disputes from 3 distinct sessions -> resolved_at set (existing auto_resolve_on_dispute)
# ------------------------------------------------------------------
echo "--- Test 4: 3 disputes from 3 distinct sessions set resolved_at ---"
for entry in "$DISPUTE_VOTER_1_TOKEN:$DISPUTE_VOTER_1_ID" "$DISPUTE_VOTER_2_TOKEN:$DISPUTE_VOTER_2_ID" "$DISPUTE_VOTER_3_TOKEN:$DISPUTE_VOTER_3_ID"; do
  TOK=${entry%%:*}
  UID_=${entry##*:}
  BODY=$(jq -n --arg pin "$OPEN_SPOT_PIN_ID" --arg user "$UID_" '{pin_id: $pin, user_id: $user, vote: "dispute"}')
  RESP=$(rest POST /rest/v1/votes "$TOK" "$BODY")
  STATUS=$(echo "$RESP" | head -n1)
  RBODY=$(echo "$RESP" | tail -n +2)
  assert_status "$STATUS" 201 "dispute vote insert accepted (user ${UID_:0:8})" "$RBODY"
done

RESP=$(rest GET "/rest/v1/pins?id=eq.${OPEN_SPOT_PIN_ID}&select=resolved_at,dispute_count" "$SUPABASE_ANON_KEY")
RBODY=$(echo "$RESP" | tail -n +2)
RESOLVED_AT=$(echo "$RBODY" | jq -r '.[0].resolved_at // empty')
DISPUTE_COUNT=$(echo "$RBODY" | jq -r '.[0].dispute_count // empty')
if [ -n "$RESOLVED_AT" ] && [ "$RESOLVED_AT" != "null" ]; then
  pass "pin resolved_at set after 3rd dispute (dispute_count=$DISPUTE_COUNT)"
else
  fail "pin resolved_at NOT set after 3 disputes (dispute_count=$DISPUTE_COUNT)"
fi
echo

# ------------------------------------------------------------------
# Test 5 — claim_pin: first caller true, second caller false
# ------------------------------------------------------------------
echo "--- Test 5: claim_pin returns true then false ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" \
  --arg author "$LEAVING_AUTHOR_ID" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author, leaving_minutes: 10
}')
RESP=$(rest POST /rest/v1/pins "$LEAVING_AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "leaving_soon pin insert accepted (for claim_pin test)" "$RBODY"
CLAIM_PIN_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')

if [ -n "$CLAIM_PIN_ID" ]; then
  RESP=$(rest POST /rest/v1/rpc/claim_pin "$CLAIMANT_1_TOKEN" "{\"p_pin_id\":\"${CLAIM_PIN_ID}\"}")
  RBODY=$(echo "$RESP" | tail -n +2)
  RESULT1=$(echo "$RBODY" | jq -r '.')
  assert_eq "$RESULT1" "true" "first claim_pin call wins"

  RESP=$(rest POST /rest/v1/rpc/claim_pin "$CLAIMANT_2_TOKEN" "{\"p_pin_id\":\"${CLAIM_PIN_ID}\"}")
  RBODY=$(echo "$RESP" | tail -n +2)
  RESULT2=$(echo "$RBODY" | jq -r '.')
  assert_eq "$RESULT2" "false" "second claim_pin call loses (someone beat you to it)"
else
  fail "leaving_soon pin (claim test) did not return an id — skipped claim_pin assertions"
fi
echo

# ------------------------------------------------------------------
# Test 6 — leaving_soon with leaving_minutes=20 -> expires_at ~= now+23m, not client-controllable
# ------------------------------------------------------------------
echo "--- Test 6: leaving_soon leaving_minutes=20 -> expires_at ~= now+23m ---"
BOGUS_EXPIRES=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).isoformat())")
BEFORE=$(now_epoch)
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" \
  --arg author "$LEAVING_AUTHOR_ID" --arg bogus "$BOGUS_EXPIRES" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
  leaving_minutes: 20, expires_at: $bogus
}')
RESP=$(rest POST /rest/v1/pins "$LEAVING_AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "leaving_soon (20min) insert accepted" "$RBODY"
LEAVING20_PIN_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')
LEAVING20_EXPIRES=$(echo "$RBODY" | jq -r '.[0].expires_at // empty')
if [ -n "$LEAVING20_EXPIRES" ]; then
  EXP_EPOCH=$(to_epoch "$LEAVING20_EXPIRES")
  DIFF=$((EXP_EPOCH - BEFORE - 23 * 60))
  assert_close "$DIFF" 30 "leaving_soon(20) expires_at ~= insert-time + 23 minutes (server-derived, ignoring client's +1d payload)"
else
  fail "leaving_soon(20) response missing expires_at"
fi
echo

# ------------------------------------------------------------------
# Best-effort cleanup — delete the pins this script created, via each author's own token
# (pins_delete_own policy). Anonymous auth users/profiles are left in place (harmless, and
# deleting auth.users needs the service-role key, which this script never touches).
# ------------------------------------------------------------------
echo "--- Cleanup ---"
for entry in "$OPEN_SPOT_PIN_ID:$AUTHOR_TOKEN" "$CLAIM_PIN_ID:$LEAVING_AUTHOR_TOKEN" "$LEAVING20_PIN_ID:$LEAVING_AUTHOR_TOKEN"; do
  PID=${entry%%:*}
  TOK=${entry##*:}
  if [ -n "$PID" ] && [ "$PID" != "null" ]; then
    curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/pins?id=eq.${PID}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H "Authorization: Bearer ${TOK}" >/dev/null
    echo "  deleted test pin ${PID:0:8}..."
  fi
done
echo

echo "=== Results: ${PASSES} passed, ${FAILURES} failed ==="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
