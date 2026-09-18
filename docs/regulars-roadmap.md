# Regulars — Roadmap (Sequencing View)

**Status:** Active roadmap. Date: 2026-09-16 (regenerated against the formal spec amendment,
`docs/regulars-network-spec.md` commit `cb464c65`, and PR #111's QA fix round,
`docs/qa/pr111-regulars-s1-schema.md`).
**Target:** the feature described end to end in `docs/regulars-network-spec.md` — a flat, per-user
trust list ("Regulars") built via QR/link invites, a tiered handoff head-start for `leaving_soon`
pins, a one-way "moving my car" broadcast, and Scheduled Departure ("I'm out at 2pm today") — dark-
shipped behind a compile-time flag until Kevin's field-confidence gate.
**Spec:** `docs/regulars-network-spec.md` (all scope statements there govern; this doc is the
sequencing/sizing view, same relationship the Community 2.0 roadmap has to its own reconciliation
spec).
**Verdict up front (spec §8): FEASIBLE**, structurally similar in size to one mid-sized Community 2.0
phase pair, not a second Community 2.0. Every hard primitive already exists and is proven in
production (targeted push delivery, a race-safe single-writer-wins RPC pattern, a proven deny-most/
SECURITY-DEFINER-RPC RLS posture, a proven rate-limit table, a proven compile-time-flag-plus-guard-
tests dark-ship playbook). **Total: 16 core sessions, +2 buffer = 18 sessions (spec §8, amended
2026-09-15 — Scheduled Departure added S10b + S12b).** The original, now-superseded estimate was 14
core + 2 buffer = 16.

---

## Flag decision (recorded up top, per the spec — do not re-derive this later)

`AppConstants.regularsEnabled` ships **dark (`false`)** through every build session, exactly like
`communityEnabled` did for Community 2.0 (spec §3.6 — a direct copy of that playbook, not a new
pattern). **Six** guard tests are pre-declared **now**, by name, so the eventual flip PR has a known
checklist instead of an after-the-fact discovery pass (the Community 2.0 roadmap's own retro note:
its 4 guard tests were "discovered incrementally and had to be reconciled by name at the flip" — this
spec is written to prevent a repeat of that surprise):

- `testRegularsEnabled_defaultsFalse`
- `testRegularsSettingsRow_hidden_whenDisabled`
- `testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled`
- `testAppConstants_regularsHeadStartRange_matchesServerClamp` — client stepper bounds must match
  **`[60, 3600]` seconds (1–60 minutes)** — the amended spec's final, locked range (§0 decision 6,
  §2.1, commit `cb464c65`). This is NOT the same number the schema first shipped with mid-flight
  (`[15, 3600]`) — that earlier number was itself superseded by the amendment before this roadmap's
  QA fix round reconciled the schema file to it. See "QA fix round" below.
- `testAppConstants_regularsHeadStartDefault_is15Minutes` — **new, §0 decision 6.** Locks the
  15-minute default so it can't silently drift back toward the spec's original 2-minute
  recommendation.
- `testRegularNoticeScheduleMode_hidden_whenRegularsDisabled` — **new, §0 decision 7.** Scheduled
  Departure's schedule toggle follows the same dark-ship gating every other Regulars surface uses.

None of these tests exist yet — S1 is a schema-only session (no iOS code) and creates zero Swift
files. They are recorded here as the standing checklist for the iOS sessions (S5 onward) that will
actually add them, mirroring the flag playbook's own "seed guard tests before code, not after"
discipline.

---

## Mid-flight ruling (Kevin, 2026-09-15) → formally amended the same day (commit `cb464c65`) →
## reconciled in S1's QA fix round (2026-09-16, `docs/qa/pr111-regulars-s1-schema.md`)

Three items arrived while S1 was already in flight, addressed first as an unreviewed mid-flight
ruling, then formalized into the spec itself the same day with the exact final numbers, then found
by QA to be only PARTIALLY reconciled into the schema file before this roadmap's own regeneration:

1. **Head-start default is 15 minutes, not 2.** Kevin: *"2 minutes is nothing... I was thinking 15
   minutes."* **Final, locked range: `[60, 3600]` seconds (1–60 minutes)** — §0 decision 6, spec
   §2.1. The mid-flight ruling had widened the schema to `[15, 3600]` before the amendment tightened
   the floor to 60; QA caught the drift live (Finding #4) and it is now fixed in
   `supabase/07-regulars-schema.sql`. Preset ladder: 5/10/15/30 min + Custom (1–60 min), default 15.
   The 2min-vs-15min default/preset choice itself is a client-side UX decision, deferred to the iOS
   session that builds the stepper (S9).
2. **NEW capability: scheduled/future departure announcements.** Kevin: *"People also usually plan
   they're leaving... they could tell their Regulars, I'm out at 2pm today."* `regular_notices` gains
   a nullable `scheduled_for timestamptz` column (S1) plus a derive-expiry trigger so a scheduled
   notice's `expires_at` is anchored to the announced departure time plus a 60-minute grace window,
   not to the moment it was posted (spec §2.6). Placed on `regular_notices` rather than `pins` or a
   new table — see the migration file's own PLACEMENT REASONING comment. **Two CHECKs required**
   (future-only + 24h horizon, spec §2.6) — QA found only the 24h-horizon CHECK had been built
   (Finding #3); both are now present. This capability drove two new sessions, S10b/S12b (§5 below).
3. **Head-start can exceed a pin's own expiry window, so the public fallthrough may never fire.**
   Addressed structurally, not with new code: `pins.zone_pushed_at` stays nullable with no NOT NULL
   constraint and no trigger anywhere in S1 that requires it to ever be set — nothing in this session
   assumes the (still-deferred, see the S1-follow-up row below) zone-wide fallthrough phase always
   runs for a given `leaving_soon` pin. QA verified this live-safe, unchanged.

**S1's QA fix round (2026-09-16) also closed two independently-found 🔴 blocking findings** unrelated
to the amendment reconciliation above — a rate-limit/TTL bypass via client-writable `created_at`/
`expires_at` on `regular_notices`/`regular_invites`, fixed via the same table-level-REVOKE +
column-level-re-GRANT pattern this repo already proved for `pins.created_at`/`source`
(`02f-block-scoped-restrictions.sql`). Full findings: `docs/qa/pr111-regulars-s1-schema.md`.

---

## What a "session" means

Same unit as the Community 2.0 roadmap: **one focused working block (~2–4 h wall clock) driving this
repo to one coherent, QA-able output** — typically one PR built + tested, or one QA pass + merge. A
session includes the agent build, the test suite additions, and the doc updates; it does NOT include
Kevin's short gate tasks (dashboard migration apply, Edge Function deploy, live two-device smoke),
which attach to the end of specific sessions and are called out explicitly below.

## Session-by-session plan (16 core sessions, +2 buffer = 18, per amended spec §5/§8)

| # | Session | Owner | Work | Kevin gate at end |
|---|---|---|---|---|
| S1 | ✅ **MERGED `db6469e9`** (2026-09-17, PR #111) — DRAFT migration 07 + 15-section test script (~69 checks) + roadmap seed | `@backend-data` | `supabase/07-regulars-schema.sql`: `pins.regulars_head_start_seconds`/`pins.zone_pushed_at` (spec §2.1, **`[60,3600]`s clamp, amendment-locked**) + `pins_with_author` view recreation, `regular_edges` (trust graph, canonical low/high ordering, no client insert path), `regular_blocks` + block-severs-edge trigger, `regular_invites` + race-safe `redeem_regular_invite()` RPC (`SELECT ... FOR UPDATE`, single-writer-wins) + column-privilege lockdown on `created_at`/`expires_at`, `pin_notes` + ownership trigger, `regular_notices` (+ nullable `scheduled_for`, both future-only and 24h-horizon CHECKs, a derive-expiry trigger, and a matching column-privilege lockdown on `created_at`), `regular_invite`/`regular_notice` rate-limit config rows + trigger functions. Companion `supabase/07-regulars-schema-test.sh` (66 checks across 15 sections, up from 42/11 — added head-start boundary coverage, `scheduled_for` expiry-derivation coverage, permanent regression coverage for both QA-found exploits, and `regular_invite` rate-limit coverage). **Still DEFERRED to a follow-up** (see the migration file's own SCOPE NOTE): spec §2.8's rewrite of the live `pins_invoke_send_community_push` trigger WHEN clause + the new 30-second `sweep_leaving_soon_zone_push()` cron job — push-delivery-TIMING behavior, not trust-graph schema/RLS/RPC surface, and it touches a trigger that is live in production today. | **NOT applied.** File + test script only, per the standing "Kevin applies all Supabase migrations to production by hand" rule. QA round 1: 🔴 FIX-THEN-MERGE (`docs/qa/pr111-regulars-s1-schema.md`) — all 6 findings fixed on this branch, re-validated locally (real Postgres 16 + a real local PostgREST 12.2.3 instance, both exploit loops confirmed now failing). Pending: `@qa-verifier` re-pass, then Kevin's dashboard apply + test-script run. |
| S1-follow-up | ⬜ Not yet scheduled — **now a hard gate for S3's ceremony, not just S1's** (QA finding, `docs/qa/pr112-regulars-s3-push.md`, 2026-09-18: live-proven that without this row's rewrite, `send-regular-push` and `send-community-push` fire in the same statement for every `leaving_soon` insert, making the Regulars head start a no-op) | `@backend-data` | The deferred §2.8 piece from S1's SCOPE NOTE: the live push-trigger WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` + its cron job. `pins.regulars_head_start_seconds`/`zone_pushed_at` already exist as of S1 — this follow-up is the piece that actually makes them live. Small, but touches production push timing — sized as its own reviewable diff rather than folded into S1 or S3. **Must land and be applied before Kevin deploys `send-regular-push`/applies `08-regulars-push-trigger.sql`** — see S3's own gate cell below. | — |
| S2 | ✅ **DONE with S1** (two-pass QA inside PR #111: pass 1 FIX-THEN-MERGE — two live-reproduced 🔴 rate-limit/TTL bypasses via client-set timestamps + 4 🟡; pass 2 MERGE, exploits independently re-verified dead on a second scratch Postgres, both now permanent regression sections in the test script) | `@qa-verifier` | QA on S1 (schema/RLS/RPCs) — the friend graph is the most sensitive data this app has; expect an adversarial pass on the RLS/RETURNING interactions, the invite-redemption race, and (per the amended spec §2.10 and the round-1 QA report) the `[60,3600]` clamp edges and the `scheduled_for` expiry-derivation math specifically, same rigor as `docs/qa/pr93-community-phase0-schema.md`. | — |
| S3 | ✅ **MERGED `7ad4e683`** (2026-09-18, PR #112, two-pass QA) | `@backend-data` | `supabase/functions/send-regular-push/index.ts` (new): targets a `leaving_soon` pin author's Regulars via `public.regular_edges` joined to `public.device_push_tokens` **by `user_id`, not `zone_id`**; visible/content-bearing APNs alert (title+body, `pushType:"alert"`, priority `"10"`) — payload fields: `pin_type`, `pin_id`, `author_id`, `segment_id`, `zone_id`, `leaving_minutes`, `regulars_head_start_seconds`, plus the generated `aps.alert.{title,body}` copy (author's `profiles.username` + `zones.name`, **not** a street-level resolution — `pins.segment_id` is an internal tile-index slug with no server-side geocoding available; flagged in the PR as a resolved, non-blocking spec ambiguity since §2.9 gives one illustrative example, not a locked copy contract); **never reads or includes `pin_notes` text**, by construction (that table isn't queried at all). `supabase/functions/_shared/apns.ts` (new): JWT signing/caching + the raw APNs send/dead-token-classification loop, extracted from `send-community-push/index.ts` — **behavior-preserving only**; that file's own diff in this PR is "import instead of define," with the exact same body/headers still constructed and sent (verified via a `tsc --noEmit` structural check against both files, since `deno` is unavailable in this environment — same Deno-global/URL-import-only baseline error signature on old and new code, zero new errors introduced). `supabase/08-regulars-push-trigger.sql` (new, DRAFT — DO NOT APPLY): `pins_invoke_send_regular_push`, `AFTER INSERT ON pins WHEN (pin_type = 'leaving_soon' AND source = 'crowd' AND lifespan = 'ephemeral')` (tightened to match `04`'s own gate scope per QA's 🟢 nit, `docs/qa/pr112-regulars-s3-push.md` — deliberately still omitting `04`'s `zone_id is not null` clause, since this trigger's targeting is by `author_id`, not zone; see the file's own comment), unconditional/immediate, mirrors `04`'s Vault-read-inside-exception-block fail-open pattern verbatim (the S11/PR#99 lesson) — does NOT touch `pins_invoke_send_community_push`'s WHEN clause or add any sweep/cron job (that remains the separate, still-unscheduled S1-follow-up row above). Depends on **07's FILE** (07 must be applied before 08 in Kevin's eventual ceremony; neither is applied yet). **Local validation (real Postgres 16, this session):** built a minimal Supabase-shape scratch fixture (stub `auth.users`/`auth.uid()`, stub `vault.decrypted_secrets`, `pg_cron`/`pg_net` lines stripped — not installable in this sandbox, same precedent PR #99's QA pass 2 and PR #111's QA already established) and applied `01→02→02e→02f→03→04→07→08` in order, clean, zero errors, **and idempotent** (07 and 08 both re-applied cleanly a second time back-to-back). Live-exercised the new trigger: a `leaving_soon` insert survives BOTH failure stages independently (vault-secret-not-found AND `net` schema missing — matching PR #99 pass 2's own two-stage proof shape exactly, log lines confirmed via `postgresql-16-main.log`), a zero-Regulars author's `leaving_soon` insert also survives unaffected, and a non-`leaving_soon` pin insert fires `send-community-push` only, **never** `send-regular-push` — confirming the WHEN clause's scope live, not just by reading it. Extended test tooling: `supabase/08-regulars-push-trigger-test.sh` (new, curl/anon-key-only, mirrors `04-community-push-test.sh`'s shape — invite/redeem round trip, device-token registration, the same three insert-survives assertions proven locally above, plus MANUAL steps for the `net._http_response`/Edge-Function-log checks anon-key access can't reach). Depends on S1's FILE (not its production apply). | ⚠️ **DO NOT deploy `send-regular-push` or apply `08-regulars-push-trigger.sql` until the S1-follow-up row above (the live `04` WHEN-clause rewrite + `sweep_leaving_soon_zone_push()` cron job) has merged AND been applied.** QA-proven live (`docs/qa/pr112-regulars-s3-push.md`): with `04` unmodified, a `leaving_soon` insert fires `send-community-push` (zone-wide, instant, silent) and `send-regular-push` (Regulars, instant, visible) in the **same statement**, regardless of `regulars_head_start_seconds` — the head start is completely inert (zero exclusivity, silently) until S1-follow-up lands. Ceremony order once that gate clears: apply `07` → confirm S1-follow-up's own migration is applied and its cron job is running → deploy `send-regular-push` **and re-deploy `send-community-push`** (the `_shared/apns.ts` extraction only takes effect in prod once that live function is redeployed — see the PR body) → apply `08` → run `08-regulars-push-trigger-test.sh`. Pending `@qa-verifier` (S4) re-pass first. |
| S4 | ✅ **DONE with S3** (two passes inside PR #112: pass 1 FIX-THEN-MERGE — head start proven inert until S1-follow-up, ceremony gate wired into every actionable surface; pass 2 MERGE — scope-tightening verified live incl. the null-zone design call, builder's "theoretical" claim corrected but design confirmed right) | — |
| S5 | ✅ **DONE** (branch `ios/regulars-s5-models`, `[COMPILE-UNVERIFIED]` — no Xcode/Swift toolchain on the VPS; Mac `xcodebuild build`+`test` is a required gate before merge) | `@ios-engineer` | iOS model/service layer: `Models/Regular.swift` (`RegularEdge`/`RegularInvite`/`RegularInviteRedeemResult`/`PinNote`/`RegularNotice` — the last with `scheduledFor`; CodingKeys mapped verbatim against `07-regulars-schema.sql`'s real columns, same custom-ISO8601 `Date` decode convention as `ZoneMessage`/`CommunityPin`), `Services/RegularsService.swift` (`@MainActor @Observable`, raw URLSession + Codable, mirrors `ZoneMessageService`'s house shape: `fetchEdges`/`createInvite`/`redeemInvite`/`fetchNotices`/`sendNotice(body:scheduledFor:)`/`block`/`unblock` — every write sends ONLY the columns 07's column-level grants actually permit, e.g. `createInvite()` sends `created_by` alone, `sendNotice` sends `sender_id`/`body`/`scheduled_for` alone), `AppConstants.regularsEnabled = false` + the now-**6** guard tests named above (`RegularsFlagGuardTests`, `WeParkTests/RegularsModelServiceTests.swift`) + `regularsHeadStartRangeSeconds`/`regularsHeadStartDefaultSeconds` constants matching 07's `[60,3600]`s clamp and 15-minute default. Zero UI — `git diff` confirmed zero `Views/` files touched. 34 new tests (main was 1373 → 1407): Codable round-trips against fixture JSON copied verbatim from 07's column shapes (incl. a Scheduled Departure `scheduled_for` fixture whose `expires_at` lands past `scheduled_for`, not past `created_at`), all four `redeem_regular_invite` result-state decodes, and wire-level request-shape tests (URL/headers/body) per this repo's `PushTokenUpsertPayloadTests`/`PushRegistrationServiceWireTests` precedent. `pin_notes` read/write, the `revoked_at` "Cancel invite" update path, and a standalone `regular_edges` unfriend-delete were deliberately left for S7/S9 (not named in this session's dispatch list) — flagged in this row so a later session doesn't have to rediscover why. | — |
| S6 | ⬜ Not started | `@qa-verifier` | QA on S5. | — |
| S7 | ⬜ Not started | `@ios-engineer` | iOS UI: `RegularsSettingsView.swift`, `RegularInviteView.swift` (QR + `ShareLink`), `WeParkApp.swift` `.onOpenURL`, `Info.plist` URL scheme (Kevin's one-time step), `SettingsView.swift` row wiring. Depends on S5; needs S3/S4 deployed for the live-push half of its gate (can build against S5 alone and defer that half to S13). | — |
| S8 | ⬜ Not started | `@qa-verifier` | QA on S7 + Kevin's `Info.plist` step + a live two-device QR-scan-and-redeem smoke. | — |
| S9 | ⬜ Not started | `@ios-engineer` | iOS UI: `ParkedCarDetailView.swift` head-start chip row + custom stepper + optional note field (spec §3.4). **Amended scope:** preset ladder 5/10/15/30 min + Custom (1–60 min), default 15 min; plus the new honest-exclusivity inline warning (§1.2a — shown when the chosen head start ≥ the leaving-in value). Still one session, growth fits inside the existing ~2–4h unit. Depends on S5. **Parallel-execution seam** — S9/S7/S10 are three disjoint diffs sharing only the S5 dependency, safe as up to three concurrent worktrees once S5 merges. | — |
| S10 | ⬜ Not started | `@ios-engineer` | iOS UI: `RegularNoticeView.swift` (Quick Regulars Notice, spec §3.5) + entry point wiring. **Amended scope: stays send-now only** — Scheduled Departure's schedule mode is broken out into S10b so this session doesn't blow past its ~2–4h unit and the S7/S9/S10 parallel batch stays clean. Depends on S5. | — |
| S10b | ⬜ **New, §0 decision 7.** Not started | `@ios-engineer` | Scheduled Departure — `RegularNoticeView.swift` schedule mode (4th canned phrase, time picker, "Schedule for ___" button), local-notification scheduling for the T-0 poster reminder, deep link into `ParkedCarDetailView`'s existing Tiered Handoff sheet pre-filled for one-tap conversion, "no active parked car" fallback state (spec §3.5). Depends on **S9 AND S10 both merged** — reuses S9's composer as the conversion target, S10's sheet as the scheduling surface. This is the point the S7/S9/S10 parallel batch converges back to serial. Safe to run alongside S11/S12 (QA on the now-merged S9/S10) — no shared files. | — |
| S11 | ⬜ Not started | `@qa-verifier` | QA on S9. | S12 |
| S12 | ⬜ Not started | `@qa-verifier` | QA on S10. | S11 |
| S12b | ⬜ **New.** Not started | `@qa-verifier` | QA on S10b — including the no-show case (dismiss the T-0 reminder; confirm zero pin created, zero orphaned row, and the `regular_notices` row still expires on its own schedule) and the "parked car already gone" fallback. Local-notification-only, no physical-device push needed — **can run on Simulator**, unlike S13. Depends on S10b. | — |
| S13 | ⬜ Not started | `@ios-engineer` + Kevin ceremony | Physical-device push verification: friend-targeted visible push arrives immediately; zone-wide fallback push arrives only after the configured head start on a control device; custom head-start value round-trips server-clamped (against the amended `[60,3600]` range); `pin_notes` visible only to a Regular, RLS-filtered (not erroring) for a non-Regular control device on the same pin. **Needs an actual second person/device — spec §8's biggest named risk.** Depends on S3/S4 deployed, S9/S11 merged. | — |
| S14 | ⬜ Not started | `@ios-engineer` | Flag flip: `regularsEnabled = true`, adjust the now-**6** named guard tests to launched-world assertions, one small PR. Gated on everything above (including S10b/S12b) + Kevin's field-confidence call (spec §8). | — |

**Buffer:** +2 sessions for rework the QA passes surface (same historical-rate justification as the
Community 2.0 roadmap). **Total: 16 core (S1–S14, including S10b/S12b) + 2 buffer = 18 sessions.**

**Designer touchpoint:** `RegularInviteView`'s QR/link layout and `RegularsSettingsView`'s list — one
review pass, can happen any time after S7's first draft, does not block engineering (mirrors the
FT-20 sheet-detent review pattern from Community 2.0).

## Kevin's ceremonies (none skippable, none an agent's to perform)

- Apply `07-regulars-schema.sql` to production after S2's QA clears (dashboard paste).
- Apply the S1-follow-up migration (pins columns already exist as of S1 — this follow-up is the
  push-trigger rewrite + cron job) after its own QA clears — a SEPARATE apply from S1's, per the
  SCOPE NOTE's reasoning.
- Register `wepark://` in `Info.plist` before S8's live gate.
- Deploy `send-regular-push` + confirm the `sweep-leaving-soon-zone-push` cron job is running after
  S3/S4 clears (once the S1-follow-up migration has landed).
- S13's two-physical-device push verification.
- Confirm the Scheduled Departure 24-hour scheduling horizon (spec §6 item 4) — low-stakes, a one-line
  CHECK-constraint change either way, does not block any session.

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
4. **Amendment-reconciliation drift is a real, recurring risk on a spec that changes mid-build.** S1's
   own QA fix round found the schema had partially, not fully, reconciled a same-day formal amendment
   before its first push — not a one-off mistake, but a class of risk this roadmap should flag for
   every future session that lands after a spec amendment: always diff the actual file against the
   CURRENT spec text, not against the ruling/conversation that inspired the amendment.

## Decisions locked (do not re-litigate — spec §0)

1. Feature name: **"Regulars."**
2. DM scope: **NOT a chat app** — no threads, no inbox, no read receipts, no reply-in-app.
3. Car-pin visibility to Regulars: **no passive/standing visibility**, ever.
4. Tier timing: user-configurable, per post, presets + a custom picker.
5. Invite mechanism: **both QR and share link, same underlying token.**
6. **New, 2026-09-15 — head-start default + range.** Default 15 minutes; range `[60, 3600]` seconds
   (1–60 minutes); preset ladder 5/10/15/30 min + Custom.
7. **New, 2026-09-15 — Scheduled Departure.** A 4th canned-phrase mode on the Quick Regulars Notice
   lets a sender announce a future departure time; `regular_notices.scheduled_for` (nullable) carries
   it; expiry anchors past the declared time, not past post time.
8. **New, 2026-09-15 — honest exclusivity.** A head start measured in the same unit as a departure
   window can legitimately exceed it; the client warns before submit, the server does not reject it
   (spec §1.2a).
