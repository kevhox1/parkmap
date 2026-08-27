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
| S2 | ✅ **Phase 0 QA → merged `9b42a853`** (2026-08-26) | Two QA passes: pass 1 FIX-THEN-MERGE (two rep-farming holes → append-only `reputation_award_log` ledger; durable-type rate-limit gap → `durable_crowd_report` key); pass 2 verified all 7 fixed, MERGE. `docs/qa/pr93-community-phase0-schema.md` | ⏳ **PENDING: apply migration in dashboard + run test script (~30 min).** Two-step paste — enum block first, commit, then the rest (procedure in PR #93 body). Phase 1 UI work does not wait on this; live testing does |
| S3 | **Phase 1 model + service layer** | `.openSpot`/`.leavingSoon` cases + meta, 45m/120m TTL update, `zone_id` merge-gate dimension, `ZoneMessageService` (no runtime DB dependency — PR #36 precedent) | — |
| S4 | **Phase 1 UI** | Crew feed section in `BrowseNavigationSheet`, third detent, zone chips, empty states — the highest-regression-risk change (3-incident file) | — |
| S5 | **Phase 1 QA → merge** | 2 QA passes budgeted for this file | Mac: test run + live-sim smoke, AC-P1.3/P1.5 |
| S6 | **Phase 2a → merge** | Confirm-the-street (W5 pattern reuse) + closure tile → existing `BlockRestrictionReportSheet`. Reuse-heavy, QA same session. **Also**: stamp `zone_id` server-side on `insertCrowdPin` (S4 QA pass 1, PR #94 Finding #3 — every write path today inserts `zone_id: nil`; S4 shipped a client-side bounding-box fallback in `CrewFeedMerge.resolvedZoneId(for:)` so the crew feed still surfaces pre-existing pins, but that's a display-only patch, not a cure — `pins.zone_id` itself should get populated at write time, mirroring OQ-1's box-lookup-by-lat/lng, so a future server-side/analytics query on the column isn't silently null) | Mac: test run |
| S7 | **Phase 2b build** | `SpotPlacementView` (curb snap + fraction) + `IdentitySheet` (show-once gate, spec §3 fix) + profiles upsert | — |
| S8 | **Phase 2b QA → merge** | Includes AC-P2.1 two-device check: **Mac simulator + Kevin's phone** — does NOT need the second phone or NYC | Mac: sim + phone side-by-side (~30 min) |
| S9 | **Phase 3 → merge** | `ReactionsRow` extension, profile row (div-by-zero guard), leaderboard v1 (live query), QA same session | Mac: test run |
| S10 | **Phase 4a → merge** | Leaving-soon picker + claim button in `ParkedCarDetailView` (only file colliding with #91 — safely post-merge by now) | Mac: test run + sim smoke |
| S11 | **Phase 4b backend** | `send-community-push` Edge Function + `pg_net` trigger + token-table wiring | One-time APNs setup: `.p8` key in ASC + `aps-environment` entitlement (flagged NOW to avoid a repeat of the iCloud-capability silent gap) |
| S12 | **Phase 4b iOS → merge** | APNs registration, zone-scoped token upload, silent-push → on-device relevance gate → local notification | Physical phone + SQL insert verifies AC-P4.3 — works outside NYC |
| S13 | **Hero-parity pass** | @designer screenshot-by-screenshot audit vs `design/screenshots/`, copy verbatim-check, empty/dark states; fix list worked; final QA | Mac: final smoke |

**Buffer:** +2 sessions for rework the QA passes surface (historical rate on this repo justifies it).
**Total: ~12–15 sessions.**

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

## Top risks, honestly ranked

1. **`BrowseNavigationSheet` third detent (S4)** — the file has three documented live-UI regressions;
   this is why S5 budgets two QA passes and a mandatory live smoke.
2. **APNs (S11–12)** — net-new infra with a known silent-failure mode (same shape as the iCloud
   capability gap). Mitigated by doing the one-time setup *before* S11, and by 4a/4b split so the
   handoff feature ships regardless.
3. **`ContentView.swift` contention** — every phase wires something here; phases are serialized
   partly for this reason. No two iOS agents touch it concurrently.
4. **Flag-flip realtime dependence** — merges are safe (dark); the rollout gate is the drive test.
