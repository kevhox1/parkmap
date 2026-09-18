#!/usr/bin/env bash
# WePark Regulars network — S1-follow-up zone-push-delay test script
# Spec: docs/regulars-network-spec.md §2.8. Companion to supabase/09-regulars-zone-push-delay.sql —
# run this AFTER Kevin has applied, IN ORDER:
#   1. supabase/07-regulars-schema.sql (pins.regulars_head_start_seconds / pins.zone_pushed_at)
#   2. supabase/09-regulars-zone-push-delay.sql (THIS file's companion — the 04 WHEN-clause rewrite +
#      sweep_leaving_soon_zone_push() + its 30-second cron job)
# Do NOT apply supabase/08-regulars-push-trigger.sql or deploy send-regular-push before running this
# script — this script is specifically about proving 09 works correctly BEFORE 08 (the visible
# Regulars push) ever goes live, per this file's own apply-order reasoning.
#
# NEVER applied/run by an agent — this is Kevin's task, same as every prior migration verification.
#
# Usage:
#   SUPABASE_URL=https://jiispshyqerscdoferaw.supabase.co \
#   SUPABASE_ANON_KEY=<anon key from Dashboard > Settings > API> \
#   ./supabase/09-regulars-zone-push-delay-test.sh
#
# Never hardcode credentials in this file — both env vars are required and read at runtime only.
#
# RUNTIME WARNING: this script is slow by necessity — the feature it tests has a 60-second minimum
# head start (the server clamp floor, spec §2.1) and a 30-second sweep cadence, so proving the delay
# and the "second sweep run is a no-op" property requires real wall-clock waiting, not a mock clock.
# Expect ~2-3 minutes for Tests 1-4. Test 6 (honest-exclusivity / "skip forever") additionally waits
# for a real pin to expire (~8 minutes, leaving_minutes=5 + the existing derive_pin_expiry() +3-minute
# grace, 03-community-2.0-schema.sql) — set RUN_SLOW_EXPIRY_TEST=false to skip it for a faster iteration
# loop; it is NOT skipped by default because it is the sharpest proof of the honest-exclusivity ruling
# (spec §1.2a, §0 decision 8) and the one property that is easiest to get subtly wrong.
#
# What this script CAN verify with anon-key-only access (all of Tests 1-5 are FULLY automated — this
# is a meaningfully stronger position than 04/08's own test scripts, because pins_with_author already
# exposes zone_pushed_at as a plain, pollable column — no SQL-Editor-only access is needed to observe
# the delay/no-op/never-pushed properties themselves):
#   - A leaving_soon pin posted WITH a head start does NOT have zone_pushed_at set immediately (Test 1).
#   - The SAME pin DOES have zone_pushed_at set once its head start has elapsed and at least one sweep
#     tick has run (Test 2) — the delay is real, not just documented.
#   - A SECOND sweep tick after that leaves zone_pushed_at unchanged (Test 3) — the no-double-push
#     property holds, not just by inspection of SKIP LOCKED's reasoning but by direct observation.
#   - A leaving_soon pin posted WITHOUT a head start keeps zone_pushed_at null FOREVER (never becomes
#     the sweep's job) even after multiple sweep ticks have run (Test 4) — confirms the scope note in
#     09's own header (null-head-start pins are the immediate trigger's job, not the sweep's).
#   - An open_spot pin is entirely unaffected (Test 5).
#   - A leaving_soon pin whose OWN expiry (leaving_minutes=5, ~8 min) arrives before its head start
#     (regulars_head_start_seconds=3600, 60 min) NEVER gets zone_pushed_at set, even well past its own
#     expiry and many sweep ticks later (Test 6, optional/slow) — the honest-exclusivity "skip forever"
#     behavior, observed directly rather than just reasoned about.
#
# What this script CANNOT verify with anon-key-only access (same limitation 04/08's own scripts
# document, printed as MANUAL steps instead of silently skipped):
#   - That send-community-push's HTTP endpoint was actually reached at the RIGHT time (net._http_response
#     and cron.job_run_details are SQL-Editor/Dashboard-only) — Tests 1-4's zone_pushed_at-based checks
#     are strong indirect evidence (that column has exactly one writer, sweep_leaving_soon_zone_push(),
#     which only stamps it immediately after attempting that exact HTTP call), but the direct log/response
#     confirmation is still a SQL Editor step, listed as MANUAL below.
#   - That the eventual visible Regulars push (send-regular-push, 08, a SEPARATE file) fires at the
#     correct instant relative to this delay — that is 08's own test script's job, and requires 08 to be
#     applied, which this script deliberately runs BEFORE.
#
# Requires: curl, jq.

set -uo pipefail

FAILURES=0
PASSES=0
RUN_SLOW_EXPIRY_TEST="${RUN_SLOW_EXPIRY_TEST:-true}"

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
# HTTP helpers (same shape as 04-community-push-test.sh / 08-regulars-push-trigger-test.sh)
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

# zone_pushed_at_of PIN_ID -> prints the value ("null" literal string if actually null/absent)
zone_pushed_at_of() {
  local pin_id=$1
  local resp body val
  resp=$(rest GET "/rest/v1/pins_with_author?id=eq.${pin_id}&select=zone_pushed_at" "$SUPABASE_ANON_KEY")
  body=$(echo "$resp" | tail -n +2)
  val=$(echo "$body" | jq -r '.[0].zone_pushed_at // "null"')
  echo "$val"
}

echo "=== WePark Regulars S1-follow-up (zone-push-delay) test ==="
echo "Target: ${SUPABASE_URL}"
echo

# Coordinates inside the seeded 'nolita' zone box (03-community-2.0-schema.sql §2.3).
TEST_LAT=40.7235
TEST_LNG=-73.9950
ZONE_ID=nolita

echo "--- Setting up an anonymous test session ---"
new_session; AUTHOR_TOKEN=$SESSION_TOKEN; AUTHOR_ID=$SESSION_USER_ID
echo "  1 anonymous session created."
echo

# ------------------------------------------------------------------
# Test 1 — leaving_soon WITH a (minimum, 60s) head start: zone_pushed_at is NOT set immediately.
# ------------------------------------------------------------------
echo "--- Test 1: leaving_soon + regulars_head_start_seconds=60 insert -> zone_pushed_at null at insert ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$AUTHOR_ID" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
  leaving_minutes: 20, regulars_head_start_seconds: 60
}')
RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "leaving_soon pin insert (head start=60s) accepted" "$RBODY"
PIN_HEADSTART=$(echo "$RBODY" | jq -r '.[0].id // empty')

if [ -z "$PIN_HEADSTART" ]; then
  echo "FATAL: pin insert did not return an id — cannot continue Tests 1-3. Body: $RBODY" >&2
else
  ZP=$(zone_pushed_at_of "$PIN_HEADSTART")
  if [ "$ZP" = "null" ]; then
    pass "zone_pushed_at is null immediately after insert (head start not yet elapsed)"
  else
    fail "zone_pushed_at was already set immediately after insert (expected null, got $ZP) — the 04 WHEN-clause rewrite may not be applied, or is not taking effect"
  fi
fi
manual "To directly confirm send-community-push was NOT fired for pin ${PIN_HEADSTART:-<pin-id>} at insert"
manual "time (as opposed to inferring it from zone_pushed_at alone), run in the SQL Editor right now:"
manual "  select * from net._http_response order by created desc limit 5;"
manual "Expect ZERO rows referencing this pin's id in the body/timing — only a send-regular-push row if"
manual "08-regulars-push-trigger.sql happens to already be applied (it should not be yet, per this"
manual "script's own header)."
echo

# ------------------------------------------------------------------
# Test 2 — after the head start elapses AND at least one sweep tick runs, zone_pushed_at becomes set.
# ------------------------------------------------------------------
echo "--- Test 2: after ~95s (60s head start + margin for a 30s sweep tick), zone_pushed_at is set ---"
if [ -n "${PIN_HEADSTART:-}" ]; then
  echo "  Waiting 95s for the head start to elapse and the sweep to run (real wall-clock, no shortcuts)..."
  sleep 95
  ZP1=$(zone_pushed_at_of "$PIN_HEADSTART")
  if [ "$ZP1" != "null" ] && [ -n "$ZP1" ]; then
    pass "zone_pushed_at is now set ($ZP1) — the sweep fired the delayed push"
  else
    fail "zone_pushed_at is STILL null after 95s — either the cron job is not registered/running, or the sweep's WHERE clause is not matching this pin. Check: select * from cron.job where jobname = 'sweep-leaving-soon-zone-push'; and select * from cron.job_run_details order by start_time desc limit 5;"
  fi
fi
echo

# ------------------------------------------------------------------
# Test 3 — a second sweep tick (another ~35s later) leaves zone_pushed_at UNCHANGED — no double push.
# ------------------------------------------------------------------
echo "--- Test 3: a second sweep tick (35s later) does not re-stamp/re-push (no-op) ---"
if [ -n "${PIN_HEADSTART:-}" ] && [ "${ZP1:-null}" != "null" ]; then
  echo "  Waiting 35s for one more sweep tick..."
  sleep 35
  ZP2=$(zone_pushed_at_of "$PIN_HEADSTART")
  if [ "$ZP2" = "$ZP1" ]; then
    pass "zone_pushed_at unchanged across a second sweep tick ($ZP2) — confirmed no-op / no double push"
  else
    fail "zone_pushed_at CHANGED between sweep ticks (was $ZP1, now $ZP2) — the sweep may be re-processing already-pushed rows; the zone_pushed_at is null filter or the SKIP LOCKED race-safety may not be working as intended"
  fi
else
  echo "  Skipped (Test 2 did not produce a set zone_pushed_at to compare against)."
fi
echo

# ------------------------------------------------------------------
# Test 4 — leaving_soon WITHOUT a head start: zone_pushed_at stays null FOREVER (not the sweep's job;
# the unmodified immediate trigger already handled this pin at insert time, per the scope note in
# 09-regulars-zone-push-delay.sql's own header).
# ------------------------------------------------------------------
echo "--- Test 4: leaving_soon with NO head start -> immediate behavior, zone_pushed_at never set ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$AUTHOR_ID" '{
  pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
  leaving_minutes: 20
}')
RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "leaving_soon pin insert (no head start) accepted" "$RBODY"
PIN_NOHEADSTART=$(echo "$RBODY" | jq -r '.[0].id // empty')
if [ -n "$PIN_NOHEADSTART" ]; then
  ZP=$(zone_pushed_at_of "$PIN_NOHEADSTART")
  if [ "$ZP" = "null" ]; then
    pass "zone_pushed_at is null right after insert for a no-head-start pin (expected — immediate trigger handled it, not the sweep)"
  else
    fail "zone_pushed_at was unexpectedly non-null for a no-head-start pin (got $ZP)"
  fi
  echo "  Waiting 35s for a sweep tick, to confirm the sweep never touches this pin either..."
  sleep 35
  ZP=$(zone_pushed_at_of "$PIN_NOHEADSTART")
  if [ "$ZP" = "null" ]; then
    pass "zone_pushed_at is STILL null after a sweep tick — confirmed the sweep's WHERE clause correctly excludes null-head-start pins"
  else
    fail "zone_pushed_at became non-null after a sweep tick (got $ZP) — the sweep's regulars_head_start_seconds IS NOT NULL filter may be missing/broken"
  fi
fi
manual "To directly confirm send-community-push WAS fired immediately at insert for pin"
manual "${PIN_NOHEADSTART:-<pin-id>} (zero regression for the common, no-head-start case), check"
manual "net._http_response / the send-community-push Edge Function logs in the SQL Editor / Dashboard."
echo

# ------------------------------------------------------------------
# Test 5 — open_spot pin: entirely unaffected by this migration.
# ------------------------------------------------------------------
echo "--- Test 5: open_spot pin insert (unaffected by this migration) still succeeds (expect 201) ---"
BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$AUTHOR_ID" '{
  pin_type: "open_spot", source: "crowd", lifespan: "ephemeral",
  lat: $lat, lng: $lng, zone_id: $zone, author_id: $author
}')
RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
STATUS=$(echo "$RESP" | head -n1)
RBODY=$(echo "$RESP" | tail -n +2)
assert_status "$STATUS" 201 "open_spot pin insert accepted (unaffected by the WHEN-clause rewrite)" "$RBODY"
PIN_OPENSPOT=$(echo "$RBODY" | jq -r '.[0].id // empty')
echo

# ------------------------------------------------------------------
# Test 6 (SLOW, optional) — honest exclusivity: a pin whose OWN expiry (leaving_minutes=5, ~8 min via
# derive_pin_expiry()'s +3-minute grace) arrives before its head start (regulars_head_start_seconds=3600,
# 60 min) NEVER gets zone_pushed_at set, even well after its own expiry and several sweep ticks later.
# ------------------------------------------------------------------
if [ "$RUN_SLOW_EXPIRY_TEST" = "true" ]; then
  echo "--- Test 6 (slow, ~9 min): head-start-exceeds-departure -> skipped FOREVER, never zone-pushed ---"
  BODY=$(jq -n --argjson lat "$TEST_LAT" --argjson lng "$TEST_LNG" --arg zone "$ZONE_ID" --arg author "$AUTHOR_ID" '{
    pin_type: "leaving_soon", source: "crowd", lifespan: "ephemeral",
    lat: $lat, lng: $lng, zone_id: $zone, author_id: $author,
    leaving_minutes: 5, regulars_head_start_seconds: 3600
  }')
  RESP=$(rest POST /rest/v1/pins "$AUTHOR_TOKEN" "$BODY")
  STATUS=$(echo "$RESP" | head -n1)
  RBODY=$(echo "$RESP" | tail -n +2)
  assert_status "$STATUS" 201 "leaving_soon pin insert (leaving_minutes=5, head start=3600s) accepted" "$RBODY"
  PIN_EXPIRESFIRST=$(echo "$RBODY" | jq -r '.[0].id // empty')
  if [ -n "$PIN_EXPIRESFIRST" ]; then
    echo "  Waiting ~9 minutes for this pin's own expiry (leaving_minutes=5 + 3min grace = ~8min) to pass,"
    echo "  plus margin for a couple of sweep ticks after that..."
    sleep 540
    ZP=$(zone_pushed_at_of "$PIN_EXPIRESFIRST")
    if [ "$ZP" = "null" ]; then
      pass "zone_pushed_at is STILL null well past this pin's own expiry — honest-exclusivity 'skip forever' confirmed live"
    else
      fail "zone_pushed_at became non-null for a pin that should have expired before its head start elapsed (got $ZP) — the sweep's expires_at > now() filter may not be excluding already-expired rows"
    fi
  fi
  echo
else
  echo "--- Test 6 SKIPPED (RUN_SLOW_EXPIRY_TEST=false) ---"
  echo
fi

# ------------------------------------------------------------------
# Best-effort cleanup
# ------------------------------------------------------------------
echo "--- Cleanup ---"
for pid in "${PIN_HEADSTART:-}" "${PIN_NOHEADSTART:-}" "${PIN_OPENSPOT:-}" "${PIN_EXPIRESFIRST:-}"; do
  if [ -n "$pid" ] && [ "$pid" != "null" ]; then
    curl -sS -X DELETE "${SUPABASE_URL}/rest/v1/pins?id=eq.${pid}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H "Authorization: Bearer ${AUTHOR_TOKEN}" >/dev/null
  fi
done
echo "  deleted test pins."
echo

echo "=== Results: ${PASSES} passed, ${FAILURES} failed ==="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
