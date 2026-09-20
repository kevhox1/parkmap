# Regulars — Zone-Push Delay (S1-follow-up) QA Pass 2 — 2026-09-20

**Reviewed:** branch `backend/regulars-headstart-delay` at `50a65ac6` (fix commit, parent `eab76ee8` = QA pass 1's subject), against `docs/qa/pr114-regulars-delay.md` (pass 1's two findings).
**Verdict:** ✅ **MERGE**

## Summary

Both pass-1 findings are fixed and independently re-verified live on a fresh scratch instance built from this exact commit (not a re-read of pass 1's own scratch DB). Diff scope is exactly the four files claimed. Finding #1's fix (schema move to `internal.sweep_leaving_soon_zone_push()`) is correct, and I re-reproduced my own original anon-invocation exploit against the new code and confirmed it now fails — for both `anon` and `authenticated`, with `postgres` (and, more rigorously, a bare non-superuser role with explicit grants) still succeeding. Finding #2's fix (roadmap ceremony section replaced with the pass-1 checklist verbatim, S3 gate cell + open-items #23 now pointing at it rather than duplicating) is consistent across all three surfaces — I re-grepped the whole tree and found no remaining stale ceremony prose anywhere. The new Test 0 in the test script is a sane, correctly-reasoned regression guard.

## Re-verification of Finding #1 (🔴 → fixed)

- Rebuilt a **fresh** scratch Postgres 16 database from commit `50a65ac6`'s actual files (not pass 1's cached copies) — full chain `01→...→07→09→08` applies clean, zero errors, idempotent (re-ran the `07`+`09`+`08` tail twice back-to-back).
- **Schema/function state confirmed:** `internal.sweep_leaving_soon_zone_push()` exists (not `public.*`); `pg_namespace.nspacl` for `internal` is empty (no explicit grants to anyone, including `PUBLIC`) — matches vanilla, un-customized Postgres schema-privilege defaults (the "PUBLIC gets USAGE+CREATE" special case applies only to the schema literally named `public`, never to a custom schema, core Postgres behavior since long before this project existed — not something Supabase would need to, or plausibly does, override).
- **Access re-verified live, both roles, both fail identically:**
  ```
  set role anon; select internal.sweep_leaving_soon_zone_push();
    → ERROR: permission denied for schema internal
  set role authenticated; select internal.sweep_leaving_soon_zone_push();
    → ERROR: permission denied for schema internal
  ```
- **`postgres` still succeeds** — but I did not stop at that, because in my sandbox `postgres` is a true superuser (bypasses all grants/RLS unconditionally), which would make "postgres succeeds" a non-finding either way and wouldn't distinguish "the grant mechanism works" from "superuser bypass masks everything." I isolated the actual mechanism: created a throwaway **non-superuser, non-owner** role, explicitly granted it `usage on schema internal` + `execute on function internal.sweep_leaving_soon_zone_push()` (mirroring exactly what a real, non-superuser Supabase `postgres`-equivalent role would need), and confirmed it succeeds under `set role` — then confirmed the reverse (a role with neither grant, i.e. `anon`/`authenticated`) fails. This proves the mechanism is schema-USAGE + function-EXECUTE gating, not an artifact of my sandbox's superuser shortcut.
- **Cron job's command string references the qualified name:** manually registered the job's actual `cron.schedule(...)` call from the file against the same DB (my harness normally stubs/strips top-level `cron.schedule` calls to avoid depending on the real pg_cron extension) and confirmed `cron.job.command` reads `select internal.sweep_leaving_soon_zone_push();` verbatim — the qualified name, not the old unqualified/`public.*` one.
- **Sweep behavior unchanged post-move:** re-ran the elapse→push-once spot check (backdated `created_at`, ran `internal.sweep_leaving_soon_zone_push()` directly): pin gets exactly one dispatch, `zone_pushed_at` stamped; a second sweep run leaves the timestamp byte-identical and dispatch count still 1. Matches pass 1's pre-fix behavior exactly, confirming the schema move is a pure rename with zero behavioral side effect.

**On the "reliance on schema placement without an explicit REVOKE" question specifically:** this is consistent with repo precedent (`internal.invoke_send_community_push`, `internal.invoke_send_regular_push`, `internal.invoke_film_permit_ingest` all rely on the identical mechanism — an un-granted custom schema — with no explicit `REVOKE` anywhere in this codebase for any of them) and I independently confirmed the mechanism holds in a from-scratch Postgres 16 instance with no Supabase-specific customization applied beyond what these migration files themselves create. The one thing I cannot verify without live access to the actual Supabase project is whether that specific project has ever run a customizing `ALTER DEFAULT PRIVILEGES ... GRANT ... ON SCHEMAS TO PUBLIC` (or equivalent) that would change the vanilla-Postgres default described above. This is exceedingly unlikely — it would be a highly unusual, deliberately-made customization with no plausible reason to exist — but it's the one residual gap between "verified in a clean sandbox" and "verified in the actual target." **Kevin's ceremony should include this one-line live check** (belongs in ceremony step 2/4, right after applying `09`):
```sql
set role authenticated; select internal.sweep_leaving_soon_zone_push(); reset role;
```
Expected: `ERROR: permission denied for schema internal` (or `for function`). If this instead succeeds, this project's schema defaults have been customized somewhere, and an explicit `revoke usage on schema internal from public;` should be added before trusting the schema-placement-only protection for this or any other `internal.*` helper. This is now also exactly what the test script's new Test 0 checks for via the PostgREST layer (a 404 for both roles) — Test 0's HTTP check and this SQL-level check are complementary, not redundant: Test 0 confirms PostgREST's schema-cache exposure boundary, this one-liner confirms the underlying Postgres grant boundary Test 0 depends on.

## Re-verification of Finding #2 (🟡 → fixed)

- Re-diffed `docs/regulars-roadmap.md`'s "Kevin's ceremonies" section: the old two-bullet fragment (07, "the S1-follow-up migration") is gone, replaced by the pass-1 report's 9-step checklist, reproduced close to verbatim (steps renumbered slightly to fold in an explicit step 2 confirming Finding #1's own fix, and a step 9 "housekeeping" note — both reasonable, faithful extensions of the original, not a rewrite that drifts from it).
- Re-diffed the S3 gate cell and `docs/open-items.md` #23: both now explicitly say "see the consolidated 9-step checklist ... do not duplicate the steps here" rather than repeating the ceremony order inline — this is the correct fix (single source of truth), better than what I recommended (I only asked for the missing bullet to be added; this go further and removes the duplication risk entirely, which is stronger).
- Grepped the full tree for "07...08", "08...09", "Ceremony order"/"ceremony order" across `docs/regulars-roadmap.md` and `docs/open-items.md` — the only remaining hits are the (correct, current) checklist itself and unrelated items (#12, #15) about different features entirely. No stale ceremony prose found anywhere.

## Test 0 assessment

Sane. It POSTs to `/rest/v1/rpc/sweep_leaving_soon_zone_push` (the unqualified name — the only name PostgREST would ever expose a `public`-schema function under) and expects 404 (or 401/403, treated as an equally-valid rejection) for both anon and an authenticated session. This is the right check: PostgREST resolves the schema-cache lookup before any role-based authorization, so a function that was never scanned into the exposed-schema cache 404s universally, independent of caller identity — which is exactly why the anon check works correctly even without sending an `Authorization` header (only `apikey`), unlike this script's other tests. A regression back to `public.*` (or into any other exposed schema) would flip this to 200/204, which the test correctly treats as failure. No changes needed.

## Diff scope

Confirmed exactly the four files the coordinator's message claimed: `docs/open-items.md`, `docs/regulars-roadmap.md`, `supabase/09-regulars-zone-push-delay-test.sh`, `supabase/09-regulars-zone-push-delay.sql`. No unrelated changes.

## Verdict

**MERGE.** Both findings are correctly fixed and independently re-verified live (not just read). One residual, low-probability, easy-to-check item carried forward into the ceremony checklist (the one-line `authenticated`-role live check above) rather than blocking on it — this is a "verify in the real environment" item, not a code defect, and matches the same posture pass 1 already took with the pg_cron Postgres-version prerequisite.

## Report path

`/root/repos/parkmap/.claude/worktrees/agent-aad63fa569986423b/docs/qa/pr114-regulars-delay-pass-2.md` (this file). Pass 1: `/root/repos/parkmap/.claude/worktrees/agent-aad63fa569986423b/docs/qa/pr114-regulars-delay.md`.
