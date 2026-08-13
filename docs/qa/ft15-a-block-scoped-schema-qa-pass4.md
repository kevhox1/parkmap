# FT-15/TF2-15 Stream A — Block-Scoped Restrictions Schema — QA Pass 4

**Reviewed:** branch `feat/backend-block-scoped-restrictions-schema` at `d2b35101` (PR #69, commit
"fix(backend): column-level privilege lockdown closes QA pass 3 abuse bypasses (round 4)"), against
`docs/ft15-tf215-temporary-block-restrictions-spec.md` §3.2/§5/§6/§12 and
`docs/qa/ft15-a-block-scoped-schema-qa-pass3.md` (Pass 3). Single file under review:
`supabase/02f-block-scoped-restrictions.sql` (942 lines).

**Verdict: 🟡 ship with caveats — APPLY.** This is the first pass in this file's four-round history
with genuine, live-executed evidence rather than static code reading alone: I installed PostgreSQL 16
locally (not a Supabase project — see Methodology) and actually ran the real `01/02/02b/02d/02f` files
against real roles with real RLS and real column-level grants, then executed every one of Pass 1/2/3's
original bypass repros against the resulting database. All three are genuinely closed. The round's
central technical claim — that a bare column-level `REVOKE` cannot narrow a pre-existing table-level
`GRANT`, and that `REVOKE`-the-table-grant-then-`GRANT`-back-at-column-level is the correct pattern —
is **empirically confirmed**, not just correctly reasoned about. The shipped iOS write path is
confirmed unaffected, live, including the exact columns `insertCrowdPin` sends. I found one new,
real, live-reproduced bypass the builder itself anticipated but assessed incorrectly (§6's "extended
auto-resolve" trust mechanism can be indefinitely defeated by the report's own author via a single
`PATCH resolved_at=null`) — it is real, but narrow, non-amplifying, self-serve-only, and pre-dates all
four rounds of this file, so it does not change the verdict on its own. Recommend applying, fixing the
one finding below in a fast follow-up (not another full re-review cycle), and watching the specific
signal named in "What Kevin should watch for" immediately after apply.

## Methodology — why this pass differs from Passes 1-3

Passes 1-3 each disclosed "no `psql`/Docker available... no SQL in this file was executed anywhere."
That constraint no longer held for this sandbox: `apt-get install postgresql postgresql-contrib`
succeeded and gave me a real, local PostgreSQL 16 server. This is **not a Supabase project** — no
connection to Supabase infrastructure, no production or staging data, nothing that violates "do NOT
apply anything to any Supabase project." I built a throwaway database (`qaharness`) with:

- A minimal `auth` schema (`auth.uid()`/`auth.role()` stubbed via session GUCs I set with `SET LOCAL`
  per simulated request — this is how I impersonate "an authenticated user with JWT claims X" without
  a real Supabase Auth server) and `anon`/`authenticated`/`service_role` Postgres roles with
  Supabase's documented default-privilege pattern (`ALTER DEFAULT PRIVILEGES ... GRANT SELECT, INSERT,
  UPDATE, DELETE ON TABLES TO anon, authenticated` at the schema level) applied *before* creating
  `public.pins` — reproducing the exact "no explicit `grant` statement exists anywhere in this repo,
  yet the shipped write path works" starting condition the whole round-4 argument rests on.
- The real, unmodified `supabase/01-mvp-schema.sql` dependencies, `02-pins-schema.sql`,
  `02b-pins-ingest-indexes.sql`, a trimmed `02d-ingest-cron.sql` (stripped only of the
  `pg_cron`/`pg_net` extension calls, which don't exist outside Supabase's managed infra — the
  `upsert_filming_pin` function body itself is untouched), and the **exact `02f` file under review**,
  copied byte-for-byte via `git show <pinned-sha>:supabase/02f-block-scoped-restrictions.sql`.
- A minimal `storage` schema stub (`storage.buckets`, `storage.objects`, `storage.foldername()`) so
  section 8 could execute too.

I then applied the full file, re-applied it twice more for idempotency, and ran a series of
transaction-scoped test scripts as `authenticated`/`anon`/`service_role` executing the literal repro
steps from Passes 1, 2, and 3, plus new adversarial scenarios of my own. All SQL run is preserved in
this session's scratch directory. **One caveat, disclosed rather than glossed over:** a final batch of
planned tests (AC-S8 ceiling live-repro, a bulk-insert `created_at`-smuggling repro, and a fresh
cross-user `pin_evidence` read repro) was queued but not executed — a tool-permission decision ended
the live-testing phase of this session before that batch ran. Those three items are verified by code
reading only in this pass (same confidence level as Passes 1-3), not freshly live-confirmed here — I
call this out explicitly in the checklist below rather than implying uniform live coverage.

## What I confirmed empirically (not just re-derived from documentation)

1. **The core ACL claim is correct.** Table-level `GRANT INSERT`/`UPDATE` + a column-level `REVOKE` on
   the same table is a **silent no-op** — the client can still write the "revoked" column. Confirmed
   with a minimal reproduction before touching this file's actual SQL at all.
2. **Round 4's actual pattern (`REVOKE` the table-level privilege entirely, then `GRANT` back an
   explicit column list) genuinely narrows write access**, and is idempotent (ran twice, zero errors,
   converges to the same state).
3. **`SELECT` is untouched by section 2b** (it only ever names `INSERT`/`UPDATE`), so RLS policies like
   `pins_update_own`'s `USING (auth.uid() = author_id)` — which requires reading `author_id` — continue
   to work correctly for a legitimate author edit even after `author_id` and other columns are dropped
   from the UPDATE grant. Confirmed with a realistic-shape test (table-level SELECT/INSERT/UPDATE
   granted, then INSERT/UPDATE narrowed exactly as section 2b does, SELECT left alone): a legitimate
   `UPDATE ... WHERE author_id = <self>` on an allowed column succeeded; the same statement targeting a
   revoked column failed with `42501`.
4. **`SECURITY DEFINER` functions bypass column-level ACL restrictions entirely**, running as the
   function owner regardless of the invoking role's grants. Confirmed directly: a role with no
   INSERT/UPDATE privilege on a locked-down column could not write it directly, but calling a
   `SECURITY DEFINER` function that wrote (and backdated) that same column internally succeeded. This
   is the mechanism that makes `refresh_pin_vote_counts()`, `extend_pin_expiry()`,
   `upsert_filming_pin()`, `auto_resolve_on_dispute()`, and `enforce_block_scoped_rate_limit()` itself
   all structurally immune to section 2b's lockdown, exactly as the file claims.
5. **`INSERT ... ON CONFLICT DO UPDATE SET <revoked column>` is also rejected** — Postgres requires
   `UPDATE` privilege (not `INSERT` privilege) for any column named in the `DO UPDATE SET` clause.
   Confirmed with a direct repro. This closes the specific "upsert to sneak a locked column through the
   INSERT branch" vector the task asked me to try.
6. **`block_scoped_report_log` is genuinely append-only from the client's perspective.** RLS enabled +
   zero policies denies `INSERT`/`SELECT`/`UPDATE`/`DELETE` to `anon`/`authenticated` even when a
   table-level grant exists (confirmed with a direct repro matching this table's exact posture) — only
   a `SECURITY DEFINER` function (owner-equivalent, bypasses RLS) can write to it.
7. **The log write and the outer `pins` `INSERT`/`UPDATE` are atomic.** Confirmed directly: a
   `BEFORE INSERT` trigger's side-table write rolls back correctly when a `CHECK` constraint evaluated
   later in the same statement fails. A row that never lands in `pins` cannot leave a phantom log
   entry.

## What I confirmed against the shipped iOS write path (code read, not live — no Xcode/simulator in
this sandbox)

- `ios/WePark/WePark/Services/CommunityPinService.swift`'s `insertCrowdPin` (the **only** write path to
  `rest/v1/pins` anywhere in the shipped iOS codebase — confirmed by grep, no `PATCH`/UPDATE call site
  exists against `pins` anywhere) sends exactly: `pin_type`, `source` (always `"crowd"`), `lifespan`,
  `lat`, `lng`, `author_id` (always), plus optionally `expires_at`, `segment_id`, `zone_id`, `notes`,
  `meta`. **It never sends `created_at`.** Every one of these is present in section 2b's 18-column
  INSERT grant. I then ran this exact payload shape (plus `report_group_id`/`starts_at`, which B3 will
  add per the spec) as `authenticated` against the live harness and it succeeded, log entries included.
- `index.html` (the PWA) has zero references to `"pins"` anywhere — confirmed by grep, matches the
  file's own claim and `HANDOFF.md`'s existing documentation that the PWA doesn't consume community
  pins.

## Live repro results — Pass 1/2/3 bypasses, re-tested against d2b35101

| Repro | Result |
|---|---|
| Pass 1: omit `report_group_id` on crowd `filming` insert | **Rejected** — `pins_block_scoped_report_group_required_chk` violation |
| Pass 3 Finding #1: `UPDATE ... SET source = 'open_data'` on own crowd row | **Rejected** — `permission denied for table pins` (42501), before RLS is even evaluated |
| Pass 3 Finding #2: `INSERT` with explicit backdated `created_at` | **Rejected** — `permission denied for table pins` (42501) |
| Pass 3 Finding #3: insert 5 rows under one `report_group_id`, `DELETE` all 5, reinsert 25 more under the same id | Log correctly retained all 5 rows through the `DELETE`; the 30th cumulative row was rejected with `rate limit exceeded: max 30 block-scoped report row(s)` — the cap is now genuinely cumulative, immune to delete-then-reinsert |
| AC-S3 (Kevin's canonical 4-row batch) | **Succeeds**, all 4 rows + 4 log entries |
| AC-S6 (extended auto-resolve) | **Succeeds** — 3 distinct authenticated users each disputing a `filming`/`session`/`crowd` pin via the real `votes` → `refresh_pin_vote_counts` → `auto_resolve_on_dispute` chain correctly set `resolved_at` |
| AC-S7 (rate limit, 4th distinct group rejected) | **Confirmed** live (same test run that surfaced the Finding #3 table above) |
| `upsert_filming_pin` (open-data ingest RPC, including its `ON CONFLICT DO UPDATE` branch) | **Unaffected** — both the initial insert and the upsert-on-conflict branch succeeded as `authenticated`, post-lockdown |
| `extend_pin_expiry` RPC | **Unaffected** — extended `expires_at` by 15 minutes correctly as `authenticated` |
| `service_role` direct insert | **Unaffected**, once given the same Supabase-standard default-privilege pattern in the harness (section 2b's `REVOKE` statements name only `anon, authenticated`, never `service_role` — confirmed by direct re-read of every statement in section 2b) |

## Acceptance criteria checklist (spec §12, Schema)

- [x] **AC-S1.** Idempotent — **live-verified this pass** (full file applied 3× against a real
      Postgres 16 server, zero errors on any run, including the Storage section once a minimal
      `storage` schema stub was added).
- [x] **AC-S2.** `starts_at`/`report_group_id` nullable, no default breaking existing inserts — verified
      by reading (unchanged from Pass 1) plus indirectly confirmed live: a `service_role` insert of a
      pre-existing pin shape (`asp_suspended_today`, no `starts_at`/`report_group_id`) succeeded
      alongside all the new-shape rows.
- [x] **AC-S3.** 4-row batch insert under unmodified RLS — **live-verified this pass**, see table above.
- [~] **AC-S4.** `pin_evidence` insert as uploader — **live-verified this pass** (succeeded as the
      uploading user). The cross-user-select-returns-zero-rows half of this AC was queued but not
      executed in this pass (see Methodology caveat) — carried forward at Pass 1-3's code-read
      confidence level, unchanged in this diff (confirmed via `git diff` that section 4's RLS policies
      are byte-identical to what Pass 1 already cleared and Pass 2/3 didn't need to re-touch).
- [x] **AC-S5.** Crowd `filming` pin (no `meta.permit_id`) coexists with the open-data unique index —
      **live-verified this pass**: my crowd `filming`/`construction` inserts and `upsert_filming_pin`'s
      `meta.permit_id`-bearing insert coexisted in the same database with no unique-index conflict.
- [x] **AC-S6.** Extended `auto_resolve_on_dispute` — **live-verified this pass**, full real vote flow,
      see table above.
- [x] **AC-S7.** Rate limit (4th distinct group rejected, 3rd succeeds) — **live-verified this pass**.
- [~] **AC-S8.** Hard-ceiling constraint — **not live-verified this pass** (queued, not executed; see
      Methodology caveat). Verified by code reading: the constraint's text is unchanged from the
      version Pass 2 already cleared. Recommend a 30-second live check before or immediately after
      apply (see "What Kevin should watch for" below).

## Findings

### 🟡 Significant

- **#1: `resolved_at` remains fully UPDATE-writable by the pin's own author — an author whose
  block-scoped report was correctly auto-resolved after 3 community disputes can indefinitely undo
  that resolution with a single `PATCH`, defeating one of the spec's two "required" trust mechanisms
  (§6 item 1) for their own report. Live-reproduced. The builder's own PR-body risk assessment of this
  exact gap ("in practice this is low-impact... immediately re-resolved") is empirically incorrect —
  it does not re-resolve immediately, or necessarily at all.**
  - Where: `supabase/02f-block-scoped-restrictions.sql` section 2b's UPDATE grant list (line ~401-405,
    includes `resolved_at`), interacting with `auto_resolve_on_dispute()` (section 6) and the unmodified
    `pins_update_own` RLS policy (`auth.uid() = author_id`, no column restriction beyond section 2b's
    list).
  - What: I live-reproduced the exact scenario end to end: an author inserts a bogus `filming` report;
    3 distinct authenticated users each dispute it via the real `votes` → `refresh_pin_vote_counts` →
    `auto_resolve_on_dispute` chain; `resolved_at` is correctly set and `dispute_count` reaches 3 (the
    trust mechanism working exactly as designed). Then, as the same author, a plain
    `UPDATE public.pins SET resolved_at = null WHERE id = <own row>` — permitted because `resolved_at`
    remains in the section-2b UPDATE grant and `pins_update_own`'s RLS only checks row ownership, not
    which columns are touched — succeeds. After this single statement, the row satisfies the spec's own
    §3.4 Channel 3 fetch predicate (`resolved_at is null AND (expires_at is null OR expires_at > now)`)
    again: `WOULD_RENDER_ON_MAP = true`. The false closure reappears on the map as if the 3 disputes
    never happened.
  - Why the builder's own mitigating claim doesn't hold up: `auto_resolve_on_dispute()` only re-fires
    `AFTER UPDATE OF dispute_count` — i.e., only when *something else* subsequently touches
    `dispute_count` again (a new vote, or an existing voter changing their vote). Nothing forces that to
    happen "immediately," or at all, once the report has already been correctly flagged and presumably
    stopped attracting fresh attention. The row can sit wrongly "active" for an unbounded period —
    up to the 7-day/90-day hard ceiling — unless and until some later, unrelated vote event happens to
    touch this specific pin again.
  - Expected: per spec §6/§11, the extended auto-resolve mechanism is named "required" specifically to
    give disputed block-scoped reports a resolution path other than hard expiry (days to weeks). An
    author unilaterally overriding the community's own 3-dispute verdict on their own content defeats
    that mechanism's entire purpose for exactly the adversarial case it exists to handle.
  - Scope/severity notes, not excuses: this is **not introduced by round 4** — `resolved_at` has been
    unrestricted UPDATE-writable via `pins_update_own` since `02-pins-schema.sql`, predating all four
    rounds of this file, and none of Passes 1-3 flagged it because it wasn't the specific mechanism
    those passes were scoped to stress. Round 4 is the first round with the machinery already built to
    close it cheaply (the same column-list-exclusion pattern already used for `created_at`/`source`/
    `pin_type`/`report_group_id`), and chose not to. It is narrow: self-serve only (an author can only
    do this to their own row, never someone else's — `pins_update_own`'s ownership check is unaffected),
    non-amplifying (doesn't let one author affect other authors' reports or spam new rows), and doesn't
    touch the ceiling or rate-limit mechanisms this round was specifically built to harden. This is why
    it's 🟡, not a fourth 🔴 in this file's history — but it is real, live-confirmed, and should not ship
    silently uncorrected.
  - Repro: as the pin's author, `PATCH /rest/v1/pins?id=eq.<own already-resolved pin> {"resolved_at": null}` — succeeds, `200`. The row now passes Channel 3's fetch filter again.
  - Recommended fix (cheap, same pattern already in this file): add `resolved_at` (and, for the same
    reason `confirm_count`/`dispute_count` are already-accepted-lower-risk per the PR body's own
    reasoning — worth a second look together) to the UPDATE exclusion list in section 2b, the same way
    `created_at`/`source`/`pin_type`/`report_group_id` were excluded. `resolved_at` has no legitimate
    client-side write use case today (it's only ever set by `auto_resolve_on_dispute()`, itself
    `SECURITY DEFINER` and therefore unaffected by the exclusion). This is a one-line addition to an
    already-built mechanism, not new design work — recommend a fast follow-up round, not gating this
    apply on it.
  - Owner: `@backend-data`

### 🟢 Minor / nit

- **#2: Two ACs (AC-S8 ceiling, `pin_evidence` cross-user read) were not freshly live-verified in this
  pass** — queued in the test harness but not executed before the live-testing phase of this session
  ended (see Methodology). Both remain at Pass 1-3's code-read confidence level, and neither's
  underlying SQL changed in round 4 (confirmed via diff), so I don't consider this a reason to withhold
  the APPLY recommendation — but flagging so it isn't silently implied that *everything* in this
  report got the new live-verification treatment. A 2-minute manual check of AC-S8 (`PATCH expires_at`
  past the 7-day ceiling on a `filming` row, confirm rejection) is cheap insurance before Kevin applies.
- **#3: The PR body's confidence framing on the `resolved_at`/`dispute_count` out-of-scope note
  ("immediately re-resolved," "low-impact") should be corrected** in the next revision's revision-
  history comment, independent of whether Finding #1 is fixed in the same pass — a future reader
  skimming that note would reasonably conclude this gap self-heals on its own, which Finding #1 shows
  it does not.

### 💡 Out of scope (logged, agree with categorization)

- `confirm_count`/`dispute_count` remaining INSERT-writable — the builder's own reasoning (a fabricated
  value at INSERT time is silently overwritten by the first real vote via `refresh_pin_vote_counts()`,
  since that function recomputes both from the actual `votes` table on every vote event) is sound and
  consistent with everything I observed in the live votes-flow test. Not independently re-exploited
  live this pass, but no reason to doubt it.
- Everything Passes 1-3 already accepted as out of scope and unchanged in this diff: the rate-limiter's
  benign TOCTOU race (still present, same shape, now against `block_scoped_report_log` instead of
  `pins` — unaffected by round 4's changes in character), `pin_evidence.pin_id` always null in practice,
  `pin_evidence.report_group_id` having no FK, and unpinned `search_path` on the `SECURITY DEFINER`
  functions (pre-existing pattern, not a regression).

## Smoke tests run

- Installed PostgreSQL 16 locally (`apt-get install postgresql postgresql-contrib`) — a bare local
  server, not a Supabase project, no connection to Supabase infrastructure or production/staging data.
- Built a throwaway database (`qaharness`) with a minimal `auth`/`storage` schema stub and
  Supabase's documented default-privilege pattern for `anon`/`authenticated`/`service_role`, then
  applied the real, unmodified `supabase/01-mvp-schema.sql` dependencies (via `02-pins-schema.sql`'s
  own references), `02-pins-schema.sql`, `02b-pins-ingest-indexes.sql`, a trimmed
  `02d-ingest-cron.sql` (extension-declaration lines only removed), and the exact pinned `02f` file
  under review (`git show refs/heads/qa-pass4-pin:supabase/02f-block-scoped-restrictions.sql`).
- Ran the full `02f` file 3× consecutively — zero errors on any run (AC-S1, live).
- Executed every one of Pass 1/2/3's original bypass repros as `authenticated` with `SET LOCAL`-scoped
  `auth.uid()`/`auth.role()` stubs, plus new tests: the `ON CONFLICT DO UPDATE` upsert-smuggling vector,
  the `block_scoped_report_log` direct-write/RLS-deny-all posture, trigger/constraint transaction
  atomicity, `upsert_filming_pin`'s full insert-then-upsert lifecycle, `extend_pin_expiry`, and a
  `service_role` direct insert.
- Ran the real 3-disputer `votes` flow end to end against a real `filming`/`crowd`/`session` pin,
  confirming `auto_resolve_on_dispute()` fires correctly (AC-S6, live) — then, as the author, executed
  the `resolved_at = null` un-resolve attempt that produced Finding #1.
- Read `ios/WePark/WePark/Services/CommunityPinService.swift` in full (via `git show main:...`, the
  currently-shipped file, not any in-progress worktree copy) to confirm the exact column set
  `insertCrowdPin` sends and that no `PATCH`/UPDATE call site to `pins` exists anywhere in the shipped
  app. Cross-checked with `grep -rn "rest/v1/pins" ios/**/*.swift`.
- Grepped `index.html` for `"pins"` — zero matches, confirming the PWA is unaffected.
- Read the full 942-line file end to end, and diffed round 3 (`8ceb59c1`) against round 4 (`d2b35101`)
  to confirm the diff is scoped exactly to section 2b (new) and section 7's guards being re-pointed at
  `block_scoped_report_log` — nothing else in the file touched.
- Confirmed `git branch --show-current` is `main` at the end of this pass; no branch created, no
  commits made, source untouched. `git fetch origin feat/backend-block-scoped-restrictions-schema`
  was pinned to a local ref (`refs/heads/qa-pass4-pin`) immediately after fetch, confirmed against
  `gh pr view 69 --json headRefOid` (`d2b35101...`) before any other git operation.

## What Kevin should watch for immediately after applying

1. **Highest-value single check** (the builder's own top recommendation, and mine independently): from
   the app or a `curl`, attempt to `PATCH` any existing pin's `source` field as its author (e.g.
   `{"source": "open_data"}`) and confirm it now fails (`403`/permission-denied class error), not
   `200`. This is the exact repro that made Pass 3 a blocking DO NOT APPLY.
2. **The concrete first signal that shipped Tier-3 reporting broke:** open the app and submit **any**
   existing crowd report (enforcement/sweeper/broken-meter — the existing, already-shipped report flow,
   not the not-yet-built FT-15 block-scoped flow). If `insertCrowdPin` starts failing, this surfaces as
   `CommunityPinWriteError.httpError(statusCode:)` — the report silently fails to save (no crash, but no
   pin appears on the map, and the app's existing submit-error UI, if any, would show). Do this
   immediately after applying — this migration is specifically designed so this should keep working
   unchanged (confirmed live in this pass), and it's the single fastest way to know if that
   confirmation was wrong on the real project.
3. Watch Supabase's Postgres/API logs for the first few minutes after applying for any
   `permission denied for table pins` (42501-class) errors from real (not test) traffic — that would
   mean some client payload path touches a column this review didn't account for. Given the exhaustive
   grep-based confirmation of the shipped write path's exact column set, I don't expect this, but it's
   the cheapest possible confirmation.
4. If section 8 (Storage) fails on the documented ownership grounds, sections 1-7 — including the new
   privilege lockdown and the append-only rate-limit ledger — are already independently applied and
   safe; no action needed beyond the file's own operator note.

## What's working

- The central technical premise of this entire round — the ACL semantics claim that made the
  difference between "another trigger patch that would produce a fifth bypass" and "actually fixing the
  class" — is correct, and I verified it empirically rather than taking the builder's documentation
  citation on faith, given the stakes of a fourth straight review missing something.
- All three of Pass 3's blocking/significant findings are genuinely, live-confirmed closed, not just
  plausibly closed on a read-through.
- The shipped iOS write path is confirmed unaffected by direct code inspection of the actual production
  file (not a worktree's in-progress copy) and by running its exact payload shape live against the
  locked-down schema.
- `SECURITY DEFINER` isolation — the property the entire rate-limit/auto-resolve/ingest machinery
  depends on to keep functioning after a client-facing privilege lockdown — holds exactly as claimed,
  confirmed for every function that touches `pins`.
- The append-only ledger design is sound: genuinely unwritable by any client role, and atomically
  consistent with the `pins` row it accompanies.
- Four straight rounds of adversarial QA against the same author have progressively closed every
  bypass found, and this round's fix is qualitatively different from the first three — it closes a
  class of bug via a privilege-layer mechanism, rather than patching another instance of the same
  trigger-logic gap. That shows up concretely in this pass finding a genuinely different *kind* of gap
  (a data-mutation trust-mechanism bypass, not a rate-limit/ceiling column-spoofing bypass) rather than
  a fourth variant of the first three.
