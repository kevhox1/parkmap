# Account deletion (10) + coverage requests (11) QA Pass 1 — 2026-10-23

**Reviewed:** branch `backend/account-deletion-and-coverage-requests` at `27197168` (PR #139), against the migration headers, `docs/supabase-ceremony-10-11.md`, and the applied schema 01-06.
**Verdict:** 🟡 FIX-THEN-MERGE. The two SQL files are sound and can be applied as written. The fixes are to the ceremony doc (add a real-schema pre-check and a content-bearing smoke) and one Kevin decision on storage photos. No finding blocks the SQL.

## Summary

I stood up my own Postgres 16.15 cluster, applied the repo's real 01-06 on a stub, then the real 10 and 11, and tried to break both with well over 100 adversarial statements (authorization, completeness, atomicity, concurrency, mass-assignment, boundary inputs, rate limits). I found no way for a client to delete anyone but themselves, to write `user_id` / `id` / `created_at`, to store precise coordinates, or to bypass the per-user limit. The builder's FK list is complete for 01-06. The one real product gap is Storage photos. Evidence upload is live in the shipped iOS app, and neither the RPC nor any policy removes the files. The other gap is that the ceremony cannot detect a real-project-only blocker (see #1, #2), which is the one thing this stub harness cannot prove.

## Acceptance criteria checklist

**Migration 10, `delete_my_account()`**
- [x] No argument, no overload. `pg_proc` shows only `delete_my_account()`. Calling `delete_my_account(uuid)` gives 42883.
- [x] anon is refused, with or without forged claims. No claims gives 42501 "permission denied for function". With `request.jwt.claims` forced to A's sub while in role anon (stronger than a real client can do), it is still 42501 at the ACL layer.
- [x] authenticated with no claims, an empty sub, or a malformed sub is refused. No claims and empty sub give 42501 "authentication required". A malformed sub gives 22P02, which is harmless.
- [x] `service_role` with no claims gets 42501 "authentication required". It has no JWT sub, so it cannot target anyone (see #7).
- [x] `has_function_privilege`: anon=f, authenticated=t, PUBLIC has no ACL entry (`proacl = {postgres, service_role, authenticated}`). `prosecdef=t`, `proconfig={"search_path=\"\""}`.
- [x] search_path hygiene. With a malicious schema/table on the caller's search_path (`set search_path = evil, public`), the call behaved normally. Every reference is schema-qualified.
- [x] Identity comes only from `auth.uid()`. A client controls only the JWT, not session GUCs, and no `set_config` is exposed through `public`.
- [x] FK completeness against the real applied 01-06 schema (queried `pg_constraint`, not the builder's list). All 11 FKs onto `auth.users`/`profiles` are handled:
  - `pins.author_id`, `zone_messages.author_id`, `pin_evidence.uploaded_by`: SET NULL.
  - `pins.claimed_by`: NO ACTION, cleared explicitly in step 2.
  - `votes`, `profiles`, `reputation_award_log`, `device_push_tokens`: CASCADE.
  - `block_scoped_report_log.author_id`: no FK, deleted explicitly.
  - No other `*_by`, owner, or sender columns exist in `public`. I also listed every uuid column in `public`.
  - After applying 07 on top (draft, in a throwaway clone), `claimed_by` is still the only NO ACTION FK. The header's Regulars claim holds, and 10 and 11 apply cleanly on 01-06 alone.
- [x] Triggers do not obstruct deletion. The UPDATE/DELETE triggers on pins and votes fire (`refresh_pin_vote_counts`, `award_accuracy_on_first_confirm`, `enforce_block_scoped_rate_limit`).
  - I tested a user at the block-scoped rate cap (3 groups) who also voted on someone's block-scoped pin. Deletion succeeded, the author was NULLed, and the vote count was recomputed. The "same report_group_id" skip branch in 02f holds.
- [x] Atomic. I added a surprise NO ACTION FK. The call failed with 23503, and profile, votes, pin author, and message author were all unchanged.
- [x] Idempotent: a second call for an already-deleted user returns normally. Four parallel calls for one user gave 0 errors and the user was gone.
- [x] Zero-content account (user D) deletes cleanly.
- [x] Zombie token. After deletion, insert into pins / zone_messages / profiles / votes / device_push_tokens / coverage_requests and `claim_pin` all fail with 23503. Nothing resurrects. There is no profile-creating trigger on `auth.users` in the repo.
- [x] Anonymization. A's retained pins and messages have `author_id` NULL. `pins_with_author` and `zone_messages_with_author` return NULL username/reputation/avatar. `claimed_by` is cleared on others' pins.
  - The `reputation_award_log` rows for A are gone. B's own award rows, with A only as the source, survive and carry no A identity.
  - The iOS models (`ZoneMessage`, `CommunityPin`) already decode nullable author fields.
- [x] Non-superuser owner (see "Stub vs real Supabase"). With `delete_my_account` owned by a NOLOGIN, BYPASSRLS, non-superuser role and `auth.users` owned by a different role, deletion works provided the owner has DELETE on `auth.users`.
- [x] Idempotent re-apply of the file.

**Migration 11, `coverage_requests`**
- [x] Column privileges are exactly 4 INSERT rows for `authenticated` (city, note, viewed_lat, viewed_lng), none for anon, no table-level privilege for anon/authenticated/PUBLIC. One INSERT-only policy (`polcmd 'a'`).
- [x] Insert with `user_id` = someone else's id, an explicit `id`, or an explicit `created_at` all give 42501 "permission denied for table". `ON CONFLICT (id) DO UPDATE` gives 42501. `ON CONFLICT DO NOTHING` (no target) works.
- [x] anon insert and anon select both give 42501. Authenticated select/update/delete/truncate all give 42501. `rate_limit_config` is untouchable by clients (RLS deny).
- [x] RETURNING contract. Only `returning 1` works. `returning id` and `returning *` give 42501. This is the only consequence, and the documented iOS contract is correct (`return=minimal`).
- [x] Rounding. A precise `40.123456789 / -73.987654321` stored as `40.12 / -73.99`. The BEFORE trigger cannot be skipped, and the client has no timestamp or column that influences it.
- [x] CHECK boundaries:
  - city 80 ok, 81 rejected. Emoji count as characters: 80 emoji (320 bytes) ok, 81 rejected.
  - note 500 ok, 501 rejected. A note padded with trailing spaces past 500 is trimmed first and accepted.
  - Whitespace-only note stores as NULL.
  - NaN, Infinity, 91, and a lat without a lng are all rejected. 90.004 rounds to 90 and is accepted.
- [x] Per-user limit is 5/h. Twelve parallel inserts from one user stored exactly 5 and rejected 7 (advisory lock works).
- [x] Global cap. With the cap set to 3, three users inserted and the 4th and 5th were rejected.
- [x] Fallbacks. With the `rate_limit_config` rows deleted, the hard-coded defaults (5, 300) still apply.
- [x] Deletion interplay. The coverage row survives with `user_id` NULL (FK `ON DELETE SET NULL`). A deleted user's stale JWT cannot insert (23503).
- [ ] City whitespace-only check is incomplete. See #6.

**Both**
- [x] Idempotent re-apply of both files (no errors, same end state; the only output is expected NOTICEs).
- [x] Builder's suites re-run independently: 66/66 and 66/66.
- [x] Mutation checks, two spot-checked on copies:
  - Removing the `claimed_by = null` step made the 10 suite fail 24 tests.
  - Removing the advisory lock made the 11 suite fail the 2 concurrency tests (3/3 runs).
  - Both guards are genuinely covered. The builder's mutation claim is not documented in the repo, only in the PR text.
- [ ] Ceremony doc: SQL steps are correct and ordered, but it cannot catch a real-project blocker. See #1 and #2.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: Ceremony has no pre-check for FKs onto `auth.users` that exist only in the real project**
  - Where: `docs/supabase-ceremony-10-11.md` Step 1 (migration 10 header lists only 01-06 FKs).
  - What: The completeness proof is against the repo's migrations. The production DB can also contain tables made through the dashboard, and Supabase-managed schemas (e.g. `storage.objects.owner`) with FKs onto `auth.users`. Any NO ACTION/RESTRICT FK there makes the final `delete from auth.users` fail with 23503. The function would roll back atomically (verified), so the failure is safe, but every user would be undeletable, which is an App Review rejection risk. From memory, older Supabase storage schemas had `objects_owner_fkey` with no ON DELETE action and later dropped it. This is unverified, and the stub cannot prove or disprove it.
  - Expected: Kevin runs this BEFORE applying and expects only SET NULL/CASCADE rows outside `auth`, plus the already-handled `public.pins.claimed_by` (`a`):
    ```sql
    select conrelid::regclass as tbl, conname, confdeltype  -- a=NO ACTION r=RESTRICT c=CASCADE n=SET NULL
      from pg_constraint
     where contype = 'f' and confrelid = 'auth.users'::regclass
       and connamespace::regnamespace::text not in ('auth')
     order by 1;
    ```
    Also run `select count(*) from public.pins where source='crowd' and pin_type in ('filming','construction') and report_group_id is null;`. It should be 0. A legacy row violating the NOT VALID `pins_block_scoped_report_group_required_chk` would make the step-3 UPDATE fail for that author (02f), again rolled back safely.
  - Owner: `@backend-data`

- **#2: The smoke test deletes an EMPTY account, so it cannot exercise any of the data paths**
  - Where: ceremony Step 1.3.
  - What: A fresh anonymous user has no pins, votes, messages, claim, or storage object. The curl smoke would pass even if the `claimed_by` / cascade / real-FK paths were broken on the real project. This is the single thing the stub cannot prove, and the doc calls Step 1.3 "the real acceptance test".
  - Expected: Extend the throwaway user before deleting it:
    - Insert one chat message via `POST /rest/v1/zone_messages` and one pin via `POST /rest/v1/pins`.
    - Optionally upload one object to `pin-evidence/<uid>/test/x.jpg`.
    - Then delete. Afterwards check in the SQL Editor that the pin/message survive with `author_id` null and that the user is gone.
    - The storage upload is the case that best exercises #1.
  - Owner: `@backend-data`

- **#3: Evidence photos in the `pin-evidence` bucket survive account deletion, and evidence upload is LIVE**
  - Where: `10-account-deletion.sql` header "NOT HANDLED HERE (a)"; `02f` section 8; `ios/WePark/WePark/Services/PinEvidenceUploader.swift`.
  - What: Verified the builder's open question:
    - The photo upload is wired in the shipped app. `AppConstants.communityEnabled = true`, and long-press then "Report closure (film shoot / construction)" then `BlockRestrictionReportSheet` then `CommunityPinService.insertBlockScopedReport` then `PinEvidenceUploader.upload`. The photo is mandatory (AC-R5).
    - Deleting the `pin_evidence` rows (done) removes only the pointers. The files stay at `pin-evidence/{uid}/…`. They are private, unreachable by any client, but still stored.
    - The repo's storage policies are select-own and insert-own only. There is no delete/update policy, so the client cannot remove them today (the iOS cleanup comment already admits this).
    - Direct `delete from storage.objects` is not the answer: it only drops metadata, and the table is owned by `supabase_storage_admin`.
  - Expected: Apple 5.1.1(v) review will not look in the bucket, but a street-scene photo from a deleted user's location is a real privacy gap (GDPR/CCPA erasure).
  - Minimal fix, in order of cost:
    1. **Interim, Kevin-run, no code.** Orphans have a first path segment that no longer exists in `auth.users`. List them in the SQL Editor with `select name from storage.objects where bucket_id='pin-evidence' and (storage.foldername(name))[1]::uuid not in (select id from auth.users);`, then delete them via the Storage dashboard/API. Run it periodically.
    2. **Client-side.** Add `create policy pin_evidence_storage_delete_own on storage.objects for delete using (bucket_id='pin-evidence' and auth.uid()::text=(storage.foldername(name))[1])` (same ownership caveat as the other 02f storage policies; the dashboard Policies UI works if the SQL Editor lacks ownership). The app reads its own `pin_evidence.storage_path` rows (select-own already exists) and calls `storage.remove(paths)` BEFORE `delete_my_account`. A failed removal aborts the delete with a retry. The order matters: the RPC deletes the `pin_evidence` rows, so the paths must be read first.
    3. **Server-side.** A small Edge Function using the service role: remove the `{uid}/` prefix, then call the RPC. This also catches the iOS-documented "orphaned object with no DB row" case, which option 2 misses.
  - This does not block applying 10 (the RPC does not make the gap worse), but the Settings "Delete account" UI should not ship without a decision. Kevin ruling needed.
  - Owner: `@backend-data` (policy / Edge Function), `@ios-engineer` (client sequence)

### 🟢 Minor / nit

- **#4: Stub harness cannot prove real GoTrue behavior.** See "Stub vs real Supabase" below. It does not change the verdict, but note that the builder's 66/66 is evidence about `public` only.
- **#5: Global cap is a lockout lever, bounded.**
  - Each anonymous sign-in is a fresh `user_id`, so the per-user 5/h limit is trivially bypassable by minting sessions. The 300/h global cap then lets one attacker block every real user's suggestion for the hour (rejected with 42501 "temporarily unavailable").
  - Supabase's per-IP anonymous sign-in limit (default 30/h) means roughly 60 sessions, so about two IPs, would saturate it.
  - For a low-stakes feedback table that Kevin reads from the dashboard, this is acceptable. Worst-case table growth is bounded at 300 rows/h. The cost is a griefing window, not data loss or exposure. The iOS copy suggested for any "rate limit exceeded" ("You've sent a few already") is wrong for the global-cap message, which is not the user's fault. The contract should distinguish the two: the global one reads "temporarily unavailable".
  - If it ever matters, key on a coarse bucket or require a non-anonymous identity. No change recommended now.
- **#6: Whitespace-only `city` passes the length check.** `btrim()` strips only ASCII space. A city of `chr(9)||chr(9)` (tabs), `chr(160)*2` (NBSP), or `chr(8203)*2` (zero-width space) was accepted and stored; plain spaces are rejected. Harmless for a feedback table (Kevin sees blanks), and it is not a security issue. A one-line fix is to require at least one visible character, e.g. a regex check `new.city ~ '[^[:space:]\u00a0\u200b]'` in the trigger, if tidiness matters. This is not worth blocking the migration.
- **#7: `service_role` keeps EXECUTE on `delete_my_account`.** `revoke … from public, anon, authenticated` does not touch the `service_role` default-privilege grant. It is harmless (no JWT sub, so `auth.uid()` is null and it raises "authentication required"), and the header says "authenticated ONLY". Either add `revoke … from service_role` or soften the wording.
- **#8: Contract nits.**
  - Header mentions "magic-link" identities, but the shipped app is anonymous-auth only (`signInAnonymously`; no Sign in with Apple, so there are no Apple tokens to revoke).
  - The suggested chat label is "Former neighbor", while `BlockDetailView` renders `authorUsername ?? "Neighbor"`. Pick one for the iOS follow-up.
  - supabase-swift `rpc(...)` on a void function may return 200 or 204 depending on PostgREST version. Tell iOS to treat any 2xx as success.
  - Existing iOS inserts use `Prefer: return=representation` (`CommunityPinService`), so a copy-paste for coverage requests would 42501. The contract already warns; worth repeating in the iOS ticket.
- **#9: Performance note.** `pins.author_id` and `votes.user_id` have no leading index, so the function does a few sequential scans. This is fine at current table sizes. Supabase's `authenticated` role has an ~8 s statement timeout. Revisit only if `pins` grows by orders of magnitude.
- **#10: Product caveats (no change needed).**
  - Free text is retained verbatim (chat bodies, pin notes), as the builder decided.
  - `auth.audit_log_entries` and backups retain traces.
  - A retained pin can lose a confirm (vote deleted). I judge deleting votes correct: a sentinel voter would collide with `unique(pin_id,user_id)`.
  - B's `accurate_report_count` keeps an award earned from A's now-deleted vote. Cosmetic.
  - When 07 ships, `pin_notes.author_id` is CASCADE, so a deleted user's notes on others' pins vanish rather than being anonymized, unlike pins and chat. Decide then.

### 💡 Out of scope (logged, not fixed)

- **`pins_with_author` leaks `parked_car` pins to anon (pre-existing, reproduced on scratch).**
  - The view is owner-run (no `security_invoker`), so the `pins_select_public` RLS that hides `parked_car` rows from non-authors is bypassed through the view.
  - As `anon`: `select count(*) from pins where pin_type='parked_car'` returned 0 on the table, but 1 through `pins_with_author`, including `author_id`, exact lat/lng, and the username. Earlier QA (community-1.0-schema-qa AC-S7/S8) checked only the table policy.
  - Whether any client currently writes `parked_car` to the server is unclear (the model exists; the contract calls it device-local). If it does, the exact location of a user's parked car is world-readable via PostgREST.
  - Recommend: verify with a curl against production, and if confirmed, `alter view public.pins_with_author set (security_invoker = on)`. That is a separate 03-class migration and owner decision, not for this PR.

## Stub vs real Supabase: what the harness cannot prove

- **`auth.users` is a stub.** `auth.users` here is a stub with identities/sessions/refresh_tokens of the same cascade shape. Real GoTrue tables, triggers, and `auth.audit_log_entries` are not exercised. Whether `postgres` can `delete from auth.users` on the real project is not tested.
  - My non-superuser simulation shows the mechanism works when the function owner is non-superuser BYPASSRLS and holds DELETE on `auth.users`. Supabase documents `delete from auth.users` in the SQL Editor and ships SECURITY DEFINER delete-self patterns on this basis, so I rate the risk low but not zero. Ceremony Step 1.3 (hardened per #2) is the real proof.
- **`auth.uid()` is hand-written.** I swapped the stub's `auth.uid()` for the real Supabase form (it honors both `request.jwt.claim.sub` and `request.jwt.claims->>'sub'`). Real PostgREST sets these per request, the HTTP status mapping comes from PostgREST, and this is not exercised by `psql SET ROLE`. The 401/403/204/201 expectations in the curl smoke were not independently verified.
- **Storage and publications are stubs.** `storage.objects` is a stub (no `protect_delete` trigger, no real owner semantics), and pg_cron / pg_net / Realtime are stubs. Realtime UPDATE payloads from the author-NULLing were reasoned about (full new row, author null), not observed.

## Smoke tests run

- Own scratch cluster (PG 16.15, port 5544): stub plus real 01-06 plus real 10 and 11, applied twice (idempotent).
- Scenario DB with 5 users, claims, votes, evidence, a parked_car pin, a block-scoped pin, a device token, reputation rows, and a coverage row. Ran the full authorization matrix, the delete as authenticated, a second call, a view check as anon, and a stale-JWT write matrix.
- Atomicity (injected NO ACTION FK), 4-way parallel delete, 12-way parallel coverage insert, and global-cap and config-deleted fallback runs.
- The 07-applied clone (FK inventory) and a non-superuser-owner clone (delete works).
- Boundary matrix for city / note / lat / lng (including tabs, NBSP, ZWSP, emoji, NaN, Infinity, edge-of-range rounding), anon / authenticated privilege matrix, and `rate_limit_config` tamper attempts.
- Builder's suites re-run unmodified (66/66 + 66/66); two mutations on copies in `/tmp` (not the repo); code-trace of the iOS upload path to establish it is live.
- No iOS build or live-UI smoke was needed: this PR touches no Swift or mount-chain files (7 files, all `supabase/` or `docs/`).

## What's working

- The authorization story is clean: no argument, `SET search_path = ''`, `REVOKE … FROM PUBLIC` then explicit GRANT, plus an in-body null guard. This applies the PR #114 lesson correctly and is verified, not assumed.
- The builder found the one real blocker in the applied schema (`pins.claimed_by` with no ON DELETE action), which a bare `delete from auth.users` would have hit, and made the NULLing explicit rather than leaning on FK semantics.
- Anonymization needs no schema change. The existing LEFT JOIN views and the iOS models already tolerate NULL authors.
- Coverage table: the column-level privilege model is correct and complete, the rounding trigger is un-bypassable, and the advisory-lock claim is true under 12-way concurrency.
- The test suites are honest. Both mutations I tried were caught, and the doc states plainly what the stub cannot prove and tells Kevin a rollback.

---

# QA Pass 2 addendum — 2026-10-23

**Reviewed:** branch `backend/account-deletion-and-coverage-requests` at `fe2c1a27` (builder's pass-1 fixes), fresh clone of the branch, my own scratch Postgres 16.15 (new DB, rebuilt from the repo's stub + real 01-06).
**Verdict:** MERGE for the SQL (10, 11, 12) and the ceremony. Every pass-1 finding is closed and I found no hole in the new surface. **One new high-impact finding belongs to the iOS stream, not this PR: evidence uploads appear to fail with 403 in the shipped app (uppercase storage path), see #P2-1.** It does not block applying 10-12, but it must be resolved before the Settings "Delete account" flow or any evidence-photo feature is trusted.

## Pass-1 finding status

| # | Finding | Status |
|---|---|---|
| 1 | No real-schema pre-check | Closed. Step 0 queries A-E ran on a scratch DB with only 01-06: A = 8 rows, B = exactly `pins_claimed_by_fkey` (a), C = 0 rows, D = 11 rows, E = 0. All five expected outputs in the doc match. |
| 2 | Smoke deleted an empty account | Closed. I replayed Step 4 as SQL (same inserts, claim, vote, storage object, delete, repeat delete, B cleanup). BEFORE/AFTER tables came out exactly as documented: pin and message kept with NULL author, `claimed_by` null, `confirm_count` 1 to 0, 0 votes/profile/storage objects, user gone. |
| 3 | Orphaned photos | Closed at the SQL level by migration 12 (attacks below). The iOS sequence is still to be built, and #P2-1 affects it. |
| 6 | Invisible-only city | Closed (see section 5). |
| 7 | `service_role` EXECUTE | Closed. ACL is exactly `{postgres=X/postgres, authenticated=X/postgres}`. Nothing in the repo calls `delete_my_account` (grepped `ios/`, `supabase/functions/*`, SQL; the Edge Functions only use the service key for ingest/push). |
| 8 | Header nits | Closed (anonymous-only auth, one label, any-2xx, `return=minimal` warning). |
| 9 | Missing indexes | Closed (see section 4). |

## (1) Apply and re-run

Fresh DB, 01-06 then 10, 11, 12, twice, with `ON_ERROR_STOP`: all six applies rc=0 (idempotent). Re-ran all three suites unmodified: **69/69, 91/91, 28/28**, matching the builder.

Mutation spot-checks on copies in `/tmp` (not the repo), all caught:
- 12 without `to authenticated`: 5 failures (an anon role carrying a forged sub deleted 3 rows).
- 12 without the bucket check: 2 failures. 12 with the owner check replaced by `true`: 2 failures. These two fail only because the test widens SELECT, which is the right design.
- 11 with the city check neutered to `>= 0`: 15 failures.

## (2) Attacks on the storage DELETE policy (all negative)

Policy listing on `storage.objects`: `pin_evidence_storage_delete_own (d, {authenticated})`, `..._insert_own (a, public)`, `..._select_own (r, public)`. One permissive policy per command, so nothing is OR-widened across commands; there is no UPDATE policy. I widened SELECT to `true` (temporary policy, dropped afterwards) so a `DELETE ... WHERE true` sees every row and only the DELETE policy gates. Fourteen planted objects:

- **anon** `delete from storage.objects returning name`: 0 rows. **authenticated with no/empty sub**: 0 rows.
- **User B** sweep deleted only `B/g1/b1.jpg`, `B/nullowner.jpg`, `B/../A/trick.jpg`, `B/A/later-seg.jpg`. All four have B's own uid as the first path segment. A's `A/g1/a1.jpg` and `A/a-top.jpg` survived.
- Survivors B could not touch: other-bucket objects (including one under B's own uid), the look-alike bucket `pin-evidence-x`, a leading-slash name `/B/...`, a no-slash name `B`, the empty name, `A%2Fx/enc.jpg` (the policy does not decode a URL-encoded slash), and `AAAA...A/g1/upper.jpg` (an uppercase prefix matches no caller because `auth.uid()::text` is always lowercase).
- A NULL-owner object under B's prefix is deletable by B. That is correct: ownership is the path, per the 02f convention (the `owner` column is not used).
- `B/../A/trick.jpg` deletes only the object literally named that. Whether the real Storage service normalizes `..` before using the key is **not verified** (scratch cannot show it). The insert policy already has the same property, so this is not new; see the Step 4 probe suggestion (#P2-6).
- **UPDATE** by A (rename into B's prefix): 0 rows (no update policy).

## (3) `service_role` revoke

Confirmed: no legitimate caller exists. The revoke is safe. `service_role` bypasses RLS and can still administer data directly if ever needed.

## (4) The five new indexes

- Column names verified against the real applied schema: `pins(author_id)`, `pins(claimed_by)`, `votes(user_id)`, `zone_messages(author_id)`, `reputation_award_log(subject_id)`. No name collisions with any existing index (listed all indexes on the four tables).
- None is redundant. `pins_author_report_group_created_idx` starts with `author_id` but is partial (`WHERE report_group_id IS NOT NULL`), so it cannot serve general author lookups; `votes_pin_id_user_id_key` starts with `pin_id`, not `user_id`.
- `if not exists` matches by name only. If production held a differently-defined index with one of these names it would be skipped silently, and Step 1.3 counts by name only so it would not notice. Nothing in the repo creates these names; very low risk.
- No `CONCURRENTLY` in 10/11/12 outside comments (grepped), so it runs inside the SQL Editor's transaction. Plain `CREATE INDEX` takes a SHARE lock (blocks writes, not reads) on each table for the build; seconds at worst at current scale. Acceptable.

## (5) City / note normalization

- Rejected by the CHECK (23514): all-ZWSP, BOM-only, ideographic-space-only, NBSP+ZWJ+LRM, tab+`a`+ZWSP (1 visible char), and 81 characters.
- Accepted: a 2-character CJK city (`北京`), `Soho` padded with NBSP (stored trimmed), a ZWJ family emoji, `e` + combining acute (2 code points), heart + VS16.
- An interior ZWSP in `Park​Slope` is preserved (only edges are trimmed). Fine.
- Note is edge-trimmed with the same class; an invisible-only note stores NULL.
- Trigger and CHECK agree: an untrimmed-edge value with 2 visible characters passes, 1 visible fails.
- **Locale independence verified.** The class uses `\uXXXX` escapes (code point based), not `[[:space:]]`. Same results on a `C.UTF-8` DB and a freshly created `en_US.utf8` DB. `standard_conforming_strings` is on (Supabase default), which the literal regex needs.
- Gap (🟢): invisible characters outside the class are not stripped, for example Hangul filler U+3164 and combining grapheme joiner U+034F. A city of two U+3164 passes. Harmless for a dashboard-read table.

## (6) Ceremony walk-through

Steps 0-3 are runnable as written. Step 4: replayed as SQL (above); expectations are right. Findings:

- 🟡 **#P2-2 SQL Editor shows only the last statement's result (believed, not verified here).** Step 0 has five separate code blocks (A-E), fine if run one at a time, but a non-expert who selects all five will see only E. The Step 4 "After deleting" block has two statements (the union table, then the standing orphan check): the union table, the one that matters, may be hidden. Suggest an explicit "run each block separately" line in Step 0 and splitting the after-delete block in two.
- 🟢 **#P2-3** Step 0 is only valid before 11 is applied. After 11, Query A shows 9 rows (adds `coverage_requests_user_id_fkey`, n). Add "(9 if 11 is already applied)" for any re-run.
- 🟢 **#P2-4** The standing orphan query does `(storage.foldername(name))[1]::uuid` in the same WHERE as the regex guard; Postgres does not guarantee evaluation order, so a non-UUID first segment could in theory throw 22P02. It did not on scratch with a planted `not-a-uuid/g/x.jpg`. Safer: `not in (select id::text from auth.users)` with no cast.
- 🟢 **#P2-5** Step 4 posts a chat message into the real `soho-les` zone. It is visible to real users (and via Realtime) until the cleanup `delete` at the end. The pin is in New York Harbor with no `zone_id`, so no push fires.
- 🟢 **#P2-6** The Storage list call uses `"prefix":"<uid>/"` with a trailing slash. I cannot verify how the real `storage.search` treats it. Step 4 catches it: if the list returns nothing, the "storage under A" check shows 1 instead of 0, so read that result closely. Optional extra probe: also try uploading/deleting `$B/../$A/x` to see whether the Storage service rejects `..`.
- Safety: all calls use throwaway anonymous users A and B created in the script; no real account is touched. Works in bash and zsh.
- Step 3 Dashboard-UI fallback: the field names and expression match what that form generates (name, operation, target role, USING expression), so it is plausible. The Step 3.3 verification query returns the 3 expected rows (`d`, `a`, `r`) on scratch.

## (7) The builder's flagged iOS bug is real

- **#P2-1 (🔴 for the iOS stream; not a merge blocker for this PR).** `ios/WePark/WePark/Services/PinEvidenceUploader.swift:201` builds `objectPath = "\(userId.uuidString)/\(reportGroupId.uuidString)/\(filename)"`. Swift's `UUID.uuidString` is UPPERCASE. I grepped the whole `ios/` tree: nothing lowercases it anywhere in the upload chain (`CommunityPinService.insertBlockScopedReport` passes `authSvc.currentUserId` straight in, and `currentUserId = session.user.id`, a `UUID`). The only `.lowercased()` calls in `ios/` are unrelated string formatting.
- 02f's INSERT policy compares `auth.uid()::text = (storage.foldername(name))[1]`; `auth.uid()` is a `uuid`, so its text form is lowercase. Reproduced on my scratch DB as role `authenticated` with sub `abcdef01-...`: inserting `ABCDEF01-.../GROUP/FILE.jpg` gives `new row violates row-level security policy for table "objects"`; the lowercase twin inserts fine.
- The iOS unit test `testPinEvidenceUploader_objectPathConvention...` bakes in the uppercase expectation against a mocked network, so it can never catch this. HANDOFF's "storage policies verified live" refers to the policies being applied, not to a successful upload; I found no record of a real upload ever succeeding.
- **What one real upload test would show:** `POST /storage/v1/object/pin-evidence/<UPPERCASE-UID>/...` returns HTTP 403 (body like `{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}`), the uploader throws, `insertBlockScopedReport` surfaces `.evidenceUploadFailed`, and zero `pins` rows are created. So today every block-scoped report (film shoot / construction closure) from the shipped app would fail at the photo step, because the photo is mandatory.
- Fix (iOS, one line plus its test): `userId.uuidString.lowercased()` in the object path (and the group segment for consistency), the same for every prefix the delete-account flow lists or removes, and update the unit-test expectation. One real-device upload after the fix is the acceptance test.
- Interaction with this PR: if uploads have never succeeded there are no photos to orphan, and migration 12 is harmless and ready for when uploads work. Do not skip 12: the fix will make uploads start working.

## Remaining caveats (unchanged from pass 1)

The stub still cannot prove real GoTrue cascades, real PostgREST status codes, or real Storage service behavior (list/remove API, `protect_delete`, `..` handling). Step 0 (Query B) and Step 4 are the acceptance tests for those and are now strong enough for that role.

## Smoke tests run (pass 2)

Fresh scratch DB from the branch at `fe2c1a27`; double apply of 10/11/12; three suites re-run; three mutation checks on 12 and one on 11; 14-object storage attack matrix with SELECT widened; uppercase-prefix insert reproduction; Step 0 A-E queries on a 01-06-only DB; Step 4 replayed end to end in SQL including the orphan query with a planted orphan; city/note matrix on `C.UTF-8` and `en_US.utf8`; grep of `ios/` and `supabase/functions/` for callers and for any lowercasing. No Swift changed in this PR, so no live-UI smoke applies.
