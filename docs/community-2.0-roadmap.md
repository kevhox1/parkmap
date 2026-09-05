# Community 2.0 — Roadmap to the Hero Prototype (Build 20)

**Status:** Active roadmap. Date: 2026-08-26.
**Target:** the product shown in `design/prototype.html` + `design/screenshots/`, running on-device,
flag-flipped for external TestFlight.
**Spec:** `docs/community-2.0-reconciliation-spec.md` (all scope statements there govern; this doc is
the sequencing/sizing view).
**Verdict up front: FEASIBLE.** The reconciliation pass found that most of the hard primitives
already ship today (typed pins, realtime, confirm-to-extend, rate limiting, anonymous auth, the
FT-20 sheet). The genuinely new surface is bounded: two pin types, the crew feed, the report-flow
upgrade, identity, rep triggers, and one net-new infrastructure item (APNs).

---

## What a "session" means

The same unit used to size builds 18/19: **one focused working block (~2–4 h wall clock) driving
this repo to one coherent, QA-able output** — typically one PR built + tested, or one QA pass +
merge. A session includes the agent build, the test suite additions, and the doc updates; it does
NOT include Kevin's short gate tasks (Mac test run ≈ 5 min, live-sim smoke ≈ 10–30 min, dashboard
migration apply ≈ 15–30 min), which attach to the end of specific sessions and are called out
explicitly below.

## Session-by-session plan (~12–13 sessions, +2 buffer)

| # | Session | Work | Kevin gate at end |
|---|---|---|---|
| S1 | ✅ **Phase 0 build** (done 2026-08-26, PR #93) | @backend-data wrote the migration per spec §2 (enum additions, `position_fraction`/`leaving_minutes`/`claimed_by`, `claim_pin` RPC, rep triggers +5/+2/+1, rate-limit generalization, `device_push_tokens`, 3 zone-box seeds, server-derived `expires_at`, hygiene sweep) + curl test script | — |
| S2 | ✅ **Phase 0 QA → merged `9b42a853`** (2026-08-26) | Two QA passes: pass 1 FIX-THEN-MERGE (two rep-farming holes → append-only `reputation_award_log` ledger; durable-type rate-limit gap → `durable_crowd_report` key); pass 2 verified all 7 fixed, MERGE. `docs/qa/pr93-community-phase0-schema.md` | ✅ **APPLIED to prod + verified 2026-08-27.** Kevin ran both paste steps + the test script: 14/15 pass; the single "fail" was a script bug (asserted 403 where PostgREST correctly returns 401 for anon-role RLS denial — rejection itself confirmed, SQLSTATE 42501). Script assertion fixed same day. **Phase 0 is live in production.** |
| S3 | ✅ **Phase 1 model + service layer** (2026-08-27) | `.openSpot`/`.leavingSoon` cases + meta, 45m/120m TTLs, zone merge-gate dimension, `ZoneMessageService`, `communityEnabled` flag — PR #94 (draft) | — |
| S4 | ✅ **Phase 1 UI** (2026-08-28) | Crew feed mounted in the sheet's EXISTING `.large` detent (QA ruled this correct — the spec had mischaracterized FT-20 as two-detent), zone chips, new-type markers, empty states, client-side zone-box fallback for nil `zone_id` | — |
| S5 | ✅ **Phase 1 QA → MERGED `8b812041`** (2026-08-28) | QA pass 1 caught 2 blockers (ungated marker path; List-greedy layout redux) → fixed → pass 2 verified. Two Mac compile rounds (type-inference + arg-order, fixed same-hour). ⚠️ Squash title carries a stale `[COMPILE-UNVERIFIED]` tag — same gh retitle race as #91; the code is verified, this row governs | ✅ **DONE 2026-08-28:** 982/982 tests · full smoke green — flag-off pixel-parity + gated-marker invisibility vs a live prod row · flag-on feed/chips/fallback/empty-states · realtime insert ≤2s, delete near-instant. 📌 Note for S7: hand-inserted pin rendered mid-block (raw lat/lng, un-snapped test data) — eyeball placement again once 2b's curb-snap flow exists |
| S6 | ✅ **Phase 2a → MERGED `1fbee567`** (2026-08-28, PR #95) | Confirm-the-street (W5 reuse) + closure tile → existing FT-15 sheet (zero-diff verified) + write-time zone stamping. The long one: 2 QA passes + a live-gate teardown blocker (row shifted under the finger mid-tap — fixed by rendering the closure row first) + a routing model wired into the live buttons + a stop-and-instrument round that proved the "missing" confirm-street section was a below-the-fold discoverability flaw, not a bug (open-items #12). Suite 982→**1023** | ✅ Full gate done: 1023/1023 · flag-off 2-type parity · closure hand-off immediate-tap · candidate pick updates heading chips · sweeper flow verified. 4 UX findings logged to open-items #12, all deferred to S13 |
| S7 | ✅ **Phase 2b build** (2026-08-28→31, PR #96) | `SpotPlacementView` (curb snap + fraction — verified landing ON the curb line live) + `IdentitySheet` (show-once + swipe-dismiss cancellation) + profiles upsert (username made non-optional at type level after QA found a masked NOT-NULL violation) + the 2×2 tile-grid rider (resolves S6's row-order compromise by construction) | — |
| S8 | ✅ **Phase 2b QA → MERGED `ebf16b64`** (2026-08-31) | 2 QA passes (pass 1: silent NOT-NULL + second stacked `.sheet` → both fixed, single-sheet `ActiveSheet.identityPrompt` pattern; pass 2 verified cold). One compile round. Suite 1023→**1067**. Full gate: flag-off parity · 2×2 grid · placement accuracy · cleared-handle live vs prod ✓ · show-once ✓ · swipe-dismiss fakeout ✓ · pin lifecycle verified end-to-end in prod incl. the cron soft-close (resolved_at stamped on schedule 3 days running) | ⚠️ **AC-P2.1 literal two-device run DEFERRED TO S12** — Kevin's Mac can't carry an Xcode device build (memory) and a second sim overloads it; both halves proven separately (client→server via live posts + SQL; server→client via live SQL-insert propagating ≤2s). S12's internal-TestFlight phone build closes the literal check. Phone dev-build issue also noted for pre-S12 |
| S9 | ✅ **Phase 3 → MERGED `c581d65f`** (2026-09-01, PR #97) | Reactions routed through one shared pure fn on both surfaces (fixed a pre-existing leaving_soon gap in PinDetailSheet), claim wired to live `claim_pin` (S4 stub gone), profile row, leaderboard v1 (cancellable `.task(id:)` + bounded top-200 query after QA). **Tickets-dodged honestly skipped** → replaced by Kevin's garage-savings decision (S13c). Suite 1067→**1111**. Mac gate caught a real test-fixture bug (6-way tie + alphabetical tie-break ranked "Me" #1 — test wrong, impl right, hand-traced). ⚠️ Xcode 26.5→26.6 update wiped all sims mid-gate — device now resolved dynamically per updated memory | ✅ 1111/1111 · flag-on feed visual + zone-flick race check ✓ (claim live-check deferred — RPC verified at Phase 0 gate + request-shape tested) |
| S10 | ✅ **Phase 4a → MERGED `5452ccc9`** (2026-09-01, PR #98) | Leaving-soon handoff (FCFS copy verbatim, identity-gated, server-derived expiry) + WP4 My Car redesign (offset chips, swept badge, screenshot-15 layout) + direction-doc §4 superseded-marker in the same PR per spec §5. Claim UI confirmed already shipped in S9 (stale roadmap wording, QA-verified non-issue). 2 QA passes fixed: truth-derived duplicate-post guard + a PRE-EXISTING reminder-offsets lost-update bug (ContentView stale cache) the chips made reachable. One compile round (XCTestCase-extension name shadow). Suite 1111→**1154**. Two 🟢 minors logged (justPosted latch outlives TTL with sheet held open; exact-30m-radius boundary test) — S13-class | ✅ Full gate 2026-09-01: 1154/1154 · mount-chain 📸 · flag-off My Car parity 📸 · screenshot-15 layout live 📸 · leaving-soon posted → 🚙 on map · reopen shows posted state (dupe fix) · cross-sheet chip edit survives Settings (lost-update fix, both directions) |
| S11 | ✅ **Phase 4b backend → MERGED + DEPLOYED + VERIFIED** (2026-09-02/03, PRs #99 `79e24ddf` + #100 `8b532b08`) | Edge Function + pg_net trigger + avatar view fix. QA pass 1 **proved the fail-open guarantee false on live local Postgres** (Vault read outside the exception block → a Vault hiccup would have 500'd the live crowd loop) → fixed + re-proven both stages. Kevin's deploy ceremony then caught a SECOND prod bug: deny-all SELECT on `device_push_tokens` + PostgREST RETURNING → all token writes 42501 → PR #100 select-own policy; spec §2.9 amended | ✅ **Ceremony complete 2026-09-03**: 5 secrets set (one caught empty-key near-miss), function deployed, migrations 04+05 applied, **test script 10/10**, `net._http_response` 200, function log `no sandbox tokens… nothing to send` w/ matching pin id. `.p8` at `~/Documents/keys/`. ⚠️ S12 note: **TestFlight uses the production APNs environment** — client stamps `environment` per build type; `APNS_ENV` flips to `production` for the TestFlight phase |
| S12 | ✅ **Phase 4b iOS → MERGED `4e78b8f1` + VERIFIED ON HARDWARE** (2026-09-04/05, PR #101) | Push registration (runtime env stamping via embedded-profile parse), silent-push relevance router (on-device only — server never learns the blockface), WP5 confirm card. QA caught the missing `on_conflict` on token upsert AND, from the same pattern, a **shipped production bug: vote-CHANGING silently broken since Tier 3** (fixed same commit, recorded in field-testing-log). Suite 1154→**1183**, first blind-built branch to pass first-try | ✅ **THE BUZZ, 2026-09-05:** TestFlight build 20 (Option B ceremony, archived from `main@93cf963a`+local flag flip, discarded after) → token registered `production`/`nolita` → app closed → SQL sweeper insert on the car's segment → **notification received**; different-segment control → **silence**. AC-P4.3 ✓, two-device check ✓. Two-day detour root-caused: NO code bug — the phone was running an older community binary; registration code first executed after installing the real build 20. New ceremony rule: verify the INSTALLED TestFlight build number, not the upload |
| S13a | **Map chrome parity (WP1+WP2, ~2 sessions)** | Persistent Report pill (bottom-left) + "?" map-key button/legend (screenshots 01/02) + zone-boundary dashed overlay (screenshot 03). Touches `ContentView` + `MapViewRepresentable` — targeted live smoke required | Mac: test run + sim smoke |
| S13b | **Block detail redesign + chat write path (WP3, ~1.5–2 sessions)** | The gap-inventory's headline: `BlockDetailView` per screenshot 07 (color header, LIVE ON THIS BLOCK, BLOCK CHATTER + compose) + `ZoneMessageService.sendMessage` — the write path that makes the live `award_chat_reputation` trigger reachable. **No spec ever listed this file; added by Kevin's 2026-08-28 expansion decision** | Mac: test run + sim smoke |
| S13c | **Hero-parity pass** | @designer screenshot-by-screenshot audit vs `design/screenshots/`, copy verbatim-check, empty/dark states, crew-feed icon palette consistency fix; fix list worked; final QA. **+DECISION (Kevin 2026-08-31): the prototype's "tickets dodged" card is replaced by a garage-savings stat** — S9 correctly skipped tickets-dodged as unfabricatable ("interesting but so difficult to verify" — Kevin); the replacement is honestly derivable (parked-duration from Park Here → clear-pin timestamps × a garage rate), framing to be made catchy ("money saved from garage or something like that"). Needs a small derivation design (session accumulation, rate source, per-user vs zone-level) — spec it within S13c or as a fast-follow, never fabricate | Mac: final smoke |

**Buffer:** +2 sessions for rework the QA passes surface (historical rate on this repo justifies it).
**Total: ~15–18 sessions** (expanded 2026-08-28 from ~12–15: Kevin adopted the gap-inventory plan —
`docs/design/community-2.0-hero-gap-inventory.md` — adding S13a/S13b and four near-free riders).

**⚠️ Flag-flip prerequisite discovered 2026-08-28:** running the suite with `communityEnabled = true`
fails 3 tests (found accidentally via a stale working-tree flag during PR #95's gate; suite is
1021/1021 with the flag off). The eventual launch commit that flips the flag MUST identify and
adjust those flag-value-dependent tests in the same PR — budget it into the flip, don't discover it
at launch.

## Calendar shape

At the usual pace (1–2 sessions/day driven from the phone, Mac gates batched), this is **roughly
1.5–2.5 weeks of build time** — which lands the finished, dark-shipped feature right around when
Kevin is back in NYC. That timing is not a coincidence to fight: the **flag flip is gated on the
build-18 drive test** (realtime proven on a moving car), which is the first thing that happens on
return. External testers see community the day the drive test passes, not before.

## What is genuinely NYC/second-phone blocked (nothing else is)

- Build-18 drive test → gates `communityEnabled` flip + external rollout, NOT any merge.
- Cross-device iCloud verification (#91 follow-up) — needs the second phone.
- Sunlight legibility on any new chrome — rides along with the next drive test.
- Everything else on this roadmap is verifiable now: two-device realtime ACs use Mac simulator +
  phone; APNs verification uses one physical phone + a SQL insert.

## Decisions locked (do not re-litigate)

1. Leaving-soon handoff IS in v1 (Kevin 2026-08-26; reverses direction-doc §4 — superseded-marker
   edit rides with Phase 4a's merge).
2. TTLs: prototype governs — enforcement 45m / sweeper 120m; **age always displayed** (staleness is
   the signal). `open_spot` 3m, `leaving_soon` stated+3.
3. APNs planned: token table in Phase 0, pipeline in Phase 4b.
4. Zones: Nolita/SoHo/LES as **bounding boxes** (OQ-1 recommendation adopted 2026-08-26 with Kevin's
   "you have everything you need" go-ahead; true NTA polygons only if boxes misclassify in practice).
5. Build numbering: community = build 20. Smart-route renumbers to 21+ when picked up.
6. **Prototype-exact fidelity (Kevin 2026-08-28):** "match the claude design hero as exactly as
   possible" — including the Report pill + map-key chrome (ruled NOT in tension with FT-20 §0f,
   which covered the sheet's action column, not map chrome). Standing exceptions, both protecting
   Kevin's own older rules: map markers keep the teal SF-Symbol treatment (prototype's orange rings
   collide with the sacred curb-legality orange) and the crew feed stays at the `.large` detent.
   Overruling either requires an explicit new decision, not a parity fix.

## Top risks, honestly ranked

1. **`BrowseNavigationSheet` third detent (S4)** — the file has three documented live-UI regressions;
   this is why S5 budgets two QA passes and a mandatory live smoke.
2. **APNs (S11–12)** — net-new infra with a known silent-failure mode (same shape as the iCloud
   capability gap). Mitigated by doing the one-time setup *before* S11, and by 4a/4b split so the
   handoff feature ships regardless.
3. **`ContentView.swift` contention** — every phase wires something here; phases are serialized
   partly for this reason. No two iOS agents touch it concurrently.
4. **Flag-flip realtime dependence** — merges are safe (dark); the rollout gate is the drive test.
