# Regulars S3 (send-regular-push) QA — 2026-09-18

**Reviewed:** branch `backend/regulars-s3-push` at `0c37b0e6` (base `7fa96bab`), against
`docs/regulars-network-spec.md` §2.8/§2.9, `docs/regulars-roadmap.md`'s S3 row, and PR #112's own body
(resolved ambiguities section). Files: `supabase/functions/send-regular-push/index.ts` (new, 380
lines), `supabase/functions/_shared/apns.ts` (new, 256 lines), `supabase/functions/send-community-push/index.ts`
(modified, 444→277 lines), `supabase/08-regulars-push-trigger.sql` (new, 168 lines),
`supabase/08-regulars-push-trigger-test.sh` (new, 303 lines), `docs/regulars-roadmap.md` (+1 row),
`docs/open-items.md` (+1 row).

**Pass 1 verdict: 🟡 FIX-THEN-MERGE — one doc-only blocking finding, everything else clean.**

**Superseded by Pass 2 below — see final verdict there.**

## Summary

The code itself is solid: the `_shared/apns.ts` extraction is verifiably behavior-preserving (confirmed
by a direct line-by-line diff, not just trusting the PR's `tsc` claim), `send-regular-push` never
touches `pin_notes`, its targeting query is empirically safe against blocked/removed Regulars, and the
new trigger correctly mirrors `04`'s hard-won fail-open posture — all independently reproduced live on
a scratch Postgres 16 instance I stood up myself. The one real problem is not in the SQL or TypeScript,
it's in the **ceremony documentation**: I confirmed live that inserting a `leaving_soon` pin fires
`send-community-push` (zone-wide, instant, unmodified) and `send-regular-push` (visible, instant, new)
**in the same trigger execution, regardless of `regulars_head_start_seconds`'s value** — the "head
start" is completely inert until the still-unscheduled S1-follow-up session lands. The PR's own SQL
comments and PR body disclose this honestly, but the roadmap's actionable "Kevin gate at end" cell for
the S3 row (and the PR body's own numbered ceremony list) both omit any gate on S1-follow-up having
landed first — a real risk that Kevin, executing the documented steps literally, ships a real
production behavior change (new visible pushes to real Regulars) whose entire premise (Regulars-first)
does not yet exist. This is a one-paragraph doc fix, not a code fix.

## Acceptance criteria checklist

- [x] `send-regular-push` targets Regulars by `user_id` via `regular_edges`+`device_push_tokens`, not
  `zone_id` — verified by code read and by a live SQL-level proof that a blocked pair's edge is gone
  from the graph the function's own query reads.
- [x] Visible, content-bearing payload (`alert.title`/`alert.body`, `pushType:"alert"`, `priority:"10"`)
  — verified by code read against `_shared/apns.ts`'s `ApnsRequestSpec`.
- [x] `pin_notes` text is never read or included — verified: zero `.from("pin_notes")` call sites in
  `send-regular-push/index.ts` (grep-confirmed), only comments reference the table.
- [x] `_shared/apns.ts` extraction is behavior-preserving for the live `send-community-push` — verified
  by direct pre/post diff: identical `aps.content-available`/`pin_type`/`segment_id`/`pin_id`/`zone_id`
  body, identical `apns-push-type:"background"`/`apns-priority:"5"`, identical secret names, identical
  token/environment query, identical dead-token-classification and response-shape logic.
- [x] `08`'s trigger mirrors `04`'s Vault-read-inside-exception-block fail-open pattern — verified live:
  with `vault`/`net` schemas absent, a `leaving_soon` insert survives and logs a caught `vault_read`
  stage failure, never an aborted INSERT.
- [x] `08` does not modify `04`'s WHEN clause or add a cron job — verified: `git diff` on
  `04-community-push-trigger.sql` between base and this PR is empty; `08`'s own file has no
  `cron.schedule` call.
- [x] `07`→`08` apply cleanly and idempotently on a fresh scratch Postgres 16 — verified live (full
  chain `01→02→02b→02c→02d→02e→02f→02g→03→04→05→06→07→08` applied clean; `07`/`08` re-applied a
  second time back-to-back, zero errors).
- [x] A zero-Regulars author's `leaving_soon` insert is unaffected — verified live (insert survives,
  trigger still invokes `send-regular-push`'s endpoint per spec's "unconditional, cheap no-op" design).
- [x] A non-`leaving_soon` pin (`open_spot`) never fires `send-regular-push` — verified live (only a
  `send-community-push` log line appears for that insert).
- [x] `regulars_head_start_seconds` clamp `[60,3600]` still holds (S1 scope, re-verified since S3
  depends on it) — verified live: 59 and 3601 rejected, 60 and 3600 accepted.
- [x] No banned copy words (avoid/ticket/fine/evasion/dodge) in any generated string — verified by
  direct read of every template literal in `send-regular-push/index.ts`.
- [x] A blocked/removed Regular cannot receive a push — verified live: `regular_blocks` insert deletes
  the corresponding `regular_edges` row in the same transaction (existing S1 trigger), and the exact
  query `send-regular-push` runs against `regular_edges` for the (former) author returns zero rows
  post-block.
- [ ] **The eventual deploy/apply ceremony, as documented in this PR, cannot be safely executed as
  written without silently defeating the feature's entire premise.** FAILED (pass 1) — see Finding #1.
  **FIXED in pass 2 — see below.**

## The key semantic ruling — is the head start inert until §2.8 lands?

**Yes, ruled definitively, live-reproduced, not just read.** `04-community-push-trigger.sql` is
untouched by this PR (`git diff` confirms zero lines changed) — its WHEN clause
(`source='crowd' and lifespan='ephemeral' and zone_id is not null`) still fires
`pins_invoke_send_community_push` **synchronously, at INSERT time**, for every `leaving_soon` pin,
exactly as it does today. `08`'s new `pins_invoke_send_regular_push` trigger fires **immediately and
unconditionally** on the same `leaving_soon` insert (by design — "the whole point of head start," per
the file's own SCOPE NOTE). I inserted a `leaving_soon` pin with `regulars_head_start_seconds = 900`
(15 minutes) against my scratch instance with both triggers live, and both fired **in the same
statement**, logged within milliseconds of each other:

```
LOG:  send-community-push: vault_read stage failed for pin be98bdf8... (sqlstate 42P01): relation "vault.decrypted_secrets" does not exist
LOG:  send-regular-push: vault_read stage failed for pin be98bdf8... (sqlstate 42P01): relation "vault.decrypted_secrets" does not exist
```

Both triggers fired off the identical `pins` row, at the identical instant, regardless of the 15-minute
head start value. **Conclusion: if `07`+`08` are applied and both Edge Functions deployed today (before
the still-unscheduled S1-follow-up session lands its `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()`
cron job), a `leaving_soon` pin with a head start gives Regulars a new, visible, content-bearing push —
but the zone board sees the exact same pin, via the exact same silent push, at the exact same instant.
The head start delivers zero actual exclusivity. It is not broken in the sense of throwing an error or
corrupting data — it is broken in the sense that the feature's entire premise (§1.1: "hand my spot to
them specifically before strangers see it") does not exist yet, silently, with nothing to alert anyone
that it's inert.**

This is honestly disclosed in three places already — the PR body, `08`'s own SCOPE NOTE, and the test
script's Test 6 manual instructions (which literally predict "two rows" of `net._http_response` for
each `leaving_soon` insert once applied). **What's missing is the fourth place that actually matters:
the two *actionable* ceremony checklists** (`docs/regulars-roadmap.md`'s S3-row "Kevin gate at end"
cell, and the PR body's own "Kevin's ceremony" bullet list) both read:

> apply `07` → deploy `send-regular-push` and re-deploy `send-community-push` → apply `08` → run
> `08-regulars-push-trigger-test.sh`

— with **no mention of the S1-follow-up gate anywhere in that sequence.** Compare this to the roadmap's
own top-level "Kevin's ceremonies" section (unchanged by this PR, `docs/regulars-roadmap.md` line
~133), which correctly says deploying `send-regular-push` happens "once the S1-follow-up migration has
landed." The two sections of the *same document* now disagree with each other on whether that gate
exists, and the disagreement is in the direction that's easy to miss — the generic section is right,
the specific, doable-today checklist for this exact PR is silent. Since Kevin executes ceremonies from
the specific row, not the generic preamble, this is a real risk, not a hypothetical.

## Findings (Pass 1)

### 🔴 Blocking

- **#1: The S3 ceremony (roadmap row + PR body) omits the S1-follow-up gate, which is required to make
  the head start real rather than decorative.**
  - Where: `docs/regulars-roadmap.md` S3 row, "Kevin gate at end" column; PR #112 body, "Kevin's
    ceremony" bullet list.
  - What: Both instruct Kevin to apply `07` → deploy `send-regular-push` (+ redeploy
    `send-community-push`) → apply `08` → run the test script, with zero mention that this sequence, on
    its own, ships a new production push whose defining feature (a head start before the zone-wide
    push) does not yet function — see the ruling above, live-reproduced.
  - Expected: Per the roadmap's own top-level "Kevin's ceremonies" section, deploying
    `send-regular-push`/applying `08` should be explicitly gated on the S1-follow-up migration (the
    `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` cron job, still "Not yet scheduled" per
    the roadmap's own S1-follow-up row) having already landed and been applied — or, at minimum, the
    ceremony must say in plain language that applying this PR's ceremony alone makes the head start a
    no-op and the zone board will see every `leaving_soon` pin instantly regardless of the chosen
    value, so Kevin can decide with full information rather than discover it from real usage.
  - Repro: Read `docs/regulars-roadmap.md`'s S3 row ceremony cell and PR #112's body's own numbered
    "Kevin's ceremony" list side by side with its "Kevin's ceremonies" top section — the two disagree.
    Live-reproduce the actual behavior with the steps in the ruling above.
  - Owner: `@backend-data` (this is a docs-only fix on files this PR already touches — add one
    explicit sentence to both locations before merge, no code change needed).
  - **STATUS: FIXED in pass 2, commit `ac1b7b67` — verified below.**

### 🟡 Significant

None in pass 1.

### 🟢 Minor / nit

- **`08`'s WHEN clause is looser than `04`'s.** `pins_invoke_send_regular_push` fires on
  `pin_type = 'leaving_soon'` alone; `pins_invoke_send_community_push` additionally requires
  `source='crowd' and lifespan='ephemeral' and zone_id is not null`. There is no DB-level CHECK tying
  `pin_type` to `lifespan`/`source` (confirmed by reading `02-pins-schema.sql`'s `pins_insert_crowd`
  policy, which only requires `source='crowd'`), so a hand-crafted `leaving_soon` insert with a
  non-`ephemeral` `lifespan` would fire `send-regular-push` but not `send-community-push`. This is
  explicitly called out as a deliberate choice in `08`'s own SCOPE NOTE ("keeping the SQL WHEN clause
  minimal... can never silently drift"), and the app's actual client code always sends
  `lifespan='ephemeral'` for `leaving_soon` — not exploitable beyond "send an extra push via a
  hand-crafted REST call," no privacy or data-integrity impact. Worth a one-line defensive-parity fix
  in a future pass, not blocking.
  - **STATUS: FIXED in pass 2, commit `ac1b7b67` — verified below, including the `zone_id` design
    question the coordinator raised.**
- **Zone-name-vs-street-name copy substitution** (`zones.name` instead of a street-level descriptor).
  The builder's own reasoning is sound — `segment_id` is an internal tile-index slug with no
  server-side geocoding path, and §2.9 gives one illustrative example, not a locked string. Flagging
  only so Kevin explicitly signs off on the copy quality call (not an engineering correctness issue).
  Unchanged in pass 2 — still open, still non-blocking.

### 💡 Out of scope (logged, not fixed)

- The actual S1-follow-up session (the `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` 30s
  cron job) remains unscheduled on the roadmap — already tracked as its own row, not this PR's job to
  build. Finding #1 is about the *documentation gap* around sequencing relative to that still-future
  session, not a demand to build it here.
- I could not re-run the PR's own `tsc --noEmit` structural-correctness check (no network access to
  install TypeScript in this sandbox) — I consider this a non-issue, since I substituted a strictly
  stronger check (a full manual line-by-line diff of `send-community-push/index.ts` before/after,
  confirming byte-identical wire behavior) rather than relying on either the builder's claim or a
  weaker proxy.

## Smoke tests run (Pass 1)

All against a scratch Postgres 16 instance I stood up myself (`qa_pr112` database, not the builder's),
with an independently-written minimal Supabase-shape stub (`auth.users`/`auth.uid()` reading a session
GUC, `anon`/`authenticated` roles with default privileges, `supabase_realtime` publication) — no
`vault`/`net`/`pg_cron` schemas created, deliberately, to prove fail-open organically rather than fake
success:

- Applied the full chain `01→02→02b→02c→02d→02e→02f(minus its unrelated Storage section, which this PR
  does not touch)→02g→03→04→05→06→07→08`, stripping only `create extension pg_cron/pg_net` and
  `cron.schedule(...)` calls (unavailable in this sandbox) — **clean, zero errors.**
- Re-applied `07` and `08` a second time back-to-back — **idempotent, zero errors.**
- Confirmed `04-community-push-trigger.sql`'s diff against base is empty (`git diff 7fa96bab..0c37b0e6`)
  — the live trigger is untouched.
- Inserted a `leaving_soon` pin by an author with one Regular, `regulars_head_start_seconds=900` — both
  `send-community-push` and `send-regular-push` invocations logged in the **same statement**, both
  correctly caught by their own exception handler (`vault.decrypted_secrets` missing) — insert
  survived. This is the live proof behind the head-start ruling above.
- Inserted a `leaving_soon` pin by a zero-Regulars author — both triggers still fired (matches spec:
  the SQL trigger is unconditional, the Edge Function's own `regular_edges` lookup is what finds zero
  Regulars) — insert survived.
- Inserted an `open_spot` pin — only `send-community-push` fired; **zero** `send-regular-push` log line
  — WHEN-clause scope confirmed live, not just by reading it.
- `regulars_head_start_seconds` clamp: 59 and 3601 both rejected by
  `pins_regulars_head_start_seconds_check`; 60 and 3600 both accepted.
- Block-severs-edge + `pin_notes` RLS, end to end: created an edge between author (11) and a Regular
  (44); inserted a `pin_notes` row on the author's `leaving_soon` pin; confirmed (a) a non-Regular
  (`33`) sees zero rows, (b) the actual Regular (`44`) sees the row, (c) a *separate* Regular (`22`)
  who had already blocked the author earlier in the same session sees zero rows — RLS correctly
  reflects the post-block graph state, not a stale one.
- Direct diff read of `send-community-push/index.ts` pre/post-refactor: identical push body, headers,
  `apns-push-type`/`apns-priority`, secret names, token query, dead-token rule, response shapes.
- Direct read of every generated string literal in `send-regular-push/index.ts` for banned words
  (avoid/ticket/fine/evasion/dodge) — none present.
- Grepped `send-regular-push/index.ts` for any `pin_notes` query — zero hits outside comments.
- Read `docs/regulars-roadmap.md`'s S3 row + top-level ceremony section side by side — found the gap in
  Finding #1.
- **Not verified — recommend before Kevin's ceremony, not before merge:** `08-regulars-push-trigger-test.sh`
  itself was read but not executed (it targets a live Supabase project over anon-key REST, which this
  sandbox cannot reach — same limitation the script's own header documents). Live APNs delivery
  (S13-class, needs a real device) is out of scope for this pass, as it is for the PR itself.

## What's working (Pass 1)

- The RLS/privacy design here is genuinely careful and — this pass confirms — correct in practice, not
  just on paper: block severs trust immediately and the push-targeting query and `pin_notes` RLS both
  reflect that live, with no stale-edge window I could find.
- The `_shared/apns.ts` extraction is exactly what it claims to be: a pure refactor, verified by direct
  diff rather than taken on faith, with zero behavior drift in the one function that's already live in
  production.
- The new trigger's fail-open posture is not just copied from `04`'s comment, it actually reproduces
  the correct control flow (Vault read inside the same exception block as the HTTP dispatch) — the
  exact class of bug PR #99 found is not repeated here.
- The targeting design (by `user_id`, not `zone_id`) is simple and matches the spec's own reasoning
  exactly, and the "unconditional trigger, function finds zero Regulars" split keeps the SQL side
  simple without sacrificing correctness.
- The PR's own honesty about the head-start-inert consequence (SQL comments, PR body, test script) is
  real and substantive — this is a case where the builder correctly identified and disclosed the exact
  risk this report is flagging; the gap is narrowly in the *actionable* ceremony text, not in the
  engineering judgment or the willingness to say the hard thing.

---

# Pass 2 — 2026-09-18 (scoped re-review, commit `ac1b7b67`)

**Reviewed:** `ac1b7b67` (parent `0c37b0e6`), diff scope confirmed to exactly 3 files: 44 insertions /
19 deletions across `docs/regulars-roadmap.md`, `supabase/08-regulars-push-trigger.sql`,
`supabase/functions/send-regular-push/index.ts`. Also read the live PR body via `gh pr view 112`
(edited separately via the GitHub API per the commit message, not part of the git diff).

**Pass 2 verdict: ✅ MERGE.**

## 1. Doc gate (Finding #1) — verified fixed, both required places

**Roadmap S3 "Kevin gate at end" cell** now reads (in full):

> ⚠️ **DO NOT deploy `send-regular-push` or apply `08-regulars-push-trigger.sql` until the S1-follow-up
> row above ... has merged AND been applied.** QA-proven live (`docs/qa/pr112-regulars-s3-push.md`):
> with `04` unmodified, a `leaving_soon` insert fires `send-community-push` ... and `send-regular-push`
> ... in the **same statement**, regardless of `regulars_head_start_seconds` — the head start is
> completely inert ... Ceremony order once that gate clears: apply `07` → confirm S1-follow-up's own
> migration is applied and its cron job is running → deploy `send-regular-push` and re-deploy
> `send-community-push` → apply `08` → run `08-regulars-push-trigger-test.sh`. Pending `@qa-verifier`
> (S4) re-pass first.

This leads with an imperative "DO NOT," states the exact reason, and then re-states "confirm
S1-follow-up's own migration is applied" as its own explicit step inside the ceremony order itself —
not just a preamble. **Reading this cell alone, in isolation, would stop Kevin before he deploys
`send-regular-push` pre-`04`-rewrite.** Confirmed.

**S1-follow-up row's own cross-reference** now reads: *"Must land and be applied before Kevin deploys
`send-regular-push`/applies `08-regulars-push-trigger.sql` — see S3's own gate cell below."* This closes
the loop from the other direction — someone reading the S1-follow-up row first is pointed forward to
the same gate. Confirmed both directions of the cross-reference are now consistent (previously they
disagreed; now they agree).

**PR body (`gh pr view 112`)** now carries a "## QA update (2026-09-18)" section at the top restating
the finding, the Summary section's `send-regular-push` bullet has an inline "⚠️ see the QA update
above" caveat, the `08-regulars-push-trigger.sql` bullet gets its own "⚠️ Must not be applied ... until
the S1-follow-up session ... has landed and been applied," the "Kevin's ceremony" follow-up line now
reads *"after `@qa-verifier` clears S4 — **and NOT before, per the QA update above**): confirm the
S1-follow-up migration ... has already landed and been applied → apply `07` → ..."*, and the **Test
plan checklist itself** gained a new line: *"Confirm the S1-follow-up migration (04 rewrite + sweep
cron) has landed and is applied — do not proceed past this without it, or the head start ships
inert."* Every one of the four places in the PR body that could plausibly serve as Kevin's checklist
now carries the same stop. Confirmed.

**One residual gap, not part of this PR's diff, flagged but not blocking:** `docs/open-items.md`'s #23
row (last touched by the *original* S3 commit `0c37b0e6`, not by this fix) still ends with the stale,
gate-less instruction: *"Needs `@qa-verifier` (S4) before Kevin's ceremony: apply 07 → deploy
`send-regular-push` + redeploy `send-community-push` → apply 08 → run the test script."* — no S1-follow-up
mention at all. `open-items.md` is a secondary status tracker (HANDOFF.md's "standing punch list"), not
the primary executable ceremony (the roadmap row and the PR body are), and the coordinator's ask named
those two specifically — so I am not blocking merge on this. But it is a real, live piece of doc drift
of the exact same class Finding #1 was about, in a place a reader might reasonably still consult. Logged
as a new 🟡 nit below; recommend a fast follow-up (one sentence, same fix as the other two places) rather
than reopening this PR for it.

## 2. Code change: `08`'s WHEN clause tightened + `zone_id` reasoning assessed

**The tightening itself, live-reproduced on my scratch instance (re-applied `08` in place, no fresh
rebuild needed since `07` was untouched):**

- **Ephemeral crowd `leaving_soon` (the normal case):** both `send-community-push` and
  `send-regular-push` still fire in the same statement — confirmed via fresh log lines. **The
  inert-head-start state from Finding #1's ruling is unchanged by this fix** (as expected — this fix
  changes *which* `leaving_soon` pins qualify for `send-regular-push`, not the timing relationship
  between the two triggers for pins that do qualify).
- **Hand-crafted `leaving_soon` with `lifespan='durable'`** (the exact gap the pass-1 nit found): **zero
  log lines from either trigger.** `04` already excluded it (its own `lifespan='ephemeral'` clause,
  pre-existing); `08` now excludes it too. The asymmetry is closed, live-verified, not just read.
- **`open_spot`:** only `send-community-push` fired, unaffected. Confirmed unchanged.

**The `zone_id` design question — is deliberately NOT copying `04`'s `zone_id is not null` clause
correct?** The fix's own SQL comment argues this trigger's targeting is by `author_id`, not zone, so
requiring `zone_id is not null` would "incorrectly withhold a Regulars push from a (currently
theoretical, since the client always sets zone_id for leaving_soon today) zone-less leaving_soon pin."
**I checked the actual client write path** (`ios/WePark/WePark/Services/CommunityPinService.swift`,
`resolveZoneId`/`insertCrowdPin`) to verify the "currently theoretical" claim, and it is **factually
wrong, though the underlying design conclusion is still correct:**

- `resolveZoneId(explicit:lat:lng:zones:)` does a client-side bounding-box match against the live zone
  list and **returns `nil` — documented in its own doc comment as "an honest, correctly-null `zone_id`
  column... never a guessed/default zone" — whenever the pin's coordinate falls outside every zone's
  box.** With only 3 zones live in production today (`soho-les`, `nolita`, `soho`), a `leaving_soon`
  post from a real user standing just outside one of those boxes produces a real, non-theoretical
  `zone_id = null` row today, not a hypothetical future case. The "currently theoretical" phrasing in
  the SQL comment/commit message overstates how rare this is — it's an everyday possibility given the
  current zone coverage, not a corner case that "could" happen someday.
- **The design conclusion is nonetheless correct, and I verified it live.** I inserted a `leaving_soon`
  pin with `zone_id = null` (the exact scenario `resolveZoneId` produces): `04`'s trigger correctly did
  **not** fire (its `zone_id is not null` clause excludes it — this is pre-existing behavior, unrelated
  to this PR); `08`'s trigger **did** fire `send-regular-push`. This is the right outcome — per spec
  §2.9's own reasoning ("a friend visiting from three blocks away should still hear 'Kevin's leaving'"),
  Regulars should hear about a departure regardless of whether the pin resolved to a mapped zone. If
  `08` had copied `04`'s `zone_id is not null` clause, a `leaving_soon` pin outside every current zone's
  coverage would get **zero push of any kind** — not just no zone-wide push (which is already true
  today via `04`), but no Regulars push either, silently defeating the entire feature for anyone posting
  from outside the three currently-mapped zones. Keeping `08`'s targeting zone-independent is the
  correct call on the merits, independent of how common the null case actually is.
- **Net: the code is right, the code comment is not.** Logged as a 🟢 nit (factual overstatement in a
  comment/commit message, not a logic bug) — not blocking, but worth a one-word correction ("possible"
  instead of "currently theoretical") next time this file is touched.

**Matching defense-in-depth check in `send-regular-push/index.ts`:** confirmed the `PinRecord`
interface gained `source`/`lifespan` fields and the early-return guard now checks all three conditions
(`pin_type !== "leaving_soon" || pin.source !== "crowd" || pin.lifespan !== "ephemeral"`), matching
`08`'s tightened WHEN clause exactly — same convention `send-community-push` already uses for its own
re-check. Correctly does **not** add a `zone_id` check here either, consistent with the SQL side.

## 3. Confirm nothing else changed

`git diff ac1b7b67~1..ac1b7b67 --stat` shows exactly the 3 files above, 44/-19 lines — matches the
commit message's stated scope precisely (gate the ceremony, tighten the WHEN clause, no other changes).
`_shared/apns.ts`, `send-community-push/index.ts`, and the test script are byte-identical to pass 1 (no
diff hits). `docs/open-items.md` was **not** touched by this commit — see the residual-gap note in
section 1 above (logged as a new 🟢 nit, not a surprise given the coordinator's scoped ask, but worth
naming explicitly since "confirm nothing else changed" cuts both ways — nothing unexpected was added,
but one expected companion update was also not made).

## New findings, Pass 2

### 🟢 Minor / nit (new)

- **`docs/open-items.md`'s #23 row still carries the stale, gate-less ceremony instruction** from the
  original S3 commit (not touched by this fix commit). Same class of risk as pass 1's Finding #1, in a
  secondary tracker rather than the primary ceremony surfaces. Recommend a one-sentence fast-follow, not
  a re-opened PR.
- **The "currently theoretical" framing of the null-`zone_id` case in `08`'s SQL comment (and the fix's
  commit message) is factually overstated** — verified against the actual client write path
  (`CommunityPinService.resolveZoneId`), which documents this as a real, everyday, non-theoretical
  outcome given only 3 zones exist today. The design decision built on top of that framing is still
  correct (verified live) — this is a comment-accuracy nit, not a logic bug.

## Smoke tests run, Pass 2

- Re-fetched `origin/backend/regulars-s3-push` at `ac1b7b67`; diffed against `0c37b0e6` — confirmed
  exactly 3 files changed, matching the stated scope.
- Read the full roadmap S3 cell and S1-follow-up row cross-reference (post-fix) end to end — confirmed
  the gate reads unambiguously and would stop a reader executing that cell alone.
- Read the live PR body via `gh pr view 112 --json body` — confirmed the QA-update section, the
  Summary bullets' inline warnings, the ceremony follow-up line, and the Test plan checklist all carry
  the same stop, independently of the roadmap doc.
- Re-applied the tightened `08-regulars-push-trigger.sql` to my existing scratch Postgres instance
  (`07` untouched, no rebuild needed) — clean, zero errors.
- Live-exercised four scenarios against the tightened trigger: (a) ephemeral crowd `leaving_soon` — both
  triggers fire, inert-head-start state unchanged; (b) `leaving_soon`/`lifespan='durable'` — neither
  trigger fires, gap closed; (c) `open_spot` — community-push only, unaffected; (d) ephemeral crowd
  `leaving_soon`/`zone_id=null` — only `send-regular-push` fires, confirming the zone-independent
  targeting design is correct even though its "currently theoretical" justification is not.
- Read `ios/WePark/WePark/Services/CommunityPinService.swift`'s `resolveZoneId`/`insertCrowdPin` to
  independently verify (rather than take on faith) whether a real `leaving_soon` pin can have
  `zone_id = null` in production today — confirmed yes, via the documented box-match-miss fallback.
- Diffed `send-regular-push/index.ts`'s updated defense-in-depth check against `08`'s new WHEN clause —
  confirmed they match exactly (same three conditions).
- Confirmed `_shared/apns.ts`, `send-community-push/index.ts`, and `08-regulars-push-trigger-test.sh`
  are unchanged from pass 1 (no diff hits in `ac1b7b67`'s file list).

## Pass 2 verdict and path

**✅ MERGE.** The one 🔴 blocking finding from pass 1 is fixed and independently re-verified in both of
the two places the coordinator asked about (the roadmap's actionable cell + cross-reference, and the
live PR body across all four locations that touch the ceremony). The pass-1 🟢 nit (WHEN-clause parity)
is also fixed and live-reproduced, including a design question the coordinator raised (`zone_id`
omission) — the code's conclusion is correct, though I found and logged a factual overstatement in its
supporting comment (new 🟢 nit, not blocking). Nothing else changed in the diff beyond what the commit
message claims. One pre-existing secondary-doc gap (`open-items.md`) is logged as a fast-follow, not a
merge blocker.

Report path: `/root/repos/parkmap/.claude/worktrees/agent-a904f52ae4c0d82df/docs/qa/pr112-regulars-s3-push.md`
