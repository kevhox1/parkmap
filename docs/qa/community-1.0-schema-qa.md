# Community 1.0 Typed-Pin Schema QA Pass 1 — 2026-06-01

**Reviewed:** `main` at `9310240`, files `supabase/02-pins-schema.sql` and `supabase/02b-pins-ingest-indexes.sql`, against `docs/typed-pin-schema-spec.md` AC-S1 through AC-S12.
**Verdict:** PASS-WITH-NITS

No local Postgres was available; this is a rigorous static review of the SQL against the spec. Every AC that can be verified by reading the DDL is verified by reading the DDL. ACs that require a live database (S5, S6, S7, S8, S9, S10, S11, S12) are assessed by tracing the relevant RLS policies and trigger code with explicit logic proofs where needed.

---

## Summary

The schema is well-constructed. Every acceptance criterion in AC-S1–S12 is satisfied by the DDL as written. RLS policies are correct with no anonymous-write gap. The frozen-`now()` partial-index bug (the specific issue called out in the QA scope) is genuinely fixed — the active spatial index predicate is `where resolved_at is null` with a detailed comment explaining why `expires_at > now()` was intentionally omitted. The `extend_pin_expiry` RPC has an explicit auth guard that rejects anonymous callers. The file is idempotent throughout. One significant finding: the `votes_update_own` and `pins_update_own` UPDATE policies omit a `WITH CHECK` clause — this is safe in Postgres (the USING expression is used as the default WITH CHECK), but it is implicit behavior that warrants an explicit comment. Two nits: the `alter table ... enable row level security` statements are not guarded for re-run (they are idempotent in Postgres 15 but not obviously so to a reader), and the active index is renamed `pins_active_spatial_idx` vs `pins_active_idx` in the spec (cosmetic, no functional impact).

---

## Acceptance Criteria Checklist

- [x] **AC-S1** — Idempotent. Verified by: enum creation is guarded in a `DO $$ if not exists (select 1 from pg_type where typname = 'pin_type') $$` block; all tables use `CREATE TABLE IF NOT EXISTS`; all indexes use `CREATE INDEX IF NOT EXISTS`; all policies use `DROP POLICY IF EXISTS` before `CREATE POLICY`; the trigger uses `DROP TRIGGER IF EXISTS` then `CREATE TRIGGER`; functions use `CREATE OR REPLACE FUNCTION`; the Realtime block uses a `DO $$ if not exists ... $$` guard. The only non-guarded statements are `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` — these are idempotent in Postgres 15 (Supabase's engine) but carry no explicit guard. See Finding 2.

- [x] **AC-S2** — `pin_type` enum contains exactly 10 values. Verified by direct count of the enum body in the DDL (lines 19–31): `filming`, `asp_suspended_today`, `special_event`, `construction`, `sign_correction`, `block_note`, `enforcement_active`, `sweeper_passed`, `broken_meter`, `parked_car` = 10. Matches spec §4.1 exactly, including tier groupings.

- [x] **AC-S3** — `pins` table has all columns from spec §4.2 with correct types and constraints. Verified column-by-column:
  - `id uuid primary key default gen_random_uuid()` — matches spec.
  - `pin_type public.pin_type not null` — matches.
  - `source text not null check (source in ('open_data', 'hybrid', 'crowd'))` — matches.
  - `lifespan text not null check (lifespan in ('ephemeral', 'session', 'durable', 'correction'))` — matches.
  - `lat double precision not null`, `lng double precision not null` — matches.
  - `segment_id text` (nullable) — matches.
  - `zone_id text references public.zones(id) on delete set null` — matches.
  - `author_id uuid references auth.users(id) on delete set null` (nullable) — matches.
  - `created_at timestamptz not null default now()`, `updated_at timestamptz not null default now()` — matches.
  - `expires_at timestamptz` (nullable), `resolved_at timestamptz` (nullable) — matches.
  - `confirm_count integer not null default 0`, `dispute_count integer not null default 0` — matches.
  - `meta jsonb` (nullable) — matches.
  - `notes text check (length(notes) <= 500)` — matches.

- [x] **AC-S4** — `votes` table has `unique(pin_id, user_id)`. Verified at line 168: `unique (pin_id, user_id)` inline constraint. One vote per user per pin enforced at DB level per OQ-2 decision.

- [x] **AC-S5** — Anonymous INSERT rejected; authenticated INSERT succeeds. Static proof: policy `pins_insert_crowd` (line 140–145): `with check (auth.uid() is not null and author_id = auth.uid() and source = 'crowd')`. For an anonymous caller `auth.uid()` returns `null`; `(null is not null)` evaluates to `FALSE`; the `WITH CHECK` fails and the insert is rejected. For an authenticated caller with a matching `author_id` and `source = 'crowd'`: all three conditions are `TRUE`; insert succeeds. The `auth.uid() is not null` guard is explicit and correct.

- [x] **AC-S6** — Service-role `open_data` insert bypasses RLS. Verified: comment at line 138 states "open_data and hybrid pins arrive via service-role key, which bypasses RLS entirely." This is standard Supabase behavior — the `service_role` JWT sets `request.jwt.claims.role = 'service_role'`, which bypasses all RLS policies at the Supabase PostgREST layer. No policy is needed for this path and none exists. Correct.

- [x] **AC-S7** — `parked_car` pin is invisible to a different authenticated user. Static proof: SELECT policy `pins_select_public` (lines 131–135): `using (pin_type != 'parked_car' or auth.uid() = author_id)`. For a `parked_car` pin queried by user B (not the author): `(pin_type != 'parked_car')` = `FALSE`; `auth.uid() = author_id` = `(B = A)` = `FALSE`; `FALSE OR FALSE` = `FALSE`; row not returned. For user A (the author): `(B = A)` = `TRUE`; `FALSE OR TRUE` = `TRUE`; row returned. Correct.

- [x] **AC-S8** — A `filming` pin is visible to anonymous callers. Static proof: for any `pin_type != 'parked_car'`, the first condition of the SELECT policy is `TRUE`, so the `OR` short-circuits and the row is returned regardless of `auth.uid()`. `filming` satisfies `pin_type != 'parked_car'`. The view `pins_with_author` grants `SELECT` to `anon` (line 276). Correct.

- [x] **AC-S9 / AC-S10** — Vote insert/delete updates `confirm_count` / `dispute_count`. Verified: trigger `votes_refresh_pin_counts` fires `AFTER INSERT OR UPDATE OR DELETE ON public.votes FOR EACH ROW` (lines 230–232). The trigger function (lines 208–227) uses `SECURITY DEFINER` to bypass the author-only UPDATE RLS and runs two `count(*)` subqueries against `votes` filtered by `v_pin_id` and `vote = 'confirm'/'dispute'`. Because the trigger fires after the DML (INSERT or DELETE), the counts reflect the post-change state. This is synchronous (same transaction). AC-S9 and AC-S10 are satisfied.

- [x] **AC-S11** — Realtime subscription. Verified: the Realtime block (lines 281–291) adds `public.pins` to the `supabase_realtime` publication if not already present, guarded idempotently. This is the same pattern as `zone_messages` in `01-mvp-schema.sql`. Correct. (Live 2s timing cannot be verified statically.)

- [x] **AC-S12** — `pins_with_author` view returns `author_username` and `author_reputation`. Verified: view at lines 268–274 selects `p.*`, `pr.username as author_username`, `pr.reputation as author_reputation` via `LEFT JOIN public.profiles pr on pr.id = p.author_id`. Matches the spec §9 definition exactly. `SELECT` grant to `anon, authenticated` at line 276.

---

## Findings

### Significant

**#1: `votes_update_own` and `pins_update_own` UPDATE policies lack an explicit `WITH CHECK` clause**
- Where: `02-pins-schema.sql` lines 195–196 (`votes_update_own`) and lines 149–150 (`pins_update_own`)
- What: Both UPDATE policies are written with only a `USING` clause and no `WITH CHECK` clause. In PostgreSQL, when `WITH CHECK` is absent on an UPDATE policy, it defaults silently to the `USING` expression. This means an authenticated user cannot update another user's `user_id` into their vote row (the default `WITH CHECK` = `auth.uid() = user_id` would block it). The behavior is correct, but it relies on implicit Postgres semantics rather than an explicit constraint.
- Expected per spec: The spec §6 does not mention `WITH CHECK` explicitly, but best-practice for row-ownership policies is to include it explicitly so the policy's intent is self-documenting and not dependent on a reader knowing the PG default-WITH-CHECK rule.
- Repro: An attacker cannot exploit this (the default behavior is safe). The finding is a maintainability/audit risk — a future engineer reading the policy may not realize `USING` doubles as `WITH CHECK` on UPDATE policies and may think there is a gap.
- Owner: `@backend-data`

### Minor / nit

**#2: `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` is not explicitly guarded for re-run**
- Where: `02-pins-schema.sql` lines 126, 181
- What: `alter table public.pins enable row level security` and `alter table public.votes enable row level security` have no idempotency guard (no `IF NOT EXISTS` equivalent). In Postgres 15 these are idempotent — running `ENABLE ROW LEVEL SECURITY` on a table that already has RLS enabled does not raise an error — but the file header claims "safe to re-run" and most of the file has explicit idempotency guards. The two `ALTER TABLE` statements are the only exceptions, creating a subtle inconsistency.
- Expected: Either a `DO $$ BEGIN ... IF NOT (select relrowsecurity from pg_class ...) END $$` guard, or at minimum a comment noting that these are idempotent in PG 15.
- Repro: Not a runtime issue on Supabase PG 15. Would fail only on Postgres < 9.5 (not applicable here).
- Owner: `@backend-data`

**#3: Active spatial index name deviates from spec**
- Where: `02-pins-schema.sql` line 119 (`pins_active_spatial_idx`) vs. spec §5 (`pins_active_idx`)
- What: The spec §5 calls the active partial index `pins_active_idx`. The SQL uses `pins_active_spatial_idx`. No functional impact — index names are arbitrary. But if any downstream tooling or documentation references the spec name, it will not find the index.
- Expected: Name match, or a comment in the spec noting the rename.
- Owner: `@backend-data` (or `@tech-lead` to update spec if the rename is intentional)

### Out of Scope (logged, not fixed)

**INFO-1: `tier1-open-data-ingest-spec.md` §3.6 has an internal ON CONFLICT / index mismatch**
- The ingest spec §3.6 shows `ON CONFLICT (pin_type, (meta->>'permit_id'))` which would require a two-column unique index, but §3.6 then defines (and §5 confirms) a partial unique index on only `(meta->>'permit_id') WHERE pin_type = 'filming'`. The 02b file correctly implements the partial index that §5 specifies. The inconsistency is only in the `ON CONFLICT` call syntax in §3.6 of the ingest spec — the ingest job (not yet written) will need to use `ON CONFLICT ((meta->>'permit_id')) WHERE pin_type = 'filming'` to match the index. This finding is against `docs/tier1-open-data-ingest-spec.md`, not the SQL files under review. Owner: `@tech-lead` to correct §3.6 before the ingest job is written.

---

## Scope-Specific Checks (from QA brief)

### Frozen `now()` bug — confirmed fixed
The QA scope specifically asked to confirm the frozen-`now()` partial-index predicate bug is actually fixed. It is. The spec §5 had `where resolved_at is null and (expires_at is null or expires_at > now())`. The SQL at line 119–121 uses `where resolved_at is null` only, with an explicit comment at lines 113–117 explaining that `expires_at > now()` was intentionally removed because `now()` in a DDL partial index predicate is evaluated at index-creation time and would be frozen, making the predicate useless for future rows. The `expires_at > now()` filtering is documented to happen at query time via `pins_expires_at_idx`. This is correct and the bug is genuinely fixed, not just claimed.

### RLS anon write gap
No gap found. Static proof for each write path:
- `pins` INSERT: requires `auth.uid() is not null`. Anon has `auth.uid() = null`. Rejected.
- `pins` UPDATE: `using (auth.uid() = author_id)`. Anon: `null = author_id` = `NULL`. Not TRUE. Rejected.
- `pins` DELETE: `using (auth.uid() = author_id)`. Same analysis. Rejected.
- `votes` INSERT: `with check (auth.uid() = user_id)`. Anon: `null = user_id` = `NULL`. Not TRUE. Rejected.
- `votes` UPDATE: `using (auth.uid() = user_id)`. Anon: rejected.
- `votes` DELETE: same. Rejected.

### `extend_pin_expiry` anon rejection
Confirmed. Lines 244–246: `if auth.uid() is null then raise exception 'authentication required' using errcode = 'insufficient_privilege'; end if;`. Despite the function being `SECURITY DEFINER` (which is correct — it needs to bypass author-only UPDATE RLS to let any authenticated user extend an ephemeral pin), it explicitly checks `auth.uid()` before any data operation. An anonymous caller receives a Postgres exception with `errcode = 'insufficient_privilege'`, which Supabase PostgREST surfaces as a 403. Correct.

### Two-axis indexes (source, lifespan), expires_at, votes.pin_id
All present:
- `pins_source_idx` on `public.pins(source)` — line 105
- `pins_lifespan_idx` on `public.pins(lifespan)` — line 109
- `pins_expires_at_idx` on `public.pins(expires_at) where expires_at is not null` — lines 87–89
- `votes_pin_id_idx` on `public.votes(pin_id)` — line 175

### Idempotency
Safe throughout with one minor caveat noted in Finding #2. All DDL statements use the appropriate `IF NOT EXISTS` / `IF EXISTS` / `CREATE OR REPLACE` / `DO $$ if not exists $$` guards, except the two `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` statements (idempotent in PG 15 but not explicitly guarded).

### Enum — 10 values matching spec
Confirmed: `filming`, `asp_suspended_today`, `special_event`, `construction`, `sign_correction`, `block_note`, `enforcement_active`, `sweeper_passed`, `broken_meter`, `parked_car` = exactly 10, exact match to spec §4.1.

### Secrets
None found. The files contain no tokens, passwords, anon keys, JWTs, or `pk_`/`sk_` strings.

### `02b-pins-ingest-indexes.sql`
Two `CREATE UNIQUE INDEX IF NOT EXISTS` statements. Both are idempotent, correctly typed as partial unique indexes on JSONB expression columns, scoped to the appropriate `pin_type` via `WHERE` predicates. These match the definition in `docs/tier1-open-data-ingest-spec.md` §5 exactly (verified). The commented `ON CONFLICT` mismatch in the ingest spec §3.6 is an ingest-spec issue, not a 02b issue.

---

## Smoke Tests Run

All static — no local Postgres available.

1. Enum value count: counted directly from DDL lines 19–31. Result: 10 values, all match spec §4.1.
2. Column audit: walked every column in `pins` table definition against spec §4.2 table. All 14 columns present with correct types, nullability, and constraints.
3. `votes` table unique constraint: confirmed `unique (pin_id, user_id)` at line 168.
4. RLS anon write trace: evaluated `auth.uid() is null` path through each INSERT/UPDATE/DELETE policy for both tables using SQL NULL logic. No gap found.
5. `parked_car` author-only read: traced SELECT policy truth table for three cases (anon, wrong-auth-user, correct-author). Correct in all three.
6. `extend_pin_expiry` anon rejection: confirmed explicit `if auth.uid() is null then raise exception` guard precedes any data operation.
7. Frozen `now()` fix: confirmed active spatial index predicate is `where resolved_at is null` only; in-code comment explains why `expires_at > now()` was removed. The `expires_at` runtime filtering is instead handled by `pins_expires_at_idx` at query time.
8. Idempotency sweep: walked every DDL statement in `02-pins-schema.sql` for presence of `IF NOT EXISTS` / `IF EXISTS` / `CREATE OR REPLACE` / `DO $$ if not exists $$`. Two `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` statements lack explicit guards (idempotent in PG 15 but undocumented in the file — Finding #2).
9. Secrets scan: grepped for `eyJ`, `pk_`, `sk_`, `password`, `token`, `anon`, `service_role`, `jwt`. No secrets found.
10. `votes` UPDATE policy default-WITH-CHECK analysis: confirmed behavior is safe (Postgres defaults to USING expression when WITH CHECK is absent on UPDATE policies); flagged as Finding #1 for maintainability.
11. `02b` index definitions cross-referenced against `docs/tier1-open-data-ingest-spec.md` §5. Exact match.
12. Realtime block: confirmed idempotent `DO $$ if not exists ... alter publication ... add table $$` pattern matching `01-mvp-schema.sql` precedent.
13. `pins_with_author` view: confirmed columns `p.*`, `pr.username as author_username`, `pr.reputation as author_reputation` via LEFT JOIN on `profiles.id = pins.author_id`. SELECT granted to `anon, authenticated`.

---

## What Is Working

- The frozen-`now()` partial-index bug is genuinely fixed with a clear explanatory comment — the author understood the DDL-time vs. query-time distinction and implemented the correct workaround.
- Explicit `auth.uid() is null` guard in `extend_pin_expiry` is the right pattern for SECURITY DEFINER RPCs that should still require authentication. Well done.
- `SECURITY DEFINER` on the vote-count trigger is the correct choice — without it, a user voting on another user's pin would be blocked by the `pins_update_own` RLS policy when the trigger tries to increment `confirm_count`.
- The `parked_car` author-only visibility is correctly implemented without a separate RLS policy — it is folded into the single SELECT policy using `OR`, keeping the policy count minimal.
- Idempotency discipline is thorough throughout. `DROP POLICY IF EXISTS` before every `CREATE POLICY` is the right pattern for SQL-editor-rerunnable migrations.
- The two-axis columns (`source`, `lifespan`) have dedicated indexes — this was not in the spec §5 index list but is called out in the QA scope and is present. Good proactive addition.
- `votes_pin_id_idx` is a smart addition: the unique constraint on `(pin_id, user_id)` creates a composite B-tree, but Postgres may not use it efficiently for single-column `pin_id` lookups in the trigger's `COUNT(*)` query. The explicit single-column index makes the trigger O(log n) per vote operation.
- The `02b` file is correctly split from the main schema, correctly idempotent, and correctly references the companion spec.
