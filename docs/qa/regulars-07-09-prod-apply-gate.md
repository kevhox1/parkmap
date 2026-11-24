# Regulars 07/08/09 production apply gate QA — 2026-11-23

**Reviewed:** `main` at `4f473e67` (worktree branch), `supabase/07-regulars-schema.sql`, `08-regulars-push-trigger.sql`, `09-regulars-zone-push-delay.sql`, `supabase/functions/send-regular-push/index.ts`, against production = 01-06 (+02b..02g) + 10, 11, 12, 13.
**Verdict:** 🟡 APPLY-READY with one ordering change (apply 09 before 08) and one pre-flag-flip follow-up (send-regular-push has no bearer check). No 🔴.

## Summary
On a scratch Postgres 16 built in production's order (01-06 incl. 02b-02g, then 10, 11, 12, 13, then 07, 08, 09), everything applies cleanly and re-applies cleanly. 07 to 09 change nothing observable for ordinary traffic while no Regulars data exists: community push fires for exactly the same pins as before (diffed over a 330-row matrix), the sweep is a no-op, and the only new side effect is one extra, harmless pg_net call to `send-regular-push` per ordinary leaving_soon post. `delete_my_account()` (13's version) deletes a user with every kind of Regulars row. The repo's own 07/08/09 test scripts are live-REST (curl against a Supabase project) and cannot run on a scratch DB, so I substituted SQL-level checks (below) and say so plainly.

## Acceptance checklist
- [x] Prod-order build applies cleanly: 01-06 (+02b..02g), 10, 11, 12, 13, 07, 08, 09 all applied with no errors.
- [x] 07, 08, 09 re-applied a second time: no errors (idempotent). Exactly one `sweep-leaving-soon-zone-push` cron row; exactly one trigger of each push kind on `pins`.
- [x] Existing harnesses on a DB pre-built in prod order, with 07-09 already present before each script's own steps: `10-account-deletion-test.sh` 69/0, `11-coverage-requests-test.sh` 91/0, `13-spot-handoffs-test.sh` 205/0 (these re-apply 10/11/13 on top of 07-09, so the reverse order is covered too). Stock runs (own DB, no 07-09): 69/0, 91/0, 205/0, and `12-storage-delete-own-test.sh` 28/0. In the combo run 12 gave 27/1; the one failure is a harness artifact (I pre-applied 12 and its "before 12" assertion expects 12 absent), not a defect.
- [ ] `07/08/09-*-test.sh`: NOT RUN. They need `SUPABASE_URL`/anon key and real anonymous auth (curl REST). Not runnable in scratch and I did not touch production. Replaced by SQL-level checks (see Smoke tests).
- [x] `delete_my_account()` with Regulars rows: pass (below).
- [x] 09 trigger WHEN equivalence with NULL head start: pass (below).
- [x] 09 cron job: no name collision, no-op with no data: pass.
- [x] 08 trigger quantified: harmless (finding #3).
- [x] No object-name/grant conflicts with 10-13.
- [x] `deno check` of `send-regular-push/index.ts` and `send-community-push/index.ts`: clean (both use `_shared/apns.ts` with 13's `pushType` union widening).

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
- **#1: Orchestrator's order (07, 08, 09) contradicts 09's own documented order (07, 09, deploy function, 08)**
  - Where: `09-regulars-zone-push-delay.sql` header "APPLY ORDER"; `08-regulars-push-trigger.sql` header.
  - What: 08 makes every qualifying leaving_soon insert fire `send-regular-push` immediately; 09 is what stops the zone-wide push for head-start pins. With 08 before 09 there is a window where a head-start pin gets both pushes (the inert state PR #112 QA reproduced). Also, 08 applied before the function is deployed means pg_net gets a 404 on each leaving_soon post until deploy (fail-open, logged, harmless noise). With the flag off and no client writing `regulars_head_start_seconds`, real impact today is nil, but a hand-crafted REST insert can set that column (it is in the insert grant), so the window is not purely theoretical.
  - Expected: follow the file headers.
  - Recommended order: **07, 09, deploy `send-regular-push`, 08.** Scratch result is clean either way (I applied 07, 08, 09 exactly as requested), so this is ordering hygiene, not a breakage.
  - Owner: orchestrator / `@backend-data` (doc only)
- **#2: `send-regular-push` does not authenticate its caller beyond the gateway JWT check, and trusts the body**
  - Where: `supabase/functions/send-regular-push/index.ts` (handler start; no bearer comparison). `send-community-push` has the same posture; `send-handoff-push` (13's PR) does it right with `safeEqual(bearer, service-role key)`.
  - What: with default `verify_jwt` the gateway accepts ANY valid project JWT, including the public anon key. A caller can POST `{"pin":{"id":..,"pin_type":"leaving_soon","source":"crowd","lifespan":"ephemeral","author_id":<victim uuid>,"street_label":"<any text>"}}` and send a visible alert titled "<victim username> is leaving soon" with attacker-chosen body text to the victim's Regulars. Author UUIDs are public (`pins_with_author`).
  - Impact today: none. It needs the victim to have Regulars edges, and none can exist in practice while the iOS flag is off. It becomes a real spam/spoofing vector once `regularsEnabled` flips. Same gap exists on already-deployed `send-community-push` (silent push only, pre-existing, out of scope).
  - Expected: reject unless bearer equals the service-role key before enabling Regulars. Not required to deploy now; must-fix before the flag flip.
  - Owner: `@backend-data`

### 🟢 Minor / nit
- **#3: 08 fires a pg_net call for every ordinary leaving_soon post even with zero Regulars.** Quantified on the 330-row matrix: community-push calls identical to baseline; new `send-regular-push` calls = exactly 2 of 330 (the only crowd/ephemeral/leaving_soon rows, one with null zone). So cost is one edge invocation per leaving_soon post, returning `sent: 0` after one `regular_edges` query. Intentional per 08's scope note. Optional: add an `exists(regular_edges)` guard to the trigger.
- **#4: 07's SECURITY DEFINER functions have no `set search_path`, and `redeem_regular_invite` is executable by `anon` (default privilege).** Not exploitable: anon call returned `{"ok": false, "reason": "expired_or_used"}`; trigger functions are not RPC-callable. 10/11/13 use the stricter `set search_path=''` + REVOKE pattern; 07 predates it. Optional hardening later.
- **#5: Sweep has no supporting index** (filters on `pin_type`, `regulars_head_start_seconds`). Every 30 s it scans via `pins_pin_type_idx` then filters. Negligible at current volume; revisit only if `pins` grows by orders of magnitude.

### 💡 Out of scope (logged)
- Default Supabase table privileges (TRUNCATE/REFERENCES/TRIGGER for anon/authenticated) show on the 07 tables as on all earlier tables; RLS gates the DML and PostgREST does not expose TRUNCATE. Pre-existing platform posture.
- The 07/08/09 test scripts are REST-only; there is no scratch-Postgres variant like 10/11/13 have. Worth porting before Regulars launch.
- Real pg_cron/pg_net behavior (sub-minute `'30 seconds'`, actual HTTP) cannot be proven on the scratch stub. Covered by the pre-check (pg_cron >= 1.5), the post-apply verify, and a live smoke after apply.

## Out-of-order risk results
1. **delete_my_account with Regulars rows.** Seeded user D with 2 edges, 2 blocks (both directions), 1 created invite, 1 redeemed invite (as redeemer), 1 leaving_soon pin + pin_note, 1 regular_notice. Called as `authenticated` with JWT sub = D. Before: edges=2 blocks=2 invites_created=1 invites_redeemed=1 notes=1 notices=1. After: user gone; edges=0 blocks=0 invites_created=0; no invite references D; the other party's invite row kept with `redeemed_by` NULL and `redeemed_at` set (ON DELETE SET NULL as 10 documented); pin_note gone (cascade); notices=0; D's pin kept with `author_id` NULL (de-attributed, per 10).
2. **09 WHEN rewrite, head start NULL.** Built a baseline DB (01-06, 10-13 only) and the combo DB; inserted a matrix over every `pin_type` x source (crowd/open_data/hybrid) x lifespan (4) x zone (set/null), combos rejected by constraints being rejected identically in both. The `send-community-push` invocations are identical between baseline and combo (11 calls each; the diff shows only the two added `send-regular-push` rows). Logic: NEW = OLD AND NOT(leaving_soon AND head_start IS NOT NULL AND > 0); with NULL the inner term is false. Also with a positive head start: no community push at insert, only `send-regular-push`; one sweep after the head start fires `send-community-push` once and stamps `zone_pushed_at`; a second sweep fires nothing.
3. **09 cron job.** Jobs after prod-order apply: `community-pin-expiry-hygiene-sweep` (`*/15 * * * *`), `handoff-sweep` (`* * * * *`), `ingest-film-permits` (`0 9 * * *`), `sweep-leaving-soon-zone-push` (`30 seconds`). No collision. With no head-start rows a sweep over the 330 pins made 0 calls and stamped 0 rows. Function lives in `internal`; `anon`/`authenticated` get "permission denied for schema internal".
4. **08 trigger on pins.** See #3. Fires only for crowd+ephemeral+leaving_soon. Fail-open by read (Vault read, null check and post in one exception block, same as 04's post-fix shape); I did not simulate a thrown Vault error.
5. **Name/grant conflicts with 10-13.** No duplicate function names across `public`/`internal` (besides pgcrypto's own overloads). `device_push_tokens` policies unchanged (select/insert/update/delete_own). `rate_limit_config` ends with 7 keys (block_scoped_report, coverage_request, coverage_request_global, durable_crowd_report, ephemeral_report, regular_invite, regular_notice), no conflict with 11's. `pins_with_author` recreated by 07 with a superset column list (CREATE OR REPLACE succeeded over 04's definition; 10-13 do not redefine it). `delete_my_account` ACL/definer posture is unchanged after 07-09 (verify query row 14).

## send-regular-push static review
- Invocation contract matches 08: POST `https://jiispshyqerscdoferaw.functions.supabase.co/send-regular-push`, body `{"pin": to_jsonb(NEW)}`; function reads id, pin_type, source, lifespan, author_id, segment_id, zone_id, leaving_minutes, regulars_head_start_seconds, street_label (all on `pins` after 07). Re-checks the same three WHEN conditions. Never reads `notes`/`pin_notes`.
- Auth: gateway `verify_jwt` only. Finding #2.
- Fail-open: 200 with `sent: 0`/`skipped` for no edges, no tokens, missing APNs secrets; 500 only on DB query error (pg_net discards it).
- Shared APNs: imports `APNS_HOSTS, DeviceTokenRow, ApnsEnv, getApnsJwt, sendInChunks` from `../_shared/apns.ts`; 13 widened `pushType` to add `"liveactivity"` (type-only); `pushType: "alert"` still valid. `deno check` clean.
- Secrets: same `APNS_*` as send-community-push; nothing new. Reads `device_push_tokens.user_id`/`environment`, present.
- Deploy command (default verify_jwt, do NOT pass `--no-verify-jwt`):
  `supabase functions deploy send-regular-push --project-ref jiispshyqerscdoferaw`

## Apply order
1. Run PRE-CHECK (below); all rows `OK`.
2. Apply `07-regulars-schema.sql` (SQL Editor, whole file).
3. Apply `09-regulars-zone-push-delay.sql`.
4. Deploy `send-regular-push` (command above).
5. Apply `08-regulars-push-trigger.sql`.
6. Run POST-APPLY VERIFY (below); all rows `OK`.

(07, 08, 09 also applies cleanly; see finding #1 for why not preferred.) Each SQL Editor paste is one transaction, so a failure rolls back that file only.

### Pre-check (read-only, single query)
```sql
select check_name, expected, actual, case when expected = actual then 'OK' else 'STOP' end as status
from (
  select 1 as n, '10-13 present: delete_my_account + handoff-sweep + coverage_requests + spot_handoffs' as check_name, 'true' as expected,
    (to_regprocedure('public.delete_my_account()') is not null
     and exists (select 1 from cron.job where jobname = 'handoff-sweep')
     and to_regclass('public.coverage_requests') is not null
     and to_regclass('public.spot_handoffs') is not null)::text as actual
  union all select 2, '07-09 NOT yet applied: count of 07-09 objects found', '0',
    ((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('regular_edges','regular_blocks','regular_invites','regular_notices','pin_notes'))
   + (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where (n.nspname, p.proname) in (('internal','invoke_send_regular_push'),('internal','sweep_leaving_soon_zone_push'),('public','redeem_regular_invite')))
   + (select count(*) from pg_trigger where tgname = 'pins_invoke_send_regular_push' and not tgisinternal)
   + (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'pins' and column_name in ('regulars_head_start_seconds','zone_pushed_at','street_label'))
   + (select count(*) from cron.job where jobname = 'sweep-leaving-soon-zone-push'))::text
  union all select 3, 'live community push trigger WHEN is the 04 form (no head-start term)', 'true',
    (select (pg_get_triggerdef(t.oid) like '%zone_id IS NOT NULL)%' and pg_get_triggerdef(t.oid) not like '%regulars_head_start%')::text
       from pg_trigger t where t.tgname = 'pins_invoke_send_community_push' and t.tgrelid = 'public.pins'::regclass)
  union all select 4, 'pins_with_author view exists, last column is author_avatar (04)', 'author_avatar',
    (select column_name from information_schema.columns where table_schema = 'public' and table_name = 'pins_with_author' order by ordinal_position desc limit 1)
  union all select 5, 'rate_limit_config has no regular_* keys yet', '0',
    (select count(*)::text from public.rate_limit_config where key in ('regular_invite','regular_notice'))
  union all select 6, 'Vault secret service_role_key present (sweep/push need it)', 'true',
    exists (select 1 from vault.decrypted_secrets where name = 'service_role_key')::text
  union all select 7, 'pg_cron >= 1.5 (needed for the ''30 seconds'' schedule)', 'true',
    (select (string_to_array(extversion, '.')::int[] >= array[1,5])::text from pg_extension where extname = 'pg_cron')
  union all select 8, 'pg_net installed', 'true',
    exists (select 1 from pg_extension where extname = 'pg_net')::text
  union all select 9, 'device_push_tokens has user_id/apns_token/environment', 'true',
    (select (count(*) = 3)::text from information_schema.columns where table_schema = 'public' and table_name = 'device_push_tokens' and column_name in ('user_id','apns_token','environment'))
) q
order by n;
```
Expect all `OK`. `STOP` on row 1: 10-13 not all present; row 2 non-zero: something from 07-09 already partly applied; row 7: pg_cron too old for `'30 seconds'`.

### Post-apply verify (read-only, single query)
```sql
select check_name, expected, actual, case when expected = actual then 'OK' else 'FAIL' end as status
from (
  select 1 as n, '07 tables exist with RLS on (5)' as check_name, '5' as expected,
    (select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('regular_edges','regular_blocks','regular_invites','regular_notices','pin_notes') and c.relrowsecurity) as actual
  union all select 2, '07 pins columns (3)', '3',
    (select count(*)::text from information_schema.columns where table_schema = 'public' and table_name = 'pins' and column_name in ('regulars_head_start_seconds','zone_pushed_at','street_label'))
  union all select 3, 'pins_with_author exposes the 3 new columns', '3',
    (select count(*)::text from information_schema.columns where table_schema = 'public' and table_name = 'pins_with_author' and column_name in ('regulars_head_start_seconds','zone_pushed_at','street_label'))
  union all select 4, 'rate_limit_config regular_invite + regular_notice', '2',
    (select count(*)::text from public.rate_limit_config where key in ('regular_invite','regular_notice'))
  union all select 5, '08 trigger pins_invoke_send_regular_push enabled', 'O',
    (select tgenabled::text from pg_trigger where tgname = 'pins_invoke_send_regular_push' and tgrelid = 'public.pins'::regclass)
  union all select 6, '09 community trigger WHEN carries head-start term, enabled', 'true',
    (select (tgenabled = 'O' and pg_get_triggerdef(oid) like '%regulars_head_start_seconds IS NOT NULL%')::text from pg_trigger where tgname = 'pins_invoke_send_community_push' and tgrelid = 'public.pins'::regclass)
  union all select 7, 'exactly one community + one regular push trigger on pins', '2',
    (select count(*)::text from pg_trigger where tgrelid = 'public.pins'::regclass and tgname in ('pins_invoke_send_community_push','pins_invoke_send_regular_push'))
  union all select 8, 'cron: sweep job registered once, 30 seconds, active', 'sweep-leaving-soon-zone-push|30 seconds|true|1',
    (select min(jobname) || '|' || min(schedule) || '|' || bool_and(active)::text || '|' || count(*)::text from cron.job where jobname = 'sweep-leaving-soon-zone-push')
  union all select 9, 'cron: prior jobs intact (handoff-sweep, ingest-film-permits, community-pin-expiry-hygiene-sweep)', '3',
    (select count(*)::text from cron.job where jobname in ('handoff-sweep','ingest-film-permits','community-pin-expiry-hygiene-sweep'))
  union all select 10, 'internal schema not usable by anon|authenticated', 'false|false',
    (has_schema_privilege('anon','internal','USAGE')::text || '|' || has_schema_privilege('authenticated','internal','USAGE')::text)
  union all select 11, 'redeem_regular_invite executable by authenticated', 'true',
    has_function_privilege('authenticated','public.redeem_regular_invite(uuid)','EXECUTE')::text
  union all select 12, 'zone_pushed_at NOT client-insertable', 'false',
    has_column_privilege('authenticated','public.pins','zone_pushed_at','INSERT')::text
  union all select 13, 'regular_edges has no client INSERT/UPDATE/ALL policy', '0',
    (select count(*)::text from pg_policies where tablename = 'regular_edges' and cmd in ('INSERT','UPDATE','ALL'))
  union all select 14, 'delete_my_account still SECURITY DEFINER with empty search_path', 'true|true',
    (select prosecdef::text || '|' || (array_to_string(proconfig, ',') like 'search_path=""%')::text from pg_proc where oid = 'public.delete_my_account()'::regprocedure)
  union all select 15, 'no Regulars data yet (flag off): edges+invites+notices+notes', '0',
    ((select count(*) from public.regular_edges) + (select count(*) from public.regular_invites) + (select count(*) from public.regular_notices) + (select count(*) from public.pin_notes))::text
) q
order by n;
```
Expect all `OK`. Then a live smoke: post one leaving_soon pin from a test account and run `select url, status_code from net._http_response order by created desc limit 5;`, expecting one `send-community-push` and one `send-regular-push` call, both 200.

## Smoke tests run
- Scratch PG16 cluster `~/Library/Caches/wepark-qa-reg-pg`, port 55477, unix-socket only, stubs from `supabase/scratch/`; `df -h /` showed 15 GB free at start. Cluster stopped and directory deleted at the end.
- Prod-order apply and double re-apply of 07/08/09: clean.
- Harness reruns (10/11/12/13), stock and on the prod-order DB: 69/0, 91/0, 28/0 (27/1 artifact), 205/0.
- SQL-level substitutes for 07: invite create/redeem/self-redeem/replay (`ok`, `cannot_add_self`, `expired_or_used`), block severs the edge, stranger cannot read `pin_notes` while a Regular can, `regular_edges` client insert denied by RLS, `zone_pushed_at` insert denied for the client role, RLS on all 5 tables.
- WHEN-clause matrix diff, sweep behavior, seeded delete_my_account, privilege probes (above).
- Pre-check/verify queries executed on scratch: pre-check on a 10-13-only DB returned `STOP` only on pg_cron version and pg_net (the stub has no real extensions); verify on the combo DB returned all `OK` except row 15 (my own seeded test rows).
- `deno check` of both push functions: clean.
- Not verified: real pg_cron `'30 seconds'` scheduling, real pg_net delivery, real Vault, the three REST test scripts.

## What's working
- 07-09 are idempotent and order-tolerant relative to 10-13, with no hidden coupling.
- 09's WHEN rewrite is a no-op for NULL head start, proven by diff; the sweep is race-safe, schema-protected, and honest-exclusivity by construction.
- 10's cascade comment about Regulars FKs is correct, verified with real data.
- The edge function is fail-open and never reads note text.
