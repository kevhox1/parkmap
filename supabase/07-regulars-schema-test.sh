#!/usr/bin/env bash
# WePark Regulars network — S1 schema test script
# Spec: docs/regulars-network-spec.md §2.10 (test-script scope), §2.2-§2.7 (schema under test).
# Companion to supabase/07-regulars-schema.sql — run this AFTER Kevin applies that migration via the
# Supabase SQL Editor. Mirrors supabase/03-community-2.0-test.sh's structure (anonymous-session
# helpers, rest() wrapper, pass/fail/assert_* accounting) — same shape, new schema.
#
# NEVER applied/run by an agent — this is Kevin's task, same as every prior migration verification.
#
# Usage:
#   SUPABASE_URL=https://jiispshyqerscdoferaw.supabase.co \
#   SUPABASE_ANON_KEY=<anon key from Dashboard > Settings > API> \
#   ./supabase/07-regulars-schema-test.sh
#
# Never hardcode credentials in this file — both env vars are required and read at runtime only.
#
# Requires: curl, jq.
#
# This script creates real rows (regular_invites, regular_edges via RPC, regular_blocks, pins,
# pin_notes, regular_notices) via real anonymous auth sessions against whatever project SUPABASE_URL
# points at. Best-effort cleanup runs at the end via each row's own author/creator token. Anonymous
# auth users/profiles rows are left in place (harmless, and deleting auth.users needs the service-role
# key, which this script deliberately never touches — same convention as 03/04's test scripts).
#
# STATUS-CODE CONVENTION (established by this repo — see 03-community-2.0-test.sh Test 1 and
# docs/qa/pr90-ft2-delete-own-pin.md's F1 finding): PostgREST returns HTTP 401, not 403, when the
# ANON role is denied by row-level security or lacks a table/function privilege outright — a "you
# should authenticate" hint. An AUTHENTICATED role denied by RLS (or a raised 42501 from a trigger)
# gets 403. Every assertion below follows this convention explicitly rather than assuming either code
# universally.

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

# assert_empty_array BODY LABEL — RLS-filtered SELECT should return 200 + [], never an error.
assert_empty_array() {
  local body=$1 label=$2
  local len
  len=$(echo "$body" | jq 'if type == "array" then length else -1 end' 2>/dev/null || echo -1)
  if [ "$len" = "0" ]; then
    pass "$label (zero rows, RLS-filtered not errored)"
  else
    fail "$label (expected an empty array, got: $body)"
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

# rest_anon METHOD PATH [JSON_BODY] — same as rest(), but authenticates as the bare anon key (no user
# session at all), for the "truly unauthenticated" checks distinct from an authenticated-but-unrelated
# session.
rest_anon() {
  local method=$1 path=$2 body=${3:-}
  rest "$method" "$path" "$SUPABASE_ANON_KEY" "$body"
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

echo "=== WePark Regulars S1 schema test ==="
echo "Target: ${SUPABASE_URL}"
echo

TEST_LAT=40.7235
TEST_LNG=-73.9950
ZONE_ID=nolita

echo "--- Setting up anonymous test sessions ---"
new_session; A_TOKEN=$SESSION_TOKEN; A_ID=$SESSION_USER_ID   # invite creator, pin author, notice sender
new_session; B_TOKEN=$SESSION_TOKEN; B_ID=$SESSION_USER_ID   # redeemer, becomes A's Regular
new_session; C_TOKEN=$SESSION_TOKEN; C_ID=$SESSION_USER_ID   # never a Regular of A — negative control
new_session; D_TOKEN=$SESSION_TOKEN; D_ID=$SESSION_USER_ID   # blocker
new_session; E_TOKEN=$SESSION_TOKEN; E_ID=$SESSION_USER_ID   # blocked
new_session; H_TOKEN=$SESSION_TOKEN; H_ID=$SESSION_USER_ID   # rate-limit probe (isolated from other counts)
echo "  6 anonymous sessions created (A, B, C, D, E, H)."
echo

# ==================================================================
# Section 1 — anon cannot read anyone's edges/invites/notices
# ==================================================================
echo "--- Section 1: anon SELECT on every Regulars table returns 200 + [] (RLS-filtered, not errored) ---"
RESP=$(rest_anon GET "/rest/v1/regular_edges?select=*")
assert_status "$(echo "$RESP" | head -n1)" 200 "anon GET regular_edges status"
assert_empty_array "$(echo "$RESP" | tail -n +2)" "anon GET regular_edges body"

RESP=$(rest_anon GET "/rest/v1/regular_invites?select=*")
assert_status "$(echo "$RESP" | head -n1)" 200 "anon GET regular_invites status"
assert_empty_array "$(echo "$RESP" | tail -n +2)" "anon GET regular_invites body"

RESP=$(rest_anon GET "/rest/v1/regular_notices?select=*")
assert_status "$(echo "$RESP" | head -n1)" 200 "anon GET regular_notices status"
assert_empty_array "$(echo "$RESP" | tail -n +2)" "anon GET regular_notices body"

RESP=$(rest_anon GET "/rest/v1/regular_blocks?select=*")
assert_status "$(echo "$RESP" | head -n1)" 200 "anon GET regular_blocks status"
assert_empty_array "$(echo "$RESP" | tail -n +2)" "anon GET regular_blocks body"

RESP=$(rest_anon GET "/rest/v1/pin_notes?select=*")
assert_status "$(echo "$RESP" | head -n1)" 200 "anon GET pin_notes status"
assert_empty_array "$(echo "$RESP" | tail -n +2)" "anon GET pin_notes body"
echo

# ==================================================================
# Section 2 — anon cannot write to any Regulars table or call the RPC (401 — no session at all)
# ==================================================================
echo "--- Section 2: anon writes are rejected (expect HTTP 401 — no auth session, not merely an RLS row-filter) ---"
BODY=$(jq -n --arg by "$A_ID" '{created_by: $by}')
RESP=$(rest_anon POST /rest/v1/regular_invites "$BODY")
STATUS=$(echo "$RESP" | head -n1)
if [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
  pass "anon INSERT regular_invites rejected (HTTP $STATUS)"
else
  fail "anon INSERT regular_invites rejected (expected 401/403, got HTTP $STATUS — body: $(echo "$RESP" | tail -n +2))"
fi

RESP=$(rest_anon POST "/rest/v1/rpc/redeem_regular_invite" '{"p_token":"00000000-0000-0000-0000-000000000000"}')
STATUS=$(echo "$RESP" | head -n1)
if [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
  pass "anon RPC redeem_regular_invite rejected (HTTP $STATUS — no EXECUTE grant for anon)"
else
  fail "anon RPC redeem_regular_invite rejected (expected 401/403, got HTTP $STATUS — body: $(echo "$RESP" | tail -n +2))"
fi
echo

# ==================================================================
# Section 3 — an authenticated session cannot write regular_edges directly (403 — no policy for any
# client role; the ONLY writer is the RPC's SECURITY DEFINER context)
# ==================================================================
echo "--- Section 3: authenticated direct INSERT into regular_edges is rejected (expect HTTP 403 — no insert policy exists for any client role) ---"
BODY=$(jq -n --arg lo "$A_ID" --arg hi "$B_ID" '{low_user_id: $lo, high_user_id: $hi}')
RESP=$(rest POST /rest/v1/regular_edges "$A_TOKEN" "$BODY")
assert_status "$(echo "$RESP" | head -n1)" 403 "authenticated direct regular_edges insert rejected"
echo

# ==================================================================
# Section 4 — invite create/redeem happy path (also exercises INSERT...RETURNING + SELECT policy,
# the S11/PR#100 lesson, on regular_invites)
# ==================================================================
echo "--- Section 4: invite create -> redeem happy path ---"
BODY=$(jq -n --arg by "$A_ID" '{created_by: $by}')
RESP=$(rest POST /rest/v1/regular_invites "$A_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "A creates an invite (INSERT...RETURNING succeeds — SELECT policy satisfies the S11 lesson)"
INVITE1_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')
if [ -z "$INVITE1_ID" ]; then
  echo "FATAL: invite insert did not return an id — cannot continue dependent tests. Body: $RBODY" >&2
  exit 1
fi

RESP=$(rest POST /rest/v1/rpc/redeem_regular_invite "$B_TOKEN" "{\"p_token\":\"${INVITE1_ID}\"}")
STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 200 "B redeems A's invite (RPC call succeeds)"
OK=$(echo "$RBODY" | jq -r '.ok // empty')
REGULAR_ID=$(echo "$RBODY" | jq -r '.regular_id // empty')
assert_eq "$OK" "true" "redeem_regular_invite reports ok:true"
assert_eq "$REGULAR_ID" "$A_ID" "redeem_regular_invite reports regular_id = A (the inviter)"

# Edge visible from BOTH sides.
RESP=$(rest GET "/rest/v1/regular_edges?select=*" "$A_TOKEN")
COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
assert_eq "$COUNT" "1" "A sees exactly 1 regular_edges row after redemption"
RESP=$(rest GET "/rest/v1/regular_edges?select=*" "$B_TOKEN")
COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
assert_eq "$COUNT" "1" "B sees exactly 1 regular_edges row after redemption"
# C (never invited) still sees zero — cross-check that visibility isn't accidentally global.
RESP=$(rest GET "/rest/v1/regular_edges?select=*" "$C_TOKEN")
COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
assert_eq "$COUNT" "0" "C (uninvolved) sees zero regular_edges rows"
echo

# ==================================================================
# Section 5 — re-redeeming the same (now-used) token fails race-safely
# ==================================================================
echo "--- Section 5: re-redeeming an already-redeemed token returns ok:false, reason:expired_or_used ---"
RESP=$(rest POST /rest/v1/rpc/redeem_regular_invite "$C_TOKEN" "{\"p_token\":\"${INVITE1_ID}\"}")
STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 200 "second redemption attempt still a valid RPC call (rejection is a payload, not an HTTP error)"
OK=$(echo "$RBODY" | jq -r '.ok // empty')
REASON=$(echo "$RBODY" | jq -r '.reason // empty')
assert_eq "$OK" "false" "second redemption reports ok:false"
assert_eq "$REASON" "expired_or_used" "second redemption reason is expired_or_used"
echo

# ==================================================================
# Section 6 — self-redemption is rejected
# ==================================================================
echo "--- Section 6: creator cannot redeem their own invite (ok:false, reason:cannot_add_self) ---"
BODY=$(jq -n --arg by "$A_ID" '{created_by: $by}')
RESP=$(rest POST /rest/v1/regular_invites "$A_TOKEN" "$BODY")
INVITE2_ID=$(echo "$RESP" | tail -n +2 | jq -r '.[0].id // empty')
RESP=$(rest POST /rest/v1/rpc/redeem_regular_invite "$A_TOKEN" "{\"p_token\":\"${INVITE2_ID}\"}")
RBODY=$(echo "$RESP" | tail -n +2)
OK=$(echo "$RBODY" | jq -r '.ok // empty')
REASON=$(echo "$RBODY" | jq -r '.reason // empty')
assert_eq "$OK" "false" "self-redemption reports ok:false"
assert_eq "$REASON" "cannot_add_self" "self-redemption reason is cannot_add_self"
echo

# ==================================================================
# Section 7 — a block prevents redemption of a pre-existing invite between the same two users
# (also exercises regular_blocks INSERT...RETURNING, per Section 9 below)
# ==================================================================
echo "--- Section 7: blocking prevents redemption (ok:false, reason:blocked) ---"
BODY=$(jq -n --arg by "$D_ID" '{created_by: $by}')
RESP=$(rest POST /rest/v1/regular_invites "$D_TOKEN" "$BODY")
INVITE3_ID=$(echo "$RESP" | tail -n +2 | jq -r '.[0].id // empty')

BODY=$(jq -n --arg u "$D_ID" --arg b "$E_ID" '{user_id: $u, blocked_user_id: $b}')
RESP=$(rest POST /rest/v1/regular_blocks "$D_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "D blocks E (INSERT...RETURNING succeeds)"
BLOCK_COUNT=$(echo "$RBODY" | jq 'length')
assert_eq "$BLOCK_COUNT" "1" "regular_blocks insert returns exactly 1 row (RETURNING body present)"

RESP=$(rest POST /rest/v1/rpc/redeem_regular_invite "$E_TOKEN" "{\"p_token\":\"${INVITE3_ID}\"}")
RBODY=$(echo "$RESP" | tail -n +2)
OK=$(echo "$RBODY" | jq -r '.ok // empty')
REASON=$(echo "$RBODY" | jq -r '.reason // empty')
assert_eq "$OK" "false" "redemption after a block reports ok:false"
assert_eq "$REASON" "blocked" "redemption after a block reason is blocked"
echo

# ==================================================================
# Section 8 — regular_edges DELETE...RETURNING (S11/PR#100 lesson on the DELETE path specifically)
# ==================================================================
echo "--- Section 8: regular_edges DELETE...RETURNING succeeds for either party (S11 lesson, DELETE path) ---"
if [[ "$A_ID" < "$B_ID" ]]; then
  EDGE_LOW=$A_ID; EDGE_HIGH=$B_ID
else
  EDGE_LOW=$B_ID; EDGE_HIGH=$A_ID
fi
RESP=$(rest DELETE "/rest/v1/regular_edges?low_user_id=eq.${EDGE_LOW}&high_user_id=eq.${EDGE_HIGH}" "$A_TOKEN")
STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 200 "A deletes the A/B edge (DELETE...RETURNING succeeds, not a 42501 RLS error)"
DEL_COUNT=$(echo "$RBODY" | jq 'length')
assert_eq "$DEL_COUNT" "1" "regular_edges delete returns exactly 1 row (RETURNING body present)"
echo

# ==================================================================
# Section 9 — pin_notes: happy path + Regulars-visibility + the ownership trigger
# ==================================================================
echo "--- Section 9: pin_notes happy path, Regulars-only visibility, and the ownership trigger ---"
# Re-establish A/B as Regulars (Section 8 deleted the edge) so the visibility check below is real.
BODY=$(jq -n --arg by "$A_ID" '{created_by: $by}')
RESP=$(rest POST /rest/v1/regular_invites "$A_TOKEN" "$BODY")
INVITE4_ID=$(echo "$RESP" | tail -n +2 | jq -r '.[0].id // empty')
rest POST /rest/v1/rpc/redeem_regular_invite "$B_TOKEN" "{\"p_token\":\"${INVITE4_ID}\"}" >/dev/null

# A posts a leaving_soon pin (the only pin_type the ownership trigger accepts a note against).
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$A_ID" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author, leaving_minutes: 10
}')
RESP=$(rest POST /rest/v1/pins "$A_TOKEN" "$BODY")
A_PIN_ID=$(echo "$RESP" | tail -n +2 | jq -r '.[0].id // empty')
if [ -z "$A_PIN_ID" ]; then
  echo "FATAL: A's leaving_soon pin insert did not return an id — skipping Section 9's pin_notes tests." >&2
else
  BODY=$(jq -n --arg pin "$A_PIN_ID" --arg author "$A_ID" '{pin_id: $pin, author_id: $author, body: "front spot, plug is a little loose"}')
  RESP=$(rest POST /rest/v1/pin_notes "$A_TOKEN" "$BODY")
  STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
  assert_status "$STATUS" 201 "A attaches a pin_notes row to their own leaving_soon pin (INSERT...RETURNING succeeds)"
  NOTE_BODY=$(echo "$RBODY" | jq -r '.[0].body // empty')
  assert_eq "$NOTE_BODY" "front spot, plug is a little loose" "pin_notes INSERT...RETURNING returns the inserted body"

  # B (A's Regular) can see it; C (not A's Regular) cannot.
  RESP=$(rest GET "/rest/v1/pin_notes?pin_id=eq.${A_PIN_ID}&select=*" "$B_TOKEN")
  COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
  assert_eq "$COUNT" "1" "B (A's Regular) can read A's pin_notes row"
  RESP=$(rest GET "/rest/v1/pin_notes?pin_id=eq.${A_PIN_ID}&select=*" "$C_TOKEN")
  COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
  assert_eq "$COUNT" "0" "C (not A's Regular) sees zero rows for A's pin_notes (RLS-filtered, not errored)"

  # Mismatched author_id: D (an unrelated user, not the pin's author) tries to attach a note to A's
  # pin using their OWN uid as author_id — passes RLS (author_id = auth.uid()) but the ownership
  # trigger must reject it because D did not author this pin.
  BODY=$(jq -n --arg pin "$A_PIN_ID" --arg author "$D_ID" '{pin_id: $pin, author_id: $author, body: "not really my pin"}')
  RESP=$(rest POST /rest/v1/pin_notes "$D_TOKEN" "$BODY")
  STATUS=$(echo "$RESP" | head -n1)
  assert_status "$STATUS" 403 "D cannot attach a pin_notes row to A's pin even with author_id=D (ownership trigger rejects)"

  # Non-leaving_soon pin_type: A posts an open_spot pin, then tries to attach a note to it.
  BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$A_ID" '{
    pin_type: "open_spot", source: "crowd", lifespan: "ephemeral",
    lat: $lat, lng: $lng, zone_id: $zone, author_id: $author
  }')
  RESP=$(rest POST /rest/v1/pins "$A_TOKEN" "$BODY")
  A_OPEN_SPOT_ID=$(echo "$RESP" | tail -n +2 | jq -r '.[0].id // empty')
  if [ -n "$A_OPEN_SPOT_ID" ]; then
    BODY=$(jq -n --arg pin "$A_OPEN_SPOT_ID" --arg author "$A_ID" '{pin_id: $pin, author_id: $author, body: "should not be allowed"}')
    RESP=$(rest POST /rest/v1/pin_notes "$A_TOKEN" "$BODY")
    STATUS=$(echo "$RESP" | head -n1)
    assert_status "$STATUS" 403 "A cannot attach a pin_notes row to their own non-leaving_soon pin (ownership trigger rejects on pin_type)"
  fi
fi
echo

# ==================================================================
# Section 10 — regular_notices: happy path, Regulars-only visibility, RETURNING
# ==================================================================
echo "--- Section 10: regular_notices happy path + Regulars-only visibility ---"
BODY=$(jq -n '{body: "Moving my car"}')
RESP=$(rest POST /rest/v1/regular_notices "$A_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "A sends a regular_notices row (INSERT...RETURNING succeeds)"
NOTICE_ID=$(echo "$RBODY" | jq -r '.[0].id // empty')

RESP=$(rest GET "/rest/v1/regular_notices?id=eq.${NOTICE_ID}&select=*" "$B_TOKEN")
COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
assert_eq "$COUNT" "1" "B (A's Regular) can read A's regular_notices row"
RESP=$(rest GET "/rest/v1/regular_notices?id=eq.${NOTICE_ID}&select=*" "$C_TOKEN")
COUNT=$(echo "$RESP" | tail -n +2 | jq 'length')
assert_eq "$COUNT" "0" "C (not A's Regular) sees zero rows for A's regular_notices"
echo

# ==================================================================
# Section 11 — rate-limit rejection (regular_notice: 10/1h, isolated session H)
# ==================================================================
echo "--- Section 11: regular_notice rate limit rejects the 11th insert within the window ---"
RL_OK=true
for i in $(seq 1 10); do
  BODY=$(jq -n --arg b "notice $i" '{body: $b}')
  RESP=$(rest POST /rest/v1/regular_notices "$H_TOKEN" "$BODY")
  STATUS=$(echo "$RESP" | head -n1)
  if [ "$STATUS" != "201" ]; then
    RL_OK=false
    fail "regular_notice rate-limit setup: insert #$i expected 201, got $STATUS (body: $(echo "$RESP" | tail -n +2))"
    break
  fi
done
if [ "$RL_OK" = true ]; then
  pass "10 regular_notices inserts under the 10/1h cap all succeeded"
  BODY=$(jq -n '{body: "notice 11 — should be rejected"}')
  RESP=$(rest POST /rest/v1/regular_notices "$H_TOKEN" "$BODY")
  STATUS=$(echo "$RESP" | head -n1); RBODY=$(echo "$RESP" | tail -n +2)
  assert_status "$STATUS" 403 "11th regular_notices insert within the window is rejected (rate limit, 42501)"
fi
echo

# ------------------------------------------------------------------
# Best-effort cleanup
# ------------------------------------------------------------------
echo "--- Cleanup ---"
[ -n "${A_PIN_ID:-}" ] && curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/pins?id=eq.${A_PIN_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${A_TOKEN}" >/dev/null
[ -n "${A_OPEN_SPOT_ID:-}" ] && curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/pins?id=eq.${A_OPEN_SPOT_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${A_TOKEN}" >/dev/null
curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/regular_blocks?user_id=eq.${D_ID}&blocked_user_id=eq.${E_ID}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${D_TOKEN}" >/dev/null
echo "  best-effort cleanup complete (pins, regular_blocks). regular_invites/regular_edges/pin_notes/"
echo "  regular_notices rows are left in place — no delete policy for invites, and the others are"
echo "  low-value throwaway rows from anonymous test sessions, same convention as 03/04's scripts."
echo

echo "=== Results: ${PASSES} passed, ${FAILURES} failed ==="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
