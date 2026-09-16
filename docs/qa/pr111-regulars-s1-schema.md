# Regulars S1 Schema QA — 2026-09-16

**Reviewed:** branch `backend/regulars-s1-schema` at `f4fe62f8` (base `f03a4682`), against
`docs/regulars-network-spec.md` §2 **AS AMENDED on `main` @ `cb464c65`** (§0 decisions 6–8, §2.1,
§2.6, §2.10). Files: `supabase/07-regulars-schema.sql` (709 lines), `supabase/07-regulars-schema-test.sh`
(440 lines, 42 assertions), `docs/regulars-roadmap.md` (133 lines), `docs/open-items.md` (+1 row).

**Verdict: 🔴 FIX-THEN-MERGE — do not apply to production as drafted.**

The trust-graph design itself (deny-by-default RLS, RPC-only edge writer, race-safe redemption,
block-severs-edge, RETURNING/SELECT closure) is genuinely solid and empirically verified against a
real Postgres instance — every happy-path and adversarial RLS scenario I threw at it behaved exactly
as spec'd. But this migration reintroduces, on two brand-new tables, the *exact* rate-limit-bypass bug
class this same repo already found and fixed once (`docs/qa/ft15-a-block-scoped-schema-qa-pass3.md`,
Finding #2, closed in `02f-block-scoped-restrictions.sql` via table-level REVOKE + column-level
re-GRANT). I reproduced it live: an authenticated client can backdate `created_at` on
`regular_notices`/`regular_invites` INSERT and defeat both rate limits without bound, and can set
`regular_invites.expires_at` to any future date, defeating the invite's 10-minute TTL entirely. Neither
table applies the column-privilege lockdown `pins`/`regular_invites.revoked_at` already use elsewhere
in this exact file. Additionally, the `[15, 3600]` head-start range and the missing future-only CHECK
on `regular_notices.scheduled_for` are real drifts from the amended spec that landed on `main` after
this branch forked — the mid-flight ruling predates the amendment's exact numbers and was never
reconciled.

## Amendment reconciliation (task item 1)

- **`pins.regulars_head_start_seconds` CHECK range: `[15, 3600]`, amended spec requires `[60, 3600]`.**
  Confirmed live — `pins_regulars_head_start_seconds_check` in the applied schema reads `>= 15 AND <=
  3600`; I inserted a pin with `regulars_head_start_seconds = 30` and it succeeded, which the amended
  spec's §2.1 explicitly says must be rejected (Kevin: "15 minutes," not "15 seconds"). This is a
  real, live drift — the commit message's own "MID-FLIGHT RULING ADDENDUM" is honest that it predates
  a formal amendment and says so ("a formal amendment to the spec is being written separately... this
  file does not wait for it"), but the amendment has since landed on `main` (`cb464c65`, merge-base
  `f03a4682` confirms this PR branched before it) with a materially different number, and nobody
  reconciled the two. See Finding #4.
- **§2.6 CHECKs — only one of two present.** The amended spec requires BOTH a future-only CHECK
  (`scheduled_for is null or scheduled_for > created_at`) and a 24h-horizon CHECK. The migration only
  has the 24h-horizon CHECK (`regular_notices_check` in `pg_constraint`); the future-only CHECK does
  not exist anywhere in the file. Confirmed live — I inserted `scheduled_for = now() - interval '1
  day'` and it was accepted, producing a row whose derived `expires_at` (`scheduled_for + 60min`) landed
  **before** its own `created_at`, i.e. a notice that is already expired the instant it's created. This
  is exactly the failure mode the amendment's §2.6 reconciliation note asked S1's QA to check for — it
  described the "far future" direction, but the code has the mirror-image "far past" hole, and the
  actual protecting CHECK was simply never written. See Finding #3.
- **Expiry-anchoring logic itself is correct.** `derive_regular_notice_expiry()` correctly anchors to
  `scheduled_for + 60min` when set, and to `now() + 60min` (functionally `created_at + 60min`) when
  not — this is the one thing the amendment's reconciliation note was most worried about, and it's
  right. The bug is the missing input-validation CHECK around it, not the derivation formula.

## The deferred §2.8 call (task item 2)

**Verified live-safe.** I diffed this migration against `04-community-push-trigger.sql`'s actual,
currently-live `pins_invoke_send_community_push` trigger and confirmed:
- The trigger's `WHEN` clause (`new.source = 'crowd' and new.lifespan = 'ephemeral' and new.zone_id is
  not null`) is untouched by this file — zero grep hits for the trigger or function name anywhere in
  `07-regulars-schema.sql`.
- `leaving_soon` pins already have `lifespan = 'ephemeral'`, so they already match this WHEN clause
  today and will continue to fire the zone-wide push **synchronously at insert**, unchanged, the moment
  this migration is applied. `regulars_head_start_seconds`/`zone_pushed_at` are inert new columns —
  never read by any trigger/function in this file or in `04`. The only incidental effect is that
  `to_jsonb(NEW)` (used to build the push payload) will now include these two extra keys in the JSON
  sent to `send-community-push`; the Edge Function is documented to read only named fields and ignore
  the rest, so this is low-risk, not a behavior change (💡 noted, not a finding).
- **Net effect confirmed: applying this migration changes nothing about the live push pipeline's
  timing or content today.** The reasoning in the file's own SCOPE NOTE holds up under an actual diff,
  not just a read of the comment.

## Adversarial RLS + abuse (task items 3–4) — live-verified against a scratch Postgres 16 instance

I stood up my own local Postgres cluster (not reusing the builder's), built a minimal Supabase-shape
harness (`auth.users`, `auth.uid()` stub reading a session GUC, `anon`/`authenticated` roles with
`ALTER DEFAULT PRIVILEGES ... GRANT ALL` matching the project-template default `02f` documents), applied
`07-regulars-schema.sql` verbatim (clean, idempotent, zero errors, confirmed by re-running it twice),
and drove every scenario below as `SET ROLE authenticated; SET request.jwt.claim.sub = '<uuid>'` —
confirmed RLS actually engages under this setup with a direct sanity check (an unrelated bare INSERT
into `regular_edges` correctly threw `new row violates row-level security policy`).

**What's solid (all live-verified, not just read):**
- `regular_edges` has genuinely no client INSERT path of any kind — confirmed by direct attempt.
- Full invite lifecycle works exactly as spec'd: A creates invite → A redeeming their own token returns
  `cannot_add_self` → B redeems → `ok:true`, edge visible to A and B, invisible to stranger C → B
  re-redeeming the same token returns `expired_or_used` → A blocks B → the A-B edge is deleted in the
  same transaction as the block insert → A creates a new invite → blocked B attempting to redeem it
  gets `blocked` → B querying `regular_blocks` about themselves sees zero rows (cannot discover being
  blocked).
- `pin_notes`: ownership trigger correctly rejects a mismatched `(pin_id, author_id)` pair even though
  it passes the table's own RLS check; a Regular of the pin's author sees the note, a non-Regular
  stranger gets zero rows (RLS-filtered, not a 403) — matches the amended standing-privacy-rule
  extension exactly.
- No `search_path` pinning on any of the 6 new `SECURITY DEFINER` functions — confirmed via
  `pg_proc.proconfig` — but every reference inside them is schema-qualified (`public.`/`auth.`), so
  this is the same pre-existing, already-accepted repo convention `docs/qa/pr93-community-phase0-schema.md`
  called "out of scope," not a new gap. 💡, not a finding.
- Mutuality representation: one canonically-ordered row (`low_user_id < high_user_id`), not a symmetric
  pair — confirmed the redemption RPC's `least`/`greatest` + `on conflict (low_user_id, high_user_id) do
  nothing` correctly targets this single-row representation; a second invite between an already-Regular
  pair still returns `ok:true` with no duplicate/error.

### 🔴 New findings, live-reproduced

**Finding #1 — `regular_notices`' 10/1h rate limit is fully bypassable by backdating `created_at` on INSERT.**
No column-privilege lockdown exists on `regular_notices.created_at` (unlike `pins.created_at`, which
`02f` already REVOKEd/re-GRANTed for exactly this reason). Under the harness's Supabase-template-default
privileges (confirmed accurate per `02f`'s own extensive documentation of this exact default), an
authenticated client can INSERT with an explicit past `created_at`, which the trigger's `count(*) ...
where created_at > now() - window` never counts. Live repro: 15 sequential backdated inserts, zero
rejections, 16 total rows for one sender (cap is 10/hour). Each of these rows would still fire a real,
immediate push to every one of the sender's actual Regulars once S3's push trigger lands (the AFTER
INSERT event fires regardless of the stored `created_at` value) — this is a live spam vector against
real users, not just a bookkeeping curiosity, the moment a later session wires up delivery.

**Finding #2 — `regular_invites`' 20/24h rate limit is bypassable the same way, AND `expires_at` is
independently client-settable, defeating the 10-minute invite TTL.**
Same missing column lockdown, this time on two columns. Live repro: (a) 25 backdated `regular_invites`
inserts, zero rejections, 26 rows for one creator (cap is 20/24h); (b) a single INSERT with an explicit
`expires_at = now() + 50 years` succeeded and returned that value verbatim — nothing in the file
prevents a client from minting an invite that never expires. Blast radius is lower than Finding #1
(unredeemed invites are inert, and redemption is still single-use/consent-gated per-token), but it is a
real, live violation of the spec's stated "10-minute TTL" security property, and the token could remain
live and redeemable by whoever finds/screenshots the QR code far longer than the UX communicates.

**Why these are 🔴, not 🟡:** this isn't a novel discovery — it is the *identical* bug class
`02f-block-scoped-restrictions.sql`'s own revision history documents fixing, three QA rounds deep, for
`pins.created_at`/`source` ("A client can set an arbitrary `created_at` on INSERT, making the row
permanently invisible to both guards' window filters... via a pure INSERT loop"). That fix (table-level
`REVOKE` + column-level re-`GRANT`, *not* a bare column-level `REVOKE`, which is documented in the same
file as a silent no-op against a table-level grant) is a known, load-bearing pattern in this exact
migration file already — it's applied correctly to `pins.zone_pushed_at` and to
`regular_invites.revoked_at`. It was simply never extended to `regular_notices.created_at`,
`regular_invites.created_at`, or `regular_invites.expires_at`, the three columns that actually need it
here. This is a mechanical gap, not a design flaw, and should be a small, fast fix:
```sql
revoke insert on public.regular_notices from anon, authenticated;
grant insert (sender_id, body, scheduled_for) on public.regular_notices to anon, authenticated;

revoke insert on public.regular_invites from anon, authenticated;
grant insert (created_by) on public.regular_invites to anon, authenticated;
```
(`regular_notices.expires_at` needs no equivalent lockdown — its `BEFORE INSERT` trigger
unconditionally overwrites `new.expires_at` regardless of client input, verified live; this is already
correct and is the one column of the four I checked that isn't a problem.)

### 🟡 Significant

**Finding #3 — `regular_notices.scheduled_for` is missing the amended spec's future-only CHECK.**
Covered under "Amendment reconciliation" above. Fix: add
`check (scheduled_for is null or scheduled_for > created_at)` alongside the existing 24h-horizon CHECK.

**Finding #4 — `pins.regulars_head_start_seconds` CHECK is `[15, 3600]`, amended spec locks `[60, 3600]`.**
Covered above. This also means `docs/regulars-roadmap.md`'s own restated guard-test name
(`testAppConstants_regularsHeadStartRange_matchesServerClamp`) currently points iOS at the wrong number
if built against this file as-is — a same-file, self-consistent drift, but the wrong target relative to
what's now locked on `main`.

**Finding #5 — Test script has zero coverage for three of §2.10's (amended) required scenarios.**
Counted 42 assertion call sites (`assert_status`/`assert_eq`/`assert_empty_array`, excluding the three
function definitions) — matches the PR's own claim. Missing, all three explicitly named in spec §2.10:
1. Insert a `leaving_soon` pin with `regulars_head_start_seconds=120`, confirm `zone_pushed_at` stays
   null — absent entirely (defensible in isolation, since S1 never sets `zone_pushed_at` — but the spec
   asked for it as a coverage item and it costs nothing to add).
2. Head-start boundary values (59/3601 rejected, 60/900/3600 accepted, amended §2.10 item 1) — absent.
   Would have caught Finding #4 mechanically.
3. `scheduled_for` several hours out, confirm `expires_at` lands past `scheduled_for` not `created_at`
   (amended §2.10 item 2 — the exact item the spec's own reconciliation note asked S1's QA to check) —
   absent. Would have caught Finding #3.

Also no dedicated test exercises the `regular_invite` rate limit at all (only `regular_notice`'s 10/1h
is tested, Section 11) — not explicitly required by §2.10 but an asymmetry worth closing given
Finding #2.

**Finding #6 — `docs/regulars-roadmap.md` is the stale pre-amendment 16-session plan, not the amended 18.**
The amended spec (`cb464c65`) updates the total to "16 core sessions, +2 buffer = 18" and adds S10b
(Scheduled Departure UI) + S12b (its QA) to the session table. `docs/regulars-roadmap.md` as shipped in
this PR still says "Total: ~14 sessions + 2 buffer = 16 sessions" and its session-by-session table only
runs S1–S14 with no S10b/S12b rows at all — it was written the same day as the mid-flight ruling but
before the formal amendment merged, and (like the schema file) was never reconciled against it. This
will misdirect whoever picks up S9/S10 next expecting a 14-session finish line. `docs/open-items.md`'s
new row #23 is internally accurate to what was true when it was written (correctly states `[15,3600]`
and the deferred §2.8), but is now stale for the same reason once read against amended `main`.

### 🟢 Minor / nit

- Migration header correctly carries `DRAFT — DO NOT APPLY` in both the file's first line and its
  title comment; `docs/open-items.md`'s new row also states "NOT applied" explicitly. Ceremony framing
  is correct.
- `regular_notices`'s push-payload `to_jsonb(NEW)`-style extra-field concern noted above under §2.8 is
  low-risk but worth a one-line confirmation from whoever builds S3 that `send-regular-push`/the shared
  `_shared/apns.ts` module's payload parsing is similarly permissive of unknown keys.

## Race + abuse (task item 4) — race safety independently verified

`redeem_regular_invite()`'s `SELECT ... FOR UPDATE` + `redeemed_at is null` predicate is genuinely
race-safe by construction (verified by code trace, matching `claim_pin`'s proven shape — true
concurrent-session locking isn't reproducible in a single-connection psql harness, but the mechanism is
the same row-lock-serialization pattern already proven correct for `claim_pin`, and the sequential
double-redeem test above confirms the loser path returns `expired_or_used`, never a second edge). The
`on conflict (low_user_id, high_user_id) do nothing` net on the `regular_edges` insert is a real,
independent second safety net — confirmed live that a second invite/redemption between an
already-Regular pair still reports `ok:true` with zero duplicate/conflicting rows, matching the
comment's stated reasoning. Mutuality is stored as **one row**, canonically ordered — not two symmetric
rows — confirmed. No reputation trigger anywhere in this file touches `profiles.reputation` or any
`*_count` column; grepped the full 709-line file for `reputation`/`helped_count`/`total_report_count` —
zero hits outside comments discussing the existing, unrelated Community 2.0 triggers. No rep-farming
surface is introduced by this migration.

## Test script run-shape audit (task item 5)

- 42 assertion call sites confirmed by direct count, matching the PR's claim.
- 401-vs-403 convention: Section 2 (true-anon, no session) correctly uses the established lenient
  `401 or 403` OR-check, matching this repo's own precedent in `03-community-2.0-test.sh` Test 1
  (verified against that file directly — the OR-check is the established convention here, not a
  weakening introduced by this PR). Section 3 (an authenticated-but-RLS-denied session) correctly
  asserts a strict `403`. This is the right split, correctly implemented.
- Coverage gaps: see Finding #5.

## Docs (task item 6)

- Migration header: DO-NOT-APPLY present and correctly worded. ✅
- `docs/regulars-roadmap.md`: stale 16-session plan, missing S10b/S12b. See Finding #6.
- `docs/open-items.md` row #23: accurate to its own write-time state, stale relative to amended `main`
  for the same reason as the roadmap. See Finding #6.

## Kevin's apply ceremony, when it eventually runs (S1 merging does NOT trigger this)

Per the spec's ceremony plan (§5, "Kevin's ceremonies") and this file's own header, merging this PR to
`main` changes nothing in production by itself. When S2's fixes clear and Kevin is ready to actually
apply S1:
1. Paste `supabase/07-regulars-schema.sql` (post-fix) into the Supabase SQL Editor for project
   `jiispshyqerscdoferaw` — single paste, no STEP 1/STEP 2 split needed (confirmed: no new enum value is
   added in this file).
2. Run `select count(*) from public.regular_edges;` etc. as a smoke sanity check (all new tables should
   read 0 rows).
3. Run `supabase/07-regulars-schema-test.sh` (post-fix, with the added §2.10 coverage) against the live
   project with a real anon key.
4. Nothing else changes — the live `send-community-push` trigger, `claim_pin`, and every existing pin
   write path are byte-identical before and after, confirmed above. **S1's apply is independent of and
   does not require the deferred §2.8 follow-up** (push-trigger rewrite + 30s sweep) — that lands as its
   own, separately-applied migration and ceremony per the roadmap's own S1-follow-up row.

## Smoke tests run

- Stood up an independent local Postgres 16.15 cluster (`initdb`/`pg_ctl`, run as the `postgres` OS
  user, not reusing the builder's instance), built a minimal Supabase-shape harness (`auth.users`,
  `auth.uid()` GUC stub, `anon`/`authenticated` roles with default-privilege grants matching the
  documented Supabase project-template default), and applied `07-regulars-schema.sql` verbatim —
  clean apply, re-ran a second time to confirm the file's own idempotency claim (all `DROP ... IF
  EXISTS`/`CREATE ... IF NOT EXISTS` guards fire correctly, zero errors on re-run).
- Sanity check that RLS actually engages under `SET ROLE authenticated` in this harness (a bare
  unrelated `regular_edges` insert correctly threw the RLS violation) before trusting any subsequent
  "this is denied" result.
- Live-drove: full invite create → redeem → re-redeem → self-redeem → block → block-then-redeem →
  blocked-party-cannot-discover-block flow (all outcomes matched spec exactly); `pin_notes` ownership
  trigger + cross-user visibility; the `regular_notices`/`regular_invites` rate-limit bypass via
  backdated `created_at` (16/10 and 26/20 rows respectively, zero rejections); `regular_invites.expires_at`
  client-override to +50 years; `regulars_head_start_seconds = 30` acceptance (confirms the `[15,3600]`
  vs. amended `[60,3600]` drift); `regular_notices.scheduled_for` in the past acceptance, producing
  `expires_at < created_at`; `pg_proc.proconfig`/`pg_constraint` introspection for `search_path`
  pinning and the exact CHECK definitions actually in the database (not just the file text).
- Diffed `07-regulars-schema.sql` against the live `04-community-push-trigger.sql` trigger/function
  definitions directly (not just read the migration's own claim) to verify zero behavioral change to
  the live push path.
- Counted test-script assertions directly; read the full 440-line script end to end against §2.10's
  (amended) checklist line by line.
- Read `docs/regulars-roadmap.md` and the `docs/open-items.md` diff in full against the amended spec on
  `main`.
- Did not test: true concurrent-session race on `redeem_regular_invite()` (single-connection harness;
  verified by code trace against the proven `claim_pin` pattern instead, consistent with this repo's
  prior QA passes' own stated constraints on this point); PostgREST-layer HTTP status codes specifically
  (verified the SQL/RLS layer directly against a raw connection rather than standing up PostgREST itself
  — the test script's own HTTP-layer assertions were read and audited for shape/coverage, not executed
  against a live PostgREST instance).

## What's working

The trust-graph core is well-built: canonical single-row mutuality, a genuinely race-safe RPC modeled
correctly on `claim_pin`, a block trigger that provably severs the edge in the same transaction, an
invite table that correctly closes the S11/PR#100 RETURNING-needs-SELECT lesson on every single
writable path I checked (including the DELETE path, which is easy to forget), and a `pin_notes`
ownership trigger that closes a gap RLS genuinely cannot close on its own (pin ownership + pin_type,
not just author identity). The `04-community-push-trigger.sql` interaction was reasoned about
correctly and — this is the part worth calling out — actually verified true under a direct diff, not
just asserted in a comment. The two 🔴 findings are a narrow, mechanical gap (a known fix pattern not
yet extended to two new tables) sitting inside an otherwise carefully-built file, not a sign the design
needs rework.
