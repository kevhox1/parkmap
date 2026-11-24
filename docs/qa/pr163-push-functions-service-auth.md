# PR #163 QA: service-role bearer on send-community-push / send-regular-push (2026-11-23)

**Reviewed:** PR #163 `fix/push-functions-service-auth` at `f5a51d4c`, against QA finding #2 in docs/qa/regulars-07-09-prod-apply-gate.md
**Verdict:** DEPLOY-READY (conditional on the post-deploy probe below passing; roll back community if it returns 401)

## Summary
The diff is 4 files, +75/-0: a small helper plus 5 inserted lines in each function. Every legitimate caller sends exactly the Vault `service_role_key` as a Bearer token. No client calls either function. deno check and deno tests pass. The one residual risk is operational: the Vault value must byte-equal the runtime `SUPABASE_SERVICE_ROLE_KEY`. The probe verifies that.

## Checklist
- [x] (1) Callers: `internal.invoke_send_community_push` (04:153-157), `invoke_send_regular_push` (08:111-115) and `sweep_leaving_soon_zone_push` (09:290-293) each `net.http_post` with `'Authorization','Bearer ' || v_service_role_key`, read from `vault.decrypted_secrets where name='service_role_key'`. No other header variant. bearer() trims whitespace anyway.
- [x] (2) Ordering: the gate sits after the env read and the missing-URL/key 500 (server misconfig, not caller-dependent). It runs before the APNs-secret check, `req.json()`, createClient, DB and APNs. All failure modes (missing header, `Bearer` only, wrong scheme, wrong key, anon key, near-miss) return the same `401 {"error":"unauthorized"}`; covered by the unit test.
- [x] (3) safeEqual (handoff.ts:234) XORs the lengths into `diff` and loops to `max(len)` with `?? 0` padding, so there is no early exit on length. It is constant-time over the compared data. Absolute time still reflects the max length, which is acceptable. Send-handoff-push already uses the same primitive in prod.
- [x] (4) Success path: the diff to both index.ts files is the import plus 5 lines only. Nothing else changed.
- [x] (5) Clients: grep of ios/ and the PWA/index.html finds no caller. The only iOS hit is a doc comment (WeParkApp.swift:176). Other hits are SQL triggers, docs and test .sh scripts, which contain no direct function invocations (no `functions/v1` or `functions.supabase` in any *.sh), so none break.
- [x] (6) `deno check` is clean on send-community-push, send-regular-push and send-handoff-push. `deno test _shared/service_auth_test.ts _shared/handoff_test.ts`: 16 passed, 0 failed.
- [x] (7) Probe: see below.

## Findings
### Blocking
None.

### Significant
None.

### Minor
- **#1: key-format coupling.** The compare is opaque. If Vault holds a legacy JWT service key while the runtime injects `sb_secret_*` (or the reverse), community push (LIVE) would silently go 401. The pg_net failure is swallowed by design (fail-open), so users just stop getting pushes with no error. Run the probe immediately after deploy and keep Vault and the runtime secret in sync on rotation. Owner: orchestrator / `@backend-data` (runbook note).
- **#2: missing-secret case returns 500 before 401.** It fires only on server misconfig and leaks nothing sensitive. Info only.

### Out of scope
- `verify_jwt` stays on at the gateway, so the anon key passes the gateway and is then rejected by the new gate (intended layering).
- send-handoff-push was not re-reviewed.

## Post-deploy probe (no push, no app-data write)
With the correct key and body `{}`, community push returns **200 `{"error":"APNs secrets not configured","skipped":true}`** if APNs secrets are unset, otherwise **400 `{"error":"Missing pin in request body"}`**. Both happen before `createClient`, the token query or any APNs call, so nothing is sent. Regular push behaves identically. Anything other than 401 proves the Vault key matches the runtime key. The probe writes only a `net._http_response` row (pg_net's own log).

Query 1 (fire; note the returned id):
```sql
select net.http_post(
  url     := 'https://jiispshyqerscdoferaw.functions.supabase.co/send-community-push',
  headers := jsonb_build_object(
    'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='service_role_key'),
    'Content-Type','application/json'),
  body    := '{}'::jsonb
) as request_id;
```
Query 2 (wait a few seconds, substitute the id; PASS = status_code 200 or 400, FAIL = 401):
```sql
select id, status_code, content::text, error_msg, created
from net._http_response where id = <request_id>;
```
Repeat with `/send-regular-push` after that function is deployed.

Negative probe, which must return 401 `{"error":"unauthorized"}` (public anon key):
```
curl -sS -i -X POST https://jiispshyqerscdoferaw.functions.supabase.co/send-community-push \
  -H "Authorization: Bearer <ANON_KEY>" -H "apikey: <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"pin":{"id":"x","pin_type":"leaving_soon","source":"crowd","lifespan":"ephemeral","zone_id":"any"}}'
```
A request with no Authorization header also returns 401 (the gateway's own shape).

## What's working
Minimal, surgical diff reusing the proven bearer/safeEqual pair, uniform failure responses, and a good unit test (including `sb_secret_` keys, and an empty server key never authenticating).

## Re-review after rework (2026-11-24)

**Reviewed:** `fix/push-functions-service-auth` at `d18ba3a0`. **Verdict: DEPLOY-READY**, on the condition that all three functions are deployed WITH gateway verify_jwt (no `--no-verify-jwt`).

The earlier exact-compare verdict is superseded. The prod probe showed the Vault key is not byte-equal to the runtime key, so exact-compare would have 401'd every live community trigger.

### 1. Trusting the gateway
- No `supabase/config.toml` and no `verify_jwt` override exist in the repo, so the default (true) applies. Prod already has send-community-push and send-handoff-push at verify_jwt=true. The send-regular-push deploy must not pass `--no-verify-jwt`. Both the `service_auth.ts` header and README-handoff.md state this.
- Reaching role=service_role through a verify_jwt gateway needs a token signed with the project's secret. The anon key (role=anon) and user access tokens (role=authenticated) fail the role check. Users cannot alter claims without breaking the signature, so the gateway rejects them before our code runs.
- If verify_jwt were off, the role check is forgeable. That is documented and is the single point of failure. Never use `--no-verify-jwt`.
- Parsing, run against the real helper (copied from the branch into scratchpad):
  - Base64url without padding decodes correctly.
  - Duplicate `role` keys follow JSON.parse last-wins (`anon` then `service_role` returns true). This is not exploitable, because the token must already carry a valid signature.
  - Rejected: non-string role (array), a role-only JSON string payload, a 2-part token, `sb_publishable_*`, and a `ref` that doesn't match the URL host.
  - Accepted: no `ref` and no `iss` (matches the supabase-js legacy key shape), and the Vault-shaped claims (role, ref, iss=supabase).
  - Tolerating an absent `ref` or `iss` is acceptable because the signature check is the real control.
- New-style keys: with verify_jwt=true the gateway rejects non-JWT bearers ("Invalid JWT"), and `sb_publishable_*` is not a JWT. This is from my recall of gateway behavior and is not verified live. If one did reach our code, the helper rejects it: it isn't a 3-part JWT, and it only equals the env key if it is the secret key. `sb_secret_*` passes only by exact match.

### 2. Gate placement
- The gate runs before `req.json()`, `createClient` and any APNs work in all three functions:
  - community: gate at line 128, body at 150.
  - regular: gate at line 155, body at 177.
  - handoff: gate at line 62, body at 81, and also before the kill-switch check.
- Failures return the uniform `401 {"error":"unauthorized"}`.
- The success path diff is only the import and the gate call. `logAuthStartup` only logs.
- Minor: send-handoff-push still returns 405 for non-POST before the gate. That was already the case and leaks nothing.

### 3. send-handoff-push
- It now accepts the Vault JWT, which it previously 401'd. That is the intended fix.
- Nothing else loosened: the exact-match path is retained, and the 401 body shape is unchanged (`json()` and `unauthorizedResponse()` are equivalent).

### 4. Checks
- `deno check` passes on all three entrypoints.
- `deno test _shared/service_auth_test.ts _shared/handoff_test.ts`: 20 passed, 0 failed.

### 5. Post-deploy probe matrix
Use `<URL>=https://jiispshyqerscdoferaw.supabase.co/functions/v1/<fn>`, `V` = the Vault service_role_key, `A` = the anon key. Send `-X POST -H 'Content-Type: application/json' -d '{}'`.

| Function | Bearer | Expected |
|---|---|---|
| send-community-push | V | non-401. Expect 400 invalid/empty payload, or 200 skipped. It must not be 401, must send no push, and the `{}` body has no valid event. |
| send-community-push | A | 401. This is either the gateway shape or `{"error":"unauthorized"}`. Must not be 400 or 200. |
| send-regular-push | V | non-401 (400 invalid payload). No push. |
| send-regular-push | A | 401 |
| send-handoff-push | V | non-401. 200 `{"skipped":true,"reason":"disabled"}` if the kill switch is on, otherwise 400 invalid payload. No push. |
| send-handoff-push | A | 401 `{"error":"unauthorized"}` |

Also probe each function with no Authorization header (expect 401) and `Bearer garbage` (expect 401).

The pass criterion is "not 401 with V, 401 with A". Check the function logs for the `service auth = role-claim JWT` startup line and for zero APNs sends during probing.

If V returns 401 on any function, roll back immediately. In that case the key's claims differ from what was decoded, or the function was deployed with a stale build.
