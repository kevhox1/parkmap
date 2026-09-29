# Regulars — street_label amendment (PR #119) QA Pass 1 — 2026-09-29

**Reviewed:** branch `backend/regulars-street-label` at `48436a6b`, against `docs/regulars-network-spec.md`'s
"Amendment 2026-09-21 — push copy must be street-accurate" (Kevin's ruling: author-supplied label,
Regulars-only disclosure). Base `3f35344b`. Scope: unapplied DRAFT `supabase/07-regulars-schema.sql`
amendment + undeployed `supabase/functions/send-regular-push/index.ts`. Nothing in this PR is applied or
deployed — Kevin's own gate, as always.

**Verdict: MERGE**

## Summary

This is a clean, small, well-scoped amendment: one nullable `pins.street_label text` column
(insert-only, ≤80-char CHECK, never updatable post-insert) and a corresponding preference of that column
over `zones.name` in `send-regular-push`'s alert body. I stood up my own scratch Postgres 16 instance
(independent of the builder's, and independent of the several other `qa_*`/`wepark_fix_verify` databases
already sitting in this shared cluster), applied the full documented chain
(`00(harness)→01→02→02e→02f(minus Storage)→03(minus pg_cron)→04(minus pg_net)→07`), and independently
reproduced every claim in the PR description with real SQLSTATEs, not by reading comments: 80/81-char
CHECK boundary (`23514`), post-insert UPDATE rejected (`42501`, and I confirmed this is because **no**
UPDATE grant exists on `street_label` anywhere in the chain — table-level UPDATE is genuinely absent from
`pins`' ACL, not merely undocumented), `street_label`+`zone_pushed_at` combined insert still rejected
(`42501`), and both of PR #111's live-reproduced S1 exploit loops (backdated `created_at` on
`regular_notices`, `expires_at` override on `regular_invites`) still dead (`42501`). The push function diff
is exactly what it claims to be — a body-construction change only, no new payload fields, `pin_notes`
still never queried — and I independently confirmed the JSON-encoding path (`JSON.stringify` in
`_shared/apns.ts`'s `sendOnePush`) correctly escapes quotes/backslashes/newlines/emoji in a free-text
label, so a hostile or malformed `street_label` cannot break the APNs payload. The `[60,3600]` head-start
CHECK from PR #111 is untouched, the ceremony inventory (`07 → 09 → deploy → 08`) is unchanged, and docs
annotations are accurate. One 🟢 non-blocking product observation below, nothing blocking.

## Acceptance criteria checklist

- [x] `pins.street_label` nullable, ≤80-char CHECK, insert-only — verified live on scratch Postgres
      (schema inspection + functional INSERT/UPDATE tests, SQLSTATEs 23514/42501 exactly as claimed).
- [x] Chain applies clean and is idempotent — verified (`07` re-applied a second time, zero errors).
- [x] Label round-trips verbatim through `pins` and `pins_with_author` — verified (Test 1/7, exact string
      match including the em dash).
- [x] 80 accepted / 81 rejected (23514) — verified live.
- [x] Post-insert UPDATE rejected (42501) — verified live, by the pin's own author.
- [x] `street_label` + `zone_pushed_at` combined insert still rejected (42501) — verified live.
- [x] No UPDATE grant on `street_label` anywhere in the chain; 02f's table-level REVOKE is the operative
      defense — verified two ways: `information_schema.column_privileges`/`has_column_privilege()` show
      no UPDATE row for `street_label` for `anon`/`authenticated`, AND `pg_class.relacl` for `public.pins`
      shows neither role holds table-level `w` (UPDATE) at all — the REVOKE is real, not just documented.
- [x] S1's two exploit loops (backdated `created_at`, `expires_at` override) still dead — verified live,
      independent of `street_label`'s presence.
- [x] `send-regular-push` diff is body-construction-only, no new payload fields, `pin_notes` never queried
      — verified by full read of the diffed file; grep confirms zero `.from("pin_notes")` calls.
- [x] APNs payload JSON safety for a free-text label (quotes/emoji/newlines) — verified: `sendOnePush` uses
      `JSON.stringify(spec.body)`, standard-library escaping, reproduced independently in Node with a label
      containing `"`, `\`, a literal newline, an em dash, and emoji — round-trips byte-for-byte through
      `JSON.parse`.
- [x] `[60,3600]` head-start CHECK (PR #111) untouched — verified via diff and live constraint inspection.
- [x] Ceremony inventory unchanged, 07 remains one apply — confirmed, see below.
- [x] No tiles/iOS changes — confirmed via `git diff --stat` (6 files: 3 docs, `07.sql`, its test script,
      `send-regular-push/index.ts`).
- [x] No banned words in generated copy, including examples — confirmed; the only "avoid/ticket/fine/
      evasion/dodge" hits in the diff are inside the comment that *names* the banned-word list, not actual
      copy.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

None.

### 🟢 Minor / nit

- **#1: `street_label` is the first genuinely free-text field to flow into a *visible* push notification
  body.** Before this amendment, the location segment of a Regulars push body was always `zones.name` — a
  small, curated, non-user-writable set of real zone names. After this amendment, when present, it's an
  arbitrary ≤80-char string the pin's own author typed, rendered directly in a lock-screen-visible
  notification banner with zero moderation (matches the PR's own stated posture — same as
  `pin_notes.body`/`regular_notices.body`, neither of which is filtered either). This is a real, if modest,
  escalation in exposure surface versus the pre-amendment state, because a lock-screen banner is
  potentially glanceable by a bystander near the recipient's phone without the recipient ever opening the
  app — unlike `pin_notes`/`regular_notices`, which require an in-app tap to read. Mitigating factors,
  which is why this is 🟢 not 🟡: (a) recipients are already mutual, consenting Regulars (invite +
  redemption both required), not strangers; (b) `authorName` (the user's own `profiles.username`) has
  already been flowing into this same visible push body unfiltered since S3 — this amendment adds a second
  free-text field to an existing pattern, it doesn't invent visible-unfiltered-user-text as a new class;
  (c) `regular_blocks` already provides an after-the-fact remedy. Not a blocker; worth a line in a future
  Regulars abuse-handling pass if Kevin wants one, not this PR's job to solve.
- **#2 (💡, not really a finding): an empty-string `street_label` (`''`) passes the CHECK** (`char_length`
  bounds only the *upper* end, not a minimum of 1) and would be silently treated as "no label" by
  `pin.street_label || zoneName`'s truthiness check in `send-regular-push`, falling back to `zones.name`.
  This is almost certainly the correct behavior (an empty label shouldn't produce an empty body segment or
  a dangling `" — "`), so I'm not filing it as a gap — just flagging that it's implicit, not asserted by
  any test in Section 16. A trivial future addition (`char_length(street_label) >= 1`) would make the
  intent explicit if anyone cares.

### 💡 Out of scope (logged, not fixed)

- Tap-through deep-link (the amendment's "at least" floor) is unchanged — still S13's scope, correctly not
  touched here, and correctly stated as such in both the spec's "IMPLEMENTED IN DRAFT" note and
  `docs/regulars-roadmap.md`'s S13 row.
- Client-side population of `street_label` at `leaving_soon` insert (S9) is not built yet — correctly
  scoped out, and `docs/regulars-roadmap.md`'s S9 row is correctly annotated with the new requirement
  (≤80-char client-side mirror of the server CHECK).

## Cross-PR coherence

- **07 on this branch vs. 07 on `main`:** diffed directly (`git diff 3f35344b..qa-pr119 --
  supabase/07-regulars-schema.sql`) — the only changes are the amendment header comment, the new
  `street_label` column/CHECK/comment, its addition to the existing insert-only GRANT, and its append to
  `pins_with_author`'s explicit column list. Nothing else in the file moved. Confirmed no drift against
  PR #111's QA-locked constraints: `regulars_head_start_seconds`'s `[60,3600]` CHECK is byte-identical
  (`pins_regulars_head_start_seconds_check` — verified via `pg_get_constraintdef` on my scratch instance),
  and the two S1 exploit-column lockdowns (`regular_notices.created_at`, `regular_invites.expires_at`) are
  untouched and still empirically dead.
- **Ceremony docs:** `docs/regulars-roadmap.md`'s "Kevin's ceremonies" section (the 9-step
  `07 → 09 → deploy → 08` checklist) is unmodified by this PR — verified by reading the section directly
  off `qa-pr119`; the new "Amendment 2026-09-21" block above it explicitly and correctly states "this does
  not change 07's apply status or the push-pipeline ceremony." `docs/open-items.md` #23 and the S9 row in
  `docs/regulars-roadmap.md` are both accurately annotated with this PR's scope and what's still deferred.

## Smoke tests run

All against my own scratch Postgres 16 instance (`qa_pr119_streetlabel`, a fresh database in the shared
local cluster — not reused from any other agent's `qa_*`/`wepark_fix_verify` database already present),
built from a from-scratch minimal Supabase-shape harness (`auth.users`, `auth.uid()` GUC stub, `anon`/
`authenticated`/`service_role` roles with `ALTER DEFAULT PRIVILEGES ... GRANT ALL` matching the Supabase
project-template default, stub `supabase_realtime` publication):

- Applied `00(harness)→01→02→02e→02f(minus Storage section)→03(minus pg_cron section)→04(Section A
  only, pg_net section stripped — extension unavailable in this sandbox, same precedent prior QA passes
  established)→07` — clean, zero errors.
- Re-applied `07` a second time — zero errors, confirming idempotency.
- `leaving_soon` insert with a valid `street_label` → 201-equivalent success, round-trips verbatim
  (including the em dash).
- `leaving_soon` insert with no `street_label` → succeeds, column stays null.
- `street_label` at exactly 80 chars → accepted.
- `street_label` at 81 chars → rejected, `sqlstate=23514` (`pins_street_label_check`), confirmed via a
  `DO`/`EXCEPTION` block that prints the actual SQLSTATE, not inferred from a generic error.
- Post-insert `UPDATE street_label` by the pin's own author → rejected, `sqlstate=42501`.
- Insert with `street_label` + `zone_pushed_at` together → rejected, `sqlstate=42501`.
- Regression: `regular_notices` backdated `created_at` → rejected, `sqlstate=42501`. `regular_invites`
  `expires_at` override (`now() + 50 years`) → rejected, `sqlstate=42501`.
- `pins_with_author` surfaces `street_label` correctly; column list confirmed append-only (28 columns,
  `street_label` last).
- Privilege proof (not just read from comments): `information_schema.column_privileges` and
  `has_column_privilege('authenticated', 'public.pins', 'street_label', 'UPDATE')` both confirm **no**
  UPDATE privilege exists on `street_label` for `anon`/`authenticated`; `pg_class.relacl` for
  `public.pins` confirms neither role holds table-level UPDATE (`w`) at all — `02f`'s REVOKE is the real,
  operative defense, not merely asserted in a comment.
- `send-regular-push/index.ts` full read: confirmed `pin_notes` is referenced only in comments, never
  queried (`grep -n "pin_notes"` → 4 hits, all in `//`/`/* */` comments); confirmed the APNs payload's
  top-level keys are unchanged from pre-amendment (`pin_type`, `pin_id`, `author_id`, `segment_id`,
  `zone_id`, `leaving_minutes`, `regulars_head_start_seconds`) — only `aps.alert.body`'s construction
  changed.
- APNs JSON-encoding safety: read `_shared/apns.ts`'s `sendOnePush` — body is sent via
  `JSON.stringify(spec.body)` (standard library, not manual string concatenation). Independently
  reproduced in Node with a label containing a double quote, a backslash, a literal newline, an em dash,
  and emoji — the resulting JSON string round-trips byte-for-byte through `JSON.parse`, confirming no
  payload-corruption risk from adversarial label content.
- `git diff --stat` against `main`: confirmed exactly 6 files touched (3 docs, `07-regulars-schema.sql`,
  `07-regulars-schema-test.sh`, `send-regular-push/index.ts`) — no tiles, no iOS files.
- Grepped the full diff for banned words (avoid/ticket/fine/evasion/dodge) — the only hits are inside the
  comment that names the banned-word list itself, not actual generated copy.
- Read `docs/regulars-network-spec.md`'s "Amendment 2026-09-21" section and its "IMPLEMENTED IN DRAFT"
  follow-up, `docs/regulars-roadmap.md`'s new amendment block + S9 row, and `docs/open-items.md` #23 —
  all three are accurate against what the diff actually does.

## What's working

- The insert-only, never-updatable posture is not just claimed — it's real and independently proven at
  the SQLSTATE level, including the specific adversarial case (street_label + zone_pushed_at in the same
  insert) that would matter most if someone tried to piggyback a privilege escalation on this amendment.
- The push function change is genuinely minimal and exactly matches its own PR description — I found no
  scope creep (no new fields, no re-introduction of a `zones` fetch when a label is present, no accidental
  widening of any grant).
- Test coverage (`07-regulars-schema-test.sh` Section 16) matches the live behavior I independently
  reproduced line-for-line, including the correct HTTP-status-per-SQLSTATE convention this repo already
  established (23514→400, 42501→403 for `authenticated`).
- Docs hygiene is clean — three separate doc files (spec, roadmap, open-items) all got consistent,
  accurate annotations in the same PR, and the ceremony checklist was correctly left untouched rather than
  redundantly re-stated.
