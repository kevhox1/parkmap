# Supabase ceremony — migrations 10 (account deletion), 11 (coverage requests), 12 (storage delete-own)

**Who:** Kevin, by hand, in the Supabase SQL Editor (project `jiispshyqerscdoferaw`). No agent applies schema to production.
**Prereqs:** 01–06 already applied (they are). Draft Regulars migrations 07/08/09 are NOT required and NOT referenced; 10, 11 and 12 work whether or not 07+ is ever applied.
**Files:** `supabase/10-account-deletion.sql`, `supabase/11-coverage-requests.sql`, `supabase/12-storage-delete-own.sql`. Each is one paste, one Run, idempotent (safe to re-run).

## Order, and why

**Step 0 pre-check, then 10, then 11, then 12, then the end-to-end smoke (Step 4).**

- **Pre-check first** because it can tell you 10 will fail on this project before you apply anything.
- **10 before the rest** because it is the core feature and everything else (11's de-attribution, 12's iOS sequence) refers to it.
- **11 before 12** because 11 is independent and zero-risk, while 12 is the only file with a genuine chance of failing on ownership (`storage.objects` belongs to `supabase_storage_admin`). Putting 12 last means a failure there blocks nothing else and you can switch to the Dashboard Policies UI at your leisure.
- **Smoke last** because the full account-deletion path (files, then RPC) needs both 10 and 12 live.
- 10 and 12 are BOTH required before the iOS "Delete account" row ships; 11 gates only the "Suggest a neighborhood" sheet.

**Stop rule for the whole ceremony:** if any expected output below differs, STOP, do not apply the next file, and paste the actual output to the orchestrator.

---

## Step 0 — PRE-CHECK against the REAL project (run BEFORE applying 10)

The scratch tests prove the SQL against migrations 01–06 only. This project may also contain tables made through the dashboard, or Supabase-managed tables, with a foreign key onto `auth.users`. Any `NO ACTION` / `RESTRICT` FK like that would make `delete_my_account()` fail on its last statement (it rolls back atomically, so nothing is lost, but NO user could ever be deleted, which is an App Review risk). Check now.

**Query A — every FK onto `auth.users` outside the `auth` schema.** Expected: exactly these 8 rows (order may vary):

```sql
select conrelid::regclass as tbl, conname, confdeltype  -- a=NO ACTION r=RESTRICT c=CASCADE n=SET NULL
  from pg_constraint
 where contype = 'f' and confrelid = 'auth.users'::regclass
   and connamespace::regnamespace::text not in ('auth')
 order by 1, 2;
```

| tbl | conname | confdeltype |
|---|---|---|
| device_push_tokens | device_push_tokens_user_id_fkey | c |
| pin_evidence | pin_evidence_uploaded_by_fkey | n |
| pins | pins_author_id_fkey | n |
| pins | pins_claimed_by_fkey | **a** (expected; migration 10 clears it explicitly) |
| profiles | profiles_id_fkey | c |
| reputation_award_log | reputation_award_log_subject_id_fkey | c |
| votes | votes_user_id_fkey | c |
| zone_messages | zone_messages_author_id_fkey | n |

(Rows may print as `public.pins` etc. depending on search_path; same thing.)

**Query B — the decisive one: ANY non-cascading FK onto `auth.users`, in ANY schema (including `storage`, `auth`).** Expected: exactly ONE row, `pins | pins_claimed_by_fkey | a`.

```sql
select conrelid::regclass as tbl, conname, confdeltype
  from pg_constraint
 where contype = 'f' and confrelid = 'auth.users'::regclass and confdeltype in ('a', 'r')
 order by 1, 2;
```

**Query C — FKs onto `public.profiles`.** Expected: 0 rows.

```sql
select conrelid::regclass as tbl, conname, confdeltype
  from pg_constraint where contype = 'f' and confrelid = 'public.profiles'::regclass;
```

**Query D — user-ish uuid columns in `public` (catches dashboard-made tables with a user column but no FK, which the delete would silently leave behind).** Expected: exactly these 11 rows (the two `*_with_author` views included):

```sql
select table_name, column_name from information_schema.columns
 where table_schema = 'public' and data_type = 'uuid'
   and column_name ~ '(user|author|owner|_by$|sender|subject)'
 order by 1, 2;
```

`block_scoped_report_log.author_id`, `device_push_tokens.user_id`, `pin_evidence.uploaded_by`, `pins.author_id`, `pins.claimed_by`, `pins_with_author.author_id`, `pins_with_author.claimed_by`, `reputation_award_log.subject_id`, `votes.user_id`, `zone_messages.author_id`, `zone_messages_with_author.author_id`.

**Query E — legacy block-scoped crowd pins with no `report_group_id`.** Expected: `0`. A legacy row violating the NOT VALID `pins_block_scoped_report_group_required_chk` (02f) would make the deletion's de-attribution UPDATE fail for that one author (rolled back safely, but that user is then undeletable).

```sql
select count(*) from public.pins
 where source = 'crowd' and pin_type in ('filming', 'construction') and report_group_id is null;
```

**If anything differs** — an extra FK row in A/B (especially a `storage`-schema row such as an `objects_owner_fkey` with `a`/`r`), a row in C, an unknown table/column in D, or E > 0 — **STOP. Do not apply 10.** Paste the actual output of A–E to the orchestrator; the fix is a small addition to `delete_my_account()` (or a data clean-up for E), done on the branch before you apply anything.

---

## Step 1 — `supabase/10-account-deletion.sql`

1. SQL Editor → New query → paste the whole file → Run. Expect `Success. No rows returned`.
2. Verify the privileges (expect `anon_exec = f`, `authed_exec = t`, `service_exec = f`, `prosecdef = t`, `proconfig = {"search_path=\"\""}`):

```sql
select has_function_privilege('anon',          'public.delete_my_account()', 'execute') as anon_exec,
       has_function_privilege('authenticated', 'public.delete_my_account()', 'execute') as authed_exec,
       has_function_privilege('service_role',  'public.delete_my_account()', 'execute') as service_exec,
       p.prosecdef, p.proconfig
  from pg_proc p where p.oid = 'public.delete_my_account()'::regprocedure;
```

3. Verify the 5 supporting indexes exist (expect 5):

```sql
select count(*) from pg_indexes where schemaname = 'public'
   and indexname in ('pins_author_id_idx','pins_claimed_by_idx','votes_user_id_idx','zone_messages_author_id_idx','reputation_award_log_subject_id_idx');
```

The behavioral test of this function is Step 4 (it needs 12 for the file part). Rollback if ever needed: `drop function public.delete_my_account();` (the indexes are harmless to keep).

## Step 2 — `supabase/11-coverage-requests.sql`

1. SQL Editor → paste → Run. Expect `Success. No rows returned`.
2. Verify the privilege surface (expect exactly 4 rows, all `authenticated | INSERT`, on `city`, `note`, `viewed_lat`, `viewed_lng`; nothing for `anon`):

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

4. Smoke with a throwaway anonymous user (needs "Allow anonymous sign-ins" on). Use the shell variables from Step 4's header (`URL`, `KEY`) or set them now:

```bash
URL=https://jiispshyqerscdoferaw.supabase.co ; KEY=<anon key>
R=$(curl -sS -X POST "$URL/auth/v1/signup" -H "apikey: $KEY" -H "Content-Type: application/json" -d '{"data":{}}')
TOKEN=$(echo "$R" | jq -r .access_token)
# expect 201 (note: Prefer: return=minimal is REQUIRED):
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/coverage_requests" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Prefer: return=minimal" -d '{"city":"Park Slope, Brooklyn","note":"ceremony smoke","viewed_lat":40.671234,"viewed_lng":-73.977891}'
# expect 401 or 403 (anon key, no user):
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/coverage_requests" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"city":"nope"}'
# expect 401 or 403 (clients cannot read):
curl -sS -o /dev/null -w '%{http_code}\n' "$URL/rest/v1/coverage_requests?select=*" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN"
# expect 401 or 403 (return=representation is refused by design; iOS must use return=minimal):
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/coverage_requests" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Prefer: return=representation" -d '{"city":"Should Fail"}'
```

5. In the SQL Editor: `select * from public.coverage_requests order by created_at desc limit 5;` — expect 1 row, `viewed_lat = 40.67`, `viewed_lng = -73.98` (coarsened server-side).
6. Delete the smoke row: `delete from public.coverage_requests where note = 'ceremony smoke';`

Rollback: `drop table public.coverage_requests; drop function public.coverage_requests_before_insert(); delete from public.rate_limit_config where key in ('coverage_request','coverage_request_global');`
**Reading the demand signal later:** `select city, count(*), max(created_at) from public.coverage_requests group by 1 order by 2 desc;`
**Retuning limits** (no migration): `update public.rate_limit_config set max_count = 10 where key = 'coverage_request';` (per user per hour, default 5) and `key = 'coverage_request_global'` (all users per hour, default 300).

## Step 3 — `supabase/12-storage-delete-own.sql`

1. SQL Editor → paste → Run. Expect `Success. No rows returned`. This should work the same way 02f's two storage policies did (HANDOFF records them as applied and verified live).
2. **If it fails with `must be owner of table objects` (or similar):** create the same policy in the Dashboard instead. Storage → Policies → "Other policies under storage.objects" → New policy → "For full customization":
   - Policy name: `pin_evidence_storage_delete_own`
   - Allowed operation: `DELETE`
   - Target roles: `authenticated`
   - USING expression: `bucket_id = 'pin-evidence' and auth.uid() is not null and auth.uid()::text = (storage.foldername(name))[1]`
   - Review → Save policy.
3. Verify (expect 3 rows: `pin_evidence_storage_delete_own | d`, `..._insert_own | a`, `..._select_own | r`):

```sql
select polname, polcmd from pg_policy
 where polrelid = 'storage.objects'::regclass and polname like 'pin_evidence_storage_%' order by polname;
```

## Step 4 — End-to-end deletion smoke (the real acceptance test)

This is the one thing the scratch tests cannot prove: that on the REAL project, a user who has content, a claim, a vote and a stored photo can be deleted, content stays de-attributed, and the files go. **Throwaway anonymous users only; never a real account** (deletion is immediate and irreversible).

```bash
URL=https://jiispshyqerscdoferaw.supabase.co ; KEY=<anon key>
H=(-H "apikey: $KEY" -H "Content-Type: application/json")
signup() { curl -sS -X POST "$URL/auth/v1/signup" "${H[@]}" -d '{"data":{}}'; }

# --- two throwaway users: A (will be deleted) and B (owns a pin A interacts with)
RA=$(signup); TA=$(echo "$RA" | jq -r .access_token); A=$(echo "$RA" | jq -r .user.id)
RB=$(signup); TB=$(echo "$RB" | jq -r .access_token); B=$(echo "$RB" | jq -r .user.id)
echo "A=$A B=$B"          # ids are lowercase; the iOS client must lowercase uuidString too

# --- A creates a chat message and a pin (off-map point in New York Harbor so no real user sees it)
curl -sS -o /dev/null -w 'A message: %{http_code} (expect 201)\n' -X POST "$URL/rest/v1/zone_messages" "${H[@]}" -H "Authorization: Bearer $TA" -H "Prefer: return=minimal" \
  -d "{\"zone_id\":\"soho-les\",\"author_id\":\"$A\",\"message_type\":\"user\",\"body\":\"ceremony smoke message\"}"
curl -sS -o /dev/null -w 'A pin: %{http_code} (expect 201)\n' -X POST "$URL/rest/v1/pins" "${H[@]}" -H "Authorization: Bearer $TA" -H "Prefer: return=minimal" \
  -d "{\"pin_type\":\"block_note\",\"source\":\"crowd\",\"lifespan\":\"durable\",\"lat\":40.70,\"lng\":-74.04,\"author_id\":\"$A\",\"notes\":\"ceremony smoke pin A\"}"

# --- B creates a leaving_soon pin; A votes on it and claims it (exercises votes + the pins.claimed_by NO ACTION FK)
PB=$(curl -sS -X POST "$URL/rest/v1/pins" "${H[@]}" -H "Authorization: Bearer $TB" -H "Prefer: return=representation" \
  -d "{\"pin_type\":\"leaving_soon\",\"source\":\"crowd\",\"lifespan\":\"ephemeral\",\"lat\":40.70,\"lng\":-74.04,\"author_id\":\"$B\",\"leaving_minutes\":10,\"notes\":\"ceremony smoke pin B\"}" | jq -r '.[0].id')
echo "B pin id: $PB"
curl -sS -o /dev/null -w 'A vote: %{http_code} (expect 201)\n' -X POST "$URL/rest/v1/votes" "${H[@]}" -H "Authorization: Bearer $TA" -H "Prefer: return=minimal" \
  -d "{\"pin_id\":\"$PB\",\"user_id\":\"$A\",\"vote\":\"confirm\"}"
curl -sS -X POST "$URL/rest/v1/rpc/claim_pin" "${H[@]}" -H "Authorization: Bearer $TA" -d "{\"p_pin_id\":\"$PB\"}"; echo "  <- claim_pin (expect true)"

# --- A uploads an evidence photo (path convention {uid}/{group}/{file}; lowercase uid)
GRP=$(uuidgen | tr 'A-F' 'a-f'); printf '\xff\xd8\xff\xd9' > /tmp/smoke.jpg
curl -sS -o /dev/null -w 'A upload: %{http_code} (expect 200)\n' -X POST "$URL/storage/v1/object/pin-evidence/$A/$GRP/smoke.jpg" \
  -H "apikey: $KEY" -H "Authorization: Bearer $TA" -H "Content-Type: image/jpeg" --data-binary @/tmp/smoke.jpg
```

**Before deleting — SQL Editor** (substitute `<A>` / `<B>` / `<PB>`). Expect: pin A `author_id = <A>`; message `author_id = <A>`; `claimed_by = <A>` and `confirm_count = 1` on B's pin; a vote row; one storage object under `<A>/`:

```sql
select 'pin A' k, author_id::text v from public.pins where notes = 'ceremony smoke pin A'
union all select 'msg A', author_id::text from public.zone_messages where body = 'ceremony smoke message'
union all select 'B pin claimed_by', claimed_by::text from public.pins where notes = 'ceremony smoke pin B'
union all select 'B pin confirm_count', confirm_count::text from public.pins where notes = 'ceremony smoke pin B'
union all select 'votes by A', count(*)::text from public.votes where user_id = '<A>'
union all select 'storage objects under A', count(*)::text from storage.objects where bucket_id = 'pin-evidence' and name like '<A>/%';
```

**Delete A exactly the way the iOS app will: files first, account last.**

```bash
# 1. list (non-recursive: first level = report_group folders; then each folder)
curl -sS -X POST "$URL/storage/v1/object/list/pin-evidence" -H "apikey: $KEY" -H "Authorization: Bearer $TA" -H "Content-Type: application/json" -d "{\"prefix\":\"$A/\",\"limit\":100,\"offset\":0}" | jq -c '.[].name'     # expect "<GRP>"
curl -sS -X POST "$URL/storage/v1/object/list/pin-evidence" -H "apikey: $KEY" -H "Authorization: Bearer $TA" -H "Content-Type: application/json" -d "{\"prefix\":\"$A/$GRP/\",\"limit\":100,\"offset\":0}" | jq -c '.[].name' # expect "smoke.jpg"
# 2. remove (expect 200 and a JSON array naming the removed object)
curl -sS -X DELETE "$URL/storage/v1/object/pin-evidence" -H "apikey: $KEY" -H "Authorization: Bearer $TA" -H "Content-Type: application/json" -d "{\"prefixes\":[\"$A/$GRP/smoke.jpg\"]}"; echo
# 3. ONLY after removal succeeded: the RPC (expect 204 or 200)
curl -sS -o /dev/null -w 'delete A: %{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" "${H[@]}" -H "Authorization: Bearer $TA" -d '{}'
# 4. again (stale token): expect 204/200 again — idempotent
curl -sS -o /dev/null -w 'delete A again: %{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" "${H[@]}" -H "Authorization: Bearer $TA" -d '{}'
# 5. the anon key alone must be refused: expect 401 or 403
curl -sS -o /dev/null -w 'anon: %{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" "${H[@]}" -H "Authorization: Bearer $KEY" -d '{}'
```

**After deleting — SQL Editor.** Expect: user gone (`0`); pin A and message **still exist with `author_id` NULL**; B's pin `claimed_by` NULL and `confirm_count` 0; no votes by A; **0** storage objects under `<A>/`; no orphans anywhere:

```sql
select 'A in auth.users (expect 0)' k, count(*)::text v from auth.users where id = '<A>'
union all select 'pin A kept, author NULL (expect 1)', count(*)::text from public.pins where notes = 'ceremony smoke pin A' and author_id is null
union all select 'msg A kept, author NULL (expect 1)', count(*)::text from public.zone_messages where body = 'ceremony smoke message' and author_id is null
union all select 'B pin claimed_by (expect null)', coalesce(claimed_by::text, 'null') from public.pins where notes = 'ceremony smoke pin B'
union all select 'B pin confirm_count (expect 0)', confirm_count::text from public.pins where notes = 'ceremony smoke pin B'
union all select 'votes by A (expect 0)', count(*)::text from public.votes where user_id = '<A>'
union all select 'profiles A (expect 0)', count(*)::text from public.profiles where id = '<A>'
union all select 'storage under A (expect 0)', count(*)::text from storage.objects where bucket_id = 'pin-evidence' and name like '<A>/%';

-- Standing orphan check (also usable any time later): evidence objects whose owner no longer exists. Expect 0 rows.
select name from storage.objects
 where bucket_id = 'pin-evidence'
   and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
   and (storage.foldername(name))[1]::uuid not in (select id from auth.users);
```

Also glance at Dashboard → Storage → `pin-evidence`: the `<A>/` folder should be gone. (Metadata deleted via the API also removes the file; this is the visual confirmation.)

**Clean up:** B deletes themselves (a second real run of the RPC), then remove the retained smoke content.

```bash
curl -sS -o /dev/null -w 'delete B: %{http_code}\n' -X POST "$URL/rest/v1/rpc/delete_my_account" "${H[@]}" -H "Authorization: Bearer $TB" -d '{}'
```
```sql
delete from public.pins where notes like 'ceremony smoke pin %';
delete from public.zone_messages where body = 'ceremony smoke message';
delete from public.coverage_requests where note = 'ceremony smoke';
```

**If the first `delete A` call returns an error instead of 204/200**, send the response body. The likely causes, none testable on scratch: (a) the function owner can't `delete from auth.users` from inside a `SECURITY DEFINER` function on this project; (b) an FK your pre-check missed. Everything is atomic: nothing was deleted. Rollback: `drop function public.delete_my_account();`

## What the scratch tests could not prove (so Steps 0 and 4 are the real acceptance tests)

- The scratch DB stubs `auth.users` (plus identities/sessions/refresh_tokens with the same cascade shape as GoTrue). Real GoTrue has more tables hanging off `auth.users`, all `ON DELETE CASCADE` as far as I know, but that is from knowledge, not tested. Step 0 Query B and Step 4 prove it on the real project.
- Real PostgREST/Storage deliver the HTTP status codes and the real list/remove API; psql with `SET ROLE` does not. The curl expectations above are from the documented behavior, not independently run.
- `storage.objects` is a plain table on scratch: no Storage service, no S3 object, no `protect_delete` trigger, no ownership semantics. 12's tests prove the RLS policy logic (28 checks) but NOT that the SQL Editor role may create the policy, nor that the Storage API actually removes the file. Step 3 and Step 4 prove those.
