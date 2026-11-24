# Spot Pass backend — Kevin's apply / deploy / verify steps

Spec: `docs/specs/qr-spot-handoff.md` (Rev 2), sections 3, 8, 9, 10. Files are written only; **nothing here has been
applied or deployed.** Everything below is run by Kevin.

Replace `<PROJECT_REF>` with `jiispshyqerscdoferaw` and `<SERVICE_ROLE_KEY>` / `<ANON_KEY>` with the project keys
(never commit them).

## 0. What ships

| Piece | File |
|---|---|
| Migration (tables, RLS, RPCs, karma, sweep cron, flag, account-deletion extension) | `supabase/13-spot-handoffs.sql` |
| Scratch-Postgres test (182 checks) | `supabase/13-spot-handoffs-test.sh` |
| Public functions (anonymous-callable) | `handoff-peek`, `handoff-claim`, `handoff-depart`, `handoff-extend`, `handoff-cancel`, `handoff-report` (additive) |
| Push sender (service role only) | `send-handoff-push` |
| Shared | `_shared/handoff.ts`, `_shared/handoff_runtime.ts`, `_shared/handoff_push.ts`, `_shared/apns.ts` (type-only widening) |
| Deno unit tests | `deno test supabase/functions/_shared/handoff_test.ts` |

## 1. Apply order

1. **Prerequisites already in prod:** 01-06, **10-account-deletion.sql** (13 replaces `delete_my_account()`, so 10 must be there),
   Vault secret `service_role_key` (08 created the pattern; confirm: `select name from vault.decrypted_secrets;`),
   `pg_cron` and `pg_net` enabled (02d/08 already rely on them).
2. **SQL Editor:** paste `supabase/13-spot-handoffs.sql` and run. One paste, idempotent. The flag is seeded **off**.
   (If `create extension pg_cron` somehow fails the earlier statements are still the important part; re-run just the last
   two statements after enabling it.)
3. **Secrets** (Dashboard > Edge Functions > Secrets, or CLI). `send-handoff-push` reuses the existing APNs secrets
   (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_TOPIC` = the **app** bundle id `com.kevinhoxha.wepark`, `APNS_ENV`).
   Nothing new is required. Optional:
   ```
   supabase secrets set HANDOFF_IP_SALT=<random 32+ chars>          # salt for the IP hash (default: service key)
   supabase secrets set HANDOFF_ALLOWED_ORIGINS=https://getwepark.com   # CORS for the web fallback (default same)
   supabase secrets set HANDOFF_APP_URL=https://getwepark.com/p         # clip target-content-id (default same)
   supabase secrets set HANDOFF_EXTRA_TOPICS=                           # extra allowed claimer bundle ids
   ```
   `APNS_ENV` must match the build testers run (sandbox = debug builds, production = TestFlight/App Store); claimer
   tokens carry no environment of their own.
4. **Deploy the functions** (order does not matter; `supabase/functions/_shared` deploys with each):
   ```
   # public, anonymous-callable (QR scanners on the web fallback / clip have no session):
   supabase functions deploy handoff-peek    --no-verify-jwt
   supabase functions deploy handoff-claim   --no-verify-jwt
   supabase functions deploy handoff-depart  --no-verify-jwt
   supabase functions deploy handoff-extend  --no-verify-jwt
   supabase functions deploy handoff-cancel  --no-verify-jwt
   supabase functions deploy handoff-report  --no-verify-jwt
   # service-role only: keep default JWT verification AND it checks the bearer == service role key itself
   supabase functions deploy send-handoff-push
   ```
   `apns.ts` changed only by a **type** union; the already-deployed `send-community-push` / `send-regular-push` do not need
   a redeploy.
5. **Realtime:** do NOT add `spot_handoffs` to the `supabase_realtime` publication (it would stream whole rows including
   claimer tokens). The seeker app learns state from alert pushes + selecting its own row.
6. **Flip the flag when iOS/web are ready (default OFF):**
   ```sql
   update public.handoff_config set value = 'true'  where key = 'HANDOFF_ENABLED';   -- on
   update public.handoff_config set value = 'false' where key = 'HANDOFF_ENABLED';   -- kill switch (instant, all RPCs/functions)
   ```
   Emergency stop with no SQL: `supabase secrets set HANDOFF_ENABLED=false` makes every function answer 503 `{"error":"disabled"}`
   (unset it, or set `true`, to defer to the database flag again).
7. Lift a suspension by hand: `delete from public.handoff_suspensions where user_id = '<uuid>';`

## 2. Verification checklist (paste into the SQL editor / a terminal)

```sql
-- A. objects + posture (expect: false, cron row, anon_create=f authed_create=t authed_claim=f svc_claim=t, six rows relrowsecurity=t)
select key, value from public.handoff_config;
select jobname, schedule from cron.job where jobname = 'handoff-sweep';
select has_function_privilege('anon','public.create_handoff(boolean)','execute') anon_create,
       has_function_privilege('authenticated','public.create_handoff(boolean)','execute') authed_create,
       has_function_privilege('authenticated','public.handoff_claim(text,timestamptz,text,text,text,uuid,text)','execute') authed_claim,
       has_function_privilege('service_role','public.handoff_claim(text,timestamptz,text,text,text,uuid,text)','execute') svc_claim;
select relname, relrowsecurity from pg_class where relname in
  ('spot_handoffs','handoff_reports','handoff_suspensions','handoff_pair_log','handoff_rate_events','handoff_config');
```

```bash
B=https://<PROJECT_REF>.functions.supabase.co
# C. flag off => disabled (503), nothing leaks
curl -s -i -X POST $B/handoff-peek -d '{"token":"AAAAAAAAAAAAAAAAAAAAAA"}' | head -1          # HTTP/2 503
# D. flip HANDOFF_ENABLED to true (step 6), then: bad token => the single "unavailable" answer
curl -s -X POST $B/handoff-peek -d '{"token":"AAAAAAAAAAAAAAAAAAAAAA"}'                        # {"status":"unavailable"}
curl -s -X POST $B/handoff-peek -d '{"token":"nope"}'                                           # {"status":"unavailable"}
# E. depart without a secret never works
curl -s -X POST $B/handoff-depart -d '{"id":"00000000-0000-0000-0000-000000000000","claimer_secret":"AAAAAAAAAAAAAAAAAAAAAA","source":"manual"}'  # {"ok":false}
# F. 31st peek from one IP in an hour => HTTP 429 {"status":"unavailable"}
for i in $(seq 1 31); do curl -s -o /dev/null -w "%{http_code} " -X POST $B/handoff-peek -d '{"token":"AAAAAAAAAAAAAAAAAAAAAA"}'; done
# G. push sender rejects non-service callers (401)
curl -s -i -X POST $B/send-handoff-push -H "Authorization: Bearer <ANON_KEY>" -d '{"kind":"armed","handoff_id":"00000000-0000-0000-0000-000000000000"}' | head -1
```

End-to-end with two throwaway anonymous users (a TestFlight/debug build is the easiest seeker):
1. Seeker signs in anonymously, calls `create_handoff(false)` -> `{id, token, alias, glyph, expires_at}`.
2. `curl -X POST $B/handoff-peek -d '{"token":"<token>"}'` -> `open` + alias. Second user's access token:
   `curl -X POST $B/handoff-claim -H "Authorization: Bearer <user2 access token>" -d '{"token":"<token>","leave_at":"<now+10min ISO>"}'`
   -> `armed` + `claimer_secret`. Seeker device gets the `armed` alert; the same token now peeks as `unavailable`.
3. `handoff-depart {id, claimer_secret, source:"manual"}` -> `{ok:true}`, seeker gets the `departed` alert within ~10 s.
4. Seeker `confirm_handoff_outcome(id, 'got_spot')` -> `{ok:true, outcome:"got_spot", seeker_points:3}`; check
   `select reputation, helped_count from profiles where id in (...)` (driver +5 / helped +1). Repeat the call: no change.
5. Privacy spot check: `select * from public.spot_handoffs` as the seeker via PostgREST must fail (column grants);
   `select count(*) from public.spot_handoffs where claimer_push_token is not null and status in ('expired','cancelled','suspended')`
   should be 0 within a minute of any terminal (the sweep), and `... status = 'departed' and claimer_tokens_until < now()` 0.
6. Logs: Dashboard > Edge Functions > Logs for `handoff-*` should contain no tokens, secrets or IPs (the code logs none).

Local re-run of the SQL test (needs a throwaway Postgres 16; never prod):
`PGHOST=<socketdir> PGPORT=55432 PGUSER=postgres ./supabase/13-spot-handoffs-test.sh`
