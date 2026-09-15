# Regulars — Roadmap (Sequencing View)

**Status:** Active roadmap. Date: 2026-09-15.
**Target:** the feature described end to end in `docs/regulars-network-spec.md` — a flat, per-user
trust list ("Regulars") built via QR/link invites, a tiered handoff head-start for `leaving_soon`
pins, and a one-way "moving my car" broadcast — dark-shipped behind a compile-time flag until Kevin's
field-confidence gate.
**Spec:** `docs/regulars-network-spec.md` (all scope statements there govern; this doc is the
sequencing/sizing view, same relationship the Community 2.0 roadmap has to its own reconciliation
spec).
**Verdict up front (spec §8): FEASIBLE**, structurally similar in size to one mid-sized Community 2.0
phase pair, not a second Community 2.0. Every hard primitive already exists and is proven in
production (targeted push delivery, a race-safe single-writer-wins RPC pattern, a proven deny-most/
SECURITY-DEFINER-RPC RLS posture, a proven rate-limit table, a proven compile-time-flag-plus-guard-
tests dark-ship playbook). Total: ~14 sessions + 2 buffer = 16 sessions (spec §8).

---

## Flag decision (recorded up top, per the spec — do not re-derive this later)

`AppConstants.regularsEnabled` ships **dark (`false`)** through every build session, exactly like
`communityEnabled` did for Community 2.0 (spec §3.6 — a direct copy of that playbook, not a new
pattern). Four guard tests are pre-declared **now**, by name, so the eventual flip PR has a known
checklist instead of an after-the-fact discovery pass (the Community 2.0 roadmap's own retro note:
its 4 guard tests were "discovered incrementally and had to be reconciled by name at the flip" — this
spec is written to prevent a repeat of that surprise):

- `testRegularsEnabled_defaultsFalse`
- `testRegularsSettingsRow_hidden_whenDisabled`
- `testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled`
- `testAppConstants_regularsHeadStartRange_matchesServerClamp` — **range updated by the mid-flight
  ruling below: the client stepper's bounds must match [15, 3600] seconds (15s-60min), not the
  spec's original [15, 300] (15s-5min).**

None of these tests exist yet — S1 is a schema-only session (no iOS code) and creates zero Swift
files. They are recorded here as the standing checklist for the iOS sessions (S5 onward) that will
actually add them, mirroring the flag playbook's own "seed guard tests before code, not after"
discipline.

---

## Mid-flight ruling (Kevin, 2026-09-15 — incorporated into S1 below; a formal spec amendment to
`docs/regulars-network-spec.md` is being written separately and will reconcile against this)

Three items arrived while S1 was already in flight and are already reflected in
`supabase/07-regulars-schema.sql` (see that file's own MID-FLIGHT RULING ADDENDUM comment for the
full reasoning):

1. **Head-start default is 15 minutes, not 2.** Kevin: *"2 minutes is nothing... I was thinking 15
   minutes."* The server-side CHECK on `pins.regulars_head_start_seconds` is widened from the spec's
   original [15, 300] seconds to **[15, 3600]** (15 seconds to 60 minutes) so the range comfortably
   covers minutes-to-tens-of-minutes values. The 2min-vs-15min default/preset choice itself is a
   client-side UX decision, deferred to the iOS session that builds the stepper (S9) — this ruling
   only changes the server-side ceiling.
2. **NEW capability: scheduled/future departure announcements.** Kevin: *"People also usually plan
   they're leaving... they could tell their Regulars, I'm out at 2pm today."* `regular_notices` gains
   a nullable `scheduled_for timestamptz` column (S1) plus a derive-expiry trigger so a scheduled
   notice's `expires_at` is anchored to the announced departure time plus a 60-minute grace window,
   not to the moment it was posted. Placed on `regular_notices` rather than `pins` or a new table —
   see the migration file's own PLACEMENT REASONING comment for the full argument.
3. **Head-start can exceed a pin's own expiry window, so the public fallthrough may never fire.**
   Addressed structurally, not with new code: `pins.zone_pushed_at` stays nullable with no NOT NULL
   constraint and no trigger anywhere in S1 that requires it to ever be set — nothing in this session
   assumes the (still-deferred, see the S1-follow-up row below) zone-wide fallthrough phase always
   runs for a given `leaving_soon` pin.

---

## What a "session" means

Same unit as the Community 2.0 roadmap: **one focused working block (~2–4 h wall clock) driving this
repo to one coherent, QA-able output** — typically one PR built + tested, or one QA pass + merge. A
session includes the agent build, the test suite additions, and the doc updates; it does NOT include
Kevin's short gate tasks (dashboard migration apply, Edge Function deploy, live two-device smoke),
which attach to the end of specific sessions and are called out explicitly below.

## Session-by-session plan (14 sessions, +2 buffer, per spec §5)

| # | Session | Owner | Work | Kevin gate at end |
|---|---|---|---|---|
| S1 | 🟡 **IN PROGRESS** — schema, RLS, RPCs (this PR) | `@backend-data` | `supabase/07-regulars-schema.sql`: `pins.regulars_head_start_seconds`/`pins.zone_pushed_at` (spec §2.1, range widened to [15,3600]s per the mid-flight ruling above — pulled back INTO S1's scope, see the file's own MID-FLIGHT RULING ADDENDUM) + `pins_with_author` view recreation, `regular_edges` (trust graph, canonical low/high ordering, no client insert path), `regular_blocks` + block-severs-edge trigger, `regular_invites` + race-safe `redeem_regular_invite()` RPC (`SELECT ... FOR UPDATE`, single-writer-wins), `pin_notes` + ownership trigger, `regular_notices` (+ nullable `scheduled_for` and a derive-expiry trigger, new per the mid-flight ruling), `regular_invite`/`regular_notice` rate-limit config rows + trigger functions. Companion `supabase/07-regulars-schema-test.sh`. **Still DEFERRED to a follow-up** (see the migration file's own SCOPE NOTE — unchanged by the mid-flight ruling): spec §2.8's rewrite of the live `pins_invoke_send_community_push` trigger WHEN clause + the new 30-second `sweep_leaving_soon_zone_push()` cron job — push-delivery-TIMING behavior, not trust-graph schema/RLS/RPC surface, and it touches a trigger that is live in production today. | **NOT applied.** File + test script only, per the standing "Kevin applies all Supabase migrations to production by hand" rule. Pending: `@qa-verifier` pass (S2), then Kevin's dashboard apply + test-script run. |
| S1-follow-up | ⬜ Not yet scheduled | `@backend-data` | The deferred §2.8 piece from S1's SCOPE NOTE: the live push-trigger WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` + its cron job. `pins.regulars_head_start_seconds`/`zone_pushed_at` already exist as of S1 — this follow-up is the piece that actually makes them live. Small, but touches production push timing — sized as its own reviewable diff rather than folded into S1 or S3. | — |
| S2 | ⬜ Not started | `@qa-verifier` | QA on S1 (schema/RLS/RPCs) — the friend graph is the most sensitive data this app has; expect an adversarial pass on the RLS/RETURNING interactions and the invite-redemption race, same rigor as `docs/qa/pr93-community-phase0-schema.md`. | — |
| S3 | ⬜ Not started | `@backend-data` | `send-regular-push` Edge Function (new sibling to `send-community-push`) + `_shared/apns.ts` extraction + the new `pins_invoke_send_regular_push` insert trigger (fires immediately, unconditionally, on every `leaving_soon` insert — targets Regulars by `user_id`, visible/content-bearing payload, never includes `pin_notes` text). Depends on S1's FILE (not its production apply). | — |
| S4 | ⬜ Not started | `@qa-verifier` | QA on S3. | — |
| S5 | ⬜ Not started | `@ios-engineer` | iOS model/service layer: `Models/Regular.swift` (`RegularEdge`/`RegularInvite`/`PinNote`/`RegularNotice`), `Services/RegularsService.swift`, `AppConstants.regularsEnabled` + the 4 guard tests named above. Zero UI. Depends on S1's FILE (not its production apply) — can start in parallel with S3/S4 (different codebases). | — |
| S6 | ⬜ Not started | `@qa-verifier` | QA on S5. | — |
| S7 | ⬜ Not started | `@ios-engineer` | iOS UI: `RegularsSettingsView.swift`, `RegularInviteView.swift` (QR + `ShareLink`), `WeParkApp.swift` `.onOpenURL`, `Info.plist` URL scheme (Kevin's one-time step), `SettingsView.swift` row wiring. Depends on S5; needs S3/S4 deployed for the live-push half of its gate (can build against S5 alone and defer that half to S13). | — |
| S8 | ⬜ Not started | `@qa-verifier` | QA on S7 + Kevin's `Info.plist` step + a live two-device QR-scan-and-redeem smoke. | — |
| S9 | ⬜ Not started | `@ios-engineer` | iOS UI: `ParkedCarDetailView.swift` head-start chip row + custom stepper + optional note field (spec §3.4). Depends on S5. **This is the parallel-execution seam** — S9/S7/S10 are three disjoint diffs sharing only the S5 dependency, safe as up to three concurrent worktrees once S5 merges. | — |
| S10 | ⬜ Not started | `@ios-engineer` | iOS UI: `RegularNoticeView.swift` (Quick Regulars Notice, spec §3.5) + entry point wiring. Depends on S5. | — |
| S11 | ⬜ Not started | `@qa-verifier` | QA on S9. | — |
| S12 | ⬜ Not started | `@qa-verifier` | QA on S10. | — |
| S13 | ⬜ Not started | `@ios-engineer` + Kevin ceremony | Physical-device push verification: friend-targeted visible push arrives immediately; zone-wide fallback push arrives only after the configured head start on a control device; custom head-start value round-trips server-clamped; `pin_notes` visible only to a Regular, RLS-filtered (not erroring) for a non-Regular control device on the same pin. **Needs an actual second person/device — spec §8's biggest named risk.** | — |
| S14 | ⬜ Not started | `@ios-engineer` | Flag flip: `regularsEnabled = true`, adjust the 4 named guard tests to launched-world assertions, one small PR. Gated on everything above + Kevin's field-confidence call (spec §8). | — |

**Buffer:** +2 sessions for rework the QA passes surface (same historical-rate justification as the
Community 2.0 roadmap).

**Designer touchpoint:** `RegularInviteView`'s QR/link layout and `RegularsSettingsView`'s list — one
review pass, can happen any time after S7's first draft, does not block engineering (mirrors the
FT-20 sheet-detent review pattern from Community 2.0).

## Kevin's ceremonies (none skippable, none an agent's to perform)

- Apply `07-regulars-schema.sql` to production after S2's QA clears (dashboard paste).
- Apply the S1-follow-up migration (pins columns + push-trigger rewrite + cron job) after its own QA
  clears — a SEPARATE apply from S1's, per the SCOPE NOTE's reasoning.
- Register `wepark://` in `Info.plist` before S8's live gate.
- Deploy `send-regular-push` + confirm the `sweep-leaving-soon-zone-push` cron job is running after
  S3/S4 clears (once the S1-follow-up migration has landed).
- S13's two-physical-device push verification.

## Top risks, honestly ranked (spec §8)

1. **Verifiability requires a second real, cooperating human.** S8 and S13's live gates cannot be
   solo-Kevin-on-two-simulators — Regulars is valueless and untestable below two willing participants
   who complete an in-person QR exchange.
2. **The 30-second `pg_cron` sweep (deferred to S1-follow-up) has no precedent in this codebase.** The
   existing hygiene sweep runs every 15 minutes; nothing today runs sub-minute. Recommend that
   follow-up session include an explicit load/correctness check before this ships to more than
   Kevin's own build.
3. **Lost-identity risk is inherited, not created.** WePark's anonymous-auth model means a reinstall
   can cost a user their whole Regulars list with no account to sign back into (spec §4) — an honest,
   pre-existing limitation this feature does not fix.

## Decisions locked (do not re-litigate — spec §0)

1. Feature name: **"Regulars."**
2. DM scope: **NOT a chat app** — no threads, no inbox, no read receipts, no reply-in-app.
3. Car-pin visibility to Regulars: **no passive/standing visibility**, ever.
4. Tier timing: user-configurable, per post, presets + a custom picker.
5. Invite mechanism: **both QR and share link, same underlying token.**
