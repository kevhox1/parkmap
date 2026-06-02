# Community 1.0 — Build Plan, Sequencing, and Re-Aimed Metric

**Status:** Planning spec. Date: 2026-06-01.
**Owner:** Tech Lead (this doc), Kevin (decision approval on OQ table below), @backend-data + @ios-engineer (execution).
**Anchor doc:** `docs/community-1.0-direction.md` (read first).
**Foundational dependency:** `docs/typed-pin-schema-spec.md` (the pin schema this plan builds on top of).
**Supersedes framing:** the queued `docs/w8-metrics-survey-spec.md` was never written (per direction doc §8). This plan absorbs the useful parts of that idea into §4 (re-aimed metric). Do not create `w8-metrics-survey-spec.md`.

---

## Compact Open Questions Table (Kevin approves/flips fast)

Resolved OQs from `community-1.0-direction.md` §9 + schema spec — decisions you need to confirm before Tier 1 build starts.

| # | Question | Options | Recommendation | Kevin's call |
|---|---|---|---|---|
| OQ-1 | **Pin schema: generalize now?** | (a) Yes — typed pins, greenfield. (b) Migrate later from W5-only model. | **(a) DECIDED** by Kevin. Already encoded in `docs/typed-pin-schema-spec.md`. No action needed. | ✅ Decided |
| OQ-2 | **Beachhead neighborhood for Tier 3** | (a) SOHO/LES — PWA already piloted it, zone already seeded in DB (`zones.id = 'soho-les'`). (b) A different neighborhood (needs new zone seed + rationale). | **(a) SOHO/LES.** The `soho-les` zone is already seeded in `01-mvp-schema.sql`. PWA chat ran there. No new infra. The dense commercial + residential mix makes it ideal for filming/enforcement/sweeper density. | |
| OQ-3 | **Reputation model: reuse profiles or new?** | (a) Reuse existing `profiles.reputation integer` column (already in `01-mvp-schema.sql`). (b) New reputation table with per-category scores. | **(a) Reuse.** `profiles.reputation` exists today. A per-category table is more expressive but adds 2 weeks of backend work for MVP. Tier 2 spec will define the increment/decrement rules against the existing column. | |
| OQ-4 | **Tier 1 NYC open data sources: which are reliable enough to seed?** | Film permits ✓ (NYC OpenData, machine-readable). ASP calendar ✓ (already in app). DOT closures = quality TBD (often PDF/partial). Construction via HIQA = partial. | **Film permits + ASP calendar for TF1.** DOT closures and construction from HIQA are too unreliable for MVP — the wrong-pin cost on durable types is high (users trust authoritative pins). DOT/construction can be added in TF2 after quality is evaluated. Special events via NYC 311 / OpenData is a stretch goal for TF1 (depends on data quality audit by @backend-data). | |
| OQ-5 | **TF1 scope line: Tier 1 only, or more?** | (a) TF1 ships Tier 1 only (seeded citywide, no reputation). Tier 2+3 are TF2. (b) TF1 ships Tier 1 + read-only Tier 2 (users see sign corrections and block notes but can't yet create them). (c) TF1 ships Tier 1 + full Tier 2 (create + vote). | **(a) Tier 1 only for TF1.** Rationale: TF1's job is proving the core parking value prop to a small beta group. Tier 1 delivers that with near-zero community risk (authoritative data, no user-generated content QA needed). Tier 2 requires reputation + moderation; shipping it under-baked to 50 beta users will produce bad data that contaminates the dataset. Land the map read experience first. | |
| OQ-6 | **North-star metric: what replaces 70%-Yes Drive Mode survey?** | See §4 below for the full re-aimed metric design. | See §4 — recommend a 3-metric dashboard: contribution density, active-reporter coverage, retention-with-session-start. Drive Mode fear-reduction is one component (kept as a survey question) but not the only gate. | |

---

## 1. Problem Statement

The existing iOS build (W1–W8.5d, merged to main) delivers a complete Drive Mode + parked-car management experience. It is a solo-user product: every bit of value comes from the static city data or the user's own actions. Community 1.0 is the step that adds a second data layer — real-time + correction intel that makes the static data *true today*.

The build plan below sequences that second layer to minimize cold-start risk and maximize value-per-shipped-tier.

---

## 2. Dependency Graph

```
[typed-pin-schema-spec.md]  ← foundational; must land first
          │
          ├── [Tier 1: open-data ingestion]  (@backend-data)
          │         │
          │         └── [Tier 1: iOS pin display]  (@ios-engineer)
          │                   │
          │                   └── [TF1 distribution]  (@ios-engineer + Kevin)
          │
          ├── [Tier 2: crowd durable + reputation]  (@backend-data + @ios-engineer)
          │         │
          │         └── [Tier 2: sign-correction + block-note reporting UI]  (@ios-engineer)
          │                   │
          │                   └── [Tier 2: vote/confirm UI]  (@ios-engineer)
          │
          └── [Tier 3: ephemeral + decay + confirm]  (@backend-data + @ios-engineer)
                    │
                    └── [Patrol mode (W8.5e–i)]  (@ios-engineer) ← already in W8.5 roadmap
```

Streams within each tier are designed for parallelism: `@backend-data` (schema/ingest) and `@ios-engineer` (display/reporting UI) can work simultaneously once the schema spec is approved. See §6 for the parallel work-stream table.

---

## 3. Tier-by-Tier Spec Decomposition

### Tier 1 — Seeded, Citywide, Value at Zero Users

**Goal:** Film permits and ASP-today pins appear on the map before a single user has reported anything. A user opening the app on a filming day sees "Filming — no parking this block" overlaid on the static data. Cold-start is solved.

**New primitive:** Open-data ingestion pipeline.

**Downstream specs to write (not yet written):**

- `docs/tier1-open-data-ingest-spec.md` — @backend-data owns. NYC OpenData film-permit API polling, ASP-suspension calendar sync (already in app but not as a community pin), cron/edge-function schedule, idempotent upsert by `permit_id`. Film permits: `https://data.cityofnewyork.us/City-Government/Film-Permits/tg4x-b46p` (Socrata JSON). No CORS issue from Supabase Edge Functions (server-side fetch).

- `docs/tier1-pin-display-spec.md` — @ios-engineer owns. Read-only map layer showing `filming`, `asp_suspended_today`, `special_event` pins from Supabase. PostgREST bounding-box query on map region change (same trigger as tile loading). Pin callout UI. Does NOT require auth. Realtime subscription for live updates.

**TF1 entry gate:** Schema applied + at least one film permit correctly seeded + pin visible on map in NYC coverage area.

**Build order (within Tier 1):**
1. Schema spec approved (this doc + `typed-pin-schema-spec.md`).
2. `supabase/02-pins-schema.sql` applied by @backend-data. QA-verified per AC-S1–S12.
3. @backend-data and @ios-engineer work in parallel:
   - @backend-data: ingest script, film-permit seed, ASP-today sync.
   - @ios-engineer: `CommunityPin.swift` model + `CommunityPinService.swift` fetch + read-only pin display layer on the map.

### Tier 2 — Crowd, Durable, Low Density Bar

**Goal:** A single experienced parker can report "this sign says Mon-Fri 8-6 but there's no sign anymore" and that correction helps everyone who parks on that block indefinitely. One person + one report = compounding value.

**New primitive:** Reputation + upvote. A sign-correction pin gains trust as others confirm it. The reporter's `profiles.reputation` increments.

**Downstream specs to write:**

- `docs/tier2-sign-correction-spec.md` — the reporting UI for sign-correction and block-note pins. @ios-engineer owns the UI; @backend-data owns the reputation-increment RPC.

- `docs/tier2-vote-confirm-spec.md` — the "Confirm" / "Dispute" tap on any Tier 1 or Tier 2 pin. @ios-engineer owns UI; `votes` table is already in `02-pins-schema.sql`.

- `docs/tier2-reputation-spec.md` — rules for incrementing/decrementing `profiles.reputation`. Simple for MVP: +2 for a sign-correction that receives 3+ confirms, -1 for a pin that receives 2x more disputes than confirms. @backend-data owns the DB trigger or RPC. Reuses existing `profiles.reputation` column.

**Density requirement:** Low. A single report is useful. No beachhead constraint.

**Build order (within Tier 2):** Serializes after Tier 1 pin display is live (users need to see pins before they can vote on them). Sign-correction reporting UI + vote UI can run in parallel once the schema supports it (it does — `votes` table in `02-pins-schema.sql`).

### Tier 3 — Crowd, Ephemeral, High Density Bar (+ Patrol Mode)

**Goal:** "Enforcement active on Mott St — reported 3 min ago, 2 confirms." This only has value if there are enough simultaneous users in the area to generate a signal. Ship beachhead-first.

**New primitive:** Decay + "still there?" confirm. The `extend_pin_expiry` RPC (defined in `typed-pin-schema-spec.md` §8) is the mechanical heart.

**Downstream specs to write:**

- `docs/tier3-ephemeral-report-spec.md` — the reporting UI for `enforcement_active`, `sweeper_passed`, `broken_meter`. This is where patrol mode (W8.5e–i) lands. The reporting action is a tap in patrol mode → select type → optional sub-tag → submit. @ios-engineer owns; the spec is a sub-spec of the W8.5 master.

- `docs/tier3-decay-display-spec.md` — how the map shows ephemeral pins: a fading indicator, "reported X min ago, N confirms", "Still there?" CTA. @ios-engineer owns. @designer reviews.

- `docs/tier3-beachhead-spec.md` — the SOHO/LES zone launch plan. How we seed the first 10–20 active reporters (Kevin's network + sticker program + zone-chat invite). What density metric triggers a "good enough" signal (recommendation: ≥3 confirms on an enforcement_active pin within 5 min of report = the signal works). @backend-data owns zone configuration; Kevin owns distribution.

**Density requirement:** High. Only ship to SOHO/LES in TF1 scope. Citywide in TF2 once density patterns are understood.

**Build order (within Tier 3):** Serializes after Tier 2 reputation is live (reporters need a trust signal before ephemeral pins are worth displaying). Patrol mode (W8.5e–i) was already planned in the Drive Mode roadmap; this plan aligns it with Tier 3 as the reporting UI surface.

---

## 4. Re-Aimed North-Star Metric

### The Problem with the Old Metric

The queued `w8-metrics-survey-spec.md` (never written; per `community-1.0-direction.md` §8, held pending this doc) was aiming at a single Drive-Mode question: "Did WePark reduce your parking anxiety?" with a 70%-Yes threshold. That metric:

1. Only measures the solo-user Drive Mode experience — ignores community contribution entirely.
2. Is binary: one survey question can't detect whether the app is improving or degrading.
3. Doesn't measure retention or habit formation — a user who answers "Yes" once might churn the next week.

### The Re-Aimed Dashboard (3 metrics + Drive Mode as input)

**Metric 1 — Contribution Density (the supply signal)**

Definition: Number of community pins created per 1,000 Drive Mode sessions per zone per week.

Why: If experienced parkers aren't contributing, the community layer is empty regardless of how many novices use Drive Mode. This measures whether the flywheel is turning.

Target for "healthy" at launch: ≥1 pin per 100 Drive Mode sessions in SOHO/LES within the first 4 weeks of Tier 1 live. (Filmed permit pins seeded by @backend-data count toward this — they prime the map and demonstrate the format.)

Implementation: `drive_sessions` Supabase table (see §4.1 below) + pin count query per zone per week.

**Metric 2 — Active-Reporter Coverage (the density signal)**

Definition: Percentage of Drive Mode sessions where at least one community pin was visible in the user's route corridor (within 500m of any point on the route).

Why: Measures whether the community layer is actually providing coverage for the driving user, not just whether pins exist somewhere in the city.

Target: ≥20% of Drive Mode sessions see at least one community pin within 4 weeks of Tier 1 live (seeded film-permit pins drive this).

Implementation: Post-route server-side check — after a Drive Mode session ends (arrival or "End Drive"), query pins within a bounding box of the route's polyline. Log to a `session_coverage` view or column.

**Metric 3 — Retention With Session Start (the habit signal)**

Definition: 7-day and 30-day retention of users who have started at least one Drive Mode session.

Why: Users who use Drive Mode are the highest-value segment (they've seen the core product). If they come back, the product is sticky. If they don't, the core value prop isn't landing.

Target: ≥40% 7-day retention among users with ≥1 Drive Mode session. (Industry average for utility apps is 20–30%.)

Implementation: `drive_sessions` table + standard retention cohort query.

**Drive Mode Fear-Reduction (as one input, not the gate)**

The original 70%-Yes survey question is valuable but demoted from gating metric to diagnostic input. It is asked once at Day 3 post-Drive-Mode-use (not at first session — too early):

> "Did WePark help you find parking with less stress? Yes / Somewhat / No."

This is the same survey idea from the original queued spec, kept because the qualitative signal is useful. The threshold is now "70%-Yes or Somewhat = feature is working" rather than "70%-Yes-only = ship/hold." It feeds into Metric 1 (if fear is high but contribution is low, community layer isn't compensating).

### 4.1 `drive_sessions` Table (new; lightweight)

This table was the centerpiece of the queued `w8-metrics-survey-spec.md`. It belongs here:

```sql
-- Proposal for supabase/03-metrics-schema.sql (separate migration, separate spec)
-- Included here for completeness; @backend-data writes the actual migration.

create table if not exists public.drive_sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null,
  -- null = anonymous session (no auth required for Drive Mode in MVP)
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  origin_lat   double precision,
  origin_lng   double precision,
  dest_lat     double precision,
  dest_lng     double precision,
  zone_id      text references public.zones(id) on delete set null,
  pin_drop_within_10min boolean,  -- did user drop a parked-car pin within 10 min of session end?
  survey_response text check (survey_response in ('yes', 'somewhat', 'no', null))
  -- survey shown on Day 3; null until then
);
```

This table is intentionally thin. It does not log GPS trace or route geometry (privacy). The `pin_drop_within_10min` flag is set by the iOS client when `ParkPinService.save` fires within 10 minutes of `ended_at` — a proxy for "did Drive Mode successfully get them to a parking spot."

The survey question fires on Day 3 post-first-Drive-Mode-session. iOS implementation: `NotificationScheduler` schedules a local notification 3 days after `drive_sessions.started_at` (first session only). Tapping the notification routes to an in-app one-question survey sheet. Response is written back to `drive_sessions` via Supabase upsert.

**Note:** The `drive_sessions` table spec is a separate migration (`supabase/03-metrics-schema.sql`) written by @backend-data. This build plan calls it out here to establish the intent; the full spec is a downstream `docs/metrics-schema-spec.md`.

---

## 5. Sequencing Against the W8.5 Roadmap

The existing W8.5 roadmap (from HANDOFF.md) is: destination-mode Drive Mode complete (W8.5d done) → drive-test → W8.5c-follow voice calibration → patrol mode (W8.5e–i) → W8 TF1.

Community 1.0 inserts cleanly alongside that roadmap:

| Phase | W8.5 stream | Community 1.0 stream | Can parallel? |
|---|---|---|---|
| Now (post-W8.5d) | Drive-test + W8.5c-follow voice calibration | Schema spec review + `@backend-data` starts `02-pins-schema.sql` | Yes |
| Next | Patrol mode W8.5e–i (reporting UI surface) | Tier 1 ingest pipeline (@backend-data) + Tier 1 pin display (@ios-engineer) | Yes — disjoint files |
| After patrol mode | W8 TF1 prep (on-device install, Mapbox token restriction, App Store) | Tier 1 fully live on device; Tier 2 spec written | TF1 ships with Tier 1 community layer |
| Post-TF1 | W8.5c-follow calibration tuning | Tier 2 reporting UI + voting | Sequential (TF1 first) |
| TF2 | Expanded Drive Mode (maneuver hints, etc.) | Tier 3 ephemeral + decay + SOHO/LES beachhead | Yes |

The key insight: **patrol mode (W8.5e–i) is Tier 3's reporting UI surface**. These two tracks share the same engineering moment. Tier 3 does not need its own separate UI build — patrol mode IS the Tier 3 reporting flow. The community-1.0 direction doc's Tier 3 and the W8.5 master spec's patrol mode are the same session in the same build.

---

## 6. Parallel Work-Stream Table (Full Picture)

Per TEAM.md parallelization rules: streams touching disjoint files run in the same invocation.

| Stream | Owner | Spec doc (to write) | Unblocked by | Parallel with |
|---|---|---|---|---|
| **Schema apply** | @backend-data | `typed-pin-schema-spec.md` (done) | Kevin OQ-table approval | iOS model layer (B) |
| **iOS model layer** | @ios-engineer | `typed-pin-schema-spec.md` (done) §10 | Kevin OQ-table approval | Schema apply (A) |
| **Tier 1 ingest** | @backend-data | `tier1-open-data-ingest-spec.md` | Schema applied + QA'd | Tier 1 iOS display (D) |
| **Tier 1 iOS pin display** | @ios-engineer | `tier1-pin-display-spec.md` | iOS model layer + schema applied | Tier 1 ingest (C) |
| **Drive-test + W8.5c-follow** | @ios-engineer + Kevin | none (carry-over) | Kevin installs on device | Tier 1 ingest (C) |
| **Patrol mode W8.5e–i** | @ios-engineer | existing W8.5 master spec | W8.5d merged (done) | Tier 1 ingest (C) |
| **Metrics schema** | @backend-data | `metrics-schema-spec.md` (to write) | Schema applied | Everything above |
| **Tier 2 sign-correction** | @ios-engineer + @backend-data | `tier2-sign-correction-spec.md` | Tier 1 display live in TF1 | Post-TF1 |
| **Tier 2 vote/confirm** | @ios-engineer | `tier2-vote-confirm-spec.md` | Tier 2 sign-correction | Post-TF1 |
| **Tier 2 reputation** | @backend-data | `tier2-reputation-spec.md` | Tier 2 vote/confirm | Post-TF1 |
| **Tier 3 ephemeral + decay** | @backend-data + @ios-engineer | `tier3-ephemeral-report-spec.md` | Tier 2 reputation, patrol mode | TF2 |
| **SOHO/LES beachhead** | Kevin + @backend-data | `tier3-beachhead-spec.md` | Tier 3 ephemeral + decay | TF2 |

---

## 7. Acceptance Criteria (Build Plan Level)

These are the criteria that determine when each tier is "done" from a product perspective. Feature-level ACs live in the downstream specs.

**Tier 1 done when:**
- [ ] **AC-T1.1** At least one film-permit pin is visible on the iOS map for a real NYC filming location (or a seeded test permit in a known block).
- [ ] **AC-T1.2** An ASP-suspended-today pin appears on the correct blocks on a day when ASP is actually suspended (or test-verified with a seed record).
- [ ] **AC-T1.3** Pins are filtered correctly by bounding box — a user in SOHO does not see pins from Midtown (verified by query inspection, not just visual check).
- [ ] **AC-T1.4** Pins survive a Supabase Realtime reconnect (WebSocket drop + reconnect) — pin count on map does not decrease after reconnect.
- [ ] **AC-T1.5** No unauthenticated user can create a filming or ASP-today pin via the PostgREST REST API (confirmed by AC-S5 in schema spec).
- [ ] **AC-T1.6** Contribution density metric is instrumented: `drive_sessions` table exists and records a session row when Drive Mode ends.

**Tier 2 done when:**
- [ ] **AC-T2.1** A logged-in user can submit a sign-correction pin from the block detail sheet. The pin appears on the map for all users within 5s (Realtime).
- [ ] **AC-T2.2** A different logged-in user can tap the sign-correction pin and vote "Confirm" or "Dispute." `confirm_count` or `dispute_count` increments in the DB within 2s.
- [ ] **AC-T2.3** After 3 confirms, the submitting user's `profiles.reputation` increments by 2.
- [ ] **AC-T2.4** A sign-correction pin with dispute_count ≥ 2×confirm_count is auto-flagged (resolved_at set or hidden from map). Mechanism defined in `tier2-reputation-spec.md`.

**Tier 3 done when:**
- [ ] **AC-T3.1** A patrol-mode user in SOHO/LES can report `enforcement_active` with optional sub-tag. The pin appears on all other users' maps within 5s.
- [ ] **AC-T3.2** An `enforcement_active` pin's `expires_at` starts at 30 minutes. A "Still there?" tap by a second user extends it by 15 minutes (capped at 2h).
- [ ] **AC-T3.3** An `enforcement_active` pin with no confirms after 30 minutes disappears from the map (client-side expiry filter).
- [ ] **AC-T3.4** Contribution density in SOHO/LES reaches ≥1 pin per 100 Drive Mode sessions within 4 weeks of Tier 3 live (the beachhead signal).

---

## 8. Open Decisions Follow-Up Protocol

Once Kevin reviews the OQ table at the top of this doc and fills in the "Kevin's call" column, the recommended dispatch order is:

1. **Kevin approves OQs 2–5.** (OQ-1 is already decided.)
2. **Dispatch @backend-data** to write `supabase/02-pins-schema.sql` per `typed-pin-schema-spec.md`.
3. **In parallel, dispatch @ios-engineer** to write `Models/CommunityPin.swift` + all meta structs + decode unit tests (no DB dependency for this work).
4. Once schema is applied and QA-verified, dispatch @backend-data to write `tier1-open-data-ingest-spec.md` and begin the film-permit ingest script.
5. Dispatch @ios-engineer to write `tier1-pin-display-spec.md` and begin the map display layer.
6. Continue the existing W8.5 roadmap (drive-test → W8.5c-follow → patrol mode W8.5e–i) in parallel — these streams are file-disjoint from community work.

---

## 9. Out-of-Scope Follow-Ups

**Zone chat cross-pollination.** When a community pin is created in a zone, auto-posting it to that zone's chat as a `system_tracker` message is already noted as "Phase 2d" in HANDOFF.md. The schema supports it (`zone_messages.related_report_id` maps to `pins.id`). The RPC is documented in `01-mvp-schema.sql:99–101`. Not Tier 1; not TF1. Land it in TF2 after Tier 2 reporting is live.

**Spot handoff ("I'm leaving this spot").** Explicitly deferred per `community-1.0-direction.md` §4 with legal/abuse rationale (MonkeyParking/Sweetch SF precedent). Do not spec or build.

**Android.** iOS-only for v1.0 per the 2026-05-07 decision in HANDOFF.md.

**Business model / paywall.** `docs/business-model.md` documents Free + WePark Pro, $4.99/mo. MVP ships free. Community 1.0 is pre-paywall. Don't add StoreKit or feature-gating to any Tier 1/2/3 work.

**DOT closure + construction data quality audit.** Recommended for TF2 when @backend-data can evaluate the actual dataset reliability. The NYC HIQA / DOT permit APIs are inconsistent; shipping bad durable pins (construction on a block that finished 6 months ago) destroys trust faster than shipping nothing. Hold until quality is verified.
