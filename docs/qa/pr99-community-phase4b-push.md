# QA Report — PR #99: Community 2.0 Phase 4b backend (send-community-push), Pass 1

**Reviewed:** PR #99, branch `backend/community-phase4b-push` @ `995eb5f6`, base `main` @ `945613dd`,
against `docs/community-2.0-reconciliation-spec.md` §2.9 + §3 Phase 4, ground-truthed against
`supabase/03-community-2.0-schema.sql` and `supabase/02d-ingest-cron.sql`.
**Reviewer:** @qa-verifier (independent; did not build the feature). Date: 2026-09-01.
*(Filed by the orchestrator from the reviewer's final report — the reviewer's worktree was
auto-cleaned before the file landed; content below is the report verbatim.)*

**Verdict: 🔴 FIX-THEN-MERGE.** One blocking finding, proven live against a local Postgres instance
(not just read cold) — a small, mechanical fix. Everything else (privacy model, view recreation,
WHEN clause, dead-token cleanup scoping, JWT construction, deploy runbook) is solid and should ship
once the fix lands.

## Findings

**🔴 Blocking — #1: the Vault-secret read in `internal.invoke_send_community_push()` is NOT inside
the exception-handling block, so an error there aborts the pins INSERT — contradicting the PR's own
explicit fail-open guarantee.**
- Only the `net.http_post(...)` call is wrapped in `begin ... exception when others ... end;`. The
  preceding `select decrypted_secret into v_service_role_key from vault.decrypted_secrets ...` is
  unprotected. Any throw there (permissions, Vault hiccup — HANDOFF itself calls Vault "BETA" —
  locking, future schema change) propagates uncaught and aborts the whole triggering transaction.
- **Reproduced live**: local Postgres 16 fixture matching 01/02/03, PR's `04-community-push-trigger.sql`
  applied verbatim (minus `create extension pg_net`), then an ordinary crowd-pin INSERT →
  `ERROR: relation "vault.decrypted_secrets" does not exist` — the INSERT fails outright. In prod the
  relation exists, but the structural gap is identical, and the blast radius is not "no push sent" —
  it's the live, load-bearing crowd-reporting loop 500ing.
- Fix: move the Vault select + null-check inside the same (or an outer) `begin/exception when others`
  block, so any failure anywhere degrades to a logged skip.

**🟡 Significant — #2: HANDOFF.md's Gate-2 entry ("loaded into Edge Function secrets at S11")
reads as already-done on a cold read**, while this PR's runbook treats it as Step 1 to-do. Almost
certainly anticipatory phrasing, but it's the doc/reality-mismatch class this repo has been bitten
by. Recommendation: Kevin runs `supabase secrets list` before Step 1 rather than assuming either
state. *(Orchestrator: HANDOFF wording fixed same day.)*

**🟢 Minor — #3:** `04-community-push-trigger.sql` doesn't restate `create schema if not exists
internal;` (created by 02d), slightly overstating its clean-project re-runnability. Cheap optional fix.

## What's working (verified, not just asserted)

- **Privacy invariant holds.** APNs body is `{aps:{content-available:1}, pin_type, segment_id,
  pin_id, zone_id}` — no author_id, no lat/lng, no username. Token lookup pulls
  `id, apns_token, environment` by `zone_id`+`environment` only. Logging never prints a raw token or
  a location+user pair.
- **View recreation correct.** All 24 prior `pins_with_author` columns present in order,
  `author_avatar` appended, grant re-issued identically — the silent-drop bug class is not repeated.
- **`device_push_tokens.environment` exists** in the applied 03 schema — the APNS_ENV
  filter-and-host deviation is sound.
- **Trigger scope correct**: `source='crowd' and lifespan='ephemeral' and zone_id is not null`,
  AFTER INSERT only (claim_pin's UPDATE does not re-fire).
- **Dead-token deletion precisely scoped**: only 410 or 400+BadDeviceToken delete; transient
  errors (network, 403, 429, 500) never do.
- **JWT construction correct** (ES256, kid/iss/iat, P1363 signature), cached ~55 min per warm
  instance. **Missing-secrets behavior clean** (200 + skipped:true; pg_net is async fire-and-forget
  so function responses can never affect the INSERT).
- **TypeScript type-checks clean**; **SQL applied successfully on a live local Postgres 16 fixture**.
- **Test script honest** (MANUAL steps printed where anon-key can't verify; expected view columns
  match the real 25-column output). **Deploy runbook complete and correctly ordered**, with the
  multiline-`.p8`-via-`$(cat ...)` pattern avoiding the newline footgun; APNS_ENV sandbox default
  correct for the pre-S12 phase.

## Kevin's deploy ceremony checklist (run after the fix lands + PR merges)

1. `supabase secrets list --project-ref jiispshyqerscdoferaw` — resolve current secret state first
   (re-running `secrets set` is harmless; skipping on a wrong assumption is not).
2. Set the 4 `APNS_*` secrets per the PR's Step 1 (separate `$(cat ...)` call for the key).
3. `supabase functions deploy send-community-push` (or dashboard upload).
4. Apply `04-community-push-trigger.sql` — single paste, no enum two-step. "trigger already exists"
   NOTICE is expected/harmless.
5. Run `04-community-push-test.sh` — expect Tests 1–5 PASS.
6. MANUAL Test 6: SQL Editor → `select id, status_code, created from net._http_response order by
   created desc limit 5;` → fresh row, `status_code=200`. Also check Postgres logs for a
   `raise log` line (not an uncaught exception) around Test 5's insert.
7. Dashboard → Edge Functions → send-community-push → Logs → expect
   `no sandbox tokens for zone=nolita ... nothing to send` (no tokens exist until S12).
8. S12 reminder: `APNS_ENV` stays `sandbox` until the internal-TestFlight build ships real tokens;
   flipping to `production` early would filter out every sandbox-registered token.
