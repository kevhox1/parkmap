# QA Report — PR #99: Community 2.0 Phase 4b backend (send-community-push)

## Pass 1

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

### Findings

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

### What's working (verified, not just asserted)

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

### Kevin's deploy ceremony checklist (run after the fix lands + PR merges)

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

---

## Pass 2 — 2026-09-02

**Reviewed:** PR #99, branch `backend/community-phase4b-push` @ `29f64458` (fix commit, parent
`995eb5f6` reviewed in Pass 1), base `main` @ `945613dd`.
**Reviewer:** @qa-verifier (independent; did not build the fix). Cold re-verification, not a
re-read of the builder's claims.

**Verdict: 🟢 MERGE-THEN-DEPLOY.** The blocking finding from Pass 1 is fixed and independently
re-proven on a fresh local Postgres 16 instance, including the failure-mode the builder claimed to
have additionally exercised (the http_post stage). The minor finding is fixed and verified
idempotent. No scope creep in the diff. The deploy runbook now leads with the Step 0 the Pass 1
report asked for, and the doc ambiguity flagged in Finding #2 is resolved on `main`. Nothing
outstanding blocks merge or the deploy ceremony.

### Pass 1 findings — resolution status

| # | Severity | Status | Verified how |
|---|---|---|---|
| 1 | 🔴 Blocking | **Fixed** | Re-read the SQL structurally + independently reproduced both pre-fix abort and post-fix survival on a fresh local Postgres 16 fixture (see below) |
| 2 | 🟡 Significant | **Fixed** (docs, on `main`, not this PR) | Read `HANDOFF.md`'s current Gate-2 wording + PR body's new Step 0 |
| 3 | 🟢 Minor | **Fixed** | Applied the fixed file to a fixture with zero pre-existing `internal` schema — succeeded |

### 1. Code read — the restructure is exactly as claimed

`git diff 995eb5f6 29f64458 -- supabase/04-community-push-trigger.sql` shows a single, self-contained
change to `internal.invoke_send_community_push()`. Confirmed by direct read:

- The function's `declare` section only assigns constants (`v_service_role_key text; v_request_id
  bigint; v_stage text := 'vault_read';`) — nothing there can throw.
- Exactly ONE `begin ... exception when others ... end;` block (nested inside the function's own
  outer `begin/end`) now encloses, in order: the Vault `select`, the null-check (`if
  v_service_role_key is null then raise log ...; return new; end if;`), and the `net.http_post` call.
  `v_stage` is set to `'vault_read'` before the select and reassigned to `'http_post'` immediately
  before the post call, so the single shared `exception when others` handler's `raise log
  'send-community-push: % stage failed for pin % (sqlstate %): %', v_stage, new.id, sqlstate,
  sqlerrm;` line still identifies which stage failed.
- Nothing after the function body's outer `begin` and before the inner `begin` can throw (it's
  immediately `begin` again). The only code after the inner block's `end;` is `return new; end; $$;` —
  trivial, can't throw. There is no remaining statement inside the function that sits outside
  exception coverage.
- The trigger's own `WHEN` clause (evaluated by Postgres outside the function, per the task's own
  framing) is unchanged and was never in scope for this bug class.

### 2. Independent live re-repro (own fixture, not the builder's)

Rebuilt the repro from scratch on a fresh, isolated Postgres 16 database (`qa99pass2`; prior scratch
DB `qaharness` had been touched by the builder's own repro run, so a clean database was used instead
to avoid any cross-contamination doubt). Fixture: minimal `zones`/`profiles`/`pins`/
`device_push_tokens` tables matching 01/02/03's relevant columns, `pg_net`/`pg_cron` extension lines
stripped (not installable on this box, same as Pass 1).

- **Old code (`995eb5f6`), `internal` schema pre-created:** applied cleanly, then
  ```sql
  insert into public.pins (pin_type, source, lifespan, lat, lng, zone_id)
  values ('open_spot', 'crowd', 'ephemeral', 40.72, -73.99, 'nolita');
  ```
  → `ERROR: relation "vault.decrypted_secrets" does not exist`, transaction rolled back, `select
  count(*) from public.pins` afterward = **0**. Bug reproduced independently, matches Pass 1 exactly.

- **New code (`29f64458`), applied to a TRULY clean database (no manual `internal` schema
  pre-create — this also doubles as the idempotency/clean-project check for Finding #3):** applied
  with zero errors (`CREATE SCHEMA` for `internal` ran on its own, no dependency on 02d).
  Re-ran the identical `open_spot` INSERT → **succeeded**, row returned, `count(*) = 1`. Tailed
  `/var/log/postgresql/postgresql-16-main.log` and found:
  ```
  LOG:  send-community-push: vault_read stage failed for pin 575e4785-... (sqlstate 42P01): relation "vault.decrypted_secrets" does not exist
  ```
  Logged, not thrown. INSERT survived.

- **http_post stage, exercised independently** (not just trusting the builder's description of their
  own stub): created a stub `vault` schema + `vault.decrypted_secrets` table with a real-looking row
  for `service_role_key`, so the Vault read now succeeds and `v_service_role_key` is non-null.
  `pg_net`/the `net` schema is still absent. Inserted a second qualifying pin
  (`sweeper_passed`/crowd/ephemeral/zone `nolita`) → **succeeded**, row returned, `count(*) = 2`. Log:
  ```
  LOG:  send-community-push: http_post stage failed for pin 61abef08-... (sqlstate 3F000): schema "net" does not exist
  ```
  Both failure sites confirmed independently, with distinguishable `v_stage` values, and both INSERTs
  survive. This matches the builder's claim exactly — verified cold, not taken on faith.

### 3. `create schema if not exists internal;` + end-to-end idempotency

- Confirmed present in Section B, before the function definition (see diff above) — and its purpose
  is proven, not just asserted: applying the OLD file to a database with `internal` missing failed at
  `CREATE FUNCTION` with `ERROR: schema "internal" does not exist`; applying the NEW file to the same
  missing-schema state succeeded.
- Re-applied `04-new.sql` a **second time**, back-to-back, on top of its own already-applied state:
  `CREATE VIEW` / `GRANT` / `NOTICE: schema "internal" already exists, skipping` / `CREATE SCHEMA` /
  `CREATE FUNCTION` / `DROP TRIGGER` / `CREATE TRIGGER` — clean re-run, zero errors, exit 0. The
  file's "safe to re-run" claim holds end-to-end, not just for the one line that changed.

### 4. Diff scope — no leakage

`git diff --stat 995eb5f6 29f64458` → **`supabase/04-community-push-trigger.sql` only**, 35
insertions / 14 deletions. `git diff 995eb5f6 29f64458 -- supabase/04-community-push-test.sh
supabase/functions/send-community-push/index.ts` → **zero lines** — both files are byte-identical to
what Pass 1 reviewed. No scope creep.

### 5. PR body / runbook

- New "QA round 1 fix (`29f64458`)" section accurately summarizes all three Pass 1 findings and their
  resolutions, including the same sqlstate/log-line detail independently reproduced above.
- Runbook now opens with **Step 0** (`supabase secrets list --project-ref ...`) exactly as the Pass 1
  checklist asked for, with a note that per the (now-corrected) HANDOFF Gate-2 entry the `.p8` was
  only downloaded, not yet loaded as a secret — resolves Finding #2 without asking Kevin to guess.
  Steps 1–4 are byte-identical in substance to what Pass 1 reviewed (same commands, same order, same
  multiline-`.p8`-via-`$(cat ...)` pattern).
- Confirmed on `main`: `f2c9a658` ("HANDOFF Gate-2 wording — .p8 was downloaded, not yet loaded")
  and `2662b5eb` (this report's Pass 1 content landed) are both present at `main`'s current tip,
  ahead of `945613dd` (the base this PR diffs against).

### Pass-1 reconstruction faithfulness check

Read the reconstructed `docs/qa/pr99-community-phase4b-push.md` as it exists on `main` (`2662b5eb`)
against my own memory of the Pass 1 review delivered in that session's final message. Verdict,
severities, all three findings (including exact wording of the fix recommendation for #1), the
"what's working" list, and the 8-step ceremony checklist all match with no drift, no dropped
findings, no softened/hardened severities. The reconstruction is faithful. Folded into this same
file (Pass 1 section above) rather than left as a separate reconstruction artifact.

### Updated deploy ceremony checklist

Unchanged from Pass 1 (see above) — the fix was internal to the trigger function's error handling and
didn't touch anything the ceremony steps check. One addition: **Step 6 (MANUAL Test 6)** now has a
concrete, verified expectation for what a healthy Postgres log line looks like around a qualifying
pin insert: `send-community-push: vault_read stage failed for pin ... (sqlstate ...): ...` or
`... http_post stage failed for pin ... (sqlstate ...): ...` if something IS wrong at deploy time
(e.g. secrets not actually loaded yet) — either way, that's the fail-open path working correctly, not
evidence of a problem, as long as the pin INSERT itself succeeded (Test 5 already asserts HTTP 201).

### Smoke tests run (Pass 2)

- `git diff`/`git show` reads of `29f64458` vs `995eb5f6` — structural review of the restructured
  function.
- Live Postgres 16 repro, own fixture, own database (`qa99pass2`, isolated from the builder's own
  repro artifacts): old-code abort reproduced (0 rows survive), new-code vault_read-stage survival
  reproduced (1 row, correct log line), new-code http_post-stage survival independently constructed
  and reproduced (2nd row, correct log line).
- Idempotency: fixed file re-applied twice on the same database, second application clean.
- Clean-project applicability: fixed file applied to a database with zero pre-existing `internal`
  schema, succeeded (proves Finding #3's fix, not just its presence in the diff).
- `git diff --stat` and file-level diffs confirming no changes outside
  `supabase/04-community-push-trigger.sql`.
- Read `main`'s HANDOFF.md Gate-2 entry and PR #99's current body for Finding #2's resolution.
