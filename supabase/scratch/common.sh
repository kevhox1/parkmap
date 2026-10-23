#!/usr/bin/env bash
# Shared helpers for the scratch-Postgres migration tests (10-account-deletion-test.sh,
# 11-coverage-requests-test.sh). SOURCED, not executed.
#
# These tests run against a THROWAWAY local Postgres 16 — never a Supabase project, never production.
# Connection comes from the standard libpq env (PGHOST / PGPORT / PGUSER / PGPASSWORD); the connecting
# role must be able to CREATE DATABASE and be a superuser (the tests impersonate `anon` and
# `authenticated` with SET ROLE, exactly as PostgREST does, and set request.jwt.claim.sub as the JWT sub).
#
# Each test creates its own fresh database `wepark_<name>_<pid>` and drops it on exit.

export PGOPTIONS="${PGOPTIONS:--c client_min_messages=error}"
SUPABASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSES=0
FAILURES=0

pass() { PASSES=$((PASSES + 1)); echo "  PASS: $1"; }
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

# check LABEL ACTUAL EXPECTED
check() {
  if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1 (expected '$3', got '$2')"; fi
}
# check_err LABEL OUTPUT EXPECTED_SQLSTATE  — OUTPUT is combined stdout+stderr from sql_as with VERBOSITY=verbose
check_err() {
  if printf '%s' "$2" | grep -q "ERROR:  $3:"; then pass "$1 (SQLSTATE $3)"; else fail "$1 (expected SQLSTATE $3, got: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-240))"; fi
}
check_ok() {
  if printf '%s' "$2" | grep -q "ERROR:"; then fail "$1 (unexpected error: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-240))"; else pass "$1"; fi
}

# sql DB SQL — run as the connecting superuser; prints tuples only (unaligned, no headers).
sql() { printf '%s\n' "$2" | psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$1" 2>&1; }

# sql_as DB ROLE UID SQL — run as ROLE (anon|authenticated) with JWT sub = UID (empty = no JWT), one
# session per call. Errors are NOT fatal and are printed with SQLSTATE (VERBOSITY=verbose).
sql_as() {
  local db=$1 role=$2 uid=$3 stmt=$4
  printf '%s\n' "\\set VERBOSITY verbose
select set_config('request.jwt.claim.sub', '${uid}', false) \\g /dev/null
set role ${role};
${stmt}" | psql -X -q -t -A -d "$db" 2>&1
}

# scratch_create_db NAME -> sets DB, installs the stub, applies migrations 01-06 verbatim.
scratch_create_db() {
  DB="wepark_${1}_$$"
  psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "create database \"$DB\"" || { echo "FATAL: cannot create database"; exit 1; }
  trap 'psql -X -q -d postgres -c "drop database if exists \"'"$DB"'\" with (force)" >/dev/null 2>&1' EXIT
  psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$SUPABASE_DIR/scratch/00-supabase-stub.sql" >/dev/null || { echo "FATAL: stub failed"; exit 1; }
  local f
  for f in 01-mvp-schema 02-pins-schema 02b-pins-ingest-indexes 02c-asp-seed 02d-ingest-cron \
           02e-auto-resolve-trigger 02f-block-scoped-restrictions 02g-ingest-runs \
           03-community-2.0-schema 04-community-push-trigger 05-device-push-tokens-rls-fix 06-manhattan-zones; do
    # pg_cron / pg_net are not installable in the scratch cluster; the stub schemas stand in for them.
    sed -E 's/^create extension if not exists (pg_cron|pg_net);/-- [scratch] skipped: &/' "$SUPABASE_DIR/$f.sql" \
      | psql -X -q -d "$DB" -v ON_ERROR_STOP=1 >/dev/null 2>"/tmp/scratch_apply_$$.err" \
      || { echo "FATAL: applying $f.sql failed:"; cat "/tmp/scratch_apply_$$.err"; exit 1; }
  done
  rm -f "/tmp/scratch_apply_$$.err"
}

# apply_file FILE — apply a migration verbatim (stdout/stderr visible on failure); echoes "ok" or the error.
apply_file() {
  psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$SUPABASE_DIR/$1" 2>&1 >/dev/null && echo ok
}

# new_user DB [anon:true|false] -> prints a fresh auth.users id
new_user() { sql "$DB" "insert into auth.users (email, is_anonymous) values ('u'||gen_random_uuid()||'@example.test', ${1:-false}) returning id;"; }

finish() {
  echo
  echo "RESULT: ${PASSES} passed, ${FAILURES} failed"
  [ "$FAILURES" -eq 0 ]
}
