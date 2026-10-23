# Supabase ceremony — migrations 10 (account deletion) and 11 (coverage requests)

**Who:** Kevin, by hand, in the Supabase SQL Editor (project `jiispshyqerscdoferaw`). No agent applies schema to production.
**Prereqs:** 01–06 already applied (they are). Migrations 07/08/09 (Regulars) are NOT required and NOT referenced — 10 and 11 work whether or not 07+ is ever applied.
**Order:** 10 then 11 (independent, but 11's de-attribution-on-deletion behavior is only observable once 10 exists). Each file is one paste, one Run, no multi-step enum restriction, and is idempotent (safe to re-run).
**Tested on:** a scratch Postgres 16.15 with a stubbed `auth` schema — see "What the scratch tests could not prove" at the bottom.

## Step 1 — `supabase/10-account-deletion.sql`

1. SQL Editor → New query → paste the whole file → Run. Expect `Success. No rows returned`.
2. Verify (expect `anon_exec = f`, `authed_exec = t`, `prosecdef = t`, `proconfig = {"search_path=\"\""}`):

```sql
select has_function_privilege('anon',          'public.delete_my_account()', 'execute') as anon_exec,
       has_function_privilege('authenticated', 'public.delete_my_account()', 'execute') as authed_exec,
       p.prosecdef, p.proconfig
  from pg_proc p where p.oid = 'public.delete_my_account()'::regprocedure;
```

3. Smoke test with a THROWAWAY anonymous user (requires "Allow anonymous sign-ins" on; never use a real account — deletion is immediate and irreversible):

```bash
URL=https://jiispshyqerscdoferaw.supabase.co ; KEY=<anon key>
R=$(curl -sS -X POST "$URL/auth/v1/signup" -H "apikey: $KEY" -H "Content-Type: application/json" -d '{"data":{}}')
TOKEN=$(echo "$R" | jq -r .access_token); UID_=$(echo "$R" | jq -r .user.id)
# anon key alone must be refused (expect HTTP 401/403, code 42501):
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{}'
# the throwaway user deletes itself (expect HTTP 204), then again (expect 204 — idempotent):
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```

4. Confirm the identity is really gone (expect `0`; substitute the printed `$UID_`): `select count(*) from auth.users where id = '<uid>';`

**If step 3's first authenticated call returns an error instead of 204**, send me the response body: the likely cause is the SQL Editor role not being allowed to delete from `auth.users` from inside a `SECURITY DEFINER` function (not testable on the scratch DB). Rollback: `drop function public.delete_my_account();` (no tables touched).

## Step 2 — `supabase/11-coverage-requests.sql`

1. SQL Editor → New query → paste the whole file → Run. Expect `Success. No rows returned`.
2. Verify the privilege surface (expect exactly 4 rows: `authenticated | city/note/viewed_lat/viewed_lng | INSERT`; nothing for `anon`):

```sql
select grantee, column_name, privilege_type
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'coverage_requests'
   and grantee in ('anon', 'authenticated')
 order by grantee, column_name;
```

3. Verify exactly one policy (expect `coverage_requests_insert_own | a`):

```sql
select polname, polcmd from pg_policy where polrelid = 'public.coverage_requests'::regclass;
```

4. Smoke test with a throwaway anonymous user:

```bash
# (TOKEN from a fresh anonymous signup as above)
# expect HTTP 201:
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/coverage_requests" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Prefer: return=minimal" -d '{"city":"Park Slope, Brooklyn","note":"smoke test","viewed_lat":40.671234,"viewed_lng":-73.977891}'
# anon key, no user: expect HTTP 401/403:
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/coverage_requests" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"city":"nope"}'
# client read: expect 401/403 (no SELECT grant):
curl -sS -o /dev/null -w '%{http_code}\n' "$URL/rest/v1/coverage_requests?select=*" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN"
```

5. See the row in the dashboard (expect 1 row, `viewed_lat = 40.67`, `viewed_lng = -73.98` — coarsened server-side):
   `select * from public.coverage_requests order by created_at desc limit 5;`
6. Delete the smoke row: `delete from public.coverage_requests where note = 'smoke test';`

Rollback: `drop table public.coverage_requests; drop function public.coverage_requests_before_insert(); delete from public.rate_limit_config where key in ('coverage_request','coverage_request_global');`

**Reading the demand signal later:** `select city, count(*), max(created_at) from public.coverage_requests group by 1 order by 2 desc;`
**Retuning the limits** (no migration): `update public.rate_limit_config set max_count = 10 where key = 'coverage_request';` (per user per hour; default 5) and `key = 'coverage_request_global'` (all users per hour; default 300).

## What the scratch tests could not prove (so Step 1.3 and Step 2.4 are the real acceptance tests)

- The scratch DB stubs `auth.users` (plus identities/sessions/refresh_tokens with the same cascade shape as GoTrue's). Real GoTrue has more tables hanging off `auth.users`, all `ON DELETE CASCADE`, but that is from knowledge, not tested here. Step 1.3 proves it on the real project.
- Real PostgREST, not psql with `SET ROLE`, delivers the HTTP status codes; the smoke commands above check them.
- Storage blobs in the `pin-evidence` bucket are NOT removed by migration 10 (open decision in the PR).
